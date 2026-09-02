#!/usr/bin/env node
/**
 * 在公司内部流水线中分阶段发布 @mediaio/cli。
 *
 * 用法：
 *   node deploy/publish-release.mjs sync-source
 *   node deploy/publish-release.mjs force-github-baseline
 *   node deploy/publish-release.mjs create-draft-release
 *   node deploy/publish-release.mjs upload-binary
 *   node deploy/publish-release.mjs publish-github-release
 *   node deploy/publish-release.mjs publish-npm
 *   node deploy/publish-release.mjs all
 *
 * 不依赖 gh、jq 或 GitHub Actions；只依赖 Node.js、Git 与 npm。
 */

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";

const packageRoot = resolve(new URL("..", import.meta.url).pathname);
const packageName = "@mediaio/cli";
const allowedOperations = new Set([
  "sync-source",
  "force-github-baseline",
  "create-draft-release",
  "upload-binary",
  "publish-github-release",
  "publish-npm",
  "all",
]);

function fail(message) {
  throw new Error(message);
}

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) fail(`缺少环境变量：${name}`);
  return value;
}

function assertSemVer(version) {
  if (!/^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$/.test(version)) {
    fail(`RELEASE_VERSION 不是合法的 SemVer：${version}`);
  }
}

function assertBaseVersion(version) {
  if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(version)) {
    fail(`BASE_VERSION 必须是未带 prerelease/build metadata 的 SemVer：${version}`);
  }
}

function parseCiSuffixSelection(value) {
  if (value === "true") return true;
  if (value === "false") return false;
  fail(`RELEASE_WITH_CI_SUFFIX 仅支持 true 或 false：${value}`);
}

function assertReleaseSelection(baseVersion, releaseVersion, releaseDistTag, withCiSuffix) {
  assertBaseVersion(baseVersion);
  assertSemVer(releaseVersion);
  if (releaseDistTag !== "next" && releaseDistTag !== "latest") {
    fail(`RELEASE_DIST_TAG 仅支持 next 或 latest：${releaseDistTag}`);
  }
  if (!withCiSuffix) {
    if (releaseVersion !== baseVersion) fail(`未启用 CI 后缀时 RELEASE_VERSION 必须等于 BASE_VERSION：${releaseVersion}`);
    return;
  }

  const prefix = `${baseVersion}-ci.`;
  const buildNumber = releaseVersion.startsWith(prefix) ? releaseVersion.slice(prefix.length) : "";
  if (!/^[1-9][0-9]*$/.test(buildNumber)) {
    fail(`启用 CI 后缀时 RELEASE_VERSION 必须为 ${baseVersion}-ci.<正整数>：${releaseVersion}`);
  }
}

// GitHub Release 页面的“Release label”只有 None/Pre-release/Latest 三态，由 RELEASE_DIST_TAG 派生：
// latest -> Latest，next -> Pre-release；assertReleaseSelection 目前只放行这两个取值，
// 未识别的取值一律回退为 None，不允许静默变成 Latest。
function releaseLabelFor(releaseDistTag) {
  if (releaseDistTag === "latest") return { prerelease: false, makeLatest: "true" };
  if (releaseDistTag === "next") return { prerelease: true, makeLatest: "false" };
  return { prerelease: false, makeLatest: "false" };
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? packageRoot,
    env: options.env ?? process.env,
    encoding: "utf8",
  });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error) fail(`${command} 无法执行：${result.error.message}`);
  if (result.status !== 0) fail(`${command} 执行失败，退出码：${result.status}`);
  return result.stdout.trim();
}

function tryRun(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? packageRoot,
    env: options.env ?? process.env,
    encoding: "utf8",
  });
  return {
    ok: !result.error && result.status === 0,
    status: result.status,
    stdout: (result.stdout ?? "").trim(),
    stderr: (result.stderr ?? "").trim(),
  };
}

// npm publish 后新版本在 registry 各边缘节点的可见时间不固定，紧跟着的 npm install
// 偶尔会拿到还没同步的旧 packument 而报 ETARGET；这里按退避延迟重试同一条命令。
async function runWithRetry(command, args, options, retryDelaysMs) {
  for (let attempt = 0; attempt < retryDelaysMs.length; attempt += 1) {
    if (attempt > 0) {
      const delayMs = retryDelaysMs[attempt];
      console.log(`[publish] ${command} ${args.join(" ")} 失败，${Math.round(delayMs / 1_000)} 秒后重试（${attempt}/${retryDelaysMs.length - 1}）`);
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
    const result = tryRun(command, args, options);
    if (result.stdout) process.stdout.write(`${result.stdout}\n`);
    if (result.stderr) process.stderr.write(`${result.stderr}\n`);
    if (result.ok) return result.stdout;
    if (attempt === retryDelaysMs.length - 1) fail(`${command} 执行失败，退出码：${result.status}`);
  }
}

function sha256(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    fail(`无法读取 JSON 文件 ${file}：${error.message}`);
  }
}

function parseChecksums(file) {
  const result = new Map();
  for (const line of readFileSync(file, "utf8").trim().split("\n")) {
    if (!line.trim()) continue;
    const [checksum, name] = line.trim().split(/\s+/);
    if (!checksum || !name) fail(`checksums.txt 格式错误：${line}`);
    result.set(name, checksum);
  }
  return result;
}

function createGitAskPass(token) {
  const directory = mkdtempSync(join(tmpdir(), "mediaio-github-askpass-"));
  const script = join(directory, "askpass.sh");
  writeFileSync(
    script,
    `#!/usr/bin/env bash\ncase "$1" in\n  *Username*) printf '%s\\n' 'x-access-token' ;;\n  *Password*) printf '%s\\n' "$GITHUB_TOKEN" ;;\n  *) exit 1 ;;\nesac\n`,
    { mode: 0o700 },
  );
  return {
    directory,
    env: {
      ...process.env,
      GITHUB_TOKEN: token,
      GIT_ASKPASS: script,
      GIT_TERMINAL_PROMPT: "0",
    },
  };
}

async function githubRequest(url, token, options = {}) {
  const response = await fetch(url, {
    method: options.method ?? "GET",
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "X-GitHub-Api-Version": "2022-11-28",
      ...(options.headers ?? {}),
    },
    body: options.body,
  });
  if (options.allowNotFound && response.status === 404) return null;
  const body = await response.text();
  if (!response.ok) {
    fail(`GitHub API ${options.method ?? "GET"} ${url} 失败：HTTP ${response.status} ${body}`);
  }
  return body ? JSON.parse(body) : {};
}

function sourceContext(baseVersion) {
  for (const command of ["git", "node"]) {
    if (!tryRun(command, ["--version"]).ok) fail(`缺少命令：${command}`);
  }

  const pkg = readJson(join(packageRoot, "package.json"));
  if (pkg.name !== packageName) fail(`正式发布包名必须是 ${packageName}，当前为：${pkg.name}`);
  if (pkg.version !== baseVersion) {
    fail(`package.json.version (${pkg.version}) 必须等于 BASE_VERSION (${baseVersion})`);
  }

  const cliCommit = run("git", ["rev-parse", "HEAD"]);
  if (run("git", ["rev-parse", "--is-shallow-repository"]) === "true") {
    fail("CLI checkout 为 shallow repository；请在代码拉取插件中启用完整历史后再发布");
  }
  if (process.env.CLI_RELEASE_COMMIT && process.env.CLI_RELEASE_COMMIT !== cliCommit) {
    fail("当前 CLI checkout 与 CLI_RELEASE_COMMIT 不一致");
  }
  return { cliCommit };
}

function binaryArchiveNames(releaseVersion) {
  const targets = [
    ["darwin", "amd64"],
    ["darwin", "arm64"],
    ["linux", "amd64"],
    ["linux", "arm64"],
    ["windows", "amd64"],
    ["windows", "arm64"],
  ];
  return targets.map(([os, arch]) => `mediaio_${releaseVersion}_${os}_${arch}.tar.gz`);
}

function verifiedArtifacts(releaseVersion) {
  const binArtifactDirectory = resolve(requiredEnv("BIN_ARTIFACT_DIR"));
  if (!existsSync(binArtifactDirectory)) fail(`BIN_ARTIFACT_DIR 不存在：${binArtifactDirectory}`);

  const binBuild = readJson(join(binArtifactDirectory, "bin-build.json"));
  if (binBuild.release_version !== releaseVersion) fail("bin-build.json 的版本不匹配");

  const archiveNames = binaryArchiveNames(releaseVersion);
  const checksumsPath = join(binArtifactDirectory, "checksums.txt");
  const checksums = parseChecksums(checksumsPath);
  for (const name of archiveNames) {
    const file = join(binArtifactDirectory, name);
    if (!existsSync(file)) fail(`缺少 binary Asset：${file}`);
    if (checksums.get(name) !== sha256(file)) fail(`checksums.txt 与 ${name} 不一致`);
  }

  return {
    archiveNames,
    binArtifactDirectory,
    binBuild,
    checksums,
    checksumsPath,
  };
}

function configureGithubRemote(githubToken, githubRepository) {
  const gitAuth = createGitAskPass(githubToken);
  askPassDirectory = gitAuth.directory;
  const remoteName = "github-publish";
  const remoteUrl = `https://github.com/${githubRepository}.git`;
  if (tryRun("git", ["remote", "get-url", remoteName], { env: gitAuth.env }).ok) {
    run("git", ["remote", "set-url", remoteName, remoteUrl], { env: gitAuth.env });
  } else {
    run("git", ["remote", "add", remoteName, remoteUrl], { env: gitAuth.env });
  }
  return { ...gitAuth, remoteName };
}

function syncSource(gitAuth, cliCommit, githubBranch) {
  run("git", ["fetch", "--no-tags", gitAuth.remoteName, githubBranch], { env: gitAuth.env });
  if (!tryRun("git", ["merge-base", "--is-ancestor", `${gitAuth.remoteName}/${githubBranch}`, cliCommit], { env: gitAuth.env }).ok) {
    fail(`GitHub ${githubBranch} 不是当前 CLI 提交的祖先；请先人工完成镜像基线对齐，不能 force push`);
  }
  run("git", ["push", gitAuth.remoteName, `${cliCommit}:refs/heads/${githubBranch}`], { env: gitAuth.env });
  console.log(`[publish] source synced: ${githubBranch} -> ${cliCommit}`);
}

// 仅用于首次把内网 CLI 建立为 GitHub main 的镜像基线。
// 常规发布绝不能调用此方法，仍由 syncSource 只允许 fast-forward。
function forceGithubBaseline(gitAuth, cliCommit, githubRepository, githubBranch) {
  if (githubRepository !== "media-io/cli" || githubBranch !== "main") {
    fail("force-github-baseline 仅允许更新 media-io/cli 的 main 分支");
  }
  if (requiredEnv("GITHUB_BASELINE_FORCE_ACK") !== "REPLACE_GITHUB_MAIN_WITH_INTERNAL_CLI") {
    fail("必须将 GITHUB_BASELINE_FORCE_ACK 设置为 REPLACE_GITHUB_MAIN_WITH_INTERNAL_CLI 才能执行一次性基线覆盖");
  }

  run("git", ["fetch", "--no-tags", gitAuth.remoteName, githubBranch], { env: gitAuth.env });
  const remoteCommit = run("git", ["rev-parse", `${gitAuth.remoteName}/${githubBranch}`], { env: gitAuth.env });
  console.log(`[publish] baseline force: ${githubRepository}/${githubBranch} ${remoteCommit} -> ${cliCommit}`);
  run("git", [
    "push",
    `--force-with-lease=refs/heads/${githubBranch}:${remoteCommit}`,
    gitAuth.remoteName,
    `${cliCommit}:refs/heads/${githubBranch}`,
  ], { env: gitAuth.env });

  const remoteHead = run("git", ["ls-remote", gitAuth.remoteName, `refs/heads/${githubBranch}`], { env: gitAuth.env }).split(/\s+/)[0];
  if (remoteHead !== cliCommit) fail(`GitHub ${githubBranch} 基线覆盖后提交校验失败`);
  console.log(`[publish] baseline force completed: ${githubBranch} -> ${cliCommit}`);
}

function assertSourceAlreadySynced(gitAuth, cliCommit, githubBranch) {
  run("git", ["fetch", "--no-tags", gitAuth.remoteName, githubBranch], { env: gitAuth.env });
  if (!tryRun("git", ["merge-base", "--is-ancestor", cliCommit, `${gitAuth.remoteName}/${githubBranch}`], { env: gitAuth.env }).ok) {
    fail(`GitHub ${githubBranch} 尚未包含当前 CLI 提交；请先执行“同步 CLI 源码到 GitHub”`);
  }
}

function ensureGithubTag(gitAuth, githubTag, cliCommit) {
  const dereferencedTag = run("git", ["ls-remote", gitAuth.remoteName, `refs/tags/${githubTag}^{}`], { env: gitAuth.env });
  const lightweightTag = run("git", ["ls-remote", gitAuth.remoteName, `refs/tags/${githubTag}`], { env: gitAuth.env });
  const existingTagCommit = (dereferencedTag || lightweightTag).split(/\s+/)[0];
  if (existingTagCommit) {
    if (existingTagCommit !== cliCommit) {
      fail(`GitHub tag ${githubTag} 已存在但未指向当前 CLI 提交`);
    }
    console.log(`[publish] tag already present: ${githubTag}`);
    return;
  }
  // 流水线 checkout 可能已带同名内网 tag，直接 git tag -a 会报“标签已存在”。
  // 这里只重建工作区内的本地 tag，不影响内网仓库；GitHub 侧不存在同名 tag 已在上面校验过。
  const localTagCommit = tryRun("git", ["rev-parse", "--verify", "--quiet", `refs/tags/${githubTag}^{commit}`], { env: gitAuth.env });
  if (localTagCommit.ok) {
    console.log(`[publish] local tag exists: ${githubTag} -> ${localTagCommit.stdout}; recreate for ${cliCommit}`);
    run("git", ["tag", "-d", githubTag], { env: gitAuth.env });
  }
  run("git", ["config", "user.name", process.env.GIT_TAGGER_NAME ?? "mediaio-release-bot"], { env: gitAuth.env });
  run("git", ["config", "user.email", process.env.GIT_TAGGER_EMAIL ?? "mediaio-release-bot@users.noreply.github.com"], { env: gitAuth.env });
  run("git", ["tag", "-a", githubTag, cliCommit, "-m", `Release ${githubTag}`], { env: gitAuth.env });
  run("git", ["push", gitAuth.remoteName, `refs/tags/${githubTag}:refs/tags/${githubTag}`], { env: gitAuth.env });
  const pushedTagCommit = run("git", ["ls-remote", gitAuth.remoteName, `refs/tags/${githubTag}^{}`], { env: gitAuth.env }).split(/\s+/)[0];
  if (pushedTagCommit !== cliCommit) fail(`GitHub tag ${githubTag} 推送后未指向当前 CLI 提交`);
  console.log(`[publish] tag created: ${githubTag}`);
}

async function releaseForTag(apiBase, githubTag, githubToken) {
  const taggedRelease = await githubRequest(
    `${apiBase}/releases/tags/${encodeURIComponent(githubTag)}`,
    githubToken,
    { allowNotFound: true },
  );
  if (taggedRelease) return taggedRelease;

  // GitHub 的按 tag 查询在部分场景不会返回 Draft Release；已认证的
  // Release 列表会包含该 Draft，因此用它作为安全回退，不会创建新 Release。
  const releases = await githubRequest(`${apiBase}/releases?per_page=100`, githubToken);
  return releases.find((release) => release.tag_name === githubTag) ?? null;
}

// Draft Release 在某些 GitHub Token/API 组合下不能可靠地通过 tag 或列表再次查询。
// 因此创建阶段把 GitHub 返回的 Release ID 保存到当前发布 Job 的工作区，后续阶段
// 直接使用该 ID。该文件不包含任何密钥，也不属于发布产物。
function githubReleaseStatePath() {
  const stateDirectory = resolve(process.env.WORKSPACE ?? packageRoot);
  if (!existsSync(stateDirectory)) {
    fail(`GitHub Release 状态目录不存在：${stateDirectory}`);
  }
  return join(stateDirectory, ".mediaio-github-release-state.json");
}

function writeGithubReleaseState(release, githubRepository, githubTag, releaseVersion, cliCommit) {
  if (!release?.id) fail("GitHub Draft Release 未返回 release.id");
  const statePath = githubReleaseStatePath();
  const state = {
    schema_version: 1,
    github_repository: githubRepository,
    github_tag: githubTag,
    release_version: releaseVersion,
    cli_commit: cliCommit,
    release_id: release.id,
  };
  writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  console.log(`[publish] draft release state saved: ${statePath}`);
  return state;
}

function readGithubReleaseState(githubRepository, githubTag, releaseVersion, cliCommit, options = {}) {
  const statePath = githubReleaseStatePath();
  if (!existsSync(statePath)) {
    if (options.allowMissing) return null;
    fail(`缺少 Draft Release 状态文件：${statePath}；请先执行“创建 GitHub tag/Draft Release”步骤`);
  }
  const state = readJson(statePath);
  if (
    state.schema_version !== 1
    || state.github_repository !== githubRepository
    || state.github_tag !== githubTag
    || state.release_version !== releaseVersion
    || state.cli_commit !== cliCommit
    || !state.release_id
  ) {
    if (options.allowMissing) return null;
    fail(`Draft Release 状态文件与当前发布不匹配：${statePath}`);
  }
  return state;
}

// GitHub 创建 Draft 后，按 Release ID 读取偶尔也会经历数十秒的最终一致性延迟。
// 上传或公开阶段最多等待约 98 秒，避免因短暂的 404 而使流水线失败。
async function releaseFromState(apiBase, githubToken, state, options = {}) {
  const retryDelaysMs = [0, 2_000, 3_000, 5_000, 8_000, 10_000, 10_000, 10_000, 10_000, 10_000, 10_000, 10_000, 10_000];
  for (let attempt = 0; attempt < retryDelaysMs.length; attempt += 1) {
    const release = await githubRequest(`${apiBase}/releases/${encodeURIComponent(state.release_id)}`, githubToken, {
      allowNotFound: true,
    });
    if (release) {
      if (release.tag_name !== state.github_tag) {
        fail(`GitHub Release ID ${state.release_id} 的 tag 与状态文件不一致`);
      }
      return release;
    }

    if (options.retry === false || attempt === retryDelaysMs.length - 1) break;
    const delayMs = retryDelaysMs[attempt + 1];
    console.log(`[publish] Draft Release ID ${state.release_id} 尚未可查询，${Math.round(delayMs / 1_000)} 秒后重试（${attempt + 1}/${retryDelaysMs.length - 1}）`);
    await new Promise((resolve) => setTimeout(resolve, delayMs));
  }
  if (options.allowMissing) return null;
  fail(`等待 GitHub Draft Release 可查询超时：${state.github_tag}`);
}

async function ensureDraftRelease(apiBase, githubTag, cliCommit, releaseDistTag, githubToken) {
  let release = await releaseForTag(apiBase, githubTag, githubToken);
  if (!release) {
    const { prerelease, makeLatest } = releaseLabelFor(releaseDistTag);
    release = await githubRequest(`${apiBase}/releases`, githubToken, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        tag_name: githubTag,
        target_commitish: cliCommit,
        name: githubTag,
        draft: true,
        prerelease,
        make_latest: makeLatest,
        generate_release_notes: false,
      }),
    });
    console.log(`[publish] draft release created: ${githubTag}`);
  } else if (!release.draft) {
    fail(`GitHub Release ${githubTag} 已公开；不能创建或改写 Draft Release`);
  } else {
    console.log(`[publish] draft release already present: ${githubTag}`);
  }
  return release;
}

function createReleaseManifest(baseVersion, releaseVersion, releaseDistTag, withCiSuffix, githubTag, cliCommit, artifacts) {
  temporaryDirectory = mkdtempSync(join(tmpdir(), "mediaio-release-"));
  const releaseManifestPath = join(temporaryDirectory, "release-manifest.json");
  const releaseManifest = {
    schema_version: 1,
    base_version: baseVersion,
    release_dist_tag: releaseDistTag,
    release_with_ci_suffix: withCiSuffix,
    release_version: releaseVersion,
    github_tag: githubTag,
    cli: {
      commit: cliCommit,
      package: packageName,
    },
    bin: {
      commit: artifacts.binBuild.bin_commit,
      build_number: artifacts.binBuild.build_number,
      built_at: artifacts.binBuild.built_at,
      go_version: artifacts.binBuild.go_version,
    },
    assets: artifacts.archiveNames.map((name) => ({ name, sha256: artifacts.checksums.get(name) })),
  };
  writeFileSync(releaseManifestPath, `${JSON.stringify(releaseManifest, null, 2)}\n`);
  return releaseManifestPath;
}

function releaseAssetNames(archiveNames) {
  return [...archiveNames, "checksums.txt", "release-manifest.json"];
}

async function uploadBinaryAssets(release, apiBase, githubRepository, githubToken, artifacts, manifestPath) {
  if (!release.draft) fail("GitHub Release 已公开，拒绝继续上传或覆盖 Asset");

  const uploadFiles = [
    ...artifacts.archiveNames.map((name) => join(artifacts.binArtifactDirectory, name)),
    artifacts.checksumsPath,
    manifestPath,
  ];
  const existingAssets = new Map(release.assets.map((asset) => [asset.name, asset]));
  for (const file of uploadFiles) {
    const name = basename(file);
    const existing = existingAssets.get(name);
    if (existing) {
      if (Number(existing.size) !== statSync(file).size) {
        fail(`GitHub Draft Release 中已有同名但大小不同的 Asset：${name}`);
      }
      console.log(`[publish] asset already present, skip: ${name}`);
      continue;
    }
    const uploadUrl = `https://uploads.github.com/repos/${githubRepository}/releases/${release.id}/assets?name=${encodeURIComponent(name)}`;
    await githubRequest(uploadUrl, githubToken, {
      method: "POST",
      headers: { "Content-Type": "application/octet-stream" },
      body: readFileSync(file),
    });
    console.log(`[publish] uploaded: ${name}`);
  }

  const refreshedRelease = await githubRequest(`${apiBase}/releases/${release.id}`, githubToken);
  const uploadedNames = new Set(refreshedRelease.assets.map((asset) => asset.name));
  for (const name of releaseAssetNames(artifacts.archiveNames)) {
    if (!uploadedNames.has(name)) fail(`GitHub Release 缺少已上传资产：${name}`);
  }
  console.log(`[publish] binary assets verified: ${release.tag_name}`);
  return refreshedRelease;
}

async function publishGithubRelease(release, apiBase, githubToken, archiveNames, releaseDistTag) {
  const uploadedNames = new Set(release.assets.map((asset) => asset.name));
  for (const name of releaseAssetNames(archiveNames)) {
    if (!uploadedNames.has(name)) fail(`GitHub Release 缺少资产：${name}`);
  }
  const { prerelease, makeLatest } = releaseLabelFor(releaseDistTag);
  if (!release.draft) {
    // Draft 期间 make_latest 会被 GitHub 忽略，公开后的 prerelease 才是最终真值；
    // 已公开的重试如果标签和本次 RELEASE_DIST_TAG 对不上，说明发布渠道选错了，不能静默放行。
    if (release.prerelease !== prerelease) {
      fail(`GitHub Release ${release.tag_name} 已公开，但 prerelease=${release.prerelease} 与 RELEASE_DIST_TAG=${releaseDistTag} 期望值不一致`);
    }
    console.log(`[publish] GitHub Release already public: ${release.tag_name}`);
    return release;
  }
  const publicRelease = await githubRequest(`${apiBase}/releases/${release.id}`, githubToken, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ draft: false, prerelease, make_latest: makeLatest }),
  });
  if (publicRelease.draft) fail("GitHub Release 未成功公开");
  if (publicRelease.prerelease !== prerelease) fail(`GitHub Release 公开后 prerelease 状态与 RELEASE_DIST_TAG=${releaseDistTag} 不一致`);
  console.log(`[publish] GitHub Release published: ${publicRelease.tag_name} (dist-tag=${releaseDistTag})`);
  return publicRelease;
}

function createNpmPublishCopy(releaseVersion) {
  const temporaryRoot = mkdtempSync(join(tmpdir(), "mediaio-npm-package-"));
  const publishRoot = join(temporaryRoot, "package");
  const excludedNames = new Set([".git", "node_modules", "vendor"]);
  cpSync(packageRoot, publishRoot, {
    recursive: true,
    filter: (source) => !excludedNames.has(basename(source)),
  });

  const pkgPath = join(publishRoot, "package.json");
  const pkg = readJson(pkgPath);
  if (pkg.name !== packageName) fail(`正式发布包名必须是 ${packageName}，当前为：${pkg.name}`);
  pkg.version = releaseVersion;
  writeFileSync(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`);
  return { publishRoot, temporaryRoot };
}

async function publishNpm(releaseVersion, releaseDistTag, githubTag, apiBase, githubToken) {
  const release = await releaseForTag(apiBase, githubTag, githubToken);
  if (!release || release.draft) fail("GitHub Release 尚未公开，禁止发布 npm");
  const uploadedNames = new Set(release.assets.map((asset) => asset.name));
  for (const name of releaseAssetNames(binaryArchiveNames(releaseVersion))) {
    if (!uploadedNames.has(name)) fail(`已公开的 GitHub Release 缺少资产：${name}`);
  }

  if (!tryRun("npm", ["--version"]).ok) fail("缺少命令：npm");
  const npmToken = requiredEnv("NODE_AUTH_TOKEN");
  const npmDistTag = releaseDistTag;
  const npmDirectory = mkdtempSync(join(tmpdir(), "mediaio-npmrc-"));
  const publishCopy = createNpmPublishCopy(releaseVersion);
  const npmrcPath = join(npmDirectory, ".npmrc");
  writeFileSync(npmrcPath, `//registry.npmjs.org/:_authToken=${npmToken}\n`, { mode: 0o600 });
  const npmEnv = { ...process.env, NPM_CONFIG_USERCONFIG: npmrcPath };
  try {
    const existingPackage = tryRun("npm", ["view", `${packageName}@${releaseVersion}`, "version", "--registry=https://registry.npmjs.org"], { env: npmEnv });
    if (existingPackage.ok) {
      if (existingPackage.stdout !== releaseVersion) {
        fail(`npmjs 中已有冲突版本：${existingPackage.stdout}`);
      }
      console.log(`[publish] npm version already present: ${packageName}@${releaseVersion}`);
    } else {
      run("npm", ["pack", "--dry-run"], { cwd: publishCopy.publishRoot, env: npmEnv });
      run("npm", ["publish", "--access", "public", "--tag", npmDistTag, "--registry=https://registry.npmjs.org"], { cwd: publishCopy.publishRoot, env: npmEnv });
    }

    const smokeDirectory = mkdtempSync(join(tmpdir(), "mediaio-smoke-"));
    try {
      const npmRegistryPropagationDelaysMs = [0, 3_000, 5_000, 8_000, 10_000, 15_000, 15_000, 15_000, 15_000];
      await runWithRetry(
        "npm",
        ["install", "--prefix", smokeDirectory, "--registry=https://registry.npmjs.org", `${packageName}@${releaseVersion}`],
        { env: npmEnv },
        npmRegistryPropagationDelaysMs,
      );
      run(join(smokeDirectory, "node_modules", ".bin", "mediaio"), ["--help"], { env: npmEnv });
      run(join(smokeDirectory, "node_modules", ".bin", "mi"), ["--help"], { env: npmEnv });
    } finally {
      rmSync(smokeDirectory, { recursive: true, force: true });
    }
  } finally {
    rmSync(npmDirectory, { recursive: true, force: true });
    rmSync(publishCopy.temporaryRoot, { recursive: true, force: true });
  }
  console.log(`[publish] npm published and verified: ${packageName}@${releaseVersion}`);
}

function printUsage() {
  console.log("用法：node deploy/publish-release.mjs <sync-source|force-github-baseline|create-draft-release|upload-binary|publish-github-release|publish-npm|all>");
}

const operation = process.argv[2] ?? "all";
if (operation === "--help" || operation === "-h") {
  printUsage();
  process.exit(0);
}
if (process.argv.length > 3 || !allowedOperations.has(operation)) {
  printUsage();
  fail(`不支持的发布阶段：${operation}`);
}

const releaseVersion = requiredEnv("RELEASE_VERSION");
const baseVersion = process.env.BASE_VERSION ?? releaseVersion;
// 发布渠道是安全边界：缺失时不能静默降级为 latest，避免预发布误占用稳定版 tag/npm 版本。
const releaseDistTag = requiredEnv("RELEASE_DIST_TAG");
const withCiSuffix = parseCiSuffixSelection(requiredEnv("RELEASE_WITH_CI_SUFFIX"));
if (process.env.NPM_DIST_TAG && process.env.NPM_DIST_TAG !== releaseDistTag) {
  fail("NPM_DIST_TAG 必须由 RELEASE_DIST_TAG 派生，二者不一致");
}
assertReleaseSelection(baseVersion, releaseVersion, releaseDistTag, withCiSuffix);
const githubRepository = process.env.GITHUB_REPOSITORY ?? "media-io/cli";
const githubBranch = process.env.GITHUB_BRANCH ?? "main";
const githubTag = `v${releaseVersion}`;
const apiBase = `https://api.github.com/repos/${githubRepository}`;

let temporaryDirectory = "";
let askPassDirectory = "";

try {
  const source = sourceContext(baseVersion);
  console.log(`[publish] phase: ${operation}`);
  console.log(`[publish] base version: ${baseVersion}`);
  console.log(`[publish] release: ${releaseVersion}`);
  console.log(`[publish] dist-tag: ${releaseDistTag}`);
  console.log(`[publish] CI suffix: ${withCiSuffix}`);
  console.log(`[publish] CLI commit: ${source.cliCommit}`);

  if (operation === "sync-source") {
    const githubToken = requiredEnv("GITHUB_TOKEN");
    const gitAuth = configureGithubRemote(githubToken, githubRepository);
    syncSource(gitAuth, source.cliCommit, githubBranch);
  } else if (operation === "force-github-baseline") {
    const githubToken = requiredEnv("GITHUB_TOKEN");
    const gitAuth = configureGithubRemote(githubToken, githubRepository);
    forceGithubBaseline(gitAuth, source.cliCommit, githubRepository, githubBranch);
  } else if (operation === "create-draft-release") {
    const githubToken = requiredEnv("GITHUB_TOKEN");
    const gitAuth = configureGithubRemote(githubToken, githubRepository);
    assertSourceAlreadySynced(gitAuth, source.cliCommit, githubBranch);
    ensureGithubTag(gitAuth, githubTag, source.cliCommit);
    const storedState = readGithubReleaseState(
      githubRepository,
      githubTag,
      releaseVersion,
      source.cliCommit,
      { allowMissing: true },
    );
    let release = storedState
      ? await releaseFromState(apiBase, githubToken, storedState, { allowMissing: true, retry: false })
      : null;
    if (!release) {
      release = await ensureDraftRelease(apiBase, githubTag, source.cliCommit, releaseDistTag, githubToken);
    }
    if (!release.draft) fail(`GitHub Release ${githubTag} 已公开；不能创建或改写 Draft Release`);
    writeGithubReleaseState(release, githubRepository, githubTag, releaseVersion, source.cliCommit);
  } else if (operation === "upload-binary") {
    const githubToken = requiredEnv("GITHUB_TOKEN");
    const artifacts = verifiedArtifacts(releaseVersion);
    const state = readGithubReleaseState(githubRepository, githubTag, releaseVersion, source.cliCommit);
    const release = await releaseFromState(apiBase, githubToken, state);
    const manifestPath = createReleaseManifest(baseVersion, releaseVersion, releaseDistTag, withCiSuffix, githubTag, source.cliCommit, artifacts);
    await uploadBinaryAssets(release, apiBase, githubRepository, githubToken, artifacts, manifestPath);
  } else if (operation === "publish-github-release") {
    const githubToken = requiredEnv("GITHUB_TOKEN");
    const state = readGithubReleaseState(githubRepository, githubTag, releaseVersion, source.cliCommit);
    const release = await releaseFromState(apiBase, githubToken, state);
    await publishGithubRelease(release, apiBase, githubToken, binaryArchiveNames(releaseVersion), releaseDistTag);
  } else if (operation === "publish-npm") {
    const githubToken = requiredEnv("GITHUB_TOKEN");
    await publishNpm(releaseVersion, releaseDistTag, githubTag, apiBase, githubToken);
  } else {
    const githubToken = requiredEnv("GITHUB_TOKEN");
    const artifacts = verifiedArtifacts(releaseVersion);
    const gitAuth = configureGithubRemote(githubToken, githubRepository);
    syncSource(gitAuth, source.cliCommit, githubBranch);
    ensureGithubTag(gitAuth, githubTag, source.cliCommit);
    let release = await ensureDraftRelease(apiBase, githubTag, source.cliCommit, releaseDistTag, githubToken);
    const manifestPath = createReleaseManifest(baseVersion, releaseVersion, releaseDistTag, withCiSuffix, githubTag, source.cliCommit, artifacts);
    release = await uploadBinaryAssets(release, apiBase, githubRepository, githubToken, artifacts, manifestPath);
    await publishGithubRelease(release, apiBase, githubToken, artifacts.archiveNames, releaseDistTag);
    await publishNpm(releaseVersion, releaseDistTag, githubTag, apiBase, githubToken);
  }
} finally {
  if (temporaryDirectory) rmSync(temporaryDirectory, { recursive: true, force: true });
  if (askPassDirectory) rmSync(askPassDirectory, { recursive: true, force: true });
}

// Node 18 的 fetch 连接偶尔会让事件循环在发布完成后继续存活。
// 此处已完成全部发布与临时目录清理，显式退出以结束流水线 Bash 节点。
process.exit(0);

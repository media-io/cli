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
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
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

function findOnlyTarball(directory) {
  const tarballs = readdirSync(directory)
    .filter((name) => name.endsWith(".tgz"))
    .map((name) => join(directory, name));
  if (tarballs.length !== 1) {
    fail(`CLI_ARTIFACT_DIR 中必须恰好有一个 .tgz 文件，实际为 ${tarballs.length} 个`);
  }
  return tarballs[0];
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

function sourceContext(releaseVersion) {
  for (const command of ["git", "node"]) {
    if (!tryRun(command, ["--version"]).ok) fail(`缺少命令：${command}`);
  }

  const pkg = readJson(join(packageRoot, "package.json"));
  if (pkg.name !== packageName) fail(`正式发布包名必须是 ${packageName}，当前为：${pkg.name}`);
  if (pkg.version !== releaseVersion) {
    fail(`package.json.version (${pkg.version}) 必须等于 RELEASE_VERSION (${releaseVersion})`);
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

function verifiedArtifacts(releaseVersion, cliCommit) {
  const binArtifactDirectory = resolve(requiredEnv("BIN_ARTIFACT_DIR"));
  const cliArtifactDirectory = resolve(requiredEnv("CLI_ARTIFACT_DIR"));
  if (!existsSync(binArtifactDirectory)) fail(`BIN_ARTIFACT_DIR 不存在：${binArtifactDirectory}`);
  if (!existsSync(cliArtifactDirectory)) fail(`CLI_ARTIFACT_DIR 不存在：${cliArtifactDirectory}`);

  const binBuild = readJson(join(binArtifactDirectory, "bin-build.json"));
  const cliBuild = readJson(join(cliArtifactDirectory, "cli-build.json"));
  const cliTarball = findOnlyTarball(cliArtifactDirectory);
  if (binBuild.release_version !== releaseVersion) fail("bin-build.json 的版本不匹配");
  if (cliBuild.release_version !== releaseVersion) fail("cli-build.json 的版本不匹配");
  if (cliBuild.package_name !== packageName) fail("cli-build.json 的包名不匹配");
  if (cliBuild.cli_commit !== cliCommit) {
    fail("当前 CLI checkout 与已验证 npm tarball 的源提交不一致");
  }
  if (cliBuild.tarball_sha256 !== sha256(cliTarball)) {
    fail("npm tarball 的 SHA-256 与 cli-build.json 不一致");
  }

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
    cliBuild,
    cliTarball,
  };
}

function verifiedCliArtifact(releaseVersion, cliCommit) {
  const cliArtifactDirectory = resolve(requiredEnv("CLI_ARTIFACT_DIR"));
  if (!existsSync(cliArtifactDirectory)) fail(`CLI_ARTIFACT_DIR 不存在：${cliArtifactDirectory}`);

  const cliBuild = readJson(join(cliArtifactDirectory, "cli-build.json"));
  const cliTarball = findOnlyTarball(cliArtifactDirectory);
  if (cliBuild.release_version !== releaseVersion) fail("cli-build.json 的版本不匹配");
  if (cliBuild.package_name !== packageName) fail("cli-build.json 的包名不匹配");
  if (cliBuild.cli_commit !== cliCommit) {
    fail("当前 CLI checkout 与已验证 npm tarball 的源提交不一致");
  }
  if (cliBuild.tarball_sha256 !== sha256(cliTarball)) {
    fail("npm tarball 的 SHA-256 与 cli-build.json 不一致");
  }
  return { cliBuild, cliTarball };
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
  run("git", ["config", "user.name", process.env.GIT_TAGGER_NAME ?? "mediaio-release-bot"], { env: gitAuth.env });
  run("git", ["config", "user.email", process.env.GIT_TAGGER_EMAIL ?? "mediaio-release-bot@users.noreply.github.com"], { env: gitAuth.env });
  run("git", ["tag", "-a", githubTag, cliCommit, "-m", `Release ${githubTag}`], { env: gitAuth.env });
  run("git", ["push", gitAuth.remoteName, `refs/tags/${githubTag}`], { env: gitAuth.env });
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

async function ensureDraftRelease(apiBase, githubTag, cliCommit, releaseVersion, githubToken) {
  let release = await releaseForTag(apiBase, githubTag, githubToken);
  if (!release) {
    release = await githubRequest(`${apiBase}/releases`, githubToken, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        tag_name: githubTag,
        target_commitish: cliCommit,
        name: githubTag,
        draft: true,
        prerelease: releaseVersion.includes("-"),
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

function createReleaseManifest(releaseVersion, githubTag, cliCommit, artifacts) {
  temporaryDirectory = mkdtempSync(join(tmpdir(), "mediaio-release-"));
  const releaseManifestPath = join(temporaryDirectory, "release-manifest.json");
  const releaseManifest = {
    schema_version: 1,
    release_version: releaseVersion,
    github_tag: githubTag,
    cli: {
      commit: cliCommit,
      package: packageName,
      tarball_name: basename(artifacts.cliTarball),
      tarball_sha256: sha256(artifacts.cliTarball),
    },
    bin: {
      commit: artifacts.binBuild.bin_commit,
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

async function publishGithubRelease(release, apiBase, githubToken, archiveNames) {
  const uploadedNames = new Set(release.assets.map((asset) => asset.name));
  for (const name of releaseAssetNames(archiveNames)) {
    if (!uploadedNames.has(name)) fail(`GitHub Release 缺少资产：${name}`);
  }
  if (!release.draft) {
    console.log(`[publish] GitHub Release already public: ${release.tag_name}`);
    return release;
  }
  const publicRelease = await githubRequest(`${apiBase}/releases/${release.id}`, githubToken, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ draft: false }),
  });
  if (publicRelease.draft) fail("GitHub Release 未成功公开");
  console.log(`[publish] GitHub Release published: ${publicRelease.tag_name}`);
  return publicRelease;
}

async function publishNpm(releaseVersion, githubTag, apiBase, githubToken, cliTarball) {
  const release = await releaseForTag(apiBase, githubTag, githubToken);
  if (!release || release.draft) fail("GitHub Release 尚未公开，禁止发布 npm");
  const uploadedNames = new Set(release.assets.map((asset) => asset.name));
  for (const name of releaseAssetNames(binaryArchiveNames(releaseVersion))) {
    if (!uploadedNames.has(name)) fail(`已公开的 GitHub Release 缺少资产：${name}`);
  }

  if (!tryRun("npm", ["--version"]).ok) fail("缺少命令：npm");
  const npmToken = requiredEnv("NODE_AUTH_TOKEN");
  const npmDistTag = process.env.NPM_DIST_TAG ?? "latest";
  const npmDirectory = mkdtempSync(join(tmpdir(), "mediaio-npmrc-"));
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
      run("npm", ["publish", cliTarball, "--access", "public", "--tag", npmDistTag, "--registry=https://registry.npmjs.org"], { env: npmEnv });
    }

    const smokeDirectory = mkdtempSync(join(tmpdir(), "mediaio-smoke-"));
    try {
      run("npm", ["install", "--prefix", smokeDirectory, "--registry=https://registry.npmjs.org", `${packageName}@${releaseVersion}`], { env: npmEnv });
      run(join(smokeDirectory, "bin", "mediaio"), ["--help"], { env: npmEnv });
    } finally {
      rmSync(smokeDirectory, { recursive: true, force: true });
    }
  } finally {
    rmSync(npmDirectory, { recursive: true, force: true });
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
assertSemVer(releaseVersion);
const githubRepository = process.env.GITHUB_REPOSITORY ?? "media-io/cli";
const githubBranch = process.env.GITHUB_BRANCH ?? "main";
const githubTag = `v${releaseVersion}`;
const apiBase = `https://api.github.com/repos/${githubRepository}`;

let temporaryDirectory = "";
let askPassDirectory = "";

try {
  const source = sourceContext(releaseVersion);
  console.log(`[publish] phase: ${operation}`);
  console.log(`[publish] release: ${releaseVersion}`);
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
    await ensureDraftRelease(apiBase, githubTag, source.cliCommit, releaseVersion, githubToken);
  } else if (operation === "upload-binary") {
    const githubToken = requiredEnv("GITHUB_TOKEN");
    const artifacts = verifiedArtifacts(releaseVersion, source.cliCommit);
    const release = await releaseForTag(apiBase, githubTag, githubToken);
    if (!release) fail(`找不到 GitHub Draft Release：${githubTag}`);
    const manifestPath = createReleaseManifest(releaseVersion, githubTag, source.cliCommit, artifacts);
    await uploadBinaryAssets(release, apiBase, githubRepository, githubToken, artifacts, manifestPath);
  } else if (operation === "publish-github-release") {
    const githubToken = requiredEnv("GITHUB_TOKEN");
    const release = await releaseForTag(apiBase, githubTag, githubToken);
    if (!release) fail(`找不到 GitHub Draft Release：${githubTag}`);
    await publishGithubRelease(release, apiBase, githubToken, binaryArchiveNames(releaseVersion));
  } else if (operation === "publish-npm") {
    const githubToken = requiredEnv("GITHUB_TOKEN");
    const cliArtifact = verifiedCliArtifact(releaseVersion, source.cliCommit);
    await publishNpm(releaseVersion, githubTag, apiBase, githubToken, cliArtifact.cliTarball);
  } else {
    const githubToken = requiredEnv("GITHUB_TOKEN");
    const artifacts = verifiedArtifacts(releaseVersion, source.cliCommit);
    const gitAuth = configureGithubRemote(githubToken, githubRepository);
    syncSource(gitAuth, source.cliCommit, githubBranch);
    ensureGithubTag(gitAuth, githubTag, source.cliCommit);
    let release = await ensureDraftRelease(apiBase, githubTag, source.cliCommit, releaseVersion, githubToken);
    const manifestPath = createReleaseManifest(releaseVersion, githubTag, source.cliCommit, artifacts);
    release = await uploadBinaryAssets(release, apiBase, githubRepository, githubToken, artifacts, manifestPath);
    await publishGithubRelease(release, apiBase, githubToken, artifacts.archiveNames);
    await publishNpm(releaseVersion, githubTag, apiBase, githubToken, artifacts.cliTarball);
  }
} finally {
  if (temporaryDirectory) rmSync(temporaryDirectory, { recursive: true, force: true });
  if (askPassDirectory) rmSync(askPassDirectory, { recursive: true, force: true });
}

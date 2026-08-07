#!/usr/bin/env node
/**
 * 在公司内部流水线中同步 CLI 源码、创建 GitHub Release、发布 npm 并冒烟验证。
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

const releaseVersion = requiredEnv("RELEASE_VERSION");
assertSemVer(releaseVersion);
const githubToken = requiredEnv("GITHUB_TOKEN");
const npmToken = requiredEnv("NODE_AUTH_TOKEN");
const binArtifactDirectory = resolve(requiredEnv("BIN_ARTIFACT_DIR"));
const cliArtifactDirectory = resolve(requiredEnv("CLI_ARTIFACT_DIR"));
const githubRepository = process.env.GITHUB_REPOSITORY ?? "media-io/cli";
const githubBranch = process.env.GITHUB_BRANCH ?? "main";
const npmDistTag = process.env.NPM_DIST_TAG ?? "latest";
const githubTag = `v${releaseVersion}`;
const packageName = "@mediaio/cli";

let temporaryDirectory = "";
let askPassDirectory = "";

try {
  for (const command of ["git", "npm", "node"]) {
    if (!tryRun(command, ["--version"]).ok) fail(`缺少命令：${command}`);
  }
  if (!existsSync(binArtifactDirectory)) fail(`BIN_ARTIFACT_DIR 不存在：${binArtifactDirectory}`);
  if (!existsSync(cliArtifactDirectory)) fail(`CLI_ARTIFACT_DIR 不存在：${cliArtifactDirectory}`);

  const pkg = readJson(join(packageRoot, "package.json"));
  if (pkg.name !== packageName) fail(`正式发布包名必须是 ${packageName}，当前为：${pkg.name}`);
  if (pkg.version !== releaseVersion) {
    fail(`package.json.version (${pkg.version}) 必须等于 RELEASE_VERSION (${releaseVersion})`);
  }

  const cliCommit = run("git", ["rev-parse", "HEAD"]);
  if (run("git", ["rev-parse", "--is-shallow-repository"]) === "true") {
    fail("CLI checkout 为 shallow repository；请在代码拉取插件中启用完整历史后再发布");
  }

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

  const targets = [
    ["darwin", "amd64"],
    ["darwin", "arm64"],
    ["linux", "amd64"],
    ["linux", "arm64"],
    ["windows", "amd64"],
    ["windows", "arm64"],
  ];
  const archiveNames = targets.map(([os, arch]) => `mediaio_${releaseVersion}_${os}_${arch}.tar.gz`);
  const checksumsPath = join(binArtifactDirectory, "checksums.txt");
  const checksums = parseChecksums(checksumsPath);
  for (const name of archiveNames) {
    const file = join(binArtifactDirectory, name);
    if (!existsSync(file)) fail(`缺少 binary Asset：${file}`);
    if (checksums.get(name) !== sha256(file)) fail(`checksums.txt 与 ${name} 不一致`);
  }

  temporaryDirectory = mkdtempSync(join(tmpdir(), "mediaio-release-"));
  const releaseManifestPath = join(temporaryDirectory, "release-manifest.json");
  const releaseManifest = {
    schema_version: 1,
    release_version: releaseVersion,
    github_tag: githubTag,
    cli: {
      commit: cliCommit,
      package: packageName,
      tarball_name: basename(cliTarball),
      tarball_sha256: sha256(cliTarball),
    },
    bin: {
      commit: binBuild.bin_commit,
      go_version: binBuild.go_version,
    },
    assets: archiveNames.map((name) => ({ name, sha256: checksums.get(name) })),
  };
  writeFileSync(releaseManifestPath, `${JSON.stringify(releaseManifest, null, 2)}\n`);

  console.log(`[publish] release: ${releaseVersion}`);
  console.log(`[publish] CLI commit: ${cliCommit}`);
  console.log(`[publish] BIN commit: ${binBuild.bin_commit}`);

  // 源码镜像仅允许 fast-forward，禁止对公开仓库执行 force push。
  const gitAuth = createGitAskPass(githubToken);
  askPassDirectory = gitAuth.directory;
  const remoteName = "github-publish";
  const remoteUrl = `https://github.com/${githubRepository}.git`;
  if (tryRun("git", ["remote", "get-url", remoteName], { env: gitAuth.env }).ok) {
    run("git", ["remote", "set-url", remoteName, remoteUrl], { env: gitAuth.env });
  } else {
    run("git", ["remote", "add", remoteName, remoteUrl], { env: gitAuth.env });
  }
  run("git", ["fetch", "--no-tags", remoteName, githubBranch], { env: gitAuth.env });
  if (!tryRun("git", ["merge-base", "--is-ancestor", `${remoteName}/${githubBranch}`, cliCommit], { env: gitAuth.env }).ok) {
    fail(`GitHub ${githubBranch} 不是当前 CLI 提交的祖先；请先人工完成镜像基线对齐，不能 force push`);
  }
  run("git", ["push", remoteName, `${cliCommit}:refs/heads/${githubBranch}`], { env: gitAuth.env });

  const dereferencedTag = run("git", ["ls-remote", remoteName, `refs/tags/${githubTag}^{}`], { env: gitAuth.env });
  const lightweightTag = run("git", ["ls-remote", remoteName, `refs/tags/${githubTag}`], { env: gitAuth.env });
  const existingTagCommit = (dereferencedTag || lightweightTag).split(/\s+/)[0];
  if (existingTagCommit) {
    if (existingTagCommit !== cliCommit) {
      fail(`GitHub tag ${githubTag} 已存在但未指向当前 CLI 提交`);
    }
  } else {
    run("git", ["tag", "-a", githubTag, cliCommit, "-m", `Release ${githubTag}`], { env: gitAuth.env });
    run("git", ["push", remoteName, `refs/tags/${githubTag}`], { env: gitAuth.env });
  }

  const apiBase = `https://api.github.com/repos/${githubRepository}`;
  let release = await githubRequest(`${apiBase}/releases/tags/${encodeURIComponent(githubTag)}`, githubToken, { allowNotFound: true });
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
  }

  const uploadFiles = [
    ...archiveNames.map((name) => join(binArtifactDirectory, name)),
    checksumsPath,
    releaseManifestPath,
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

  release = await githubRequest(`${apiBase}/releases/${release.id}`, githubToken);
  const uploadedNames = new Set(release.assets.map((asset) => asset.name));
  for (const file of uploadFiles) {
    if (!uploadedNames.has(basename(file))) fail(`GitHub Release 缺少已上传资产：${basename(file)}`);
  }
  if (release.draft) {
    release = await githubRequest(`${apiBase}/releases/${release.id}`, githubToken, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ draft: false }),
    });
  }
  if (release.draft) fail("GitHub Release 未成功公开，禁止继续 npm 发布");

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

  console.log(`[publish] completed: ${packageName}@${releaseVersion}`);
} finally {
  if (temporaryDirectory) rmSync(temporaryDirectory, { recursive: true, force: true });
  if (askPassDirectory) rmSync(askPassDirectory, { recursive: true, force: true });
}

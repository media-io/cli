import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { createNpmArchive, packagePipelineArtifact, verifyNpmArchive } from "./package-pipeline-artifact.mjs";

function withPackage(run) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "mediaio-npm-artifact-test-")));
  const directory = join(root, "package");
  mkdirSync(join(directory, "bin"), { recursive: true });
  writeFileSync(join(directory, "package.json"), JSON.stringify({ name: "@mediaio/cli", version: "0.5.1", scripts: { postinstall: "exit 96" } }));
  for (const filename of ["install.js", "README.md", "LICENSE", "bin/mediaio.js"]) writeFileSync(join(directory, filename), "public fixture");
  execFileSync("git", ["init", "--quiet"], { cwd: directory });
  execFileSync("git", ["add", "package.json", "install.js", "README.md", "LICENSE", "bin"], { cwd: directory });
  function archive() {
    const filename = join(root, "package.tgz");
    execFileSync("tar", ["--exclude=package/.git", "-czf", filename, "-C", root, "package"]);
    const content = readFileSync(filename);
    return { content, integrity: `sha512-${createHash("sha512").update(content).digest("base64")}` };
  }
  return Promise.resolve().then(() => run({ root, directory, archive })).finally(() => rmSync(root, { recursive: true, force: true }));
}

test("验证已发布npm包，不执行postinstall，拒绝integrity与版本不符", () => withPackage(({ archive }) => {
  const { content, integrity } = archive();
  assert.ok(verifyNpmArchive(content, "0.5.1", integrity).includes("package/bin/mediaio.js"));
  assert.throws(() => verifyNpmArchive(content, "0.5.1", "sha512-invalid"), /integrity/);
  assert.throws(() => verifyNpmArchive(content, "0.5.2", integrity), /version/);
}));

test("CLI/BIN清单保留旧字段且npm依赖GitHubRelease，不归档BIN源码", () => withPackage(({ root, directory }) => {
  execFileSync("git", ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture"], { cwd: directory });
  const binaryDirectory = join(root, "binary-assets");
  const output = join(root, "archive");
  mkdirSync(binaryDirectory);
  const assets = ["darwin_amd64", "darwin_arm64", "linux_amd64", "linux_arm64", "windows_amd64", "windows_arm64"].map(target => {
    const name = `mediaio_0.5.1_${target}.tar.gz`;
    writeFileSync(join(binaryDirectory, name), `binary fixture ${target}`);
    return { name, sha256: createHash("sha256").update(readFileSync(join(binaryDirectory, name))).digest("hex") };
  });
  writeFileSync(join(binaryDirectory, "checksums.txt"), assets.map(asset => `${asset.sha256}  ${asset.name}\n`).join(""));
  writeFileSync(join(binaryDirectory, "bin-build.json"), JSON.stringify({ release_version: "0.5.1", bin_commit: "b".repeat(40), build_number: "123", built_at: "2026-10-15T00:00:00Z", go_version: "fixture", assets }));
  writeFileSync(join(binaryDirectory, "main.go"), "must not be archived");
  const values = { RELEASE_VERSION: "0.5.1", BK_CI_BUILD_NUM: "123", RELEASE_DIST_TAG: "latest", RELEASE_WITH_CI_SUFFIX: "false", BIN_ARTIFACT_DIR: binaryDirectory, ARTIFACT_ARCHIVE_PATH: "./fixture/123" };
  const previous = Object.fromEntries(Object.keys(values).map(name => [name, process.env[name]]));
  Object.assign(process.env, values);
  try {
    const result = packagePipelineArtifact(output, directory);
    const manifest = JSON.parse(readFileSync(join(output, "release-manifest.json"), "utf8"));
    assert.equal(manifest.release_version, "0.5.1");
    assert.equal(manifest.cli.package, "@mediaio/cli");
    assert.equal(manifest.bin.commit, "b".repeat(40));
    assert.equal(manifest.assets.length, 6);
    assert.equal(manifest.units[1].channel, "npm");
    assert.deepEqual(manifest.units[1].depends_on, ["github-release"]);
    assert.equal(manifest.units[1].files[0].name, "mediaio-cli-0.5.1.tgz");
    assert.ok(result.file.endsWith(manifest.units[1].files[0].name));
    const members = execFileSync("tar", ["-tzf", result.archiveFile], { encoding: "utf8" }).trim().split("\n");
    assert.ok(members.includes("release-manifest.json"));
    assert.ok(members.includes("cli-build.json"));
    assert.ok(members.includes("mediaio-cli-0.5.1.tgz"));
    assert.equal(members.length, 11);
    assert.ok(!members.some(name => name.includes("main.go")));
    assert.throws(() => readFileSync(join(output, "main.go")), /ENOENT/);
    mkdirSync(join(directory, "deploy"));
    cpSync(new URL("./package-pipeline-artifact.mjs", import.meta.url), join(directory, "deploy/package-pipeline-artifact.mjs"));
    const workspace = join(root, "pipeline workspace");
    mkdirSync(workspace);
    const pipelineEnv = { ...process.env, WORKSPACE: workspace, MODULE_NAME: "media-plugin-cli-public", ARTIFACT_ARCHIVE_PATH: "ignored" };
    const pipelineFiles = [];
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const pipeline = spawnSync(process.execPath, [join(directory, "deploy/package-pipeline-artifact.mjs"), "--pipeline"], {
        cwd: root, env: pipelineEnv, encoding: "utf8",
      });
      assert.equal(pipeline.status, 0, pipeline.stderr);
      assert.equal(pipeline.stderr, "");
      const filename = pipeline.stdout.trim();
      assert.equal(pipeline.stdout, `${filename}\n`);
      assert.ok(!filename.startsWith("/") && !filename.includes("..") && !filename.includes("\n"));
      assert.ok(filename.endsWith("/mediaio-cli-archive_0.5.1_123.tar.gz"));
      assert.ok(!pipelineFiles.includes(filename));
      const pipelineManifest = JSON.parse(execFileSync("tar", ["-xOzf", join(workspace, filename), "release-manifest.json"], { encoding: "utf8" }));
      assert.equal(pipelineManifest.archive_path, "./media-plugin-cli-public/123/plugin-cli-npm");
      assert.equal(pipelineManifest.assets.length, 6);
      assert.equal(pipelineManifest.units[1].files[0].name, "mediaio-cli-0.5.1.tgz");
      pipelineFiles.push(filename);
    }
    for (const filename of pipelineFiles) assert.ok(existsSync(join(workspace, filename)));
    for (const invalidEnv of [
      { WORKSPACE: "" }, { MODULE_NAME: "../escape" }, { BK_CI_BUILD_NUM: "../escape" }, { WORKSPACE: directory }, { BIN_ARTIFACT_DIR: "" },
    ]) {
      const invalid = spawnSync(process.execPath, [join(directory, "deploy/package-pipeline-artifact.mjs"), "--pipeline"], {
        cwd: root, env: { ...pipelineEnv, ...invalidEnv }, encoding: "utf8",
      });
      assert.notEqual(invalid.status, 0);
      assert.equal(invalid.stdout, "");
    }
  } finally {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
}));

test("npm归档拒绝非白名单、链接和正文凭据，错误不含原值", () => withPackage(({ directory, archive }) => {
  writeFileSync(join(directory, ".npmrc"), "fixture");
  let packed = archive();
  assert.throws(() => verifyNpmArchive(packed.content, "0.5.1", packed.integrity), /allowlist/);
  rmSync(join(directory, ".npmrc"));
  writeFileSync(join(directory, "bin/internal.tech.md"), "internal fixture");
  packed = archive();
  assert.throws(() => verifyNpmArchive(packed.content, "0.5.1", packed.integrity), /Sensitive/);
  rmSync(join(directory, "bin/internal.tech.md"));
  symlinkSync("../README.md", join(directory, "bin/link.js"));
  packed = archive();
  assert.throws(() => verifyNpmArchive(packed.content, "0.5.1", packed.integrity), /link/);
  rmSync(join(directory, "bin/link.js"));
  const secret = "ghp_" + "x".repeat(36);
  writeFileSync(join(directory, "README.md"), secret);
  packed = archive();
  assert.throws(() => verifyNpmArchive(packed.content, "0.5.1", packed.integrity), error => error.message.includes("credential") && !error.message.includes(secret));
}));

test("真实npm pack离线生成CI版本、不执行生命周期且不改源码", () => withPackage(({ root, directory }) => {
  const output = join(root, "output");
  mkdirSync(output);
  const original = readFileSync(join(directory, "package.json"), "utf8");
  const result = createNpmArchive(directory, "0.5.1-ci.123", output);
  assert.equal(result.filename, "mediaio-cli-0.5.1-ci.123.tgz");
  assert.ok(result.files.includes("package/bin/mediaio.js"));
  assert.equal(readFileSync(join(directory, "package.json"), "utf8"), original);
  assert.throws(() => createNpmArchive(directory, "9.0.0", output), /version/);
  writeFileSync(join(directory, "bin/untracked.js"), "fixture");
  assert.throws(() => createNpmArchive(directory, "0.5.1", output), /Untracked/);
}));

test("npm prepare等打包钩子提前拒绝，不依赖ignore-scripts的版本差异", () => withPackage(({ root, directory }) => {
  const output = join(root, "output");
  mkdirSync(output);
  for (const name of ["prepare", "prepack", "postpack"]) {
    writeFileSync(join(directory, "package.json"), JSON.stringify({ name: "@mediaio/cli", version: "0.5.1", scripts: { [name]: "exit 99" } }));
    assert.throws(() => createNpmArchive(directory, "0.5.1", output), /lifecycle hooks require review/);
  }
}));
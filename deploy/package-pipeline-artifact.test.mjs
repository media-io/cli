import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { runInNewContext } from "node:vm";

import { createNpmArchive, packagePipelineArtifact, verifyNpmArchive } from "./package-pipeline-artifact.mjs";

test("发布版本校验使用dev后缀并保留渠道与正式版本规则", () => {
  const source = readFileSync(new URL("./publish-release.mjs", import.meta.url), "utf8");
  const start = source.indexOf("function fail(message)");
  const end = source.indexOf("// GitHub Release 页面的", start);
  assert.ok(start >= 0 && end > start);
  const selection = runInNewContext(`${source.slice(start, end)}\nassertReleaseSelection;`);
  for (const channel of ["next", "latest"]) {
    selection("0.5.1", "0.5.1-dev.160", channel, true);
    selection("0.5.1", "0.5.1", channel, false);
    for (const version of ["0.5.1-ci.160", "0.5.1-dev.0", "0.5.1-dev.0160", "0.5.0-dev.160", "0.5.1"]) {
      assert.throws(() => selection("0.5.1", version, channel, true), /RELEASE_VERSION/);
    }
    assert.throws(() => selection("0.5.1", "0.5.1-dev.160", channel, false), /RELEASE_VERSION/);
  }
  assert.throws(() => selection("0.5.1", "0.5.1-dev.160", "unknown", true), /RELEASE_DIST_TAG/);
});

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

test("CLI npm独立归档不读取BIN，不关联GitHubRelease且保留真实npm校验", () => withPackage(({ root, directory }) => {
  execFileSync("git", ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture"], { cwd: directory });
  const binaryDirectory = join(root, "binary-assets");
  const output = join(root, "archive");
  mkdirSync(binaryDirectory);
  writeFileSync(join(binaryDirectory, "checksums.txt"), "invalid old BIN checksums");
  writeFileSync(join(binaryDirectory, "bin-build.json"), JSON.stringify({ release_version: "0.5.0-ci.150", build_number: "150" }));
  writeFileSync(join(binaryDirectory, "main.go"), "must not be archived");
  const values = { RELEASE_VERSION: "0.5.1", BK_CI_BUILD_NUM: "160", RELEASE_DIST_TAG: "latest", RELEASE_WITH_CI_SUFFIX: "false", BIN_ARTIFACT_DIR: "", ARTIFACT_ARCHIVE_PATH: "./fixture/160" };
  const previous = Object.fromEntries(Object.keys(values).map(name => [name, process.env[name]]));
  Object.assign(process.env, values);
  try {
    const result = packagePipelineArtifact(output, directory);
    const manifest = JSON.parse(readFileSync(join(output, "release-manifest.json"), "utf8"));
    assert.equal(manifest.release_version, "0.5.1");
    assert.equal(manifest.cli.package, "@mediaio/cli");
    for (const field of ["bin", "assets", "github_tag"]) assert.equal(Object.hasOwn(manifest, field), false);
    assert.ok(Number.isFinite(Date.parse(manifest.built_at)));
    assert.equal(manifest.units.length, 1);
    assert.equal(manifest.units[0].channel, "npm");
    assert.deepEqual(manifest.units[0].depends_on, []);
    assert.equal(manifest.units[0].files[0].name, "mediaio-cli-0.5.1.tgz");
    assert.ok(result.file.endsWith(manifest.units[0].files[0].name));
    const members = execFileSync("tar", ["-tzf", result.archiveFile], { encoding: "utf8" }).trim().split("\n");
    assert.deepEqual(members.sort(), ["mediaio-cli-0.5.1.tgz", "cli-build.json", "release-manifest.json", "artifact-checksums.txt"].sort());
    const metadata = JSON.parse(readFileSync(join(output, "cli-build.json"), "utf8"));
    assert.ok(verifyNpmArchive(readFileSync(result.file), "0.5.1", metadata.pack_integrity).includes("package/bin/mediaio.js"));
    for (const line of readFileSync(join(output, "artifact-checksums.txt"), "utf8").trim().split("\n")) {
      const [, expected, name] = /^([a-f0-9]{64})  (.+)$/.exec(line);
      assert.equal(createHash("sha256").update(readFileSync(join(output, name))).digest("hex"), expected);
    }
    assert.throws(() => readFileSync(join(output, "main.go")), /ENOENT/);
    mkdirSync(join(directory, "deploy"));
    cpSync(new URL("./package-pipeline-artifact.mjs", import.meta.url), join(directory, "deploy/package-pipeline-artifact.mjs"));
    const workspace = join(root, "pipeline workspace");
    mkdirSync(workspace);
    const pipelineEnv = { ...process.env, WORKSPACE: workspace, MODULE_NAME: "media-plugin-cli-public", ARTIFACT_ARCHIVE_PATH: "ignored" };
    const pipelineFiles = [];
    for (const binaryInput of ["", binaryDirectory, join(root, "missing-binary-assets")]) {
      const pipeline = spawnSync(process.execPath, [join(directory, "deploy/package-pipeline-artifact.mjs"), "--pipeline"], {
        cwd: root, env: { ...pipelineEnv, BIN_ARTIFACT_DIR: binaryInput }, encoding: "utf8",
      });
      assert.equal(pipeline.status, 0, pipeline.stderr);
      assert.equal(pipeline.stderr, "");
      const filename = pipeline.stdout.trim();
      assert.equal(pipeline.stdout, `${filename}\n`);
      assert.ok(!filename.startsWith("/") && !filename.includes("..") && !filename.includes("\n"));
      assert.ok(filename.endsWith("/mediaio-cli-archive_0.5.1_160.tar.gz"));
      assert.ok(!pipelineFiles.includes(filename));
      const pipelineManifest = JSON.parse(execFileSync("tar", ["-xOzf", join(workspace, filename), "release-manifest.json"], { encoding: "utf8" }));
      assert.equal(pipelineManifest.archive_path, "./media-plugin-cli-public/160/plugin-cli-npm");
      assert.equal(Object.hasOwn(pipelineManifest, "bin"), false);
      assert.equal(pipelineManifest.units.length, 1);
      assert.equal(pipelineManifest.units[0].files[0].name, "mediaio-cli-0.5.1.tgz");
      pipelineFiles.push(filename);
    }
    for (const filename of pipelineFiles) assert.ok(existsSync(join(workspace, filename)));
    const ci = spawnSync(process.execPath, [join(directory, "deploy/package-pipeline-artifact.mjs"), "--pipeline"], {
      cwd: root, env: { ...pipelineEnv, RELEASE_VERSION: "0.5.1-dev.160", RELEASE_WITH_CI_SUFFIX: "true", BIN_ARTIFACT_DIR: binaryDirectory }, encoding: "utf8",
    });
    assert.equal(ci.status, 0, ci.stderr);
    assert.ok(ci.stdout.trim().endsWith("/mediaio-cli-archive_0.5.1-dev.160_160.tar.gz"));
    const ciManifest = JSON.parse(execFileSync("tar", ["-xOzf", join(workspace, ci.stdout.trim()), "release-manifest.json"], { encoding: "utf8" }));
    assert.equal(ciManifest.release_version, "0.5.1-dev.160");
    assert.equal(ciManifest.release_with_ci_suffix, true);
    assert.deepEqual(ciManifest.units[0].depends_on, []);
    for (const invalidEnv of [
      { WORKSPACE: "" }, { MODULE_NAME: "../escape" }, { BK_CI_BUILD_NUM: "../escape" }, { WORKSPACE: directory },
      { RELEASE_VERSION: "0.5.1-dev.150", RELEASE_WITH_CI_SUFFIX: "true" },
      { RELEASE_VERSION: "0.5.1-ci.160", RELEASE_WITH_CI_SUFFIX: "true" },
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
  const result = createNpmArchive(directory, "0.5.1-dev.123", output);
  assert.equal(result.filename, "mediaio-cli-0.5.1-dev.123.tgz");
  assert.ok(result.files.includes("package/bin/mediaio.js"));
  assert.equal(readFileSync(join(directory, "package.json"), "utf8"), original);
  assert.throws(() => createNpmArchive(directory, "0.5.1-ci.123", output), /version/);
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
#!/usr/bin/env node

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { constants, copyFileSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, relative, resolve, sep } from "node:path";

const packageRoot = resolve(new URL("..", import.meta.url).pathname);
const packageName = "@mediaio/cli";
const maximumArchiveBytes = 32 * 1024 * 1024;

function assertVersion(version) {
  if (!/^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$/.test(version ?? "")) {
    throw new Error("RELEASE_VERSION must be an exact release version.");
  }
}

function checkContent(directory) {
  for (const name of readdirSync(directory)) {
    const filepath = join(directory, name);
    const entry = lstatSync(filepath);
    if (entry.isSymbolicLink()) throw new Error("Symbolic links are not allowed in npm artifacts.");
    if (name.startsWith(".") || /^(?:credentials(?:\.[^.]+)?|id_rsa|id_ed25519)$/i.test(name)
      || /(?:\.tech\.md|\.(?:pem|key|p12|pfx|sqlite3?|db))$/i.test(name)) throw new Error("Sensitive file name in npm artifact; content withheld.");
    if (entry.isDirectory()) checkContent(filepath);
    else {
      if (!entry.isFile() || entry.size > maximumArchiveBytes) throw new Error("Unsupported npm artifact entry.");
      const text = readFileSync(filepath, "utf8");
      if (/-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----|\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})\b/.test(text)
        || /["']?(?:app_secret|client_secret|access_token|refresh_token|api_key|password|_authToken)["']?\s*[:=]\s*["'][A-Za-z0-9+\/_=.-]{16,}["']/i.test(text)
        || /[?&](?:access_token|api_key)=[A-Za-z0-9_-]{20,}/i.test(text)) {
        throw new Error("Potential credential in npm artifact; content withheld.");
      }
    }
  }
}

export function verifyNpmArchive(archive, version, integrity) {
  assertVersion(version);
  if (!Buffer.isBuffer(archive) || archive.length > maximumArchiveBytes) throw new Error("Npm archive exceeds the size limit.");
  const observed = `sha512-${createHash("sha512").update(archive).digest("base64")}`;
  if (integrity !== observed) throw new Error("Npm pack integrity does not match the archive.");
  const work = mkdtempSync(join(tmpdir(), "mediaio-npm-verify-"));
  try {
    const tarball = join(work, "package.tgz");
    writeFileSync(tarball, archive);
    const members = execFileSync("tar", ["-tzf", tarball], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim().split("\n");
    if (new Set(members).size !== members.length) throw new Error("Duplicate npm archive entries are not allowed.");
    for (const member of members) {
      const parts = member.replace(/\/$/, "").split("/");
      if (/[\\\x00-\x1f\x7f]/.test(member) || parts.some(part => !part || part === "." || part === "..")) throw new Error("Unsafe npm archive path.");
      if (member !== "package/" && !/^package\/(?:package\.json|install\.js|LICENSE|README\.md|bin(?:\/[A-Za-z0-9_.-]+)*\/?)$/.test(member)) {
        throw new Error("Npm archive contains a path outside the package allowlist.");
      }
    }
    const listing = execFileSync("tar", ["-tvzf", tarball], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    if (listing.trim().split("\n").some(line => !["-", "d"].includes(line[0]))) throw new Error("Npm archive contains a link or special entry.");
    const extracted = join(work, "extracted");
    mkdirSync(join(extracted, "package"), { recursive: true });
    let unpackedBytes = 0;
    for (const member of members.filter(name => !name.endsWith("/"))) {
      const content = execFileSync("tar", ["-xOzf", tarball, member], { maxBuffer: maximumArchiveBytes, stdio: ["ignore", "pipe", "pipe"] });
      unpackedBytes += content.length;
      if (unpackedBytes > maximumArchiveBytes) throw new Error("Unpacked npm archive exceeds the size limit.");
      const target = join(extracted, member);
      mkdirSync(resolve(target, ".."), { recursive: true });
      writeFileSync(target, content);
    }
    checkContent(extracted);
    const pkg = JSON.parse(readFileSync(join(extracted, "package/package.json"), "utf8"));
    if (pkg.name !== packageName || pkg.version !== version) throw new Error("Archived npm package name or version is incorrect.");
    for (const required of ["package.json", "install.js", "LICENSE", "README.md", "bin/mediaio.js"]) {
      if (!lstatSync(join(extracted, "package", required)).isFile()) throw new Error("Required npm package file is missing.");
    }
    return members.filter(member => !member.endsWith("/")).sort();
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

export function createNpmArchive(sourceDirectory, version, outputDirectory) {
  assertVersion(version);
  const sourcePackage = JSON.parse(readFileSync(join(sourceDirectory, "package.json"), "utf8"));
  if (["prepare", "prepack", "postpack"].some(name => Object.hasOwn(sourcePackage.scripts ?? {}, name))) {
    throw new Error("Package build lifecycle hooks require review before safe artifact packing.");
  }
  if (sourcePackage.name !== packageName || (version !== sourcePackage.version && !version.startsWith(`${sourcePackage.version}-ci.`))) {
    throw new Error("Npm artifact version must match the CLI source version or its CI suffix.");
  }
  const work = mkdtempSync(join(tmpdir(), "mediaio-npm-pack-"));
  try {
    const staging = join(work, "package");
    mkdirSync(staging);
    const tracked = new Set(execFileSync("git", ["ls-files", "-z"], { cwd: sourceDirectory, encoding: "utf8" }).split("\0").filter(Boolean));
    function inspect(filepath) {
      const entry = lstatSync(filepath);
      if (entry.isSymbolicLink()) throw new Error("Symbolic links are not allowed in npm input.");
      if (entry.isDirectory()) {
        for (const name of readdirSync(filepath)) inspect(join(filepath, name));
      } else if (!entry.isFile() || !tracked.has(relative(sourceDirectory, filepath).split(sep).join("/"))) {
        throw new Error("Untracked or ignored file is not allowed in npm input.");
      }
    }
    for (const entry of ["package.json", "bin", "install.js", "LICENSE", "README.md"]) {
      const original = join(sourceDirectory, entry);
      inspect(original);
      cpSync(original, join(staging, entry), { recursive: true });
    }
    checkContent(staging);
    sourcePackage.version = version;
    sourcePackage.files = ["bin/", "install.js", "LICENSE", "README.md"];
    writeFileSync(join(staging, "package.json"), `${JSON.stringify(sourcePackage, null, 2)}\n`);
    const npmrc = join(work, "empty.npmrc");
    const globalNpmrc = join(work, "global.npmrc");
    writeFileSync(npmrc, "");
    writeFileSync(globalNpmrc, "");
    const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !/TOKEN|SECRET|PASSWORD|^NPM_CONFIG_/i.test(name)));
    Object.assign(env, { NPM_CONFIG_USERCONFIG: npmrc, NPM_CONFIG_GLOBALCONFIG: globalNpmrc, NPM_CONFIG_CACHE: join(work, "cache"), NPM_CONFIG_OFFLINE: "true", NPM_CONFIG_IGNORE_SCRIPTS: "true" });
    const result = JSON.parse(execFileSync("npm", ["pack", "--json", "--ignore-scripts", "--pack-destination", work], { cwd: staging, env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
    const expectedName = `mediaio-cli-${version}.tgz`;
    if (result.length !== 1 || result[0].filename !== expectedName) throw new Error("Unexpected npm pack result.");
    const archive = readFileSync(join(work, expectedName));
    const files = verifyNpmArchive(archive, version, result[0].integrity);
    copyFileSync(join(work, expectedName), join(outputDirectory, expectedName), constants.COPYFILE_EXCL);
    return { filename: expectedName, files, integrity: result[0].integrity, sha256: createHash("sha256").update(archive).digest("hex") };
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

export function packagePipelineArtifact(outputDirectory, sourceDirectory = packageRoot) {
  const version = process.env.RELEASE_VERSION;
  assertVersion(version);
  const buildNumber = process.env.BK_CI_BUILD_NUM;
  if (!/^[0-9]+$/.test(buildNumber ?? "")) throw new Error("BK_CI_BUILD_NUM must be numeric.");
  const releaseDistTag = process.env.RELEASE_DIST_TAG;
  if (!["latest", "next"].includes(releaseDistTag)) throw new Error("RELEASE_DIST_TAG must be latest or next.");
  const withCiSuffix = process.env.RELEASE_WITH_CI_SUFFIX;
  if (!["true", "false"].includes(withCiSuffix)) throw new Error("RELEASE_WITH_CI_SUFFIX must be true or false.");
  const archivePath = process.env.ARTIFACT_ARCHIVE_PATH;
  if (!archivePath || /[\x00-\x1f]|:\/\/|\.\./.test(archivePath)) throw new Error("ARTIFACT_ARCHIVE_PATH must identify the internal archive directory.");
  const output = resolve(outputDirectory);
  const source = realpathSync(sourceDirectory);
  if (output === source || output.startsWith(`${source}${sep}`) || source.startsWith(`${output}${sep}`)) throw new Error("Artifact output must be outside the source checkout.");
  mkdirSync(output, { recursive: true });
  const physicalOutput = realpathSync(output);
  if (physicalOutput === source || physicalOutput.startsWith(`${source}${sep}`) || source.startsWith(`${physicalOutput}${sep}`)) throw new Error("Artifact output must be outside the source checkout.");
  const target = join(output, `mediaio-cli-${version}.tgz`);
  if (existsSync(target)) throw new Error("Artifact already exists; archive the existing result instead of overwriting it.");
  const work = mkdtempSync(join(tmpdir(), "mediaio-npm-artifact-"));
  try {
    const packed = createNpmArchive(source, version, work);
    const sourceCommit = execFileSync("git", ["rev-parse", "HEAD"], { cwd: source, encoding: "utf8" }).trim();
    const baseVersion = JSON.parse(readFileSync(join(source, "package.json"), "utf8")).version;
    if ((withCiSuffix === "false" && version !== baseVersion) || (withCiSuffix === "true" && version !== `${baseVersion}-ci.${buildNumber}`)) {
      throw new Error("Release version does not match the selected CLI CI suffix policy.");
    }
    const metadata = {
      schema_version: 1, release_version: version, cli_commit: sourceCommit, package_name: packageName,
      tarball_name: packed.filename, tarball_sha256: packed.sha256, build_number: buildNumber,
      pack_integrity: packed.integrity, files: packed.files,
    };
    writeFileSync(join(work, "cli-build.json"), `${JSON.stringify(metadata, null, 2)}\n`);
    const buildMetadataHash = createHash("sha256").update(readFileSync(join(work, "cli-build.json"))).digest("hex");
    const releaseManifest = {
      schema_version: 1, product_line: "MI", plugin_pid: "mediaio-cli",
      base_version: baseVersion, release_version: version, release_dist_tag: releaseDistTag,
      release_with_ci_suffix: withCiSuffix === "true", built_at: new Date().toISOString(),
      source: { repository: "media-plugin-cli", commit: sourceCommit }, archive_path: archivePath,
      cli: { commit: sourceCommit, package: packageName },
      units: [
        { unit: "npm-package", channel: "npm", target: packageName, depends_on: [], unpack: false, files: [{ name: packed.filename, sha256: packed.sha256 }] },
      ],
      support_files: [{ name: "cli-build.json", sha256: buildMetadataHash }],
    };
    writeFileSync(join(work, "release-manifest.json"), `${JSON.stringify(releaseManifest, null, 2)}\n`);
    const releaseManifestHash = createHash("sha256").update(readFileSync(join(work, "release-manifest.json"))).digest("hex");
    const checksumLines = [{ name: packed.filename, sha256: packed.sha256 }, { name: "cli-build.json", sha256: buildMetadataHash }, { name: "release-manifest.json", sha256: releaseManifestHash }];
    writeFileSync(join(work, "artifact-checksums.txt"), checksumLines.map(file => `${file.sha256}  ${file.name}\n`).join(""));
    const names = [packed.filename, "cli-build.json", "release-manifest.json", "artifact-checksums.txt"];
    for (const name of names) {
      if (existsSync(join(output, name))) throw new Error("Artifact metadata already exists; refusing to overwrite.");
    }
    for (const name of names) copyFileSync(join(work, name), join(output, name), constants.COPYFILE_EXCL);
    const transport = join(work, "transport.tar.gz");
    execFileSync("tar", ["-czf", transport, "-C", output, ...names], { stdio: "pipe" });
    const archiveFile = join(output, `mediaio-cli-archive_${version}_${buildNumber}.tar.gz`);
    copyFileSync(transport, archiveFile, constants.COPYFILE_EXCL);
    return { file: target, archiveFile, sha256: packed.sha256, sourceCommit };
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

function packageForPipeline() {
  const { WORKSPACE: workspace, MODULE_NAME: moduleName, BK_CI_BUILD_NUM: buildNumber } = process.env;
  if (!workspace) throw new Error("WORKSPACE is required for pipeline packaging.");
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(moduleName ?? "")) throw new Error("MODULE_NAME must be a safe archive directory name.");
  if (!/^[0-9]+$/.test(buildNumber ?? "")) throw new Error("BK_CI_BUILD_NUM must be numeric.");
  const root = realpathSync(workspace);
  const source = realpathSync(packageRoot);
  const prefix = join(root, `cli-npm-archive-${buildNumber}.`);
  if (prefix === source || prefix.startsWith(`${source}${sep}`) || source.startsWith(`${prefix}${sep}`)) {
    throw new Error("Artifact output must be outside the source checkout.");
  }
  const output = mkdtempSync(prefix);
  process.env.ARTIFACT_ARCHIVE_PATH = `./${moduleName}/${buildNumber}/plugin-cli-npm`;
  return relative(root, packagePipelineArtifact(output).archiveFile);
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(new URL(import.meta.url).pathname)) {
  try {
    if (process.argv.length !== 3) throw new Error("Usage: node deploy/package-pipeline-artifact.mjs <output-directory|--pipeline>");
    if (process.argv[2] === "--pipeline") {
      console.log(packageForPipeline());
    } else {
      const result = await packagePipelineArtifact(process.argv[2]);
      console.log(`[artifact] file: ${result.file}`);
      console.log(`[artifact] archive file: ${result.archiveFile}`);
      console.log(`[artifact] sha256: ${result.sha256}`);
    }
  } catch (error) {
    console.error(`[artifact] ${error.message}`);
    process.exitCode = 1;
  }
}
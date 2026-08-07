#!/usr/bin/env bash
# 校验并打包将发布到 npmjs 的 @mediaio/cli。
# 由公司内部发布流水线调用，不负责 npm publish。

set -Eeuo pipefail
IFS=$'\n\t'

fail() {
  echo "[cli-package] ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

require_command node
require_command npm
require_command git
require_command tar
require_command sha256sum

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${RELEASE_VERSION:?必须设置 RELEASE_VERSION，例如 0.1.0}"
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  fail "RELEASE_VERSION 不是合法的 SemVer：$RELEASE_VERSION"
fi

OUTPUT_DIR="${CLI_RELEASE_OUTPUT_DIR:-$ROOT_DIR/release-out}"
mkdir -p "$OUTPUT_DIR"
if [[ -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  fail "CLI_RELEASE_OUTPUT_DIR 必须为空：$OUTPUT_DIR"
fi

OWN_NPM_CACHE=0
if [[ -z "${NPM_CONFIG_CACHE:-}" ]]; then
  export NPM_CONFIG_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/mediaio-npm-cache.XXXXXX")"
  OWN_NPM_CACHE=1
fi
cleanup() {
  if [[ "$OWN_NPM_CACHE" == "1" ]]; then
    rm -rf "$NPM_CONFIG_CACHE"
  fi
}
trap cleanup EXIT

PACKAGE_NAME="$(node -p 'require("./package.json").name')"
PACKAGE_VERSION="$(node -p 'require("./package.json").version')"

[[ "$PACKAGE_NAME" == "@mediaio/cli" ]] || \
  fail "正式发布包名必须是 @mediaio/cli，当前为：$PACKAGE_NAME"
[[ "$PACKAGE_VERSION" == "$RELEASE_VERSION" ]] || \
  fail "package.json.version ($PACKAGE_VERSION) 必须等于 RELEASE_VERSION ($RELEASE_VERSION)"

node --check install.js
node --check bin/mediaio.js
node --check bin/run.js

echo "[cli-package] Node: $(node --version)"
echo "[cli-package] npm: $(npm --version)"
echo "[cli-package] source commit: $(git rev-parse HEAD)"
echo "[cli-package] package: $PACKAGE_NAME@$PACKAGE_VERSION"

pack_result="$(npm pack --json --pack-destination "$OUTPUT_DIR")"
TARBALL_NAME="$(printf '%s' "$pack_result" | node -e '
let input = "";
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  const result = JSON.parse(input);
  if (!Array.isArray(result) || result.length !== 1 || !result[0].filename) process.exit(1);
  process.stdout.write(result[0].filename);
});
')" || fail "无法解析 npm pack 输出"
TARBALL_PATH="$OUTPUT_DIR/$TARBALL_NAME"
[[ -f "$TARBALL_PATH" ]] || fail "未找到 npm pack 产物：$TARBALL_PATH"

tar -tzf "$TARBALL_PATH" | grep -qx 'package/package.json' || fail "npm tarball 缺少 package/package.json"
tar -tzf "$TARBALL_PATH" | grep -qx 'package/install.js' || fail "npm tarball 缺少 package/install.js"
tar -tzf "$TARBALL_PATH" | grep -qx 'package/bin/mediaio.js' || fail "npm tarball 缺少 package/bin/mediaio.js"
tar -tzf "$TARBALL_PATH" | grep -qx 'package/bin/run.js' || fail "npm tarball 缺少 package/bin/run.js"

CLI_COMMIT="$(git rev-parse HEAD)"
TARBALL_SHA256="$(sha256sum "$TARBALL_PATH" | awk '{print $1}')"
node - "$OUTPUT_DIR/cli-build.json" "$RELEASE_VERSION" "$CLI_COMMIT" "$PACKAGE_NAME" "$TARBALL_NAME" "$TARBALL_SHA256" <<'NODE'
const fs = require("fs");
const [outputPath, releaseVersion, commit, packageName, tarballName, sha256] = process.argv.slice(2);
fs.writeFileSync(outputPath, `${JSON.stringify({
  schema_version: 1,
  release_version: releaseVersion,
  cli_commit: commit,
  package_name: packageName,
  tarball_name: tarballName,
  tarball_sha256: sha256,
}, null, 2)}\n`);
NODE

echo "[cli-package] generated: $TARBALL_NAME, cli-build.json"
echo "[cli-package] output directory: $OUTPUT_DIR"

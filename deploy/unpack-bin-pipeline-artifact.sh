#!/usr/bin/env bash
# 解压同一次内部流水线归档的 BIN 临时构件，并校验发布文件完整性。
# 不拉取 BIN 源码，也不访问 GitHub/npm。

set -Eeuo pipefail
IFS=$'\n\t'

fail() {
  echo "[bin-unpack] ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

for command in tar sha256sum find sort; do
  require_command "$command"
done

: "${WORKSPACE:?必须设置 WORKSPACE}"
: "${RELEASE_VERSION:?必须设置 RELEASE_VERSION，例如 0.1.0}"
: "${BK_CI_BUILD_NUM:?必须设置 BK_CI_BUILD_NUM}"
: "${BIN_PIPELINE_ARTIFACT_DIR:?必须设置 BIN_PIPELINE_ARTIFACT_DIR}"
: "${BIN_ARTIFACT_DIR:?必须设置 BIN_ARTIFACT_DIR}"

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  fail "RELEASE_VERSION 不是合法的 SemVer：$RELEASE_VERSION"
fi

EXPECTED_BUNDLE_NAME="mediaio-bin_${RELEASE_VERSION}_${BK_CI_BUILD_NUM}.tar.gz"
BUNDLE_NAME="${BIN_PIPELINE_ARTIFACT_NAME:-$EXPECTED_BUNDLE_NAME}"
[[ "$BUNDLE_NAME" == "$EXPECTED_BUNDLE_NAME" ]] || \
  fail "BIN_PIPELINE_ARTIFACT_NAME 必须为：$EXPECTED_BUNDLE_NAME"

BUNDLE_PATH="$BIN_PIPELINE_ARTIFACT_DIR/$BUNDLE_NAME"
[[ -f "$BUNDLE_PATH" ]] || fail "找不到已拉取的 BIN 临时构件：$BUNDLE_PATH"

expected_files="$(printf '%s\n' \
  "mediaio_${RELEASE_VERSION}_darwin_amd64.tar.gz" \
  "mediaio_${RELEASE_VERSION}_darwin_arm64.tar.gz" \
  "mediaio_${RELEASE_VERSION}_linux_amd64.tar.gz" \
  "mediaio_${RELEASE_VERSION}_linux_arm64.tar.gz" \
  "mediaio_${RELEASE_VERSION}_windows_amd64.tar.gz" \
  "mediaio_${RELEASE_VERSION}_windows_arm64.tar.gz" \
  "checksums.txt" \
  "bin-build.json" | sort)"
actual_files="$(tar -tzf "$BUNDLE_PATH" | sort)"
[[ "$actual_files" == "$expected_files" ]] || fail "BIN 临时构件内容不是预期的八个发布文件"

mkdir -p "$BIN_ARTIFACT_DIR"
if [[ -n "$(find "$BIN_ARTIFACT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  fail "BIN_ARTIFACT_DIR 必须为空，拒绝混入旧文件：$BIN_ARTIFACT_DIR"
fi

tar -xzf "$BUNDLE_PATH" -C "$BIN_ARTIFACT_DIR"
(
  cd "$BIN_ARTIFACT_DIR"
  sha256sum --check checksums.txt
)

echo "[bin-unpack] bundle: $BUNDLE_PATH"
echo "[bin-unpack] output: $BIN_ARTIFACT_DIR"
echo "[bin-unpack] files:"
find "$BIN_ARTIFACT_DIR" -maxdepth 1 -type f -printf '%f\n' | sort

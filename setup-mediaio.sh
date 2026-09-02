#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step_index=0
failures=()
warnings=()
MediaIoPackageName="${MEDIAIO_NPM_PACKAGE:-@mediaio/cli}"
MediaIoInstallDir="${MEDIAIO_INSTALL_DIR:-$HOME/.local/bin}"
MediaIoNpmRegistry="${MEDIAIO_NPM_REGISTRY:-https://registry.npmjs.org}"
MediaIoReleaseRepo="${MEDIAIO_RELEASE_REPO:-media-io/cli}"
MediaIoReleaseBaseUrl="${MEDIAIO_RELEASE_BASE_URL:-https://github.com/$MediaIoReleaseRepo/releases/download}"
MediaIoReleaseApiUrl="${MEDIAIO_RELEASE_API_URL:-https://api.github.com/repos/$MediaIoReleaseRepo/releases/latest}"
MediaIoVersion="${MEDIAIO_VERSION:-latest}"
MediaIoBinaryUrl="${MEDIAIO_BINARY_URL:-}"
MediaIoChecksumUrl="${MEDIAIO_CHECKSUM_URL:-}"
MediaIoNodeInstallRoot="${MEDIAIO_NODE_INSTALL_DIR:-$HOME/.local/share/mediaio/node}"
MediaIoNodeCurrentDir="$MediaIoNodeInstallRoot/current"
MediaIoNodeBinDir="$MediaIoNodeCurrentDir/bin"
MediaIoNpmBinDir=""
MediaIoNodeReady=0
claude_available=0
codex_available=0
claude_plugin_installed=0
codex_plugin_installed=0
use_personal_marketplace_fallback=0
resolved_codex_marketplace_name=""

write_step() {
  step_index=$((step_index + 1))
  printf '\n[%s] %s\n' "$step_index" "$1"
}

add_failure() {
  failures+=("$1")
  printf '  FAIL: %s\n' "$1"
}

add_warning() {
  warnings+=("$1")
  printf '  WARN: %s\n' "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1
}

invoke_checked_step() {
  local label="$1"
  local action="$2"
  local verify="${3:-}"
  local success_message="${4:-}"
  local status=0

  write_step "$label"

  set +e
  eval "$action"
  status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    add_failure "$label - command failed"
    return 1
  fi

  if [[ -n "$verify" ]]; then
    set +e
    eval "$verify"
    status=$?
    set -e
    if [[ $status -ne 0 ]]; then
      add_failure "$label - verification failed"
      return 1
    fi
  fi

  if [[ -n "$success_message" ]]; then
    printf '  OK: %s\n' "$success_message"
  else
    printf '  OK\n'
  fi
}

invoke_soft_step() {
  local label="$1"
  local action="$2"
  local success_message="${3:-}"
  local status=0

  write_step "$label"

  set +e
  eval "$action"
  status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    add_warning "$label failed."
    return 1
  fi

  if [[ -n "$success_message" ]]; then
    printf '  OK: %s\n' "$success_message"
  else
    printf '  OK\n'
  fi
  return 0
}

invoke_optional_fallback_step() {
  local label="$1"
  local primary="$2"
  local fallback="$3"
  local verify="${4:-}"
  local success_message="${5:-}"
  local status=0

  write_step "$label"

  set +e
  eval "$primary"
  status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    add_warning "$label primary path failed."
    printf '  Trying fallback path...\n'
    set +e
    eval "$fallback"
    status=$?
    set -e
    if [[ $status -ne 0 ]]; then
      add_failure "$label fallback failed"
      return 1
    fi
  fi

  if [[ -n "$verify" ]]; then
    set +e
    eval "$verify"
    status=$?
    set -e
    if [[ $status -ne 0 ]]; then
      add_failure "$label verification failed"
      return 1
    fi
  fi

  if [[ -n "$success_message" ]]; then
    printf '  OK: %s\n' "$success_message"
  else
    printf '  OK\n'
  fi
  return 0
}

check_optional_host() {
  local label="$1"
  local command_name="$2"
  local var_name="$3"

  write_step "$label"
  if require_command "$command_name"; then
    printf '  OK: %s is available\n' "$command_name"
    printf -v "$var_name" '%s' 1
  else
    add_warning "$command_name is not available; skipping dependent steps."
    printf -v "$var_name" '%s' 0
  fi
}

ensure_node_and_npm() {
  if require_command node && require_command npm && require_command npx; then
    MediaIoNodeReady=1
    node -v
    npm -v
    npx --version
    return 0
  fi

  if ! require_command curl || ! require_command tar; then
    MediaIoNodeReady=0
    return 1
  fi

  if install_nodejs_from_official_tarball && require_command node && require_command npm && require_command npx; then
    MediaIoNodeReady=1
    node -v
    npm -v
    npx --version
    return 0
  fi

  MediaIoNodeReady=0
  return 1
}

append_path_export_if_missing() {
  local shell_rc="$1"
  local path_dir="$2"
  local export_line="export PATH=\"$path_dir:\$PATH\""

  [[ -n "$shell_rc" ]] || return 0
  [[ -f "$shell_rc" ]] || touch "$shell_rc"
  grep -Fqx "$export_line" "$shell_rc" 2>/dev/null && return 0
  printf '\n%s\n' "$export_line" >>"$shell_rc"
}

persist_path_dir_in_shells() {
  local path_dir="$1"
  local updated=0
  case ":$PATH:" in
    *":$path_dir:"*) ;;
    *) PATH="$path_dir:$PATH" ;;
  esac

  if [[ -n "${ZSH_VERSION:-}" ]] && [[ -n "${HOME:-}" ]]; then
    append_path_export_if_missing "$HOME/.zshrc" "$path_dir"
    updated=1
  fi

  if [[ -n "${BASH_VERSION:-}" ]] && [[ -n "${HOME:-}" ]]; then
    append_path_export_if_missing "$HOME/.bashrc" "$path_dir"
    append_path_export_if_missing "$HOME/.bash_profile" "$path_dir"
    updated=1
  fi

  if [[ $updated -eq 0 ]] && [[ -n "${HOME:-}" ]]; then
    append_path_export_if_missing "$HOME/.profile" "$path_dir"
  fi
}

persist_mediaio_install_dir_path() {
  persist_path_dir_in_shells "$MediaIoInstallDir"
}

get_npm_global_bin_dir() {
  npm prefix -g
}

persist_npm_global_bin_dir_path() {
  local npm_bin_dir="$1"
  [[ -n "$npm_bin_dir" ]] || return 0
  persist_path_dir_in_shells "$npm_bin_dir"
}

persist_node_bin_dir_path() {
  persist_path_dir_in_shells "$MediaIoNodeBinDir"
}

get_mediaio_arch() {
  local mediaio_arch
  mediaio_arch="${MEDIAIO_ARCH:-}"
  if [[ -n "$mediaio_arch" ]]; then
    mediaio_arch="$(printf '%s' "$mediaio_arch" | tr '[:upper:]' '[:lower:]')"
    case "$mediaio_arch" in
      amd64|arm64) printf '%s\n' "$mediaio_arch"; return 0 ;;
      *) echo "Invalid MEDIAIO_ARCH value '$MEDIAIO_ARCH'. Must be 'amd64' or 'arm64'." >&2; return 1 ;;
    esac
  fi

  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' amd64 ;;
    arm64|aarch64) printf '%s\n' arm64 ;;
    *) echo "Unsupported architecture. Set MEDIAIO_ARCH to 'amd64' or 'arm64'." >&2; return 1 ;;
  esac
}

get_node_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' x64 ;;
    arm64|aarch64) printf '%s\n' arm64 ;;
    *) echo "Unsupported architecture. Set MEDIAIO_ARCH or use a supported macOS CPU." >&2; return 1 ;;
  esac
}

get_node_lts_version() {
  local index_line version
  index_line="$(curl -fsSL https://nodejs.org/dist/index.json | grep '"lts":' | head -n 1 || true)"
  version="$(printf '%s\n' "$index_line" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -n 1)"
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

install_nodejs_from_official_tarball() {
  local node_version node_arch download_url temp_dir archive_path extract_root source_dir
  node_version="$(get_node_lts_version)" || return 1
  node_arch="$(get_node_arch)" || return 1
  download_url="https://nodejs.org/dist/$node_version/node-$node_version-darwin-$node_arch.tar.gz"

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mediaio-node.XXXXXX")"
  archive_path="$temp_dir/node.tar.gz"
  extract_root="$temp_dir/extract"

  printf '  Downloading Node.js from %s\n' "$download_url"
  if ! curl -fsSL "$download_url" -o "$archive_path"; then
    rm -rf "$temp_dir"
    return 1
  fi

  mkdir -p "$extract_root"
  if ! tar -xzf "$archive_path" -C "$extract_root"; then
    rm -rf "$temp_dir"
    return 1
  fi

  source_dir="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$source_dir" ]]; then
    rm -rf "$temp_dir"
    return 1
  fi

  mkdir -p "$MediaIoNodeInstallRoot"
  rm -rf "$MediaIoNodeCurrentDir"
  if ! cp -R "$source_dir" "$MediaIoNodeCurrentDir"; then
    rm -rf "$temp_dir"
    return 1
  fi

  persist_node_bin_dir_path
  rm -rf "$temp_dir"
  printf '  OK: Node.js is installed\n'
}

resolve_mediaio_version_from_github_latest() {
  if [[ "$MediaIoVersion" != latest ]]; then
    printf '%s\n' "$MediaIoVersion"
    return 0
  fi

  local release_json tag_name
  release_json="$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$MediaIoReleaseApiUrl")" || return 1
  tag_name="$(printf '%s\n' "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [[ -z "$tag_name" ]]; then
    return 1
  fi

  MediaIoVersion="${tag_name#v}"
  printf '%s\n' "$MediaIoVersion"
}

get_mediaio_release_tag() {
  if [[ "$MediaIoVersion" == v* ]]; then
    printf '%s\n' "$MediaIoVersion"
  else
    printf 'v%s\n' "$MediaIoVersion"
  fi
}

get_mediaio_archive_name() {
  if [[ -n "${MEDIAIO_ARCHIVE_NAME:-}" ]]; then
    printf '%s\n' "$MEDIAIO_ARCHIVE_NAME"
    return 0
  fi

  printf 'mediaio_%s_darwin_%s.tar.gz\n' "${MediaIoVersion#v}" "$(get_mediaio_arch)"
}

assert_mediaio_checksum_if_available() {
  local asset_path="$1"
  local asset_name="$2"
  local temp_dir="$3"
  local checksum_url="${MediaIoChecksumUrl:-}"

  if [[ -z "$checksum_url" ]]; then
    if [[ -n "$MediaIoBinaryUrl" ]]; then
      add_warning "MEDIAIO_BINARY_URL is set without MEDIAIO_CHECKSUM_URL, so checksum verification is skipped."
      return 0
    fi
    checksum_url="$MediaIoReleaseBaseUrl/$(get_mediaio_release_tag)/checksums.txt"
  fi

  local checksum_path expected_line expected actual
  checksum_path="$temp_dir/checksums.txt"
  if ! curl -fsSL "$checksum_url" -o "$checksum_path"; then
    add_warning "Could not download checksums.txt from $checksum_url, so checksum verification is skipped."
    return 0
  fi

  expected_line="$(grep -E "^[0-9A-Fa-f]{64}[[:space:]]+\*?$asset_name$" "$checksum_path" | head -n 1 || true)"
  if [[ -z "$expected_line" ]]; then
    add_warning "$asset_name is missing from checksums.txt, so checksum verification is skipped."
    return 0
  fi

  expected="${expected_line%% *}"
  actual="$(shasum -a 256 "$asset_path" | awk '{print tolower($1)}')"
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  if [[ "$actual" != "$expected" ]]; then
    echo "SHA256 checksum mismatch for $asset_name. Expected $expected, got $actual." >&2
    return 1
  fi
  printf '  OK: SHA256 checksum verified for %s\n' "$asset_name"
}

install_mediaio_cli_from_release() {
  local release_version archive_name download_url temp_dir asset_name asset_path extract_root source_bin dest_bin staged_bin
  if ! release_version="$(resolve_mediaio_version_from_github_latest)"; then
    return 1
  fi
  MediaIoVersion="$release_version"

  archive_name="$(get_mediaio_archive_name)"
  download_url="$MediaIoBinaryUrl"
  if [[ -z "$download_url" ]]; then
    download_url="$MediaIoReleaseBaseUrl/$(get_mediaio_release_tag)/$archive_name"
  fi

  mkdir -p "$MediaIoInstallDir"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mediaio-install.XXXXXX")"
  asset_name="${download_url##*/}"
  asset_path="$temp_dir/$asset_name"
  extract_root="$temp_dir/extract"

  printf '  Downloading Media.io CLI from %s\n' "$download_url"
  curl -fsSL "$download_url" -o "$asset_path"
  assert_mediaio_checksum_if_available "$asset_path" "$asset_name" "$temp_dir"

  mkdir -p "$extract_root"
  tar -xzf "$asset_path" -C "$extract_root"
  source_bin="$(find "$extract_root" -type f \( -name mediaio -o -name mediaio.exe \) | head -n 1)"
  if [[ -z "$source_bin" ]]; then
    rm -rf "$temp_dir"
    echo "Could not find mediaio binary in $asset_name." >&2
    return 1
  fi

  dest_bin="$MediaIoInstallDir/mediaio"
  staged_bin="$MediaIoInstallDir/.mediaio.tmp-$$"
  cp "$source_bin" "$staged_bin"
  mv -f "$staged_bin" "$dest_bin"
  chmod +x "$dest_bin"
  persist_mediaio_install_dir_path
  rm -rf "$temp_dir"
  printf '  OK: Media.io CLI is installed\n'
}

install_mediaio_cli_from_npm_package() {
  if [[ "$MediaIoNodeReady" -ne 1 ]]; then
    return 1
  fi

  if ! npm install -g "$MediaIoPackageName"; then
    return 1
  fi

  MediaIoNpmBinDir="$(get_npm_global_bin_dir)/bin"
  persist_npm_global_bin_dir_path "$MediaIoNpmBinDir"
  if ! verify_mediaio_cli_available; then
    add_warning "npm install succeeded, but mediaio is not yet on PATH. Persisting the npm global bin directory and continuing."
    persist_npm_global_bin_dir_path "$MediaIoNpmBinDir"
  fi
}

get_mediaio_plugin_source_candidates() {
  local candidates=()
  if [[ -n "${MEDIAIO_PLUGIN_SOURCE:-}" ]]; then
    candidates+=("$MEDIAIO_PLUGIN_SOURCE")
  fi
  candidates+=(
    "$SCRIPT_ROOT/../media-plugin-main"
    "$SCRIPT_ROOT/../plugins/media-io"
    "$HOME/.codex/.tmp/marketplaces/media-io"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate/.codex-plugin/plugin.json" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

get_mediaio_plugin_source_root() {
  get_mediaio_plugin_source_candidates
}

get_mediaio_plugin_version() {
  local manifest_path
  manifest_path="$(get_mediaio_plugin_source_root)/.codex-plugin/plugin.json"
  node -e '
    const fs = require("fs");
    const path = process.argv[1];
    if (!fs.existsSync(path)) process.exit(2);
    const manifest = JSON.parse(fs.readFileSync(path, "utf8"));
    if (!manifest.version) process.exit(3);
    process.stdout.write(String(manifest.version));
  ' "$manifest_path"
}

get_local_mediaio_plugin_root() {
  printf '%s\n' "$HOME/plugins/media-io"
}

get_skill_target_bases() {
  if [[ "$codex_available" -eq 1 ]]; then
    printf '%s\n' "$HOME/.codex/skills"
  fi
  if [[ "$claude_available" -eq 1 ]]; then
    printf '%s\n' "$HOME/.claude/skills"
  fi
}

get_skill_target_agent_args() {
  local agents=()
  if [[ "$codex_available" -eq 1 ]]; then
    agents+=("-a codex")
  fi
  if [[ "$claude_available" -eq 1 ]]; then
    agents+=("-a claude-code")
  fi

  if [[ ${#agents[@]} -eq 0 ]]; then
    return 1
  fi

  printf '%s\n' "${agents[*]}"
}

get_mediaio_skill_source_candidates() {
  local candidates=()
  if [[ -n "${MEDIAIO_SKILL_SOURCE:-}" ]]; then
    candidates+=("$MEDIAIO_SKILL_SOURCE")
  fi
  candidates+=(
    "$SCRIPT_ROOT/../media-plugin-main"
    "$SCRIPT_ROOT/../plugins/media-io"
    "$(get_local_mediaio_plugin_root)"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate/skills/mediaio-generate/SKILL.md" ]] && [[ -f "$candidate/skills/mediaio-install/SKILL.md" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

get_mediaio_skill_source_root() {
  get_mediaio_skill_source_candidates
}

get_personal_marketplace_path() {
  printf '%s\n' "$HOME/.agents/plugins/marketplace.json"
}

get_personal_marketplace_name() {
  local marketplace_path
  marketplace_path="$(get_personal_marketplace_path)"
  if [[ -f "$marketplace_path" ]]; then
    node -e '
      const fs = require("fs");
      const path = process.argv[1];
      try {
        const payload = JSON.parse(fs.readFileSync(path, "utf8"));
        if (payload && payload.name && String(payload.name).trim()) {
          process.stdout.write(String(payload.name));
          process.exit(0);
        }
      } catch {}
      process.exit(1);
    ' "$marketplace_path" && return 0
  fi

  printf '%s\n' personal
}

format_display_name_from_name() {
  local name="$1"
  local part
  local result=()

  IFS='-_' read -r -a parts <<<"$name"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    local first rest
    first="${part:0:1}"
    rest="${part:1}"
    first="$(printf '%s' "$first" | tr '[:lower:]' '[:upper:]')"
    rest="$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')"
    result+=("${first}${rest}")
  done

  if [[ ${#result[@]} -eq 0 ]]; then
    printf '%s\n' Personal
  else
    printf '%s\n' "${result[*]}"
  fi
}

write_json_no_bom() {
  local path="$1"
  local json="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$json" >"$path"
}

initialize_local_mediaio_plugin_root() {
  local source_root source_manifest plugin_root source_full plugin_full
  source_root="$(get_mediaio_plugin_source_root)"
  source_manifest="$source_root/.codex-plugin/plugin.json"
  plugin_root="$(get_local_mediaio_plugin_root)"

  [[ -d "$source_root" ]] || return 1
  [[ -f "$source_manifest" ]] || return 1

  mkdir -p "$plugin_root"
  source_full="$(cd "$source_root" && pwd)"
  plugin_full="$(cd "$plugin_root" && pwd)"
  if [[ "$source_full" != "$plugin_full" ]]; then
    cp -R "$source_root"/. "$plugin_root"/
  fi
  cp "$source_manifest" "$plugin_root/plugin.json"
}

initialize_personal_marketplace_fallback() {
  local marketplace_path marketplace_name display_name plugin_root payload
  marketplace_path="$(get_personal_marketplace_path)"
  marketplace_name="$(get_personal_marketplace_name)"
  display_name="$(format_display_name_from_name "$marketplace_name")"
  plugin_root="$(get_local_mediaio_plugin_root)"

  if [[ -f "$marketplace_path" ]]; then
    payload="$(node -e '
      const fs = require("fs");
      const path = process.argv[1];
      process.stdout.write(fs.readFileSync(path, "utf8"));
    ' "$marketplace_path")"
  else
    payload=""
  fi

  if [[ -z "$payload" ]]; then
    payload=$(cat <<EOF
{"name":"$marketplace_name","interface":{"displayName":"$display_name"},"plugins":[]}
EOF
)
  fi

  payload="$(node -e '
    const payload = JSON.parse(process.argv[1]);
    payload.name = String(payload.name || process.argv[2]).trim() || process.argv[2];
    payload.interface = payload.interface || {};
    payload.interface.displayName = String(payload.interface.displayName || process.argv[3]).trim() || process.argv[3];
    payload.plugins = Array.isArray(payload.plugins) ? payload.plugins.filter((entry) => entry && entry.name !== "media-io") : [];
    payload.plugins.push({
      name: "media-io",
      source: { source: "local", path: "./plugins/media-io" },
      policy: { installation: "AVAILABLE", authentication: "ON_INSTALL" },
      category: "Design"
    });
    process.stdout.write(JSON.stringify(payload));
  ' "$payload" "$marketplace_name" "$display_name")"

  mkdir -p "$(dirname "$marketplace_path")"
  write_json_no_bom "$marketplace_path" "$payload"
  initialize_local_mediaio_plugin_root
  printf '%s\n' "$marketplace_name"
}

get_codex_available_plugin_ids() {
  node -e '
    const { spawnSync } = require("child_process");
    const result = spawnSync("codex", ["plugin", "list", "--json", "--available"], { encoding: "utf8" });
    if (result.status !== 0) process.exit(result.status || 1);
    const parsed = JSON.parse(result.stdout || "{}");
    const ids = Array.isArray(parsed.available) ? parsed.available.map((entry) => entry.pluginId).filter(Boolean) : [];
    process.stdout.write(JSON.stringify(ids));
  '
}

get_claude_marketplace_ids() {
  node -e '
    const { spawnSync } = require("child_process");
    const result = spawnSync("claude", ["plugin", "marketplace", "list", "--json"], { encoding: "utf8" });
    if (result.status !== 0) process.exit(result.status || 1);
    const parsed = JSON.parse(result.stdout || "[]");
    const ids = Array.isArray(parsed) ? parsed.map((entry) => entry.name).filter(Boolean) : [];
    process.stdout.write(JSON.stringify(ids));
  '
}

get_codex_plugin_cache_root() {
  local marketplace_name="$1"
  local version
  version="$(get_mediaio_plugin_version)"
  printf '%s\n' "$HOME/.codex/plugins/cache/$marketplace_name/media-io/$version"
}

get_claude_plugin_cache_root() {
  local version
  version="$(get_mediaio_plugin_version)"
  printf '%s\n' "$HOME/.claude/plugins/cache/media-io/media-io/$version"
}

install_skill_files_from_local_source() {
  local source_root target_base
  source_root="$(get_mediaio_skill_source_root)"
  [[ -d "$source_root/skills/mediaio-generate" ]] || return 1
  [[ -d "$source_root/skills/mediaio-install" ]] || return 1

  while IFS= read -r target_base; do
    [[ -n "$target_base" ]] || continue
    mkdir -p "$target_base"
    rm -rf "$target_base/mediaio-generate" "$target_base/mediaio-install"
    cp -R "$source_root/skills/mediaio-generate" "$target_base/"
    cp -R "$source_root/skills/mediaio-install" "$target_base/"
  done < <(get_skill_target_bases)
}

install_skill_files_from_npx() {
  local agent_args
  agent_args="$(get_skill_target_agent_args)" || return 1
  npx --yes skills add media-io/plugin -g $agent_args --skill '*' -y
}

install_skill_files() {
  if install_skill_files_from_local_source; then
    return 0
  fi

  install_skill_files_from_npx
}

remove_direct_mediaio_skills_if_present() {
  local skill_root
  while IFS= read -r skill_root; do
    [[ -n "$skill_root" ]] || continue
    if [[ -d "$skill_root" ]]; then
      rm -rf "$skill_root"
      printf '  OK: removed duplicate direct skill %s\n' "$skill_root"
    fi
  done < <(
    get_skill_target_bases | while IFS= read -r base; do
      [[ -n "$base" ]] || continue
      printf '%s\n' "$base/mediaio-generate" "$base/mediaio-install"
    done
  )
}

test_skill_directories_absent() {
  local skill_root
  while IFS= read -r skill_root; do
    [[ -n "$skill_root" ]] || continue
    if [[ -d "$skill_root" ]]; then
      return 1
    fi
  done < <(
    get_skill_target_bases | while IFS= read -r base; do
      [[ -n "$base" ]] || continue
      printf '%s\n' "$base/mediaio-generate" "$base/mediaio-install"
    done
  )

  return 0
}

test_skill_directories_present() {
  local skill_root
  while IFS= read -r skill_root; do
    [[ -n "$skill_root" ]] || continue
    if [[ ! -d "$skill_root" ]]; then
      return 1
    fi
  done < <(
    get_skill_target_bases | while IFS= read -r base; do
      [[ -n "$base" ]] || continue
      printf '%s\n' "$base/mediaio-generate" "$base/mediaio-install"
    done
  )

  return 0
}

test_claude_plugin_cache_present() {
  [[ -d "$(get_claude_plugin_cache_root)" ]]
}

test_codex_plugin_cache_present() {
  local cache_root
  for cache_root in \
    "$(get_codex_plugin_cache_root "$(get_personal_marketplace_name)")" \
    "$(get_codex_plugin_cache_root media-io)"
  do
    if [[ -d "$cache_root" ]]; then
      return 0
    fi
  done

  return 1
}

verify_mediaio_cli_available() {
  if command -v mediaio >/dev/null 2>&1; then
    mediaio version >/dev/null 2>&1
    return 0
  fi

  [[ -x "$MediaIoInstallDir/mediaio" ]]
}

printf '%s\n' "Media.io setup script"
printf '%s\n' "This script installs the Media.io plugin, CLI, and skills. The CLI prefers npm and falls back to a release archive; skills prefer direct package/local installers and fall back to npm/npx only when needed."

check_optional_host "Preflight: locate claude" claude claude_available
check_optional_host "Preflight: locate codex" codex codex_available
invoke_optional_fallback_step "Install Media.io CLI" "ensure_node_and_npm && install_mediaio_cli_from_npm_package" "install_mediaio_cli_from_release" "verify_mediaio_cli_available" "Media.io CLI is installed"
invoke_checked_step "Run Media.io doctor" "mediaio doctor" "" "local Media.io checks passed"

if [[ "$claude_available" -eq 1 ]]; then
  invoke_checked_step "Add Media.io marketplace (Claude)" "claude plugin marketplace add media-io/plugin" "" "marketplace is registered"
  invoke_checked_step "Refresh Media.io marketplace (Claude)" "claude plugin marketplace update media-io" "" "marketplace is refreshed"
  invoke_checked_step "Verify Claude marketplace visibility" '
    available_ids="$(get_claude_marketplace_ids)"
    if node -e '"'"'
      const ids = JSON.parse(process.argv[1]);
      if (!ids.includes("media-io")) process.exit(1);
    '"'"' "$available_ids"; then
      printf '"'"'  OK: Claude Code can see media-io in the configured marketplaces\n'"'"'
    else
      add_warning "Claude Code does not surface media-io from the configured marketplaces on this build."
    fi
  ' "" "Marketplace lookup finished"
  invoke_checked_step "Install Claude Code plugin" '
    if ! claude plugin install media-io@media-io -s user -y; then
      return 1
    fi
    if ! [[ -d "$(get_claude_plugin_cache_root)" ]]; then
      return 1
    fi
    claude_plugin_installed=1
  ' "" "Claude Code plugin install completed"
  invoke_checked_step "Verify Claude Code plugin cache" '
    cache_root="$(get_claude_plugin_cache_root)"
    [[ -d "$cache_root" ]]
    raw="$(claude plugin list --json 2>/dev/null || true)"
    if [[ -n "$raw" ]]; then
      if ! node -e '"'"'
        const payload = JSON.parse(process.argv[1]);
        const ids = Array.isArray(payload) ? payload.map((entry) => entry && entry.id).filter(Boolean) : [];
        if (!ids.includes("media-io@media-io")) process.exit(1);
      '"'"' "$raw"; then
        add_warning "Claude Code does not currently list media-io@media-io in the installed plugin list, but the cache root exists."
      else
        printf '"'"'  OK: Claude Code lists media-io@media-io as installed\n'"'"'
      fi
    fi
  ' "" "Claude Code plugin cache is present"
fi

if [[ "$codex_available" -eq 1 ]]; then
  if ! invoke_soft_step "Add Media.io marketplace (Codex)" "codex plugin marketplace add media-io/plugin" "Codex marketplace is registered"; then
    use_personal_marketplace_fallback=1
  fi

  if [[ "$use_personal_marketplace_fallback" -eq 0 ]]; then
    if ! invoke_soft_step "Refresh Media.io marketplace (Codex)" "codex plugin marketplace upgrade media-io" "Codex marketplace is refreshed"; then
      use_personal_marketplace_fallback=1
    fi
  fi

  if [[ "$use_personal_marketplace_fallback" -eq 0 ]]; then
    if ! invoke_soft_step "Verify Codex marketplace visibility" '
      available_ids="$(get_codex_available_plugin_ids)"
      if node -e '"'"'
        const ids = JSON.parse(process.argv[1]);
        if (!ids.includes("media-io@media-io")) process.exit(1);
      '"'"' "$available_ids"; then
        printf '"'"'  OK: Codex can see media-io in the git marketplace snapshot\n'"'"'
      else
        add_warning "Codex does not surface media-io from the git marketplace snapshot on this build."
        return 1
      fi
    ' "Codex marketplace lookup finished"; then
      use_personal_marketplace_fallback=1
    fi
  fi
  invoke_checked_step "Install Codex plugin" '
    installed_marketplace_name="media-io"

    if [[ "$use_personal_marketplace_fallback" -eq 0 ]]; then
      if codex plugin add media-io@media-io; then
        if [[ -d "$(get_codex_plugin_cache_root media-io)" ]]; then
          resolved_codex_marketplace_name="media-io"
        else
          add_warning "The git marketplace install did not leave an installable cache root. Switching to the personal marketplace fallback."
          use_personal_marketplace_fallback=1
        fi
      else
        add_warning "The git marketplace install failed. Switching to the personal marketplace fallback."
        use_personal_marketplace_fallback=1
      fi
    fi

    if [[ "$use_personal_marketplace_fallback" -eq 1 ]]; then
      installed_marketplace_name="$(initialize_personal_marketplace_fallback)"
      codex plugin add "media-io@$installed_marketplace_name"
      if ! [[ -d "$(get_codex_plugin_cache_root "$installed_marketplace_name")" ]]; then
        return 1
      fi
      resolved_codex_marketplace_name="$installed_marketplace_name"
    fi
    codex_plugin_installed=1
  ' "" "Codex plugin install completed"
  invoke_checked_step "Verify Codex plugin cache" '
    [[ -n "$resolved_codex_marketplace_name" ]]
    cache_root="$(get_codex_plugin_cache_root "$resolved_codex_marketplace_name")"
    [[ -d "$cache_root" ]]
    available_ids="$(get_codex_available_plugin_ids)"
    expected_id="media-io@$resolved_codex_marketplace_name"
    if ! node -e '"'"'
      const ids = JSON.parse(process.argv[1]);
      const expected = process.argv[2];
      if (!ids.includes(expected)) process.exit(1);
    '"'"' "$available_ids" "$expected_id"; then
      add_warning "Codex does not currently list $expected_id in the available plugin list, but the cache root exists."
    else
      printf '"'"'  OK: Codex lists %s as available\n'"'"' "$expected_id"
    fi
  ' "" "Codex plugin cache is present"
fi

if [[ "$claude_plugin_installed" -eq 1 || "$codex_plugin_installed" -eq 1 ]]; then
  write_step "Skip direct Media.io skills install"
  remove_direct_mediaio_skills_if_present
  printf '  OK: plugin-provided skills are installed; direct skills install is skipped to avoid duplicate entries\n'
else
  invoke_checked_step "Install Media.io skills" "install_skill_files" "" "skills are installed"
fi

write_step "Final verification"
if verify_mediaio_cli_available; then
  printf '  OK: mediaio version responded\n'
else
  add_failure "Final verification - mediaio version failed"
fi

if [[ "$claude_plugin_installed" -eq 1 || "$codex_plugin_installed" -eq 1 ]]; then
  if [[ "$claude_plugin_installed" -eq 1 ]] && ! test_claude_plugin_cache_present; then
    add_failure "Final verification - Claude Code plugin cache is still missing."
  fi
  if [[ "$codex_plugin_installed" -eq 1 ]] && ! test_codex_plugin_cache_present; then
    add_failure "Final verification - Codex plugin cache is still missing."
  fi
else
  if ! test_skill_directories_present; then
    add_failure "Final verification - Media.io skill directories are still missing."
  fi
fi

if (( ${#failures[@]} > 0 )); then
  printf '\nSetup finished with failures.\n'
  for item in "${failures[@]}"; do
    printf '  - %s\n' "$item"
  done
  if (( ${#warnings[@]} > 0 )); then
    printf '\nWarnings:\n'
    for item in "${warnings[@]}"; do
      printf '  - %s\n' "$item"
    done
  fi
  exit 1
fi

printf '\nSetup finished successfully.\n'
if (( ${#warnings[@]} > 0 )); then
  printf 'Warnings were emitted, but the required files and commands are present.\n'
fi

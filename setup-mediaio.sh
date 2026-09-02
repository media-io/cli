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
MediaIoVersion="${MEDIAIO_VERSION:-latest}"
MediaIoBinaryUrl="${MEDIAIO_BINARY_URL:-}"
MediaIoChecksumUrl="${MEDIAIO_CHECKSUM_URL:-}"
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

run_checked_step() {
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
  if ! require_command node || ! require_command npm || ! require_command npx || ! require_command curl || ! require_command tar; then
    return 1
  fi

  node -v
  npm -v
  npx --version
  curl --version >/dev/null 2>&1
  tar --version >/dev/null 2>&1
}

get_mediaio_arch() {
  if [[ -n "${MEDIAIO_ARCH:-}" ]]; then
    case "${MEDIAIO_ARCH,,}" in
      amd64|arm64) printf '%s\n' "${MEDIAIO_ARCH,,}"; return 0 ;;
      *) echo "Invalid MEDIAIO_ARCH value '$MEDIAIO_ARCH'. Must be 'amd64' or 'arm64'." >&2; return 1 ;;
    esac
  fi

  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' amd64 ;;
    arm64|aarch64) printf '%s\n' arm64 ;;
    *) echo "Unsupported architecture. Set MEDIAIO_ARCH to 'amd64' or 'arm64'." >&2; return 1 ;;
  esac
}

resolve_mediaio_version_from_npm() {
  if [[ "$MediaIoVersion" != latest ]]; then
    printf '%s\n' "$MediaIoVersion"
    return 0
  fi

  local version
  version="$(npm view "$MediaIoPackageName" version --json 2>/dev/null || true)"
  version="${version%$'\n'}"
  version="${version%\"}"
  version="${version#\"}"
  if [[ -z "$version" ]]; then
    return 1
  fi

  MediaIoVersion="$version"
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
  if ! release_version="$(resolve_mediaio_version_from_npm)"; then
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
  rm -rf "$temp_dir"
  printf '  OK: Media.io CLI is installed\n'
}

install_mediaio_cli_from_npm_package() {
  install_mediaio_cli_from_release
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
  printf '%s\n' "$HOME/.codex/skills"
  printf '%s\n' "$HOME/.claude/skills"
  printf '%s\n' "$HOME/.agents/skills"
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
  npx --yes skills add media-io/plugin -g --skill '*' -y
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

printf '%s\n' "Media.io setup script"
printf '%s\n' "This script installs the Media.io plugin, CLI, and skills. CLI and skills prefer direct package/local installers and fall back to npm/npx only when needed."

check_optional_host "Preflight: locate claude" claude claude_available
check_optional_host "Preflight: locate codex" codex codex_available
run_checked_step "Preflight: ensure Node.js and npm" "ensure_node_and_npm" "" "Node.js, npm, and npx are available"
run_checked_step "Install Media.io CLI" "install_mediaio_cli_from_npm_package" "mediaio version" "Media.io CLI is installed"
run_checked_step "Run Media.io doctor" "mediaio doctor" "" "local Media.io checks passed"

if [[ "$claude_available" -eq 1 ]]; then
  run_checked_step "Add Media.io marketplace (Claude)" "claude plugin marketplace add media-io/plugin" "" "marketplace is registered"
  run_checked_step "Refresh Media.io marketplace (Claude)" "claude plugin marketplace update media-io" "" "marketplace is refreshed"
  run_checked_step "Verify Claude marketplace visibility" '
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
  run_checked_step "Install Claude Code plugin" '
    if ! claude plugin install media-io@media-io -s user -y; then
      return 1
    fi
    if ! [[ -d "$(get_claude_plugin_cache_root)" ]]; then
      return 1
    fi
    claude_plugin_installed=1
  ' "" "Claude Code plugin install completed"
  run_checked_step "Verify Claude Code plugin cache" '
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
  run_checked_step "Add Media.io marketplace (Codex)" "codex plugin marketplace add media-io/plugin" "" "marketplace is registered"
  run_checked_step "Refresh Media.io marketplace (Codex)" "codex plugin marketplace upgrade media-io" "" "marketplace is refreshed"
  run_checked_step "Verify Codex marketplace visibility" '
    available_ids="$(get_codex_available_plugin_ids)"
    if node -e '"'"'
      const ids = JSON.parse(process.argv[1]);
      if (!ids.includes("media-io@media-io")) process.exit(1);
    '"'"' "$available_ids"; then
      printf '"'"'  OK: Codex can see media-io in the git marketplace snapshot\n'"'"'
    else
      use_personal_marketplace_fallback=1
      add_warning "Codex does not surface media-io from the git marketplace snapshot on this build. I will fall back to the personal marketplace."
    fi
  ' "" "Marketplace lookup finished"
  run_checked_step "Install Codex plugin" '
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
  run_checked_step "Verify Codex plugin cache" '
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
  run_checked_step "Install Media.io skills" "install_skill_files" "" "skills are installed"
fi

write_step "Final verification"
if mediaio version >/dev/null 2>&1; then
  printf '  OK: mediaio version responded\n'
else
  add_failure "Final verification - mediaio version failed"
fi

if [[ "$claude_plugin_installed" -eq 1 ]]; then
  if ! test_claude_plugin_cache_present; then
    add_failure "Final verification - Claude Code plugin cache is still missing."
  fi
fi

if [[ "$codex_plugin_installed" -eq 1 ]]; then
  if ! test_codex_plugin_cache_present; then
    add_failure "Final verification - Codex plugin cache is still missing."
  fi
fi

if [[ "$claude_plugin_installed" -eq 1 || "$codex_plugin_installed" -eq 1 ]]; then
  if ! test_skill_directories_absent; then
    add_failure "Final verification - duplicate direct skill directories are still present."
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

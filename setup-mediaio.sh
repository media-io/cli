#!/bin/sh
# Media.io setup script for macOS.
# setup-mediaio.sh script version: 0.1.5
# Installs the Media.io plugin, CLI, and skills in one pass.
# CLI prefers npm and falls back to a release archive; direct skills are installed with npx only when plugin install is unavailable.
#
# Usage (from an existing shell session):
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/setup-mediaio.sh | sh
#
# Environment variables (all optional):
#   MEDIAIO_INSTALL_DIR      — where to put the CLI binary       (default: ~/.local/bin)
#   MEDIAIO_VERSION          — version to install                (default: latest)
#   MEDIAIO_NPM_PACKAGE      — npm package name for the CLI      (default: @mediaio/cli)
#   MEDIAIO_NPM_REGISTRY     — npm registry URL                  (default: https://registry.npmjs.org)
#   MEDIAIO_RELEASE_REPO     — GitHub repo for release assets    (default: media-io/cli)
#   MEDIAIO_SKILL_REPO       — GitHub repo for skill source       (default: media-io/plugin)
#   MEDIAIO_SKILL_SOURCE     — local or remote skill source path
#
set -eu

SCRIPT_ROOT=$(CDPATH= cd "$(dirname "$0")" && pwd)

step_index=0
failure_count=0
warning_count=0
failures=
warnings=
SCRIPT_VERSION="0.1.5"
MediaIoPackageName=${MEDIAIO_NPM_PACKAGE:-@mediaio/cli}
MediaIoMarketplaceSource=${MEDIAIO_MARKETPLACE_SOURCE:-media-io/plugin}
MediaIoClaudePluginId=${MEDIAIO_CLAUDE_PLUGIN_ID:-media-io@media-io}
MediaIoCodexPluginName=${MEDIAIO_CODEX_PLUGIN_NAME:-media-io}
MediaIoCodexMarketplaceName=${MEDIAIO_CODEX_MARKETPLACE_NAME:-media-io}
MediaIoInstallDir=${MEDIAIO_INSTALL_DIR:-"$HOME/.local/bin"}
MediaIoNpmRegistry=${MEDIAIO_NPM_REGISTRY:-https://registry.npmjs.org}
MediaIoReleaseRepo=${MEDIAIO_RELEASE_REPO:-media-io/cli}
MediaIoReleaseBaseUrl=${MEDIAIO_RELEASE_BASE_URL:-"https://github.com/$MediaIoReleaseRepo/releases/download"}
MediaIoReleaseApiUrl=${MEDIAIO_RELEASE_API_URL:-"https://api.github.com/repos/$MediaIoReleaseRepo/releases/latest"}
MediaIoVersion=${MEDIAIO_VERSION:-latest}
MediaIoBinaryUrl=${MEDIAIO_BINARY_URL:-}
MediaIoChecksumUrl=${MEDIAIO_CHECKSUM_URL:-}
MediaIoSkillRepo=${MEDIAIO_SKILL_REPO:-media-io/plugin}
MediaIoPluginArchiveUrl=${MEDIAIO_PLUGIN_ARCHIVE_URL:-https://github.com/media-io/plugin/archive/refs/heads/main.zip}
MediaIoNodeInstallRoot=${MEDIAIO_NODE_INSTALL_DIR:-"$HOME/.local/share/mediaio/node"}
MediaIoNodeCurrentDir=$MediaIoNodeInstallRoot/current
MediaIoNodeBinDir=$MediaIoNodeCurrentDir/bin
MediaIoNodeReady=0
claude_available=0
codex_available=0
claude_plugin_installed=0
codex_plugin_installed=0
claude_plugin_ready=0
codex_plugin_ready=0
use_personal_marketplace_fallback=0
personal_marketplace_fallback_reason=
resolved_personal_marketplace_name=
resolved_codex_marketplace_name=

append_line() {
  if [ -z "$1" ]; then
    printf '%s' "$2"
  else
    printf '%s\n%s' "$1" "$2"
  fi
}

write_step() {
  step_index=$((step_index + 1))
  printf '\n[%s] %s\n' "$step_index" "$1"
}

add_failure() {
  failure_count=$((failure_count + 1))
  failures=$(append_line "$failures" "$1")
  printf '  FAIL: %s\n' "$1"
}

add_warning() {
  warning_count=$((warning_count + 1))
  warnings=$(append_line "$warnings" "$1")
  printf '  WARN: %s\n' "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1
}

run_action() {
  set +e
  eval "$1"
  status=$?
  set -e
  return "$status"
}

invoke_checked_step() {
  label=$1
  action=$2
  verify=${3:-}
  success_message=${4:-}

  write_step "$label"
  if ! run_action "$action"; then
    add_failure "$label - command failed"
    return 1
  fi

  if [ -n "$verify" ] && ! run_action "$verify"; then
    add_failure "$label - verification failed"
    return 1
  fi

  if [ -n "$success_message" ]; then
    printf '  OK: %s\n' "$success_message"
  else
    printf '  OK\n'
  fi
}

invoke_soft_step() {
  label=$1
  action=$2
  success_message=${3:-}

  write_step "$label"
  if ! run_action "$action"; then
    add_warning "$label failed."
    return 1
  fi

  if [ -n "$success_message" ]; then
    printf '  OK: %s\n' "$success_message"
  else
    printf '  OK\n'
  fi
}

invoke_optional_fallback_step() {
  label=$1
  primary=$2
  fallback=$3
  verify=${4:-}
  success_message=${5:-}

  write_step "$label"
  if ! run_action "$primary"; then
    add_warning "$label primary path failed."
    printf '  Trying fallback path...\n'
    if ! run_action "$fallback"; then
      add_failure "$label fallback failed"
      return 1
    fi
  fi

  if [ -n "$verify" ] && ! run_action "$verify"; then
    add_failure "$label verification failed"
    return 1
  fi

  if [ -n "$success_message" ]; then
    printf '  OK: %s\n' "$success_message"
  else
    printf '  OK\n'
  fi
}

check_optional_host() {
  label=$1
  command_name=$2
  var_name=$3

  write_step "$label"
  if require_command "$command_name"; then
    printf '  OK: %s is available\n' "$command_name"
    eval "$var_name=1"
  else
    add_warning "$command_name is not available; skipping dependent steps."
    eval "$var_name=0"
  fi
}

append_path_export_if_missing() {
  shell_rc=$1
  path_dir=$2
  export_line="export PATH=\"$path_dir:\$PATH\""

  [ -n "$shell_rc" ] || return 0
  [ -f "$shell_rc" ] || : >"$shell_rc"
  grep -Fqx "$export_line" "$shell_rc" 2>/dev/null && return 0
  printf '\n%s\n' "$export_line" >>"$shell_rc"
}

# Keyed on the user's login shell, not on $ZSH_VERSION/$BASH_VERSION: those
# describe whichever shell interprets this script, so the documented
# "curl ... | sh" usage would always look like bash and never touch .zshrc.
persist_path_dir_in_shells() {
  path_dir=$1
  updated=0

  case ":$PATH:" in
    *":$path_dir:"*) ;;
    *) PATH=$path_dir:$PATH ;;
  esac

  [ -n "${HOME:-}" ] || return 0

  login_shell=${SHELL:-}
  login_shell=${login_shell##*/}

  case "$login_shell" in
    zsh)
      append_path_export_if_missing "$HOME/.zshrc" "$path_dir"
      updated=1
      ;;
    bash)
      append_path_export_if_missing "$HOME/.bashrc" "$path_dir"
      append_path_export_if_missing "$HOME/.bash_profile" "$path_dir"
      updated=1
      ;;
  esac

  # Unknown or unset $SHELL: fall back to the POSIX profile, plus any rc file
  # that already exists, so an interactive shell still picks the directory up.
  if [ "$updated" -eq 0 ]; then
    append_path_export_if_missing "$HOME/.profile" "$path_dir"
    [ ! -f "$HOME/.zshrc" ] || append_path_export_if_missing "$HOME/.zshrc" "$path_dir"
    [ ! -f "$HOME/.bashrc" ] || append_path_export_if_missing "$HOME/.bashrc" "$path_dir"
  fi
}

get_npm_global_bin_dir() {
  npm prefix -g
}

get_mediaio_arch() {
  mediaio_arch=${MEDIAIO_ARCH:-}
  if [ -n "$mediaio_arch" ]; then
    mediaio_arch=$(printf '%s' "$mediaio_arch" | tr '[:upper:]' '[:lower:]')
    case "$mediaio_arch" in
      amd64|arm64) printf '%s\n' "$mediaio_arch"; return 0 ;;
      *) printf "Invalid MEDIAIO_ARCH value '%s'. Must be 'amd64' or 'arm64'.\n" "$MEDIAIO_ARCH" >&2; return 1 ;;
    esac
  fi

  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' amd64 ;;
    arm64|aarch64) printf '%s\n' arm64 ;;
    *) printf '%s\n' "Unsupported architecture. Set MEDIAIO_ARCH to 'amd64' or 'arm64'." >&2; return 1 ;;
  esac
}

get_node_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' x64 ;;
    arm64|aarch64) printf '%s\n' arm64 ;;
    *) printf '%s\n' "Unsupported architecture. Use a supported macOS CPU." >&2; return 1 ;;
  esac
}

get_node_lts_version() {
  index_line=$(curl -fsSL https://nodejs.org/dist/index.json | grep '"lts":' | head -n 1 || true)
  version=$(printf '%s\n' "$index_line" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

install_nodejs_from_official_tarball() {
  node_version=$(get_node_lts_version) || return 1
  node_arch=$(get_node_arch) || return 1
  download_url="https://nodejs.org/dist/$node_version/node-$node_version-darwin-$node_arch.tar.gz"
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/mediaio-node.XXXXXX")
  archive_path=$temp_dir/node.tar.gz
  extract_root=$temp_dir/extract

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

  source_dir=$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  if [ -z "$source_dir" ]; then
    rm -rf "$temp_dir"
    return 1
  fi

  mkdir -p "$MediaIoNodeInstallRoot"
  rm -rf "$MediaIoNodeCurrentDir"
  if ! cp -R "$source_dir" "$MediaIoNodeCurrentDir"; then
    rm -rf "$temp_dir"
    return 1
  fi

  persist_path_dir_in_shells "$MediaIoNodeBinDir"
  rm -rf "$temp_dir"
  printf '  OK: Node.js is installed\n'
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

resolve_mediaio_version_from_github_latest() {
  if [ "$MediaIoVersion" != latest ]; then
    printf '%s\n' "$MediaIoVersion"
    return 0
  fi

  release_json=$(curl -fsSL -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$MediaIoReleaseApiUrl") || return 1
  tag_name=$(printf '%s\n' "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$tag_name" ] || return 1
  MediaIoVersion=${tag_name#v}
  printf '%s\n' "$MediaIoVersion"
}

get_mediaio_release_tag() {
  case "$MediaIoVersion" in
    v*) printf '%s\n' "$MediaIoVersion" ;;
    *) printf 'v%s\n' "$MediaIoVersion" ;;
  esac
}

get_mediaio_archive_name() {
  if [ -n "${MEDIAIO_ARCHIVE_NAME:-}" ]; then
    printf '%s\n' "$MEDIAIO_ARCHIVE_NAME"
    return 0
  fi
  printf 'mediaio_%s_darwin_%s.tar.gz\n' "${MediaIoVersion#v}" "$(get_mediaio_arch)"
}

assert_mediaio_checksum_if_available() {
  asset_path=$1
  asset_name=$2
  temp_dir=$3
  checksum_url=${MediaIoChecksumUrl:-}

  if [ -z "$checksum_url" ]; then
    if [ -n "$MediaIoBinaryUrl" ]; then
      add_warning "MEDIAIO_BINARY_URL is set without MEDIAIO_CHECKSUM_URL, so checksum verification is skipped."
      return 0
    fi
    checksum_url="$MediaIoReleaseBaseUrl/$(get_mediaio_release_tag)/checksums.txt"
  fi

  checksum_path=$temp_dir/checksums.txt
  if ! curl -fsSL "$checksum_url" -o "$checksum_path"; then
    add_warning "Could not download checksums.txt from $checksum_url, so checksum verification is skipped."
    return 0
  fi

  expected_line=$(grep -E "^[0-9A-Fa-f]{64}[[:space:]]+\*?$asset_name$" "$checksum_path" | head -n 1 || true)
  if [ -z "$expected_line" ]; then
    add_warning "$asset_name is missing from checksums.txt, so checksum verification is skipped."
    return 0
  fi

  expected=${expected_line%% *}
  actual=$(shasum -a 256 "$asset_path" | awk '{print tolower($1)}')
  expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
  if [ "$actual" != "$expected" ]; then
    printf 'SHA256 checksum mismatch for %s. Expected %s, got %s.\n' "$asset_name" "$expected" "$actual" >&2
    return 1
  fi
  printf '  OK: SHA256 checksum verified for %s\n' "$asset_name"
}

install_mediaio_cli_from_release() {
  release_version=$(resolve_mediaio_version_from_github_latest) || return 1
  MediaIoVersion=$release_version
  archive_name=$(get_mediaio_archive_name)
  download_url=$MediaIoBinaryUrl
  if [ -z "$download_url" ]; then
    download_url="$MediaIoReleaseBaseUrl/$(get_mediaio_release_tag)/$archive_name"
  fi

  mkdir -p "$MediaIoInstallDir"
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/mediaio-install.XXXXXX")
  asset_name=${download_url##*/}
  asset_path=$temp_dir/$asset_name
  extract_root=$temp_dir/extract

  printf '  Downloading Media.io CLI from %s\n' "$download_url"
  curl -fsSL "$download_url" -o "$asset_path"
  assert_mediaio_checksum_if_available "$asset_path" "$asset_name" "$temp_dir"

  mkdir -p "$extract_root"
  tar -xzf "$asset_path" -C "$extract_root"
  source_bin=$(find "$extract_root" -type f \( -name mediaio -o -name mediaio.exe \) | head -n 1)
  if [ -z "$source_bin" ]; then
    rm -rf "$temp_dir"
    printf 'Could not find mediaio binary in %s.\n' "$asset_name" >&2
    return 1
  fi

  dest_bin=$MediaIoInstallDir/mediaio
  staged_bin=$MediaIoInstallDir/.mediaio.tmp-$$
  cp "$source_bin" "$staged_bin"
  mv -f "$staged_bin" "$dest_bin"
  chmod +x "$dest_bin"
  persist_path_dir_in_shells "$MediaIoInstallDir"
  rm -rf "$temp_dir"
  printf '  OK: Media.io CLI is installed\n'
}

verify_mediaio_cli_available() {
  if command -v mediaio >/dev/null 2>&1; then
    mediaio version >/dev/null 2>&1
    return 0
  fi
  [ -x "$MediaIoInstallDir/mediaio" ]
}

install_mediaio_cli_from_npm_package() {
  [ "$MediaIoNodeReady" -eq 1 ] || return 1
  npm install -g "$MediaIoPackageName" || return 1
  npm_bin_dir=$(get_npm_global_bin_dir)/bin
  persist_path_dir_in_shells "$npm_bin_dir"
  if ! verify_mediaio_cli_available; then
    add_warning "npm install succeeded, but mediaio is not yet on PATH. Persisting the npm global bin directory and continuing."
  fi
}

get_local_mediaio_plugin_root() {
  printf '%s\n' "$HOME/plugins/media-io"
}

get_default_mediaio_skill_names() {
  printf '%s\n' mediaio-generate mediaio-install
}

get_mediaio_plugin_source_root() {
  if [ -n "${MEDIAIO_PLUGIN_SOURCE:-}" ] && [ -f "$MEDIAIO_PLUGIN_SOURCE/.codex-plugin/plugin.json" ]; then
    printf '%s\n' "$MEDIAIO_PLUGIN_SOURCE"
    return 0
  fi
  for candidate in "$SCRIPT_ROOT" "$SCRIPT_ROOT/../media-plugin-main" "$SCRIPT_ROOT/../plugins/media-io" "$HOME/.codex/.tmp/marketplaces/$MediaIoCodexMarketplaceName" "$(get_local_mediaio_plugin_root)"; do
    if [ -f "$candidate/.codex-plugin/plugin.json" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

get_mediaio_skill_source_root() {
  if [ -n "${MEDIAIO_SKILL_SOURCE:-}" ] && [ -d "$MEDIAIO_SKILL_SOURCE" ]; then
    printf '%s\n' "$MEDIAIO_SKILL_SOURCE"
    return 0
  fi
  for candidate in "$SCRIPT_ROOT/skills" "$SCRIPT_ROOT/../media-plugin-main/skills" "$SCRIPT_ROOT/../plugins/media-io/skills" "$(get_local_mediaio_plugin_root)/skills"; do
    if [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

get_mediaio_skill_names() {
  source_root=$(get_mediaio_skill_source_root 2>/dev/null || true)
  if [ -z "$source_root" ] || [ ! -d "$source_root" ]; then
    get_default_mediaio_skill_names
    return 0
  fi
  skill_names=$(find "$source_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while IFS= read -r skill_dir; do
    [ -n "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] && basename "$skill_dir"
  done)
  if [ -n "$skill_names" ]; then
    printf '%s\n' "$skill_names"
  else
    get_default_mediaio_skill_names
  fi
}

get_skill_target_bases() {
  if [ "$codex_available" -eq 1 ] && [ "$codex_plugin_ready" -eq 0 ]; then
    printf '%s\n' "$HOME/.codex/skills"
  fi
  if [ "$claude_available" -eq 1 ] && [ "$claude_plugin_ready" -eq 0 ]; then
    printf '%s\n' "$HOME/.claude/skills"
  fi
}

get_all_skill_target_bases() {
  [ "$codex_available" -eq 1 ] && printf '%s\n' "$HOME/.codex/skills"
  [ "$claude_available" -eq 1 ] && printf '%s\n' "$HOME/.claude/skills"
}

get_skill_target_agent_args() {
  args=
  if [ "$codex_available" -eq 1 ] && [ "$codex_plugin_ready" -eq 0 ]; then
    args="$args -a codex"
  fi
  if [ "$claude_available" -eq 1 ] && [ "$claude_plugin_ready" -eq 0 ]; then
    args="$args -a claude-code"
  fi
  [ -n "$args" ] || return 1
  printf '%s\n' "$args"
}

test_mediaio_skill_set_in_base() {
  base=$1
  skill_count=0
  # Read line by line: a skill directory name may contain spaces, which an
  # unquoted "for ... in $(...)" would split into separate names.
  while IFS= read -r skill_name; do
    [ -n "$skill_name" ] || continue
    skill_count=$((skill_count + 1))
    [ -f "$base/$skill_name/SKILL.md" ] || return 1
  done <<EOF
$(get_mediaio_skill_names)
EOF
  [ "$skill_count" -gt 0 ]
}

test_claude_plugin_provided_skills_present() {
  namespace_root=$HOME/.claude/plugins/cache/media-io/media-io
  [ -d "$namespace_root" ] || return 1
  test_mediaio_skill_set_in_base "$namespace_root/skills" && return 0
  find "$namespace_root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -r | {
    while IFS= read -r root; do
      [ -n "$root" ] || continue
      test_mediaio_skill_set_in_base "$root/skills" && exit 0
    done
    exit 1
  }
}

test_codex_plugin_provided_skills_present() {
  marketplace_name=$1
  namespace_root=$HOME/.codex/plugins/cache/$marketplace_name/$MediaIoCodexPluginName
  [ -d "$namespace_root" ] || return 1
  test_mediaio_skill_set_in_base "$namespace_root/skills" && return 0
  find "$namespace_root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -r | {
    while IFS= read -r root; do
      [ -n "$root" ] || continue
      test_mediaio_skill_set_in_base "$root/skills" && exit 0
    done
    exit 1
  }
}

list_contains_line() {
  needle=$1
  haystack=$2
  [ -n "$haystack" ] || return 1
  printf '%s\n' "$haystack" | grep -Fqx "$needle"
}

# Emits one marketplace name per line. Returns non-zero when the list cannot be
# read at all, so callers can tell "not visible" apart from "could not check".
get_claude_marketplace_names() {
  require_command claude || return 1
  require_command node || return 1
  claude plugin marketplace list --json 2>/dev/null | node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      let data;
      try { data = JSON.parse(raw); } catch (error) { process.exit(2); }
      if (!Array.isArray(data)) process.exit(2);
      const names = data.map((entry) => entry && entry.name).filter((name) => typeof name === "string" && name);
      process.stdout.write(names.join("\n"));
    });
  '
}

get_claude_installed_plugin_ids() {
  require_command claude || return 1
  require_command node || return 1
  claude plugin list --json 2>/dev/null | node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      let data;
      try { data = JSON.parse(raw); } catch (error) { process.exit(2); }
      if (!Array.isArray(data)) process.exit(2);
      const ids = data.map((entry) => entry && entry.id).filter((id) => typeof id === "string" && id);
      process.stdout.write(ids.join("\n"));
    });
  '
}

# $1 is the top-level key to read: "installed" or "available".
get_codex_plugin_ids() {
  codex_list_key=$1
  require_command codex || return 1
  require_command node || return 1
  codex plugin list --json --available 2>/dev/null | node -e '
    const key = process.argv[1];
    let raw = "";
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      let data;
      try { data = JSON.parse(raw); } catch (error) { process.exit(2); }
      const entries = data && data[key];
      if (!Array.isArray(entries)) process.exit(2);
      const ids = entries.map((entry) => entry && entry.pluginId).filter((id) => typeof id === "string" && id);
      process.stdout.write(ids.join("\n"));
    });
  ' "$codex_list_key"
}

warn_if_claude_marketplace_not_visible() {
  if claude_marketplace_names=$(get_claude_marketplace_names); then
    if list_contains_line media-io "$claude_marketplace_names"; then
      printf '  OK: Claude Code can see media-io in the configured marketplaces\n'
    else
      add_warning "Claude Code does not surface media-io from the configured marketplaces on this build."
    fi
  else
    add_warning "Claude marketplace list could not be read; the media-io visibility check was skipped."
  fi
}

warn_if_claude_plugin_not_listed() {
  if claude_plugin_ids=$(get_claude_installed_plugin_ids); then
    if list_contains_line "$MediaIoClaudePluginId" "$claude_plugin_ids"; then
      printf '  OK: Claude Code lists %s as installed\n' "$MediaIoClaudePluginId"
    else
      add_warning "Claude Code does not currently list $MediaIoClaudePluginId in the installed plugin list."
    fi
  else
    add_warning "Claude installed plugin list could not be read; the $MediaIoClaudePluginId check was skipped."
  fi
}

# An already-installed plugin need not appear in the available[] snapshot, so the
# installed[] list is checked first, exactly as the PowerShell script does.
test_codex_marketplace_visible() {
  expected_codex_plugin_id="$MediaIoCodexPluginName@$MediaIoCodexMarketplaceName"
  codex_lists_readable=0

  if codex_installed_ids=$(get_codex_plugin_ids installed); then
    codex_lists_readable=1
    if list_contains_line "$expected_codex_plugin_id" "$codex_installed_ids"; then
      printf '  OK: Codex plugin %s is already installed\n' "$expected_codex_plugin_id"
      return 0
    fi
  fi

  if codex_available_ids=$(get_codex_plugin_ids available); then
    codex_lists_readable=1
    if list_contains_line "$expected_codex_plugin_id" "$codex_available_ids"; then
      printf '  OK: Codex can see %s in the git marketplace snapshot\n' "$expected_codex_plugin_id"
      return 0
    fi
  fi

  # Being unable to read the lists is not evidence that the plugin is missing, so
  # do not let it push the install into the personal marketplace fallback.
  if [ "$codex_lists_readable" -eq 0 ]; then
    add_warning "Codex plugin list could not be read; the $expected_codex_plugin_id visibility check was skipped."
    return 0
  fi

  printf 'Codex does not surface %s from the git marketplace snapshot on this build.\n' "$expected_codex_plugin_id" >&2
  return 1
}

warn_if_codex_plugin_not_listed() {
  expected_codex_plugin_id="$MediaIoCodexPluginName@$1"
  if codex_installed_ids=$(get_codex_plugin_ids installed); then
    if list_contains_line "$expected_codex_plugin_id" "$codex_installed_ids"; then
      printf '  OK: Codex lists %s as installed\n' "$expected_codex_plugin_id"
    else
      add_warning "Codex does not currently list $expected_codex_plugin_id in the installed plugin list."
    fi
  else
    add_warning "Codex installed plugin list could not be read; the $expected_codex_plugin_id check was skipped."
  fi
}

use_codex_personal_marketplace_fallback() {
  fallback_reason=$1
  if [ "$use_personal_marketplace_fallback" -eq 0 ]; then
    add_warning "Using Codex personal marketplace fallback: $fallback_reason"
    personal_marketplace_fallback_reason=$fallback_reason
  else
    printf '  Codex personal marketplace fallback still active: %s\n' "$fallback_reason"
    [ -n "$personal_marketplace_fallback_reason" ] || personal_marketplace_fallback_reason=$fallback_reason
  fi
  use_personal_marketplace_fallback=1
}

get_personal_marketplace_path() {
  printf '%s\n' "$HOME/.agents/plugins/marketplace.json"
}

get_personal_marketplace_name() {
  marketplace_path=$(get_personal_marketplace_path)
  if [ -f "$marketplace_path" ]; then
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
  printf '%s\n' "$1" | awk -F '[-_]' '{
    out="";
    for (i=1;i<=NF;i++) {
      if ($i == "") continue;
      out = out toupper(substr($i,1,1)) tolower(substr($i,2));
    }
    if (out == "") out="Personal";
    print out;
  }'
}

write_json_no_bom() {
  path=$1
  json=$2
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$json" >"$path"
}

initialize_local_mediaio_plugin_root() {
  source_root=$(get_mediaio_plugin_source_root 2>/dev/null || true)
  temp_dir=
  if [ -z "$source_root" ]; then
    require_command curl || return 1
    require_command unzip || return 1
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/mediaio-plugin.XXXXXX")
    archive_path=$temp_dir/mediaio-plugin.zip
    printf '  Downloading Media.io plugin source from %s\n' "$MediaIoPluginArchiveUrl"
    curl -fsSL "$MediaIoPluginArchiveUrl" -o "$archive_path" || {
      rm -rf "$temp_dir"
      return 1
    }
    unzip -q "$archive_path" -d "$temp_dir" || {
      rm -rf "$temp_dir"
      return 1
    }
    source_root=$(find "$temp_dir" -type f -path '*/.codex-plugin/plugin.json' 2>/dev/null | sed 's|/.codex-plugin/plugin.json$||' | head -n 1)
  fi
  source_manifest=$source_root/.codex-plugin/plugin.json
  plugin_root=$(get_local_mediaio_plugin_root)
  [ -d "$source_root" ] || return 1
  [ -f "$source_manifest" ] || return 1

  mkdir -p "$plugin_root"
  source_full=$(CDPATH= cd "$source_root" && pwd)
  plugin_full=$(CDPATH= cd "$plugin_root" && pwd)
  if [ "$source_full" != "$plugin_full" ]; then
    cp -R "$source_root"/. "$plugin_root"/
  fi
  cp "$source_manifest" "$plugin_root/plugin.json"
  [ -z "$temp_dir" ] || rm -rf "$temp_dir"
}

# Reports the marketplace name through $resolved_personal_marketplace_name rather
# than stdout: this function also emits progress and warnings, which would end up
# inside the value if callers captured it with a command substitution.
initialize_personal_marketplace_fallback() {
  resolved_personal_marketplace_name=
  marketplace_path=$(get_personal_marketplace_path)
  marketplace_name=$(get_personal_marketplace_name)
  display_name=$(format_display_name_from_name "$marketplace_name")

  if [ -f "$marketplace_path" ]; then
    payload=$(node -e '
      const fs = require("fs");
      const path = process.argv[1];
      const raw = fs.readFileSync(path, "utf8");
      JSON.parse(raw);
      process.stdout.write(raw);
    ' "$marketplace_path" 2>/dev/null) || {
      add_warning "Personal marketplace file exists but could not be parsed cleanly. It will be recreated."
      payload=
    }
  else
    payload=
  fi

  if [ -z "$payload" ]; then
    payload="{\"name\":\"$marketplace_name\",\"interface\":{\"displayName\":\"$display_name\"},\"plugins\":[]}"
  fi

  payload=$(node -e '
    const payload = JSON.parse(process.argv[1]);
    payload.name = String(payload.name || process.argv[2]).trim() || process.argv[2];
    payload.interface = payload.interface || {};
    payload.interface.displayName = String(payload.interface.displayName || process.argv[3]).trim() || process.argv[3];
    payload.plugins = Array.isArray(payload.plugins) ? payload.plugins.filter((entry) => entry && entry.name !== "media-io") : [];
    payload.plugins.push({
      name: process.argv[4],
      source: { source: "local", path: "./plugins/media-io" },
      policy: { installation: "AVAILABLE", authentication: "ON_INSTALL" },
      category: "Design"
    });
    process.stdout.write(JSON.stringify(payload));
  ' "$payload" "$marketplace_name" "$display_name" "$MediaIoCodexPluginName")

  mkdir -p "$(dirname "$marketplace_path")"
  write_json_no_bom "$marketplace_path" "$payload"
  # The marketplace entry points at ./plugins/media-io, so a missing plugin root
  # would leave Codex with a dangling local source.
  initialize_local_mediaio_plugin_root || return 1
  resolved_personal_marketplace_name=$marketplace_name
}

install_skill_files() {
  agent_args=$(get_skill_target_agent_args) || return 1
  printf '  Installing Media.io skills with npx\n'
  ensure_node_and_npm || return 1
  npx --yes skills add "$MediaIoSkillRepo" -g $agent_args --skill '*' -y
}

test_skill_directories_present() {
  get_skill_target_bases | {
    base_count=0
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      base_count=$((base_count + 1))
      test_mediaio_skill_set_in_base "$base" || exit 1
    done
    [ "$base_count" -gt 0 ] || exit 1
    exit 0
  }
}

test_any_direct_skill_directories_present() {
  get_all_skill_target_bases | {
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      while IFS= read -r skill_name; do
        [ -n "$skill_name" ] || continue
        [ -d "$base/$skill_name" ] && exit 0
      done <<EOF
$(get_mediaio_skill_names)
EOF
    done
    exit 1
  }
}

ensure_mediaio_auth() {
  write_step "Authenticate Media.io"
  if mediaio whoami >/dev/null 2>&1; then
    printf '  OK: already signed in\n'
    return 0
  fi
  printf '  Run `mediaio whoami` first.\n'
  printf '  If not signed in, run `mediaio auth login` and complete sign-in in the browser it opens.\n'
}

print_list() {
  text=$1
  [ -n "$text" ] || return 0
  printf '%s\n' "$text" | while IFS= read -r item; do
    [ -n "$item" ] && printf '  - %s\n' "$item"
  done
}

printf '%s\n' "Media.io setup script"
printf 'Script version: %s\n' "$SCRIPT_VERSION"
printf '%s\n' "This script installs the Media.io plugin, CLI, and skills. The CLI prefers npm and falls back to a release archive; direct skills are installed with npx only when plugin install is unavailable."

check_optional_host "Preflight: locate claude" claude claude_available
check_optional_host "Preflight: locate codex" codex codex_available
invoke_optional_fallback_step "Install Media.io CLI" "ensure_node_and_npm && install_mediaio_cli_from_npm_package" "install_mediaio_cli_from_release" "verify_mediaio_cli_available" "Media.io CLI is installed"
invoke_checked_step "Run Media.io doctor" "mediaio doctor" "" "local Media.io checks passed"

if [ "$claude_available" -eq 1 ]; then
  invoke_checked_step "Add Media.io marketplace (Claude)" "claude plugin marketplace add '$MediaIoMarketplaceSource'" "" "marketplace is registered"
  invoke_checked_step "Refresh Media.io marketplace (Claude)" "claude plugin marketplace update media-io" "" "marketplace is refreshed"
  invoke_checked_step "Verify marketplace visibility (Claude)" "warn_if_claude_marketplace_not_visible" "" "Marketplace lookup finished"
  invoke_checked_step "Install Claude Code plugin" "claude plugin install '$MediaIoClaudePluginId' -s user -y && claude_plugin_installed=1" "" "Claude Code plugin install completed"
  invoke_checked_step "Verify Claude Code plugin install" '
    warn_if_claude_plugin_not_listed
    if test_claude_plugin_provided_skills_present; then
      claude_plugin_ready=1
    else
      add_warning "Claude Code plugin-provided skills are missing; direct skills install will be attempted with npx."
    fi
  ' "" "Claude Code plugin install verification completed"
fi

if [ "$codex_available" -eq 1 ]; then
  if ! invoke_soft_step "Add Media.io marketplace (Codex)" "codex plugin marketplace add '$MediaIoMarketplaceSource'" "Codex marketplace is registered"; then
    use_codex_personal_marketplace_fallback "Codex marketplace add failed for '$MediaIoMarketplaceSource'."
  fi
  if [ "$use_personal_marketplace_fallback" -eq 0 ] && ! invoke_soft_step "Refresh Media.io marketplace (Codex)" "codex plugin marketplace upgrade '$MediaIoCodexMarketplaceName'" "Codex marketplace is refreshed"; then
    use_codex_personal_marketplace_fallback "Codex marketplace refresh failed for '$MediaIoCodexMarketplaceName'."
  fi
  if [ "$use_personal_marketplace_fallback" -eq 0 ] && ! invoke_soft_step "Verify marketplace visibility (Codex)" "test_codex_marketplace_visible" "Codex marketplace lookup finished"; then
    use_codex_personal_marketplace_fallback "Codex marketplace visibility check failed for '$MediaIoCodexPluginName@$MediaIoCodexMarketplaceName'."
  fi
  invoke_checked_step "Install Codex plugin" '
    if [ "$use_personal_marketplace_fallback" -eq 0 ] && codex plugin add "$MediaIoCodexPluginName@$MediaIoCodexMarketplaceName"; then
      resolved_codex_marketplace_name=$MediaIoCodexMarketplaceName
    else
      use_codex_personal_marketplace_fallback "Codex git marketplace install failed for '\''$MediaIoCodexPluginName@$MediaIoCodexMarketplaceName'\''."
      initialize_personal_marketplace_fallback || return 1
      installed_marketplace_name=$resolved_personal_marketplace_name
      [ -n "$installed_marketplace_name" ] || return 1
      printf "  Installing through Codex personal marketplace fallback: %s@%s\n" "$MediaIoCodexPluginName" "$installed_marketplace_name"
      printf "  Personal marketplace file: %s\n" "$(get_personal_marketplace_path)"
      codex plugin add "$MediaIoCodexPluginName@$installed_marketplace_name" || return 1
      resolved_codex_marketplace_name=$installed_marketplace_name
    fi
    codex_plugin_installed=1
  ' "" "Codex plugin install completed"
  invoke_checked_step "Verify Codex plugin install" '
    [ -n "$resolved_codex_marketplace_name" ] || return 1
    warn_if_codex_plugin_not_listed "$resolved_codex_marketplace_name"
    if test_codex_plugin_provided_skills_present "$resolved_codex_marketplace_name"; then
      codex_plugin_ready=1
    else
      add_warning "Codex plugin-provided skills are missing; direct skills install will be attempted with npx."
    fi
  ' "" "Codex plugin install verification completed"
fi

if [ -z "$(get_skill_target_agent_args 2>/dev/null || true)" ]; then
  write_step "Skip direct Media.io skills install"
  printf '  OK: plugin-provided skills are installed; direct skills install is skipped to avoid duplicate entries\n'
else
  invoke_checked_step "Install Media.io skills" "install_skill_files" "test_skill_directories_present" "skills are installed"
fi

write_step "Final verification"
if verify_mediaio_cli_available; then
  printf '  OK: mediaio version responded\n'
else
  add_failure "Final verification - mediaio version failed"
fi

if [ -z "$(get_all_skill_target_bases || true)" ]; then
  add_warning "Neither Codex nor Claude Code is available; no Media.io skills target was verified."
elif [ -n "$(get_skill_target_bases || true)" ]; then
  # At least one available host is not plugin-ready, so the direct skills install
  # had to cover it. Verify the skill files really landed there.
  if test_skill_directories_present; then
    printf '  OK: Media.io skill files are present for every host without a ready plugin\n'
  else
    add_failure "Final verification - Media.io skill files are still missing."
  fi
else
  printf '  OK: Media.io plugin-provided skills are present\n'
  if test_any_direct_skill_directories_present; then
    add_warning "Residual direct Media.io skill directories still exist alongside the plugin install."
  fi
fi

if [ "$failure_count" -gt 0 ]; then
  printf '\nSetup finished with failures.\n'
  print_list "$failures"
  if [ "$warning_count" -gt 0 ]; then
    printf '\nWarnings:\n'
    print_list "$warnings"
  fi
  exit 1
fi

printf '\nSetup finished successfully.\n'
if [ "$warning_count" -gt 0 ]; then
  printf 'Warnings were emitted, but the required files and commands are present.\n'
fi
ensure_mediaio_auth

#!/usr/bin/env bash
# uninstall-mediaio.sh script version: 0.1.5
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"

step_index=0
failures=()
warnings=()
SCRIPT_VERSION="0.1.5"
MediaIoInstallDir="${MEDIAIO_INSTALL_DIR:-$HOME/.local/bin}"
MediaIoCodexMarketplaceName="${MEDIAIO_CODEX_MARKETPLACE_NAME:-media-io}"
claude_available=0
codex_available=0

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

  write_step "$label"

  if ! eval "$action"; then
    add_failure "$label - command failed"
    return 0
  fi

  if [[ -n "$verify" ]]; then
    if ! eval "$verify"; then
      add_failure "$label - verification failed"
      return 0
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
    add_warning "$command_name is not available; skipping host-specific removal steps."
    printf -v "$var_name" '%s' 0
  fi
}

get_mediaio_plugin_source_candidates() {
  local candidates=()
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

get_mediaio_skill_source_candidates() {
  local candidates=()
  if [[ -n "${MEDIAIO_SKILL_SOURCE:-}" ]]; then
    candidates+=("$MEDIAIO_SKILL_SOURCE")
  fi
  candidates+=(
    "$SCRIPT_ROOT"
    "$SCRIPT_ROOT/../media-plugin-main"
    "$SCRIPT_ROOT/../plugins/media-io"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate/skills" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

get_mediaio_skill_source_root() {
  get_mediaio_skill_source_candidates
}

get_default_mediaio_skill_names() {
  printf '%s\n' mediaio-generate mediaio-install
}

get_mediaio_skill_names() {
  local source_root skill_dir found=0
  if ! source_root="$(get_mediaio_skill_source_root)" || ! [[ -d "$source_root/skills" ]]; then
    get_default_mediaio_skill_names
    return 0
  fi

  while IFS= read -r skill_dir; do
    [[ -n "$skill_dir" ]] || continue
    if [[ -f "$skill_dir/SKILL.md" ]]; then
      basename "$skill_dir"
      found=1
    fi
  done < <(find "$source_root/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  if [[ "$found" -eq 0 ]]; then
    get_default_mediaio_skill_names
  fi
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

get_mediaio_codex_marketplace_name() {
  printf '%s\n' "$MediaIoCodexMarketplaceName"
}

remove_path_if_present() {
  local path="$1"

  if [[ -e "$path" ]]; then
    rm -rf "$path"
    printf '  OK: removed %s\n' "$path"
    return 0
  fi

  return 1
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

write_json_no_bom() {
  local path="$1"
  local json="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$json" >"$path"
}

remove_personal_marketplace_entry() {
  local marketplace_path payload updated
  marketplace_path="$(get_personal_marketplace_path)"

  [[ -f "$marketplace_path" ]] || return 1

  payload="$(node -e '
    const fs = require("fs");
    const path = process.argv[1];
    process.stdout.write(fs.readFileSync(path, "utf8"));
  ' "$marketplace_path")"

  updated="$(node -e '
    try {
      const payload = JSON.parse(process.argv[1]);
      if (!Array.isArray(payload.plugins)) process.exit(2);
      const before = payload.plugins.length;
      payload.plugins = payload.plugins.filter((entry) => entry && entry.name !== "media-io");
      if (payload.plugins.length === before) process.exit(3);
      payload.interface = payload.interface || {};
      if (!String(payload.name || "").trim()) payload.name = "personal";
      if (!String(payload.interface.displayName || "").trim()) payload.interface.displayName = "Personal";
      process.stdout.write(JSON.stringify(payload));
    } catch {
      process.exit(4);
    }
  ' "$payload")" || return 1

  write_json_no_bom "$marketplace_path" "$updated"
}

get_codex_plugin_cache_roots() {
  local version marketplace cache_root
  version="$(get_mediaio_plugin_version)"
  marketplace="$(get_personal_marketplace_name)"
  for cache_root in \
    "$HOME/.codex/plugins/cache/$marketplace/media-io/$version" \
    "$HOME/.codex/plugins/cache/$marketplace/media-io" \
    "$HOME/.codex/plugins/cache/$MediaIoCodexMarketplaceName/media-io/$version" \
    "$HOME/.codex/plugins/cache/$MediaIoCodexMarketplaceName/media-io" \
    "$HOME/.codex/plugins/cache/media-io/media-io/$version" \
    "$HOME/.codex/plugins/cache/media-io/media-io" \
    "$HOME/.codex/plugins/cache/personal/media-io/$version" \
    "$HOME/.codex/plugins/cache/personal/media-io"
  do
    printf '%s\n' "$cache_root"
  done

  if [[ -d "$HOME/.codex/plugins/cache" ]]; then
    while IFS= read -r dir; do
      [[ -n "$dir" ]] || continue
      printf '%s\n' "$dir/$MediaIoCodexMarketplaceName/media-io"
      printf '%s\n' "$dir/media-io"
    done < <(find "$HOME/.codex/plugins/cache" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  fi
}

get_codex_marketplace_roots() {
  local roots=()
  local tmp_marketplace_root="$HOME/.codex/.tmp/marketplaces"
  local marketplace

  for marketplace in "$MediaIoCodexMarketplaceName" media-io; do
    [[ -n "$marketplace" ]] || continue
    roots+=("$tmp_marketplace_root/$marketplace")
  done

  local root
  for root in "${roots[@]}"; do
    printf '%s\n' "$root"
  done
}

get_claude_plugin_cache_roots() {
  local version cache_root
  version="$(get_mediaio_plugin_version)"
  for cache_root in \
    "$HOME/.claude/plugins/cache/media-io/media-io/$version" \
    "$HOME/.claude/plugins/cache/media-io/media-io"
  do
    printf '%s\n' "$cache_root"
  done

  if [[ -d "$HOME/.claude/plugins/cache" ]]; then
    while IFS= read -r dir; do
      [[ -n "$dir" ]] || continue
      printf '%s\n' "$dir/media-io"
    done < <(find "$HOME/.claude/plugins/cache" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  fi
}

remove_codex_plugin_caches() {
  local cache_root
  while IFS= read -r cache_root; do
    [[ -n "$cache_root" ]] || continue
    remove_path_if_present "$cache_root" >/dev/null || true
  done < <(get_codex_plugin_cache_roots)
}

remove_codex_marketplaces() {
  local marketplace_root
  while IFS= read -r marketplace_root; do
    [[ -n "$marketplace_root" ]] || continue
    remove_path_if_present "$marketplace_root" >/dev/null || true
  done < <(get_codex_marketplace_roots)
}

remove_claude_plugin_caches() {
  local cache_root
  while IFS= read -r cache_root; do
    [[ -n "$cache_root" ]] || continue
    remove_path_if_present "$cache_root" >/dev/null || true
  done < <(get_claude_plugin_cache_roots)
}

remove_skill_directories() {
  local skill_root
  local base skill_name skill_count=0
  while IFS= read -r skill_name; do
    [[ -n "$skill_name" ]] || continue
    skill_count=$((skill_count + 1))
    for base in "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.codex/skills"; do
      skill_root="$base/$skill_name"
      if [[ -d "$skill_root" ]]; then
        rm -rf "$skill_root"
        printf '  OK: removed skill directory %s\n' "$skill_root"
      fi
    done
  done < <(get_mediaio_skill_names)

  [[ $skill_count -gt 0 ]]
}

test_skill_directories_absent() {
  local skill_root
  local base skill_name skill_count=0
  while IFS= read -r skill_name; do
    [[ -n "$skill_name" ]] || continue
    skill_count=$((skill_count + 1))
    for base in "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.codex/skills"; do
      skill_root="$base/$skill_name"
      if [[ -d "$skill_root" ]]; then
        return 1
      fi
    done
  done < <(get_mediaio_skill_names)

  [[ $skill_count -gt 0 ]]
}

test_codex_plugin_cache_present() {
  local cache_root
  while IFS= read -r cache_root; do
    [[ -n "$cache_root" ]] || continue
    if [[ -d "$cache_root" ]]; then
      return 0
    fi
  done < <(get_codex_plugin_cache_roots)

  return 1
}

test_claude_plugin_cache_present() {
  local cache_root
  while IFS= read -r cache_root; do
    [[ -n "$cache_root" ]] || continue
    if [[ -d "$cache_root" ]]; then
      return 0
    fi
  done < <(get_claude_plugin_cache_roots)

  return 1
}

verify_mediaio_package_removed() {
  local package_dir
  package_dir="$(npm root -g)/@mediaio/cli"
  [[ ! -e "$package_dir" ]]
}

warn_if_mediaio_still_on_path() {
  local mediaio_path npm_bin_dir
  mediaio_path="$(command -v mediaio || true)"
  if [[ -z "$mediaio_path" ]]; then
    return 0
  fi

  npm_bin_dir="$(npm prefix -g)/bin"
  case "$mediaio_path" in
    "$npm_bin_dir"/*)
      add_warning "mediaio still resolves from the npm global bin directory: $mediaio_path"
      ;;
    *)
      add_warning "mediaio still resolves from PATH, but not from this npm install: $mediaio_path"
      ;;
  esac

  return 0
}

remove_mediaio_cli() {
  if require_command npm; then
    npm uninstall -g @mediaio/cli
  fi

  local release_bin
  for release_bin in "$MediaIoInstallDir/mediaio" "$MediaIoInstallDir/mediaio.exe"; do
    if [[ -e "$release_bin" ]]; then
      rm -f "$release_bin"
      printf '  OK: removed %s\n' "$release_bin"
    fi
  done
}

remove_claude_plugin() {
  local removed=0 raw=""

  if ! test_claude_plugin_cache_present; then
    printf '  OK: Claude Code plugin already absent\n'
    remove_claude_plugin_caches
    return 0
  fi

  if require_command claude; then
    raw="$(claude plugin uninstall media-io@media-io -s user -y 2>&1)" && {
      removed=1
      printf '  OK: claude plugin uninstall media-io@media-io -s user -y\n'
    } || {
      if [[ "$raw" == *'Plugin "media-io@media-io" not found in installed plugins'* ]]; then
        printf '  OK: Claude Code plugin already absent\n'
      else
        add_warning "claude plugin uninstall media-io@media-io failed: $raw"
      fi
    }
  else
    add_warning "claude is not available; removing cached files only."
  fi

  remove_claude_plugin_caches

  if [[ $removed -eq 0 ]]; then
    return 0
  fi
}

remove_codex_plugin() {
  local marketplace_name target removed=0 raw=""
  marketplace_name="$(get_personal_marketplace_name)"

  if ! test_codex_plugin_cache_present; then
    printf '  OK: Codex plugin already absent\n'
  fi

  if require_command codex; then
    for target in "media-io@$marketplace_name" "media-io@media-io"; do
      raw="$(codex plugin remove "$target" 2>&1)" && {
        removed=1
        printf '  OK: codex plugin remove %s\n' "$target"
        break
      } || {
        if [[ "$raw" == *'not found in installed plugins'* ]]; then
          continue
        fi
        add_warning "codex plugin remove $target failed: $raw"
      }
    done
  else
    add_warning "codex is not available; removing cached files only."
  fi

  if remove_personal_marketplace_entry; then
    printf '  OK: removed media-io from personal marketplace file\n'
  elif [[ -f "$(get_personal_marketplace_path)" ]]; then
    add_warning "No media-io entry was found in the personal marketplace file."
  else
    add_warning "Personal marketplace file does not exist."
  fi

  remove_codex_plugin_caches
  remove_codex_marketplaces

  if [[ $removed -eq 0 ]]; then
    return 0
  fi
}

verify_codex_plugin_removed() {
  if test_codex_plugin_cache_present; then
    return 1
  fi
  local marketplace_root
  while IFS= read -r marketplace_root; do
    [[ -n "$marketplace_root" ]] || continue
    if [[ -e "$marketplace_root" ]]; then
      return 1
    fi
  done < <(get_codex_marketplace_roots)

  local marketplace_path
  marketplace_path="$(get_personal_marketplace_path)"
  if [[ -f "$marketplace_path" ]]; then
    node -e '
      const fs = require("fs");
      const path = process.argv[1];
      const payload = JSON.parse(fs.readFileSync(path, "utf8"));
      const names = Array.isArray(payload.plugins) ? payload.plugins.map((entry) => entry && entry.name) : [];
      if (names.includes("media-io")) process.exit(1);
    ' "$marketplace_path"
  fi
}

verify_claude_plugin_removed() {
  ! test_claude_plugin_cache_present
}

verify_final_state() {
  if verify_mediaio_package_removed; then
    printf '  OK: @mediaio/cli is absent from the npm global root\n'
  else
    add_failure "Final verification - npm package @mediaio/cli is still present."
  fi

  if test_codex_plugin_cache_present; then
    add_failure "Final verification - Media.io Codex plugin cache is still present."
  fi
  while IFS= read -r marketplace_root; do
    [[ -n "$marketplace_root" ]] || continue
    if [[ -e "$marketplace_root" ]]; then
      add_failure "Final verification - Media.io Codex marketplace snapshot is still present."
      break
    fi
  done < <(get_codex_marketplace_roots)

  if test_claude_plugin_cache_present; then
    add_failure "Final verification - Media.io Claude Code plugin cache is still present."
  fi

  if ! test_skill_directories_absent; then
    add_failure "Final verification - some Media.io skill directories are still present."
  fi

  local marketplace_path
  marketplace_path="$(get_personal_marketplace_path)"
  if [[ -f "$marketplace_path" ]]; then
    node -e '
      const fs = require("fs");
      const path = process.argv[1];
      const payload = JSON.parse(fs.readFileSync(path, "utf8"));
      const names = Array.isArray(payload.plugins) ? payload.plugins.map((entry) => entry && entry.name) : [];
      if (names.includes("media-io")) process.exit(1);
    ' "$marketplace_path"
  fi
  printf '  OK: requested Media.io uninstall targets are absent\n'
}

printf '%s\n' "Media.io uninstall script"
printf 'Script version: %s\n' "$SCRIPT_VERSION"
printf '%s\n' "This script removes the Media.io CLI, Claude/Codex plugin state, and Media.io skills with checks after each step."

check_optional_host "Preflight: locate claude" claude claude_available
check_optional_host "Preflight: locate codex" codex codex_available
run_checked_step "Preflight: locate npm" "require_command npm" "" "npm is available"
run_checked_step "Preflight: locate npx" "require_command npx" "" "npx is available"

run_checked_step "Uninstall Media.io CLI" "remove_mediaio_cli" "verify_mediaio_package_removed" "Media.io CLI removed"
warn_if_mediaio_still_on_path

if [[ "$claude_available" -eq 1 ]]; then
  run_checked_step "Remove Claude Code plugin" "remove_claude_plugin" "verify_claude_plugin_removed" "Claude Code plugin removed"
else
  write_step "Remove Claude Code plugin"
  remove_claude_plugin
fi

if [[ "$codex_available" -eq 1 ]]; then
  run_checked_step "Remove Codex plugin" "remove_codex_plugin" "verify_codex_plugin_removed" "Codex plugin removed"
else
  write_step "Remove Codex plugin"
  remove_codex_plugin
fi

run_checked_step "Remove Media.io skills" "remove_skill_directories" "test_skill_directories_absent" "Media.io skills removed"

write_step "Final verification"
verify_final_state

if (( ${#failures[@]} > 0 )); then
  printf '\nUninstall finished with failures.\n'
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

printf '\nUninstall finished successfully.\n'
if (( ${#warnings[@]} > 0 )); then
  printf 'Warnings were emitted, but the requested removal targets are gone.\n'
fi

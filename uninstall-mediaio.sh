#!/usr/bin/env bash
set -euo pipefail

step_index=0
failures=()
warnings=()
removed_by_cli=0
removed_from_marketplace=0

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

run_checked_step() {
  local label="$1"
  local action="$2"
  local verify="${3:-}"
  local success_message="${4:-}"

  write_step "$label"

  if ! "$action"; then
    add_failure "$label - command failed"
    return 0
  fi

  if [[ -n "$verify" ]]; then
    if ! "$verify"; then
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

require_command() {
  command -v "$1" >/dev/null 2>&1
}

preflight_npm() { require_command npm; }
preflight_npx() { require_command npx; }
preflight_codex() { require_command codex; }

uninstall_mediaio_cli() { npm uninstall -g @mediaio/cli; }

get_npm_global_root() {
  npm root -g
}

get_npm_global_bin_dir() {
  npm prefix -g
}

verify_mediaio_package_removed() {
  local package_dir
  package_dir="$(get_npm_global_root)/@mediaio/cli"
  [[ ! -e "$package_dir" ]]
}

warn_if_mediaio_still_on_path() {
  local mediaio_path npm_bin_dir
  mediaio_path="$(command -v mediaio || true)"
  if [[ -z "$mediaio_path" ]]; then
    return 0
  fi

  npm_bin_dir="$(get_npm_global_bin_dir)/bin"
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

remove_codex_plugin() {
  local marketplace_name target
  marketplace_name="$(get_personal_marketplace_name)"
  local cli_removed=0

  removed_by_cli=0
  for target in "media-io@$marketplace_name" "media-io@media-io"; do
    if codex plugin remove "$target"; then
      removed_by_cli=1
      cli_removed=1
      printf '  OK: codex plugin remove %s\n' "$target"
      break
    fi
    add_warning "codex plugin remove $target failed"
  done

  removed_from_marketplace=0
  if remove_personal_marketplace_entry; then
    removed_from_marketplace=1
    printf '  OK: removed media-io from personal marketplace file\n'
  elif [[ -f "$(get_personal_marketplace_path)" ]]; then
    add_warning "No media-io entry was found in the personal marketplace file."
  else
    add_warning "Personal marketplace file does not exist."
  fi

  remove_codex_plugin_caches

  if [[ $removed_by_cli -eq 0 && $removed_from_marketplace -eq 0 ]] && ! test_codex_plugin_cache_present; then
    add_warning "Codex did not report removing media-io, but the plugin cache was cleared."
  fi

  if [[ $cli_removed -eq 0 ]]; then
    return 1
  fi
}

verify_codex_plugin_removed() {
  if test_codex_plugin_cache_present; then
    return 1
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
}

verify_final_state() {
  if verify_mediaio_package_removed; then
    printf '  OK: @mediaio/cli is absent from the npm global root\n'
  else
    add_failure "Final verification - npm package @mediaio/cli is still present."
  fi

  if test_codex_plugin_cache_present; then
    add_failure "Final verification - Media.io plugin cache is still present."
    return 0
  fi

  if ! test_skill_directories_absent; then
    add_failure "Final verification - Media.io skill directories are still present."
    return 0
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
  printf '  OK: media-io is absent from Codex cache and personal marketplace\n'
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
    const payload = JSON.parse(process.argv[1]);
    if (!Array.isArray(payload.plugins)) process.exit(2);
    const before = payload.plugins.length;
    payload.plugins = payload.plugins.filter((entry) => entry && entry.name !== "media-io");
    if (payload.plugins.length === before) process.exit(3);
    payload.interface = payload.interface || {};
    if (!String(payload.name || "").trim()) payload.name = "personal";
    if (!String(payload.interface.displayName || "").trim()) payload.interface.displayName = "Personal";
    process.stdout.write(JSON.stringify(payload));
  ' "$payload")" || return 1

  write_json_no_bom "$marketplace_path" "$updated"
}

remove_codex_plugin_caches() {
  local cache_root
  for cache_root in \
    "$HOME/.codex/plugins/cache/personal/media-io" \
    "$HOME/.codex/plugins/cache/media-io/media-io"
  do
    if [[ -d "$cache_root" ]]; then
      rm -rf "$cache_root"
      printf '  OK: removed plugin cache %s\n' "$cache_root"
    fi
  done
}

remove_skill_directories() {
  local skill_root
  for skill_root in \
    "$HOME/.agents/skills/mediaio-generate" \
    "$HOME/.agents/skills/mediaio-install" \
    "$HOME/.codex/skills/mediaio-generate" \
    "$HOME/.codex/skills/mediaio-install"
  do
    if [[ -d "$skill_root" ]]; then
      rm -rf "$skill_root"
      printf '  OK: removed skill directory %s\n' "$skill_root"
    fi
  done
}

test_skill_directories_absent() {
  local skill_root
  for skill_root in \
    "$HOME/.agents/skills/mediaio-generate" \
    "$HOME/.agents/skills/mediaio-install" \
    "$HOME/.codex/skills/mediaio-generate" \
    "$HOME/.codex/skills/mediaio-install"
  do
    if [[ -d "$skill_root" ]]; then
      return 1
    fi
  done

  return 0
}

test_codex_plugin_cache_present() {
  local cache_root
  for cache_root in \
    "$HOME/.codex/plugins/cache/personal/media-io" \
    "$HOME/.codex/plugins/cache/media-io/media-io"
  do
    if [[ -d "$cache_root" ]]; then
      return 0
    fi
  done

  return 1
}

printf '%s\n' "Media.io uninstall script"
printf '%s\n' "This script removes the Media.io CLI, Codex plugin, and Media.io skills with checks after each step."

run_checked_step "Preflight: locate npm" preflight_npm "" "npm is available"
run_checked_step "Preflight: locate npx" preflight_npx "" "npx is available"
run_checked_step "Preflight: locate codex" preflight_codex "" "codex is available"

run_checked_step "Uninstall Media.io CLI" uninstall_mediaio_cli verify_mediaio_package_removed "Media.io CLI removed"
warn_if_mediaio_still_on_path

run_checked_step "Remove Codex plugin" remove_codex_plugin verify_codex_plugin_removed "Codex plugin removed"
run_checked_step "Remove Media.io skills" remove_skill_directories test_skill_directories_absent "Media.io skills removed"

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

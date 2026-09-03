#!/bin/sh
# uninstall-mediaio.sh script version: 0.1.5
set -eu

SCRIPT_ROOT=$(CDPATH= cd "$(dirname "$0")" && pwd)

step_index=0
failure_count=0
warning_count=0
failures=
warnings=
SCRIPT_VERSION="0.1.5"
MediaIoPackageName=${MEDIAIO_NPM_PACKAGE:-@mediaio/cli}
MediaIoInstallDir=${MEDIAIO_INSTALL_DIR:-"$HOME/.local/bin"}
MediaIoClaudePluginId=${MEDIAIO_CLAUDE_PLUGIN_ID:-media-io@media-io}
MediaIoCodexPluginName=${MEDIAIO_CODEX_PLUGIN_NAME:-media-io}
MediaIoCodexMarketplaceName=${MEDIAIO_CODEX_MARKETPLACE_NAME:-media-io}
claude_available=0
codex_available=0

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

run_checked_step() {
  label=$1
  action=$2
  verify=${3:-}
  success_message=${4:-}

  write_step "$label"
  if ! eval "$action"; then
    add_failure "$label - command failed"
    return 0
  fi

  if [ -n "$verify" ] && ! eval "$verify"; then
    add_failure "$label - verification failed"
    return 0
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
    add_warning "$command_name is not available; skipping host-specific removal steps."
    eval "$var_name=0"
  fi
}

get_default_mediaio_skill_names() {
  printf '%s\n' mediaio-generate mediaio-install
}

get_mediaio_plugin_source_root() {
  for candidate in "$SCRIPT_ROOT" "$SCRIPT_ROOT/../media-plugin-main" "$SCRIPT_ROOT/../plugins/media-io" "$HOME/.codex/.tmp/marketplaces/$MediaIoCodexMarketplaceName"; do
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
  for candidate in "$SCRIPT_ROOT/skills" "$SCRIPT_ROOT/../media-plugin-main/skills" "$SCRIPT_ROOT/../plugins/media-io/skills"; do
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

get_mediaio_plugin_version() {
  manifest_path=$(get_mediaio_plugin_source_root)/.codex-plugin/plugin.json
  node -e '
    const fs = require("fs");
    const path = process.argv[1];
    if (!fs.existsSync(path)) process.exit(2);
    const manifest = JSON.parse(fs.readFileSync(path, "utf8"));
    if (!manifest.version) process.exit(3);
    process.stdout.write(String(manifest.version));
  ' "$manifest_path"
}

remove_path_if_present() {
  path=$1
  if [ -e "$path" ]; then
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

write_json_no_bom() {
  path=$1
  json=$2
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$json" >"$path"
}

remove_personal_marketplace_entry() {
  marketplace_path=$(get_personal_marketplace_path)
  [ -f "$marketplace_path" ] || return 1

  payload=$(node -e 'const fs=require("fs"); const raw=fs.readFileSync(process.argv[1],"utf8"); JSON.parse(raw); process.stdout.write(raw);' "$marketplace_path") || {
    add_warning "Personal marketplace file exists but could not be parsed cleanly; skipping marketplace entry removal."
    return 1
  }
  updated=$(node -e '
    try {
      const payload = JSON.parse(process.argv[1]);
      if (!Array.isArray(payload.plugins)) process.exit(2);
      const before = payload.plugins.length;
      payload.plugins = payload.plugins.filter((entry) => entry && entry.name !== process.argv[2]);
      if (payload.plugins.length === before) process.exit(3);
      payload.interface = payload.interface || {};
      if (!String(payload.name || "").trim()) payload.name = "personal";
      if (!String(payload.interface.displayName || "").trim()) payload.interface.displayName = "Personal";
      process.stdout.write(JSON.stringify(payload));
    } catch {
      process.exit(4);
    }
  ' "$payload" "$MediaIoCodexPluginName") || return 1

  write_json_no_bom "$marketplace_path" "$updated"
}

get_codex_plugin_cache_roots() {
  version=$(get_mediaio_plugin_version 2>/dev/null || true)
  marketplace=$(get_personal_marketplace_name)
  for cache_root in \
    "$HOME/.codex/plugins/cache/$marketplace/$MediaIoCodexPluginName/$version" \
    "$HOME/.codex/plugins/cache/$marketplace/$MediaIoCodexPluginName" \
    "$HOME/.codex/plugins/cache/$MediaIoCodexMarketplaceName/$MediaIoCodexPluginName/$version" \
    "$HOME/.codex/plugins/cache/$MediaIoCodexMarketplaceName/$MediaIoCodexPluginName" \
    "$HOME/.codex/plugins/cache/media-io/$MediaIoCodexPluginName/$version" \
    "$HOME/.codex/plugins/cache/media-io/$MediaIoCodexPluginName" \
    "$HOME/.codex/plugins/cache/personal/$MediaIoCodexPluginName/$version" \
    "$HOME/.codex/plugins/cache/personal/$MediaIoCodexPluginName"
  do
    [ -n "$cache_root" ] && printf '%s\n' "$cache_root"
  done

  if [ -d "$HOME/.codex/plugins/cache" ]; then
    find "$HOME/.codex/plugins/cache" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      printf '%s\n' "$dir/$MediaIoCodexPluginName"
    done
  fi
}

get_codex_marketplace_roots() {
  tmp_marketplace_root=$HOME/.codex/.tmp/marketplaces
  for marketplace in "$MediaIoCodexMarketplaceName" media-io; do
    [ -n "$marketplace" ] && printf '%s\n' "$tmp_marketplace_root/$marketplace"
  done
}

get_claude_plugin_cache_roots() {
  version=$(get_mediaio_plugin_version 2>/dev/null || true)
  for cache_root in "$HOME/.claude/plugins/cache/media-io/media-io/$version" "$HOME/.claude/plugins/cache/media-io/media-io"; do
    [ -n "$cache_root" ] && printf '%s\n' "$cache_root"
  done

  if [ -d "$HOME/.claude/plugins/cache" ]; then
    find "$HOME/.claude/plugins/cache" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r dir; do
      [ -n "$dir" ] && printf '%s\n' "$dir/media-io"
    done
  fi
}

get_codex_plugin_cache_namespace_roots() {
  printf '%s\n' "$HOME/.codex/plugins/cache/$MediaIoCodexMarketplaceName"
  printf '%s\n' "$HOME/.codex/plugins/cache/media-io"
  printf '%s\n' "$HOME/.codex/plugins/cache/personal"
}

get_claude_plugin_cache_namespace_roots() {
  printf '%s\n' "$HOME/.claude/plugins/cache/media-io"
}

remove_empty_directory_if_present() {
  path=$1
  [ -d "$path" ] || return 1
  if [ -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    rmdir "$path"
    printf '  OK: removed empty directory %s\n' "$path"
    return 0
  fi
  return 1
}

remove_codex_plugin_caches() {
  get_codex_plugin_cache_roots | while IFS= read -r cache_root; do
    [ -n "$cache_root" ] || continue
    remove_path_if_present "$cache_root" >/dev/null || true
  done
  get_codex_plugin_cache_namespace_roots | while IFS= read -r namespace_root; do
    [ -n "$namespace_root" ] || continue
    remove_empty_directory_if_present "$namespace_root" >/dev/null || true
  done
}

remove_codex_marketplaces() {
  if require_command codex; then
    for marketplace in "$MediaIoCodexMarketplaceName" media-io; do
      [ -n "$marketplace" ] || continue
      raw=$(codex plugin marketplace remove "$marketplace" 2>&1) && {
        printf '  OK: codex plugin marketplace remove %s\n' "$marketplace"
      } || {
        case "$raw" in
          *'not configured or installed'*) add_warning "codex marketplace $marketplace was already absent." ;;
          *) add_warning "codex plugin marketplace remove $marketplace failed: $raw" ;;
        esac
      }
    done
  else
    add_warning "codex is not available; removing Codex marketplace snapshots directly."
  fi
  get_codex_marketplace_roots | while IFS= read -r marketplace_root; do
    [ -n "$marketplace_root" ] || continue
    remove_path_if_present "$marketplace_root" >/dev/null || true
  done
}

remove_claude_plugin_caches() {
  get_claude_plugin_cache_roots | while IFS= read -r cache_root; do
    [ -n "$cache_root" ] || continue
    remove_path_if_present "$cache_root" >/dev/null || true
  done
  get_claude_plugin_cache_namespace_roots | while IFS= read -r namespace_root; do
    [ -n "$namespace_root" ] || continue
    remove_empty_directory_if_present "$namespace_root" >/dev/null || true
  done
}

remove_skill_directories() {
  skill_count=0
  for skill_name in $(get_mediaio_skill_names); do
    [ -n "$skill_name" ] || continue
    skill_count=$((skill_count + 1))
    for base in "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.codex/skills"; do
      skill_root=$base/$skill_name
      if [ -d "$skill_root" ]; then
        rm -rf "$skill_root"
        printf '  OK: removed skill directory %s\n' "$skill_root"
      fi
    done
  done
  [ "$skill_count" -gt 0 ]
}

test_skill_directories_absent() {
  skill_count=0
  for skill_name in $(get_mediaio_skill_names); do
    [ -n "$skill_name" ] || continue
    skill_count=$((skill_count + 1))
    for base in "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.codex/skills"; do
      [ ! -d "$base/$skill_name" ] || return 1
    done
  done
  [ "$skill_count" -gt 0 ]
}

test_codex_plugin_cache_present() {
  if get_codex_plugin_cache_roots | {
    while IFS= read -r cache_root; do
      [ -n "$cache_root" ] || continue
      [ -d "$cache_root" ] && exit 0
    done
    exit 1
  }; then
    return 0
  fi
  if get_codex_plugin_cache_namespace_roots | {
    while IFS= read -r namespace_root; do
      [ -n "$namespace_root" ] || continue
      [ -d "$namespace_root" ] && exit 0
    done
    exit 1
  }; then
    return 0
  fi
  return 1
}

test_claude_plugin_cache_present() {
  if get_claude_plugin_cache_roots | {
    while IFS= read -r cache_root; do
      [ -n "$cache_root" ] || continue
      [ -d "$cache_root" ] && exit 0
    done
    exit 1
  }; then
    return 0
  fi
  if get_claude_plugin_cache_namespace_roots | {
    while IFS= read -r namespace_root; do
      [ -n "$namespace_root" ] || continue
      [ -d "$namespace_root" ] && exit 0
    done
    exit 1
  }; then
    return 0
  fi
  return 1
}

verify_mediaio_package_removed() {
  if require_command npm; then
    package_dir=$(npm root -g)/$MediaIoPackageName
    [ ! -e "$package_dir" ]
  else
    return 0
  fi
}

warn_if_mediaio_still_on_path() {
  mediaio_path=$(command -v mediaio || true)
  [ -n "$mediaio_path" ] || return 0
  if require_command npm; then
    npm_bin_dir=$(npm prefix -g)/bin
    case "$mediaio_path" in
      "$npm_bin_dir"/*) add_warning "mediaio still resolves from the npm global bin directory: $mediaio_path" ;;
      *) add_warning "mediaio still resolves from PATH, but not from this npm install: $mediaio_path" ;;
    esac
  else
    add_warning "mediaio still resolves from PATH: $mediaio_path"
  fi
}

remove_mediaio_cli() {
  if require_command npm; then
    raw=$(npm uninstall -g "$MediaIoPackageName" 2>&1) && {
      printf '  OK: npm uninstall -g %s\n' "$MediaIoPackageName"
    } || {
      add_warning "npm uninstall -g $MediaIoPackageName failed: $raw"
    }
  else
    add_warning "npm is not available; skipping npm global package removal."
  fi
  for release_bin in "$MediaIoInstallDir/mediaio" "$MediaIoInstallDir/mediaio.exe"; do
    if [ -e "$release_bin" ]; then
      rm -f "$release_bin"
      printf '  OK: removed %s\n' "$release_bin"
    fi
  done
}

invoke_mediaio_skill_remove() {
  if require_command npx; then
    skill_args=
    for skill_name in $(get_mediaio_skill_names); do
      [ -n "$skill_name" ] || continue
      skill_args="$skill_args $skill_name"
    done
    if [ -n "$skill_args" ]; then
      raw=$(npx --yes skills remove $skill_args -g -a codex -a claude-code -y 2>&1) && {
        printf '  OK: npx skills remove%s\n' "$skill_args"
      } || {
        add_warning "npx skills remove failed; falling back to direct directory removal. $raw"
      }
    else
      add_warning "No Media.io skill names were found; falling back to direct directory removal."
    fi
  else
    add_warning "npx is not available; removing Media.io skill directories directly."
  fi

  remove_skill_directories
}

remove_claude_plugin() {
  removed=0
  if ! test_claude_plugin_cache_present; then
    printf '  OK: Claude Code plugin already absent\n'
    remove_claude_plugin_caches
    return 0
  fi

  if require_command claude; then
    raw=$(claude plugin uninstall "$MediaIoClaudePluginId" -s user -y 2>&1) && {
      removed=1
      printf '  OK: claude plugin uninstall %s -s user -y\n' "$MediaIoClaudePluginId"
    } || {
      case "$raw" in
        *'not found in installed plugins'*) printf '  OK: Claude Code plugin already absent\n' ;;
        *) add_warning "claude plugin uninstall $MediaIoClaudePluginId failed: $raw" ;;
      esac
    }
  else
    add_warning "claude is not available; removing cached files only."
  fi

  remove_claude_plugin_caches
  [ "$removed" -eq 0 ] || return 0
}

remove_codex_plugin() {
  marketplace_name=$(get_personal_marketplace_name)
  removed=0

  if ! test_codex_plugin_cache_present; then
    printf '  OK: Codex plugin already absent\n'
  fi

  if require_command codex; then
    for target in "$MediaIoCodexPluginName@$marketplace_name" "$MediaIoCodexPluginName@$MediaIoCodexMarketplaceName" "$MediaIoCodexPluginName@personal"; do
      raw=$(codex plugin remove "$target" 2>&1) && {
        removed=1
        printf '  OK: codex plugin remove %s\n' "$target"
        break
      } || {
        case "$raw" in
          *'not found in installed plugins'*) ;;
          *) add_warning "codex plugin remove $target failed: $raw" ;;
        esac
      }
    done
  else
    add_warning "codex is not available; removing cached files only."
  fi

  if remove_personal_marketplace_entry; then
    printf '  OK: removed %s from personal marketplace file\n' "$MediaIoCodexPluginName"
  elif [ -f "$(get_personal_marketplace_path)" ]; then
    add_warning "No media-io entry was found in the personal marketplace file."
  else
    add_warning "Personal marketplace file does not exist."
  fi

  remove_codex_plugin_caches
  remove_codex_marketplaces
  remove_path_if_present "$HOME/plugins/media-io" >/dev/null || true
  [ "$removed" -eq 0 ] || return 0
}

verify_codex_plugin_removed() {
  test_codex_plugin_cache_present && return 1
  get_codex_marketplace_roots | {
    while IFS= read -r marketplace_root; do
      [ -n "$marketplace_root" ] || continue
      [ ! -e "$marketplace_root" ] || exit 1
    done
    exit 0
  } || return 1
  marketplace_path=$(get_personal_marketplace_path)
  if [ -f "$marketplace_path" ]; then
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
  failures_before=$failure_count

  if verify_mediaio_package_removed; then
    printf '  OK: @mediaio/cli is absent from the npm global root\n'
  else
    add_failure "Final verification - npm package @mediaio/cli is still present."
  fi

  test_codex_plugin_cache_present && add_failure "Final verification - Media.io Codex plugin cache is still present."
  if ! get_codex_marketplace_roots | {
    while IFS= read -r marketplace_root; do
      [ -n "$marketplace_root" ] || continue
      if [ -e "$marketplace_root" ]; then
        exit 1
      fi
    done
    exit 0
  }; then
    add_failure "Final verification - Media.io Codex marketplace snapshot is still present."
  fi

  test_claude_plugin_cache_present && add_failure "Final verification - Media.io Claude Code plugin cache is still present."
  test_skill_directories_absent || add_failure "Final verification - some Media.io skill directories are still present."

  marketplace_path=$(get_personal_marketplace_path)
  if [ ! -f "$marketplace_path" ]; then
    :
  elif ! require_command node; then
    add_warning "node is not available; the personal marketplace file was not checked for a leftover media-io entry."
  else
    entry_status=0
    node -e '
      const fs = require("fs");
      const path = process.argv[1];
      let payload;
      try {
        payload = JSON.parse(fs.readFileSync(path, "utf8"));
      } catch (error) {
        process.exit(2);
      }
      const names = Array.isArray(payload.plugins) ? payload.plugins.map((entry) => entry && entry.name) : [];
      if (names.includes("media-io")) process.exit(1);
    ' "$marketplace_path" || entry_status=$?
    case "$entry_status" in
      0) ;;
      2) add_warning "Personal marketplace file exists but could not be parsed cleanly; treating the media-io entry as absent." ;;
      *) add_failure "Final verification - media-io remains in the personal marketplace file." ;;
    esac
  fi

  if [ "$failure_count" -eq "$failures_before" ]; then
    printf '  OK: requested Media.io uninstall targets are absent\n'
  fi
}

print_list() {
  text=$1
  [ -n "$text" ] || return 0
  printf '%s\n' "$text" | while IFS= read -r item; do
    [ -n "$item" ] && printf '  - %s\n' "$item"
  done
}

printf '%s\n' "Media.io uninstall script"
printf 'Script version: %s\n' "$SCRIPT_VERSION"
printf '%s\n' "This script removes the Media.io CLI, Claude/Codex plugin state, and Media.io skills with checks after each step."

check_optional_host "Preflight: locate claude" claude claude_available
check_optional_host "Preflight: locate codex" codex codex_available
run_checked_step "Uninstall Media.io CLI" "remove_mediaio_cli" "verify_mediaio_package_removed" "Media.io CLI removed"
warn_if_mediaio_still_on_path

if [ "$claude_available" -eq 1 ]; then
  run_checked_step "Remove Claude Code plugin" "remove_claude_plugin" "verify_claude_plugin_removed" "Claude Code plugin removed"
else
  write_step "Remove Claude Code plugin"
  remove_claude_plugin
fi

if [ "$codex_available" -eq 1 ]; then
  run_checked_step "Remove Codex plugin" "remove_codex_plugin" "verify_codex_plugin_removed" "Codex plugin removed"
else
  write_step "Remove Codex plugin"
  remove_codex_plugin
fi

run_checked_step "Remove Media.io skills" "invoke_mediaio_skill_remove" "test_skill_directories_absent" "Media.io skills removed"

write_step "Final verification"
verify_final_state

if [ "$failure_count" -gt 0 ]; then
  printf '\nUninstall finished with failures.\n'
  print_list "$failures"
  if [ "$warning_count" -gt 0 ]; then
    printf '\nWarnings:\n'
    print_list "$warnings"
  fi
  exit 1
fi

printf '\nUninstall finished successfully.\n'
if [ "$warning_count" -gt 0 ]; then
  printf 'Warnings were emitted, but the requested removal targets are gone.\n'
fi

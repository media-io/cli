#!/usr/bin/env bash
set -euo pipefail

step_index=0
failures=()
warnings=()
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

require_command() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1
}

ensure_node_and_npm() {
  if ! require_command node || ! require_command npm || ! require_command npx; then
    return 1
  fi

  node -v
  npm -v
  npx --version
}

get_mediaio_source_root() {
  printf '%s\n' "$HOME/.codex/.tmp/marketplaces/media-io"
}

get_mediaio_plugin_version() {
  local manifest_path
  manifest_path="$(get_mediaio_source_root)/.codex-plugin/plugin.json"
  node -e '
    const fs = require("fs");
    const path = process.argv[1];
    if (!fs.existsSync(path)) {
      process.exit(2);
    }
    const manifest = JSON.parse(fs.readFileSync(path, "utf8"));
    if (!manifest.version) {
      process.exit(3);
    }
    process.stdout.write(String(manifest.version));
  ' "$manifest_path"
}

get_codex_plugin_cache_root() {
  local marketplace_name="$1"
  local version
  version="$(get_mediaio_plugin_version)"
  printf '%s\n' "$HOME/.codex/plugins/cache/$marketplace_name/media-io/$version"
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
  local source_root plugin_root source_manifest
  source_root="$(get_mediaio_source_root)"
  plugin_root="$HOME/plugins/media-io"
  source_manifest="$source_root/.codex-plugin/plugin.json"

  [[ -d "$source_root" ]] || return 1
  [[ -f "$source_manifest" ]] || return 1

  mkdir -p "$plugin_root"
  cp -R "$source_root"/. "$plugin_root"/
  cp "$source_manifest" "$plugin_root/plugin.json"
}

initialize_personal_marketplace_fallback() {
  local marketplace_path marketplace_name display_name plugin_root payload
  marketplace_path="$(get_personal_marketplace_path)"
  marketplace_name="$(get_personal_marketplace_name)"
  display_name="$(format_display_name_from_name "$marketplace_name")"
  plugin_root="$HOME/plugins/media-io"

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
    const fs = require("fs");
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

install_skill_files() {
  local required_paths=(
    "$HOME/.agents/skills/mediaio-generate/SKILL.md"
    "$HOME/.agents/skills/mediaio-install/SKILL.md"
  )

  npx --yes skills add media-io/plugin -g --skill '*' -y

  local path
  for path in "${required_paths[@]}"; do
    [[ -f "$path" ]] || return 1
  done
}

printf '%s\n' "Media.io setup script"
printf '%s\n' "This script prints each step, checks the result, and reports failures at the end."

run_checked_step "Preflight: ensure Node.js and npm" "ensure_node_and_npm" "" "Node.js, npm, and npx are available"
run_checked_step "Preflight: locate codex" "require_command codex" "" "codex is available"
run_checked_step "Install Media.io CLI" "npm i -g @mediaio/cli" "mediaio version" "Media.io CLI is installed"
run_checked_step "Run Media.io doctor" "mediaio doctor" "" "local Media.io checks passed"
run_checked_step "Add Media.io marketplace" "codex plugin marketplace add media-io/plugin" "" "marketplace is registered"
run_checked_step "Refresh Media.io marketplace" "codex plugin marketplace upgrade media-io" "" "marketplace is refreshed"

run_checked_step "Verify marketplace visibility" '
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

run_checked_step "Install Media.io skills" "install_skill_files" "" "skills are installed"

write_step "Final verification"
if mediaio version >/dev/null 2>&1; then
  printf '  OK: mediaio version responded\n'
else
  add_failure "Final verification - mediaio version failed"
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

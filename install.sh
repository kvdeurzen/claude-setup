#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
MANAGED_BY="claude-setup"

# Categories: repo subdir -> target under ~/.claude/
declare -A CATEGORIES=(
  [skills]="skills"
  [agents]="agents"
  [rules]="rules"
  [output-styles]="output-styles"
  [hooks]="hooks"
)

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: install.sh [OPTIONS] [ITEMS...]

Options:
  --all            Install everything across all categories
  --all-skills     Install all skills
  --all-agents     Install all agents
  --all-rules      Install all rules
  --all-styles     Install all output-styles
  --all-hooks      Install all hooks
  --uninstall      Remove all symlinks and hook entries managed by this repo
  --list           Show what's available and what's installed
  -h, --help       Show this help

Items:
  Specific items to install, e.g.: skills/refinement hooks/my-hook

Without any flags or items, nothing is installed.
EOF
}

log() { echo "  $1"; }
ok()  { echo "  ✓ $1"; }
warn() { echo "  ⚠ $1"; }
err() { echo "  ✗ $1" >&2; }

# Check if a path is a symlink pointing into this repo
is_our_symlink() {
  local path="$1"
  [[ -L "$path" ]] && [[ "$(readlink -f "$path")" == "${SCRIPT_DIR}/"* ]]
}

# ── Symlink-based install (skills, agents, rules, output-styles) ─────────────

install_item() {
  local category="$1" name="$2"
  local src="${SCRIPT_DIR}/${category}/${name}"
  local target_dir="${CLAUDE_DIR}/${CATEGORIES[$category]}"
  local target="${target_dir}/${name}"

  if [[ ! -e "$src" ]]; then
    err "${category}/${name} not found in repo"
    return 1
  fi

  mkdir -p "$target_dir"

  if is_our_symlink "$target"; then
    log "${category}/${name} already installed (symlink up to date)"
    return 0
  fi

  if [[ -e "$target" ]] || [[ -L "$target" ]]; then
    warn "${category}/${name}: target exists and is not our symlink — skipping (remove manually to install)"
    return 1
  fi

  ln -s "$src" "$target"
  ok "${category}/${name} installed"
}

uninstall_item() {
  local category="$1" name="$2"
  local target="${CLAUDE_DIR}/${CATEGORIES[$category]}/${name}"

  if is_our_symlink "$target"; then
    rm "$target"
    ok "${category}/${name} uninstalled"
  fi
}

# ── Hook-specific install/uninstall ──────────────────────────────────────────

install_hook() {
  local name="$1"
  local hook_dir="${SCRIPT_DIR}/hooks/${name}"
  local hook_json="${hook_dir}/hook.json"

  if [[ ! -f "$hook_json" ]]; then
    err "hooks/${name}: no hook.json found"
    return 1
  fi

  # Symlink the hook directory into ~/.claude/hooks/
  install_item "hooks" "$name" || return 1

  # Find the script file (first non-json file)
  local script_file
  script_file=$(find "$hook_dir" -maxdepth 1 -type f ! -name 'hook.json' | head -1)
  if [[ -z "$script_file" ]]; then
    err "hooks/${name}: no script file found alongside hook.json"
    return 1
  fi
  local script_name
  script_name=$(basename "$script_file")

  # Build the command path pointing to the installed location
  local cmd="${CLAUDE_DIR}/hooks/${name}/${script_name}"

  # Read hook.json and build the settings entry
  local event matcher type timeout
  event=$(jq -r '.event' "$hook_json")
  matcher=$(jq -r '.matcher // empty' "$hook_json")
  type=$(jq -r '.type // "command"' "$hook_json")
  timeout=$(jq -r '.timeout // empty' "$hook_json")

  # Determine interpreter prefix based on extension
  local command_str
  case "$script_name" in
    *.sh)  command_str="bash \"${cmd}\"" ;;
    *.js)  command_str="node \"${cmd}\"" ;;
    *.py)  command_str="python3 \"${cmd}\"" ;;
    *)     command_str="\"${cmd}\"" ;;
  esac

  # Build the hook entry JSON
  local hook_entry
  hook_entry=$(jq -n \
    --arg managed "$MANAGED_BY" \
    --arg name "$name" \
    --arg type "$type" \
    --arg command "$command_str" \
    --arg matcher "$matcher" \
    --arg timeout "$timeout" \
    '{
      _managed_by: $managed,
      _hook_name: $name
    }
    + (if $matcher != "" then {matcher: $matcher} else {} end)
    + {
      hooks: [{
        type: $type,
        command: $command
      }
      + (if $timeout != "" then {timeout: ($timeout | tonumber)} else {} end)
      ]
    }')

  # Merge into settings.json
  local settings_file="${CLAUDE_DIR}/settings.json"
  if [[ ! -f "$settings_file" ]]; then
    echo '{}' > "$settings_file"
  fi

  # Backup settings.json
  cp "$settings_file" "${settings_file}.bak"

  # Remove any existing entry for this hook, then add the new one
  local updated
  updated=$(jq \
    --arg event "$event" \
    --arg name "$name" \
    --arg managed "$MANAGED_BY" \
    --argjson entry "$hook_entry" \
    '
    # Ensure hooks object and event array exist
    .hooks //= {} |
    .hooks[$event] //= [] |
    # Remove existing entries for this hook name from this manager
    .hooks[$event] = [.hooks[$event][] | select(._managed_by != $managed or ._hook_name != $name)] |
    # Append the new entry
    .hooks[$event] += [$entry]
    ' "$settings_file")

  echo "$updated" > "$settings_file"
  ok "hooks/${name} registered in settings.json (event: ${event})"
}

uninstall_hook() {
  local name="$1"
  local target="${CLAUDE_DIR}/hooks/${name}"

  # Remove symlink
  if is_our_symlink "$target"; then
    rm "$target"
    ok "hooks/${name} symlink removed"
  fi

  # Remove from settings.json
  local settings_file="${CLAUDE_DIR}/settings.json"
  if [[ -f "$settings_file" ]]; then
    local updated
    updated=$(jq \
      --arg name "$name" \
      --arg managed "$MANAGED_BY" \
      '
      if .hooks then
        .hooks |= with_entries(
          .value = [.value[] | select(._managed_by != $managed or ._hook_name != $name)] |
          select(.value | length > 0)
        )
      else . end
      ' "$settings_file")
    echo "$updated" > "$settings_file"
    ok "hooks/${name} removed from settings.json"
  fi
}

# ── Collect items in a category ──────────────────────────────────────────────

list_items() {
  local category="$1"
  local src_dir="${SCRIPT_DIR}/${category}"
  local items=()

  if [[ ! -d "$src_dir" ]]; then
    return
  fi

  for entry in "$src_dir"/*; do
    [[ -e "$entry" ]] || continue
    local name
    name=$(basename "$entry")
    [[ "$name" == ".gitkeep" ]] && continue

    # For skills, require SKILL.md; for hooks, require hook.json; others accept anything
    case "$category" in
      skills) [[ -f "$entry/SKILL.md" ]] || continue ;;
      hooks)  [[ -f "$entry/hook.json" ]] || continue ;;
    esac

    items+=("$name")
  done

  echo "${items[@]}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  local do_all=false
  local do_uninstall=false
  local do_list=false
  local -A do_category=()
  local -a specific_items=()

  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)        do_all=true ;;
      --all-skills) do_category[skills]=1 ;;
      --all-agents) do_category[agents]=1 ;;
      --all-rules)  do_category[rules]=1 ;;
      --all-styles) do_category[output-styles]=1 ;;
      --all-hooks)  do_category[hooks]=1 ;;
      --uninstall)  do_uninstall=true ;;
      --list)       do_list=true ;;
      -h|--help)    usage; exit 0 ;;
      -*)           err "Unknown option: $1"; usage; exit 1 ;;
      *)            specific_items+=("$1") ;;
    esac
    shift
  done

  # ── List mode ──
  if $do_list; then
    echo "Claude Setup — Status"
    echo "====================="
    for category in skills agents rules output-styles hooks; do
      local items
      items=$(list_items "$category")
      if [[ -z "$items" ]]; then
        echo ""
        echo "  ${category}/  (empty)"
        continue
      fi
      echo ""
      echo "  ${category}/"
      for name in $items; do
        local target="${CLAUDE_DIR}/${CATEGORIES[$category]}/${name}"
        if is_our_symlink "$target"; then
          echo "    ✓ ${name}  (installed)"
        elif [[ -e "$target" ]]; then
          echo "    ⚠ ${name}  (exists but not managed by us)"
        else
          echo "    ○ ${name}  (available)"
        fi
      done
    done
    echo ""
    return 0
  fi

  # ── Uninstall mode ──
  if $do_uninstall; then
    echo "Uninstalling claude-setup managed items..."
    for category in skills agents rules output-styles; do
      local target_dir="${CLAUDE_DIR}/${CATEGORIES[$category]}"
      [[ -d "$target_dir" ]] || continue
      for entry in "$target_dir"/*; do
        [[ -e "$entry" ]] || [[ -L "$entry" ]] || continue
        if is_our_symlink "$entry"; then
          local name
          name=$(basename "$entry")
          uninstall_item "$category" "$name"
        fi
      done
    done
    # Hooks: remove symlinks + settings.json entries
    local hooks_dir="${CLAUDE_DIR}/hooks"
    if [[ -d "$hooks_dir" ]]; then
      for entry in "$hooks_dir"/*; do
        [[ -e "$entry" ]] || [[ -L "$entry" ]] || continue
        if is_our_symlink "$entry"; then
          local name
          name=$(basename "$entry")
          uninstall_hook "$name"
        fi
      done
    fi
    # Also clean any orphaned managed entries from settings.json
    local settings_file="${CLAUDE_DIR}/settings.json"
    if [[ -f "$settings_file" ]]; then
      local updated
      updated=$(jq --arg managed "$MANAGED_BY" '
        if .hooks then
          .hooks |= with_entries(
            .value = [.value[] | select(._managed_by != $managed)] |
            select(.value | length > 0)
          )
        else . end
      ' "$settings_file")
      echo "$updated" > "$settings_file"
    fi
    echo "Done."
    return 0
  fi

  # ── Determine what to install ──
  local -a install_queue=()

  if $do_all; then
    for category in skills agents rules output-styles hooks; do
      do_category[$category]=1
    done
  fi

  # Expand category flags
  for category in "${!do_category[@]}"; do
    local items
    items=$(list_items "$category")
    for name in $items; do
      install_queue+=("${category}/${name}")
    done
  done

  # Add specific items
  install_queue+=("${specific_items[@]}")

  if [[ ${#install_queue[@]} -eq 0 ]]; then
    echo "Nothing to install. Use --all, --all-<category>, or specify items."
    echo "Run with --help for usage."
    exit 0
  fi

  # ── Install ──
  echo "Installing claude-setup items..."
  for item in "${install_queue[@]}"; do
    local category="${item%%/*}"
    local name="${item#*/}"

    if [[ -z "${CATEGORIES[$category]:-}" ]]; then
      err "Unknown category: ${category}"
      continue
    fi

    if [[ "$category" == "hooks" ]]; then
      install_hook "$name"
    else
      install_item "$category" "$name"
    fi
  done
  echo "Done."
}

main "$@"

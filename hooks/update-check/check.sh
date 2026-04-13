#!/usr/bin/env bash
# Checks if the local claude-setup repo is behind its remote.
# Discovers the repo path by resolving this script's symlink.
# Outputs JSON for Claude Code hook system.
set -euo pipefail

ok='{"continue":true}'

# Resolve the repo root from this script's symlinked location
script_path="${BASH_SOURCE[0]}"
while [[ -L "$script_path" ]]; do
  dir="$(cd "$(dirname "$script_path")" && pwd)"
  script_path="$(readlink "$script_path")"
  [[ "$script_path" != /* ]] && script_path="$dir/$script_path"
done
repo_dir="$(cd "$(dirname "$script_path")/../.." && pwd)"

# Verify this is actually a git repo
if [[ ! -d "$repo_dir/.git" ]]; then
  echo "$ok"
  exit 0
fi

cd "$repo_dir"

# Fetch quietly, ignore failures (offline, no remote, etc.)
if ! git fetch --quiet 2>/dev/null; then
  echo "$ok"
  exit 0
fi

local_head=$(git rev-parse HEAD 2>/dev/null) || { echo "$ok"; exit 0; }
remote_head=$(git rev-parse '@{upstream}' 2>/dev/null) || { echo "$ok"; exit 0; }

if [[ "$local_head" == "$remote_head" ]]; then
  echo "$ok"
  exit 0
fi

# Check if local is behind (remote has commits we don't have)
behind=$(git rev-list --count HEAD..@{upstream} 2>/dev/null) || { echo "$ok"; exit 0; }

if [[ "$behind" -gt 0 ]]; then
  msg="claude-setup is ${behind} commit(s) behind remote. Run: git -C ${repo_dir} pull"
  printf '{"continue":true,"systemMessage":"%s"}\n' "$msg"
else
  echo "$ok"
fi

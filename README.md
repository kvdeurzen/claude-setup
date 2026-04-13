# claude-setup

Personal Claude Code extensions — skills, agents, rules, output-styles, and hooks — managed from a single repo with symlink-based installation.

## Quick Start

```bash
# Install everything
./install.sh --all

# Install specific categories
./install.sh --all-skills
./install.sh --all-hooks

# Install specific items
./install.sh skills/refinement skills/confluence-db

# See what's available and installed
./install.sh --list

# Remove everything managed by this repo
./install.sh --uninstall
```

## Structure

```
skills/          → ~/.claude/skills/       (symlinked directories)
agents/          → ~/.claude/agents/       (symlinked files/directories)
rules/           → ~/.claude/rules/        (symlinked files/directories)
output-styles/   → ~/.claude/output-styles/ (symlinked files/directories)
hooks/           → ~/.claude/hooks/        (symlinked + settings.json merge)
```

## Install Flags

| Flag | Effect |
|------|--------|
| `--all` | Install everything |
| `--all-skills` | Install all skills |
| `--all-agents` | Install all agents |
| `--all-rules` | Install all rules |
| `--all-styles` | Install all output-styles |
| `--all-hooks` | Install all hooks |
| `--uninstall` | Remove all managed symlinks and hook entries |
| `--list` | Show available/installed status |

Without flags, nothing is installed — you must be explicit.

## How It Works

- **Skills, agents, rules, output-styles**: Symlinked into `~/.claude/<category>/`. Edits in the repo are immediately live.
- **Hooks**: Each hook is a directory with a `hook.json` (metadata) and a script file. The installer symlinks the directory into `~/.claude/hooks/` and merges the hook definition into `~/.claude/settings.json`. Managed entries are tagged with `_managed_by: "claude-setup"` for clean uninstall.
- The installer never overwrites existing non-symlink items — it warns and skips.
- `settings.json` is backed up to `settings.json.bak` before hook modifications.

## Adding a Hook

Create a directory under `hooks/`:

```
hooks/my-hook/
├── hook.json
└── script.sh
```

`hook.json`:
```json
{
  "event": "PreToolUse",
  "matcher": "Write|Edit",
  "type": "command",
  "timeout": 5
}
```

The `command` field is auto-generated at install time based on the script file's location and extension (`.sh` → `bash`, `.js` → `node`, `.py` → `python3`).

## Requirements

- `jq` (for hook installation/uninstall — JSON manipulation of settings.json)
- Bash 4+ (uses associative arrays)

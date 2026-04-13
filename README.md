# claude-setup

Personal Claude Code extensions — skills, agents, rules, output-styles, and hooks — managed from a single repo with symlink-based installation.

## Quick Start

**Linux / macOS:**
```bash
./install.sh --all                # Install everything
./install.sh --all-skills         # Install specific categories
./install.sh skills/refinement    # Install specific items
./install.sh --list               # See what's available and installed
./install.sh --uninstall          # Remove everything managed by this repo
```

**Windows (PowerShell):**
```powershell
.\install.ps1 -All                # Install everything
.\install.ps1 -AllSkills          # Install specific categories
.\install.ps1 skills/refinement   # Install specific items
.\install.ps1 -List               # See what's available and installed
.\install.ps1 -Uninstall          # Remove everything managed by this repo
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

## Skills

| Skill | Trigger | Description |
|-------|---------|-------------|
| [confluence-db](skills/confluence-db/) | User mentions "Confluence database" or wants to read/write a Confluence database table | Read, add, edit, and delete rows in Confluence databases via browser automation (Playwright + Firefox SSO). |
| [refinement](skills/refinement/) | User wants to create, refine, or groom work items, or mentions refinement, sprint planning, or acceptance criteria | Guided workflow for refining Epics, Features, and Stories on Azure DevOps — from context gathering through drafting to saving. |
| [release-strategy](skills/release-strategy/) | Working on release pipelines, hotfixes, rollbacks, changelogs, or conventional commit enforcement | Reference for the single-track-forward release process using git-cliff + cargo-workspaces, including hotfix and rollback procedures. |
| [rust-style-review](skills/rust-style-review/) | User asks to check Rust style compliance, audit against style guides, or produce a style improvement plan | Reviews Rust code for compliance with the Rust Style Guide, Rust API Guidelines, and Microsoft Pragmatic Rust guidelines. Runs clippy/fmt, checks against fetched guidelines, and outputs an improvement plan via plan mode. |

## Requirements

**Linux / macOS:**
- `jq` (for hook installation/uninstall — JSON manipulation of settings.json)
- Bash 4+ (uses associative arrays)

**Windows:**
- PowerShell 5.1+ (ships with Windows 10/11) or PowerShell 7+
- Developer Mode enabled (Settings > For Developers) or run as Administrator (for symlink creation)

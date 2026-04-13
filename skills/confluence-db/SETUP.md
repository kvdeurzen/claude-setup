# Setup

## One-time setup

Install uv (if not already present), create a venv, and install dependencies:

```bash
# Install uv if needed
command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh

# Create venv and install dependencies
cd ~/.claude/skills/confluence-db
uv venv .venv
uv pip install --python .venv/bin/python -r requirements.txt
.venv/bin/python -m playwright install chromium
```

## Prerequisites

- **Firefox with SSO session**: The script reads cookies from Firefox's snap cookie store at `~/snap/firefox/common/.mozilla/firefox/ztu470v4.default/cookies.sqlite`. You must have an active login session to `rocsys.atlassian.net` in Firefox.
- **Python 3.10+**: Required for the walrus operator used in the script.

## Verify setup

```bash
~/.claude/skills/confluence-db/.venv/bin/python ~/.claude/skills/confluence-db/confluence_db.py read "https://rocsys.atlassian.net/wiki/spaces/ROCX/database/1280966673" --json 2>/dev/null | head -5
```

If this returns JSON data, the setup is working.

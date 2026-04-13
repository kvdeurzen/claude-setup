---
name: confluence-db
description: Read, add rows, edit cells, and delete rows in Confluence databases. Triggers when the user explicitly mentions "Confluence database" or wants to read/write a Confluence database table. Does NOT trigger on general mentions of PRS, requirements, or Confluence pages.
---

# Confluence Database Skill

Read and write Confluence databases via browser automation. Uses Firefox SSO session cookies and Playwright.

## Prerequisites

- Script and venv are at `~/.claude/skills/confluence-db/` (see SETUP.md for installation)
- If the venv doesn't exist, run setup first: `cd ~/.claude/skills/confluence-db && uv venv .venv && uv pip install --python .venv/bin/python3 -r requirements.txt && .venv/bin/python3 -m playwright install chromium`
- Authentication is automatic: tries saved cookies, then Firefox, then Chrome. If all fail, it opens a browser for the user to log in via SSO. To force re-login: `~/.claude/skills/confluence-db/.venv/bin/python3 ~/.claude/skills/confluence-db/confluence_db.py login`

## Known Databases

| Name | URL | Schema |
|------|-----|--------|
| S2 - Product Requirement Specification (PRS) | `https://rocsys.atlassian.net/wiki/spaces/ROCX/database/1280966673` | All text fields |
| Test database | `https://rocsys.atlassian.net/wiki/spaces/~701210294fe40c28b4ec6a0081bad6ef8dd34/database/1916043284` | `{"Tag field": "tag", "User field": "user"}` |

## Schema

The `schema` parameter maps column names to field types. Supported types:
- `text` (default) — plain text
- `number` — numeric field
- `tag` — tag/label field (styled badges, autocreated)
- `user` — user picker (autocomplete from Confluence users)
- `date` — date picker (accepts ISO `YYYY-MM-DD` format, e.g. `2026-04-13`)
- `entry_link` — link to another entry in the same database (selects from dropdown, replaces existing links)

Columns not listed in the schema default to `text`. Only specify non-text columns.

## Operations

### Read all rows

```bash
~/.claude/skills/confluence-db/.venv/bin/python ~/.claude/skills/confluence-db/confluence_db.py read "<URL>" --json
```

Returns JSON array of row dicts. Use this to import database contents for reasoning.

### Add a row (requires user confirmation)

```bash
~/.claude/skills/confluence-db/.venv/bin/python ~/.claude/skills/confluence-db/confluence_db.py add "<URL>" \
  "Column1=value1" "Column2=value2" \
  --type "TagCol:tag" "UserCol:user"
```

### Edit a cell (requires user confirmation)

```bash
~/.claude/skills/confluence-db/.venv/bin/python ~/.claude/skills/confluence-db/confluence_db.py edit "<URL>" \
  <ROW_INDEX> "Column=new value" \
  --type "TagCol:tag" "UserCol:user"
```

Row index is 0-based.

### Delete rows (requires user confirmation)

```bash
~/.claude/skills/confluence-db/.venv/bin/python ~/.claude/skills/confluence-db/confluence_db.py delete "<URL>" <ROW_INDEX> [ROW_INDEX2 ...]
```

## Important Rules

1. **ALWAYS ask the user for the database URL** if they haven't provided one. Do NOT guess or assume a URL from the known databases table — let the user specify which database they want to work with.
2. **ALWAYS read the database first** before suggesting edits, so you understand the current state and column names.
3. **NEVER execute add, edit, or delete without explicit user confirmation.** Before any write operation:
   - Show the user exactly what will be changed (which row, which columns, old value -> new value)
   - Ask "Should I proceed?" and wait for confirmation
   - Only execute after the user says yes
4. **Column names must match exactly** (case-sensitive) as they appear in the database.
5. **Row indices are 0-based** — row 1 in the UI is index 0.
6. **Multi-value fields** — tag, user, and entry_link support comma-separated multiple values:
   - Tags: `"Tag field=tag1,tag2,tag3"`
   - Users: `"User field=Kanter,Dies"` (each name is autocompleted separately)
   - Entry links: `"Link field=entry1,entry2"` (each is selected from dropdown)
8. **Network can be flaky** — if a command fails with a timeout, retry once before reporting failure.
9. **Each command opens a fresh browser** — operations are independent and stateless.

## Workflow Example

User: "Add a requirement P99.1 to the PRS database for a new safety feature"

1. First, read the database to understand columns and current state:
   ```bash
   ~/.claude/skills/confluence-db/.venv/bin/python ~/.claude/skills/confluence-db/confluence_db.py read "https://rocsys.atlassian.net/wiki/spaces/ROCX/database/1280966673" --json
   ```

2. Show the user what you plan to add:
   > I'll add a new row with:
   > - PRS ID: P99.1
   > - Category: Safety
   > - Description: New safety feature
   > - ...
   >
   > Should I proceed?

3. Only after user confirms:
   ```bash
   ~/.claude/skills/confluence-db/.venv/bin/python ~/.claude/skills/confluence-db/confluence_db.py add "https://rocsys.atlassian.net/wiki/spaces/ROCX/database/1280966673" \
     "PRS ID=P99.1" "Category=Safety" "Description=New safety feature"
   ```

4. Read back to verify the change was applied correctly.

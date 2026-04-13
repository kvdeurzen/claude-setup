"""Confluence Database read/write library.

Provides programmatic access to Confluence databases via browser automation.
Uses Firefox session cookies (SSO) and Playwright for headless browser control.

Usage as library:
    from confluence_db import ConfluenceDB

    db = ConfluenceDB("https://rocsys.atlassian.net/wiki/spaces/ROCX/database/1280966673")
    rows = db.read()
    db.add_row({"PRS ID": "P99.1", "Category": "Test", "Description": "New req"})
    db.edit_cell(0, "Description", "Updated description")
    db.delete_rows([5, 6])
    db.close()

Usage as CLI:
    python confluence_db.py read <url> [--json] [--csv]
    python confluence_db.py add <url> <col1>=<val1> <col2>=<val2> ...
    python confluence_db.py edit <url> <row> <col>=<val> ...
    python confluence_db.py delete <url> <row1> [row2 ...]

Requires: playwright (uv pip install playwright && uv run playwright install chromium)
"""

import csv
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time

# Known Firefox cookie DB locations (tried in order)
_FIREFOX_COOKIE_PATHS = [
    "~/snap/firefox/common/.mozilla/firefox/*/cookies.sqlite",
    "~/.mozilla/firefox/*/cookies.sqlite",
]

# Known Chrome/Chromium cookie DB locations (tried in order)
_CHROME_COOKIE_PATHS = [
    "~/snap/chromium/common/chromium/Default/Cookies",
    "~/.config/google-chrome/Default/Cookies",
    "~/.config/chromium/Default/Cookies",
]

# How many backspaces to send when clearing a cell
_CLEAR_BACKSPACES = 200


def _find_firefox_db():
    """Find the Firefox cookies.sqlite file."""
    import glob

    for pattern in _FIREFOX_COOKIE_PATHS:
        matches = glob.glob(os.path.expanduser(pattern))
        if matches:
            # Pick the most recently modified one
            return max(matches, key=os.path.getmtime)
    return None


def _find_chrome_db():
    """Find the Chrome/Chromium Cookies file."""
    for path in _CHROME_COOKIE_PATHS:
        expanded = os.path.expanduser(path)
        if os.path.exists(expanded):
            return expanded
    return None


def _get_firefox_cookies(db_path, domain):
    """Extract cookies from a Firefox cookies.sqlite."""
    tmp = tempfile.mktemp(suffix=".sqlite")
    shutil.copy2(db_path, tmp)
    conn = sqlite3.connect(tmp)
    cur = conn.cursor()
    cur.execute(
        "SELECT name, value, host, path, isSecure, expiry FROM moz_cookies "
        "WHERE host LIKE ?",
        (f"%{domain}%",),
    )
    cookies = []
    for name, value, host, path, secure, expiry in cur.fetchall():
        cookies.append(
            {
                "name": name,
                "value": value,
                "domain": host,
                "path": path,
                "secure": bool(secure),
                "expires": int(expiry / 1000) if expiry and expiry > 0 else -1,
            }
        )
    conn.close()
    os.unlink(tmp)
    return cookies


def _get_chrome_cookies(db_path, domain):
    """Extract cookies from a Chrome/Chromium Cookies DB.

    Chrome encrypts cookie values on Linux. This attempts decryption
    using the Chromium Safe Storage key from the system keyring.
    Falls back to the default 'peanuts' password.
    """
    tmp = tempfile.mktemp(suffix=".sqlite")
    shutil.copy2(db_path, tmp)
    conn = sqlite3.connect(tmp)
    cur = conn.cursor()
    cur.execute(
        "SELECT name, encrypted_value, value, host_key, path, is_secure, "
        "expires_utc FROM cookies WHERE host_key LIKE ?",
        (f"%{domain}%",),
    )

    # Try to get decryption key
    key = None
    try:
        from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.ciphers import (
            Cipher,
            algorithms,
            modes,
        )

        # Try gnome-keyring first
        password = b"peanuts"
        try:
            import secretstorage

            bus = secretstorage.dbus_init()
            collection = secretstorage.get_default_collection(bus)
            for item in collection.get_all_items():
                label = item.get_label()
                if "Chromium Safe Storage" == label or "Chrome Safe Storage" == label:
                    password = item.get_secret()
                    break
        except Exception:
            pass

        kdf = PBKDF2HMAC(
            algorithm=hashes.SHA1(), length=16, salt=b"saltysalt", iterations=1
        )
        key = kdf.derive(password)
    except ImportError:
        pass

    cookies = []
    for name, enc_val, plain_val, host, path, secure, expires in cur.fetchall():
        value = plain_val
        if not value and enc_val and key:
            try:
                enc_data = enc_val[3:]  # Strip v10/v11 prefix
                iv = b" " * 16
                cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
                decryptor = cipher.decryptor()
                decrypted = decryptor.update(enc_data) + decryptor.finalize()
                pad_len = decrypted[-1]
                if 0 < pad_len <= 16:
                    decrypted = decrypted[:-pad_len]
                value = decrypted.decode("utf-8", errors="replace")
            except Exception:
                continue
        if value:
            # Chrome expires_utc is microseconds since 1601-01-01
            # Convert to unix seconds
            expires_unix = (
                int((expires - 11644473600000000) / 1000000)
                if expires > 0
                else -1
            )
            cookies.append(
                {
                    "name": name,
                    "value": value,
                    "domain": host,
                    "path": path,
                    "secure": bool(secure),
                    "expires": expires_unix,
                }
            )
    conn.close()
    os.unlink(tmp)
    return cookies


_SAVED_COOKIES_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), ".cookies.json"
)

_LOGIN_URL = "https://rocsys.atlassian.net/wiki"


def _has_session_cookie(cookies):
    """Check if cookies include a valid session token."""
    session_names = {"tenant.session.token", "cloud.session.token"}
    return any(c["name"] in session_names for c in cookies)


def _save_cookies(cookies):
    """Save cookies to a JSON file for reuse."""
    with open(_SAVED_COOKIES_PATH, "w") as f:
        json.dump(cookies, f)


def _load_saved_cookies():
    """Load previously saved cookies from disk."""
    if not os.path.exists(_SAVED_COOKIES_PATH):
        return []
    try:
        with open(_SAVED_COOKIES_PATH) as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return []


def login():
    """Open a browser window for the user to log in via SSO.

    After login completes, saves cookies to disk for future use.
    """
    from playwright.sync_api import sync_playwright

    print("Opening browser for Confluence login...", file=sys.stderr)
    print("Please log in via SSO. The window will close automatically.", file=sys.stderr)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False)
        context = browser.new_context()
        page = context.new_page()
        page.goto(_LOGIN_URL)

        # Wait for the user to complete login — detected when
        # tenant.session.token appears in cookies
        print("Waiting for login to complete...", file=sys.stderr)
        while True:
            time.sleep(2)
            cookies = context.cookies()
            if _has_session_cookie(cookies):
                break
            # Also check if the page URL indicates successful login
            if "/wiki/spaces" in page.url or "/wiki/home" in page.url:
                cookies = context.cookies()
                break

        # Normalize cookies for Playwright's add_cookies format
        saved = []
        for c in cookies:
            saved.append({
                "name": c["name"],
                "value": c["value"],
                "domain": c["domain"],
                "path": c["path"],
                "secure": c.get("secure", False),
                "expires": c.get("expires", -1),
            })

        _save_cookies(saved)
        print(f"Login successful. Cookies saved to {_SAVED_COOKIES_PATH}", file=sys.stderr)
        browser.close()

    return saved


def _load_cookies():
    """Load cookies, trying saved cookies, Firefox, Chrome, then interactive login.

    Only considers cookies valid if they contain a session token.
    """
    domains = ["rocsys.atlassian.net", "atlassian.com", "atlassian.net"]

    # 1. Try saved cookies from a previous login
    cookies = _load_saved_cookies()
    if _has_session_cookie(cookies):
        return cookies

    # 2. Try Firefox (unencrypted, most reliable)
    cookies = []
    ff_db = _find_firefox_db()
    if ff_db:
        for domain in domains:
            cookies += _get_firefox_cookies(ff_db, domain)

    if _has_session_cookie(cookies):
        seen = set()
        return [
            c for c in cookies
            if (k := (c["name"], c["domain"], c["path"])) not in seen
            and not seen.add(k)
        ]

    # 3. Try Chrome/Chromium
    cookies = []
    chrome_db = _find_chrome_db()
    if chrome_db:
        for domain in domains:
            cookies += _get_chrome_cookies(chrome_db, domain)

    if _has_session_cookie(cookies):
        seen = set()
        return [
            c for c in cookies
            if (k := (c["name"], c["domain"], c["path"])) not in seen
            and not seen.add(k)
        ]

    # 4. Interactive login as last resort
    print(
        "No valid session found in saved cookies, Firefox, or Chrome.",
        file=sys.stderr,
    )
    cookies = login()
    if not _has_session_cookie(cookies):
        print("Error: Login did not produce a valid session.", file=sys.stderr)
        sys.exit(1)

    # Deduplicate
    seen = set()
    return [
        c
        for c in cookies
        if (k := (c["name"], c["domain"], c["path"])) not in seen
        and not seen.add(k)
    ]


class ConfluenceDB:
    """Interface to a single Confluence database.

    Args:
        url: Confluence database URL
        headless: Run browser headlessly
        schema: Optional dict mapping column names to field types.
                 Supported types: "text" (default), "tag", "user".
                 Example: {"Category": "tag", "Assignee": "user"}
                 Columns not in the schema default to "text".
    """

    def __init__(self, url, headless=True, schema=None):
        from playwright.sync_api import sync_playwright

        self._url = url
        self._schema = schema or {}
        self._pw = sync_playwright().start()
        self._browser = self._pw.chromium.launch(headless=headless)
        self._context = self._browser.new_context()
        self._context.add_cookies(_load_cookies())
        self._page = self._context.new_page()
        self._iframe = None
        self._columns = []
        self._load()

    def _load(self):
        """Navigate to the database and wait for it to render."""
        self._page.goto(
            self._url, wait_until="domcontentloaded", timeout=90000
        )
        iframe_el = self._page.wait_for_selector(
            'iframe[title="database-frame"]', timeout=60000
        )
        self._iframe = iframe_el.content_frame()
        try:
            self._iframe.wait_for_selector(
                '[role="grid"], [role="table"], table, '
                '[data-testid="database-grid"]',
                timeout=30000,
            )
        except Exception:
            pass
        time.sleep(5)
        self._read_columns()

    def _read_columns(self):
        """Read column names from the table header."""
        headers = self._iframe.query_selector_all(
            'th[data-testid="table-layout-header-cell"]'
        )
        self._columns = [
            (h.inner_text() or "").strip() for h in headers
        ]

    def _get_cells(self):
        return self._iframe.query_selector_all(
            '[data-testid="database-cell"]'
        )

    def _row_count(self):
        cells = self._get_cells()
        if not self._columns:
            return 0
        return len(cells) // len(self._columns)

    def _cell(self, row, col):
        """Get a cell element by row index and column index."""
        cells = self._get_cells()
        idx = row * len(self._columns) + col
        if idx >= len(cells):
            return None
        return cells[idx]

    def _col_index(self, name):
        """Get column index by name."""
        for i, c in enumerate(self._columns):
            if c.lower() == name.lower():
                return i
        raise ValueError(
            f"Column {name!r} not found. Available: {self._columns}"
        )

    def _click_more_actions(self):
        """Click the page-header 'More actions' button."""
        for btn in self._page.query_selector_all("button"):
            box = btn.bounding_box()
            text = (btn.inner_text() or "").strip()
            if (
                box
                and box["y"] > 50
                and box["y"] < 110
                and box["x"] > 1000
                and "more action" in text.lower()
            ):
                btn.click()
                time.sleep(1)
                return True
        return False

    # ── Read ──────────────────────────────────────────────────────────

    def read(self):
        """Export the database as a list of dicts via CSV export."""
        if not self._click_more_actions():
            raise RuntimeError("Could not find 'More actions' button")

        # Click Export
        for item in self._page.query_selector_all('[role="menuitem"]'):
            if "export" in (item.inner_text() or "").strip().lower():
                item.click()
                time.sleep(1)
                break
        else:
            raise RuntimeError("No 'Export' menu item")

        # CSV is default. Click Export button in the dialog.
        download_dir = tempfile.mkdtemp()
        with self._page.expect_download(timeout=30000) as dl_info:
            for ctx in [self._iframe, self._page]:
                for btn in ctx.query_selector_all("button"):
                    if (btn.inner_text() or "").strip().lower() == "export":
                        btn.click()
                        break
                else:
                    continue
                break

        download = dl_info.value
        csv_path = os.path.join(download_dir, "export.csv")
        download.save_as(csv_path)

        with open(csv_path) as f:
            content = f.read()
        os.unlink(csv_path)
        os.rmdir(download_dir)

        # Parse CSV
        if content.startswith("\ufeff"):
            content = content[1:]
        reader = csv.DictReader(content.strip().splitlines())
        rows = list(reader)

        # Refresh column list from CSV headers
        if rows:
            self._columns = list(rows[0].keys())

        return rows

    # ── Write: edit a cell ────────────────────────────────────────────

    def _clear_text_cell(self, cell_el):
        """Clear a text cell's content by End + repeated Backspace."""
        # First click to select the cell
        cell_el.click()
        time.sleep(0.5)
        # Second click to enter edit mode
        cell_el.click()
        time.sleep(0.5)
        self._page.keyboard.press("End")
        time.sleep(0.2)
        for _ in range(_CLEAR_BACKSPACES):
            self._page.keyboard.press("Backspace")
        time.sleep(0.3)

    def _type_text(self, value):
        """Type a text value into the currently focused cell."""
        self._page.keyboard.insert_text(value)
        time.sleep(0.3)

    def _type_tag(self, value):
        """Type a tag value and confirm it."""
        if not value:
            return
        # Tags can be comma-separated
        tags = [t.strip() for t in value.split(",") if t.strip()]
        for tag in tags:
            # Use type() not insert_text() — tag picker needs keydown events
            self._page.keyboard.type(tag, delay=50)
            time.sleep(0.5)
            self._page.keyboard.press("Enter")
            time.sleep(0.5)

    def _type_user(self, value):
        """Type user name(s) and select from autocomplete.

        Supports comma-separated values for multiple users,
        e.g. "Kanter,Dies" will add both users.
        """
        if not value:
            return
        users = [u.strip() for u in value.split(",") if u.strip()]
        for user in users:
            # Use type() not insert_text() — user picker needs keydown events
            self._page.keyboard.type(user, delay=50)
            time.sleep(2)  # Wait for autocomplete
            options = self._iframe.query_selector_all('[role="option"]')
            if options:
                options[0].click()
                time.sleep(1)
            else:
                self._page.keyboard.press("Enter")
                time.sleep(0.3)

    def _type_number(self, value):
        """Type a number into a number cell. Accepts int/float strings."""
        if not value:
            return
        self._page.keyboard.insert_text(str(value))
        time.sleep(0.3)

    def _type_date(self, value):
        """Type a date into a date cell.

        The date picker has a text input that accepts DD/MM/YYYY format.
        We accept ISO format (YYYY-MM-DD) and convert.
        """
        if not value:
            return
        # Convert ISO date to DD/MM/YYYY for the Confluence date picker
        date_str = value.strip()
        if len(date_str) == 10 and date_str[4] == "-":
            # YYYY-MM-DD -> DD/MM/YYYY
            parts = date_str.split("-")
            date_str = f"{parts[2]}/{parts[1]}/{parts[0]}"

        # The date picker opens a combobox input — find and fill it
        date_input = self._iframe.query_selector(
            'input[role="combobox"][type="text"]'
        )
        if date_input:
            date_input.click()
            time.sleep(0.3)
            date_input.fill("")
            time.sleep(0.2)
            date_input.fill(date_str)
            time.sleep(0.5)
            self._page.keyboard.press("Enter")
            time.sleep(0.5)
        else:
            # Fallback: type directly
            self._page.keyboard.type(date_str, delay=50)
            time.sleep(0.5)
            self._page.keyboard.press("Enter")
            time.sleep(0.3)

    def _select_entry_link_option(self, name):
        """Type a name in the entry link search and click the match."""
        search_input = self._iframe.query_selector(
            'input[role="combobox"][type="text"]'
        )
        if search_input:
            search_input.click()
            time.sleep(0.3)
            self._page.keyboard.type(name, delay=50)
            time.sleep(1)

        options = self._iframe.query_selector_all(
            '[role="listbox"] > *'
        )
        for opt in options:
            try:
                opt_text = (opt.inner_text() or "").strip()
            except Exception:
                continue
            if opt_text.lower() == name.lower():
                opt.click()
                time.sleep(0.5)
                return
        # Fallback: click first option
        if options:
            try:
                options[0].click()
                time.sleep(0.5)
            except Exception:
                pass

    def _type_entry_link(self, value):
        """Select entry link(s) from the dropdown.

        Supports comma-separated values for multiple links,
        e.g. "klaar,ne" will link to both entries.
        Existing entries have a remove button with data-testid="entry-link-remove-button".
        """
        if not value:
            return

        # Remove all existing entry links by clicking their X buttons
        for _ in range(20):
            remove_btn = self._iframe.query_selector(
                '[data-testid="entry-link-remove-button"]'
            )
            if not remove_btn:
                break
            remove_btn.click()
            time.sleep(0.5)

        # Select each entry link
        entries = [e.strip() for e in value.split(",") if e.strip()]
        for entry in entries:
            self._select_entry_link_option(entry)

    def _field_type(self, column_name):
        """Get field type from schema, defaulting to 'text'."""
        return self._schema.get(column_name, "text")

    def _set_cell_value(self, cell_el, value, field_type="text"):
        """Set a cell's value, handling different field types."""
        if field_type == "text":
            self._clear_text_cell(cell_el)
            self._type_text(value)
        elif field_type == "number":
            # Number field works like text — clear and type
            self._clear_text_cell(cell_el)
            self._type_number(value)
        elif field_type == "tag":
            # Double-click to open tag editor
            cell_el.dblclick()
            time.sleep(1)
            # Clear existing tags
            self._page.keyboard.press("Control+a")
            time.sleep(0.2)
            self._page.keyboard.press("Backspace")
            time.sleep(0.5)
            self._type_tag(value)
        elif field_type == "user":
            # Double-click to open user picker
            cell_el.dblclick()
            time.sleep(1)
            # Clear existing user
            self._page.keyboard.press("Control+a")
            time.sleep(0.2)
            self._page.keyboard.press("Backspace")
            time.sleep(0.5)
            self._type_user(value)
        elif field_type == "date":
            # Click to open date picker, then type into input
            cell_el.dblclick()
            time.sleep(1)
            self._type_date(value)
        elif field_type == "entry_link":
            # Two clicks (not dblclick) to open entry link dropdown
            cell_el.click()
            time.sleep(0.5)
            cell_el.click()
            time.sleep(1)
            self._type_entry_link(value)
        self._page.keyboard.press("Escape")
        time.sleep(0.5)

    def edit_cell(self, row, column, value):
        """Edit a single cell by row index (0-based) and column name."""
        col_idx = self._col_index(column)
        field_type = self._field_type(column)
        cell_el = self._cell(row, col_idx)
        if not cell_el:
            raise IndexError(
                f"Cell at row={row}, col={column!r} not found"
            )
        self._set_cell_value(cell_el, value, field_type)

    def edit_row(self, row, data):
        """Edit multiple cells in a row. data is a dict of {column: value}."""
        for column, value in data.items():
            self.edit_cell(row, column, value)

    # ── Write: add a row ──────────────────────────────────────────────

    def add_row(self, data):
        """Add a new row. data is a dict of {column_name: value}."""
        add_btn = self._iframe.query_selector(
            '[data-testid="table-layout-add-entry"]'
        )
        if not add_btn:
            raise RuntimeError("Could not find 'Add entry' button")
        add_btn.click()
        time.sleep(2)

        # The new row is the last row
        new_row = self._row_count() - 1

        for column, value in data.items():
            if not value:
                continue
            col_idx = self._col_index(column)
            field_type = self._field_type(column)
            cell_el = self._cell(new_row, col_idx)
            if cell_el:
                self._set_cell_value(cell_el, str(value), field_type)

    # ── Write: delete rows ────────────────────────────────────────────

    def delete_rows(self, row_indices):
        """Delete rows by index (0-based). Deletes from bottom to top."""
        if not row_indices:
            return

        # Sort descending so indices don't shift as we delete
        for row in sorted(row_indices, reverse=True):
            # Click the row number cell to select the row
            row_cells = self._iframe.query_selector_all(
                "tr td:first-child"
            )
            if row < len(row_cells):
                row_cells[row].click()
                time.sleep(0.5)

                delete_btn = self._iframe.query_selector(
                    '[data-testid="delete-entry-entry-action"]'
                )
                if delete_btn:
                    delete_btn.click()
                    time.sleep(1)
                    # Handle confirmation
                    for btn in self._iframe.query_selector_all("button"):
                        text = (btn.inner_text() or "").strip()
                        if text.lower() in ("delete", "confirm"):
                            btn.click()
                            time.sleep(1)
                            break
                    time.sleep(1)

    # ── Lifecycle ─────────────────────────────────────────────────────

    def close(self):
        """Close the browser."""
        self._browser.close()
        self._pw.stop()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    @property
    def columns(self):
        return list(self._columns)


# ── CLI ───────────────────────────────────────────────────────────────

def _cli_read(args):
    with ConfluenceDB(args.url) as db:
        rows = db.read()
        if args.json:
            print(json.dumps(rows, indent=2))
        elif args.csv:
            if rows:
                writer = csv.DictWriter(
                    sys.stdout, fieldnames=list(rows[0].keys())
                )
                writer.writeheader()
                writer.writerows(rows)
        else:
            if not rows:
                print("No rows.")
                return
            cols = list(rows[0].keys())
            widths = {
                c: min(
                    60,
                    max(len(c), max(len(str(r.get(c, ""))) for r in rows)),
                )
                for c in cols
            }
            print(
                " | ".join(c.ljust(widths[c])[:widths[c]] for c in cols)
            )
            print("-+-".join("-" * widths[c] for c in cols))
            for row in rows:
                print(
                    " | ".join(
                        str(row.get(c, "")).ljust(widths[c])[:widths[c]]
                        for c in cols
                    )
                )
            print(f"\nTotal: {len(rows)} rows")


def _parse_schema(type_args):
    """Parse --type col:type pairs into a schema dict."""
    schema = {}
    if type_args:
        for t in type_args:
            if ":" not in t:
                print(f"Error: expected col:type, got {t!r}", file=sys.stderr)
                sys.exit(1)
            col, _, ftype = t.partition(":")
            if ftype not in ("text", "tag", "user", "number", "date", "entry_link"):
                print(f"Error: unknown type {ftype!r} (use text/tag/user/number/date/entry_link)", file=sys.stderr)
                sys.exit(1)
            schema[col] = ftype
    return schema


def _cli_add(args):
    data = {}
    for kv in args.values:
        if "=" not in kv:
            print(f"Error: expected col=value, got {kv!r}", file=sys.stderr)
            sys.exit(1)
        k, _, v = kv.partition("=")
        data[k] = v
    schema = _parse_schema(args.type)
    with ConfluenceDB(args.url, schema=schema) as db:
        db.add_row(data)
        print("Row added.", file=sys.stderr)


def _cli_edit(args):
    data = {}
    for kv in args.values:
        if "=" not in kv:
            print(f"Error: expected col=value, got {kv!r}", file=sys.stderr)
            sys.exit(1)
        k, _, v = kv.partition("=")
        data[k] = v
    schema = _parse_schema(args.type)
    with ConfluenceDB(args.url, schema=schema) as db:
        db.edit_row(args.row, data)
        print(f"Row {args.row} updated.", file=sys.stderr)


def _cli_delete(args):
    with ConfluenceDB(args.url) as db:
        db.delete_rows(args.rows)
        print(f"Deleted {len(args.rows)} row(s).", file=sys.stderr)


def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Confluence Database read/write tool"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # read
    p_read = sub.add_parser("read", help="Read all rows")
    p_read.add_argument("url", help="Database URL")
    p_read.add_argument("--json", action="store_true")
    p_read.add_argument("--csv", action="store_true")

    # add
    p_add = sub.add_parser("add", help="Add a row")
    p_add.add_argument("url", help="Database URL")
    p_add.add_argument("values", nargs="+", help="col=value pairs")
    p_add.add_argument("--type", "-t", nargs="+", help="col:type pairs (text/tag/user)")

    # edit
    p_edit = sub.add_parser("edit", help="Edit a row")
    p_edit.add_argument("url", help="Database URL")
    p_edit.add_argument("row", type=int, help="Row index (0-based)")
    p_edit.add_argument("values", nargs="+", help="col=value pairs")
    p_edit.add_argument("--type", "-t", nargs="+", help="col:type pairs (text/tag/user)")

    # delete
    p_del = sub.add_parser("delete", help="Delete rows")
    p_del.add_argument("url", help="Database URL")
    p_del.add_argument("rows", type=int, nargs="+", help="Row indices")

    # login
    sub.add_parser("login", help="Log in via SSO (opens browser)")

    args = parser.parse_args()
    if args.command == "login":
        login()
    else:
        {"read": _cli_read, "add": _cli_add, "edit": _cli_edit, "delete": _cli_delete}[
            args.command
        ](args)


if __name__ == "__main__":
    main()

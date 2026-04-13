---
name: rust-style-review
description: "Reviews a Rust codebase for compliance with the Rust Style Guide, Rust API Guidelines, and Microsoft Pragmatic Rust guidelines, then produces an actionable improvement plan. Triggers when the user asks to check Rust style compliance, audit a Rust crate against style guides, or produce a Rust style improvement plan."
---

# Rust Style Review Skill

Review a Rust codebase for compliance with the Rust Style Guide, the Rust API Guidelines, and the Microsoft Pragmatic Rust guidelines. Runs automated tooling (clippy, fmt), fetches the latest guidelines from their canonical sources, checks the code against them, and produces a prioritized improvement plan in Claude Code plan mode.

## When to Use

- Reviewing a Rust workspace, crate, or module for style and API quality
- Auditing public API surface against Rust ecosystem conventions
- Preparing a crate for publication or team handoff
- Producing a structured improvement plan from review findings

**Not for:** Writing new Rust code, fixing bugs, performance profiling, or security auditing beyond basic `unsafe` review.

## Important Rules

⚠️ **Never auto-fix code.** This skill produces a plan. It does not edit source files. The user executes the plan afterward (manually or via plan mode execution).

⚠️ **Always run Phase 1 (Scope) first.** Never review the entire workspace without confirming scope with the user. Large workspaces can have dozens of crates — reviewing all of them wastes time if the user only cares about one.

⚠️ **Automated checks (Phase 2) must complete before manual review (Phase 4).** Clippy and fmt findings are inputs to the manual review — they prevent duplicate effort and help prioritize.

⚠️ **Never report a guideline violation without citing the specific file and line range.** Vague findings like "some types are missing Debug" are not actionable. Always provide the path, the type/function name, and what to change.

⚠️ **The plan (Phase 5) must be generated using plan mode.** Do not output the plan as a chat message. Enter plan mode so the plan is a standard Claude Code plan file the user can execute.

## Phase 1: Scope

Determine what to review. Ask the user or infer from their message.

1. Identify the workspace root. Look for `Cargo.toml` with `[workspace]` in the current directory or project root. If no workspace, look for a single-crate `Cargo.toml`.
2. List all workspace members:
   ```bash
   cargo metadata --no-deps --format-version=1 | jq -r '.packages[] | "\(.name) — \(.manifest_path)"'
   ```
3. Ask the user to confirm scope: entire workspace, specific crates, specific modules, or specific files. If the user already specified scope in their request, confirm it and proceed.
4. Record the scope for subsequent phases. Use absolute paths throughout.

If no `Cargo.toml` is found, stop and tell the user this skill requires a Rust project.

## Phase 2: Automated Checks

Run tooling against the scoped code. Capture output for analysis.

**Step 1 — Format check:**
```bash
cargo fmt --check 2>&1
```
If scoped to specific crates: `cargo fmt --check -p <crate> 2>&1` for each.

**Step 2 — Clippy (standard):**
```bash
cargo clippy --workspace -- -D warnings 2>&1
```
If scoped: `cargo clippy -p <crate> -- -D warnings 2>&1`.

**Step 3 — Clippy (pedantic, advisory):**
```bash
cargo clippy --workspace -- -W clippy::pedantic 2>&1
```
Pedantic findings are advisory — flag them separately from hard warnings.

**Step 4 — Summarize:** Present a summary table to the user before proceeding:

| Category | Count |
|----------|-------|
| Formatting | N files |
| Clippy errors | N |
| Clippy warnings | N |
| Clippy pedantic (advisory) | N |

If a command fails to run (e.g., clippy not installed, compilation errors), report the failure and proceed with a note that automated checks were incomplete.

## Phase 3: Load Guidelines

Fetch the latest guidelines from their canonical sources. Do not rely on embedded or memorized versions — the guidelines may change.

1. **Rust Style Guide:** Fetch from `https://doc.rust-lang.org/style-guide/`
2. **Rust API Guidelines checklist:** Fetch from `https://rust-lang.github.io/api-guidelines/checklist.html`
3. **Microsoft Pragmatic Rust Guidelines checklist:** Fetch from `https://microsoft.github.io/rust-guidelines/guidelines/checklist/index.html`

Use `WebFetch` to retrieve both in parallel. If a fetch fails, warn the user and continue with whichever succeeded. If both fail, inform the user and skip to Phase 5 with only automated findings.

Parse the fetched checklists into concrete review criteria for Phase 4.

## Phase 4: Manual Review

Read the scoped code using Glob, Read, and Grep. Review against the guidelines fetched in Phase 3.

Focus on areas that automated tools cannot check. The guidelines typically organize into categories like these (but defer to whatever the fetched checklists actually contain):

1. **Naming & Semantics** — Type/function naming conventions, conversion method patterns (`as_`/`to_`/`into_`), iterator method names
2. **API Surface** — `Debug`/`Display` on public types, type genericity choices, `Clone` on service types, parameter acceptance patterns
3. **Error Handling** — Panic semantics (bugs only), `#[expect]` vs `#[allow]`, error type design
4. **Documentation** — Doc comment presence and quality, module docs, canonical sections, magic value documentation
5. **Type Design** — `Send`/`Sync` guarantees, builder patterns, smart pointer exposure, glob re-exports, statics
6. **Safety** — `unsafe` block justification (`// SAFETY:` comments), `unsafe fn` documentation (`# Safety` sections)
7. **Testability** — I/O abstraction for mocking, feature-gated test utilities, parallel-safe test design
8. **Performance** — Structured logging, yield points in async loops

For each finding, record:
- File path and line range
- The specific guideline violated (with source: "Rust API Guidelines C-DEBUG" or "Microsoft Pragmatic Rust: error types as structs")
- Severity: **error** (unsound, breaks conventions severely), **warning** (should fix, doesn't break anything), or **suggestion** (pedantic/stylistic)
- One-sentence description of the fix

## Phase 5: Plan Generation

Enter plan mode using `EnterPlanMode` and write the improvement plan as a standard Claude Code plan file.

Structure the plan as follows:

**Title:** `Rust review: <crate/workspace name>`

**Summary:** 2–3 sentences on overall codebase health, scope reviewed, and top-level categories.

**Findings grouped by severity, then by category:**
- **Error** — Unsound `unsafe`, compilation warnings, severe convention violations
- **Warning** — Missing `Debug` impls, `#[allow]` instead of `#[expect]`, missing docs
- **Suggestion** — Pedantic clippy findings, style preferences, documentation improvements

Each finding is an actionable task:
- [ ] File path and line range
- What is wrong (one sentence)
- What to do (one sentence)

**Automated fixes section at the end:**
```bash
# Fix all formatting
cargo fmt

# Auto-fix applicable clippy lints
cargo clippy --fix --allow-dirty
```

## Conversation Style

- Be direct. No praise, no hedging.
- Present findings as facts, not opinions. Cite the guideline source.
- If the codebase is clean, say so briefly. Do not invent findings to justify the review.
- If a guideline conflicts with the project's apparent conventions, note it as a suggestion and mention the tradeoff.

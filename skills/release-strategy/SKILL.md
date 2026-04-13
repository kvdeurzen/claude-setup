---
name: release-strategy
description: Use when working on release pipelines, hotfixes, rollbacks, changelogs, branch protection, or conventional commit enforcement in repositories using git-cliff and cargo-workspaces with a single-track-forward release model
---

# Release Strategy

## Overview

Reference for our release process: single track forward, conventional commits, auto-release PRs via git-cliff + cargo-workspaces. Covers the full lifecycle including hotfixes, rollbacks, and enforcement.

**Canonical source:** [Standardizing Release process for services](https://rocsys.atlassian.net/wiki/spaces/SOF/pages/1094647809/) and [RFC-55](https://rocsys.atlassian.net/wiki/spaces/SOF/pages/755662858/)

## When to Use

- Creating or modifying CI release pipelines
- Handling an urgent production fix (hotfix flow)
- Rolling back a bad release
- Configuring changelog generation or dependency tracking
- Setting up branch protection or commit enforcement
- Debugging why a release PR wasn't generated or looks wrong

**Not for:** General git workflow questions, feature branching strategy, or deployment infrastructure.

## Quick Reference

| Scenario | Action |
|----------|--------|
| Normal release | Merge PR to `main` → CI creates `chore: release vX.Y.Z` PR → review & merge → tag → deploy |
| Urgent fix, `main` has moved ahead | Hotfix from tag (see Hotfix below) |
| Bad release, previous version good | Redeploy previous tag |
| Bad release, fix is obvious | Hotfix forward |
| Bad release, cause unclear | Redeploy previous tag, then investigate |
| Multiple PRs merged before release PR merged | Release PR accumulates — CI updates the existing open PR |

## Hotfix Procedure

Branch from the **release tag**, not `main`:

```bash
git checkout -b hotfix/v1.4.1 v1.4.0
# apply minimal fix with conventional commit
git tag v1.4.1
git push origin v1.4.1
```

Then backport the fix to `main` via a separate PR. If it doesn't cherry-pick cleanly, reimplement against `main`.

**Versioning:** Hotfixes increment patch from the affected release (`v1.4.0` → `v1.4.1`). Non-linear tags are fine — git-cliff resolves by branch lineage, not global tag order.

**Chain if needed:** `v1.4.0` → `v1.4.1` → `v1.4.2`, each branching from the previous tag.

## Rollback

1. Identify last known-good tag
2. Trigger deploy pipeline for that tag
3. **Do not** delete the bad tag — tags are immutable records
4. **Do not** panic-revert on `main` — revert commits are a deliberate follow-up, not an emergency response
5. Open an issue linking to the failed release tag

## Dependency Tracking

Use `build(deps):` prefix for dependency commits:

```
build(deps): bump serde from 1.0.190 to 1.0.195
build(deps): bump tokio to 1.35 (security fix CVE-2024-XXXX)
```

git-cliff config to group these:

```toml
# cliff.toml commit_parsers:
{ message = "^build\\(deps\\)", group = "Dependencies" }
```

**Security deps:** Always include CVE identifier. Never batch with routine bumps. Use `!` if public API changes: `build(deps)!: bump openssl to 2.0`.

## Release PR Batching

One open release PR accumulates all changes until merged. CI logic:

1. Check for existing open PR with `autorelease/` branch prefix
2. If exists → force-push updated branch, update PR body
3. If not → create new PR

Merge timing:
- **Default:** When ready to release (no urgency)
- **Sprint-based** (ROC-X OS bundles): End of sprint
- **Urgent:** As soon as CI finishes updating

## Branch Protection for `main`

| Rule | Setting |
|------|---------|
| Require PR before merging | Enabled |
| Required approving reviews | 1 minimum |
| Dismiss stale approvals | Enabled |
| Require status checks to pass | Enabled (`build`, `test`, `lint`) |
| Require branches up to date | Enabled |
| Require linear history | Consider (enforces squash-merge) |
| Allow force pushes | Disabled |
| Allow deletions | Disabled |

Use **GitHub rulesets** (not legacy branch protection). `autorelease/*` branches need no protection.

CI bot needs: write access to `autorelease/*`, permission to create PRs and tags. Release workflow must not be its own required check (circular dependency).

## Conventional Commit Enforcement

Two layers — both required:

**Client-side** (`.githooks/commit-msg`):

```bash
#!/bin/sh
commit_msg=$(cat "$1")
pattern='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\(.+\))?(!)?: .+'
if ! echo "$commit_msg" | grep -qE "$pattern"; then
  echo "ERROR: Not a conventional commit. Expected: <type>(<scope>): <description>"
  exit 1
fi
```

Enable with: `git config core.hooksPath .githooks`

**Server-side** (GitHub Actions — validates PR title since squash-merge uses it):

```yaml
- uses: amannn/action-semantic-pull-request@v5
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Add the PR title check to required status checks in branch protection.

**If a non-conventional commit reaches `main`:** Do not rewrite history. Manually adjust the changelog in the next release PR review.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Hotfix branch from `main` instead of tag | Always branch from the release tag: `git checkout -b hotfix/vX.Y.Z vX.Y.0` |
| Deleting a bad release tag | Tags are immutable. Redeploy the previous tag instead. |
| Force-pushing to `main` | Never. Use revert commits if needed. |
| Skipping PR title validation | Non-conventional titles break changelog generation on squash-merge |
| Security dep bump batched with routine bumps | Security deps get individual commits with CVE identifiers |
| Release workflow as its own required check | Creates circular dependency — exclude it from required checks |

# Upstream Sync Guide

This repository (`gpeyton/loom`) is a fork of [`rjwalters/loom`](https://github.com/rjwalters/loom) that has diverged substantially — Epic #1 (dual-runtime Claude/Codex worker support) and Epic #30 (Codex full-autonomy default) both landed here and are not present upstream. This guide explains the automated drift-monitoring workflow and the manual procedure for pulling upstream changes back into this fork.

## The drift-monitoring workflow

`.github/workflows/upstream-drift.yml` runs a daily check (disabled by default — see below) that:

1. Fetches `rjwalters/loom`'s `main` branch and computes how many commits this fork's `main` is **behind** and **ahead** of it (`git rev-list --count`).
2. Runs the Codex parity suite (`npm run test:codex`, added in issue #34) so a drift-driven merge that touches the runtime abstraction (Claude vs. Codex worker dispatch) gets an automatic parity signal.
3. Writes both results to the GitHub Actions job summary (`$GITHUB_STEP_SUMMARY`) for every run, whether or not drift was detected.
4. If the fork is behind upstream, opens **one** deduplicated operator-facing issue titled `chore: sync upstream Loom updates`. If that issue is already open, the workflow adds a comment with refreshed counts instead of opening a duplicate — re-running the workflow while drift persists never spams new issues, it just updates the existing one.

### Enabling the schedule

Like the other `.github/workflows/loom-*.yml` support-role workflows, the daily cron trigger ships **commented out** so forks don't burn Actions minutes by default. To enable it:

1. Open `.github/workflows/upstream-drift.yml` and uncomment the `schedule:` / `- cron:` lines.
2. Commit the change.

No additional secrets are required — the workflow uses the default `GITHUB_TOKEN` (`issues: write`, `contents: read`).

### Manual smoke test

Trigger a one-off run at any time via the Actions UI ("Run workflow" on the "Upstream Drift Monitor" workflow) or:

```bash
gh workflow run upstream-drift.yml
```

This is safe to run repeatedly — the dedup logic means a second run while drift is still present updates the existing sync issue rather than creating a new one.

## Interpreting the dedup issue

When the workflow opens (or updates) the `chore: sync upstream Loom updates` issue, the body/comment reports:

- **Behind** — how many commits `rjwalters/loom:main` has that this fork does not.
- **Ahead** — how many fork-only commits this fork has (Epic #1, Epic #30, and any other divergent work).
- **Codex parity result** — pass/fail for `npm run test:codex` at the time of the check.

The issue is labeled `loom:operator-only` when that label exists on the repo, signaling that a human — not an automated Loom role — needs to drive the sync (see `.github/labels.yml`'s note on `loom:operator-only`: "Requires human action outside automation"). Automated Loom roles (Curator, Builder, Judge, Champion, Auditor, Guide) skip `loom:operator-only` issues by design.

Close the issue once the sync below is complete (or once you've deliberately decided not to merge the pending upstream commits — leave a comment explaining why before closing, so the next drift check doesn't reopen confusion about the decision).

## Manual sync procedure

1. **Fetch upstream:**
   ```bash
   git remote add upstream https://github.com/rjwalters/loom.git 2>/dev/null || \
     git remote set-url upstream https://github.com/rjwalters/loom.git
   git fetch upstream main
   ```

2. **Review the diff** before merging anything:
   ```bash
   git log --oneline HEAD..upstream/main       # commits you're about to pull in
   git diff HEAD...upstream/main -- <path>      # inspect specific areas of concern
   ```
   Pay particular attention to anything touching the runtime-dispatch abstraction (`defaults/scripts/spawn-*.sh`, `.github/workflows/loom-role.yml`, `.codex/`) since that's the surface Epic #1/#30 diverged on most.

3. **Cherry-pick or merge**, depending on the scope of the drift:
   - For a small, targeted set of upstream commits: `git cherry-pick <sha>` one at a time, resolving conflicts as they arise (fork-specific files like this guide, `upstream-drift.yml`, and the Codex runtime adapters are the most likely conflict points).
   - For a large batch of upstream history: `git merge upstream/main` on a dedicated branch, then resolve conflicts in one pass.

4. **Re-run the full parity and test suite before merging drift back into `main`:**
   ```bash
   npm run test:codex
   cargo test --workspace
   ```
   Both must pass. A drift merge that breaks Codex parity or the Rust test suite should not land — fix the regression first, or (if the upstream change conflicts with a fork-specific design decision) skip that commit and note why in the sync PR description.

5. **Open a PR** for the sync branch through the normal Loom lifecycle (`loom:review-requested` → Judge → merge via `./.loom/scripts/merge-pr.sh`, never `gh pr merge`), and reference the dedup issue (`Closes #<N>`) so it closes automatically on merge.

6. **Verify the next drift check reports zero behind** — either wait for the next scheduled run or trigger a manual `gh workflow run upstream-drift.yml` smoke test.

## See also

- `.github/workflows/upstream-drift.yml` — the workflow itself
- `npm run test:codex` (issue #34) — the aggregate Codex parity suite
- `docs/guides/development.md` — general contribution setup
- `docs/guides/testing.md` — running the full test matrix

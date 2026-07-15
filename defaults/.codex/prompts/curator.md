---
description: Loom Curator — enhance and organize issues for implementation readiness
argument-hint: [issue-number]
---

You are the Loom Curator (Issue Curator) for this repository.

**Arguments**: $ARGUMENTS

If a number is provided, treat it as the target issue to curate.
Otherwise, find uncurated issues via the label-based workflow.

This prompt is a thin shim. The canonical role definition lives in this
repository at `.loom/roles/curator.md`.

Read `.loom/roles/curator.md` now and follow it exactly — enriching
issues with technical details, acceptance criteria, and scope, and
applying the `loom:curated` label when done. Do not act from memory of
what a "curator" is; the role file is the contract.

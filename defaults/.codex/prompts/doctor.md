---
description: Loom Doctor — fix bugs and address PR review feedback
argument-hint: [pr-number]
---

You are the Loom Doctor (PR Fixer) for this repository.

**Arguments**: $ARGUMENTS

If a number is provided, treat it as the target PR to fix. Otherwise,
find PRs labeled `loom:changes-requested`.

This prompt is a thin shim. The canonical role definition lives in this
repository at `.loom/roles/doctor.md`.

Read `.loom/roles/doctor.md` now and follow it exactly — addressing
judge feedback, fixing CI failures, and returning the PR to review with
the correct label transitions. Do not act from memory of what a
"doctor" is; the role file is the contract.

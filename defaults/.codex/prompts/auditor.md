---
description: Loom Auditor — validate main branch build and runtime health
argument-hint: [focus-area]
---

You are the Loom Auditor for this repository.

**Arguments**: $ARGUMENTS

If an argument is provided, treat it as the audit focus area.
Otherwise, run the standard main-branch audit.

This prompt is a thin shim. The canonical role definition lives in this
repository at `.loom/roles/auditor.md`.

Read `.loom/roles/auditor.md` now and follow it exactly — build/runtime
validation on main and filing `loom:auditor` findings. Do not act from
memory of what an "auditor" is; the role file is the contract.

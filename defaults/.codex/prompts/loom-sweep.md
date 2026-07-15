---
description: Loom Sweep — drive issues through the full Curator → Builder → Judge → Doctor → Merge lifecycle
argument-hint: [issue-numbers…]
---

You are running a Loom sweep in this repository.

**Arguments**: $ARGUMENTS

Interpret the arguments exactly as the sweep skill defines (explicit
issue numbers, a natural-language issue description, or a `--prs` PR
set).

This prompt is a thin shim. The canonical sweep definition lives in this
repository at `.claude/commands/loom/sweep.md` (the sweep skill is
runtime-shared; that file is its single source of truth). Read it now
and follow it.

**Honest limitation (Codex runtime, Epic #1 Phase 2)**: the sweep skill's
parallel dispatch assumes Claude Code subagents, which Codex does not
have. Under Codex, run the lifecycle **sequentially in this session** —
for each issue, perform Curator → Builder → Judge → Doctor (if needed)
→ Merge yourself, in order, following the corresponding
`.loom/roles/<role>.md` file at each phase. Skip the skill's
subagent/parallel-wave machinery. Full sweep orchestration for Codex
(subagent equivalents, hooks) is Epic #1 Phase 3.

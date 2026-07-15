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

**Codex runtime (Epic #1 Phase 3, #19)**: the sweep skill's parallel
dispatch assumes Claude Code Task-tool subagents, which Codex does not
have. Under Codex, run the lifecycle **sequentially in this session** —
for the target issue, perform Curator → Builder → Judge → Doctor (if
needed) → Merge yourself, in order, following the corresponding
`.loom/roles/<role>.md` file at each phase. Skip the skill's
subagent/parallel-wave machinery. See the sweep skill's
"Runtime-aware orchestration (Claude vs Codex)" section for the full
Codex strategy, the model-tier mapping, and the guardrail-parity gate.

- The "one level deep" #3289 constraint is Claude-specific and does not
  apply to this process-level path — but still **settle each PR fully**
  (Judge → optional single Doctor→Judge cycle → Merge) before moving on.
- **Guardrail parity (issue #20, landed)**: Codex has no PreToolUse-hook
  runtime, but #20 maps the Claude hook safety posture onto the Codex
  sandbox — see `defaults/.codex/GUARDRAIL-PARITY.md` for the covered/
  partial/no-equivalent table and residual gaps. An autonomous
  write-access Codex sweep still stays opt-in (`spawn-codex.sh` keeps
  the sandbox on unless `LOOM_CODEX_UNSAFE=1` is explicitly set) — do
  not treat it as a default even with parity in place.
- **Multi-wave process-level Codex orchestration** (fanning out multiple
  `codex exec` children as the analogue of `--builders-per-wave`) is a
  deferred follow-up: **#24**. Today, multiple issues run sequentially.

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

**Codex runtime (Epic #1 Phase 3, #19)**: the sweep skill's Claude-Code
Task-tool subagent dispatch does not exist under Codex. Under Codex, run
the lifecycle **sequentially in this session** — for the target issue,
perform Curator → Builder → Judge → Doctor (if needed) → Merge yourself,
in order, following the corresponding `.loom/roles/<role>.md` file at
each phase. Skip the skill's subagent/parallel-wave machinery. See the
sweep skill's "Runtime-aware orchestration (Claude vs Codex)" section for
the full Codex strategy, the model-tier mapping, and the guardrail-parity
gate.

- **Backend policy (issue #54) — do not use native Codex agent
  primitives for Loom work.** Current Codex clients expose native,
  in-session collaboration primitives (`spawn_agent`, `wait_agent`,
  `send_message`, `followup_task`, `interrupt_agent`). Those primitives
  are **not** a supported Loom orchestration backend — the only
  supported way to parallelize Loom work under Codex is process-level
  fan-out (`spawn-codex-wave.sh`, below). A request for "parallel Loom
  agents," in any phrasing, routes to `spawn-codex-wave.sh`, never to
  `spawn_agent`. Do not mix sequential-in-session, process-level
  fan-out, daemon dispatch, and native-agent spawning within one run.
  See the sweep skill's "Codex backend policy" subsection for the full
  rationale.

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
- **Multi-wave process-level Codex orchestration (issue #24, resolved)**:
  `defaults/scripts/spawn-codex-wave.sh` fans multiple `codex exec` children
  out as the process-level analogue of `--builders-per-wave`, one child per
  issue in a wave, and blocks until every child in the wave has settled
  before returning. This is opt-in behind `LOOM_CODEX_MULTI_WAVE=1`
  (orthogonal to the `LOOM_CODEX_UNSAFE` permissions gate above) — without
  it, multiple issues still run sequentially, one at a time, as before. See
  the sweep skill's "Multi-wave process-level Codex orchestration" section
  for the full substrate decision and settling-discipline rationale.
- **Child supervision (issue #52) — binding on this session and on any
  `spawn-codex-wave.sh` you launch**: log silence is never proof a child has
  stalled; there is no implicit inactivity timeout anywhere in this
  contract. Cancel a live child only for an explicit user stop, a
  separately configured hard wall-clock deadline
  (`LOOM_CODEX_WAVE_HARD_DEADLINE_SEC`, opt-in, never silence-based), or a
  confirmed unrecoverable failure. Default to a blocking join (start, then
  wait) rather than aggressive polling. Never enter or edit a Builder-owned
  worktree while that Builder's child is alive. A parent-initiated stop is
  a cancellation outcome (`cancelled_by_operator` / `cancelled_by_parent` /
  `cancelled_by_deadline`), never the generic `failed` outcome — read
  `spawn-codex-wave.sh --status` for structured state instead of parsing
  logs. Full contract and outcome taxonomy: the sweep skill's "Codex Child
  Supervision Contract" section.

---
name: loom-sweep
description: Run Loom issues or PRs end-to-end with Codex through Curator → Builder → Judge → Doctor → Merge. Use when asked to sweep issue or PR numbers.
---

# Loom sweep for Codex

`$loom-sweep` is the primary Codex entry point for the full Loom sweep
lifecycle. It **replaces** the deprecated `.codex/prompts/loom-sweep.md`
custom prompt as the documented onboarding path (issue #35) — see
`../../.codex/prompts/README.md` for the transition note. The retired
prompt still functions during the transition window; this skill is where
new setups should start.

## Canonical sweep source

This skill is a thin router, not a fork. Read `.claude/commands/loom/sweep.md`
completely and execute its lifecycle — it is the single, runtime-shared
source of truth for the sweep skill (there is no separate copy under
`.loom/roles/`; the sweep skill is not a per-role file).

Treat text following `$loom-sweep` as `$ARGUMENTS` and interpret it exactly
as the sweep skill defines: explicit issue numbers, a natural-language issue
description, or a `--prs` PR set.

## Codex runtime mappings

Codex has no Task-tool subagents, so `$loom-sweep` runs the lifecycle
**sequentially in this session**, following the retired
`.codex/prompts/loom-sweep.md` shim's contract exactly:

- For each target issue, perform Curator → Builder → Judge → Doctor (if
  needed) → Merge yourself, in order, following the matching
  `.codex/agents/loom-<role>.toml` custom agent (which in turn points at
  `.loom/roles/<role>.md`) at each phase. Skip the skill's Task-tool
  subagent/parallel-wave machinery.
- The "one level deep" Claude subagent-depth constraint (#3289) is
  Claude-specific and does not apply to this process-level path — but
  still **settle each PR fully** (Judge → optional single Doctor→Judge
  cycle → Merge) before moving on.
- **Guardrail parity**: Codex has no PreToolUse-hook runtime; `.codex/GUARDRAIL-PARITY.md`
  maps the Claude hook safety posture onto the Codex sandbox/approval
  configuration — see that file for the covered/partial/no-equivalent
  table and residual gaps.
- **Multi-wave process-level Codex orchestration**: `defaults/scripts/spawn-codex-wave.sh`
  fans multiple `codex exec` children out as the process-level analogue of
  `--builders-per-wave`, one child per issue in a wave, and blocks until
  every child in the wave has settled before returning. This is opt-in
  behind `LOOM_CODEX_MULTI_WAVE=1` (orthogonal to the Codex permissions
  posture) — without it, multiple issues run sequentially, one at a time.
- **Stage -1 pool detection**: a Codex multi-account pool means at least
  two child directories containing `auth.json` under `LOOM_CODEX_HOMES_DIR`.
  Claude's `.loom/tokens/` and `ACCOUNT_KEY_*` values are not a Codex pool.

## Codex child supervision (issue #52 — read before supervising any Codex wave)

Log silence is **never** proof that a Codex child has stalled. Editing, builds,
tests, and long tool calls can legitimately produce no log output for minutes.
There is **no implicit inactivity timeout** anywhere in this contract — cancel
only for an explicit user stop, a separately configured hard wall-clock
deadline (`LOOM_CODEX_WAVE_HARD_DEADLINE_SEC`, opt-in, never silence-based), or
a confirmed unrecoverable failure. The default monitoring pattern is a
**blocking join** (start the wave, wait for it to return) — not aggressive
1/10/20/30-second polling. A parent/root **must never** enter or edit a
Builder-owned worktree (`.loom/worktrees/issue-N`) while that Builder's child
is still alive. A parent-initiated stop is a cancellation
(`cancelled_by_operator` / `cancelled_by_parent` / `cancelled_by_deadline`),
never the generic `failed` outcome — read non-destructive structured state via
`spawn-codex-wave.sh --status` rather than parsing prose logs. **Full contract,
outcome taxonomy, and the forward reference to #53's resume mechanics**: see
`.claude/commands/loom/sweep.md`'s "Codex Child Supervision Contract" section
— it is canonical and binding on this skill.

Keep daemon MCP dispatch, checkpointing (`.loom/sweep-checkpoint/`), label
validation, confirmation gates, and dry-run behavior unchanged — this
skill is a routing layer over the canonical sweep spec, not a new one.
Continue until every item is merged, merge-ready, blocked per the
workflow, or the dry run is complete.

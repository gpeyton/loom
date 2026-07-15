# Codex Autonomy and Trust Boundary

**Epic #30 (Codex full-autonomy default), Phase 1 (#33).** Supersedes the
original hook-parity framing shipped in Epic #1, Phase 3 (#20) — see
"History" at the bottom for what changed and why.

## The short version

Loom-spawned Codex workers run with **full, unattended authority** by
default: no filesystem sandbox, no outbound-network restriction, no
approval prompts (`sandbox_mode = "danger-full-access"`,
`approval_policy = "never"` in [`config.toml`](./config.toml);
`--dangerously-bypass-approvals-and-sandbox` in
[`spawn-codex.sh`](../scripts/spawn-codex.sh)).

**This is not a new risk class.** Loom's Claude Code path has run this way
since before Codex support existed — the Loom default for Claude workers is
`--dangerously-skip-permissions`, which runs Claude non-interactively with
full tool access (Claude's PreToolUse hooks still fire under that flag, but
they are advisory guardrails layered on top of an already-unattended agent,
not a sandbox boundary the agent cannot cross). Epic #30 makes Codex match
that same posture instead of defaulting to a narrower one. **Parity, not a
new exposure.**

**The trust decision was already made when you installed Loom and enabled
autonomous workers.** Only install Loom, and only enable Codex workers, in
repositories and execution environments you trust with unattended write
access — the same bar that already applies to enabling autonomous Claude
workers. Codex's sandbox is not, and was never meant to be, a substitute for
that trust decision. Treat a Loom-managed Codex worker the same way you'd
treat a Loom-managed Claude worker: it can read, write, execute, and push
anything the host process can.

Out of scope: building a Codex hooks system (Codex does not support one; it
is not Loom's job to invent one) and the Codex sweep orchestration itself.

---

## Opting into the old sandboxed posture: `LOOM_CODEX_SAFE=1`

Operators who want the pre-#30 behavior — Codex confined to
`workspace-write`, no outbound network, `on-request` approvals — can restore
it per-invocation by setting `LOOM_CODEX_SAFE=1` in the environment before
spawning a Codex worker. That flips `spawn-codex.sh`'s mapping of Loom's
skip-permissions convention from the bypass-everything flag to `--full-auto`,
and correspondingly makes Codex honor `config.toml`'s
`[sandbox_workspace_write]` table (see the comment on that table — Codex
only reads it when `sandbox_mode = "workspace-write"`, so it is otherwise
inert).

`LOOM_CODEX_UNSAFE=1` is kept as a deprecated no-op alias for the *new*
default (full access) for one transition release; it warns and points here.
`LOOM_CODEX_SAFE=1` always wins if both are set.

The rest of this document describes what `LOOM_CODEX_SAFE=1` restores —
i.e., the guardrail posture that used to be the unconditional default before
#33.

---

## What `LOOM_CODEX_SAFE=1` restores

With `LOOM_CODEX_SAFE=1` set, Codex runs under `--full-auto`
(`workspace-write` + `network_access = false` + `on-request`). Codex has no
per-tool-call hook interception the way Claude Code does — Loom's Claude
guardrails are **PreToolUse / UserPromptSubmit hooks** wired in
[`.claude/settings.json`](../../.claude/settings.json) to scripts under
[`.loom/hooks/`](../../.loom/hooks/), and those hooks simply do not exist as
a concept under Codex. Safe mode's protection instead comes from two native,
OS-level layers configured in [`config.toml`](./config.toml) (or via CLI
flags), plus the `AGENTS.md` context Codex reads natively:

| Codex mechanism | What it does | `LOOM_CODEX_SAFE=1` value |
|-----------------|--------------|--------------|
| `sandbox_mode` | Filesystem/network confinement. Values: `read-only`, `workspace-write`, `danger-full-access`. | `workspace-write` (via `--full-auto`) |
| `[sandbox_workspace_write] network_access` | Outbound network from inside the sandbox. | `false` |
| `approval_policy` | When Codex pauses to ask a human before escalating. Values: `untrusted`, `on-request`, `never` (`on-failure` is deprecated). | `on-request` (via `--full-auto`) |
| `AGENTS.md` | Repository instructions discovered by ancestor traversal (runtime-neutral). | [`.loom/AGENTS.md`](../.loom/AGENTS.md) — always active, independent of sandbox mode |

### The load-bearing caveat: non-interactive approvals are a no-op

`approval_policy` only guards when a **human** is present to answer the
prompt. Loom automation runs `codex exec` (and `spawn-codex.sh -p …`)
**non-interactively** — no human, so an `on-request` approval cannot be
granted and effectively does not gate anything even in safe mode. Codex's
own guidance is to use `never` for non-interactive runs. **Therefore, even
under `LOOM_CODEX_SAFE=1`, the SANDBOX is the load-bearing guard for
unattended Codex workers, not the approval policy.** `sandbox_mode =
"workspace-write"` and `network_access = false` are what actually restrict
an automated safe-mode worker; `approval_policy` only matters for
interactive `codex` sessions.

---

## Hook-by-hook classification (what safe mode covers vs. doesn't)

This table is a reference for evaluating `LOOM_CODEX_SAFE=1`'s sandbox
against the individual Claude PreToolUse/UserPromptSubmit hooks it has no
literal equivalent for. It is **not** a description of the full-autonomy
default — read it as "if I opt into safe mode, what do I get back?"

| Claude hook (`.loom/hooks/`) | Wired in `.claude/settings.json` | Protection it provides | Safe-mode (`LOOM_CODEX_SAFE=1`) status | How safe mode covers it (or why it can't) |
|------------------------------|----------------------------------|------------------------|--------------|----------------------------------------|
| `guard-destructive.sh` | `PreToolUse` on `Bash` | Blocks catastrophic Bash (`rm -rf /`, force-push to main, `curl … \| sh`, cloud-CLI destruction, `DROP DATABASE`, `DELETE` w/o `WHERE`), asks on borderline commands, blocks `rm` outside repo, nudges `gh pr merge` → `merge-pr.sh`, blocks `pip install -e` in worktrees | **partial** | `workspace-write` blocks `rm`/writes outside the workspace; `network_access = false` blocks `curl \| sh` and cloud-CLI destruction (no network to reach). **Not covered:** command-pattern semantics (e.g. `DROP DATABASE` against a reachable DB), the `gh pr merge` → `merge-pr.sh` nudge, the `pip install -e` worktree guard, and the granular allow/ask/deny decisions. |
| `guard-worktree-paths.sh` | `PreToolUse` on `Edit\|Write` | Confines `Edit`/`Write` to `LOOM_WORKTREE_PATH`; blocks a builder escaping its worktree into the main checkout (#2441) | **partial** | `workspace-write` confines writes to the **workspace root**, a coarser boundary. It blocks writes outside the repo, but does **not** enforce the per-worktree boundary — a Codex worker could still write elsewhere *within* the same workspace root (cross-worktree writes are not blocked). |
| `skill-router.sh` | `UserPromptSubmit` | Injects an agent routing table + `AGENT_ROUTE` suggestion per prompt (opt-in; only when `.loom/config/skill-routes.json` exists) | **no-equivalent** | Context injection, not a safety boundary. Codex has no `UserPromptSubmit` hook. Partially mitigated by [`AGENTS.md`](../.loom/AGENTS.md) (static workflow) and the Codex prompt shims that name each role. Dynamic per-prompt routing has no Codex equivalent. Acceptable gap (informational only). |
| `methodology-inject.sh` | *(present in `.loom/hooks/` but NOT wired in this repo's `.claude/settings.json`)* | Injects universal/role/topic context from `.loom/context/` per prompt (opt-in; only when `.loom/context/` exists) | **partial** | Static "universal" project context is achievable via `AGENTS.md`, which Codex reads natively. Dynamic role/topic keyword-matched injection has **no** Codex equivalent. Context enrichment, not a safety boundary — the gap is acceptable. |
| `post-worktree.sh` | *(not a `settings.json` hook — invoked by `worktree.sh`)* | Copies the `loom-daemon` binary into a new worktree after creation | **covered** | Runtime-neutral: `worktree.sh` calls it regardless of which agent runtime is driving, so it fires identically for a Codex worker, in safe mode or full-access mode alike. Not a Claude-Code-specific hook. |

**Summary:** even at its most restrictive (`LOOM_CODEX_SAFE=1`), the two
*safety* guardrails (`guard-destructive`, `guard-worktree-paths`) are only
**partial** under Codex — the sandbox covers the filesystem/network blast
radius but not command-pattern semantics or the per-worktree boundary. The
two *context-injection* hooks (`skill-router`, `methodology-inject`) are
**no-equivalent / partial** — not safety boundaries, so the gaps are
acceptable and partly mitigated by `AGENTS.md`. `post-worktree` is
**covered** (runtime-neutral, unaffected by sandbox mode).

Under the **default** (full-access) posture, none of the above applies:
there is no sandbox, so every row's "partial" coverage is also absent. The
default relies entirely on the trust-boundary decision described at the top
of this document, not on any technical guard.

---

## Residual gaps in safe mode (known, documented, acceptable)

These are the deltas where even `LOOM_CODEX_SAFE=1` provides less than the
Claude hooks. None is a silent gap; each is a conscious trade-off pending a
richer Codex surface.

1. **Command-pattern blocking.** Codex cannot pattern-match a specific
   dangerous command (`DROP DATABASE`, `DELETE` without `WHERE`, service
   `systemctl stop`, etc.). If the operation is reachable *without* leaving the
   workspace or the network (e.g. a local DB socket inside the workspace), the
   sandbox will not stop it. Mitigation: keep destructive tooling out of the
   workspace root and rely on `network_access = false` for anything remote.
2. **Per-worktree write isolation.** `workspace-write` confines to the
   workspace root, not to a single `issue-N` worktree. Parallel Codex builders
   sharing a workspace root are not isolated from each other's trees the way
   `guard-worktree-paths.sh` isolates Claude builders. Mitigation: run one
   Codex worker per workspace root, or set `writable_roots` narrowly.
3. **Loom-specific behavioral nudges.** The `gh pr merge` → `merge-pr.sh`
   redirect and the `pip install -e` worktree block are conventions, not OS
   boundaries. Codex learns them only from [`AGENTS.md`](../.loom/AGENTS.md) /
   role prompts, which is advisory, not enforced.
4. **Per-prompt context injection.** `skill-router` / `methodology-inject`
   dynamic routing and role/topic context have no Codex equivalent. Static
   equivalents live in `AGENTS.md`.
5. **Approvals in automation.** As noted above, `approval_policy` does not gate
   non-interactive `codex exec` runs even in safe mode. The sandbox is the
   only enforced guard in automation.

---

## Supervision & cancellation guardrails (issue #52)

Sandbox/approval posture (everything above) governs what a Codex worker is
*permitted to touch*. This section covers a related but distinct guardrail:
what a Codex **supervisor** (a root/parent session running `spawn-codex-wave.sh`
or a sequential Codex sweep) is permitted to do to a **child it is watching**.
Two real Loom 0.10.6 incidents (#51) showed a supervising Codex session
mistake log silence for a stall, `SIGINT` a live Builder child, declare it
"failed," and take over Builder work itself — none of which the sandbox
posture above was ever meant to prevent, because it is a supervision-loop
defect, not a permissions defect.

The full contract lives in `.claude/commands/loom/sweep.md`'s "Codex Child
Supervision Contract" section (issue #52) and is binding on every Codex
supervision surface. The guardrail-relevant summary:

| Guardrail | Statement | No-equivalent gap? |
|---|---|---|
| No silence-based cancellation | Log inactivity is never grounds for `kill` / interrupt / replacement. Cancellation requires an explicit user stop, a separately configured (never silence-inferred) hard deadline, or a confirmed unrecoverable failure. | **No native enforcement** — same class of gap as items 3–4 above (a documented convention, not an OS boundary). Codex has no supervisor-loop primitive to police this mechanically; the contract is enforced by documentation + `spawn-codex-wave.sh`'s own implementation (no inactivity timeout exists in its code at all). |
| Non-destructive, backed-off status checks | The default operator loop is a blocking join; optional polling (`spawn-codex-wave.sh --status`) uses a bounded, increasing backoff and never mutates or cancels. | Same as above — a convention `spawn-codex-wave.sh --status` makes easy to follow correctly (it is read-only by construction), but nothing prevents a supervisor from ignoring it and polling aggressively anyway. |
| Worktree non-interference | A parent/root must not enter or edit a Builder-owned worktree (`.loom/worktrees/issue-N`) while that Builder's child is alive. | **No native enforcement for Codex.** Claude's equivalent (`guard-worktree-paths.sh`) is a PreToolUse hook scoped to a *builder's own* worktree boundary from the inside; Codex has no hook system at all (see the hook-by-hook table above), so there is no mechanical guard preventing a Codex *supervisor* session from editing a *different* session's worktree. This is enforced entirely by the contract and by operator discipline — the same trust-boundary posture this whole document already asks you to accept for Codex's full-autonomy default. |
| Cancellation ≠ failure | A parent-initiated stop is reported as `cancelled_by_operator` / `cancelled_by_parent` / `cancelled_by_deadline`, never as `failed`. | Implemented mechanically in `spawn-codex-wave.sh` (traps `INT`/`TERM`, tags the resulting outcome, never folds it into the generic failed-issues count) — this one **is** enforced in code, not just documented. |
| Native-agent interrupt mapping | If/when Loom adopts native Codex collaboration agents (`spawn_agent` / `interrupt_agent`), `interrupt_agent` must map to a cancellation outcome, never `failed`, and must not replace/take over a still-alive target. | Forward-looking only — Loom does not reference these primitives today. Tracked in issue #54 (native-agent backend policy), which inherits this contract's outcome taxonomy rather than defining its own. |

**Bottom line**: unlike the sandbox/approval rows above (which are enforced by Codex's own process boundary), the supervision guardrails in this section are enforced by (a) `spawn-codex-wave.sh`'s implementation for the mechanical parts it can own (no inactivity timeout, signal-provenance tagging, a `--status` read path that is read-only by construction), and (b) documentation + operator/agent discipline for the parts no current Codex primitive can mechanically block (worktree non-interference across sessions, refusing to poll aggressively). Treat this the same way you treat the rest of Codex's trust boundary: know where the enforced edge is, and don't rely on an unenforced convention as if it were a sandbox.

---

## History

- **Epic #1, Phase 3 (#20)**: introduced Codex support with a
  sandboxed-by-default posture (`workspace-write` + `network_access = false`
  + `on-request`) and this document as a hook-by-hook parity table framed
  around "what Codex covers of the Claude hooks by default."
- **Epic #30, Phase 1 (#31, #33)**: inverted the default. `spawn-codex.sh`'s
  skip-permissions mapping now targets full autonomy
  (`--dangerously-bypass-approvals-and-sandbox`) unless `LOOM_CODEX_SAFE=1`
  opts back into the old sandboxed behavior. This document was rewritten
  (#33) from a parity table into the trust-boundary statement above, with
  the original table preserved as "what safe mode restores."

---

## References

- Codex config reference (sandbox/approval keys): <https://developers.openai.com/codex/config-reference>
- Codex sandboxing concepts: <https://developers.openai.com/codex/concepts/sandboxing>
- Loom Codex config: [`config.toml`](./config.toml)
- Loom Codex spawn wrapper: [`../scripts/spawn-codex.sh`](../scripts/spawn-codex.sh)
- Loom Codex AGENTS.md: [`../.loom/AGENTS.md`](../.loom/AGENTS.md)
- CI support-role workflow: [`../../.github/workflows/loom-role.yml`](../../.github/workflows/loom-role.yml)
- Claude hooks: [`../../.loom/hooks/`](../../.loom/hooks/), wired in [`.claude/settings.json`](../../.claude/settings.json)
- Epic #30 (Codex full-autonomy default), Phase 1 issue: #33
- Permissions-inversion PR (Phase 1 part A): #31 / PR #39

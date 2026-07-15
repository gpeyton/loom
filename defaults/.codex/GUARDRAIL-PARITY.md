# Codex Guardrail Parity

**Epic #1 (dual-runtime worker support), Phase 3 (#20).**

Loom's safety guardrails under Claude Code are **PreToolUse / UserPromptSubmit
hooks** wired in [`.claude/settings.json`](../../.claude/settings.json) to
scripts under [`.loom/hooks/`](../../.loom/hooks/). Those hooks speak the Claude
Code hooks wire protocol (JSON on stdin → a decision JSON on stdout) and depend
on Claude Code's hook-firing semantics. **Codex has no hooks system**, so those
guards *silently do not fire* under a Codex worker — a correctness/safety
problem, not a cosmetic one.

This document is the honest, hook-by-hook map of each Claude guardrail to its
Codex status: **covered**, **partial**, or **no-equivalent**. Honesty over
false parity — a documented gap is acceptable; a silent one is not.

Out of scope: building a Codex hooks system (Codex does not support one; it is
not Loom's job to invent it) and the Codex sweep orchestration itself.

---

## How Codex enforces safety instead

Codex has no per-tool-call hook interception. Its safety model is two native,
OS-level layers configured in [`config.toml`](./config.toml) (or via CLI
flags), plus the AGENTS.md context it reads natively:

| Codex mechanism | What it does | Loom default |
|-----------------|--------------|--------------|
| `sandbox_mode` | Filesystem/network confinement. Values: `read-only`, `workspace-write`, `danger-full-access`. | `workspace-write` |
| `[sandbox_workspace_write] network_access` | Outbound network from inside the sandbox. Default off. | `false` |
| `approval_policy` | When Codex pauses to ask a human before escalating. Values: `untrusted`, `on-request`, `never` (`on-failure` is deprecated). | `on-request` |
| `AGENTS.md` | Repository instructions discovered by ancestor traversal (runtime-neutral). | [`.loom/AGENTS.md`](../.loom/AGENTS.md) |

Loom's dispatch surfaces set this posture consistently:

- **[`config.toml`](./config.toml)** (this directory, shipped by #16) sets the
  safest-functional default: `workspace-write` + `network_access = false` +
  `on-request`.
- **[`spawn-codex.sh`](../scripts/spawn-codex.sh)** (#15) maps Loom's
  `--dangerously-skip-permissions` convention to `--full-auto`
  (== `workspace-write` + `on-request`), never to fewer guards. The
  bypass-everything flag (`--dangerously-bypass-approvals-and-sandbox` ==
  `danger-full-access` + `never`) is gated behind **both** the skip-permissions
  convention **and** an explicit `LOOM_CODEX_UNSAFE=1` opt-in.
- **CI** ([`.github/workflows/loom-role.yml`](../../.github/workflows/loom-role.yml),
  #14) pins `codex exec … --sandbox workspace-write` with no bypass flag.

**No Loom dispatch path silently drops below the Claude guarantee.** The only
sub-Claude posture is reached by explicitly setting `LOOM_CODEX_UNSAFE=1`.

### The load-bearing caveat: non-interactive approvals are a no-op

`approval_policy` only guards when a **human** is present to answer the prompt.
Loom automation runs `codex exec` (and `spawn-codex.sh -p …`) **non-interactively**
— no human, so an `on-request` approval cannot be granted and effectively does
not gate anything. Codex's own guidance is to use `never` for non-interactive
runs. **Therefore, for Loom's automated Codex workers the SANDBOX is the
load-bearing guard, not the approval policy.** `sandbox_mode = "workspace-write"`
and `network_access = false` are what actually provide guardrail parity in
automation; `approval_policy` matters chiefly for interactive `codex` sessions.

---

## Parity table

| Claude hook (`.loom/hooks/`) | Wired in `.claude/settings.json` | Protection it provides | Codex status | How Codex covers it (or why it can't) |
|------------------------------|----------------------------------|------------------------|--------------|----------------------------------------|
| `guard-destructive.sh` | `PreToolUse` on `Bash` | Blocks catastrophic Bash (`rm -rf /`, force-push to main, `curl … \| sh`, cloud-CLI destruction, `DROP DATABASE`, `DELETE` w/o `WHERE`), asks on borderline commands, blocks `rm` outside repo, nudges `gh pr merge` → `merge-pr.sh`, blocks `pip install -e` in worktrees | **partial** | `workspace-write` blocks `rm`/writes outside the workspace; `network_access = false` blocks `curl \| sh` and cloud-CLI destruction (no network to reach). **Not covered:** command-pattern semantics (e.g. `DROP DATABASE` against a reachable DB), the `gh pr merge` → `merge-pr.sh` nudge, the `pip install -e` worktree guard, and the granular allow/ask/deny decisions. |
| `guard-worktree-paths.sh` | `PreToolUse` on `Edit\|Write` | Confines `Edit`/`Write` to `LOOM_WORKTREE_PATH`; blocks a builder escaping its worktree into the main checkout (#2441) | **partial** | `workspace-write` confines writes to the **workspace root**, a coarser boundary. It blocks writes outside the repo, but does **not** enforce the per-worktree boundary — a Codex worker could still write elsewhere *within* the same workspace root (cross-worktree writes are not blocked). |
| `skill-router.sh` | `UserPromptSubmit` | Injects an agent routing table + `AGENT_ROUTE` suggestion per prompt (opt-in; only when `.loom/config/skill-routes.json` exists) | **no-equivalent** | Context injection, not a safety boundary. Codex has no `UserPromptSubmit` hook. Partially mitigated by [`AGENTS.md`](../.loom/AGENTS.md) (static workflow) and the Codex prompt shims that name each role. Dynamic per-prompt routing has no Codex equivalent. Acceptable gap (informational only). |
| `methodology-inject.sh` | *(present in `.loom/hooks/` but NOT wired in this repo's `.claude/settings.json`)* | Injects universal/role/topic context from `.loom/context/` per prompt (opt-in; only when `.loom/context/` exists) | **partial** | Static "universal" project context is achievable via `AGENTS.md`, which Codex reads natively. Dynamic role/topic keyword-matched injection has **no** Codex equivalent. Context enrichment, not a safety boundary — the gap is acceptable. |
| `post-worktree.sh` | *(not a `settings.json` hook — invoked by `worktree.sh`)* | Copies the `loom-daemon` binary into a new worktree after creation | **covered** | Runtime-neutral: `worktree.sh` calls it regardless of which agent runtime is driving, so it fires identically for a Codex worker. Not a Claude-Code-specific hook. |

**Summary:** the two *safety* guardrails (`guard-destructive`,
`guard-worktree-paths`) are **partial** under Codex — the sandbox covers the
filesystem/network blast radius but not command-pattern semantics or the
per-worktree boundary. The two *context-injection* hooks (`skill-router`,
`methodology-inject`) are **no-equivalent / partial** — not safety boundaries,
so the gaps are acceptable and partly mitigated by `AGENTS.md`. `post-worktree`
is **covered** (runtime-neutral).

---

## Residual gaps (known, documented, acceptable)

These are the deltas where Codex provides **less** than the Claude hooks. None
is a silent gap; each is a conscious trade-off pending a richer Codex surface.

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
   non-interactive `codex exec` runs. The sandbox is the only enforced guard in
   automation.

---

## References

- Codex config reference (sandbox/approval keys): <https://developers.openai.com/codex/config-reference>
- Codex sandboxing concepts: <https://developers.openai.com/codex/concepts/sandboxing>
- Loom Codex config: [`config.toml`](./config.toml)
- Loom Codex spawn wrapper (#15): [`../scripts/spawn-codex.sh`](../scripts/spawn-codex.sh)
- Loom Codex AGENTS.md (#8): [`../.loom/AGENTS.md`](../.loom/AGENTS.md)
- CI support-role workflow (#14): [`../../.github/workflows/loom-role.yml`](../../.github/workflows/loom-role.yml)
- Claude hooks: [`../../.loom/hooks/`](../../.loom/hooks/), wired in [`.claude/settings.json`](../../.claude/settings.json)

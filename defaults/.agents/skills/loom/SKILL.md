---
name: loom
description: Operate Loom's label-driven forge workflow with Codex. Use for issue curation, implementation, PR review, repair, prioritization, auditing, and orchestration.
---

# Loom for Codex

`$loom` is the primary Codex entry point for Loom's role-based workflow. It
**replaces** the deprecated `.codex/prompts/*` custom prompts as the
documented onboarding path (issue #35) — see
`../../.codex/prompts/README.md` for the transition note. The retired
prompts still function during the transition window; this skill is where
new setups should start.

## Canonical role source

This skill is a thin router, not a fork. Read `CLAUDE.md` at the repository
root first for the shared workflow and label rules, then read the file
matching your task under `.loom/roles/` — that directory holds the single,
provider-neutral definition of every role (Claude Code's
`.claude/commands/loom/` slash commands resolve to the same files):

- `.loom/roles/architect.md` — architecture proposals
- `.loom/roles/auditor.md` — main-branch build/runtime validation
- `.loom/roles/builder.md` — implement `loom:issue` work, open PRs
- `.loom/roles/champion.md` — evaluate proposals, merge approved PRs
- `.loom/roles/curator.md` — enrich issues with acceptance criteria
- `.loom/roles/doctor.md` — fix PR review feedback / CI failures
- `.loom/roles/driver.md` — default interactive shell
- `.loom/roles/guide.md` — triage and prioritize the issue backlog
- `.loom/roles/hermit.md` — simplification/deletion proposals
- `.loom/roles/judge.md` — review PRs labeled `loom:review-requested`
- `.loom/roles/loom.md` — Layer 2 daemon orchestrator (MCP dispatch)

Interpret text following `$loom` as `$ARGUMENTS` for the selected role, the
same convention the retired `.codex/prompts/*.md` shims used. Do not act
from memory of what a given role "usually" does — the role file under
`.loom/roles/` is the contract, not this skill.

## Codex mappings

- Interpret Claude `Task` subagent delegation as Codex delegation: use the
  matching `.codex/agents/loom-<role>.toml` custom agent when available,
  otherwise run the role sequentially in this session with the role
  document included in context.
- Map any other legacy Claude tool names mentioned in the role files to
  their Codex equivalents.

## Guardrails unchanged

Keep Loom's forge operations, confirmation gates, label ownership, worktree
isolation (`./.loom/scripts/worktree.sh`), tests, checkpoints, and merge
restrictions (`./.loom/scripts/merge-pr.sh`, never `gh pr merge`)
unchanged — this skill only routes to the existing contract, it does not
redefine it.

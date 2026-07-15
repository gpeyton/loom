# Loom Orchestration - Repository Guide (AGENTS.md)

This repository uses **Loom** for AI-powered development orchestration.

**Loom Version**: {{LOOM_VERSION}}
**Installation Date**: {{INSTALL_DATE}}

## What is Loom?

Loom is a CLI + daemon for AI-powered development orchestration. It coordinates AI development workers using git worktrees and a forge (GitHub or Gitea) as the coordination layer. Coordination itself — labels, worktrees, the sweep lifecycle, merge scripts — is runtime-neutral: it works the same whether the worker reading this file is Claude Code or another agent runtime (e.g. OpenAI Codex CLI) that discovers repository instructions via `AGENTS.md` ancestor traversal.

**Loom Repository**: https://github.com/rjwalters/loom

**Dual-runtime status**: as of this Loom version, Claude Code is the only runtime with first-class dispatch support (slash commands, MCP tools, hooks — see "Claude Code only today" callouts below). This file exists so that any AGENTS.md-aware runtime can at least discover the label workflow, worktree rules, and merge conventions used by this repository. Runtime-specific dispatch surfaces will grow in future phases; treat everything under "Claude Code only today" as not-yet-portable rather than permanently Claude-exclusive.

## Orchestration Architecture

Loom decomposes development into three coordination tiers, with the forge (GitHub / Gitea) as the shared state.

| Tier | Entry point | Purpose | Mode |
|------|-------------|---------|------|
| Tier 3 | Human | Oversight — approve proposals, handle edge cases | Observer |
| Tier 2 | `loom-daemon` (MCP) + GH Actions cron | Multi-issue dispatch + scheduled support roles | Continuous / cron |
| Tier 1 | `/loom:sweep <issue>` | Single-issue lifecycle (Curator → Merge) | Per-issue |
| Tier 0 | Builder, Judge, Curator, Doctor, etc. | Task execution — single focused work units | Per-task |

**Claude Code only today**: `/loom:sweep <issue>` and the other slash commands (`/builder`, `/judge`, `/curator`, etc.) are Claude Code slash commands defined under `.claude/commands/loom/`. A Codex worker cannot invoke them by name; it must be told to perform the equivalent steps directly (claim the issue, create the worktree, implement, open the PR) using the workflow described below.

**Claude Code only today**: `mcp__loom__dispatch_sweep`, `mcp__loom__list_sweeps`, and the other `mcp__loom__*` tools are exposed through Claude Code's MCP integration. They are not currently reachable from a Codex session.

## Label-Based Workflow

Agents coordinate through GitHub (or Gitea) labels. This part of Loom is runtime-neutral — any worker that can run `gh` (or the Gitea API equivalent) can participate. See `.github/labels.yml` for full label definitions.

### Label Flow

**Issue Lifecycle**:
```
(created) → loom:triage → loom:curating → loom:curated → loom:issue → loom:building → (closed)
           ↑ filer        ↑ Curator        ↑ Curator      ↑ human     ↑ Builder
```

**PR Lifecycle**:
```
(created) → loom:review-requested → loom:pr → (auto-merged)
           ↑ Builder                ↑ Judge    ↑ Champion
```

**Proposal Lifecycle**:
```
(created) → loom:architect/loom:hermit/loom:auditor → (evaluated) → loom:issue
           ↑ Architect/Hermit/Auditor                 ↑ Champion    ↑ Ready for Builder
```

**Note on label cleanup**: Loom intentionally does **not** remove labels from closed issues or merged PRs (e.g., `loom:pr` remains on merged PRs). Labels on closed/merged items are harmless — all agents filter by open state.

## Sweep Lifecycle (MANDATORY)

When implementing issues — regardless of which agent runtime is doing the work — **all stages of the lifecycle must be executed in order**. Do not skip stages.

```
Curator → Builder → Judge → Doctor (if needed) → Merge
```

| Stage | What happens | Skip allowed? |
|-------|-------------|---------------|
| **Curator** | Enrich the issue with technical details, acceptance criteria, scope | No |
| **Builder** | Implement, test, commit, create PR | No |
| **Judge** | Review the PR, approve or request changes | No |
| **Doctor** | Fix issues from judge feedback | Only if judge approves |
| **Merge** | Champion auto-merges approved PRs | No |

Simply creating a PR and labeling it `loom:review-requested` is only the Builder stage — the work is not complete until the PR has been reviewed and merged.

### Manual workflow (any runtime)

1. **Find issue**: `gh issue list --label="loom:issue"`
2. **Claim**: `gh issue edit 42 --remove-label "loom:issue" --add-label "loom:building"`
3. **Create worktree**: `./.loom/scripts/worktree.sh 42 && cd .loom/worktrees/issue-42`
4. **Implement, test, commit**
5. **Create PR**: `git push -u origin feature/issue-42 && gh pr create --label "loom:review-requested" --body "Closes #42"`

### Judge workflow

1. Find PR: `gh pr list --label="loom:review-requested"`
2. Review: `gh pr checkout 123`
3. Approve: `gh pr comment 123 --body "LGTM! Approved." && gh pr edit 123 --remove-label "loom:review-requested" --add-label "loom:pr"`
4. Or request changes: `gh pr comment 123 --body "Changes needed: ..." && gh pr edit 123 --remove-label "loom:review-requested" --add-label "loom:changes-requested"`

**Note**: Use `gh pr comment` instead of `gh pr review --approve` — GitHub's API prevents self-review, and Loom agents often create and review the same PR. Labels are the coordination mechanism.

### Curator workflow

1. Find unlabeled issues: `gh issue list --label="!loom:issue,!loom:building,!loom:architect,!loom:hermit,!loom:curated,!loom:curating"`
2. Enhance the issue with technical details, acceptance criteria, and scope
3. Mark curated: `gh issue edit 42 --add-label "loom:curated"`

## Git Worktree Workflow

Loom uses git worktrees to isolate agent work. This mechanism is runtime-neutral.

**Issue Worktrees** (`.loom/worktrees/issue-N`): Issue-specific work for the Builder role.

### Creating Worktrees

```bash
# Claim issue and create worktree
gh issue edit 42 --remove-label "loom:issue" --add-label "loom:building"
./.loom/scripts/worktree.sh 42
cd .loom/worktrees/issue-42

# Work, commit, push, create PR
git push -u origin feature/issue-42
gh pr create --label "loom:review-requested"
```

### Best Practices

- Always use `./.loom/scripts/worktree.sh <issue-number>` (it writes a `.loom-managed` sentinel that authorizes cleanup)
- Never run `git worktree` directly (helper prevents nested worktrees)
- Loom-managed worktrees (under `.loom/worktrees/` with the `.loom-managed` sentinel) are auto-removed when their PR merges. User-provisioned worktrees at other paths are never removed by Loom — set `LOOM_PRESERVE_WORKTREE=1` to disable cleanup globally for a session.

### Merging PRs

**Never use `gh pr merge`** — always use `./.loom/scripts/merge-pr.sh <PR_NUMBER>` instead. The `gh pr merge` command attempts a local checkout which fails when the PR branch is linked to a worktree. The merge script merges via the forge API directly and handles worktree cleanup automatically.

```bash
./.loom/scripts/merge-pr.sh <PR_NUMBER>         # Standard merge with worktree cleanup
./.loom/scripts/merge-pr.sh <PR_NUMBER> --auto   # Enable auto-merge instead of immediate merge
./.loom/scripts/merge-pr.sh <PR_NUMBER> --dry-run # Preview without merging
```

## Configuration

### Workspace Configuration

Configuration is stored in `.loom/config.json` (committed to git for team sharing). This file is read by the daemon and by Claude Code's terminal manager; a Codex-based runtime does not currently consume it, but it is safe to leave in place.

### Custom Roles

Role definitions live in `.loom/roles/*.md` and describe each worker's responsibilities (Builder, Judge, Curator, Doctor, Champion, Architect, Hermit, Guide, Driver, Auditor). These files are plain markdown and are runtime-neutral — any agent capable of following written instructions can use them as a role brief. **Claude Code only today**: the mechanism that automatically loads a role file into a terminal (via `.loom/config.json` → `roleConfig.roleFile`) is part of the Claude Code terminal manager.

### Multi-Account Token Pool

The `.loom/tokens/` pool, `loom-tokens` CLI, and `spawn-claude.sh` wrapper described in the root `CLAUDE.md` are Claude Code OAuth-specific (**Claude Code only today**) — they rotate Claude Code credentials, not credentials for other runtimes.

## Safety Guardrails (Codex vs Claude Code)

Loom's Claude Code safety guardrails are PreToolUse hooks (`.loom/hooks/`) wired
in `.claude/settings.json`. **Codex has no hooks system**, so those guards do
not fire for a Codex worker. Their intent is mapped instead to Codex's native
sandbox + approval posture, set safe-by-default in `.codex/config.toml`
(`sandbox_mode = "workspace-write"`, `network_access = false`,
`approval_policy = "on-request"`). No Loom dispatch path drops below the Claude
guarantee without an explicit `LOOM_CODEX_UNSAFE=1` opt-in.

**Important:** in non-interactive automation (`codex exec`), approvals cannot be
answered (no human), so the **sandbox is the load-bearing guard** — keep
destructive tooling out of the workspace and leave `network_access = false`.

For the honest hook-by-hook parity map (covered / partial / no-equivalent) and
the documented residual gaps, see `.codex/GUARDRAIL-PARITY.md`.

## Forge Authentication

### GitHub

Loom uses the `gh` CLI for all GitHub operations. By default it uses the credential from `gh auth login`, which has access to all repositories. To scope access to a single repository, create a fine-grained PAT and set `export GH_TOKEN=github_pat_xxx` before running Loom.

See `.loom/docs/github-authentication.md` for the detailed setup guide.

### Gitea

For Gitea repositories, Loom uses the Gitea API with token authentication. Set `GITEA_TOKEN` or `FORGE_TOKEN` environment variable with an API token created at `<your-gitea-instance>/user/settings/applications`.

See `.loom/docs/forge-authentication.md` for the complete authentication guide covering both GitHub and Gitea.

## Troubleshooting

**Quick fixes**:

```bash
loom-clean --force                       # Clean stale worktrees/branches
./.loom/scripts/stale-building-check.sh --recover  # Recover stuck issues
gh label sync --file .github/labels.yml  # Re-sync labels (GitHub only)
```

See `.loom/docs/troubleshooting.md` for detailed troubleshooting.

## Resources

- **Main Repository**: https://github.com/rjwalters/loom
- **Role Definitions**: `.loom/roles/*.md`
- **Label Definitions**: `.github/labels.yml`
- **Troubleshooting**: `.loom/docs/troubleshooting.md`
- **Daemon Reference**: `.loom/docs/daemon-reference.md`
- **Full Claude Code guide**: `.loom/CLAUDE.md` (the Claude-Code-oriented sibling of this file — covers the daemon MCP surface, slash commands, and hooks in full)

---

**Generated by Loom Installation Process**
Last updated: {{INSTALL_DATE}}

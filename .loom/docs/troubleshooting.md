# Loom Troubleshooting Guide

## Common Issues

### Hooks not firing (`guard-destructive.sh` not blocking commands) — Claude Code only

> **Claude-runtime-only.** Loom's guardrail hooks (`guard-destructive.sh` and the
> other `PreToolUse`/`PostToolUse` hooks under `.claude/`) are a **Claude Code**
> mechanism — they are wired through Claude Code's permission/hook system. The
> OpenAI Codex CLI does not run these hooks; Codex enforces safety through its
> **sandbox mode** and **approval policy** instead (see
> [Codex worker troubleshooting](#codex-worker-troubleshooting-runtime-parity) below). The
> hook-to-sandbox safety mapping and the residual gaps between the two models are
> documented in the guardrail-parity doc (forthcoming — issue #20).

**Symptom**: Commands that should be blocked or confirmed by `guard-destructive.sh` (e.g., `git reset --hard`, `gh issue close`) are executing without any prompt or denial.

**Root cause**: Claude Code's `--permission-mode bypassPermissions` flag skips ALL PreToolUse hooks entirely. If Claude Code is invoked with this flag, hooks never run — not even safety hooks like `guard-destructive.sh`.

**How to diagnose**:
```bash
# Check if you have a shell alias that sets bypassPermissions
alias claude 2>/dev/null || echo "no alias"

# Check if Loom scripts are using the correct flag
grep -r 'permission-mode' .loom/scripts/ .loom/roles/ 2>/dev/null
```

**The two flags behave differently**:

| Flag | Hooks fire? | Use case |
|------|-------------|----------|
| `--dangerously-skip-permissions` | ✅ YES | Loom automation (agents use this) |
| `--permission-mode bypassPermissions` | ❌ NO | Fully bypasses all permission checks AND hooks |

**Fix**: If you have a shell alias using `--permission-mode bypassPermissions`, change it to use `--dangerously-skip-permissions` instead:

```bash
# WRONG - hooks silently disabled:
alias claude="claude --permission-mode bypassPermissions"

# CORRECT - hooks still fire:
alias claude="claude --dangerously-skip-permissions"
```

Note: `--dangerously-skip-permissions` still skips interactive permission prompts (so agents can run non-interactively), but hooks are executed. This is the intended mode for Loom agents.

**Verify the fix**: After updating your alias, restart your shell and confirm hooks fire by checking the hook error log:
```bash
# Hook invocations log errors here:
cat .loom/logs/hook-errors.log
```

If the log is absent or empty and hooks aren't blocking, confirm Claude Code is invoked with `--dangerously-skip-permissions` (not `bypassPermissions`).

### Cleaning Up Stale Worktrees and Branches

Use the `loom-clean` command to restore your repository to a clean state:

```bash
# Interactive mode - prompts for confirmation (default)
loom-clean

# Preview mode - shows what would be cleaned without making changes
loom-clean --dry-run

# Non-interactive mode - auto-confirms all prompts (for CI/automation)
loom-clean --force

# Deep clean - also removes build artifacts (target/, node_modules/)
loom-clean --deep

# Combine flags
loom-clean --deep --force  # Non-interactive deep clean
loom-clean --deep --dry-run  # Preview deep clean
```

**What loom-clean does**:
- Removes worktrees for closed GitHub issues (prompts per worktree in interactive mode)
- Deletes local feature branches for closed issues
- Cleans up Loom tmux sessions
- (Optional with `--deep`) Removes `target/` and `node_modules/` directories

**IMPORTANT**: For **CI pipelines and automation**, always use `--force` flag to prevent hanging on prompts:
```bash
loom-clean --force  # Non-interactive, safe for automation
```

**Manual cleanup** (if needed, but use with caution):

**WARNING**: Running `git worktree remove` while your shell is in the worktree directory will corrupt your shell state. Always ensure you've navigated out of the worktree first, or use `loom-clean` which handles this safely.

```bash
# First, ensure you're NOT in the worktree you're removing
cd /path/to/main/repo

# List worktrees
git worktree list

# Remove specific stale worktree (only after navigating out!)
git worktree remove .loom/worktrees/issue-42 --force

# Prune orphaned worktrees
git worktree prune
```

### Labels out of sync

```bash
# Re-sync labels from configuration
gh label sync --file .github/labels.yml
```

Label sync is a manual/install-time step (`./scripts/install/sync-labels.sh .`),
not something CI re-applies when `.github/labels.yml` changes. If a label is
defined in `labels.yml` but missing from the live repo, applying it fails with
`failed to update 1 issue` (the standard `gh` error for "label does not exist").
Run the sync script — or create the one label directly — to reconcile:

```bash
gh label list --search operator                      # empty => not provisioned
gh label create "loom:operator-only" --color F97316 \
  --description "Requires human action outside automation (credentials, infra, hardware); sweep/shepherd skip"
```

**GitHub caps label descriptions at 100 characters.** A `labels.yml` entry with a
longer description fails to sync (HTTP 422 "description is too long") and the label
silently never gets created. Keep descriptions at or under 100 chars.

#### `loom:blocked` vs `loom:operator-only`

These two status labels look similar but mean different things to the automation:

- **`loom:blocked`** — work is *automatable* but currently waiting on a dependency
  (another issue, an unmerged PR, missing context). The intent is "unblock it, then
  a Builder can proceed."
- **`loom:operator-only`** — work requires a *human to act outside automation
  entirely* (rotating credentials, infra changes, hardware access, manual deploys).
  Sweep/shepherd skip these in pre-flight rather than attempting them; a human must
  do the work off-automation before the issue can proceed.

Reaching for `loom:blocked` when you mean `loom:operator-only` conflates "waiting on
a dependency" with "needs a human action," which muddies the daemon/sweep skip
semantics. Use `loom:operator-only` for the human-must-act-off-automation case.

### Daemon won't start

```bash
# Check daemon logs
tail -f ~/.loom/daemon.log
```

### Claude Code not found (Claude runtime)

```bash
# Ensure Claude Code CLI is in PATH
which claude

# Install if missing (see Claude Code documentation)
```

### Spawn exits 78: "loom-tools requires >= 3.10"

`spawn-claude.sh` / `spawn-codex.sh` refuse to run `loom_tools` (token
selection, Codex-profile selection) under an interpreter below loom-tools'
`requires-python = ">=3.10"` floor. The error names the interpreter and its
version, e.g.:

```
ERROR Python interpreter '/usr/bin/python3' is Python 3.9.6, but loom-tools requires >= 3.10.
```

This is common on stock macOS, where `/usr/bin/python3` is the Command Line
Tools 3.9. The spawn scripts prefer the engine venv automatically, so the fix
is usually to create it:

```bash
# In the Loom engine checkout — creates <engine>/loom-tools/.venv
./scripts/install/setup-python-tools.sh

# Or point the spawners at any >= 3.10 interpreter explicitly
export LOOM_PYTHON=/opt/homebrew/bin/python3.12
```

Interpreter precedence is `LOOM_PYTHON` > `<engine>/loom-tools/.venv/bin/python`
> `python3` on `PATH`; the resolved choice is logged once per spawn as
`spawn-claude: python=<path> (source=...)`. Spawn paths that never touch
Python — `--help`, a pre-set `CLAUDE_CODE_OAUTH_TOKEN`/`OPENAI_API_KEY`,
`LOOM_SPAWN_NO_EXPORT`, or a Codex spawn with no `.loom/tokens/` pool — are
unaffected by the check.

### Codex worker troubleshooting (runtime parity)

Loom supports the **OpenAI Codex CLI** as a co-equal worker runtime alongside
Claude Code. The entries below are the Codex counterparts of the Claude-specific
troubleshooting above. For first-time Codex setup, see
[Using Codex with Loom](../../docs/guides/getting-started.md#using-codex-with-loom).

#### `codex` command not found

```bash
# Ensure the Codex CLI is in PATH
which codex
codex --version

# Install if missing:
npm install -g @openai/codex
# See https://developers.openai.com/codex for installation and auth
```

If a scheduled support-role workflow selected the `codex` runtime but the job
fails at startup, confirm `@openai/codex` installed and that `OPENAI_API_KEY` is
set as a repository secret (the `claude` runtime uses `CLAUDE_API_KEY` instead —
the two runtimes require different secrets).

#### Sandbox / approval blocking (Codex safety model)

Codex enforces safety through a **sandbox mode** plus an **approval policy** —
this is Codex's equivalent of Loom's Claude Code guardrail hooks (there is no
Codex hook system). Symptom: Codex refuses to write files, run commands, or reach
the network, or it stops to ask for approval mid-run.

- **Sandbox modes** (`sandbox_mode` in `.codex/config.toml`, or `--sandbox` on the
  CLI): `read-only`, `workspace-write` (Loom's default for autonomous role runs —
  allows edits inside the workspace but still gates network/out-of-workspace
  access), and `danger-full-access` (no sandbox — use only in already-isolated
  environments such as CI containers).
- **Approval policy** (`approval_policy`, or `--ask-for-approval`): valid values are
  `untrusted`, `on-request`, `never`, and `granular` (`on-failure` is deprecated).
  For non-interactive automation Loom runs `codex exec ... --sandbox workspace-write`
  so the agent proceeds without interactive prompts, mirroring Claude Code's
  `--dangerously-skip-permissions` posture.

```bash
# Non-interactive run with workspace-write sandbox (Loom's automation default):
codex exec "<inlined role prompt>" --sandbox workspace-write -m <codex-model>
```

If Codex is blocking a legitimate write, widen the sandbox to `workspace-write`;
if it is blocking network access a task genuinely needs, that is expected — the
guardrail-parity doc (forthcoming — issue #20) documents which safety guarantees
carry over from the Claude hooks and which are residual gaps.

#### MCP config / `loom` tools not resolving under Codex

Codex loads the `loom` MCP server from a **project-scoped** `.codex/config.toml`,
but only for projects you have marked **trusted** in Codex. Symptoms: the `loom`
MCP tools are missing in a Codex session, or `.codex/config.toml` overrides are
ignored entirely.

```bash
# 1. Materialize the [mcp_servers.loom] entry (idempotent, absolute-path):
./scripts/setup-mcp.sh --codex

# 2. Trust the repository in Codex so it loads the project-scoped .codex/ layer.
#    Untrusted projects skip project-local config, so the loom MCP entry never loads.

# 3. Confirm the entry is present and uncommented in .codex/config.toml:
grep -A3 'mcp_servers.loom' .codex/config.toml
```

Do **not** run `CODEX_HOME=$(pwd)/.codex codex` to force config loading — that
drags auth/session state into the repo tree. Trust the project instead and rely
on Codex's native project-scoped config merge.

#### Codex prompts / slash commands not found

Codex discovers custom prompts only in `$CODEX_HOME/prompts/` (default
`~/.codex/prompts/`), **not** in the repo's `.codex/prompts/`. If `/builder`,
`/judge`, etc. are unavailable in a Codex session, the one-time symlink setup is
missing:

```bash
# From the repo root — symlink the repo's prompt shims into CODEX_HOME:
mkdir -p ~/.codex/prompts
ln -sf "$(pwd)/.codex/prompts/"*.md ~/.codex/prompts/
rm -f ~/.codex/prompts/README.md
```

See [Using Codex with Loom → Prompt invocation](../../docs/guides/getting-started.md#using-codex-with-loom)
for the full walkthrough. Note that custom prompts are a deprecated Codex surface
(Codex recommends skills); the shims still work and a skills port is tracked under
Epic #1.

### Sweep output invisible when invoked with `2>&1` (Claude `claude -p`)

When `claude -p "/loom:sweep N"` is run with `2>&1` redirection (e.g., from Claude Code's Bash tool for long-running processes), output may be silently dropped. This is because the Bash tool's capture buffer can be exhausted by a long-running child process when both stdout and stderr are forced through the same pipe.

**Workaround** — use a file redirect:

```bash
# Redirect to file, then cat the result
claude -p "/loom:sweep 123" --dangerously-skip-permissions > /tmp/sweep-123.log 2>&1
cat /tmp/sweep-123.log
```

**Built-in log file** — when a sweep child runs, it automatically tees all output to `.loom/logs/sweep-issue-N.log`. If output is invisible in your terminal, check this log file:

```bash
cat .loom/logs/sweep-issue-123.log
# or follow in real time:
tail -f .loom/logs/sweep-issue-123.log
```

### API Error: 400 due to tool use concurrency issues

This error occurs when Claude Code's parallel tool execution causes malformed API message structures. See the dedicated guide: [Tool Use Concurrency Errors](./tool-use-concurrency-errors.md)

**Quick recovery**:
```bash
# In Claude Code, run:
/rewind
```

**Prevention** - Add to `~/.claude/CLAUDE.md`:
```markdown
# Force Sequential Tool Execution
Execute tools sequentially, never in parallel.
Process one tool call at a time.
Wait for tool_result before initiating next tool execution.
```

**Common triggers**:
- Multiple parallel file operations (Read, Write, Edit)
- Using print mode (`-p` flag) instead of interactive mode
- PostToolUse hooks that interfere with message structure
- Editing files while they're open in an IDE

### Orphaned issues stuck in loom:building state

When an agent crashes or is cancelled while building, issues can get stuck in `loom:building` state without a PR. Use the stale-building-check script to detect and recover these:

```bash
# Check for stale building issues (dry run)
./.loom/scripts/stale-building-check.sh

# Show detailed progress
./.loom/scripts/stale-building-check.sh --verbose

# Auto-recover stale issues (resets to loom:issue)
./.loom/scripts/stale-building-check.sh --recover

# JSON output for automation
./.loom/scripts/stale-building-check.sh --json
```

**Configuration via environment**:
- `STALE_THRESHOLD_HOURS=2` - Hours before issue without PR is considered stale
- `STALE_WITH_PR_HOURS=24` - Hours before issue with stale PR is flagged

**What it does**:
- Finds issues with `loom:building` label that have been stuck
- Checks if there's an associated PR (by branch name or body reference)
- Issues without PRs older than threshold are flagged/recovered
- Issues with stale PRs are flagged but not auto-recovered (need manual review)

## Stuck Agent Detection

`loom-stuck-detection` checks for stuck sweep children by reading the per-task heartbeats in `.loom/spawn-loop-state.json::running[].last_heartbeat`.

> **Note (post-v0.11.0):** `spawn-loop.sh` — the only writer of `.loom/spawn-loop-state.json` — was deleted, so this file no longer has a writer. `loom-stuck-detection` therefore currently reports nothing (a safe no-op: it only reports, it never tears down work). Repointing it to the `loom-daemon` sweep registry (`mcp__loom__list_sweeps`) and `.loom/sweep-checkpoint/issue-<N>.json` timestamps is tracked as a follow-up (see `docs/migration/daemon-state-consumers.md`).

### Check for stuck agents

```bash
# Run stuck detection check
loom-stuck-detection check

# Check with JSON output
loom-stuck-detection check --json

# Check a specific issue
loom-stuck-detection check-issue 123
```

### Stuck indicators (post-v0.10.0)

| Indicator | Default Threshold | Description |
|-----------|-------------------|-------------|
| `stale_heartbeat` | 5 minutes | No checkpoint update for extended time |
| `dead_pid` | (instant) | PID in the daemon sweep registry is no longer alive |
| `error_spike` | 5 errors | Multiple errors in `.loom/logs/sweep-issue-N.log` |

The pre-v0.10.0 indicators `missing_milestone:worktree_created` and `extended_work` were retired when the Python daemon brain (`daemon_v2/`) was removed — see [the migration guide § Per-CLI breaking changes](../../docs/migration/v0.10.0-shepherd-deprecation.md#per-cli-breaking-changes) for the field-level diff. The shell-level daemon surface (`./.loom/scripts/daemon.sh`) is preserved but does not write progress files, so milestone-based heuristics no longer apply.

## Sweep Dispatch Troubleshooting

Multi-issue dispatch is driven by the Rust `loom-daemon` binary via `mcp__loom__dispatch_sweep`. The daemon holds the sweep registry, event bus, and reaper in memory — there is no on-disk orchestration state file to inspect. (The v0.9.x `spawn-loop.sh` and its `.loom/spawn-loop-state.json` state file were removed in v0.11.0.)

### Sweep MCP tools missing (stale dist bundle)

**Symptom**: `mcp__loom__dispatch_sweep`, `mcp__loom__list_sweeps`, `mcp__loom__get_sweep_status`, `mcp__loom__tail_sweep_log`, `mcp__loom__cancel_sweep`, `mcp__loom__publish_event`, `mcp__loom__subscribe_to_events`, or `mcp__loom__tail_event_bus` are **not offered** in a live session — `/loom:sweep`'s Stage -1 daemon probe can't reach them even though `loom-daemon` is running.

**Cause**: the MCP client loads the **built bundle** `mcp-loom/dist/index.js`, never the TypeScript source. `dist/` is gitignored, so a checkout that predates the sweep tools (Phase A #3452 / Phase C #3455) keeps serving an old bundle. The source (`mcp-loom/src/index.ts` → `sweepTools`) is correct; the on-disk artifact is stale (#3803).

**Diagnose**:

```bash
# 0 means the sweep tools are absent from the built bundle -> stale
grep -c dispatch_sweep mcp-loom/dist/index.js

# Compare build vs source timestamps
ls -la mcp-loom/dist/index.js
find mcp-loom/src -type f -newer mcp-loom/dist/index.js   # any output => dist is stale
```

**Fix** — rebuild, then **reconnect**:

```bash
cd mcp-loom && npm install && npm run build
grep -c dispatch_sweep dist/index.js   # should now be > 0
```

`scripts/setup-mcp.sh` now auto-rebuilds when `dist/index.js` is missing **or** older than any file under `mcp-loom/src/` (#3803), so `./scripts/setup-mcp.sh` is the safe one-shot path. Rebuilding the bundle does **not** refresh an already-running session — an MCP client caches its tool list at connect time, so you must **restart the Claude Code session** (or respawn the `loom` MCP subprocess) for the new tools to appear. See [`mcp-loom/README.md`](../../mcp-loom/README.md#rebuilding-after-source-changes-reconnect-required) for the full rebuild + reconnect procedure and a raw `tools/list` verification snippet.

### MCP tools hang with no response (~1800s), then abort

**Symptom**: `mcp__loom__dispatch_sweep`, `mcp__loom__get_sweep_status`, `mcp__loom__list_sweeps`, or `mcp__loom__cancel_sweep` return **no response and no progress**, and are eventually aborted by the client (`sent no response or progress for 1800s; aborting`) — even though the underlying operation **succeeded** (the sweep child spawned, the PR opened, etc.). The CLI path (`loom-daemon status` / `dispatch`) stays fast throughout, which isolates the fault to the MCP/IPC response path, not a wedged daemon.

**Cause** (#4043): the MCP bridge's unary request transport (`mcp-loom/src/shared/daemon.ts` `sendDaemonRequest`) historically settled its promise only in the socket's `end` handler. The real `loom-daemon` holds each connection **open by design** (a persistent per-connection read loop, `loom-daemon/src/ipc.rs` `handle_client`): it writes one newline-delimited JSON response frame per request and never closes after answering. So the response sat complete-but-unparsed in the client buffer while the promise waited forever for an `end` that never came. A **stale bundle** (`mcp-loom/dist/` older than `mcp-loom/src/`) compounds it by discarding the per-call timeout, turning a diagnosable failure into the full ~1800s idle hang.

**Diagnose** — probe the raw socket (bypassing the MCP layer) and check the bundle for the timeout string:

```bash
# Does the bundle even carry the bounded-timeout fix? 0 => stale, pre-timeout bundle
grep -c "did not respond within" mcp-loom/dist/index.js

# Is dist/ older than src/? (any output => stale, rebuild needed)
find mcp-loom/src -type f -newer mcp-loom/dist/index.js
```

**Fix** — the transport now settles on the **first newline-delimited response frame** (in the `data` handler) and closes the socket after settling, so it no longer depends on the daemon closing the connection. If you are on a pre-fix bundle, rebuild and reconnect:

```bash
cd mcp-loom && npm install && npm run build   # then restart the Claude Code session
```

The `claude-wrapper.sh` MCP pre-flight (`check_mcp_server`) now rebuilds a stale bundle before the smoke test, so a fresh session on an up-to-date checkout self-heals; the regression is guarded by `mcp-loom/scripts/verify-daemon-timeout.mjs`'s respond-without-close stub case (`npm run verify:daemon-timeout`).

### Inspect running sweeps

```bash
# List all running sweeps in the daemon registry
mcp__loom__list_sweeps

# Inspect a specific sweep's state
mcp__loom__get_sweep_status --sweep_id <id>

# Tail a per-sweep log
mcp__loom__tail_sweep_log --sweep_id <id>
# (per-sweep logs also live at .loom/logs/sweep-issue-<N>.log)
```

### Cancel a sweep

```bash
# Cancel a running sweep (SIGTERM → grace → SIGKILL)
mcp__loom__cancel_sweep --sweep_id <id>
```

The daemon's reaper task detects dead PIDs (every 30s) and removes them from the registry, emitting `sweep.issue.*.exited` / `sweep.issue.*.crashed` events.

### Stuck sweep child

A sweep child whose pid is alive but whose `.loom/sweep-checkpoint/issue-<N>.json` mtime is stale is likely stuck. To recover:

```bash
# Check checkpoint mtime
ls -la .loom/sweep-checkpoint/issue-123.json

# Look at the child's log for errors
tail -200 .loom/logs/sweep-issue-123.log

# Cancel it through the daemon:
mcp__loom__cancel_sweep --sweep_id <id>

# The checkpoint survives cancellation, so re-dispatching the issue resumes
# from its last completed phase:
mcp__loom__dispatch_sweep --issue 123
```

### Dispatch is not producing sweeps

Issues need the `loom:issue` label (human-approved, ready for work) to be eligible for dispatch. If a dispatch isn't producing a sweep, check:

```bash
# 1. Confirm there are ready issues
gh issue list --label "loom:issue" --state open

# 2. Confirm the daemon is reachable and running
mcp__loom__list_sweeps

# 3. Confirm the multi-account token pool is bootstrapped (dispatch requires it)
ls -la .loom/tokens/

# 4. Look at recent sweep activity on the event bus
mcp__loom__tail_event_bus
```

Note: by default the daemon does not poll the forge for `loom:issue` items — dispatch is operator-driven via `mcp__loom__dispatch_sweep`. To dispatch a ready issue, call `mcp__loom__dispatch_sweep --issue <N>` explicitly. (The opt-in autonomous work finder (#3810, `LOOM_WORK_FINDER` / `autonomous.workFinder`, default-off) *does* poll and auto-dispatch open `loom:issue` items when enabled — see [daemon-reference.md](daemon-reference.md#autonomous-work-finder-3810).)

### Work generation (Architect / Hermit) not running

**This is by design post-v0.10.0.** The daemon does not generate work — Architect and Hermit cadence is tracked under follow-up #3381. If you need new work generated automatically, run Architect/Hermit on a cron via the Phase 2a GitHub Actions pattern (`.github/workflows/loom-*.yml`); the existing five shipped workflows cover Champion / Curator / Judge / Auditor / Guide, but Architect and Hermit cron workflows are not yet shipped.

For now, trigger them manually when the queue is empty:

```bash
claude -p "/loom:architect" --dangerously-skip-permissions
claude -p "/loom:hermit"    --dangerously-skip-permissions
```

## Overnight / long-running orchestration

### Keeping the host awake (#3350)

`/loom:sweep` automatically runs `./.loom/scripts/check-host-sleep.sh` at startup
and warns when the host can sleep. This is **advisory only** — Loom never blocks
on it. Heed the warning before walking away from a long run.

- **macOS:** user-idle sleep assertions (Amphetamine, `caffeinate -dimsu`, etc.)
  do **not** reliably defeat Maintenance Sleep on Apple Silicon. Use `sudo pmset
  -c sleep 0` for AC-only sleep disable, or flip your sleep manager's "allow
  system sleep when display is off" toggle to OFF. Restore with `sudo pmset -c
  sleep 1` afterwards.
- **systemd Linux:** wrap the session in `systemd-inhibit --what=idle:sleep
  --who=loom --why=loom -- <cmd>`.

Manual invocation:

```bash
./.loom/scripts/check-host-sleep.sh         # full warning (or success line)
./.loom/scripts/check-host-sleep.sh --quiet # stderr warning only, no stdout line
```

### Keeping installed `.loom/` copies fresh after a pull (#3770 detect → #3777 resync)

The installed `.loom/hooks/` and `.loom/scripts/` copies the harness actually
executes are synced from `defaults/` **at install time**. A `git pull` that merges
a hook/script fix updates `defaults/` but **not** the installed copies — so a
session can run stale hooks/scripts indefinitely (the incident: a merged
`guard-destructive.sh` fix kept prompting until hand-copied).

This is a **detect → fix** pair:

- **Detect (#3770)** — `/loom:sweep` runs `./.loom/scripts/check-main-freshness.sh`
  at startup. When local `main` is behind `origin/main` it prints a non-blocking
  warning and flags any installed file that differs from its `defaults/`
  counterpart. Advisory only; it never pulls, merges, or resets.
- **Fix (#3777)** — `./.loom/scripts/resync-installed.sh` refreshes the installed
  `.loom/hooks/*` and `.loom/scripts/*` from `defaults/`. Idempotent (a no-op when
  in sync), reports per-file `updated`/`created`/`unchanged`/`skipped`, and only
  ever touches files that exist in `defaults/` (repo-specific hooks with no
  `defaults/` counterpart are left alone). One exception (#4041): the vendored
  generic guard `hooks/guard-destructive-generic.sh` is **not** resynced (and any
  stale copy is removed) in a repo where the canonical Repo Skills guard
  (`.claude/skills/repo/hooks/guard-destructive.sh`, carrying the rjwalters/repo#29
  fix) is installed — the `guard-destructive.sh` dispatcher defers to the canonical
  guard there, so Loom does not resurrect its own generic copy.

The intended flow is **"freshness warning says you're stale → run resync"**:

```bash
git merge --ff-only origin/main                 # bring defaults/ current
./.loom/scripts/resync-installed.sh --dry-run   # preview what would change (exits 2 on drift)
./.loom/scripts/resync-installed.sh             # apply
```

`--dry-run` makes no changes and exits `2` when drift is detected (so it doubles
as a check). To pin an intentional per-repo customization so resync never
overwrites it, list its relative path (e.g. `hooks/guard-destructive.sh`) — one
per line — in `.loom/resync-ignore`; matching files are reported `skipped`. A full
`loom-daemon init` / installer run already performs the equivalent recursive copy,
so a normal reinstall keeps the copies current too.

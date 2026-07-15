#!/usr/bin/env bash
# spawn-codex-wave.sh - process-level fan-out for a wave of Codex sweep
# children (issue #24, follow-up to #19's single-role sequential Codex sweep
# and #20's guardrail parity). Issue #52 (follow-up to #51's two real-incident
# reproductions) hardened this script's supervision contract -- see the
# "Cancellation & the patience contract" section below before touching any of
# the trap / status-file / outcome-taxonomy code. Issue #53 added the
# claim/lease preflight gate (see "Claim/lease preflight (issue #53)" below)
# so a retry of an issue whose prior child was cancelled or crashed reclaims
# and resumes instead of silently no-op'ing on a stale loom:building label.
#
# ---------------------------------------------------------------------------
# What this is
# ---------------------------------------------------------------------------
# Codex has no Task-tool subagents (see sweep.md's "Codex strategy" section),
# so there is nothing to dispatch a `loom-builder` / `loom-judge` /
# `loom-doctor` *into* the way the Claude path does. The process-level
# analogue of Claude's `--builders-per-wave N` parallel wave is fanning out
# multiple `codex exec` children as independent OS processes — this script IS
# that fan-out.
#
# Given a wave (a list of issue numbers), this script:
#   1. Spawns one child per issue, each running the existing single-role
#      sequential Codex sweep lifecycle (Curator -> Builder -> Judge ->
#      Doctor -> Merge, one session, via spawn-codex.sh + the canonical
#      `.agents/skills/loom-sweep/SKILL.md` entry point -- the same
#      machinery #19 shipped, repointed off the retired
#      `.codex/prompts/loom-sweep.md` prompt by issue #53).
#   2. Waits for EVERY child in the wave to exit before returning.
#   3. Reports a non-zero exit code if ANY child failed.
#
# Coordination substrate decision (issue #24): direct `codex exec` child OS
# processes, NOT `mcp__loom__dispatch_sweep` (the daemon). The daemon's
# dispatch surface is issue-keyed only in v0.10.0
# (`dispatch_sweep --kind '{"Issue":N}'`) with no wave/batch primitive, so
# routing wave-level fan-out through it would require daemon-side changes
# out of scope for this issue. Direct process spawning is simpler, needs no
# daemon to be running, and mirrors spawn-codex.sh's existing single-child
# model almost exactly (this script is "N spawn-codex.sh invocations, run
# concurrently, with a join"). See `.claude/commands/loom/sweep.md`'s
# "Multi-wave process-level Codex orchestration" section for the documented
# resolution.
#
# ---------------------------------------------------------------------------
# Wave settling discipline (#3289 / this issue)
# ---------------------------------------------------------------------------
# The #3289 stream-pump stall hazard is Claude-specific (it does not apply to
# independent OS processes), but the SEQUENCING POLICY #3289 also enforces —
# "each wave fully settles before the next starts" — is preserved here by
# construction: this script blocks until every child in the wave has exited
# before returning control to its caller. A caller (the sweep skill's Codex
# strategy, an operator script, etc.) that invokes this script once per wave
# and waits for it to return gets the same "wave N+1 does not start until
# wave N has fully settled" guarantee the Claude path gets from the wave loop
# in sweep.md.
#
# ---------------------------------------------------------------------------
# Cancellation & the patience contract (issue #52)
# ---------------------------------------------------------------------------
# Two real Loom 0.10.6 incidents (see #51) showed a Codex root/supervisor
# session treating a quiet-but-alive child as "stalled" after ~94 seconds of
# no log output, sending SIGINT, declaring it "failed", and taking over
# Builder work itself mid-flight. THIS SCRIPT never did that -- it has always
# blocked in `wait` with no inactivity deadline. The premature cancellation
# in both incidents was an ad hoc policy improvised by the *supervising
# agent*, not something this runner did. That gap is closed as follows:
#
#   1. A live child is `running` by default. This script NEVER polls a
#      child's log mtime and NEVER infers a stall from silence. There is no
#      implicit inactivity timeout here, and there must never be one added.
#   2. The only ways a child's outcome becomes anything other than
#      `running` -> `completed` are (a) the child exits on its own (normal
#      completion or a real failure), (b) this script's own process receives
#      an explicit INT/TERM signal (an explicit stop -- see below), or (c)
#      the opt-in, wall-clock `LOOM_CODEX_WAVE_HARD_DEADLINE_SEC` is
#      configured and exceeded (also see below). Silence is never one of
#      these three.
#   3. Cancellation retains provenance. `_on_cancel_signal` records WHO asked
#      for the stop and HOW, and every still-running child's outcome becomes
#      `cancelled_by_operator` / `cancelled_by_parent` / `cancelled_by_deadline`
#      instead of the generic `failed` a plain nonzero exit would otherwise
#      produce. `failed` means the child's own work failed; `cancelled_*`
#      means something outside the child stopped it. These are NOT the same
#      outcome, and callers (including a future automated recovery path --
#      see issue #53) must not conflate them.
#   4. Structured, machine-readable state beats prose-log parsing. This
#      script maintains `<LOG_DIR>/spawn-codex-wave-status.json`, updated at
#      every state transition (child spawn, child terminal state, wave
#      cancellation). Read it non-destructively at any time -- including
#      while the wave is still running -- with:
#          spawn-codex-wave.sh --status
#      Reading the status file is always safe: it never mutates anything and
#      never triggers cancellation.
#
# Cancellation-outcome taxonomy (the exact vocabulary; issue #53's atomic
# reclaim/resume work is expected to consume this verbatim):
#
#   outcome              | meaning
#   ---------------------|----------------------------------------------------
#   running              | child is alive; default state, no deadline implied
#   completed            | child exited 0 on its own
#   failed               | child exited nonzero on its own (a real failure --
#                         | NOT the result of a signal this script sent)
#   cancelled_by_operator | this script's process received SIGINT (the
#                         | conventional "someone hit Ctrl-C" signal) and
#                         | forwarded it to the child
#   cancelled_by_parent   | this script's process received SIGTERM (the
#                         | conventional "a supervising process asked me to
#                         | stop" signal) and forwarded it to the child, OR
#                         | LOOM_CODEX_WAVE_CANCEL_INITIATOR explicitly named
#                         | "parent" regardless of which signal arrived
#   cancelled_by_deadline | LOOM_CODEX_WAVE_HARD_DEADLINE_SEC was configured
#                         | and this child's wall-clock runtime exceeded it
#                         | (an explicit, opt-in, non-implicit deadline --
#                         | never inferred from log inactivity)
#   unknown               | terminal state could not be determined (defensive
#                         | bucket; not expected in normal operation, only
#                         | meaningful when reading a status file whose wave
#                         | process is no longer alive to finish updating it)
#   skipped               | (issue #53) no child was spawned for this issue at
#                         | all because the claim/lease preflight found a
#                         | LIVE owner already working it -- a genuine no-op,
#                         | distinct from every outcome above. Never confuse
#                         | this with `completed`: `completed` means a child
#                         | ran and exited 0; `skipped` means no child ran.
#
# `LOOM_CODEX_WAVE_CANCEL_INITIATOR` (values: "operator" | "parent") lets an
# explicit caller override the signal-based default mapping (SIGINT ->
# operator, SIGTERM -> parent) when it knows better -- e.g. a supervising
# Claude/Codex session that always sends SIGTERM but wants to record itself
# as the parent rather than relying on the default (which already maps
# SIGTERM -> parent, so this is mostly useful for the SIGINT case, or for
# custom orchestration wrappers that document their own convention).
#
# `LOOM_CODEX_WAVE_HARD_DEADLINE_SEC` (a positive integer, seconds) is the
# ONLY inactivity-adjacent knob this script exposes, and it is explicitly
# NOT an inactivity/silence detector: it measures wall-clock time since a
# child started, not time since its last log write. Unset (the default)
# means no deadline at all -- children run to completion no matter how long
# they take or how quiet their logs are. This satisfies the umbrella issue's
# "cancellation only for ... a separately configured hard deadline" carve-out
# without reintroducing any form of silence-based stall detection.
#
# ---------------------------------------------------------------------------
# Worktree non-interference (issue #52)
# ---------------------------------------------------------------------------
# A parent/root Codex session supervising this script (or any Codex wave)
# MUST NOT enter or edit a Builder-owned worktree (`.loom/worktrees/issue-N`)
# while that Builder's child process is still alive per this script's status
# file. If a child needs help, the correct response is patience (this
# script's default), then -- only after the child has actually exited -- a
# rerun of the sweep for that issue, which reuses the same worktree via
# `worktree.sh`'s idempotency. Ad hoc takeover of a live Builder's worktree
# is exactly the failure mode #51 documented and is forbidden regardless of
# how long the child has been quiet. See `.claude/commands/loom/sweep.md`'s
# "Codex Child Supervision Contract" section for the full policy this script
# implements the mechanical half of.
#
# ---------------------------------------------------------------------------
# Claim/lease preflight (issue #53)
# ---------------------------------------------------------------------------
# The #51 incident's second half: after a Builder child was cancelled or
# crashed, rerunning `spawn-codex-wave.sh <issue>` exited 0 without doing any
# Builder work, because the ONLY signal available was the forge's
# `loom:building` label -- and a label can't tell you whether the process
# that set it is still alive. This script now consults a local, atomically-
# updated ownership lease (`sweep-claim.sh`, `.loom/sweep-claims/issue-<N>.json`)
# BEFORE spawning each child:
#
#   - If a LIVE claim exists for the issue (status=active, pid alive) --
#     i.e. #52's own structured state would show that issue as `running` --
#     this script does NOT spawn a child for it at all. The per-issue outcome
#     is `skipped`, a distinct bucket from `completed`/`failed`/`cancelled_*`
#     (see the outcome table below) -- so a retry that finds nothing to do
#     because the claim is genuinely still live is never confused with a
#     completed run in the structured status file or the summary line.
#   - Otherwise (no claim, or an orphaned claim -- status resumable/released,
#     or status active with a dead pid) the lease is atomically acquired
#     (`sweep-claim.sh acquire`, mkdir-lock guarded -- see that script's own
#     header for the concurrency guarantee) and a child IS spawned. Because
#     `worktree.sh` is idempotent, the fresh child re-enters the SAME
#     worktree and reuses whatever partial diff a prior, now-dead child left
#     behind -- no duplicate clone, no discarded work.
#   - On the child's terminal outcome, this script (which holds the lease
#     for the child's whole lifetime, by construction: it acquired the lease
#     right before forking and is the one process that `wait`s on the
#     child) releases the lease itself rather than trusting a child that may
#     have been killed to clean up after itself:
#       * `completed`            -> release --status released
#       * `failed`               -> release --status resumable
#       * `cancelled_by_*`       -> release --status resumable
#     A `resumable` lease is exactly what makes the NEXT retry's acquire
#     succeed instead of refusing -- this is the mechanical fix for the #51
#     "silent no-op rerun" defect.
#
# See `sweep-claim.sh`'s own header for the full lease schema, the mkdir-lock
# atomicity argument, and why `flock` is not used (stock-macOS compat, same
# precedent as `loom_tools.tokens.bad_tokens` and `worktree.sh`'s own
# `acquire_worktree_lock`).
#
# ---------------------------------------------------------------------------
# Opt-in gating (CONCURRENCY — orthogonal to spawn-codex.sh's permission env
# vars)
# ---------------------------------------------------------------------------
# spawn-codex.sh's LOOM_CODEX_SAFE / (deprecated) LOOM_CODEX_UNSAFE gate
# PERMISSIONS posture (sandboxed --full-auto vs. full-access
# --dangerously-bypass-approvals-and-sandbox, which is the default as of
# #31/epic #30 Phase 1). LOOM_CODEX_MULTI_WAVE gates CONCURRENCY (how many
# children run at once) and is a completely separate concern:
#
#   - LOOM_CODEX_MULTI_WAVE=1  -> a wave with N > 1 issues fans out all N
#                                 children concurrently as independent
#                                 background processes.
#   - unset / anything else    -> a wave with N > 1 issues DEGRADES TO
#                                 SEQUENTIAL processing, one issue at a time.
#                                 This is today's #19 behavior and is
#                                 unaffected by this script's existence: a
#                                 caller that never sets the opt-in gets
#                                 exactly the old sequential-per-issue
#                                 experience, just funneled through this
#                                 script instead of a bare loop.
#
# A single-issue wave (N == 1) is always effectively sequential (nothing to
# parallelize) regardless of the gate.
#
# Consistent with #19/#20's opt-in-and-loudly-documented discipline: autonomous
# multi-wave Codex sweeps with write access remain opt-in. This script does
# not change spawn-codex.sh's permission posture at all — it only decides how
# many spawn-codex.sh children run at once.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   .loom/scripts/spawn-codex-wave.sh <issue-number> [<issue-number> ...]
#   LOOM_CODEX_MULTI_WAVE=1 .loom/scripts/spawn-codex-wave.sh 100 101 102
#   .loom/scripts/spawn-codex-wave.sh --status   # non-destructive status read
#
# Env vars:
#   LOOM_CODEX_MULTI_WAVE    Opt-in concurrency gate (see above). Default: off.
#   LOOM_CODEX_SAFE          Forwarded to each spawn-codex.sh child unchanged
#                            (permissions posture opt-out; see spawn-codex.sh
#                            header). Not modified or interpreted by this
#                            script -- spawn-codex.sh's own default (full
#                            access, #31) applies to each wave child unless
#                            this is set.
#   LOOM_CODEX_UNSAFE        Deprecated no-op alias for full access, forwarded
#                            to each spawn-codex.sh child unchanged (see
#                            spawn-codex.sh header). Not modified or
#                            interpreted by this script.
#   LOOM_CODEX_WAVE_LOG_DIR  Directory for per-issue child logs AND the
#                            structured status file. Default:
#                            <repo-root>/.loom/logs (created if missing).
#                            Each child's stdout+stderr is written to
#                            <dir>/spawn-codex-wave-issue-<N>.log; the
#                            structured status file is
#                            <dir>/spawn-codex-wave-status.json (see
#                            "Cancellation & the patience contract" above).
#   LOOM_CODEX_WAVE_CANCEL_INITIATOR
#                            Override the signal->initiator mapping used on
#                            cancellation ("operator" or "parent"). Default
#                            mapping: SIGINT -> operator, SIGTERM -> parent.
#                            See "Cancellation & the patience contract" above.
#   LOOM_CODEX_WAVE_HARD_DEADLINE_SEC
#                            Opt-in wall-clock deadline (seconds) per child.
#                            NOT an inactivity/silence timer -- see
#                            "Cancellation & the patience contract" above.
#                            Default: unset (no deadline, children run to
#                            completion regardless of duration).
#   LOOM_CODEX_NO_EXEC       Test/CI hook: forwarded to spawn-codex.sh (each
#                            child prints its resolved argv instead of
#                            exec'ing codex, then exits 0). Does not change
#                            production behavior.
#   LOOM_SPAWN_CODEX_BIN     Override path to spawn-codex.sh. Default:
#                            script-relative spawn-codex.sh. Tests use this to
#                            swap in fixtures.
#   SWEEP_CLAIM_BIN          (issue #53) Override path to sweep-claim.sh, the
#                            claim/lease preflight helper this script gates
#                            each child on. Default: script-relative
#                            sweep-claim.sh. Tests use this to swap in
#                            fixtures / point at an isolated LOOM_WORKSPACE.
#   LOOM_MODEL, OPENAI_API_KEY, LOOM_WORKSPACE, LOOM_SPAWN_NO_EXPORT,
#   LOOM_PYTHON, LOOM_PACKAGE_PATH
#                            All forwarded to spawn-codex.sh unchanged; see
#                            that script's header for their semantics.
#                            LOOM_WORKSPACE is ALSO consulted directly by this
#                            script and by sweep-claim.sh to resolve
#                            `.loom/sweep-claims/` and `.loom/locks/` (issue
#                            #53) -- same resolution rule spawn-codex.sh
#                            already uses.
#
# Exit codes:
#   0    every child in the wave completed with exit 0 (or, on cancellation,
#        every child had already completed before the signal arrived, or
#        every issue in the wave was skipped because its claim was live)
#   1    at least one child exited non-zero as a genuine failure (per-issue
#        exit codes are printed) -- NOT set for cancelled or skipped children
#   78   EX_CONFIG: no issue numbers supplied, or an argument is not a
#        positive integer, or spawn-codex.sh is missing
#   130  the wave was cancelled via SIGINT (128 + signal 2)
#   143  the wave was cancelled via SIGTERM (128 + signal 15)

set -uo pipefail  # deliberately NOT -e: we must collect every child's exit
                  # code, including non-zero ones, without aborting early.

RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] WARN${NC} $*" >&2; }
log_error() { echo -e "${RED}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR${NC} $*" >&2; }

_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'
    exit 0
fi

# --- Resolve workspace / log directory (needed by --status too) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_resolve_workspace() {
    if [[ -n "${LOOM_WORKSPACE:-}" ]]; then
        printf '%s\n' "$LOOM_WORKSPACE"
        return
    fi
    local git_common_dir
    if git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"; then
        if [[ ! "$git_common_dir" = /* ]]; then
            git_common_dir="$(cd "$git_common_dir" && pwd)"
        fi
        printf '%s\n' "$(dirname "$git_common_dir")"
        return
    fi
    cd "$SCRIPT_DIR/../.." && pwd
}

if [[ -n "${LOOM_CODEX_WAVE_LOG_DIR:-}" ]]; then
    LOG_DIR="$LOOM_CODEX_WAVE_LOG_DIR"
else
    LOG_DIR="$(_resolve_workspace)/.loom/logs"
fi
STATUS_FILE="$LOG_DIR/spawn-codex-wave-status.json"

JQ_AVAILABLE=0
if command -v jq &>/dev/null; then
    JQ_AVAILABLE=1
fi

# --- Non-destructive status read (does not spawn or touch anything) ---
if [[ "${1:-}" == "--status" ]]; then
    if [[ ! -f "$STATUS_FILE" ]]; then
        echo "spawn-codex-wave: no status file found at $STATUS_FILE (no wave has run against this log dir yet)" >&2
        exit 1
    fi
    if [[ "$JQ_AVAILABLE" == "1" ]]; then
        jq '.' "$STATUS_FILE"
    else
        cat "$STATUS_FILE"
    fi
    exit 0
fi

mkdir -p "$LOG_DIR"

# --- Argument validation ---
if [[ $# -eq 0 ]]; then
    log_error "usage: spawn-codex-wave.sh <issue-number> [<issue-number> ...]"
    exit 78  # EX_CONFIG
fi

ISSUES=()
for arg in "$@"; do
    stripped="${arg#\#}"
    if ! [[ "$stripped" =~ ^[0-9]+$ ]]; then
        log_error "invalid issue number: '$arg' (expected a positive integer, optionally '#'-prefixed)"
        exit 78  # EX_CONFIG
    fi
    ISSUES+=("$stripped")
done

# --- Resolve spawn-codex.sh location ---
SPAWN_CODEX_BIN="${LOOM_SPAWN_CODEX_BIN:-$SCRIPT_DIR/spawn-codex.sh}"
if [[ ! -x "$SPAWN_CODEX_BIN" ]]; then
    log_error "spawn-codex.sh not found or not executable at: $SPAWN_CODEX_BIN"
    exit 78  # EX_CONFIG
fi

# --- Resolve sweep-claim.sh location (issue #53 claim/lease preflight) ---
SWEEP_CLAIM_BIN="${SWEEP_CLAIM_BIN:-$SCRIPT_DIR/sweep-claim.sh}"
CLAIM_GATE_AVAILABLE=1
if [[ ! -x "$SWEEP_CLAIM_BIN" ]]; then
    log_warn "sweep-claim.sh not found or not executable at: $SWEEP_CLAIM_BIN -- claim/lease preflight disabled, all issues will be spawned unconditionally (pre-#53 behavior)"
    CLAIM_GATE_AVAILABLE=0
fi

# --- Build the Codex sweep prompt for one issue ---
# Mirrors the codex branch of `encode_child_prompt` in
# loom-daemon/src/sweep_registry.rs (the daemon's own single source of truth
# for codex worker_type child prompts). This script runs independently of the
# daemon (see "Coordination substrate decision" above), so it carries its own
# equivalent copy rather than shelling out to Rust; keep the two in sync by
# hand if either wording changes. Repointed off the retired
# `.codex/prompts/loom-sweep.md` prompt onto the canonical
# `.agents/skills/loom-sweep/SKILL.md` entry point by issue #53 (both this
# copy and the Rust one were found still pointing at the retired prompt in
# the same #51/#53 reproduction that motivated the claim/lease work below).
_encode_prompt() {
    local issue="$1"
    printf 'Read the file .agents/skills/loom-sweep/SKILL.md in this repository and follow it exactly to run a Loom sweep for issue %s (treat its arguments as: %s). You are running under the Codex runtime: `codex exec` cannot resolve Claude slash commands or Codex slash-prompts, so drive the Curator -> Builder -> Judge -> Doctor -> Merge lifecycle sequentially in this one session per that skill'"'"'s Codex guidance -- do not attempt Claude Code Task-tool subagents.' "$issue" "$issue"
}

# --- Claim/lease preflight (issue #53) ---
# Returns 0 and prints the acquired run_id on stdout if this issue is safe to
# spawn a child for (no live owner). Returns 4 (sweep-claim.sh's own "refused,
# still live" exit code) and prints nothing to stdout if a live claim already
# owns the issue -- the caller must NOT spawn a child in that case. Any other
# non-zero exit (lock timeout, I/O error) is treated as "cannot determine,
# fail open and spawn anyway" -- a claim-system hiccup must never be able to
# wedge a wave that would otherwise have made progress.
#
# Uses THIS SCRIPT's own PID ($$), not the not-yet-forked child's PID, as the
# lease's liveness anchor. This is deliberate and correct: spawn-codex-wave.sh
# always forks the child and then synchronously `wait`s on it (sequentially
# per-issue, or collected and waited-on at the settling boundary in concurrent
# mode) -- so this process's lifetime is a superset of the child's lifetime by
# construction. If this process dies (killed, crashed) before the child
# settles, `$$` goes dead and the NEXT invocation's `kill -0 $$`-based
# liveness check correctly reports the claim as orphaned -- exactly the #51
# scenario this issue fixes. There is no need for a separate
# acquire-then-update-pid dance.
_claim_acquire() {
    local issue="$1"
    if [[ "$CLAIM_GATE_AVAILABLE" != "1" ]]; then
        echo ""  # no run_id to track; caller treats empty as "no claim tracked"
        return 0
    fi
    local errfile="$LOG_DIR/.claim-acquire-err.$$.$issue"
    local run_id code
    # NOTE: capture $? on the SAME line as the command substitution, not
    # after an `if cmd; then ...; fi` block -- when such a block's condition
    # is false and there is no `else`, the *if construct's own* exit status
    # is unconditionally 0 (POSIX if-semantics), which silently discards the
    # command's real exit code. This bit us during development (#53): a
    # refused acquire (exit 4) was misread as exit 0 because `local code=$?`
    # was placed after the `fi` instead of right after the substitution.
    run_id="$("$SWEEP_CLAIM_BIN" acquire "$issue" --pid "$$" --runtime codex 2>"$errfile")"
    code=$?
    if [[ "$code" -eq 0 ]]; then
        rm -f "$errfile" 2>/dev/null
        echo "$run_id"
        return 0
    fi
    local errtext=""
    [[ -f "$errfile" ]] && errtext="$(cat "$errfile" 2>/dev/null)"
    rm -f "$errfile" 2>/dev/null
    if [[ "$code" -eq 4 ]]; then
        log_warn "spawn-codex-wave: issue #$issue has a LIVE claim -- not spawning a child (retry found nothing to do; this is the #53 fix, not a bug). $errtext"
        return 4
    fi
    log_warn "spawn-codex-wave: sweep-claim.sh acquire failed for issue #$issue for a reason other than a live claim (exit $code) -- failing open and spawning anyway. $errtext"
    echo ""
    return 0
}

# Release a claim this script acquired, mapping the child's terminal outcome
# to the claim status per the "Claim/lease preflight (issue #53)" contract
# above: completed -> released, failed/cancelled_by_* -> resumable. Best
# effort -- a release failure must never fail the wave.
_claim_release() {
    local issue="$1" run_id="$2" outcome="$3"
    [[ "$CLAIM_GATE_AVAILABLE" == "1" ]] || return 0
    [[ -n "$run_id" ]] || return 0
    local status="resumable"
    [[ "$outcome" == "completed" ]] && status="released"
    "$SWEEP_CLAIM_BIN" release "$issue" --run-id "$run_id" --status "$status" \
        --reason "spawn-codex-wave.sh child outcome=$outcome" >/dev/null 2>&1 || true
}

# --- Run one issue's Codex sweep child, logging to a per-issue file ---
# Forwards --dangerously-skip-permissions so spawn-codex.sh's existing
# LOOM_CODEX_SAFE/LOOM_CODEX_UNSAFE-gated permissions mapping applies exactly
# as it does for a single-issue sweep (full access by default as of #31;
# this script does not touch that gate or duplicate its logic).
_run_child() {
    local issue="$1"
    local log_file="$LOG_DIR/spawn-codex-wave-issue-${issue}.log"
    local prompt
    prompt="$(_encode_prompt "$issue")"
    "$SPAWN_CODEX_BIN" -p "$prompt" --dangerously-skip-permissions \
        >"$log_file" 2>&1
}

TOTAL="${#ISSUES[@]}"
FAILED_ISSUES=()

# ---------------------------------------------------------------------------
# Structured per-child state (issue #52). Parallel indexed arrays keyed by
# position in ISSUES -- NOT associative arrays, because this repo targets
# stock macOS bash 3.2, which has no `declare -A` (see CLAUDE.md's
# mkdir-lock-not-flock precedent for the same macOS-compat constraint
# elsewhere in this codebase).
# ---------------------------------------------------------------------------
CHILD_PID=()
CHILD_STARTED_AT=()
CHILD_FINISHED_AT=()
CHILD_OUTCOME=()
CHILD_EXIT_CODE=()
CHILD_SIGNAL=()
CHILD_INITIATOR=()
CHILD_RUN_ID=()
DEADLINE_WATCHER_PID_FOR=()

for i in "${!ISSUES[@]}"; do
    CHILD_OUTCOME[$i]="running"
done

WAVE_STARTED_AT="$(_now)"
WAVE_CANCELLED=0
WAVE_CANCEL_INITIATOR=""
WAVE_CANCEL_SIGNAL=""

# Regenerate the structured status file from current in-memory state. Best
# effort: if jq is unavailable, this is a silent no-op (documented in the
# header) rather than a hard failure -- status reporting must never be able
# to break the wave itself.
_status_write() {
    if [[ "$JQ_AVAILABLE" != "1" ]]; then
        return 0
    fi
    local children_tmp
    children_tmp="$(mktemp 2>/dev/null)" || return 0
    : > "$children_tmp"
    local i
    for i in "${!ISSUES[@]}"; do
        jq -n \
            --arg issue "${ISSUES[$i]}" \
            --arg pid "${CHILD_PID[$i]:-}" \
            --arg outcome "${CHILD_OUTCOME[$i]:-running}" \
            --arg started_at "${CHILD_STARTED_AT[$i]:-}" \
            --arg finished_at "${CHILD_FINISHED_AT[$i]:-}" \
            --arg exit_code "${CHILD_EXIT_CODE[$i]:-}" \
            --arg signal "${CHILD_SIGNAL[$i]:-}" \
            --arg initiator "${CHILD_INITIATOR[$i]:-}" \
            --arg log_file "$LOG_DIR/spawn-codex-wave-issue-${ISSUES[$i]}.log" \
            '{
                issue: ($issue | tonumber),
                pid: (if $pid == "" then null else ($pid | tonumber) end),
                phase: null,
                outcome: $outcome,
                started_at: (if $started_at == "" then null else $started_at end),
                finished_at: (if $finished_at == "" then null else $finished_at end),
                exit_code: (if $exit_code == "" then null else ($exit_code | tonumber) end),
                signal: (if $signal == "" then null else $signal end),
                cancellation_initiator: (if $initiator == "" then null else $initiator end),
                log_file: $log_file
            }' >> "$children_tmp" 2>/dev/null
    done
    local tmp_out="${STATUS_FILE}.tmp.$$"
    if jq -s \
        --arg wave_started_at "$WAVE_STARTED_AT" \
        --arg multi_wave "${LOOM_CODEX_MULTI_WAVE:-0}" \
        --arg wave_cancelled "$WAVE_CANCELLED" \
        --arg wave_cancel_initiator "$WAVE_CANCEL_INITIATOR" \
        --arg wave_cancel_signal "$WAVE_CANCEL_SIGNAL" \
        '{
            wave_started_at: $wave_started_at,
            multi_wave: ($multi_wave == "1"),
            wave_cancelled: ($wave_cancelled == "1"),
            wave_cancel_initiator: (if $wave_cancel_initiator == "" then null else $wave_cancel_initiator end),
            wave_cancel_signal: (if $wave_cancel_signal == "" then null else $wave_cancel_signal end),
            children: .
        }' "$children_tmp" > "$tmp_out" 2>/dev/null; then
        mv "$tmp_out" "$STATUS_FILE" 2>/dev/null
    else
        rm -f "$tmp_out" 2>/dev/null
    fi
    rm -f "$children_tmp" 2>/dev/null
}

# Signal handler: an explicit stop was requested. This is the ONLY signal-
# driven path to cancellation in this script -- see "Cancellation & the
# patience contract" above. Never triggered by log inactivity.
_on_cancel_signal() {
    local sig="$1"
    if [[ "$WAVE_CANCELLED" == "1" ]]; then
        return
    fi
    WAVE_CANCELLED=1
    local initiator="${LOOM_CODEX_WAVE_CANCEL_INITIATOR:-}"
    if [[ -z "$initiator" ]]; then
        case "$sig" in
            INT) initiator="operator" ;;
            TERM) initiator="parent" ;;
            *) initiator="operator" ;;
        esac
    fi
    WAVE_CANCEL_INITIATOR="$initiator"
    WAVE_CANCEL_SIGNAL="$sig"
    log_warn "spawn-codex-wave: received SIG$sig -- cancelling wave (initiator=$initiator). Live children are still-running processes; log silence never justified this on its own -- this is an explicit stop signal to the wave runner itself."
    local i
    for i in "${!ISSUES[@]}"; do
        if [[ "${CHILD_OUTCOME[$i]:-running}" == "running" ]]; then
            CHILD_OUTCOME[$i]="cancelled_by_${initiator}"
            CHILD_SIGNAL[$i]="$sig"
            CHILD_INITIATOR[$i]="$initiator"
            CHILD_FINISHED_AT[$i]="$(_now)"
            if [[ -n "${CHILD_PID[$i]:-}" ]] && kill -0 "${CHILD_PID[$i]}" 2>/dev/null; then
                kill -s "$sig" "${CHILD_PID[$i]}" 2>/dev/null || true
                log_warn "spawn-codex-wave: forwarded SIG$sig to issue #${ISSUES[$i]} child (pid ${CHILD_PID[$i]}) -- outcome=cancelled_by_${initiator}"
            else
                log_warn "spawn-codex-wave: issue #${ISSUES[$i]} had not yet started when the cancellation arrived -- outcome=cancelled_by_${initiator}"
            fi
        fi
    done
    _status_write
}
trap '_on_cancel_signal INT' INT
trap '_on_cancel_signal TERM' TERM

_exit_code_for_signal() {
    case "$1" in
        INT) echo 130 ;;
        TERM) echo 143 ;;
        *) echo 1 ;;
    esac
}

# Opt-in, explicit, wall-clock-only deadline watcher. NOT an inactivity/
# silence timer -- see "Cancellation & the patience contract" above. Writes
# a sentinel file that _wait_and_record checks so the resulting outcome is
# `cancelled_by_deadline`, not `failed`.
_maybe_start_deadline_watcher() {
    local idx="$1"
    local pid="$2"
    local issue="${ISSUES[$idx]}"
    if [[ -z "${LOOM_CODEX_WAVE_HARD_DEADLINE_SEC:-}" ]]; then
        return
    fi
    if ! [[ "${LOOM_CODEX_WAVE_HARD_DEADLINE_SEC}" =~ ^[0-9]+$ ]] || [[ "${LOOM_CODEX_WAVE_HARD_DEADLINE_SEC}" -le 0 ]]; then
        log_warn "spawn-codex-wave: LOOM_CODEX_WAVE_HARD_DEADLINE_SEC='${LOOM_CODEX_WAVE_HARD_DEADLINE_SEC}' is not a positive integer -- ignoring (no deadline applied)"
        return
    fi
    (
        sleep "$LOOM_CODEX_WAVE_HARD_DEADLINE_SEC"
        if kill -0 "$pid" 2>/dev/null; then
            : > "$LOG_DIR/.deadline-issue-${issue}"
            kill -TERM "$pid" 2>/dev/null || true
        fi
    ) &
    DEADLINE_WATCHER_PID_FOR[$idx]="$!"
}

_reap_deadline_watcher() {
    local idx="$1"
    local watcher_pid="${DEADLINE_WATCHER_PID_FOR[$idx]:-}"
    if [[ -n "$watcher_pid" ]]; then
        kill "$watcher_pid" 2>/dev/null || true
        wait "$watcher_pid" 2>/dev/null || true
    fi
}

# Wait on exactly one pid and record its outcome. Each pid must be waited on
# EXACTLY ONCE — a second `wait <pid>` on an already-reaped background job id
# fails with "not a child of this shell" (exit 127) in bash, which would
# corrupt failure detection. This helper is the single call site for `wait`.
_wait_and_record() {
    local pid="$1"
    local idx="$2"
    local issue="${ISSUES[$idx]}"
    if wait "$pid"; then
        if [[ "${CHILD_OUTCOME[$idx]:-}" == cancelled_by_* ]]; then
            log_warn "spawn-codex-wave: issue #$issue child (pid $pid) exited 0 after a cancellation signal was already recorded -- outcome stays ${CHILD_OUTCOME[$idx]}"
        else
            CHILD_OUTCOME[$idx]="completed"
            CHILD_EXIT_CODE[$idx]=0
            CHILD_FINISHED_AT[$idx]="$(_now)"
            log_info "spawn-codex-wave: issue #$issue child (pid $pid) exited 0"
        fi
    else
        local code=$?
        if [[ "${CHILD_OUTCOME[$idx]:-}" == cancelled_by_* ]]; then
            CHILD_EXIT_CODE[$idx]="$code"
            log_warn "spawn-codex-wave: issue #$issue child (pid $pid) exited $code -- outcome=${CHILD_OUTCOME[$idx]} (cancellation, not a failure)"
        elif [[ -f "$LOG_DIR/.deadline-issue-${issue}" ]]; then
            CHILD_OUTCOME[$idx]="cancelled_by_deadline"
            CHILD_SIGNAL[$idx]="TERM"
            CHILD_INITIATOR[$idx]="deadline"
            CHILD_EXIT_CODE[$idx]="$code"
            CHILD_FINISHED_AT[$idx]="$(_now)"
            rm -f "$LOG_DIR/.deadline-issue-${issue}" 2>/dev/null
            log_warn "spawn-codex-wave: issue #$issue child (pid $pid) exited $code -- outcome=cancelled_by_deadline (LOOM_CODEX_WAVE_HARD_DEADLINE_SEC=${LOOM_CODEX_WAVE_HARD_DEADLINE_SEC} exceeded, not a failure)"
        else
            CHILD_OUTCOME[$idx]="failed"
            CHILD_EXIT_CODE[$idx]="$code"
            CHILD_FINISHED_AT[$idx]="$(_now)"
            log_warn "spawn-codex-wave: issue #$issue child (pid $pid) exited $code"
            FAILED_ISSUES+=("$issue")
        fi
    fi
    _reap_deadline_watcher "$idx"
    # Release the claim/lease this script acquired for this issue (issue
    # #53), mapping the now-final outcome to the lease status per the
    # "Claim/lease preflight" contract: completed -> released,
    # failed/cancelled_by_* -> resumable. This runner -- not the (possibly
    # already-dead) child -- is responsible for the release, because it is
    # the process that held the lease's liveness anchor ($$) the whole time.
    _claim_release "$issue" "${CHILD_RUN_ID[$idx]:-}" "${CHILD_OUTCOME[$idx]:-unknown}"
    _status_write
}

if [[ "${LOOM_CODEX_MULTI_WAVE:-}" == "1" && "$TOTAL" -gt 1 ]]; then
    log_info "spawn-codex-wave: LOOM_CODEX_MULTI_WAVE=1 -- fanning out $TOTAL children concurrently (issues: ${ISSUES[*]})"
    PIDS=()
    for i in "${!ISSUES[@]}"; do
        issue="${ISSUES[$i]}"
        if [[ "$WAVE_CANCELLED" == "1" ]]; then
            CHILD_OUTCOME[$i]="cancelled_by_${WAVE_CANCEL_INITIATOR}"
            CHILD_SIGNAL[$i]="$WAVE_CANCEL_SIGNAL"
            CHILD_INITIATOR[$i]="$WAVE_CANCEL_INITIATOR"
            log_warn "spawn-codex-wave: wave already cancelled -- not starting issue #$issue"
            continue
        fi
        # Claim/lease preflight (issue #53): skip spawning entirely if a
        # live owner already holds this issue's claim -- see "Claim/lease
        # preflight" in the header and _claim_acquire's own comment.
        claim_run_id=""
        claim_run_id="$(_claim_acquire "$issue")"
        claim_code=$?
        if [[ "$claim_code" -eq 4 ]]; then
            CHILD_OUTCOME[$i]="skipped"
            CHILD_FINISHED_AT[$i]="$(_now)"
            _status_write
            continue
        fi
        CHILD_RUN_ID[$i]="$claim_run_id"
        _run_child "$issue" &
        pid="$!"
        PIDS[$i]="$pid"
        CHILD_PID[$i]="$pid"
        CHILD_STARTED_AT[$i]="$(_now)"
        _maybe_start_deadline_watcher "$i" "$pid"
        log_info "spawn-codex-wave: started child for issue #$issue (pid $pid), log: $LOG_DIR/spawn-codex-wave-issue-${issue}.log"
        _status_write
    done
    # Settling boundary: block here until every started child in the wave
    # has exited. This is the ONLY join mechanism -- there is no polling
    # loop and no inactivity check between here and every child settling.
    for i in "${!PIDS[@]}"; do
        _wait_and_record "${PIDS[$i]}" "$i"
    done
else
    if [[ "$TOTAL" -gt 1 ]]; then
        log_info "spawn-codex-wave: LOOM_CODEX_MULTI_WAVE not set -- degrading to sequential processing for $TOTAL issues (matches issue #19 behavior; set LOOM_CODEX_MULTI_WAVE=1 to fan out concurrently)"
    else
        log_info "spawn-codex-wave: single-issue wave (#${ISSUES[0]}) -- running sequentially"
    fi
    # Sequential mode: start each child, then immediately settle it before
    # moving to the next -- one issue at a time, matching #19's behavior.
    for i in "${!ISSUES[@]}"; do
        issue="${ISSUES[$i]}"
        if [[ "$WAVE_CANCELLED" == "1" ]]; then
            CHILD_OUTCOME[$i]="cancelled_by_${WAVE_CANCEL_INITIATOR}"
            CHILD_SIGNAL[$i]="$WAVE_CANCEL_SIGNAL"
            CHILD_INITIATOR[$i]="$WAVE_CANCEL_INITIATOR"
            log_warn "spawn-codex-wave: wave already cancelled -- not starting issue #$issue"
            continue
        fi
        # Claim/lease preflight (issue #53): skip spawning entirely if a
        # live owner already holds this issue's claim -- see "Claim/lease
        # preflight" in the header and _claim_acquire's own comment.
        claim_run_id=""
        claim_run_id="$(_claim_acquire "$issue")"
        claim_code=$?
        if [[ "$claim_code" -eq 4 ]]; then
            CHILD_OUTCOME[$i]="skipped"
            CHILD_FINISHED_AT[$i]="$(_now)"
            _status_write
            continue
        fi
        CHILD_RUN_ID[$i]="$claim_run_id"
        _run_child "$issue" &
        pid="$!"
        CHILD_PID[$i]="$pid"
        CHILD_STARTED_AT[$i]="$(_now)"
        _maybe_start_deadline_watcher "$i" "$pid"
        log_info "spawn-codex-wave: started child for issue #$issue (pid $pid), log: $LOG_DIR/spawn-codex-wave-issue-${issue}.log"
        _status_write
        _wait_and_record "$pid" "$i"
    done
fi

_status_write

echo "spawn-codex-wave: wave settled -- $TOTAL issue(s), ${#FAILED_ISSUES[@]} failed" >&2

# Outcome breakdown (issue #52 AC: wave summaries distinguish completed /
# failed / cancelled / still-running-unknown; issue #53 adds `skipped` --
# see the outcome taxonomy in the header). This is an ADDITIONAL line -- the
# "wave settled" line above is kept byte-for-byte for existing callers.
N_COMPLETED=0
N_FAILED=0
N_CANCELLED=0
N_SKIPPED=0
N_UNKNOWN=0
for i in "${!ISSUES[@]}"; do
    case "${CHILD_OUTCOME[$i]:-unknown}" in
        completed) N_COMPLETED=$((N_COMPLETED + 1)) ;;
        failed) N_FAILED=$((N_FAILED + 1)) ;;
        cancelled_by_*) N_CANCELLED=$((N_CANCELLED + 1)) ;;
        skipped) N_SKIPPED=$((N_SKIPPED + 1)) ;;
        running) N_UNKNOWN=$((N_UNKNOWN + 1)) ;;
        *) N_UNKNOWN=$((N_UNKNOWN + 1)) ;;
    esac
done
echo "spawn-codex-wave: outcome breakdown -- completed=$N_COMPLETED failed=$N_FAILED cancelled=$N_CANCELLED skipped=$N_SKIPPED still-running-or-unknown=$N_UNKNOWN" >&2

if [[ "$WAVE_CANCELLED" == "1" ]]; then
    log_error "spawn-codex-wave: wave cancelled via SIG${WAVE_CANCEL_SIGNAL} (initiator=${WAVE_CANCEL_INITIATOR})"
    exit "$(_exit_code_for_signal "$WAVE_CANCEL_SIGNAL")"
fi

if [[ "${#FAILED_ISSUES[@]}" -gt 0 ]]; then
    log_error "spawn-codex-wave: failed issues: ${FAILED_ISSUES[*]}"
    exit 1
fi

exit 0

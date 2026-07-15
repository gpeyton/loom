#!/usr/bin/env bash
# spawn-codex-wave.sh - process-level fan-out for a wave of Codex sweep
# children (issue #24, follow-up to #19's single-role sequential Codex sweep
# and #20's guardrail parity).
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
#      Doctor -> Merge, one session, via spawn-codex.sh + the
#      `.codex/prompts/loom-sweep.md` shim — the same machinery #19 shipped).
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
# Opt-in gating (CONCURRENCY — orthogonal to LOOM_CODEX_UNSAFE)
# ---------------------------------------------------------------------------
# LOOM_CODEX_UNSAFE (spawn-codex.sh) gates PERMISSIONS posture (sandbox vs.
# bypass-everything). LOOM_CODEX_MULTI_WAVE gates CONCURRENCY (how many
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
#
# Env vars:
#   LOOM_CODEX_MULTI_WAVE    Opt-in concurrency gate (see above). Default: off.
#   LOOM_CODEX_UNSAFE        Forwarded to each spawn-codex.sh child unchanged
#                            (permissions posture; see spawn-codex.sh header).
#                            Not modified or interpreted by this script.
#   LOOM_CODEX_WAVE_LOG_DIR  Directory for per-issue child logs. Default:
#                            <repo-root>/.loom/logs (created if missing).
#                            Each child's stdout+stderr is written to
#                            <dir>/spawn-codex-wave-issue-<N>.log.
#   LOOM_CODEX_NO_EXEC       Test/CI hook: forwarded to spawn-codex.sh (each
#                            child prints its resolved argv instead of
#                            exec'ing codex, then exits 0). Does not change
#                            production behavior.
#   LOOM_SPAWN_CODEX_BIN     Override path to spawn-codex.sh. Default:
#                            script-relative spawn-codex.sh. Tests use this to
#                            swap in fixtures.
#   LOOM_MODEL, OPENAI_API_KEY, LOOM_WORKSPACE, LOOM_SPAWN_NO_EXPORT,
#   LOOM_PYTHON, LOOM_PACKAGE_PATH
#                            All forwarded to spawn-codex.sh unchanged; see
#                            that script's header for their semantics.
#
# Exit codes:
#   0   every child in the wave exited 0
#   1   at least one child exited non-zero (per-issue exit codes are printed)
#   78  EX_CONFIG: no issue numbers supplied, or an argument is not a
#       positive integer

set -uo pipefail  # deliberately NOT -e: we must collect every child's exit
                  # code, including non-zero ones, without aborting early.

RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] WARN${NC} $*" >&2; }
log_error() { echo -e "${RED}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR${NC} $*" >&2; }

# --- Help ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'
    exit 0
fi

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN_CODEX_BIN="${LOOM_SPAWN_CODEX_BIN:-$SCRIPT_DIR/spawn-codex.sh}"
if [[ ! -x "$SPAWN_CODEX_BIN" ]]; then
    log_error "spawn-codex.sh not found or not executable at: $SPAWN_CODEX_BIN"
    exit 78  # EX_CONFIG
fi

# --- Resolve log directory ---
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
mkdir -p "$LOG_DIR"

# --- Build the Codex sweep prompt for one issue ---
# Mirrors the codex branch of `encode_child_prompt` in
# loom-daemon/src/sweep_registry.rs (the daemon's own single source of truth
# for codex worker_type child prompts). This script runs independently of the
# daemon (see "Coordination substrate decision" above), so it carries its own
# equivalent copy rather than shelling out to Rust; keep the two in sync by
# hand if either wording changes.
_encode_prompt() {
    local issue="$1"
    printf 'Read the file .codex/prompts/loom-sweep.md in this repository and follow it exactly to run a Loom sweep for issue %s (treat its arguments as: %s). You are running under the Codex runtime: `codex exec` cannot resolve Claude slash commands or Codex slash-prompts, so drive the Curator -> Builder -> Judge -> Doctor -> Merge lifecycle sequentially in this one session per that shim'"'"'s Codex guidance -- do not attempt Claude Code Task-tool subagents.' "$issue" "$issue"
}

# --- Run one issue's Codex sweep child, logging to a per-issue file ---
# Forwards --dangerously-skip-permissions so spawn-codex.sh's existing
# LOOM_CODEX_UNSAFE-gated permissions mapping applies exactly as it does for
# a single-issue sweep; this script does not touch that gate.
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

# Wait on exactly one pid and record its outcome. Each pid must be waited on
# EXACTLY ONCE — a second `wait <pid>` on an already-reaped background job id
# fails with "not a child of this shell" (exit 127) in bash, which would
# corrupt failure detection. This helper is the single call site for `wait`.
_wait_and_record() {
    local pid="$1" issue="$2"
    if wait "$pid"; then
        log_info "spawn-codex-wave: issue #$issue child (pid $pid) exited 0"
    else
        local code=$?
        log_warn "spawn-codex-wave: issue #$issue child (pid $pid) exited $code"
        FAILED_ISSUES+=("$issue")
    fi
}

if [[ "${LOOM_CODEX_MULTI_WAVE:-}" == "1" && "$TOTAL" -gt 1 ]]; then
    log_info "spawn-codex-wave: LOOM_CODEX_MULTI_WAVE=1 -- fanning out $TOTAL children concurrently (issues: ${ISSUES[*]})"
    PIDS=()
    for issue in "${ISSUES[@]}"; do
        _run_child "$issue" &
        pid="$!"
        PIDS+=("$pid")
        log_info "spawn-codex-wave: started child for issue #$issue (pid $pid), log: $LOG_DIR/spawn-codex-wave-issue-${issue}.log"
    done
    # Settling boundary: block here until every child in the wave has exited.
    for i in "${!PIDS[@]}"; do
        _wait_and_record "${PIDS[$i]}" "${ISSUES[$i]}"
    done
else
    if [[ "$TOTAL" -gt 1 ]]; then
        log_info "spawn-codex-wave: LOOM_CODEX_MULTI_WAVE not set -- degrading to sequential processing for $TOTAL issues (matches issue #19 behavior; set LOOM_CODEX_MULTI_WAVE=1 to fan out concurrently)"
    else
        log_info "spawn-codex-wave: single-issue wave (#${ISSUES[0]}) -- running sequentially"
    fi
    # Sequential mode: start each child, then immediately settle it before
    # moving to the next -- one issue at a time, matching #19's behavior.
    for issue in "${ISSUES[@]}"; do
        _run_child "$issue" &
        pid="$!"
        log_info "spawn-codex-wave: started child for issue #$issue (pid $pid), log: $LOG_DIR/spawn-codex-wave-issue-${issue}.log"
        _wait_and_record "$pid" "$issue"
    done
fi

echo "spawn-codex-wave: wave settled -- $TOTAL issue(s), ${#FAILED_ISSUES[@]} failed" >&2

if [[ "${#FAILED_ISSUES[@]}" -gt 0 ]]; then
    log_error "spawn-codex-wave: failed issues: ${FAILED_ISSUES[*]}"
    exit 1
fi

exit 0

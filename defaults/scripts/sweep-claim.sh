#!/usr/bin/env bash
# sweep-claim.sh - Atomic ownership lease for a sweep's Builder claim on an
# issue (issue #53, follow-up to #52's cancellation-outcome taxonomy and #51's
# two real-incident reproductions).
#
# ---------------------------------------------------------------------------
# The problem this closes
# ---------------------------------------------------------------------------
# A Codex Builder interrupted mid-flight (curator-done checkpoint, loom:building
# label set, worktree + partial diff present, no PR opened) left a claim that
# looked identical -- from the forge's point of view -- to a live, healthy
# Builder still working. The documented recovery path ("rerun the sweep for
# the issue") could not distinguish the two cases, because `loom:building` is
# a GitHub label, not a liveness signal: the forge has no idea whether the
# process that set it is still alive. Preflight therefore had to guess, and it
# guessed "still owned" -- the safe-looking but wrong answer that produced a
# silent no-op retry (exit 0, no Builder work done).
#
# This script is the missing liveness signal: a small per-issue JSON lease
# file recording WHO holds the Builder claim (a run_id) and WHETHER that
# holder's process is still alive (a PID, checked with `kill -0`). Any caller
# -- spawn-codex-wave.sh, a Claude Task-tool builder subagent, a human running
# stale-building-check.sh --recover -- can ask a single question ("is this
# claim live or orphaned?") and get a locally-verifiable answer instead of
# trusting a forge label that only ever moves one direction on its own.
#
# ---------------------------------------------------------------------------
# Lease file
# ---------------------------------------------------------------------------
#   .loom/sweep-claims/issue-<N>.json
#
#   {
#     "issue": 53,
#     "run_id": "<opaque string, e.g. spawn-codex-wave-<pid>-<epoch>>",
#     "runtime": "codex" | "claude" | "manual",
#     "pid": 12345,
#     "status": "active" | "resumable" | "released",
#     "claimed_at": "<ISO 8601 UTC>",
#     "last_seen_at": "<ISO 8601 UTC>",
#     "reason": "<optional free-text, set on release>"
#   }
#
# A claim is LIVE iff status == "active" AND `kill -0 pid` succeeds. Every
# other combination (no file at all, status resumable/released, or status
# active with a dead pid) is ORPHANED/RECLAIMABLE -- this is deliberately a
# narrow, mechanically-checkable definition with no time-based heuristics
# (no "stale after N hours" guessing here; that guesswork, when still useful
# as an operator-facing summary, lives in stale-building-check.sh, which is a
# read-mostly reporting layer on top of this primitive, not a second source
# of truth).
#
# Releasing a claim (`release`) NEVER deletes the file -- it flips `status`
# to `resumable` (the normal case: cancelled/failed and safe to hand to the
# next attempt) or `released` (explicit final state, e.g. after a merge) and
# updates `last_seen_at`. This preserves audit history and matches the
# existing sweep-checkpoint.sh convention of leaving a record behind rather
# than erasing state on every transition. Use `delete` for the one case where
# removal is actually correct: after `merge-done`, mirroring
# sweep-checkpoint.sh's own delete-on-merge lifecycle.
#
# ---------------------------------------------------------------------------
# Atomicity (mkdir lock, NOT flock)
# ---------------------------------------------------------------------------
# Every mutating operation (acquire/update/release/delete) runs its
# read-modify-write under a short-lived mkdir-based lock at
# `.loom/locks/claim-issue-<N>/` -- mkdir is the only POSIX-atomic primitive
# available on stock macOS (flock is Linux-only; see CLAUDE.md's
# loom_tools.tokens.bad_tokens precedent and worktree.sh's
# acquire_worktree_lock, which this mirrors). Two concurrent `acquire` calls
# for the same issue race on the mkdir(2) syscall itself: exactly one wins,
# creates/updates the lease file while holding the lock, and releases the
# lock; the loser blocks briefly on the lock, then re-reads the (now updated)
# lease file and correctly refuses -- it does not blindly overwrite. This is
# the core guarantee issue #53 requires: "two concurrent retries must not
# both become Builder."
#
# Stale-lock recovery mirrors worktree.sh's acquire_worktree_lock: if the
# lock directory's owner PID is dead, clear it once and retry immediately
# rather than waiting out the full timeout.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   sweep-claim.sh acquire <issue> --pid PID [--runtime codex|claude|manual] [--run-id ID]
#       Attempt to atomically claim issue <issue>. On success, prints the
#       run_id to stdout and exits 0. On failure (an existing claim is live),
#       exits 4 and prints nothing to stdout (diagnostic to stderr).
#
#   sweep-claim.sh update <issue> --run-id ID [--pid PID]
#       Update pid/last_seen_at on the current claim, IF <issue>'s claim's
#       run_id matches ID (ownership check). Exits 1 on run_id mismatch or no
#       claim present.
#
#   sweep-claim.sh heartbeat <issue> --run-id ID
#       Update last_seen_at only, same ownership check as `update`.
#
#   sweep-claim.sh release <issue> --run-id ID [--status resumable|released] [--reason TEXT]
#       Mark the claim resumable (default) or released, IF run_id matches.
#       Never deletes the file. No-op success (exit 0) if the claim is
#       already non-active or absent -- release is idempotent.
#
#   sweep-claim.sh delete <issue>
#       Unconditionally remove the claim file (used after merge-done, or by
#       an operator explicitly resetting state). No ownership check --
#       this is the deliberately-unsafe operator escape hatch, same posture
#       as sweep-checkpoint.sh's own `delete`.
#
#   sweep-claim.sh status <issue>
#       Print the claim JSON (or a one-line "no claim" message) to stdout.
#       Exit 0 if a claim file exists, 1 if not. Never mutates.
#
#   sweep-claim.sh is-live <issue>
#       Exit 0 if a claim exists, status == "active", and its pid is alive.
#       Exit 1 in every other case (no claim / resumable / released /
#       active-but-dead-pid). Never mutates. This is the single question
#       every caller in this issue actually needs answered.
#
# Exit codes:
#   0  success (or is-live: true)
#   1  not found / not live / ownership mismatch (see per-command notes)
#   2  usage error
#   3  I/O or lock-acquisition failure
#   4  acquire refused: an existing claim is live (do not disturb)

set -uo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_warn() { echo -e "${YELLOW}[sweep-claim] WARN${NC} $*" >&2; }
log_error() { echo -e "${RED}[sweep-claim] ERROR${NC} $*" >&2; }

LOCK_TIMEOUT_SEC="${SWEEP_CLAIM_LOCK_TIMEOUT_SEC:-10}"
LOCK_POLL_SEC="${SWEEP_CLAIM_LOCK_POLL_SEC:-0.2}"

iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

repo_root() {
    if [[ -n "${LOOM_WORKSPACE:-}" ]]; then
        printf '%s\n' "$LOOM_WORKSPACE"
        return
    fi
    local common
    common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    if [[ -n "$common" ]]; then
        local abs_common
        abs_common="$(cd "$common" 2>/dev/null && pwd)" || abs_common="$common"
        dirname "$abs_common"
        return
    fi
    pwd
}

claims_dir() { echo "$(repo_root)/.loom/sweep-claims"; }
claim_file() { echo "$(claims_dir)/issue-${1}.json"; }
locks_dir() { echo "$(repo_root)/.loom/locks"; }
lock_path() { echo "$(locks_dir)/claim-issue-${1}"; }

validate_issue() {
    local issue="$1"
    if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
        log_error "issue must be a positive integer (got: '$issue')"
        exit 2
    fi
}

# --- mkdir-based lock, mirrors worktree.sh's acquire_worktree_lock ---------
_acquire_lock() {
    local issue="$1"
    local lock
    lock="$(lock_path "$issue")"
    mkdir -p "$(locks_dir)" 2>/dev/null || true

    local deadline
    deadline=$(( $(date +%s) + LOCK_TIMEOUT_SEC ))
    local stale_retry_done=0

    while true; do
        if mkdir "$lock" 2>/dev/null; then
            printf '{"owner_pid": %d, "acquired_at": "%s"}\n' "$$" "$(iso_now)" > "$lock/owner.json" 2>/dev/null || true
            return 0
        fi

        local owner_pid=""
        if [[ -f "$lock/owner.json" ]]; then
            owner_pid="$(sed -n 's/.*"owner_pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$lock/owner.json" 2>/dev/null | head -n1)"
        fi

        if [[ -n "$owner_pid" && "$stale_retry_done" -eq 0 ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
            log_warn "stale claim lock from dead PID $owner_pid on issue $issue -- clearing"
            rm -rf "$lock" 2>/dev/null || true
            stale_retry_done=1
            continue
        fi

        if [[ "$(date +%s)" -ge "$deadline" ]]; then
            return 1
        fi
        sleep "$LOCK_POLL_SEC"
    done
}

_release_lock() {
    local issue="$1"
    rm -rf "$(lock_path "$issue")" 2>/dev/null || true
}

# --- claim file read helpers (no lock needed for pure reads) ---------------
_field() {
    # _field <file> <key> -- extracts a scalar (string or number) JSON value
    # via sed; good enough for this script's own hand-rolled, single-level
    # JSON (mirrors sweep-checkpoint.sh's cmd_phase approach; no jq hard dep).
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" 2>/dev/null | head -n1
}

_field_num() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$file" 2>/dev/null | head -n1
}

_pid_alive() {
    local pid="$1"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# _claim_is_live <file> -- exit 0 if status==active AND pid alive
_claim_is_live() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local status pid
    status="$(_field "$file" status)"
    pid="$(_field_num "$file" pid)"
    [[ "$status" == "active" ]] || return 1
    _pid_alive "$pid"
}

_write_claim() {
    local file="$1" issue="$2" run_id="$3" runtime="$4" pid="$5" status="$6" claimed_at="$7" reason="${8:-}"
    local tmp="${file}.tmp.$$"
    local reason_json=""
    [[ -n "$reason" ]] && reason_json=$',\n  "reason": "'"$reason"'"'
    cat > "$tmp" <<EOF
{
  "issue": $issue,
  "run_id": "$run_id",
  "runtime": "$runtime",
  "pid": $pid,
  "status": "$status",
  "claimed_at": "$claimed_at",
  "last_seen_at": "$(iso_now)"$reason_json
}
EOF
    mv "$tmp" "$file"
}

_gen_run_id() {
    local runtime="$1"
    echo "${runtime}-$$-$(date +%s)"
}

cmd_acquire() {
    local issue="${1:-}"; shift || true
    validate_issue "$issue"
    local pid="" runtime="manual" run_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pid) pid="${2:-}"; shift 2 ;;
            --runtime) runtime="${2:-manual}"; shift 2 ;;
            --run-id) run_id="${2:-}"; shift 2 ;;
            *) log_error "acquire: unknown flag '$1'"; exit 2 ;;
        esac
    done
    [[ -z "$pid" ]] && pid="$$"
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        log_error "acquire: --pid must be a positive integer (got: '$pid')"
        exit 2
    fi
    [[ -z "$run_id" ]] && run_id="$(_gen_run_id "$runtime")"

    mkdir -p "$(claims_dir)" 2>/dev/null || true
    local file
    file="$(claim_file "$issue")"

    if ! _acquire_lock "$issue"; then
        log_error "acquire: timed out waiting for claim lock on issue $issue after ${LOCK_TIMEOUT_SEC}s"
        exit 3
    fi

    if _claim_is_live "$file"; then
        local existing_run_id
        existing_run_id="$(_field "$file" run_id)"
        _release_lock "$issue"
        log_error "acquire: issue $issue has a live claim (run_id=$existing_run_id) -- refusing to reclaim"
        exit 4
    fi

    _write_claim "$file" "$issue" "$run_id" "$runtime" "$pid" "active" "$(iso_now)"
    _release_lock "$issue"
    echo "$run_id"
    return 0
}

cmd_update() {
    local issue="${1:-}"; shift || true
    validate_issue "$issue"
    local run_id="" pid=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-id) run_id="${2:-}"; shift 2 ;;
            --pid) pid="${2:-}"; shift 2 ;;
            *) log_error "update: unknown flag '$1'"; exit 2 ;;
        esac
    done
    [[ -z "$run_id" ]] && { log_error "update: --run-id is required"; exit 2; }

    local file
    file="$(claim_file "$issue")"
    if ! _acquire_lock "$issue"; then
        log_error "update: timed out waiting for claim lock on issue $issue"
        exit 3
    fi

    if [[ ! -f "$file" ]]; then
        _release_lock "$issue"
        log_error "update: no claim exists for issue $issue"
        exit 1
    fi
    local existing_run_id
    existing_run_id="$(_field "$file" run_id)"
    if [[ "$existing_run_id" != "$run_id" ]]; then
        _release_lock "$issue"
        log_error "update: run_id mismatch for issue $issue (have '$existing_run_id', caller supplied '$run_id') -- ownership lost, refusing"
        exit 1
    fi

    local runtime cur_pid status claimed_at
    runtime="$(_field "$file" runtime)"
    cur_pid="$(_field_num "$file" pid)"
    status="$(_field "$file" status)"
    claimed_at="$(_field "$file" claimed_at)"
    [[ -n "$pid" ]] && cur_pid="$pid"

    _write_claim "$file" "$issue" "$run_id" "$runtime" "$cur_pid" "$status" "$claimed_at"
    _release_lock "$issue"
    return 0
}

cmd_heartbeat() {
    cmd_update "$@"
}

cmd_release() {
    local issue="${1:-}"; shift || true
    validate_issue "$issue"
    local run_id="" status="resumable" reason=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-id) run_id="${2:-}"; shift 2 ;;
            --status) status="${2:-resumable}"; shift 2 ;;
            --reason) reason="${2:-}"; shift 2 ;;
            *) log_error "release: unknown flag '$1'"; exit 2 ;;
        esac
    done
    if [[ "$status" != "resumable" && "$status" != "released" ]]; then
        log_error "release: --status must be 'resumable' or 'released' (got: '$status')"
        exit 2
    fi
    [[ -z "$run_id" ]] && { log_error "release: --run-id is required"; exit 2; }

    local file
    file="$(claim_file "$issue")"
    if ! _acquire_lock "$issue"; then
        log_error "release: timed out waiting for claim lock on issue $issue"
        exit 3
    fi

    if [[ ! -f "$file" ]]; then
        # Idempotent: nothing to release.
        _release_lock "$issue"
        return 0
    fi
    local existing_run_id
    existing_run_id="$(_field "$file" run_id)"
    if [[ "$existing_run_id" != "$run_id" ]]; then
        _release_lock "$issue"
        log_warn "release: run_id mismatch for issue $issue (have '$existing_run_id', caller supplied '$run_id') -- not releasing (no longer owner)"
        return 0
    fi

    local runtime cur_pid claimed_at
    runtime="$(_field "$file" runtime)"
    cur_pid="$(_field_num "$file" pid)"
    claimed_at="$(_field "$file" claimed_at)"

    _write_claim "$file" "$issue" "$run_id" "$runtime" "$cur_pid" "$status" "$claimed_at" "$reason"
    _release_lock "$issue"
    return 0
}

cmd_delete() {
    local issue="${1:-}"
    validate_issue "$issue"
    if ! _acquire_lock "$issue"; then
        log_error "delete: timed out waiting for claim lock on issue $issue"
        exit 3
    fi
    local file
    file="$(claim_file "$issue")"
    rm -f "$file" 2>/dev/null || true
    _release_lock "$issue"
    return 0
}

cmd_status() {
    local issue="${1:-}"
    validate_issue "$issue"
    local file
    file="$(claim_file "$issue")"
    if [[ ! -f "$file" ]]; then
        echo "no claim for issue $issue"
        return 1
    fi
    cat "$file"
    return 0
}

cmd_is_live() {
    local issue="${1:-}"
    validate_issue "$issue"
    local file
    file="$(claim_file "$issue")"
    _claim_is_live "$file"
}

usage() {
    sed -n '108,145p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        acquire)   cmd_acquire "$@" ;;
        update)    cmd_update "$@" ;;
        heartbeat) cmd_heartbeat "$@" ;;
        release)   cmd_release "$@" ;;
        delete)    cmd_delete "$@" ;;
        status)    cmd_status "$@" ;;
        is-live)   cmd_is_live "$@" ;;
        -h|--help|"") usage ;;
        *) log_error "unknown command '$cmd'"; usage ;;
    esac
}

main "$@"

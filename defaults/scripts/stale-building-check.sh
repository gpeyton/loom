#!/usr/bin/env bash
# stale-building-check.sh - Detect (and optionally recover) issues stuck in
# loom:building with no live owner (issue #53).
#
# This is the real implementation of the recovery helper that Loom's own
# troubleshooting docs (.loom/docs/troubleshooting.md, CLAUDE.md's "Quick
# fixes", defaults/.loom/AGENTS.md) have documented by name and flag set for
# some time, without the script itself existing in the repo -- a
# packaging/doc-drift bug identified in the same #51/#53 reproduction that
# motivated the claim/lease work in sweep-claim.sh. The interface below
# (--recover, --verbose, --json, STALE_THRESHOLD_HOURS, STALE_WITH_PR_HOURS)
# matches those existing docs exactly so no further doc changes are required
# once this script ships.
#
# ---------------------------------------------------------------------------
# What "stale" means (real liveness first, time-based heuristic as fallback)
# ---------------------------------------------------------------------------
# For every open issue labeled loom:building:
#
#   1. Consult its sweep-claim.sh lease (.loom/sweep-claims/issue-<N>.json).
#      - If the claim is LIVE (status=active, pid alive) -> the issue has a
#        real, currently-running owner. NOT stale, regardless of age. This is
#        the #53 fix: a locally-verifiable liveness check replaces guessing
#        from label age alone.
#      - If a claim exists but is ORPHANED (status resumable/released, or
#        status active with a dead pid) -> the claim is definitively
#        recoverable *right now*, independent of any time threshold. This is
#        the common case after a cancelled/failed Codex wave child (#52's
#        cancelled_by_* / failed outcomes).
#      - If NO claim file exists at all (legacy claims predating this
#        mechanism, or claims made by a runtime that never registered one) ->
#        fall back to the original time-based heuristic
#        (STALE_THRESHOLD_HOURS / STALE_WITH_PR_HOURS) so this script never
#        regresses on issues outside sweep-claim.sh's visibility.
#
#   2. Check for an existing OPEN linked PR (closedByPullRequestsReferences,
#      the same GitHub-native parser convention sweep.md's pre-flight and
#      #3359 use -- no body-grepping for "Closes #N").
#      - Open PR present -> flagged, but NEVER auto-recovered (a human should
#        look at why the PR hasn't merged before anyone touches the label).
#      - No open PR -> eligible for recovery once "stale" per step 1.
#
# ---------------------------------------------------------------------------
# Recovery action (--recover)
# ---------------------------------------------------------------------------
# For each eligible issue: reset the label (loom:building -> loom:issue),
# release the claim to "resumable" (best-effort -- uses the claim's own
# run_id read from the lease file so the release's ownership check passes;
# if no claim exists there is nothing to release), and post a short recovery
# comment on the issue for the audit trail. Dry-run (the default, no
# --recover) never mutates anything -- it only reports.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   stale-building-check.sh                # dry run, human-readable summary
#   stale-building-check.sh --verbose       # dry run, per-issue detail
#   stale-building-check.sh --recover       # actually recover eligible issues
#   stale-building-check.sh --json          # JSON output (dry run unless --recover also given)
#
# Env:
#   STALE_THRESHOLD_HOURS=2   Hours before a claim-less building issue
#                             without a PR is considered stale (fallback
#                             heuristic only -- see above).
#   STALE_WITH_PR_HOURS=24    Hours before a building issue WITH an open PR
#                             is flagged for human attention (display only;
#                             never auto-recovered).
#
# Exit codes:
#   0  ran successfully (regardless of whether any stale issues were found)
#   1  gh invocation failed / repo unreachable
#   2  usage error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP_CLAIM_BIN="${SWEEP_CLAIM_BIN:-$SCRIPT_DIR/sweep-claim.sh}"

STALE_THRESHOLD_HOURS="${STALE_THRESHOLD_HOURS:-2}"
STALE_WITH_PR_HOURS="${STALE_WITH_PR_HOURS:-24}"

VERBOSE=0
RECOVER=0
JSON_OUTPUT=0

for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=1 ;;
        --recover) RECOVER=1 ;;
        --json) JSON_OUTPUT=1 ;;
        -h|--help)
            sed -n '3,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$arg'" >&2
            exit 2
            ;;
    esac
done

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { [[ "$JSON_OUTPUT" == "1" ]] || echo -e "$*"; }
vlog() { [[ "$VERBOSE" == "1" && "$JSON_OUTPUT" != "1" ]] && echo -e "$*"; }

_now_epoch() { date -u +%s; }

_iso_to_epoch() {
    # Portable ISO8601 UTC -> epoch (handles both GNU and BSD date).
    local iso="$1"
    date -u -d "$iso" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null || echo 0
}

_hours_since() {
    local iso="$1"
    # NOTE: deliberately not named `then`/`now` -- `then` is a bash reserved
    # word and using it as a plain variable name confuses shellcheck's
    # parser (SC1010, "use semicolon or linefeed before 'then'") even though
    # bash itself accepts it. Use unambiguous names instead.
    local then_epoch now_epoch
    then_epoch="$(_iso_to_epoch "$iso")"
    now_epoch="$(_now_epoch)"
    [[ "$then_epoch" -eq 0 ]] && { echo 0; return; }
    echo $(( (now_epoch - then_epoch) / 3600 ))
}

if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI not found" >&2
    exit 1
fi

ISSUES_JSON="$(gh issue list --label "loom:building" --state open --limit 100 \
    --json number,title,updatedAt,closedByPullRequestsReferences 2>&1)"
if [[ $? -ne 0 ]]; then
    echo "ERROR: gh issue list failed: $ISSUES_JSON" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required" >&2
    exit 1
fi

COUNT="$(echo "$ISSUES_JSON" | jq 'length')"
log "${BLUE}stale-building-check:${NC} $COUNT issue(s) currently labeled loom:building"

RESULTS_JSON="[]"
STALE_COUNT=0
RECOVERED_COUNT=0
FLAGGED_WITH_PR_COUNT=0
LIVE_COUNT=0

for i in $(seq 0 $((COUNT - 1))); do
    row="$(echo "$ISSUES_JSON" | jq -c ".[$i]")"
    N="$(echo "$row" | jq -r '.number')"
    TITLE="$(echo "$row" | jq -r '.title')"
    UPDATED_AT="$(echo "$row" | jq -r '.updatedAt')"

    # Open-PR probe (closedByPullRequestsReferences, GitHub-native parser --
    # matches sweep.md's pre-flight and #3359's convention).
    OPEN_PR=""
    PR_URLS="$(echo "$row" | jq -r '.closedByPullRequestsReferences[]?.url // empty')"
    if [[ -n "$PR_URLS" ]]; then
        while IFS= read -r pr_url; do
            [[ -z "$pr_url" ]] && continue
            pr_state="$(gh pr view "$pr_url" --json state --jq '.state' 2>/dev/null || echo "")"
            if [[ "$pr_state" == "OPEN" ]]; then
                OPEN_PR="$pr_url"
                break
            fi
        done <<< "$PR_URLS"
    fi

    # Claim liveness (the #53 fix -- primary signal).
    CLAIM_STATUS="no-claim"
    CLAIM_RUN_ID=""
    if "$SWEEP_CLAIM_BIN" is-live "$N" >/dev/null 2>&1; then
        CLAIM_STATUS="live"
    else
        claim_text="$("$SWEEP_CLAIM_BIN" status "$N" 2>/dev/null || true)"
        if [[ "$claim_text" == "{"* ]]; then
            CLAIM_STATUS="orphaned"
            CLAIM_RUN_ID="$(echo "$claim_text" | jq -r '.run_id // empty' 2>/dev/null)"
        else
            CLAIM_STATUS="no-claim"
        fi
    fi

    AGE_HOURS="$(_hours_since "$UPDATED_AT")"

    # Classification.
    ACTION="skip"
    REASON=""
    if [[ "$CLAIM_STATUS" == "live" ]]; then
        ACTION="skip"
        REASON="live owner (claim active, pid alive)"
        LIVE_COUNT=$((LIVE_COUNT + 1))
    elif [[ -n "$OPEN_PR" ]]; then
        ACTION="flag"
        REASON="open PR in flight ($OPEN_PR); needs human review, not auto-recovered"
        FLAGGED_WITH_PR_COUNT=$((FLAGGED_WITH_PR_COUNT + 1))
        if [[ "$AGE_HOURS" -lt "$STALE_WITH_PR_HOURS" ]]; then
            REASON="$REASON (age ${AGE_HOURS}h < STALE_WITH_PR_HOURS=${STALE_WITH_PR_HOURS}h, informational only)"
        fi
    elif [[ "$CLAIM_STATUS" == "orphaned" ]]; then
        # Definitive proof the owner is dead -- no need to wait out a
        # time threshold; this is the whole point of the #53 fix.
        ACTION="stale"
        REASON="claim orphaned (owner process no longer alive, run_id=$CLAIM_RUN_ID), no open PR"
        STALE_COUNT=$((STALE_COUNT + 1))
    else
        # No claim on record at all -- fall back to the original
        # time-based heuristic so pre-#53 / non-claim-registering runtimes
        # are still covered.
        if [[ "$AGE_HOURS" -ge "$STALE_THRESHOLD_HOURS" ]]; then
            ACTION="stale"
            REASON="no claim on record, no open PR, age ${AGE_HOURS}h >= STALE_THRESHOLD_HOURS=${STALE_THRESHOLD_HOURS}h"
            STALE_COUNT=$((STALE_COUNT + 1))
        else
            ACTION="skip"
            REASON="no claim on record, no open PR, but age ${AGE_HOURS}h < STALE_THRESHOLD_HOURS=${STALE_THRESHOLD_HOURS}h (too young to call stale)"
        fi
    fi

    RECOVERED="false"
    if [[ "$ACTION" == "stale" && "$RECOVER" == "1" ]]; then
        gh issue edit "$N" --remove-label "loom:building" --add-label "loom:issue" >/dev/null 2>&1 || true
        if [[ -n "$CLAIM_RUN_ID" ]]; then
            "$SWEEP_CLAIM_BIN" release "$N" --run-id "$CLAIM_RUN_ID" --status resumable \
                --reason "recovered by stale-building-check.sh --recover" >/dev/null 2>&1 || true
        fi
        gh issue comment "$N" --body "stale-building-check.sh --recover: reset \`loom:building\` -> \`loom:issue\` ($REASON). If a Builder is genuinely still working on this issue, please investigate before re-claiming." >/dev/null 2>&1 || true
        RECOVERED="true"
        RECOVERED_COUNT=$((RECOVERED_COUNT + 1))
    fi

    RESULTS_JSON="$(echo "$RESULTS_JSON" | jq \
        --arg issue "$N" --arg title "$TITLE" --arg action "$ACTION" --arg reason "$REASON" \
        --arg claim_status "$CLAIM_STATUS" --arg age_hours "$AGE_HOURS" --arg open_pr "$OPEN_PR" \
        --arg recovered "$RECOVERED" \
        '. + [{
            issue: ($issue | tonumber),
            title: $title,
            action: $action,
            reason: $reason,
            claim_status: $claim_status,
            age_hours: ($age_hours | tonumber),
            open_pr: (if $open_pr == "" then null else $open_pr end),
            recovered: ($recovered == "true")
        }]')"

    if [[ "$JSON_OUTPUT" != "1" ]]; then
        case "$ACTION" in
            stale)
                if [[ "$RECOVERED" == "true" ]]; then
                    log "  ${GREEN}RECOVERED${NC} #$N \"$TITLE\" -- $REASON"
                else
                    log "  ${RED}STALE${NC}     #$N \"$TITLE\" -- $REASON"
                fi
                ;;
            flag)
                log "  ${YELLOW}FLAGGED${NC}   #$N \"$TITLE\" -- $REASON"
                ;;
            skip)
                vlog "  skip       #$N \"$TITLE\" -- $REASON"
                ;;
        esac
    fi
done

if [[ "$JSON_OUTPUT" == "1" ]]; then
    echo "$RESULTS_JSON" | jq \
        --arg total "$COUNT" --arg stale "$STALE_COUNT" --arg flagged "$FLAGGED_WITH_PR_COUNT" \
        --arg live "$LIVE_COUNT" --arg recovered "$RECOVERED_COUNT" --arg recover_mode "$RECOVER" \
        '{
            total_building: ($total | tonumber),
            live: ($live | tonumber),
            stale: ($stale | tonumber),
            flagged_with_pr: ($flagged | tonumber),
            recovered: ($recovered | tonumber),
            recover_mode: ($recover_mode == "1"),
            issues: .
        }'
else
    log ""
    log "${BLUE}Summary:${NC} $LIVE_COUNT live, $STALE_COUNT stale, $FLAGGED_WITH_PR_COUNT flagged (open PR), $RECOVERED_COUNT recovered"
    if [[ "$STALE_COUNT" -gt 0 && "$RECOVER" != "1" ]]; then
        log "Run with --recover to reset the stale issue(s) above to loom:issue."
    fi
fi

exit 0

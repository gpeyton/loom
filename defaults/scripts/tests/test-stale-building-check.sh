#!/usr/bin/env bash
# test-stale-building-check.sh — Tests for stale-building-check.sh (issue
# #53), the real implementation of the stale-`loom:building` recovery helper
# that Loom's own docs (CLAUDE.md, .loom/docs/troubleshooting.md,
# defaults/.loom/AGENTS.md) have referenced by name and flag set without the
# script itself existing in the repo -- a packaging/doc-drift bug identified
# in the same #51/#53 reproduction that motivated sweep-claim.sh.
#
# Style matches test-spawn-codex-wave.sh / test-sweep-claim.sh — plain bash,
# hand-rolled assertions, a fake `gh` binary on PATH that returns canned JSON
# keyed by issue number. Bats is NOT used in this repository.
#
# Usage:
#   ./defaults/scripts/tests/test-stale-building-check.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STALE_CHECK="$SCRIPTS_DIR/stale-building-check.sh"
SWEEP_CLAIM="$SCRIPTS_DIR/sweep-claim.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Expected: '$expected'"
        echo "    Actual:   '$actual'"
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Expected substring: '$needle'"
        echo "    In: '$haystack'"
    fi
}

assert_not_contains() {
    local needle="$1" haystack="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Unexpected substring: '$needle'"
        echo "    In: '$haystack'"
    fi
}

strip_ansi() {
    # stale-building-check.sh colorizes the STALE/FLAGGED/RECOVERED labels
    # with a reset code immediately after the word (before the column
    # padding), so a naive substring match spanning "STALE     #9502" would
    # straddle an embedded \033[0m and never match the raw byte string.
    # Strip all ANSI SGR sequences before asserting against captured output.
    sed -E $'s/\x1b\\[[0-9;]*m//g'
}

if ! command -v jq &>/dev/null; then
    echo "jq not available -- skipping test-stale-building-check.sh entirely (script itself hard-requires jq)"
    exit 0
fi

echo "Testing stale-building-check.sh (issue #53 stale-claim recovery helper)..."

WS="$(mktemp -d)"
export LOOM_WORKSPACE="$WS"
trap 'rm -rf "$WS" "$STUB_DIR" "$GH_LOG"' EXIT

# ============================================================
# Fixture issues:
#   9501 -- loom:building, LIVE claim (real owner)          -> skip
#   9502 -- loom:building, ORPHANED claim (dead pid), no PR -> stale
#   9503 -- loom:building, no claim at all, no PR, "old"    -> stale (fallback heuristic)
#   9504 -- loom:building, orphaned claim, OPEN PR in flight -> flagged, never recovered
# ============================================================

sleep 60 &
LIVE_PID=$!
( exit 0 ) &
DEAD_SRC=$!
wait "$DEAD_SRC" 2>/dev/null
DEAD_PID=$DEAD_SRC

"$SWEEP_CLAIM" acquire 9501 --pid "$LIVE_PID" --runtime codex >/dev/null
"$SWEEP_CLAIM" acquire 9502 --pid "$DEAD_PID" --runtime codex >/dev/null
# 9503 gets no claim at all -- exercises the legacy time-based fallback.
"$SWEEP_CLAIM" acquire 9504 --pid "$DEAD_PID" --runtime codex >/dev/null

# ============================================================
# Fake `gh` on PATH. Recognizes exactly the subcommands
# stale-building-check.sh issues and returns canned data. Mutating calls
# (issue edit / issue comment) are logged to $GH_LOG for assertion.
# ============================================================
GH_LOG="$(mktemp)"
STUB_DIR="$(mktemp -d)"
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
GH_LOG="$GH_LOG"
case "\$1 \$2" in
    "issue list")
        cat <<'JSON'
[
  {"number": 9501, "title": "Live owner still working", "updatedAt": "2020-01-01T00:00:00Z", "closedByPullRequestsReferences": []},
  {"number": 9502, "title": "Orphaned, no PR", "updatedAt": "2020-01-01T00:00:00Z", "closedByPullRequestsReferences": []},
  {"number": 9503, "title": "No claim on record, old", "updatedAt": "2020-01-01T00:00:00Z", "closedByPullRequestsReferences": []},
  {"number": 9504, "title": "Orphaned but has open PR", "updatedAt": "2020-01-01T00:00:00Z", "closedByPullRequestsReferences": [{"url": "https://github.com/x/y/pull/777"}]}
]
JSON
        ;;
    "pr view")
        # Real \`gh pr view <url> --json state --jq '.state'\` applies gh's
        # own --jq filter server-side and prints the bare filtered value
        # (no surrounding braces/quotes) -- match that exactly, not the raw
        # JSON object, since the script under test does not run jq itself
        # on this call's output.
        echo "OPEN"
        ;;
    "issue edit")
        echo "\$*" >> "\$GH_LOG"
        ;;
    "issue comment")
        echo "\$*" >> "\$GH_LOG"
        ;;
    *)
        echo "unhandled gh invocation: \$*" >&2
        exit 1
        ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

RUN_PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin"

# ============================================================
# Section 1: dry-run (default) classification, no mutation
# ============================================================

echo ""
echo "Testing dry-run classification (no --recover)..."

output=$(PATH="$RUN_PATH" LOOM_WORKSPACE="$WS" SWEEP_CLAIM_BIN="$SWEEP_CLAIM" "$STALE_CHECK" --verbose 2>&1 | strip_ansi)

assert_contains "skip       #9501" "$output" "issue 9501 (live claim) is classified skip, not stale"
assert_contains "STALE     #9502" "$output" "issue 9502 (orphaned, no PR) is classified STALE"
assert_contains "claim orphaned" "$output" "issue 9502's reason names the orphaned claim, not a time heuristic"
assert_contains "STALE     #9503" "$output" "issue 9503 (no claim on record, old) is classified STALE via the time-based fallback"
assert_contains "no claim on record" "$output" "issue 9503's reason names the legacy no-claim fallback path"
assert_contains "FLAGGED   #9504" "$output" "issue 9504 (orphaned claim but open PR) is FLAGGED, not STALE"
assert_contains "needs human review, not auto-recovered" "$output" "issue 9504's reason explains why it is not auto-recovered"

assert_eq "0" "$([[ -s "$GH_LOG" ]] && echo 1 || echo 0)" "dry-run (no --recover) makes zero gh mutation calls"

# ============================================================
# Section 2: --recover actually resets the label and releases the claim,
# but ONLY for genuinely stale (not flagged, not live) issues.
# ============================================================

echo ""
echo "Testing --recover mutates only genuinely stale issues..."

: > "$GH_LOG"
output=$(PATH="$RUN_PATH" LOOM_WORKSPACE="$WS" SWEEP_CLAIM_BIN="$SWEEP_CLAIM" "$STALE_CHECK" --recover 2>&1)

assert_contains "RECOVERED" "$output" "recover mode reports at least one recovered issue"
gh_log_contents="$(cat "$GH_LOG")"
assert_contains "9502 --remove-label loom:building --add-label loom:issue" "$gh_log_contents" \
    "--recover resets issue 9502's label (orphaned, no PR -- the exact #51/#53 reproduction target)"
assert_contains "9503 --remove-label loom:building --add-label loom:issue" "$gh_log_contents" \
    "--recover resets issue 9503's label (legacy no-claim, past threshold)"
assert_not_contains "9501" "$gh_log_contents" "issue 9501 (live claim) never appears in the gh mutation log"
assert_not_contains "9504 --remove-label" "$gh_log_contents" \
    "issue 9504 (open PR in flight) is NEVER auto-recovered even in --recover mode"

# The orphaned claim's lease should now be resumable, not left dangling active.
recovered_claim_status="$("$SWEEP_CLAIM" status 9502)"
assert_contains '"status": "resumable"' "$recovered_claim_status" \
    "after --recover, issue 9502's claim is released to resumable (safely reclaimable by the next Builder retry)"

# The live claim (9501) must remain completely untouched.
live_claim_status="$("$SWEEP_CLAIM" status 9501)"
assert_contains '"status": "active"' "$live_claim_status" \
    "issue 9501's live claim is untouched by --recover"

# ============================================================
# Section 3: --json produces valid, well-formed JSON with correct counts
# ============================================================

echo ""
echo "Testing --json output..."

"$SWEEP_CLAIM" delete 9502 >/dev/null 2>&1 || true
"$SWEEP_CLAIM" acquire 9502 --pid "$DEAD_PID" --runtime codex >/dev/null 2>&1 || true

json_output=$(PATH="$RUN_PATH" LOOM_WORKSPACE="$WS" SWEEP_CLAIM_BIN="$SWEEP_CLAIM" "$STALE_CHECK" --json 2>/dev/null)
parse_ok=$(echo "$json_output" | jq -e '.' >/dev/null 2>&1 && echo 1 || echo 0)
assert_eq "1" "$parse_ok" "--json output is valid, parseable JSON"

total_building=$(echo "$json_output" | jq -r '.total_building')
assert_eq "4" "$total_building" "--json reports total_building=4 for the 4 fixture issues"

live_count=$(echo "$json_output" | jq -r '.live')
assert_eq "1" "$live_count" "--json reports live=1 (issue 9501)"

stale_count=$(echo "$json_output" | jq -r '.stale')
assert_eq "2" "$stale_count" "--json reports stale=2 (issues 9502 and 9503)"

flagged_count=$(echo "$json_output" | jq -r '.flagged_with_pr')
assert_eq "1" "$flagged_count" "--json reports flagged_with_pr=1 (issue 9504)"

recover_mode=$(echo "$json_output" | jq -r '.recover_mode')
assert_eq "false" "$recover_mode" "--json without --recover reports recover_mode=false"

# ============================================================
# Summary
# ============================================================

echo ""
echo "==================================="
echo "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    exit 1
fi
echo "All tests passed."

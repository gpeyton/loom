#!/usr/bin/env bash
# test-sweep-claim.sh — Tests for sweep-claim.sh, the atomic Builder-claim
# lease primitive introduced by issue #53 (follow-up to #52's cancellation
# taxonomy and #51's two real-incident reproductions).
#
# Style matches test-spawn-codex-wave.sh / test-spawn-codex.sh — plain bash,
# hand-rolled assertions. Bats is NOT used in this repository.
#
# Usage:
#   ./defaults/scripts/tests/test-sweep-claim.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
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

echo "Testing sweep-claim.sh (issue #53 atomic Builder-claim lease)..."

# ============================================================
# Isolation: every invocation below uses its own temp LOOM_WORKSPACE so this
# suite never touches the real repo's .loom/sweep-claims or .loom/locks.
# ============================================================
WS="$(mktemp -d)"
export LOOM_WORKSPACE="$WS"
trap 'rm -rf "$WS"' EXIT

# A real, long-lived background process to use as a "definitely alive" pid
# anchor across tests (sleeping long enough to outlive the whole suite).
sleep 120 &
ALIVE_PID=$!
# A pid guaranteed to be dead: fork a short-lived child and wait for it.
( exit 0 ) &
DEAD_PID_SRC=$!
wait "$DEAD_PID_SRC" 2>/dev/null
DEAD_PID="$DEAD_PID_SRC"

# ============================================================
# Section 1: basic acquire / status / is-live / release lifecycle
# ============================================================

echo ""
echo "Testing basic acquire/status/is-live/release lifecycle..."

set +e
run_id=$("$SWEEP_CLAIM" acquire 1001 --pid "$ALIVE_PID" --runtime manual)
code=$?
assert_eq "0" "$code" "acquire on a fresh issue succeeds"
assert_contains "manual-" "$run_id" "acquire prints a run_id containing the runtime tag"

set +e
"$SWEEP_CLAIM" is-live 1001
live_code=$?
assert_eq "0" "$live_code" "is-live reports true for a freshly-acquired claim with a live pid"

status_json="$("$SWEEP_CLAIM" status 1001)"
assert_contains '"status": "active"' "$status_json" "status shows active immediately after acquire"
assert_contains "\"pid\": $ALIVE_PID" "$status_json" "status records the correct pid"

"$SWEEP_CLAIM" release 1001 --run-id "$run_id" --status resumable --reason "test release" >/dev/null
status_json="$("$SWEEP_CLAIM" status 1001)"
assert_contains '"status": "resumable"' "$status_json" "release flips status to resumable"
assert_contains '"reason": "test release"' "$status_json" "release records the supplied reason"

set +e
"$SWEEP_CLAIM" is-live 1001
live_code=$?
assert_eq "1" "$live_code" "is-live reports false after release (resumable is not live)"

# ============================================================
# Section 2: acquire refuses a LIVE claim, succeeds on an ORPHANED one
# ============================================================

echo ""
echo "Testing acquire refuses live claims but reclaims orphaned ones..."

run_id2=$("$SWEEP_CLAIM" acquire 1002 --pid "$ALIVE_PID" --runtime codex)
set +e
"$SWEEP_CLAIM" acquire 1002 --pid "$ALIVE_PID" --runtime codex >/tmp/sweep-claim-test-refuse.$$ 2>&1
refuse_code=$?
assert_eq "4" "$refuse_code" "acquire on an issue with a live claim exits 4 (refused, do not disturb)"
rm -f "/tmp/sweep-claim-test-refuse.$$"

# Now simulate the #51/#53 scenario: the owner died without releasing
# (status still "active" but pid no longer exists).
"$SWEEP_CLAIM" delete 1003 >/dev/null 2>&1 || true
run_id3=$("$SWEEP_CLAIM" acquire 1003 --pid "$DEAD_PID" --runtime codex)
set +e
"$SWEEP_CLAIM" is-live 1003
live_code=$?
assert_eq "1" "$live_code" "is-live reports false for a claim whose pid is dead (active status, dead pid == orphaned)"

set +e
reclaim_run_id=$("$SWEEP_CLAIM" acquire 1003 --pid "$ALIVE_PID" --runtime codex)
reclaim_code=$?
assert_eq "0" "$reclaim_code" "acquire on an orphaned (dead-pid) claim succeeds -- this is the #53 fix"
assert_eq "1" "$([[ "$reclaim_run_id" != "$run_id3" ]] && echo 1 || echo 0)" \
    "the reclaimed run_id differs from the orphaned claim's original run_id"

# ============================================================
# Section 3: update / heartbeat require ownership (run_id match)
# ============================================================

echo ""
echo "Testing update/heartbeat ownership checks..."

run_id4=$("$SWEEP_CLAIM" acquire 1004 --pid "$ALIVE_PID" --runtime manual)
set +e
"$SWEEP_CLAIM" update 1004 --run-id "not-the-real-run-id" --pid 99999 >/dev/null 2>&1
wrong_owner_code=$?
assert_eq "1" "$wrong_owner_code" "update with the wrong run_id is refused"

set +e
"$SWEEP_CLAIM" update 1004 --run-id "$run_id4" --pid "$ALIVE_PID" >/dev/null 2>&1
right_owner_code=$?
assert_eq "0" "$right_owner_code" "update with the correct run_id succeeds"

# ============================================================
# Section 4: release is idempotent and a no-op when ownership was lost
# ============================================================

echo ""
echo "Testing release idempotency and ownership checks..."

set +e
"$SWEEP_CLAIM" release 9999 --run-id "no-such-claim" --status resumable
noop_code=$?
assert_eq "0" "$noop_code" "release on an issue with no claim at all is a no-op success"

run_id5=$("$SWEEP_CLAIM" acquire 1005 --pid "$ALIVE_PID" --runtime manual)
set +e
"$SWEEP_CLAIM" release 1005 --run-id "some-other-run-id" --status resumable
wrong_release_code=$?
assert_eq "0" "$wrong_release_code" "release with a mismatched run_id does not error (but also does not release)"
status_json="$("$SWEEP_CLAIM" status 1005)"
assert_contains '"status": "active"' "$status_json" "a release with the wrong run_id leaves the claim active (ownership was not proven)"

# ============================================================
# Section 5: delete is unconditional (operator escape hatch)
# ============================================================

echo ""
echo "Testing delete (unconditional operator escape hatch)..."

"$SWEEP_CLAIM" acquire 1006 --pid "$ALIVE_PID" --runtime manual >/dev/null
"$SWEEP_CLAIM" delete 1006 >/dev/null
set +e
"$SWEEP_CLAIM" status 1006 >/dev/null 2>&1
status_after_delete_code=$?
assert_eq "1" "$status_after_delete_code" "status after delete reports no claim (exit 1)"

# ============================================================
# Section 6: CONCURRENCY -- two racing acquire attempts on the SAME fresh
# issue must result in exactly ONE winner. This is the load-bearing
# atomicity guarantee issue #53 requires ("two concurrent retries must not
# both become Builder").
# ============================================================

echo ""
echo "Testing concurrent acquire attempts are atomic (issue #53 core guarantee)..."

sleep 60 & RACER_A_PID=$!
sleep 60 & RACER_B_PID=$!

OUT_A="$(mktemp)"
OUT_B="$(mktemp)"

(
    "$SWEEP_CLAIM" acquire 2001 --pid "$RACER_A_PID" --runtime manual --run-id "racer-A" >"$OUT_A" 2>&1
    echo "EXIT=$?" >> "$OUT_A"
) &
JOB_A=$!
(
    "$SWEEP_CLAIM" acquire 2001 --pid "$RACER_B_PID" --runtime manual --run-id "racer-B" >"$OUT_B" 2>&1
    echo "EXIT=$?" >> "$OUT_B"
) &
JOB_B=$!
wait "$JOB_A" "$JOB_B"

exit_a="$(sed -n 's/^EXIT=//p' "$OUT_A")"
exit_b="$(sed -n 's/^EXIT=//p' "$OUT_B")"

# Exactly one of the two must succeed (exit 0) and the other must be refused
# (exit 4) -- never both succeeding, never both failing.
both_zero=0
both_four=0
[[ "$exit_a" == "0" && "$exit_b" == "0" ]] && both_zero=1
[[ "$exit_a" == "4" && "$exit_b" == "4" ]] && both_four=1
assert_eq "0" "$both_zero" "concurrent racers do NOT both succeed (exactly one must win)"
assert_eq "0" "$both_four" "concurrent racers do NOT both get refused (exactly one must win)"

winner_count=0
[[ "$exit_a" == "0" ]] && winner_count=$((winner_count + 1))
[[ "$exit_b" == "0" ]] && winner_count=$((winner_count + 1))
assert_eq "1" "$winner_count" "exactly one of the two concurrent racers acquired the claim"

final_status="$("$SWEEP_CLAIM" status 2001)"
assert_contains '"status": "active"' "$final_status" "the winning racer's claim is active after the race settles"

kill "$RACER_A_PID" "$RACER_B_PID" 2>/dev/null || true
rm -f "$OUT_A" "$OUT_B"

# ============================================================
# Section 7: CONCURRENCY -- a higher-volume race (5 racers) still yields
# exactly one winner, guarding against a lock that only happens to work
# for exactly two contenders.
# ============================================================

echo ""
echo "Testing a 5-way concurrent acquire race still yields exactly one winner..."

RACER_PIDS=()
for i in 1 2 3 4 5; do
    sleep 60 &
    RACER_PIDS+=("$!")
done

RACE_OUT_DIR="$(mktemp -d)"
JOBS=()
for i in 1 2 3 4 5; do
    (
        "$SWEEP_CLAIM" acquire 2002 --pid "${RACER_PIDS[$((i-1))]}" --runtime manual --run-id "racer-$i" \
            >"$RACE_OUT_DIR/out-$i" 2>&1
        echo "EXIT=$?" >> "$RACE_OUT_DIR/out-$i"
    ) &
    JOBS+=("$!")
done
for j in "${JOBS[@]}"; do
    wait "$j"
done

winners=0
for i in 1 2 3 4 5; do
    exit_i="$(sed -n 's/^EXIT=//p' "$RACE_OUT_DIR/out-$i")"
    [[ "$exit_i" == "0" ]] && winners=$((winners + 1))
done
assert_eq "1" "$winners" "exactly one of 5 concurrent racers wins the acquire race"

for pid in "${RACER_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
rm -rf "$RACE_OUT_DIR"

# ============================================================
# Section 8: usage errors
# ============================================================

echo ""
echo "Testing usage/validation errors..."

set +e
"$SWEEP_CLAIM" acquire not-a-number --pid "$ALIVE_PID" >/dev/null 2>&1
bad_issue_code=$?
assert_eq "2" "$bad_issue_code" "acquire with a non-numeric issue exits 2 (usage error)"

set +e
"$SWEEP_CLAIM" release 1234 --status not-a-real-status --run-id x >/dev/null 2>&1
bad_status_code=$?
assert_eq "2" "$bad_status_code" "release with an invalid --status value exits 2 (usage error)"

set +e
"$SWEEP_CLAIM" is-live 1005
final_1005_live=$?
assert_eq "0" "$final_1005_live" "sanity check: issue 1005's original (un-tampered) claim is still live at suite end"

wait 2>/dev/null || true

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

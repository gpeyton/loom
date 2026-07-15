#!/usr/bin/env bash
# test-spawn-codex-wave.sh — Tests for spawn-codex-wave.sh, the process-level
# multi-wave Codex fan-out script (issue #24, follow-up to #19's single-role
# sequential Codex sweep and #20's guardrail parity).
#
# Style matches test-spawn-codex.sh / test-spawn-worker.sh / test-spawn-claude.sh
# — plain bash, hand-rolled assertions, a fake `codex` binary on PATH that
# records its argv. Bats is NOT used in this repository.
#
# Usage:
#   ./defaults/scripts/tests/test-spawn-codex-wave.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
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
    local needle="$1"
    local haystack="$2"
    local msg="$3"
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
    local needle="$1"
    local haystack="$2"
    local msg="$3"
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

assert_lt() {
    # Numeric less-than, for timing assertions.
    local actual="$1"
    local bound="$2"
    local msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if awk -v a="$actual" -v b="$bound" 'BEGIN { exit !(a < b) }'; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg (actual=$actual < bound=$bound)"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Expected actual < bound, got actual=$actual bound=$bound"
    fi
}

assert_gt() {
    local actual="$1"
    local bound="$2"
    local msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if awk -v a="$actual" -v b="$bound" 'BEGIN { exit !(a > b) }'; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg (actual=$actual > bound=$bound)"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Expected actual > bound, got actual=$actual bound=$bound"
    fi
}

echo "Testing spawn-codex-wave.sh dispatch..."

# ============================================================
# Setup: fake `codex` binary that records its argv and sleeps briefly
# (sleep duration lets timing assertions distinguish concurrent vs.
# sequential execution without a flaky short sleep).
# ============================================================

STUB_DIR="$(mktemp -d)"
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR" "$LOG_DIR"' EXIT

cat > "$STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
echo "stub-codex args=$*"
sleep 0.4
exit 0
STUB
chmod +x "$STUB_DIR/codex"

# A fake `codex` that fails for one specific issue (matched via the prompt
# text spawn-codex-wave.sh generates, which embeds "issue <N>").
FAIL_STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR" "$LOG_DIR" "$FAIL_STUB_DIR"' EXIT
cat > "$FAIL_STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"issue 102"* ]]; then
    echo "stub-codex FAILING for issue 102"
    exit 1
fi
echo "stub-codex args=$*"
exit 0
STUB
chmod +x "$FAIL_STUB_DIR/codex"

NOCODEX_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ============================================================
# Section 1: argument validation
# ============================================================

echo ""
echo "Testing argument validation..."

set +e
output=$("$SCRIPTS_DIR/spawn-codex-wave.sh" 2>&1)
exit_code=$?
set -e
assert_eq "78" "$exit_code" "no issue numbers supplied exits 78 (EX_CONFIG)"
assert_contains "usage:" "$output" "missing-args error mentions usage"

set +e
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$LOG_DIR" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" not-a-number 2>&1)
exit_code=$?
set -e
assert_eq "78" "$exit_code" "non-numeric issue argument exits 78 (EX_CONFIG)"
assert_contains "invalid issue number" "$output" "non-numeric argument error names the problem"

# Leading '#' is accepted (matches the sweep skill's numeric-token convention)
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$LOG_DIR" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" '#301' 2>&1 || true)
assert_contains "single-issue wave (#301)" "$output" \
    "leading '#' is stripped and accepted as a valid issue number"

# --help
set +e
output=$("$SCRIPTS_DIR/spawn-codex-wave.sh" --help 2>&1)
exit_code=$?
set -e
assert_eq "0" "$exit_code" "--help exits 0"
assert_contains "spawn-codex-wave.sh" "$output" "--help output mentions spawn-codex-wave.sh"
assert_contains "LOOM_CODEX_MULTI_WAVE" "$output" "--help documents LOOM_CODEX_MULTI_WAVE"

# ============================================================
# Section 2: single-issue wave always runs (regardless of gate)
# ============================================================

echo ""
echo "Testing single-issue wave..."

output=$(PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$LOG_DIR" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 501 2>&1)
assert_contains "single-issue wave (#501) -- running sequentially" "$output" \
    "single-issue wave logs as sequential regardless of the gate"
assert_contains "wave settled -- 1 issue(s), 0 failed" "$output" \
    "single-issue wave settles cleanly"

# ============================================================
# Section 3: opt-in gate — sequential degrade without LOOM_CODEX_MULTI_WAVE
# ============================================================

echo ""
echo "Testing opt-in gate (sequential degrade, issue #19 regression guard)..."

START=$(date +%s.%N 2>/dev/null || date +%s)
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$LOG_DIR" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 601 602 603 2>&1)
END=$(date +%s.%N 2>/dev/null || date +%s)
SEQ_ELAPSED=$(awk -v s="$START" -v e="$END" 'BEGIN { print e - s }')

assert_contains "LOOM_CODEX_MULTI_WAVE not set -- degrading to sequential processing for 3 issues" "$output" \
    "unset gate logs the sequential-degrade decision"
assert_contains "wave settled -- 3 issue(s), 0 failed" "$output" \
    "sequential wave settles all 3 issues cleanly"
# 3 children x 0.4s sleep run one at a time -> expect >= ~1.0s wall time.
assert_gt "$SEQ_ELAPSED" "1.0" \
    "sequential mode (no gate) takes >= 1.0s for 3x0.4s children (proves NOT concurrent)"

# ============================================================
# Section 4: opt-in gate — concurrent fan-out with LOOM_CODEX_MULTI_WAVE=1
# ============================================================

echo ""
echo "Testing opt-in gate (concurrent fan-out)..."

START=$(date +%s.%N 2>/dev/null || date +%s)
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$LOG_DIR" \
    LOOM_CODEX_MULTI_WAVE=1 \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 701 702 703 2>&1)
END=$(date +%s.%N 2>/dev/null || date +%s)
CONC_ELAPSED=$(awk -v s="$START" -v e="$END" 'BEGIN { print e - s }')

assert_contains "LOOM_CODEX_MULTI_WAVE=1 -- fanning out 3 children concurrently" "$output" \
    "gate=1 logs the concurrent fan-out decision"
assert_contains "wave settled -- 3 issue(s), 0 failed" "$output" \
    "concurrent wave settles all 3 issues cleanly"
# 3 children x 0.4s sleep run in parallel -> expect well under the sequential
# 1.2s total; a generous 0.9s bound comfortably separates the two modes
# without flaking on a loaded CI box.
assert_lt "$CONC_ELAPSED" "0.9" \
    "concurrent mode (gate=1) takes < 0.9s for 3x0.4s children (proves fan-out, not sequential)"
assert_gt "$SEQ_ELAPSED" "$CONC_ELAPSED" \
    "sequential elapsed time exceeds concurrent elapsed time for the same 3-issue wave"

# ============================================================
# Section 5: settling boundary — every child is waited on before return
# (both branches print one "exited" line per issue, and the top-level exit
# code isn't returned until the wave-settled summary line has printed)
# ============================================================

echo ""
echo "Testing settling boundary (wave blocks until every child exits)..."

output=$(PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$LOG_DIR" \
    LOOM_CODEX_MULTI_WAVE=1 \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 801 802 2>&1)
assert_contains "issue #801 child" "$output" "settling boundary reports issue #801's outcome"
assert_contains "issue #802 child" "$output" "settling boundary reports issue #802's outcome"
# The summary line is the LAST thing printed, after both children are waited on.
last_line="$(echo "$output" | grep 'wave settled' | tail -1)"
assert_contains "2 issue(s), 0 failed" "$last_line" \
    "wave-settled summary reports both issues as accounted for"

# ============================================================
# Section 6: failure propagation — one failing child fails the wave
# ============================================================

echo ""
echo "Testing failure propagation..."

set +e
output=$(PATH="$FAIL_STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$LOG_DIR" \
    LOOM_CODEX_MULTI_WAVE=1 \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 101 102 103 2>&1)
exit_code=$?
set -e
assert_eq "1" "$exit_code" "one failing child in a concurrent wave exits 1"
assert_contains "issue #102 child" "$output" "the failing issue's exit is logged"
assert_contains "failed issues: 102" "$output" "the failure summary names the failing issue"
assert_contains "wave settled -- 3 issue(s), 1 failed" "$output" \
    "the wave-settled summary counts exactly 1 failure out of 3"

# Sequential mode also propagates a single failure
set +e
output=$(PATH="$FAIL_STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$LOG_DIR" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 101 102 103 2>&1)
exit_code=$?
set -e
assert_eq "1" "$exit_code" "one failing child in a sequential wave also exits 1"
assert_contains "wave settled -- 3 issue(s), 1 failed" "$output" \
    "sequential wave-settled summary also counts exactly 1 failure out of 3"

# ============================================================
# Section 7: LOOM_CODEX_UNSAFE forwarding (does not affect concurrency gate)
# ============================================================

echo ""
echo "Testing LOOM_CODEX_UNSAFE forwarding (orthogonal to LOOM_CODEX_MULTI_WAVE)..."

output=$(PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$LOG_DIR" \
    LOOM_CODEX_UNSAFE=1 \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 901 2>&1)
log_contents="$(cat "$LOG_DIR/spawn-codex-wave-issue-901.log" 2>/dev/null || echo "")"
assert_contains "dangerously-bypass-approvals-and-sandbox" "$log_contents" \
    "LOOM_CODEX_UNSAFE=1 is forwarded through to the spawn-codex.sh child unchanged"

# Without any permission env vars, the child gets spawn-codex.sh's own
# default posture unchanged by the wave script (issue #31, epic #30 Phase 1:
# spawn-codex.sh's default is now full access, and spawn-codex-wave.sh does
# not touch permission posture at all -- see the header note above).
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$LOG_DIR" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 902 2>&1)
log_contents="$(cat "$LOG_DIR/spawn-codex-wave-issue-902.log" 2>/dev/null || echo "")"
assert_contains "dangerously-bypass-approvals-and-sandbox" "$log_contents" \
    "no permission env vars -> spawn-codex.sh's full-access default is still applied to each wave child"

# ============================================================
# Section 8: per-issue log files
# ============================================================

echo ""
echo "Testing per-issue log files..."

FRESH_LOG_DIR="$(mktemp -d)"
PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$FRESH_LOG_DIR" \
    LOOM_CODEX_MULTI_WAVE=1 \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 1001 1002 >/dev/null 2>&1 || true
assert_eq "1" "$([[ -f "$FRESH_LOG_DIR/spawn-codex-wave-issue-1001.log" ]] && echo 1 || echo 0)" \
    "per-issue log file created for issue 1001"
assert_eq "1" "$([[ -f "$FRESH_LOG_DIR/spawn-codex-wave-issue-1002.log" ]] && echo 1 || echo 0)" \
    "per-issue log file created for issue 1002"
rm -rf "$FRESH_LOG_DIR"

# ============================================================
# Section 9: missing spawn-codex.sh handling
# ============================================================

echo ""
echo "Testing missing spawn-codex.sh handling..."

set +e
output=$(LOOM_SPAWN_CODEX_BIN="/nonexistent/spawn-codex.sh" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 1 2>&1)
exit_code=$?
set -e
assert_eq "78" "$exit_code" "missing spawn-codex.sh binary exits 78 (EX_CONFIG)"
assert_contains "not found or not executable" "$output" \
    "missing spawn-codex.sh error is descriptive"

# ============================================================
# Section 10: single-child (N=1) behavior is unaffected/unchanged
# (regression guard: spawn-codex-wave.sh with one issue behaves like a bare
# spawn-codex.sh -p ... --dangerously-skip-permissions call)
# ============================================================

echo ""
echo "Testing single-child regression guard (matches spawn-codex.sh directly)..."

FRESH_LOG_DIR="$(mktemp -d)"
PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$FRESH_LOG_DIR" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 42 >/dev/null 2>&1
child_log="$(cat "$FRESH_LOG_DIR/spawn-codex-wave-issue-42.log" 2>/dev/null || echo "")"
assert_contains "args=exec --dangerously-bypass-approvals-and-sandbox" "$child_log" \
    "single-issue wave child invokes 'codex exec --dangerously-bypass-approvals-and-sandbox ...' exactly like a direct spawn-codex.sh call (issue #31 default)"
assert_contains "loom-sweep.md" "$child_log" \
    "single-issue wave child's prompt references the .codex/prompts/loom-sweep.md shim"
assert_contains "issue 42" "$child_log" \
    "single-issue wave child's prompt names the correct issue number"
rm -rf "$FRESH_LOG_DIR"

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

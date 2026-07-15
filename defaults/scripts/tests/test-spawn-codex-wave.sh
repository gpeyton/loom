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
trap 'rm -rf "$STUB_DIR" "$LOG_DIR" "$CLAIM_WORKSPACE"' EXIT

# Issue #53: spawn-codex-wave.sh now gates each child on sweep-claim.sh, whose
# claim/lock files live under `<repo-root>/.loom/{sweep-claims,locks}/` --
# repo-root being resolved via `git rev-parse --git-common-dir` when
# LOOM_WORKSPACE is unset (the same convention worktree.sh/spawn-claude.sh
# use). Running this suite from inside the real repo/worktree WITHOUT an
# isolated LOOM_WORKSPACE would therefore leak real claim files into the
# developer's actual `.loom/` directory. Export an isolated LOOM_WORKSPACE
# for the whole suite so every invocation below is fully self-contained.
CLAIM_WORKSPACE="$(mktemp -d)"
export LOOM_WORKSPACE="$CLAIM_WORKSPACE"

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
assert_contains ".agents/skills/loom-sweep/SKILL.md" "$child_log" \
    "single-issue wave child's prompt references the canonical loom-sweep skill (issue #53 -- repointed off the retired .codex/prompts/loom-sweep.md shim)"
assert_not_contains ".codex/prompts/loom-sweep.md" "$child_log" \
    "single-issue wave child's prompt no longer references the retired .codex/prompts/loom-sweep.md shim (issue #53)"
assert_contains "issue 42" "$child_log" \
    "single-issue wave child's prompt names the correct issue number"
rm -rf "$FRESH_LOG_DIR"

# ============================================================
# Section 11: patience contract (issue #52) -- a silent-but-alive child is
# NEVER terminated. This is the exact production defect from #51's
# reproduction A: a child that produces zero log output for several would-be
# monitoring intervals must still be allowed to run to completion.
# ============================================================

echo ""
echo "Testing patience contract -- silent child is never terminated (issue #52)..."

SILENT_STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR" "$LOG_DIR" "$FAIL_STUB_DIR" "$SILENT_STUB_DIR"' EXIT
cat > "$SILENT_STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
# Deliberately silent for several seconds -- long enough to span several
# hypothetical monitoring intervals (the incident's stall was declared after
# ~94s of silence; this stub uses a much shorter but still multi-interval
# window so the test suite stays fast). No stdout/stderr, no file writes,
# just wall-clock silence, then a clean exit.
sleep 2.5
echo "finally produced output after being silent"
exit 0
STUB
chmod +x "$SILENT_STUB_DIR/codex"

SILENT_LOG_DIR="$(mktemp -d)"
SILENT_START=$(date +%s.%N 2>/dev/null || date +%s)
output=$(PATH="$SILENT_STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$SILENT_LOG_DIR" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 9001 2>&1)
exit_code=$?
SILENT_END=$(date +%s.%N 2>/dev/null || date +%s)
SILENT_ELAPSED=$(awk -v s="$SILENT_START" -v e="$SILENT_END" 'BEGIN { print e - s }')

assert_eq "0" "$exit_code" "a child silent for 2.5s with zero log output completes with exit 0 (not killed)"
assert_gt "$SILENT_ELAPSED" "2.0" \
    "the wave waited out the full silent duration rather than cutting it short (actual=${SILENT_ELAPSED}s)"
assert_contains "issue #9001 child" "$output" "the silent child's completion is logged"
assert_not_contains "cancelled_by_" "$output" "no cancellation outcome appears for an uninterrupted silent child"
assert_contains "outcome breakdown -- completed=1 failed=0 cancelled=0" "$output" \
    "the outcome breakdown counts the silent child as completed, not cancelled or failed"

if command -v jq &>/dev/null; then
    silent_outcome=$(jq -r '.children[0].outcome' "$SILENT_LOG_DIR/spawn-codex-wave-status.json" 2>/dev/null)
    assert_eq "completed" "$silent_outcome" "the structured status file records outcome=completed for the silent child"
fi
rm -rf "$SILENT_LOG_DIR"

# ============================================================
# Section 12: structured status file schema (issue #52) -- machine-readable
# per-child state, read non-destructively via --status.
# ============================================================

echo ""
echo "Testing structured status file and --status (issue #52)..."

if command -v jq &>/dev/null; then
    STATUS_LOG_DIR="$(mktemp -d)"
    PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$STATUS_LOG_DIR" \
        "$SCRIPTS_DIR/spawn-codex-wave.sh" 9101 >/dev/null 2>&1

    assert_eq "1" "$([[ -f "$STATUS_LOG_DIR/spawn-codex-wave-status.json" ]] && echo 1 || echo 0)" \
        "spawn-codex-wave-status.json is written after a wave completes"

    for field in issue pid outcome started_at finished_at exit_code signal cancellation_initiator log_file; do
        has_field=$(jq -r --arg f "$field" '.children[0] | has($f)' "$STATUS_LOG_DIR/spawn-codex-wave-status.json" 2>/dev/null)
        assert_eq "true" "$has_field" "status file child record has field '$field'"
    done

    status_output=$(LOOM_CODEX_WAVE_LOG_DIR="$STATUS_LOG_DIR" "$SCRIPTS_DIR/spawn-codex-wave.sh" --status 2>&1)
    assert_contains '"issue": 9101' "$status_output" "--status prints the structured JSON for the completed wave"

    rm -rf "$STATUS_LOG_DIR"

    EMPTY_LOG_DIR="$(mktemp -d)"
    set +e
    empty_status_output=$(LOOM_CODEX_WAVE_LOG_DIR="$EMPTY_LOG_DIR" "$SCRIPTS_DIR/spawn-codex-wave.sh" --status 2>&1)
    empty_status_code=$?
    set -e
    assert_eq "1" "$empty_status_code" "--status with no prior wave exits 1"
    assert_contains "no status file found" "$empty_status_output" "--status reports absence clearly instead of erroring obscurely"
    rm -rf "$EMPTY_LOG_DIR"
else
    echo "  (jq not available -- skipping structured status file assertions)"
fi

# ============================================================
# Section 13: explicit cancellation reports a cancellation outcome, not
# generic "failed" (issue #52). SIGINT and SIGTERM sent directly to the wave
# runner's own process must each retain provenance (initiator + signal).
#
# NOTE ON DELIVERY MECHANISM: this section signals the wave runner via a
# small python3 driver (subprocess.Popen + send_signal), not bash job
# control (`cmd & ... kill -INT $!`). POSIX/bash treat an asynchronously
# started (`cmd &`) command in a shell without job control as PERMANENTLY
# immune to SIGINT/SIGQUIT -- once bash pre-sets that disposition to ignored
# for such a child, the child's own `trap ... INT` is silently a no-op
# ("signals ignored upon entry to a non-interactive [sub]shell cannot be
# trapped or reset", which is exactly bash's documented behavior). This is a
# property of *how bash itself launches async jobs without a controlling
# terminal* -- test runners and CI containers commonly have no tty at all,
# so this bites bash-job-control-based test techniques unpredictably. A
# real external `kill -INT <pid>` sent by an operator or a supervising
# process via a normal fork/exec (not bash's own `&` bookkeeping) is NOT
# subject to this restriction -- which is exactly what subprocess.Popen
# gives us here, and exactly what happens in production (an operator's
# terminal, a supervising Python/Node/Rust process, `mcp__loom__cancel_sweep`,
# etc. all deliver signals via a normal kill(2) syscall, not bash job
# control). SIGTERM is unaffected by the async-ignore rule either way.
# ============================================================

echo ""
echo "Testing explicit cancellation -- SIGINT/SIGTERM report cancellation, not failure (issue #52)..."

if command -v python3 &>/dev/null; then
    SIG_STUB_DIR="$(mktemp -d)"
    cat > "$SIG_STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
trap 'exit 130' INT
trap 'exit 143' TERM
sleep 30
exit 0
STUB
    chmod +x "$SIG_STUB_DIR/codex"

    _signal_wave_and_capture() {
        # args: <issue> <signal-name: INT|TERM> <log-dir>
        # NOTE: PATH/LOOM_CODEX_WAVE_LOG_DIR are set INSIDE the python3 child's
        # env dict, not on the `python3` invocation itself -- overriding PATH
        # on the outer command would change which python3 interpreter gets
        # resolved (this repo/host has more than one on PATH), which is
        # irrelevant to what we're testing and has bitten this test before.
        #
        # NOTE: the child's combined stdout+stderr is captured to a REAL FILE,
        # not `subprocess.PIPE` + `communicate()`. spawn-codex-wave.sh's own
        # child (`_run_child`) is itself backgrounded (`&`) with its output
        # redirected to a log file, and that redirection is applied via
        # dup2() at fork time inside bash -- there is a narrow window where
        # forked-but-not-yet-exec'd descendants transiently hold a copy of
        # whatever fd 1 pointed at when bash forked them. With
        # `stdout=subprocess.PIPE`, that transient inherited copy of the pipe
        # write-end is enough to make `communicate()` block forever waiting
        # for EOF even after the tracked process has fully exited (a classic,
        # well-documented Python subprocess pitfall with pipes + a process
        # tree that forks). Writing directly to a file sidesteps the pipe
        # entirely and was verified to resolve the hang.
        local issue="$1" sig="$2" logdir="$3" outfile="$4"
        SIG_STUB_DIR="$SIG_STUB_DIR" \
        SPAWN_CODEX_WAVE_SH="$SCRIPTS_DIR/spawn-codex-wave.sh" \
        WAVE_ISSUE="$issue" WAVE_SIGNAL="$sig" WAVE_LOG_DIR="$logdir" WAVE_OUTFILE="$outfile" \
        python3 - <<'PYEOF'
import os, signal, subprocess, sys, time

script = os.environ["SPAWN_CODEX_WAVE_SH"]
issue = os.environ["WAVE_ISSUE"]
sig_name = os.environ["WAVE_SIGNAL"]
outfile = os.environ["WAVE_OUTFILE"]
sig = signal.SIGINT if sig_name == "INT" else signal.SIGTERM

env = dict(os.environ)
env["PATH"] = os.environ["SIG_STUB_DIR"] + ":" + env.get("PATH", "")
env["LOOM_CODEX_WAVE_LOG_DIR"] = os.environ["WAVE_LOG_DIR"]

with open(outfile, "wb") as f:
    proc = subprocess.Popen([script, issue], stdout=f, stderr=subprocess.STDOUT, env=env)
    time.sleep(1)
    proc.send_signal(sig)
    proc.wait(timeout=15)

sys.stdout.write(f"EXIT_CODE={proc.returncode}\n")
PYEOF
    }

    SIGINT_LOG_DIR="$(mktemp -d)"
    SIGINT_OUTFILE="$(mktemp)"
    sigint_result="$(_signal_wave_and_capture 9201 INT "$SIGINT_LOG_DIR" "$SIGINT_OUTFILE")"
    sigint_code="$(printf '%s\n' "$sigint_result" | sed -n 's/^EXIT_CODE=//p')"
    sigint_output="$(cat "$SIGINT_OUTFILE" 2>/dev/null)"

    SIGTERM_LOG_DIR="$(mktemp -d)"
    SIGTERM_OUTFILE="$(mktemp)"
    sigterm_result="$(_signal_wave_and_capture 9202 TERM "$SIGTERM_LOG_DIR" "$SIGTERM_OUTFILE")"
    sigterm_code="$(printf '%s\n' "$sigterm_result" | sed -n 's/^EXIT_CODE=//p')"
    sigterm_output="$(cat "$SIGTERM_OUTFILE" 2>/dev/null)"

    assert_eq "130" "$sigint_code" "SIGINT to the wave runner exits 130 (128 + SIGINT)"
    assert_eq "143" "$sigterm_code" "SIGTERM to the wave runner exits 143 (128 + SIGTERM)"
    assert_contains "cancelled_by_operator" "$sigint_output" "SIGINT is reported as cancelled_by_operator"
    assert_contains "cancelled_by_parent" "$sigterm_output" "SIGTERM is reported as cancelled_by_parent"
    assert_contains "not a failure" "$sigint_output" "SIGINT cancellation is explicitly distinguished from a failure in the log output"
    assert_contains "not a failure" "$sigterm_output" "SIGTERM cancellation is explicitly distinguished from a failure in the log output"
    assert_not_contains "spawn-codex-wave: failed issues" "$sigint_output" "SIGINT cancellation never appears in the generic failed-issues line"
    assert_not_contains "spawn-codex-wave: failed issues" "$sigterm_output" "SIGTERM cancellation never appears in the generic failed-issues line"
    rm -f "$SIGINT_OUTFILE" "$SIGTERM_OUTFILE"

    if command -v jq &>/dev/null; then
        sigint_outcome=$(jq -r '.children[0].outcome' "$SIGINT_LOG_DIR/spawn-codex-wave-status.json" 2>/dev/null)
        sigint_signal=$(jq -r '.children[0].signal' "$SIGINT_LOG_DIR/spawn-codex-wave-status.json" 2>/dev/null)
        sigint_initiator=$(jq -r '.children[0].cancellation_initiator' "$SIGINT_LOG_DIR/spawn-codex-wave-status.json" 2>/dev/null)
        assert_eq "cancelled_by_operator" "$sigint_outcome" "structured status: SIGINT child outcome is cancelled_by_operator"
        assert_eq "INT" "$sigint_signal" "structured status: SIGINT child records signal=INT"
        assert_eq "operator" "$sigint_initiator" "structured status: SIGINT child records cancellation_initiator=operator"

        sigterm_outcome=$(jq -r '.children[0].outcome' "$SIGTERM_LOG_DIR/spawn-codex-wave-status.json" 2>/dev/null)
        sigterm_signal=$(jq -r '.children[0].signal' "$SIGTERM_LOG_DIR/spawn-codex-wave-status.json" 2>/dev/null)
        sigterm_initiator=$(jq -r '.children[0].cancellation_initiator' "$SIGTERM_LOG_DIR/spawn-codex-wave-status.json" 2>/dev/null)
        assert_eq "cancelled_by_parent" "$sigterm_outcome" "structured status: SIGTERM child outcome is cancelled_by_parent"
        assert_eq "TERM" "$sigterm_signal" "structured status: SIGTERM child records signal=TERM"
        assert_eq "parent" "$sigterm_initiator" "structured status: SIGTERM child records cancellation_initiator=parent"
    fi

    rm -rf "$SIGINT_LOG_DIR" "$SIGTERM_LOG_DIR" "$SIG_STUB_DIR"
else
    echo "  (python3 not available -- skipping explicit-signal cancellation assertions; see NOTE ON DELIVERY MECHANISM above)"
fi

# ============================================================
# Section 14: opt-in hard wall-clock deadline (issue #52) -- explicit,
# never inferred from silence. A child exceeding a configured
# LOOM_CODEX_WAVE_HARD_DEADLINE_SEC is cancelled with its own distinct
# outcome, separate from both "failed" and the signal-based cancellations.
# ============================================================

echo ""
echo "Testing opt-in hard deadline (issue #52)..."

DEADLINE_STUB_DIR="$(mktemp -d)"
cat > "$DEADLINE_STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
trap 'exit 143' TERM
sleep 20
exit 0
STUB
chmod +x "$DEADLINE_STUB_DIR/codex"

DEADLINE_LOG_DIR="$(mktemp -d)"
DEADLINE_START=$(date +%s.%N 2>/dev/null || date +%s)
output=$(PATH="$DEADLINE_STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$DEADLINE_LOG_DIR" \
    LOOM_CODEX_WAVE_HARD_DEADLINE_SEC=1 \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 9301 2>&1)
DEADLINE_END=$(date +%s.%N 2>/dev/null || date +%s)
DEADLINE_ELAPSED=$(awk -v s="$DEADLINE_START" -v e="$DEADLINE_END" 'BEGIN { print e - s }')

assert_contains "cancelled_by_deadline" "$output" "a child exceeding the configured hard deadline is reported as cancelled_by_deadline"
assert_lt "$DEADLINE_ELAPSED" "10" \
    "the deadline-exceeding child was cancelled well before its 20s sleep would have finished (actual=${DEADLINE_ELAPSED}s)"
assert_not_contains "cancelled_by_operator" "$output" "the deadline path does not report itself as operator-initiated"
assert_not_contains "cancelled_by_parent" "$output" "the deadline path does not report itself as parent-initiated"

if command -v jq &>/dev/null; then
    deadline_outcome=$(jq -r '.children[0].outcome' "$DEADLINE_LOG_DIR/spawn-codex-wave-status.json" 2>/dev/null)
    deadline_initiator=$(jq -r '.children[0].cancellation_initiator' "$DEADLINE_LOG_DIR/spawn-codex-wave-status.json" 2>/dev/null)
    assert_eq "cancelled_by_deadline" "$deadline_outcome" "structured status: deadline child outcome is cancelled_by_deadline"
    assert_eq "deadline" "$deadline_initiator" "structured status: deadline child records cancellation_initiator=deadline"
fi
rm -rf "$DEADLINE_LOG_DIR" "$DEADLINE_STUB_DIR"

# Without the env var set at all, no deadline applies -- a child that would
# have exceeded the same duration completes normally (regression guard that
# the feature is opt-in, not a hidden default timeout).
NO_DEADLINE_STUB_DIR="$(mktemp -d)"
cat > "$NO_DEADLINE_STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
sleep 1.5
exit 0
STUB
chmod +x "$NO_DEADLINE_STUB_DIR/codex"
NO_DEADLINE_LOG_DIR="$(mktemp -d)"
output=$(PATH="$NO_DEADLINE_STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$NO_DEADLINE_LOG_DIR" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 9302 2>&1)
assert_contains "outcome breakdown -- completed=1 failed=0 cancelled=0" "$output" \
    "without LOOM_CODEX_WAVE_HARD_DEADLINE_SEC set, no deadline is applied -- the default process-level path has no inactivity/time timeout"
rm -rf "$NO_DEADLINE_LOG_DIR" "$NO_DEADLINE_STUB_DIR"

# ============================================================
# Section 15: claim/lease preflight (issue #53) -- reproduction of the #51
# "silent no-op rerun" defect and its fix. A retry must skip a genuinely
# LIVE claim without spawning a child, and must reclaim + spawn on an
# ORPHANED claim (the exact curator-done + loom:building + partial-diff +
# no-PR + no-live-owner scenario from the issue).
# ============================================================

echo ""
echo "Testing claim/lease preflight -- skip live, reclaim orphaned (issue #53)..."

SWEEP_CLAIM_BIN_UNDER_TEST="$SCRIPTS_DIR/sweep-claim.sh"

# --- 15a: a LIVE claim (real, currently-running owner) is never stolen ---
CLAIM_WS_LIVE="$(mktemp -d)"
CLAIM_LOG_DIR_LIVE="$(mktemp -d)"
sleep 30 &
LIVE_OWNER_PID=$!
LOOM_WORKSPACE="$CLAIM_WS_LIVE" "$SWEEP_CLAIM_BIN_UNDER_TEST" acquire 9401 --pid "$LIVE_OWNER_PID" --runtime codex >/dev/null

set +e
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$CLAIM_LOG_DIR_LIVE" \
    LOOM_WORKSPACE="$CLAIM_WS_LIVE" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 9401 2>&1)
exit_code=$?
set -e
assert_eq "0" "$exit_code" "a retry against a genuinely live claim exits 0 (a skip, not a failure)"
assert_contains "has a LIVE claim -- not spawning a child" "$output" \
    "the wave logs that issue #9401's live claim blocked spawning a child"
assert_contains "outcome breakdown -- completed=0 failed=0 cancelled=0 skipped=1" "$output" \
    "the outcome breakdown counts the live-claim issue as skipped, not completed"
assert_eq "0" "$([[ -f "$CLAIM_LOG_DIR_LIVE/spawn-codex-wave-issue-9401.log" ]] && echo 1 || echo 0)" \
    "no per-issue log file was created for a skipped issue -- no child was ever spawned"

if command -v jq &>/dev/null; then
    skipped_outcome=$(jq -r '.children[0].outcome' "$CLAIM_LOG_DIR_LIVE/spawn-codex-wave-status.json" 2>/dev/null)
    skipped_pid=$(jq -r '.children[0].pid' "$CLAIM_LOG_DIR_LIVE/spawn-codex-wave-status.json" 2>/dev/null)
    assert_eq "skipped" "$skipped_outcome" "structured status: the live-claim issue's outcome is 'skipped', distinct from 'completed'"
    assert_eq "null" "$skipped_pid" "structured status: a skipped issue has no child pid (none was ever spawned)"
fi

live_claim_status=$(LOOM_WORKSPACE="$CLAIM_WS_LIVE" "$SWEEP_CLAIM_BIN_UNDER_TEST" status 9401)
assert_contains '"status": "active"' "$live_claim_status" \
    "the live claim itself is untouched by the skip -- still active, never disturbed"

kill "$LIVE_OWNER_PID" 2>/dev/null || true
rm -rf "$CLAIM_WS_LIVE" "$CLAIM_LOG_DIR_LIVE"

# --- 15b: an ORPHANED claim (owner dead) is reclaimed and a child spawned;
# this is the exact #51 reproduction: curator-done + loom:building +
# worktree partial diff + no PR + no live owner -- rerunning must NOT no-op.
# The fixture also plants a sweep-checkpoint (phase=curator-done) and a fake
# worktree directory with a "partial diff" marker file, matching the full
# reproduction scenario verbatim -- and asserts BOTH survive the reclaim
# untouched (spawn-codex-wave.sh's own claim gate never inspects or mutates
# checkpoints/worktrees; that stays the LLM session's job per worktree.sh's
# idempotency contract).
CLAIM_WS_ORPHAN="$(mktemp -d)"
CLAIM_LOG_DIR_ORPHAN="$(mktemp -d)"
SWEEP_CHECKPOINT_BIN_UNDER_TEST="$SCRIPTS_DIR/sweep-checkpoint.sh"

# Plant the checkpoint (curator-done) and a fake worktree with a partial diff.
LOOM_WORKSPACE="$CLAIM_WS_ORPHAN" "$SWEEP_CHECKPOINT_BIN_UNDER_TEST" write 9402 curator-done --task-id "repro-53" >/dev/null
mkdir -p "$CLAIM_WS_ORPHAN/.loom/worktrees/issue-9402"
echo "diff --git a/foo.txt b/foo.txt (partial builder work, pre-interruption)" \
    > "$CLAIM_WS_ORPHAN/.loom/worktrees/issue-9402/PARTIAL_DIFF_MARKER"

( exit 0 ) &
DEAD_OWNER_SRC=$!
wait "$DEAD_OWNER_SRC" 2>/dev/null
DEAD_OWNER_PID=$DEAD_OWNER_SRC
LOOM_WORKSPACE="$CLAIM_WS_ORPHAN" "$SWEEP_CLAIM_BIN_UNDER_TEST" acquire 9402 --pid "$DEAD_OWNER_PID" --runtime codex >/dev/null

set +e
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$CLAIM_LOG_DIR_ORPHAN" \
    LOOM_WORKSPACE="$CLAIM_WS_ORPHAN" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 9402 2>&1)
exit_code=$?
set -e
assert_eq "0" "$exit_code" "a retry against an orphaned (dead-owner) claim exits 0 (reclaimed and completed)"
assert_contains "outcome breakdown -- completed=1 failed=0 cancelled=0 skipped=0" "$output" \
    "the outcome breakdown counts the reclaimed issue as completed -- a real child was spawned and ran, not a no-op"
assert_eq "1" "$([[ -f "$CLAIM_LOG_DIR_ORPHAN/spawn-codex-wave-issue-9402.log" ]] && echo 1 || echo 0)" \
    "a per-issue log file WAS created for the reclaimed issue -- this is the #51 fix: the retry actually ran Builder instead of silently no-op'ing"

reclaimed_status=$(LOOM_WORKSPACE="$CLAIM_WS_ORPHAN" "$SWEEP_CLAIM_BIN_UNDER_TEST" status 9402)
assert_contains '"status": "released"' "$reclaimed_status" \
    "after a completed reclaim, the claim is released (a clean terminal state, not left dangling active)"

checkpoint_phase_after="$(LOOM_WORKSPACE="$CLAIM_WS_ORPHAN" "$SWEEP_CHECKPOINT_BIN_UNDER_TEST" phase 9402)"
assert_eq "curator-done" "$checkpoint_phase_after" \
    "the curator-done checkpoint survives the reclaim untouched -- spawn-codex-wave.sh's claim gate never mutates checkpoints (that stays the sweep skill's job)"
assert_eq "1" "$([[ -f "$CLAIM_WS_ORPHAN/.loom/worktrees/issue-9402/PARTIAL_DIFF_MARKER" ]] && echo 1 || echo 0)" \
    "the worktree's partial diff marker survives the reclaim untouched -- reused, not discarded or duplicated"

rm -rf "$CLAIM_WS_ORPHAN" "$CLAIM_LOG_DIR_ORPHAN"

# --- 15c: on FAILURE, the wave releases the claim to 'resumable' (not left
# active/undead) so the NEXT retry can reclaim it too -- this is the
# "owning runner releases the claim" half of the #53 contract.
CLAIM_WS_FAIL="$(mktemp -d)"
CLAIM_LOG_DIR_FAIL="$(mktemp -d)"
FAIL_ONE_STUB_DIR="$(mktemp -d)"
cat > "$FAIL_ONE_STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$FAIL_ONE_STUB_DIR/codex"

set +e
output=$(PATH="$FAIL_ONE_STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$CLAIM_LOG_DIR_FAIL" \
    LOOM_WORKSPACE="$CLAIM_WS_FAIL" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 9403 2>&1)
set -e
assert_contains "outcome breakdown -- completed=0 failed=1" "$output" "a genuinely failing child is still counted as failed (unchanged #52 behavior)"
failed_claim_status=$(LOOM_WORKSPACE="$CLAIM_WS_FAIL" "$SWEEP_CLAIM_BIN_UNDER_TEST" status 9403)
assert_contains '"status": "resumable"' "$failed_claim_status" \
    "after a failed child, the claim is released to resumable -- the next retry can reclaim it without operator intervention"

rm -rf "$CLAIM_WS_FAIL" "$CLAIM_LOG_DIR_FAIL" "$FAIL_ONE_STUB_DIR"

# --- 15d: on CANCELLATION (SIGTERM), the wave releases the claim to
# 'resumable' too -- cancellation is recoverable, not corrupt (per #52's
# outcome taxonomy, consumed verbatim by #53).
if command -v python3 &>/dev/null; then
    CLAIM_WS_CANCEL="$(mktemp -d)"
    CLAIM_LOG_DIR_CANCEL="$(mktemp -d)"
    CANCEL_STUB_DIR="$(mktemp -d)"
    cat > "$CANCEL_STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
trap 'exit 143' TERM
sleep 30
exit 0
STUB
    chmod +x "$CANCEL_STUB_DIR/codex"

    CANCEL_OUTFILE="$(mktemp)"
    set +e
    CANCEL_STUB_DIR="$CANCEL_STUB_DIR" SPAWN_CODEX_WAVE_SH="$SCRIPTS_DIR/spawn-codex-wave.sh" \
    CANCEL_LOG_DIR="$CLAIM_LOG_DIR_CANCEL" CANCEL_WORKSPACE="$CLAIM_WS_CANCEL" CANCEL_OUTFILE="$CANCEL_OUTFILE" \
    python3 - <<'PYEOF'
import os, signal, subprocess, time

script = os.environ["SPAWN_CODEX_WAVE_SH"]
env = dict(os.environ)
env["PATH"] = os.environ["CANCEL_STUB_DIR"] + ":" + env.get("PATH", "")
env["LOOM_CODEX_WAVE_LOG_DIR"] = os.environ["CANCEL_LOG_DIR"]
env["LOOM_WORKSPACE"] = os.environ["CANCEL_WORKSPACE"]

with open(os.environ["CANCEL_OUTFILE"], "wb") as f:
    proc = subprocess.Popen([script, "9404"], stdout=f, stderr=subprocess.STDOUT, env=env)
    time.sleep(1)
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=15)
PYEOF
    set -e
    cancel_output="$(cat "$CANCEL_OUTFILE" 2>/dev/null)"
    assert_contains "cancelled_by_parent" "$cancel_output" "the cancelled child's outcome is reported as cancelled_by_parent"

    cancelled_claim_status=$(LOOM_WORKSPACE="$CLAIM_WS_CANCEL" "$SWEEP_CLAIM_BIN_UNDER_TEST" status 9404)
    assert_contains '"status": "resumable"' "$cancelled_claim_status" \
        "after a parent-cancelled child, the claim is released to resumable -- cancellation is recoverable, not corrupt (#52 taxonomy consumed by #53)"

    rm -f "$CANCEL_OUTFILE"
    rm -rf "$CLAIM_WS_CANCEL" "$CLAIM_LOG_DIR_CANCEL" "$CANCEL_STUB_DIR"
else
    echo "  (python3 not available -- skipping cancellation-releases-claim assertion)"
fi

# --- 15e: CONCURRENCY at the wave level -- two spawn-codex-wave.sh
# invocations racing on the SAME single issue must result in exactly one
# child actually running (the other must see the live claim the first
# invocation acquired and skip). This is the wave-level analogue of
# test-sweep-claim.sh's lower-level acquire race, exercised through the
# actual script under test end-to-end.
echo ""
echo "Testing wave-level concurrent retries are atomic (issue #53)..."

CLAIM_WS_RACE="$(mktemp -d)"
RACE_LOG_DIR_A="$(mktemp -d)"
RACE_LOG_DIR_B="$(mktemp -d)"
SLOW_STUB_DIR="$(mktemp -d)"
cat > "$SLOW_STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
sleep 1
exit 0
STUB
chmod +x "$SLOW_STUB_DIR/codex"

RACE_OUT_A="$(mktemp)"
RACE_OUT_B="$(mktemp)"
(
    PATH="$SLOW_STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$RACE_LOG_DIR_A" LOOM_WORKSPACE="$CLAIM_WS_RACE" \
        "$SCRIPTS_DIR/spawn-codex-wave.sh" 9405 >"$RACE_OUT_A" 2>&1
) &
WAVE_JOB_A=$!
(
    PATH="$SLOW_STUB_DIR:$NOCODEX_PATH" LOOM_CODEX_WAVE_LOG_DIR="$RACE_LOG_DIR_B" LOOM_WORKSPACE="$CLAIM_WS_RACE" \
        "$SCRIPTS_DIR/spawn-codex-wave.sh" 9405 >"$RACE_OUT_B" 2>&1
) &
WAVE_JOB_B=$!
set +e
wait "$WAVE_JOB_A" "$WAVE_JOB_B" 2>/dev/null
set -e

race_out_a="$(cat "$RACE_OUT_A" 2>/dev/null)"
race_out_b="$(cat "$RACE_OUT_B" 2>/dev/null)"

# Exactly one of the two concurrent wave invocations should have actually
# spawned a child (a per-issue log file with real content); the other must
# have skipped without spawning.
log_a_exists=0; log_b_exists=0
[[ -f "$RACE_LOG_DIR_A/spawn-codex-wave-issue-9405.log" ]] && log_a_exists=1
[[ -f "$RACE_LOG_DIR_B/spawn-codex-wave-issue-9405.log" ]] && log_b_exists=1
spawned_count=$((log_a_exists + log_b_exists))
assert_eq "1" "$spawned_count" "exactly one of two concurrent spawn-codex-wave.sh invocations for the same issue actually spawns a child"

skip_count=0
[[ "$race_out_a" == *"has a LIVE claim -- not spawning a child"* ]] && skip_count=$((skip_count + 1))
[[ "$race_out_b" == *"has a LIVE claim -- not spawning a child"* ]] && skip_count=$((skip_count + 1))
assert_eq "1" "$skip_count" "exactly one of the two concurrent invocations reports the other's live claim and skips"

rm -f "$RACE_OUT_A" "$RACE_OUT_B"
rm -rf "$CLAIM_WS_RACE" "$RACE_LOG_DIR_A" "$RACE_LOG_DIR_B" "$SLOW_STUB_DIR"

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

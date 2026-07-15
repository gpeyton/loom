#!/usr/bin/env bash
# test-codex-parity.sh — Cross-cutting parity tests spanning spawn-codex.sh,
# spawn-worker.sh, spawn-codex-wave.sh, and spawn-claude.sh (issue #34, Epic
# #30 Phase 1). These claims cannot be proven inside any single script's own
# suite because they compare behavior ACROSS entry points / ACROSS runtimes:
#
#   (a) Direct spawn-codex.sh invocation, spawn-worker.sh --worker codex, and
#       a spawn-codex-wave.sh child all resolve to the IDENTICAL effective
#       permission flag for the same env-var state (no drift between entry
#       points introduced by #31/#32).
#   (b) Absent workerType / --worker unset still selects Claude end-to-end
#       (regression pin — not just "codex works", which the other suites
#       already cover exhaustively).
#   (c) LOOM_CODEX_SAFE / LOOM_CODEX_UNSAFE never alter spawn-claude.sh's
#       resolved argv, env, token rotation, or model selection at all — the
#       Codex-only permission env vars must be complete no-ops for the
#       Claude runner.
#   (d) Codex model precedence stays explicit-argument > environment >
#       Codex-default, unaffected by simultaneous permission-flag changes
#       (the two concerns — model and permissions — never interact).
#
# Style matches test-spawn-codex.sh / test-spawn-worker.sh / test-spawn-claude.sh
# — plain bash, hand-rolled assertions, fake `claude`/`codex` binaries on PATH
# that record their argv/env. Bats is NOT used in this repository.
#
# Usage:
#   ./defaults/scripts/tests/test-codex-parity.sh

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

# Extract only the lines the stub `claude` binary itself printed (its
# recorded token/args), filtering out spawn-claude.sh's own `[timestamp] ...`
# log lines. Mirrors test-spawn-worker.sh's stub_lines() helper.
claude_stub_lines() {
    grep '^stub-claude ' <<<"$1" || true
}

# Extract the single effective Codex permission flag (if any) present in a
# spawn-codex.sh "would-exec" line, a stub-codex recorded argv line, or a
# spawn-codex-wave.sh child's log file. The two flags are mutually exclusive
# by construction (spawn-codex.sh emits at most one), so first-match wins.
extract_permission_flag() {
    local text="$1"
    if [[ "$text" == *"--dangerously-bypass-approvals-and-sandbox"* ]]; then
        echo "--dangerously-bypass-approvals-and-sandbox"
    elif [[ "$text" == *"--full-auto"* ]]; then
        echo "--full-auto"
    else
        echo "(none)"
    fi
}

echo "Testing cross-cutting Codex/Claude parity (issue #34, Epic #30 Phase 1)..."

# ============================================================
# Shared fixtures
# ============================================================

STUB_DIR="$(mktemp -d)"
TEST_WS="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR" "$TEST_WS"' EXIT

cat > "$STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
echo "stub-codex args=$*"
exit 0
STUB
chmod +x "$STUB_DIR/codex"

cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "stub-claude got token=${CLAUDE_CODE_OAUTH_TOKEN}"
echo "stub-claude args=$*"
exit 0
STUB
chmod +x "$STUB_DIR/claude"

mkdir -p "$TEST_WS/.loom/tokens"
chmod 700 "$TEST_WS/.loom/tokens"
echo -n "fake-token-alpha" > "$TEST_WS/.loom/tokens/alpha.token"
chmod 600 "$TEST_WS/.loom/tokens/alpha.token"

# ============================================================
# (a) Same permission flag across all three Codex entry points
# ============================================================

echo ""
echo "(a) Testing permission-flag parity across spawn-codex.sh / spawn-worker.sh / spawn-codex-wave.sh..."

# --- Case 1: default env (no LOOM_CODEX_SAFE, no LOOM_CODEX_UNSAFE) -> full access
unset LOOM_CODEX_SAFE LOOM_CODEX_UNSAFE 2>/dev/null || true

direct_output=$(PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
direct_flag="$(extract_permission_flag "$direct_output")"

worker_output=$(PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 \
    "$SCRIPTS_DIR/spawn-worker.sh" --worker codex -p "hello" --dangerously-skip-permissions 2>&1 || true)
worker_flag="$(extract_permission_flag "$worker_output")"

WAVE_LOG_DIR1="$(mktemp -d)"
PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 LOOM_CODEX_WAVE_LOG_DIR="$WAVE_LOG_DIR1" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 9001 >/dev/null 2>&1 || true
wave_child_log="$(cat "$WAVE_LOG_DIR1/spawn-codex-wave-issue-9001.log" 2>/dev/null || echo "")"
wave_flag="$(extract_permission_flag "$wave_child_log")"
rm -rf "$WAVE_LOG_DIR1"

assert_eq "--dangerously-bypass-approvals-and-sandbox" "$direct_flag" \
    "default env: direct spawn-codex.sh resolves to the full-access flag"
assert_eq "$direct_flag" "$worker_flag" \
    "default env: spawn-worker.sh --worker codex resolves to the SAME flag as direct spawn-codex.sh"
assert_eq "$direct_flag" "$wave_flag" \
    "default env: spawn-codex-wave.sh child resolves to the SAME flag as direct spawn-codex.sh"

# --- Case 2: LOOM_CODEX_SAFE=1 -> sandboxed opt-out
direct_output=$(PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 LOOM_CODEX_SAFE=1 \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
direct_flag="$(extract_permission_flag "$direct_output")"

worker_output=$(PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 LOOM_CODEX_SAFE=1 \
    "$SCRIPTS_DIR/spawn-worker.sh" --worker codex -p "hello" --dangerously-skip-permissions 2>&1 || true)
worker_flag="$(extract_permission_flag "$worker_output")"

WAVE_LOG_DIR2="$(mktemp -d)"
PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 LOOM_CODEX_SAFE=1 LOOM_CODEX_WAVE_LOG_DIR="$WAVE_LOG_DIR2" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 9002 >/dev/null 2>&1 || true
wave_child_log="$(cat "$WAVE_LOG_DIR2/spawn-codex-wave-issue-9002.log" 2>/dev/null || echo "")"
wave_flag="$(extract_permission_flag "$wave_child_log")"
rm -rf "$WAVE_LOG_DIR2"

assert_eq "--full-auto" "$direct_flag" \
    "LOOM_CODEX_SAFE=1: direct spawn-codex.sh resolves to the sandboxed flag"
assert_eq "$direct_flag" "$worker_flag" \
    "LOOM_CODEX_SAFE=1: spawn-worker.sh --worker codex resolves to the SAME flag as direct spawn-codex.sh"
assert_eq "$direct_flag" "$wave_flag" \
    "LOOM_CODEX_SAFE=1: spawn-codex-wave.sh child resolves to the SAME flag as direct spawn-codex.sh"

# --- Case 3: LOOM_CODEX_UNSAFE=1 alone -> deprecated no-op alias for full access
direct_output=$(PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 LOOM_CODEX_UNSAFE=1 \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
direct_flag="$(extract_permission_flag "$direct_output")"

worker_output=$(PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 LOOM_CODEX_UNSAFE=1 \
    "$SCRIPTS_DIR/spawn-worker.sh" --worker codex -p "hello" --dangerously-skip-permissions 2>&1 || true)
worker_flag="$(extract_permission_flag "$worker_output")"

WAVE_LOG_DIR3="$(mktemp -d)"
PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 LOOM_CODEX_UNSAFE=1 LOOM_CODEX_WAVE_LOG_DIR="$WAVE_LOG_DIR3" \
    "$SCRIPTS_DIR/spawn-codex-wave.sh" 9003 >/dev/null 2>&1 || true
wave_child_log="$(cat "$WAVE_LOG_DIR3/spawn-codex-wave-issue-9003.log" 2>/dev/null || echo "")"
wave_flag="$(extract_permission_flag "$wave_child_log")"
rm -rf "$WAVE_LOG_DIR3"

assert_eq "--dangerously-bypass-approvals-and-sandbox" "$direct_flag" \
    "LOOM_CODEX_UNSAFE=1 alone: direct spawn-codex.sh still resolves to full-access (deprecated no-op alias)"
assert_eq "$direct_flag" "$worker_flag" \
    "LOOM_CODEX_UNSAFE=1 alone: spawn-worker.sh --worker codex resolves to the SAME flag as direct spawn-codex.sh"
assert_eq "$direct_flag" "$wave_flag" \
    "LOOM_CODEX_UNSAFE=1 alone: spawn-codex-wave.sh child resolves to the SAME flag as direct spawn-codex.sh"

unset LOOM_CODEX_SAFE LOOM_CODEX_UNSAFE 2>/dev/null || true

# ============================================================
# (b) Absent workerType still selects Claude end-to-end (regression pin)
# ============================================================

echo ""
echo "(b) Testing absent workerType still selects Claude end-to-end (regression pin)..."

unset LOOM_WORKER 2>/dev/null || true
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    "$SCRIPTS_DIR/spawn-worker.sh" -p "ping" 2>&1 || true)
assert_contains "stub-claude got token=fake-token-alpha" "$output" \
    "no --worker/no LOOM_WORKER dispatches to the Claude runner (token exported)"
assert_contains "stub-claude args=-p ping" "$output" \
    "no --worker/no LOOM_WORKER forwards args to claude, not codex"
assert_not_contains "stub-codex" "$output" \
    "no --worker/no LOOM_WORKER never touches the codex runner"

# Explicit empty LOOM_WORKER="" also falls back to claude (spawn-worker.sh's
# ${LOOM_WORKER:-claude} treats unset AND empty the same way).
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_WORKER="" \
    "$SCRIPTS_DIR/spawn-worker.sh" -p "ping" 2>&1 || true)
assert_contains "stub-claude got token=fake-token-alpha" "$output" \
    "empty LOOM_WORKER also falls back to claude end-to-end"
assert_not_contains "stub-codex" "$output" \
    "empty LOOM_WORKER never touches the codex runner"

# ============================================================
# (c) LOOM_CODEX_SAFE/LOOM_CODEX_UNSAFE never affect spawn-claude.sh
# ============================================================

echo ""
echo "(c) Testing LOOM_CODEX_SAFE/LOOM_CODEX_UNSAFE never affect spawn-claude.sh..."

baseline_output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" --model claude-sonnet-4-6 2>&1 || true)

safe_output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_CODEX_SAFE=1 \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" --model claude-sonnet-4-6 2>&1 || true)

unsafe_output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_CODEX_UNSAFE=1 \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" --model claude-sonnet-4-6 2>&1 || true)

both_output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_CODEX_SAFE=1 LOOM_CODEX_UNSAFE=1 \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" --model claude-sonnet-4-6 2>&1 || true)

assert_eq "$(claude_stub_lines "$baseline_output")" "$(claude_stub_lines "$safe_output")" \
    "LOOM_CODEX_SAFE=1 does not change spawn-claude.sh's resolved argv/env (stub-recorded lines identical)"
assert_eq "$(claude_stub_lines "$baseline_output")" "$(claude_stub_lines "$unsafe_output")" \
    "LOOM_CODEX_UNSAFE=1 does not change spawn-claude.sh's resolved argv/env"
assert_eq "$(claude_stub_lines "$baseline_output")" "$(claude_stub_lines "$both_output")" \
    "LOOM_CODEX_SAFE=1 + LOOM_CODEX_UNSAFE=1 together do not change spawn-claude.sh's resolved argv/env"

# Token rotation: same account is selected regardless (spelled out
# explicitly, in addition to the stub_lines equality above).
assert_contains "stub-claude got token=fake-token-alpha" "$safe_output" \
    "token rotation picks the same account with LOOM_CODEX_SAFE=1 set"
assert_contains "stub-claude got token=fake-token-alpha" "$unsafe_output" \
    "token rotation picks the same account with LOOM_CODEX_UNSAFE=1 set"

# Model selection: explicit --model still resolves identically with the
# Codex-only env vars set (no interaction between the two concerns).
assert_contains "stub-claude args=-p ping --model claude-sonnet-4-6" "$safe_output" \
    "model selection unaffected by LOOM_CODEX_SAFE=1"
assert_contains "stub-claude args=-p ping --model claude-sonnet-4-6" "$unsafe_output" \
    "model selection unaffected by LOOM_CODEX_UNSAFE=1"

# LOOM_MODEL env-based selection (not just an explicit --model arg) is also
# unaffected by the Codex-only permission env vars.
loom_model_baseline=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_MODEL="claude-opus-4-8" \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" 2>&1 || true)
loom_model_with_codex_env=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_MODEL="claude-opus-4-8" LOOM_CODEX_SAFE=1 LOOM_CODEX_UNSAFE=1 \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" 2>&1 || true)
assert_eq "$(claude_stub_lines "$loom_model_baseline")" "$(claude_stub_lines "$loom_model_with_codex_env")" \
    "LOOM_MODEL-driven model selection is byte-identical with Codex permission env vars set"

# ============================================================
# (d) Codex model precedence is unaffected by permission-flag changes
# ============================================================

echo ""
echo "(d) Testing Codex model precedence is unaffected by permission-flag changes..."

# Explicit -m wins over LOOM_MODEL, with the default (full-access) posture.
output=$(PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 \
    LOOM_MODEL="gpt-5-codex" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" -m "o3" --dangerously-skip-permissions 2>&1 || true)
assert_contains "spawn-codex would-exec: codex exec --dangerously-bypass-approvals-and-sandbox -m o3 hello" "$output" \
    "explicit -m wins over LOOM_MODEL under the default full-access posture (composability baseline)"

# Same precedence holds with LOOM_CODEX_SAFE=1 (sandboxed posture) — the
# permission-flag change does not disturb model precedence.
output=$(PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 LOOM_CODEX_SAFE=1 \
    LOOM_MODEL="gpt-5-codex" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" -m "o3" --dangerously-skip-permissions 2>&1 || true)
assert_contains "spawn-codex would-exec: codex exec --full-auto -m o3 hello" "$output" \
    "explicit -m still wins over LOOM_MODEL under LOOM_CODEX_SAFE=1 -- permission change does not affect model precedence"

# LOOM_MODEL alone (no explicit -m) resolves identically regardless of
# permission posture.
output_default=$(PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 \
    LOOM_MODEL="gpt-5-codex" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
output_safe=$(PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 LOOM_CODEX_SAFE=1 \
    LOOM_MODEL="gpt-5-codex" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
model_default="$(grep -oE -- '-m [^ ]+' <<<"$output_default" | head -1)"
model_safe="$(grep -oE -- '-m [^ ]+' <<<"$output_safe" | head -1)"
assert_eq "-m gpt-5-codex" "$model_default" \
    "LOOM_MODEL resolves to -m gpt-5-codex under the default posture"
assert_eq "$model_default" "$model_safe" \
    "LOOM_MODEL resolution is identical between full-access and LOOM_CODEX_SAFE=1 postures"

# No model configured at all -> Codex default preserved (no -m emitted),
# independent of permission posture.
output_nomodel_default=$(PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
output_nomodel_safe=$(PATH="$STUB_DIR:$PATH" LOOM_CODEX_NO_EXEC=1 LOOM_CODEX_SAFE=1 \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
assert_not_contains "-m " "$output_nomodel_default" \
    "no LOOM_MODEL/-m -> Codex default preserved under the default posture"
assert_not_contains "-m " "$output_nomodel_safe" \
    "no LOOM_MODEL/-m -> Codex default preserved under the LOOM_CODEX_SAFE=1 posture too"

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

#!/usr/bin/env bash
# test-spawn-worker.sh — Tests for spawn-worker.sh (issue #2, Phase 1 of epic #1).
#
# Style matches test-spawn-claude.sh — plain bash, hand-rolled assertions.
# Bats is NOT used in this repository.
#
# Usage:
#   ./.loom/scripts/tests/test-spawn-worker.sh

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

# Extract only the lines the stub `claude` binary itself printed (its
# recorded token/args), filtering out spawn-worker.sh's / spawn-claude.sh's
# own `[timestamp] ...` log lines on stderr. This lets us compare argv/env
# forwarding byte-for-byte between a direct spawn-claude.sh invocation and
# one dispatched through spawn-worker.sh, without the dispatcher's extra log
# line breaking the comparison.
stub_lines() {
    grep '^stub-claude ' <<<"$1" || true
}

# ============================================================
# Setup: fake workspace + stub `claude` binary (mirrors
# test-spawn-claude.sh's fixture).
# ============================================================

echo "Testing spawn-worker.sh dispatch..."

TEST_WS="$(mktemp -d)"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_WS" "$STUB_DIR"' EXIT

mkdir -p "$TEST_WS/.loom/tokens"
chmod 700 "$TEST_WS/.loom/tokens"
echo -n "fake-token-alpha" > "$TEST_WS/.loom/tokens/alpha.token"
chmod 600 "$TEST_WS/.loom/tokens/alpha.token"

cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "stub-claude got token=${CLAUDE_CODE_OAUTH_TOKEN}"
echo "stub-claude args=$*"
exit 0
STUB
chmod +x "$STUB_DIR/claude"

# ============================================================
# Section 1: zero-behavior-change — no worker type resolves
# identically to invoking spawn-claude.sh directly.
# ============================================================

echo ""
echo "Testing default (no worker type) resolves to spawn-claude.sh..."

direct_output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" 2>&1 || true)
via_dispatcher_output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    "$SCRIPTS_DIR/spawn-worker.sh" -p "ping" 2>&1 || true)

assert_eq "$(stub_lines "$direct_output")" "$(stub_lines "$via_dispatcher_output")" \
    "spawn-worker.sh with no worker type forwards identical argv/env to the stub claude as a direct spawn-claude.sh call"

assert_contains "stub-claude got token=fake-token-alpha" "$via_dispatcher_output" \
    "spawn-worker.sh (default) exports the selected token to claude"
assert_contains "stub-claude args=-p ping" "$via_dispatcher_output" \
    "spawn-worker.sh (default) passes args through to claude"

# ============================================================
# Section 2: explicit worker-type selection
# ============================================================

echo ""
echo "Testing explicit worker-type selection..."

# --worker claude
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    "$SCRIPTS_DIR/spawn-worker.sh" --worker claude -p "/loom:sweep 1" 2>&1 || true)
assert_contains "stub-claude args=-p /loom:sweep 1" "$output" \
    "--worker claude resolves to the Claude runner and forwards args"

# --worker=claude form
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    "$SCRIPTS_DIR/spawn-worker.sh" --worker=claude -p "ping" 2>&1 || true)
assert_contains "stub-claude args=-p ping" "$output" \
    "--worker=claude form resolves to the Claude runner"

# LOOM_WORKER=claude env
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_WORKER="claude" \
    "$SCRIPTS_DIR/spawn-worker.sh" -p "/loom:sweep 1" 2>&1 || true)
assert_contains "stub-claude args=-p /loom:sweep 1" "$output" \
    "LOOM_WORKER=claude env resolves to the Claude runner"

# Explicit --worker arg wins over LOOM_WORKER env (precedence check)
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_WORKER="bogus" \
    "$SCRIPTS_DIR/spawn-worker.sh" --worker claude -p "ping" 2>&1 || true)
assert_contains "stub-claude args=-p ping" "$output" \
    "explicit --worker arg wins over a conflicting LOOM_WORKER env value"

# ============================================================
# Section 3: unknown worker type -> EX_CONFIG (78)
# ============================================================

echo ""
echo "Testing unknown worker type..."

set +e
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_WORKER="bogus" \
    "$SCRIPTS_DIR/spawn-worker.sh" -p "test" 2>&1)
exit_code=$?
set -e
assert_eq "78" "$exit_code" "unknown worker type exits 78 (EX_CONFIG)"
assert_contains "Unknown worker type" "$output" \
    "unknown worker type error message is clear"
assert_contains "bogus" "$output" \
    "unknown worker type error message names the offending value"

# Same check via --worker flag instead of env var.
set +e
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    "$SCRIPTS_DIR/spawn-worker.sh" --worker codex -p "test" 2>&1)
exit_code=$?
set -e
assert_eq "78" "$exit_code" "--worker codex (not yet implemented) exits 78 (EX_CONFIG)"

# ============================================================
# Section 4: --help shows dispatcher usage without erroring
# ============================================================

echo ""
echo "Testing --help..."

set +e
output=$("$SCRIPTS_DIR/spawn-worker.sh" --help 2>&1)
exit_code=$?
set -e
assert_eq "0" "$exit_code" "--help exits 0"
assert_contains "spawn-worker.sh" "$output" \
    "--help output mentions spawn-worker.sh"
assert_contains "LOOM_WORKER" "$output" \
    "--help output documents LOOM_WORKER"

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

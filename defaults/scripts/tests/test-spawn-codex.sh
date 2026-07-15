#!/usr/bin/env bash
# test-spawn-codex.sh — Tests for spawn-codex.sh and the codex classify_error
# pattern table (issue #10, Phase 2 of epic #1).
#
# Style matches test-spawn-worker.sh / test-spawn-claude.sh — plain bash,
# hand-rolled assertions, a fake `codex` binary on PATH that records its argv
# (the same technique the existing tests use for a fake `claude`). Bats is NOT
# used in this repository.
#
# Usage:
#   ./.loom/scripts/tests/test-spawn-codex.sh

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

# Extract only the lines the stub `codex` binary itself printed (its recorded
# argv / env), filtering out spawn-codex.sh's own `[timestamp] ...` log lines.
stub_lines() {
    grep '^stub-codex ' <<<"$1" || true
}

# ============================================================
# Setup: fake `codex` binary that records its argv + OPENAI_API_KEY.
# ============================================================

echo "Testing spawn-codex.sh dispatch..."

STUB_DIR="$(mktemp -d)"
# A PATH that deliberately does NOT contain a `codex` binary, for the
# missing-binary test. Includes the standard system dirs so spawn-codex.sh's
# own helpers (date, grep, sed) still resolve.
NOCODEX_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
trap 'rm -rf "$STUB_DIR"' EXIT

cat > "$STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
echo "stub-codex args=$*"
echo "stub-codex openai_key=${OPENAI_API_KEY:-<unset>}"
exit 0
STUB
chmod +x "$STUB_DIR/codex"

# ============================================================
# Section 1: non-interactive (exec) + interactive modes
# ============================================================

echo ""
echo "Testing exec vs interactive dispatch..."

# -p "<prompt>" -> `codex exec "<prompt>"` (via the dispatcher)
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    "$SCRIPTS_DIR/spawn-worker.sh" --worker codex -p "hello" 2>&1 || true)
assert_contains "stub-codex args=exec hello" "$output" \
    "spawn-worker --worker codex -p 'hello' invokes 'codex exec hello'"

# Direct spawn-codex.sh call, same result
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
assert_contains "stub-codex args=exec hello" "$output" \
    "spawn-codex.sh -p 'hello' invokes 'codex exec hello'"

# --prompt long form also maps to exec
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    "$SCRIPTS_DIR/spawn-codex.sh" --prompt "hello world" 2>&1 || true)
assert_contains "stub-codex args=exec hello world" "$output" \
    "--prompt long form maps to 'codex exec' with the prompt"

# Interactive (no -p) -> bare `codex`, NOT `codex exec`
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    "$SCRIPTS_DIR/spawn-codex.sh" 2>&1 || true)
assert_contains "stub-codex args=" "$output" \
    "interactive mode (no -p) invokes bare codex"
assert_not_contains "args=exec" "$output" \
    "interactive mode does NOT use the exec subcommand"

# ============================================================
# Section 2: model selection (LOOM_MODEL -> -m, explicit wins)
# ============================================================

echo ""
echo "Testing model selection..."

# LOOM_MODEL reaches codex as -m <model>
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    LOOM_MODEL="gpt-5-codex" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
assert_contains "stub-codex args=exec -m gpt-5-codex hello" "$output" \
    "LOOM_MODEL=gpt-5-codex reaches codex as '-m gpt-5-codex'"
assert_contains "spawn-codex: model=gpt-5-codex (from LOOM_MODEL)" "$output" \
    "structured model log line emitted for LOOM_MODEL case"

# Explicit -m in args wins over LOOM_MODEL (no duplicate model flag)
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    LOOM_MODEL="gpt-5-codex" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" -m "o3" 2>&1 || true)
assert_contains "stub-codex args=exec -m o3 hello" "$output" \
    "explicit -m arg wins over LOOM_MODEL"
assert_not_contains "gpt-5-codex" "$(stub_lines "$output")" \
    "LOOM_MODEL value is not injected when explicit -m present"

# No model configured -> no -m emitted
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
assert_not_contains "-m" "$(stub_lines "$output")" \
    "no LOOM_MODEL + no -m arg emits NO model flag (Codex default preserved)"
assert_contains "spawn-codex: model=default" "$output" \
    "structured model=default log line emitted when nothing configured"

# ============================================================
# Section 3: permissions mapping (SAFETY-CRITICAL)
# ============================================================

echo ""
echo "Testing permissions mapping..."

# skip-permissions -> --full-auto by default; Claude flag not forwarded
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
assert_contains "stub-codex args=exec --full-auto hello" "$output" \
    "skip-permissions maps to --full-auto by default"
assert_not_contains "--dangerously-skip-permissions" "$(stub_lines "$output")" \
    "the Claude-specific --dangerously-skip-permissions flag is NOT forwarded to codex"

# LOOM_CODEX_UNSAFE=1 -> bypass-everything flag instead of --full-auto
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    LOOM_CODEX_UNSAFE=1 \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
assert_contains "stub-codex args=exec --dangerously-bypass-approvals-and-sandbox hello" "$output" \
    "LOOM_CODEX_UNSAFE=1 maps skip-permissions to --dangerously-bypass-approvals-and-sandbox"
assert_not_contains "--full-auto" "$(stub_lines "$output")" \
    "bypass mode does not also pass --full-auto"

# No skip-permissions -> no permission flag injected (Codex default sandbox)
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
assert_not_contains "--full-auto" "$(stub_lines "$output")" \
    "no skip-permissions -> no --full-auto injected"
assert_not_contains "--dangerously-bypass-approvals-and-sandbox" "$(stub_lines "$output")" \
    "no skip-permissions -> no bypass flag injected"

# LOOM_CODEX_UNSAFE=1 WITHOUT skip-permissions -> bypass stays gated (no flag)
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    LOOM_CODEX_UNSAFE=1 \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
assert_not_contains "--dangerously-bypass-approvals-and-sandbox" "$(stub_lines "$output")" \
    "LOOM_CODEX_UNSAFE=1 alone (no skip-permissions) does NOT inject the bypass flag"

# ============================================================
# Section 4: auth passthrough + missing-binary handling
# ============================================================

echo ""
echo "Testing auth + missing binary..."

# Pre-set OPENAI_API_KEY is visible to the codex child
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    OPENAI_API_KEY="sk-test-123" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
assert_contains "stub-codex openai_key=sk-test-123" "$output" \
    "pre-set OPENAI_API_KEY is passed through to the codex child"

# Missing codex binary -> exit 78 with install hint
set +e
output=$(PATH="$NOCODEX_PATH" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1)
exit_code=$?
set -e
assert_eq "78" "$exit_code" "missing codex binary exits 78 (EX_CONFIG)"
assert_contains "npm install -g @openai/codex" "$output" \
    "missing codex binary error includes the install hint"

# ============================================================
# Section 5: --help
# ============================================================

echo ""
echo "Testing --help..."

set +e
output=$("$SCRIPTS_DIR/spawn-codex.sh" --help 2>&1)
exit_code=$?
set -e
assert_eq "0" "$exit_code" "--help exits 0"
assert_contains "spawn-codex.sh" "$output" "--help output mentions spawn-codex.sh"
assert_contains "LOOM_CODEX_UNSAFE" "$output" "--help documents LOOM_CODEX_UNSAFE"
assert_contains "0.125.0" "$output" "--help pins the minimum supported Codex CLI version"

# ============================================================
# Section 6: codex classify_error pattern table (issue #10)
# ============================================================

echo ""
echo "Testing codex classify_error patterns..."
# shellcheck source=../lib/classify-error.sh
source "$SCRIPTS_DIR/lib/classify-error.sh"

# TOKEN_EXPIRED — 401 / invalid_api_key / auth failures
result=$(classify_error "401 Unauthorized" 1 codex)
assert_eq "TOKEN_EXPIRED" "$result" "codex: '401 Unauthorized' -> TOKEN_EXPIRED"

result=$(classify_error "stream error: exceeded retry limit, last status: 401 Unauthorized" 1 codex)
assert_eq "TOKEN_EXPIRED" "$result" "codex: real 'stream error ... 401 Unauthorized' -> TOKEN_EXPIRED"

result=$(classify_error "error type invalid_api_key" 1 codex)
assert_eq "TOKEN_EXPIRED" "$result" "codex: 'invalid_api_key' -> TOKEN_EXPIRED"

result=$(classify_error "Incorrect API key provided" 1 codex)
assert_eq "TOKEN_EXPIRED" "$result" "codex: 'Incorrect API key provided' -> TOKEN_EXPIRED"

# TOKEN_EXHAUSTED — quota-exhaustion phrasing
result=$(classify_error "rate_limit_exceeded" 1 codex)
assert_eq "TOKEN_EXHAUSTED" "$result" "codex: 'rate_limit_exceeded' -> TOKEN_EXHAUSTED"

result=$(classify_error "You've hit your usage limit" 1 codex)
assert_eq "TOKEN_EXHAUSTED" "$result" "codex: 'usage limit' -> TOKEN_EXHAUSTED"

result=$(classify_error "insufficient_quota" 1 codex)
assert_eq "TOKEN_EXHAUSTED" "$result" "codex: 'insufficient_quota' -> TOKEN_EXHAUSTED"

# RECOVERABLE — bare 429 throttle (generic pattern), 5xx, network
result=$(classify_error "429 Too Many Requests" 1 codex)
assert_eq "RECOVERABLE" "$result" "codex: bare '429 Too Many Requests' -> RECOVERABLE (transient throttle)"

result=$(classify_error "503 Service Unavailable" 1 codex)
assert_eq "RECOVERABLE" "$result" "codex: '503' -> RECOVERABLE (generic 5xx)"

result=$(classify_error "ECONNREFUSED" 1 codex)
assert_eq "RECOVERABLE" "$result" "codex: 'ECONNREFUSED' -> RECOVERABLE (generic network)"

# CWD_DELETED left empty for codex: Claude's phrasing must NOT match
result=$(classify_error "current working directory was deleted" 1 codex)
assert_eq "RECOVERABLE" "$result" "codex: Claude's cwd-deleted phrase does NOT match (empty table) -> RECOVERABLE"

# Clean-exit invariant is provider-invariant (#3233 regression guard)
result=$(classify_error "401 Unauthorized" 0 codex)
assert_eq "SUCCESS" "$result" "codex: exit=0 with '401 Unauthorized' in output is still SUCCESS"

result=$(classify_error "rate_limit_exceeded" 0 codex)
assert_eq "SUCCESS" "$result" "codex: exit=0 with 'rate_limit_exceeded' in output is still SUCCESS"

# Provider selection via LOOM_WORKER env (no explicit 3rd arg)
result=$(LOOM_WORKER="codex" classify_error "invalid_api_key" 1)
assert_eq "TOKEN_EXPIRED" "$result" "LOOM_WORKER=codex env selects the codex table"

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

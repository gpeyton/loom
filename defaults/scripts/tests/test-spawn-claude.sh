#!/usr/bin/env bash
# test-spawn-claude.sh — Tests for spawn-claude.sh and classify_error.
#
# Style matches test-forge-helpers.sh — plain bash, hand-rolled assertions.
# Bats is NOT used in this repository.
#
# Usage:
#   ./.loom/scripts/tests/test-spawn-claude.sh

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

# ============================================================
# Section 1: classify_error test vectors (curator's 18 vectors)
# ============================================================

echo "Testing classify_error..."
# Source the library
# shellcheck source=../lib/classify-error.sh
source "$SCRIPTS_DIR/lib/classify-error.sh"

# Vector #1: clean exit with "500" in output → SUCCESS (regression #3233)
result=$(classify_error "successfully merged PR #500 with status 200" 0)
assert_eq "SUCCESS" "$result" "exit=0 output containing '500' is SUCCESS (#3233 regression)"

# Vector #2: clean exit with "rate limit" substring → SUCCESS (regression #3233)
result=$(classify_error "rate limit headers indicate 4500 remaining" 0)
assert_eq "SUCCESS" "$result" "exit=0 with 'rate limit' substring is SUCCESS (#3233 regression)"

# Vector #3: clean exit, "No messages returned" → SUCCESS (regression #3233)
result=$(classify_error "No messages returned in this cycle, exiting" 0)
assert_eq "SUCCESS" "$result" "exit=0 with 'No messages returned' is SUCCESS (#3233 regression)"

# Vector #4: defensive — clean exit even with "500 Internal Server Error"
result=$(classify_error "Internal Server Error 500" 0)
assert_eq "SUCCESS" "$result" "exit=0 with '500 Internal Server Error' is SUCCESS"

# Vector #5: clean exit, empty output
result=$(classify_error "" 0)
assert_eq "SUCCESS" "$result" "exit=0 empty output is SUCCESS"

# Vector #6: timeout exit 124 → TIMEOUT
result=$(classify_error "anything" 124)
assert_eq "TIMEOUT" "$result" "exit=124 is TIMEOUT"

# Vector #7: SIGKILL exit 137 → TIMEOUT
result=$(classify_error "anything" 137)
assert_eq "TIMEOUT" "$result" "exit=137 is TIMEOUT"

# Vector #8: 401 expired → TOKEN_EXPIRED
result=$(classify_error "OAuth token has expired" 1)
assert_eq "TOKEN_EXPIRED" "$result" "OAuth token expired -> TOKEN_EXPIRED"

# Vector #9: 401 authentication_error → TOKEN_EXPIRED
result=$(classify_error "401 authentication_error" 1)
assert_eq "TOKEN_EXPIRED" "$result" "401 authentication_error -> TOKEN_EXPIRED"

# Vector #10: hit your limit → TOKEN_EXHAUSTED
result=$(classify_error "You've hit your limit" 1)
assert_eq "TOKEN_EXHAUSTED" "$result" "hit your limit -> TOKEN_EXHAUSTED"

# Vector #11: weekly limit → TOKEN_EXHAUSTED
result=$(classify_error "hit your weekly limit" 1)
assert_eq "TOKEN_EXHAUSTED" "$result" "weekly limit -> TOKEN_EXHAUSTED"

# Vector #12: 429 → RECOVERABLE
result=$(classify_error "429 Too Many Requests" 1)
assert_eq "RECOVERABLE" "$result" "429 -> RECOVERABLE"

# Vector #13: 500 (with non-zero exit) → RECOVERABLE
result=$(classify_error "500 Internal Server Error" 1)
assert_eq "RECOVERABLE" "$result" "500 + exit=1 -> RECOVERABLE"

# Vector #14: 503 → RECOVERABLE
result=$(classify_error "503 Service Unavailable" 1)
assert_eq "RECOVERABLE" "$result" "503 -> RECOVERABLE"

# Vector #15: ECONNREFUSED → RECOVERABLE
result=$(classify_error "ECONNREFUSED" 1)
assert_eq "RECOVERABLE" "$result" "ECONNREFUSED -> RECOVERABLE"

# Vector #16: No messages returned + exit=1 → RECOVERABLE (only when failed)
result=$(classify_error "No messages returned" 1)
assert_eq "RECOVERABLE" "$result" "'No messages' + exit=1 -> RECOVERABLE"

# Vector #17: cwd deleted → CWD_DELETED
result=$(classify_error "current working directory was deleted" 1)
assert_eq "CWD_DELETED" "$result" "cwd deleted -> CWD_DELETED"

# Vector #18: catch-all unknown failure → RECOVERABLE
result=$(classify_error "" 2)
assert_eq "RECOVERABLE" "$result" "unknown exit=2 -> RECOVERABLE"

# ============================================================
# Section 1b: provider pattern-table selection (issue #3, epic #1)
# ============================================================

echo ""
echo "Testing classify_error provider table selection..."

# Vector #19: explicit "claude" provider param is bit-identical to default
result=$(classify_error "OAuth token has expired" 1 "claude")
assert_eq "TOKEN_EXPIRED" "$result" "explicit provider=claude: OAuth expired -> TOKEN_EXPIRED"

# Vector #20: explicit "claude" provider still honors the #3233 regression
# guard (clean exit is SUCCESS regardless of stdout content or provider).
result=$(classify_error "successfully merged PR #500 with status 200" 0 "claude")
assert_eq "SUCCESS" "$result" "explicit provider=claude: exit=0 with '500' is SUCCESS (#3233 regression)"

# Vector #21: codex is a documented stub — Claude-specific CWD-deleted
# phrasing does NOT match under the codex table (no pattern defined yet),
# so it falls through to the RECOVERABLE catch-all instead of CWD_DELETED.
result=$(classify_error "current working directory was deleted" 1 "codex")
assert_eq "RECOVERABLE" "$result" "provider=codex: Claude's cwd-deleted phrase does not match stub table"

# Vector #22: codex still gets the generic HTTP/network patterns (429).
result=$(classify_error "429 Too Many Requests" 1 "codex")
assert_eq "RECOVERABLE" "$result" "provider=codex: generic 429 pattern still applies"

# Vector #23: unknown/unrecognized provider — Claude's token-expired phrase
# does not match (no provider-specific table), falls to RECOVERABLE.
result=$(classify_error "OAuth token has expired" 1 "some-unknown-provider")
assert_eq "RECOVERABLE" "$result" "unknown provider: no provider-specific pattern for OAuth phrase -> RECOVERABLE"

# Vector #24: unknown provider still gets the generic HTTP/network patterns
# (503) — "defaults to generic HTTP/network patterns" per issue #3 AC.
result=$(classify_error "503 Service Unavailable" 1 "some-unknown-provider")
assert_eq "RECOVERABLE" "$result" "unknown provider: generic 503 pattern still applies"

# Vector #25: exit-code-first / SUCCESS short-circuit is provider-invariant —
# even a nonsense provider name doesn't change exit=0 handling.
result=$(classify_error "rate limit headers indicate 4500 remaining" 0 "some-unknown-provider")
assert_eq "SUCCESS" "$result" "unknown provider: exit=0 with 'rate limit' is still SUCCESS (#3233 regression)"

# Vector #26: LOOM_WORKER env var selects the provider table when no
# explicit 3rd argument is passed.
result=$(LOOM_WORKER="codex" classify_error "current working directory was deleted" 1)
assert_eq "RECOVERABLE" "$result" "LOOM_WORKER=codex env var selects codex table (cwd-deleted phrase does not match)"

# Vector #27: explicit 3rd-arg provider takes precedence over LOOM_WORKER.
result=$(LOOM_WORKER="codex" classify_error "current working directory was deleted" 1 "claude")
assert_eq "CWD_DELETED" "$result" "explicit provider arg overrides LOOM_WORKER env var"

# Vector #28: default provider (no 3rd arg, no LOOM_WORKER set) is "claude".
unset LOOM_WORKER 2>/dev/null || true
result=$(classify_error "hit your weekly limit" 1)
assert_eq "TOKEN_EXHAUSTED" "$result" "no provider arg / no LOOM_WORKER -> defaults to claude table"

# ============================================================
# Section 2: spawn-claude.sh dispatch (with stub `claude`)
# ============================================================

echo ""
echo "Testing spawn-claude.sh dispatch..."

# spawn-claude.sh enforces loom-tools' `requires-python = ">=3.10"` floor
# (issue #72), so the dispatch tests below — which run the REAL
# loom_tools.tokens.select — need a conforming interpreter on this host. Pin it
# via LOOM_PYTHON; the Section 4 tests set their own LOOM_PYTHON explicitly.
# shellcheck source=lib/require-python.sh
source "$SCRIPT_DIR/lib/require-python.sh"
require_python_310 || exit 1
TEST_PYTHON="$LOOM_TEST_PYTHON"
echo "  (using $("$TEST_PYTHON" --version 2>&1) at $TEST_PYTHON)"
export LOOM_PYTHON="$TEST_PYTHON"

# Set up a fake workspace
TEST_WS="$(mktemp -d)"
trap 'rm -rf "$TEST_WS"' EXIT

mkdir -p "$TEST_WS/.loom/tokens"
chmod 700 "$TEST_WS/.loom/tokens"
echo -n "fake-token-alpha" > "$TEST_WS/.loom/tokens/alpha.token"
chmod 600 "$TEST_WS/.loom/tokens/alpha.token"

# Stub `claude` binary
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_WS" "$STUB_DIR"' EXIT
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "stub-claude got token=${CLAUDE_CODE_OAUTH_TOKEN}"
echo "stub-claude args=$*"
exit 0
STUB
chmod +x "$STUB_DIR/claude"

# Test: spawn-claude selects the only token and exec's the stub
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" 2>&1 || true)
assert_contains "stub-claude got token=fake-token-alpha" "$output" \
    "spawn-claude exports selected token to claude"
assert_contains "stub-claude args=-p ping" "$output" \
    "spawn-claude passes args through to claude"
assert_contains "OAuth account 'alpha'" "$output" \
    "spawn-claude logs the chosen account"

# Test: explicit CLAUDE_CODE_OAUTH_TOKEN bypasses selection
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    CLAUDE_CODE_OAUTH_TOKEN="caller-supplied" \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" 2>&1 || true)
assert_contains "stub-claude got token=caller-supplied" "$output" \
    "explicit CLAUDE_CODE_OAUTH_TOKEN is preserved"

# Test: missing tokens dir → exit 78 with helpful message
EMPTY_WS="$(mktemp -d)"
output=$(LOOM_WORKSPACE="$EMPTY_WS" PATH="$STUB_DIR:$PATH" \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" 2>&1 || true)
exit_code=$?
assert_contains "loom-tokens bootstrap" "$output" \
    "empty pool error mentions 'loom-tokens bootstrap'"
rm -rf "$EMPTY_WS"

# Test that spawn-claude.sh exits 78 on missing tokens
set +e
LOOM_WORKSPACE="$(mktemp -d)" PATH="$STUB_DIR:$PATH" \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" >/dev/null 2>&1
exit_code=$?
set -e
assert_eq "78" "$exit_code" "missing tokens exits 78 (EX_CONFIG)"

# ============================================================
# Section 3: model selection (issue #3477, Phase 1)
#
# Precedence chain at the spawn layer, all four observable cases:
#   1. explicit --model arg beats LOOM_MODEL env
#   2. --model=value form also beats LOOM_MODEL env
#   3. LOOM_MODEL alone produces --model in the exec'd args
#   4. no env + no arg produces NO --model at all (session default
#      preserved — the zero-behavior-change acceptance criterion)
# ============================================================

echo ""
echo "Testing spawn-claude.sh model selection (#3477)..."

# Case 3: LOOM_MODEL env produces --model in args
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_MODEL="claude-sonnet-4-6" \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" 2>&1 || true)
assert_contains "stub-claude args=-p ping --model claude-sonnet-4-6" "$output" \
    "LOOM_MODEL env injects --model into claude args"
assert_contains "spawn-claude: model=claude-sonnet-4-6 (from LOOM_MODEL)" "$output" \
    "structured model log line emitted for LOOM_MODEL case (#3482)"

# Case 1: explicit --model arg wins over LOOM_MODEL env
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_MODEL="claude-sonnet-4-6" \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" --model claude-opus-4-8 2>&1 || true)
assert_contains "stub-claude args=-p ping --model claude-opus-4-8" "$output" \
    "explicit --model arg wins over LOOM_MODEL env"
assert_contains "spawn-claude: model=claude-opus-4-8 (from --model arg)" "$output" \
    "structured model log line emitted for explicit --model arg case (#3482)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$output" != *"claude-sonnet-4-6"* ]] || [[ "$output" == *"wins over LOOM_MODEL"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: LOOM_MODEL value is not injected when explicit --model present"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: LOOM_MODEL value is not injected when explicit --model present"
    echo "    In: '$output'"
fi

# Case 2: --model=value form also suppresses LOOM_MODEL injection
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_MODEL="claude-sonnet-4-6" \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" --model=claude-opus-4-8 2>&1 || true)
assert_contains "stub-claude args=-p ping --model=claude-opus-4-8" "$output" \
    "--model=value form wins over LOOM_MODEL env"
assert_contains "spawn-claude: model=claude-opus-4-8 (from --model arg)" "$output" \
    "structured model log line emitted for --model=value form (#3482)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$output" != *"--model claude-sonnet-4-6"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: --model=value suppresses LOOM_MODEL injection"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: --model=value suppresses LOOM_MODEL injection"
    echo "    In: '$output'"
fi

# Case 4 (zero-behavior-change criterion): no env + no arg => no --model
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" 2>&1 || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$output" == *"stub-claude args=-p ping"* && "$output" != *"--model"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: no LOOM_MODEL + no --model arg emits NO --model (session default preserved)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: no LOOM_MODEL + no --model arg emits NO --model (session default preserved)"
    echo "    In: '$output'"
fi
assert_contains "spawn-claude: model=default" "$output" \
    "structured model=default log line emitted when nothing configured (#3482)"

# Empty LOOM_MODEL is treated as unset — no --model emitted
output=$(LOOM_WORKSPACE="$TEST_WS" PATH="$STUB_DIR:$PATH" \
    LOOM_MODEL="" \
    "$SCRIPTS_DIR/spawn-claude.sh" -p "ping" 2>&1 || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$output" == *"stub-claude args=-p ping"* && "$output" != *"--model"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: empty LOOM_MODEL emits NO --model"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: empty LOOM_MODEL emits NO --model"
    echo "    In: '$output'"
fi
assert_contains "spawn-claude: model=default" "$output" \
    "structured model=default log line emitted for empty LOOM_MODEL (#3482)"

# ============================================================
# Section 4: Python interpreter resolution (issue #72)
#
# spawn-claude.sh must NOT run loom_tools under whatever `python3` happens to
# be on PATH — loom-tools declares `requires-python = ">=3.10"` and the engine
# ships a conforming interpreter at <engine>/loom-tools/.venv/bin/python.
# Scenarios covered:
#   4a. engine venv present            -> venv interpreter is used
#   4b. LOOM_PYTHON set                -> override beats venv and PATH
#   4c. no venv + sub-3.10 `python3`   -> fast fail, exit 78, version error
#   4d. no venv + >=3.10 `python3`     -> unchanged behavior (regression guard)
#
# Each scenario runs a COPY of spawn-claude.sh planted inside a synthetic
# engine tree (<fake>/.loom/scripts/spawn-claude.sh) so the script-relative
# engine root — and therefore the venv probe — is fully controlled.
# ============================================================

echo ""
echo "Testing spawn-claude.sh Python interpreter resolution (#72)..."

PYRES_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_WS" "$STUB_DIR" "$PYRES_TMP"' EXIT

# Plant a copy of spawn-claude.sh (plus lib/) in a synthetic engine root.
# Layout mirrors a consumer install: <root>/.loom/scripts/spawn-claude.sh,
# so the script's `<script_dir>/../..` engine probe lands on <root>.
make_fake_engine() {
    local root="$1"
    mkdir -p "$root/.loom/scripts"
    cp "$SCRIPTS_DIR/spawn-claude.sh" "$root/.loom/scripts/spawn-claude.sh"
    cp -R "$SCRIPTS_DIR/lib" "$root/.loom/scripts/lib"
    chmod +x "$root/.loom/scripts/spawn-claude.sh"
}

# Stub interpreter: logs a marker for every invocation, reports <version> for
# `--version`, and exits <c_exit> for the `-c` version assertion (0 = "meets
# the floor", 1 = "too old"). All other invocations exit 0 with empty stdout,
# which makes token selection bottom out in "returned empty key" (exit 78) —
# enough to observe WHICH interpreter ran without needing a real loom_tools.
make_stub_python() {
    local path="$1" version="$2" marker="$3" c_exit="$4"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<STUB
#!/usr/bin/env bash
echo "$marker invoked: \$*" >&2
case "\${1:-}" in
    --version) echo "Python $version"; exit 0 ;;
    -c)        exit $c_exit ;;
esac
exit 0
STUB
    chmod +x "$path"
}

# --- 4a: engine venv is preferred over bare `python3` -------------------
ENGINE_VENV="$PYRES_TMP/engine-with-venv"
make_fake_engine "$ENGINE_VENV"
make_stub_python "$ENGINE_VENV/loom-tools/.venv/bin/python" "3.12.0" "VENV-PYTHON-MARKER" 0

PATH_PY_DIR="$PYRES_TMP/path-python"
make_stub_python "$PATH_PY_DIR/python3" "3.12.0" "PATH-PYTHON-MARKER" 0

output=$(LOOM_PYTHON="" LOOM_WORKSPACE="$TEST_WS" PATH="$PATH_PY_DIR:$STUB_DIR:$PATH" \
    "$ENGINE_VENV/.loom/scripts/spawn-claude.sh" -p "ping" 2>&1 || true)
assert_contains "VENV-PYTHON-MARKER" "$output" \
    "engine venv interpreter is used when present"
assert_contains "python=$ENGINE_VENV/loom-tools/.venv/bin/python (source=engine-venv)" "$output" \
    "resolution log names the venv interpreter with source=engine-venv"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$output" != *"PATH-PYTHON-MARKER"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: bare python3 on PATH is NOT used when the engine venv exists"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: bare python3 on PATH is NOT used when the engine venv exists"
    echo "    In: '$output'"
fi

# --- 4b: LOOM_PYTHON override wins over venv AND PATH -------------------
OVERRIDE_DIR="$PYRES_TMP/override"
make_stub_python "$OVERRIDE_DIR/my-python" "3.13.0" "OVERRIDE-PYTHON-MARKER" 0

output=$(LOOM_PYTHON="$OVERRIDE_DIR/my-python" LOOM_WORKSPACE="$TEST_WS" \
    PATH="$PATH_PY_DIR:$STUB_DIR:$PATH" \
    "$ENGINE_VENV/.loom/scripts/spawn-claude.sh" -p "ping" 2>&1 || true)
assert_contains "OVERRIDE-PYTHON-MARKER" "$output" \
    "LOOM_PYTHON override is used verbatim"
assert_contains "python=$OVERRIDE_DIR/my-python (source=LOOM_PYTHON)" "$output" \
    "resolution log names the override with source=LOOM_PYTHON"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$output" != *"VENV-PYTHON-MARKER"* && "$output" != *"PATH-PYTHON-MARKER"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: LOOM_PYTHON beats both the engine venv and PATH"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: LOOM_PYTHON beats both the engine venv and PATH"
    echo "    In: '$output'"
fi

# --- 4c: no venv + sub-3.10 python3 -> fast fail with exit 78 -----------
ENGINE_BARE="$PYRES_TMP/engine-no-venv"
make_fake_engine "$ENGINE_BARE"

OLD_PY_DIR="$PYRES_TMP/old-python"
make_stub_python "$OLD_PY_DIR/python3" "3.9.7" "OLD-PYTHON-MARKER" 1

output=$(LOOM_PYTHON="" LOOM_WORKSPACE="$TEST_WS" PATH="$OLD_PY_DIR:$STUB_DIR:$PATH" \
    "$ENGINE_BARE/.loom/scripts/spawn-claude.sh" -p "ping" 2>&1 || true)
assert_contains "$OLD_PY_DIR/python3" "$output" \
    "sub-3.10 failure names the offending interpreter path"
assert_contains "Python 3.9.7" "$output" \
    "sub-3.10 failure reports the interpreter's version"
assert_contains "requires >= 3.10" "$output" \
    "sub-3.10 failure states the required floor"
assert_contains "LOOM_PYTHON" "$output" \
    "sub-3.10 failure names the LOOM_PYTHON remedy"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$output" != *"Token selection failed"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: sub-3.10 fails on the version check, not as a token-selection error"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: sub-3.10 fails on the version check, not as a token-selection error"
    echo "    In: '$output'"
fi

set +e
LOOM_PYTHON="" LOOM_WORKSPACE="$TEST_WS" PATH="$OLD_PY_DIR:$STUB_DIR:$PATH" \
    "$ENGINE_BARE/.loom/scripts/spawn-claude.sh" -p "ping" >/dev/null 2>&1
exit_code=$?
set -e
assert_eq "78" "$exit_code" "sub-3.10 interpreter exits 78 (EX_CONFIG)"

# --- 4d: no venv + >=3.10 python3 -> unchanged behavior -----------------
# Real interpreter, real loom_tools, no venv anywhere: token selection must
# still succeed and exec the stub `claude`.
NEW_PY_DIR="$PYRES_TMP/new-python"
mkdir -p "$NEW_PY_DIR"
ln -s "$TEST_PYTHON" "$NEW_PY_DIR/python3"
REPO_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"

output=$(LOOM_PYTHON="" LOOM_WORKSPACE="$TEST_WS" \
    LOOM_PACKAGE_PATH="$REPO_ROOT/loom-tools/src" \
    PATH="$NEW_PY_DIR:$STUB_DIR:$PATH" \
    "$ENGINE_BARE/.loom/scripts/spawn-claude.sh" -p "ping" 2>&1 || true)
assert_contains "python=$NEW_PY_DIR/python3 (source=PATH)" "$output" \
    "no venv + >=3.10 python3 resolves to the PATH interpreter"
assert_contains "stub-claude got token=fake-token-alpha" "$output" \
    "no venv + >=3.10 python3 still selects a token and dispatches (no regression)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$output" != *"requires >= 3.10"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: no version error emitted for a conforming PATH interpreter"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: no version error emitted for a conforming PATH interpreter"
    echo "    In: '$output'"
fi

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

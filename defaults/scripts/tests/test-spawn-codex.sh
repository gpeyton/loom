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
echo "stub-codex codex_home=${CODEX_HOME:-<unset>}"
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

# skip-permissions -> full access (--dangerously-bypass-approvals-and-sandbox)
# by default; Claude flag not forwarded (issue #31, epic #30 Phase 1: default
# inverted so no env vars set now means full autonomy)
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
assert_contains "stub-codex args=exec --dangerously-bypass-approvals-and-sandbox hello" "$output" \
    "no env vars set -> skip-permissions maps to --dangerously-bypass-approvals-and-sandbox by default"
assert_not_contains "--dangerously-skip-permissions" "$(stub_lines "$output")" \
    "the Claude-specific --dangerously-skip-permissions flag is NOT forwarded to codex"
assert_contains "spawn-codex: permissions=danger-full-access approvals=never source=loom-default" "$output" \
    "structured permission log line present, naming source=loom-default"

# LOOM_CODEX_SAFE=1 -> --full-auto (sandboxed opt-out)
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    LOOM_CODEX_SAFE=1 \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
assert_contains "stub-codex args=exec --full-auto hello" "$output" \
    "LOOM_CODEX_SAFE=1 maps skip-permissions to --full-auto"
assert_not_contains "--dangerously-bypass-approvals-and-sandbox" "$(stub_lines "$output")" \
    "sandboxed mode does not also pass the bypass flag"
assert_contains "spawn-codex: permissions=workspace-write approvals=on-request source=LOOM_CODEX_SAFE" "$output" \
    "structured permission log line present, naming source=LOOM_CODEX_SAFE"

# LOOM_CODEX_UNSAFE=1 alone (no LOOM_CODEX_SAFE) -> backward-compatible
# no-op alias for full access, with a deprecation warning; never errors
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    LOOM_CODEX_UNSAFE=1 \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
assert_contains "stub-codex args=exec --dangerously-bypass-approvals-and-sandbox hello" "$output" \
    "LOOM_CODEX_UNSAFE=1 alone behaves identically to the new default (full access)"
assert_contains "LOOM_CODEX_UNSAFE=1 is deprecated" "$output" \
    "LOOM_CODEX_UNSAFE=1 alone prints a deprecation warning pointing at LOOM_CODEX_SAFE=1"

# Both LOOM_CODEX_SAFE=1 and LOOM_CODEX_UNSAFE=1 set -> LOOM_CODEX_SAFE wins
# (full-auto); no deprecation warning needed since UNSAFE is redundant here
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    LOOM_CODEX_SAFE=1 LOOM_CODEX_UNSAFE=1 \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" --dangerously-skip-permissions 2>&1 || true)
assert_contains "stub-codex args=exec --full-auto hello" "$output" \
    "both LOOM_CODEX_SAFE=1 and LOOM_CODEX_UNSAFE=1 set -> LOOM_CODEX_SAFE wins (full-auto)"
assert_not_contains "is deprecated" "$output" \
    "no deprecation warning when LOOM_CODEX_SAFE=1 also set (UNSAFE is redundant but harmless)"

# No skip-permissions -> no permission flag injected (Codex default sandbox)
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
assert_not_contains "--full-auto" "$(stub_lines "$output")" \
    "no skip-permissions -> no --full-auto injected"
assert_not_contains "--dangerously-bypass-approvals-and-sandbox" "$(stub_lines "$output")" \
    "no skip-permissions -> no bypass flag injected"

# LOOM_CODEX_SAFE=1 WITHOUT skip-permissions -> stays gated (no flag)
output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
    LOOM_CODEX_SAFE=1 \
    "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
assert_not_contains "--full-auto" "$(stub_lines "$output")" \
    "LOOM_CODEX_SAFE=1 alone (no skip-permissions) does NOT inject --full-auto"

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
# Section 7: openai pool wiring (issue #12)
# ============================================================

echo ""
echo "Testing openai pool selection..."

# Build a fake workspace with a mixed-provider pool. The provider map lives
# in index.json (as written by `loom-tokens bootstrap`).
POOL_WS="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR" "$POOL_WS"' EXIT
mkdir -p "$POOL_WS/.loom/tokens"
printf 'sk-ant-oat01-aaa' > "$POOL_WS/.loom/tokens/claude-1.token"
printf 'sk-openai-bbb' > "$POOL_WS/.loom/tokens/codex-1.token"
cat > "$POOL_WS/.loom/tokens/index.json" <<'JSON'
{
  "version": 1,
  "accounts": [
    {"name": "claude-1", "file": "claude-1.token", "provider": "anthropic"},
    {"name": "codex-1", "file": "codex-1.token", "provider": "openai"}
  ]
}
JSON

# Point the selector at this repo's loom_tools source explicitly so the test
# does not depend on an installed package.
PKG_PATH="$(cd "$SCRIPTS_DIR/../../loom-tools/src" 2>/dev/null && pwd || echo "")"
if [[ -n "$PKG_PATH" && -d "$PKG_PATH/loom_tools/tokens" ]] \
    && command -v python3 >/dev/null 2>&1; then

    # Pool openai account is selected and exported
    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_WORKSPACE="$POOL_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
    assert_contains "stub-codex openai_key=sk-openai-bbb" "$output" \
        "openai pool account key is exported as OPENAI_API_KEY"
    assert_contains "using openai pool account 'codex-1'" "$output" \
        "pool selection log line names the selected account"

    # Pre-set OPENAI_API_KEY wins over the pool (selection skipped)
    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        OPENAI_API_KEY="sk-preset" \
        LOOM_WORKSPACE="$POOL_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
    assert_contains "stub-codex openai_key=sk-preset" "$output" \
        "pre-set OPENAI_API_KEY wins over pool selection"

    # 401 from codex marks the pool account bad with reason `auth`,
    # and the child's exit code is propagated.
    FAIL_STUB_DIR="$(mktemp -d)"
    cat > "$FAIL_STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
echo "stream error: exceeded retry limit, last status: 401 Unauthorized" >&2
exit 1
STUB
    chmod +x "$FAIL_STUB_DIR/codex"
    set +e
    output=$(PATH="$FAIL_STUB_DIR:$NOCODEX_PATH" \
        LOOM_WORKSPACE="$POOL_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1)
    exit_code=$?
    set -e
    rm -rf "$FAIL_STUB_DIR"
    assert_eq "1" "$exit_code" "codex child exit code is propagated on failure"
    assert_contains "marking bad (reason=auth)" "$output" \
        "401 failure marks the pool account bad with reason auth"
    bad_contents="$(cat "$POOL_WS/.loom/tokens/.bad_tokens" 2>/dev/null || echo "")"
    assert_contains "codex-1 auth" "$bad_contents" \
        ".bad_tokens records 'codex-1 auth'"

    # With codex-1 now bad, the pool has no usable openai account:
    # fall through to ambient auth — NO hard-fail (asymmetry vs spawn-claude)
    set +e
    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_WORKSPACE="$POOL_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1)
    exit_code=$?
    set -e
    assert_eq "0" "$exit_code" \
        "no usable openai account does NOT hard-fail (falls through to ambient auth)"
    assert_contains "stub-codex openai_key=<unset>" "$output" \
        "ambient fallback leaves OPENAI_API_KEY unset"
    assert_contains "relying on Codex CLI ChatGPT login state" "$output" \
        "ambient fallback is logged"

    # Anthropic-only pool: openai selection yields nothing -> ambient fallback
    ANTH_WS="$(mktemp -d)"
    mkdir -p "$ANTH_WS/.loom/tokens"
    printf 'sk-ant-oat01-aaa' > "$ANTH_WS/.loom/tokens/claude-1.token"
    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_WORKSPACE="$ANTH_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
    rm -rf "$ANTH_WS"
    assert_contains "stub-codex openai_key=<unset>" "$output" \
        "anthropic-only pool (no index provider match) leaves OPENAI_API_KEY unset"
else
    echo "  SKIP: python3 or loom-tools source unavailable; pool wiring tests skipped"
fi

# ============================================================
# Section 8: CODEX_HOME profile-pool precedence chain (issue #36)
# ============================================================

echo ""
echo "Testing CODEX_HOME profile precedence chain (issue #36)..."

SECRET_MARKER="sk-super-secret-should-never-appear-in-logs"

if [[ -n "$PKG_PATH" && -d "$PKG_PATH/loom_tools/codex_homes" ]] \
    && command -v python3 >/dev/null 2>&1; then

    HOMES_WS="$(mktemp -d)"
    trap 'rm -rf "$STUB_DIR" "$POOL_WS" "$HOMES_WS"' EXIT

    # --- Tier 2: LOOM_CODEX_HOME explicit pin ---

    PIN_DIR="$HOMES_WS/pinned-profile"
    mkdir -p "$PIN_DIR"
    printf '{"token":"%s"}' "$SECRET_MARKER" > "$PIN_DIR/auth.json"

    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_CODEX_HOME="$PIN_DIR" \
        LOOM_WORKSPACE="$HOMES_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
    assert_contains "stub-codex codex_home=$PIN_DIR" "$output" \
        "LOOM_CODEX_HOME pins CODEX_HOME to the given directory verbatim"
    assert_contains "using pinned Codex profile 'pinned-profile'" "$output" \
        "tier-2 log line names only the profile directory name"
    assert_contains "stub-codex openai_key=<unset>" "$output" \
        "tier-2 selection does not touch OPENAI_API_KEY"
    assert_not_contains "$SECRET_MARKER" "$output" \
        "auth.json contents never appear in spawn-codex output (tier 2)"

    # Missing/unusable LOOM_CODEX_HOME falls through (no LOOM_CODEX_HOMES_DIR
    # or pool configured here) to ambient auth — never fails the spawn.
    BROKEN_PIN_DIR="$HOMES_WS/broken-pinned-profile"
    mkdir -p "$BROKEN_PIN_DIR"  # no auth.json at all
    set +e
    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_CODEX_HOME="$BROKEN_PIN_DIR" \
        LOOM_WORKSPACE="$HOMES_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1)
    exit_code=$?
    set -e
    assert_eq "0" "$exit_code" \
        "a LOOM_CODEX_HOME with no usable auth.json does not fail the spawn"
    assert_contains "has no usable auth.json" "$output" \
        "unusable LOOM_CODEX_HOME pin is logged as a fall-through, not an error"
    assert_contains "stub-codex codex_home=<unset>" "$output" \
        "unusable LOOM_CODEX_HOME leaves CODEX_HOME unset (falls through to ambient)"

    # --- Tier 3: LOOM_CODEX_HOMES_DIR deterministic pool selection ---

    POOL_HOMES_DIR="$HOMES_WS/homes-pool"
    mkdir -p "$POOL_HOMES_DIR/agent-alpha" "$POOL_HOMES_DIR/agent-beta" "$POOL_HOMES_DIR/agent-gamma"
    printf '{"token":"%s"}' "$SECRET_MARKER" > "$POOL_HOMES_DIR/agent-alpha/auth.json"
    printf '{"token":"another-secret"}' > "$POOL_HOMES_DIR/agent-beta/auth.json"
    printf '{"token":"third-secret"}' > "$POOL_HOMES_DIR/agent-gamma/auth.json"

    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_CODEX_HOMES_DIR="$POOL_HOMES_DIR" LOOM_TERMINAL_ID="terminal-fixed-seed" \
        LOOM_WORKSPACE="$HOMES_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
    assert_contains "using pool profile" "$output" \
        "tier-3 pool selection is logged"
    assert_contains "source=pool, seed=terminal-fixed-seed" "$output" \
        "tier-3 log line records the seed used for selection"
    assert_not_contains "$SECRET_MARKER" "$output" \
        "auth.json contents never appear in spawn-codex output (tier 3)"

    # Determinism: same LOOM_TERMINAL_ID + same pool contents -> same pick,
    # across repeated invocations (separate processes each time).
    first_pick=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_CODEX_HOMES_DIR="$POOL_HOMES_DIR" LOOM_TERMINAL_ID="terminal-fixed-seed" \
        LOOM_WORKSPACE="$HOMES_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 \
        | grep -o "stub-codex codex_home=.*" || true)
    second_pick=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_CODEX_HOMES_DIR="$POOL_HOMES_DIR" LOOM_TERMINAL_ID="terminal-fixed-seed" \
        LOOM_WORKSPACE="$HOMES_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 \
        | grep -o "stub-codex codex_home=.*" || true)
    assert_eq "$first_pick" "$second_pick" \
        "same LOOM_TERMINAL_ID + same pool contents selects the same profile across repeated runs"

    # A different seed is not guaranteed to differ (pool of 3 is small), but
    # exercise it to prove the seed is actually consulted (mode=pool, no crash).
    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_CODEX_HOMES_DIR="$POOL_HOMES_DIR" LOOM_TERMINAL_ID="a-totally-different-terminal-id" \
        LOOM_WORKSPACE="$HOMES_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
    assert_contains "using pool profile" "$output" \
        "a different LOOM_TERMINAL_ID still resolves a profile from the same pool"

    # LOOM_SWEEP_ID fallback seed when LOOM_TERMINAL_ID is unset.
    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_CODEX_HOMES_DIR="$POOL_HOMES_DIR" LOOM_SWEEP_ID="sweep-issue-36" \
        LOOM_WORKSPACE="$HOMES_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
    assert_contains "source=pool, seed=sweep-issue-36" "$output" \
        "LOOM_SWEEP_ID is used as the selection seed when LOOM_TERMINAL_ID is unset"

    # No seed available at all (neither LOOM_TERMINAL_ID nor LOOM_SWEEP_ID) ->
    # tier 3 is skipped with a warning, falls through (no pool here -> ambient).
    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_CODEX_HOMES_DIR="$POOL_HOMES_DIR" \
        LOOM_WORKSPACE="$HOMES_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
    assert_contains "cannot select deterministically" "$output" \
        "LOOM_CODEX_HOMES_DIR without any seed falls through with a warning"
    assert_contains "stub-codex codex_home=<unset>" "$output" \
        "no-seed case leaves CODEX_HOME unset (ambient fallback)"

    # Empty / all-unusable pool falls through, never fails the spawn.
    EMPTY_HOMES_DIR="$HOMES_WS/empty-homes-pool"
    mkdir -p "$EMPTY_HOMES_DIR"
    set +e
    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_CODEX_HOMES_DIR="$EMPTY_HOMES_DIR" LOOM_TERMINAL_ID="terminal-x" \
        LOOM_WORKSPACE="$HOMES_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1)
    exit_code=$?
    set -e
    assert_eq "0" "$exit_code" \
        "an empty LOOM_CODEX_HOMES_DIR pool does not fail the spawn"
    assert_contains "no usable Codex profile under LOOM_CODEX_HOMES_DIR" "$output" \
        "empty pool fall-through is logged"
    assert_contains "stub-codex codex_home=<unset>" "$output" \
        "empty pool leaves CODEX_HOME unset (falls through to next tier)"

    # --- Precedence ordering ---

    # Tier 1 (OPENAI_API_KEY) wins outright over tiers 2/3 — CODEX_HOME is
    # never touched at all.
    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        OPENAI_API_KEY="sk-preset-wins" \
        LOOM_CODEX_HOME="$PIN_DIR" LOOM_CODEX_HOMES_DIR="$POOL_HOMES_DIR" LOOM_TERMINAL_ID="terminal-fixed-seed" \
        LOOM_WORKSPACE="$HOMES_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
    assert_contains "stub-codex openai_key=sk-preset-wins" "$output" \
        "tier 1 (pre-set OPENAI_API_KEY) wins over LOOM_CODEX_HOME/LOOM_CODEX_HOMES_DIR"
    assert_contains "stub-codex codex_home=<unset>" "$output" \
        "tier 1 winning means CODEX_HOME is never touched"

    # Tier 2 (LOOM_CODEX_HOME) wins over tier 3 (LOOM_CODEX_HOMES_DIR) when
    # both are set and the pin is usable.
    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_CODEX_HOME="$PIN_DIR" LOOM_CODEX_HOMES_DIR="$POOL_HOMES_DIR" LOOM_TERMINAL_ID="terminal-fixed-seed" \
        LOOM_WORKSPACE="$HOMES_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
    assert_contains "stub-codex codex_home=$PIN_DIR" "$output" \
        "tier 2 (LOOM_CODEX_HOME) wins over tier 3 (LOOM_CODEX_HOMES_DIR) when both are set"
    assert_contains "using pinned Codex profile" "$output" \
        "tier-2 log line present when both LOOM_CODEX_HOME and LOOM_CODEX_HOMES_DIR are set"

    # Tier 3 (CODEX_HOME profile) wins over tier 4 (openai pool) — the pool
    # account is never touched when a profile was already selected.
    if [[ -n "$POOL_WS" && -d "$POOL_WS/.loom/tokens" ]]; then
        output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
            LOOM_CODEX_HOMES_DIR="$POOL_HOMES_DIR" LOOM_TERMINAL_ID="terminal-fixed-seed" \
            LOOM_WORKSPACE="$POOL_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
            "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
        assert_contains "using pool profile" "$output" \
            "tier 3 resolves even though the openai pool (tier 4) also has an account available"
        assert_contains "stub-codex openai_key=<unset>" "$output" \
            "tier 3 winning means the openai pool (tier 4) is never consulted for OPENAI_API_KEY"
        assert_not_contains "using openai pool account" "$output" \
            "tier-4 pool-selection log line does not appear when tier 3 already resolved"
    fi

    # --- LOOM_SPAWN_NO_EXPORT skips the whole chain (tiers 2-4) ---
    output=$(PATH="$STUB_DIR:$NOCODEX_PATH" \
        LOOM_SPAWN_NO_EXPORT=1 \
        LOOM_CODEX_HOME="$PIN_DIR" LOOM_CODEX_HOMES_DIR="$POOL_HOMES_DIR" LOOM_TERMINAL_ID="terminal-fixed-seed" \
        LOOM_WORKSPACE="$HOMES_WS" LOOM_PACKAGE_PATH="$PKG_PATH" \
        "$SCRIPTS_DIR/spawn-codex.sh" -p "hello" 2>&1 || true)
    assert_contains "stub-codex codex_home=<unset>" "$output" \
        "LOOM_SPAWN_NO_EXPORT skips CODEX_HOME profile resolution too"
    assert_contains "stub-codex openai_key=<unset>" "$output" \
        "LOOM_SPAWN_NO_EXPORT skips OPENAI_API_KEY pool resolution"

    rm -rf "$HOMES_WS"
else
    echo "  SKIP: python3 or loom_tools.codex_homes unavailable; CODEX_HOME precedence tests skipped"
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

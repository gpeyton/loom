#!/usr/bin/env bash
# Regression test: installed worker launchers must resolve loom_tools through
# the consumer repository's gitignored .loom/loom-source-path pointer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON_BIN="$(command -v python3)"
TMP_ROOT="$(mktemp -d)"
CONSUMER="$TMP_ROOT/consumer repo"
SOURCE="$TMP_ROOT/loom source"
STUB_BIN="$TMP_ROOT/stubs"
trap 'rm -rf "$TMP_ROOT"' EXIT

TESTS_RUN=0
TESTS_FAILED=0

assert_contains() {
    local needle="$1"
    local haystack="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  PASS: %s\n' "$message"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '  FAIL: %s\n    expected: %s\n    output: %s\n' \
            "$message" "$needle" "$haystack"
    fi
}

mkdir -p \
    "$CONSUMER/.loom/scripts/lib" \
    "$CONSUMER/.loom/tokens" \
    "$SOURCE/loom-tools/src/loom_tools/tokens" \
    "$STUB_BIN"

cp "$SCRIPTS_DIR/spawn-claude.sh" "$CONSUMER/.loom/scripts/"
cp "$SCRIPTS_DIR/spawn-codex.sh" "$CONSUMER/.loom/scripts/"
cp "$SCRIPTS_DIR/lib/classify-error.sh" "$CONSUMER/.loom/scripts/lib/"
chmod +x "$CONSUMER/.loom/scripts/spawn-claude.sh" \
    "$CONSUMER/.loom/scripts/spawn-codex.sh"

printf '%s\n' "$SOURCE" > "$CONSUMER/.loom/loom-source-path"
printf 'unused-by-stub-selector\n' > "$CONSUMER/.loom/tokens/test.token"

cat > "$SOURCE/loom-tools/src/loom_tools/__init__.py" <<'PY'
PY
cat > "$SOURCE/loom-tools/src/loom_tools/tokens/__init__.py" <<'PY'
PY
cat > "$SOURCE/loom-tools/src/loom_tools/tokens/select.py" <<'PY'
import json
import sys

if "--provider" in sys.argv and "openai" in sys.argv:
    payload = {"key": "recorded-openai-key", "name": "recorded-openai", "mode": "test"}
else:
    payload = {"key": "recorded-claude-key", "name": "recorded-claude", "mode": "test"}
print(json.dumps(payload))
PY

cat > "$STUB_BIN/claude" <<'SH'
#!/usr/bin/env bash
printf 'stub-claude token=%s args=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-unset}" "$*"
SH
cat > "$STUB_BIN/codex" <<'SH'
#!/usr/bin/env bash
printf 'stub-codex key=%s args=%s\n' "${OPENAI_API_KEY:-unset}" "$*"
SH
chmod +x "$STUB_BIN/claude" "$STUB_BIN/codex"

printf 'Testing consumer .loom/loom-source-path resolution...\n'

claude_output="$({
    cd "$CONSUMER"
    PATH="$STUB_BIN:/usr/bin:/bin" \
        LOOM_WORKSPACE="$CONSUMER" \
        LOOM_PYTHON="$PYTHON_BIN" \
        ./.loom/scripts/spawn-claude.sh -p "consumer test"
} 2>&1)"
assert_contains "stub-claude token=recorded-claude-key" "$claude_output" \
    "Claude launcher imports loom_tools from the recorded source checkout"

codex_output="$({
    cd "$CONSUMER"
    PATH="$STUB_BIN:/usr/bin:/bin" \
        LOOM_WORKSPACE="$CONSUMER" \
        LOOM_PYTHON="$PYTHON_BIN" \
        ./.loom/scripts/spawn-codex.sh -p "consumer test"
} 2>&1)"
assert_contains "stub-codex key=recorded-openai-key" "$codex_output" \
    "Codex launcher imports loom_tools from the recorded source checkout"

printf '\nTests run: %s\n' "$TESTS_RUN"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
    printf 'Tests failed: %s\n' "$TESTS_FAILED"
    exit 1
fi
printf 'All consumer source-path tests passed.\n'

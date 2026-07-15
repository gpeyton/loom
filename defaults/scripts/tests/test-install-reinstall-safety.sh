#!/usr/bin/env bash
# test-install-reinstall-safety.sh - Regression tests for issue #49
# ("Harden consumer reinstall safety and align setup docs/templates").
#
# Covers the installer-safety findings from a real consumer-repo upgrade:
#   1. --quick / --yes must not silently bypass the destructive-reinstall
#      acknowledgement gate (install.sh).
#   2. Legacy-install detection (is_legacy_rjwalters_install) must trust
#      authoritative install-metadata.json (loom_version / loom_source)
#      over string markers in generated docs -- a modern v0.10.x fork
#      install must not be misclassified as legacy just because generated
#      CLAUDE.md/AGENTS.md mention "rjwalters/loom" in prose (install.sh).
#   3. `scripts/uninstall-loom.sh --local`'s staging step must only stage
#      Loom-managed paths, not unrelated untracked/staged consumer files
#      sitting in the working tree.
#   4. Quick Install must rebuild the loom-daemon binary when the source
#      tree is newer than the binary on disk, not just when it's absent
#      (install.sh).
#
# Hook-dedup semantics (finding 5) is covered by Rust unit tests in
# loom-daemon/src/init/scaffolding.rs
# (test_merge_settings_deduplicates_hooks_with_quoted_paths).
#
# Strategy: functions 1/2/4 are pure and side-effect-free, so they are
# extracted from install.sh via awk (same pattern as
# test-install-source-guard.sh) and exercised in an isolated harness rather
# than running the full installer end-to-end. Finding 3 is tested by
# actually invoking scripts/uninstall-loom.sh --local against a throwaway
# temp git repo.
#
# Usage:
#   bash defaults/scripts/tests/test-install-reinstall-safety.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
UNINSTALL_SH="$REPO_ROOT/scripts/uninstall-loom.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Looking for: '$needle'"
        echo "    In output:"
        echo "$haystack" | sed 's/^/      /'
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Should NOT contain: '$needle'"
    fi
}

assert_zero_exit() {
    local actual="$1" msg="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$actual" -eq 0 ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg (exit=$actual)"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg (expected 0, got $actual)"
    fi
}

assert_nonzero_exit() {
    local actual="$1" msg="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$actual" -ne 0 ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg (exit=$actual)"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg (expected non-zero, got $actual)"
    fi
}

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "ERROR: $INSTALL_SH not found" >&2
    exit 1
fi
if [[ ! -f "$UNINSTALL_SH" ]]; then
    echo "ERROR: $UNINSTALL_SH not found" >&2
    exit 1
fi

# Extract a single top-level function body ("name() {" ... "}") from a file.
extract_function() {
    local func_name="$1" file="$2"
    awk -v fn="${func_name}() {" '
        $0 == fn { capture=1 }
        capture { print }
        capture && /^\}$/ { exit }
    ' "$file"
}

echo "================================================================"
echo "Group 1: is_legacy_rjwalters_install (issue #49 finding 2)"
echo "================================================================"
echo ""

VERSION_GE_FN=$(extract_function "version_ge" "$INSTALL_SH")
LEGACY_FN=$(extract_function "is_legacy_rjwalters_install" "$INSTALL_SH")

if [[ -z "$VERSION_GE_FN" ]]; then
    echo "ERROR: could not extract version_ge() from $INSTALL_SH" >&2
    exit 1
fi
if [[ -z "$LEGACY_FN" ]]; then
    echo "ERROR: could not extract is_legacy_rjwalters_install() from $INSTALL_SH" >&2
    exit 1
fi

if ! command -v node &> /dev/null; then
    echo -e "${YELLOW}SKIP${NC}: node not found -- is_legacy_rjwalters_install requires node to parse install-metadata.json"
else
    HARNESS_FILE=$(mktemp /tmp/loom-legacy-detect-harness.XXXXXX.sh)
    trap 'rm -f "$HARNESS_FILE"' EXIT

    {
        echo '#!/usr/bin/env bash'
        echo 'set -uo pipefail'
        printf '%s\n' "$VERSION_GE_FN"
        printf '%s\n' "$LEGACY_FN"
        echo 'is_legacy_rjwalters_install "$1"'
        echo 'exit $?'
    } > "$HARNESS_FILE"
    chmod +x "$HARNESS_FILE"

    # Case 1 (the bug report, issue #49 finding 2): a modern v0.10.5 fork
    # install whose generated CLAUDE.md still mentions "rjwalters/loom" in
    # prose (upstream attribution), but whose install-metadata.json
    # correctly identifies a v0.10.x install from a non-rjwalters source
    # remote. Must NOT be classified as legacy.
    T1=$(mktemp -d /tmp/loom-legacy-detect-test.XXXXXX)
    SOURCE1="$T1/source-checkout"
    mkdir -p "$T1/target/.loom" "$SOURCE1"
    git -C "$SOURCE1" init --quiet
    git -C "$SOURCE1" remote add origin "https://github.com/gpeyton/loom.git"
    cat > "$T1/target/.loom/install-metadata.json" <<EOF
{
  "loom_version": "0.10.5",
  "loom_commit": "abc1234",
  "install_date": "2026-07-01",
  "loom_source": "$SOURCE1",
  "installed_files": []
}
EOF
    cat > "$T1/target/CLAUDE.md" <<'EOF'
# Some Project

This repository uses [Loom](https://github.com/rjwalters/loom) for orchestration.
See the migration guide for details on moving off rjwalters/loom v0.9.
EOF
    "$HARNESS_FILE" "$T1/target"
    EXIT1=$?
    assert_nonzero_exit "$EXIT1" "Case 1: v0.10.5 fork install with 'rjwalters/loom' prose is NOT legacy (metadata wins)"
    rm -rf "$T1"

    # Case 2: genuine legacy v0.9.x install -- no install-metadata.json (or
    # an old-shape one without loom_version), and CLAUDE.md carries the
    # rjwalters/loom string marker. Must still be classified as legacy
    # (fallback path preserved).
    T2=$(mktemp -d /tmp/loom-legacy-detect-test.XXXXXX)
    mkdir -p "$T2/target/.loom"
    cat > "$T2/target/CLAUDE.md" <<'EOF'
# Loom Orchestration - Repository Guide

This repository uses Loom. See https://github.com/rjwalters/loom for details.
EOF
    "$HARNESS_FILE" "$T2/target"
    EXIT2=$?
    assert_zero_exit "$EXIT2" "Case 2: no metadata + rjwalters/loom string marker IS legacy (fallback preserved)"
    rm -rf "$T2"

    # Case 3: metadata present but source remote resolves to genuine
    # rjwalters/loom -- must be classified as legacy even though loom_version
    # looks modern-shaped (a legacy consumer could have a hand-edited or
    # otherwise inconsistent metadata file; the source remote is decisive
    # once loom_version is absent/unknown).
    T3=$(mktemp -d /tmp/loom-legacy-detect-test.XXXXXX)
    SOURCE3="$T3/source-checkout"
    mkdir -p "$T3/target/.loom" "$SOURCE3"
    git -C "$SOURCE3" init --quiet
    git -C "$SOURCE3" remote add origin "https://github.com/rjwalters/loom.git"
    cat > "$T3/target/.loom/install-metadata.json" <<EOF
{
  "loom_version": "unknown",
  "loom_commit": "unknown",
  "install_date": "2025-01-01",
  "loom_source": "$SOURCE3",
  "installed_files": []
}
EOF
    "$HARNESS_FILE" "$T3/target"
    EXIT3=$?
    assert_zero_exit "$EXIT3" "Case 3: unknown loom_version + rjwalters/loom source remote IS legacy"
    rm -rf "$T3"

    trap - EXIT
    rm -f "$HARNESS_FILE"
fi
echo ""

echo "================================================================"
echo "Group 2: --confirm-reinstall gate (issue #49 finding 1)"
echo "================================================================"
echo ""

# install.sh's dependency-check step (git/node/pnpm/cargo) runs BEFORE the
# reinstall gate this group tests, and prompts interactively if any are
# missing. Rather than risk a false failure (or a hang) on a runner missing
# one of these, skip this group with a clear message when the full
# dependency set isn't available -- Groups 1/3/4 don't need it.
MISSING_FOR_GROUP2=()
for dep in git node pnpm cargo; do
    command -v "$dep" &> /dev/null || MISSING_FOR_GROUP2+=("$dep")
done

if [[ ${#MISSING_FOR_GROUP2[@]} -gt 0 ]]; then
    echo -e "${YELLOW}SKIP${NC}: missing ${MISSING_FOR_GROUP2[*]} -- install.sh's dependency-check step runs before the reinstall gate"
else
    # Build a throwaway "existing install" target: any dir with a .loom/
    # subdirectory is enough to hit the reinstall gate in install.sh, since
    # the gate itself runs before any uninstall/build work happens.
    T4=$(mktemp -d /tmp/loom-confirm-reinstall-test.XXXXXX)
    mkdir -p "$T4/.loom"
    echo "sentinel" > "$T4/.loom/sentinel-marker"
    git -C "$T4" init --quiet 2>/dev/null || true

    # Case 1: --quick without --confirm-reinstall must refuse (non-zero
    # exit), print guidance mentioning --confirm-reinstall, and leave the
    # existing .loom/ untouched (no uninstall attempted). Stdin redirected
    # from /dev/null so any latent interactive prompt fails fast (EOF)
    # instead of hanging.
    OUTPUT4=$("$INSTALL_SH" --quick "$T4" < /dev/null 2>&1)
    EXIT4=$?
    assert_nonzero_exit "$EXIT4" "Case 1: --quick without --confirm-reinstall refuses"
    assert_contains "$OUTPUT4" "--confirm-reinstall" "Case 1: guidance mentions --confirm-reinstall"
    if [[ -f "$T4/.loom/sentinel-marker" ]]; then
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: Case 1: existing .loom/ left untouched (no destructive uninstall ran)"
    else
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: Case 1: existing .loom/ was modified/removed -- gate did not block in time"
    fi

    # Case 2: -y (--yes) without --quick/--confirm-reinstall must ALSO
    # refuse -- -y alone still implies NON_INTERACTIVE=true, so it must hit
    # the same gate (regression guard for "any non-interactive flag
    # combination bypasses the warning", not just --quick specifically).
    OUTPUT5=$("$INSTALL_SH" -y "$T4" < /dev/null 2>&1)
    EXIT5=$?
    assert_nonzero_exit "$EXIT5" "Case 2: -y without --confirm-reinstall refuses"
    assert_contains "$OUTPUT5" "--confirm-reinstall" "Case 2: guidance mentions --confirm-reinstall"

    rm -rf "$T4"
fi
echo ""

echo "================================================================"
echo "Group 3: loom-daemon binary staleness (issue #49 finding 4)"
echo "================================================================"
echo ""

STALE_FN=$(extract_function "loom_daemon_binary_stale" "$INSTALL_SH")
if [[ -z "$STALE_FN" ]]; then
    echo "ERROR: could not extract loom_daemon_binary_stale() from $INSTALL_SH" >&2
    exit 1
fi

HARNESS2=$(mktemp /tmp/loom-stale-binary-harness.XXXXXX.sh)
{
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    printf '%s\n' "$STALE_FN"
    echo 'loom_daemon_binary_stale "$1"'
    echo 'exit $?'
} > "$HARNESS2"
chmod +x "$HARNESS2"

T5=$(mktemp -d /tmp/loom-stale-binary-test.XXXXXX)
mkdir -p "$T5/loom-daemon/src" "$T5/loom-api/src" "$T5/target/release"
echo 'fn main() {}' > "$T5/loom-daemon/src/main.rs"
touch "$T5/Cargo.toml" "$T5/Cargo.lock"

# Case 1: binary absent -> stale.
"$HARNESS2" "$T5"
assert_zero_exit "$?" "Case 1: missing binary is stale"

# Case 2: binary present and newer than all source files -> not stale.
touch "$T5/target/release/loom-daemon"
sleep 1.1
touch "$T5/target/release/loom-daemon"
"$HARNESS2" "$T5"
assert_nonzero_exit "$?" "Case 2: binary newer than source is NOT stale"

# Case 3: source file touched after the binary (simulating `git pull`
# landing a newer commit) -> stale again.
sleep 1.1
echo '// updated' >> "$T5/loom-daemon/src/main.rs"
"$HARNESS2" "$T5"
assert_zero_exit "$?" "Case 3: source newer than binary IS stale (issue #49 finding 4 regression)"

rm -rf "$T5" "$HARNESS2"
echo ""

echo "================================================================"
echo "Group 4: uninstall-loom.sh --local stages only Loom-managed paths"
echo "(issue #49 finding 3)"
echo "================================================================"
echo ""

T6=$(mktemp -d /tmp/loom-uninstall-scope-test.XXXXXX)
git -C "$T6" init --quiet
git -C "$T6" config user.email "test@test.com"
git -C "$T6" config user.name "Test"

# Minimal Loom footprint (heuristic/legacy removal path -- no
# install-metadata.json manifest, so uninstall-loom.sh walks defaults/).
mkdir -p "$T6/.loom/roles" "$T6/.loom/scripts"
echo '{}' > "$T6/.loom/config.json"
cat > "$T6/CLAUDE.md" <<'EOF'
# Loom Orchestration - Repository Guide

Generated by Loom Installation Process
EOF
git -C "$T6" add -A
git -C "$T6" commit -m "Initial commit with Loom installed" --quiet

# Unrelated consumer state that must NOT be touched by the uninstall's
# staging step: an untracked file, a staged-but-uncommitted new file, and a
# modification to an existing tracked (non-Loom) file.
echo "unrelated" > "$T6/unrelated-untracked.txt"
echo "console.log('hi')" > "$T6/app.js"
git -C "$T6" add app.js
echo "console.log('hi'); console.log('modified')" >> "$T6/README.md" 2>/dev/null
echo "# My Project" > "$T6/README.md"
git -C "$T6" add README.md
git -C "$T6" commit -m "Add app.js and README.md" --quiet
echo "# My Project (locally modified, not staged)" >> "$T6/README.md"
echo "another unrelated untracked file" > "$T6/scratch-notes.txt"

"$UNINSTALL_SH" --yes --local "$T6" > /tmp/loom-uninstall-scope-test.log 2>&1
UNINSTALL_EXIT=$?

TESTS_RUN=$((TESTS_RUN + 1))
if [[ $UNINSTALL_EXIT -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: uninstall-loom.sh --local exited 0"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: uninstall-loom.sh --local exited $UNINSTALL_EXIT"
    sed 's/^/    /' /tmp/loom-uninstall-scope-test.log
fi

STAGED_AFTER=$(git -C "$T6" diff --cached --name-only)

# The unrelated untracked files must remain untracked (NOT staged).
assert_not_contains "$STAGED_AFTER" "unrelated-untracked.txt" \
    "unrelated untracked file was not staged by uninstall"
assert_not_contains "$STAGED_AFTER" "scratch-notes.txt" \
    "second unrelated untracked file was not staged by uninstall"

# The locally-modified-but-unstaged README.md change must remain unstaged
# (git add -A would have staged it as part of the "everything" sweep).
README_STAGED_DIFF=$(git -C "$T6" diff --cached -- README.md)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -z "$README_STAGED_DIFF" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: unrelated unstaged README.md edit was not swept into the index"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: unrelated unstaged README.md edit was staged by uninstall"
fi

# Loom-managed removals (e.g. .loom/config.json) SHOULD be staged as
# deletions -- the fix must not become "stage nothing".
assert_contains "$STAGED_AFTER" ".loom/config.json" \
    "Loom-managed file removal WAS staged (fix doesn't over-correct to no-op)"

rm -rf "$T6" /tmp/loom-uninstall-scope-test.log
echo ""

echo "================================================================"
echo "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    exit 1
fi
echo "================================================================"
echo "All tests passed."

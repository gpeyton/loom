#!/usr/bin/env bash
# test-worktree-nested-symlinks.sh — dependency isolation + explicit links (#62, #3528)
#
# Coverage:
#   1. pnpm projects get real root/nested worktree-local node_modules by default.
#   2. pnpm is invoked non-interactively with the frozen lockfile.
#   3. worktree.linkPaths stays an independent explicit symlink.
#   4. worktree.dependencyMode=symlink preserves legacy root/nested links.
#   5. Invalid config and missing jq both fail safe to isolation.
#   6. A failed isolated install warns but does not abort worktree creation.
#   7. Artifact-link processing remains best-effort.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKTREE_SH="$SCRIPTS_DIR/worktree.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo -e "  ${RED}FAIL${NC}: $1"; }

assert_symlink() {
    if [[ -L "$1" ]]; then
        pass "$2"
    else
        fail "$2 (expected symlink: $1)"
    fi
}

assert_real_dir() {
    if [[ -d "$1" && ! -L "$1" ]]; then
        pass "$2"
    else
        fail "$2 (expected real directory: $1)"
    fi
}

assert_not_symlink() {
    if [[ ! -L "$1" ]]; then
        pass "$2"
    else
        fail "$2 (unexpected symlink: $1)"
    fi
}

assert_grep() {
    local pattern="$1" file="$2" message="$3"
    if [[ -f "$file" ]] && grep -qxF "$pattern" "$file"; then
        pass "$message"
    else
        fail "$message (line not found: '$pattern' in $file)"
    fi
}

assert_not_grep() {
    local pattern="$1" file="$2" message="$3"
    if [[ ! -f "$file" ]] || ! grep -qxF "$pattern" "$file"; then
        pass "$message"
    else
        fail "$message (unexpected line: '$pattern' in $file)"
    fi
}

setup_repo() {
    local tmp
    tmp=$(mktemp -d /tmp/loom-wt-deps.XXXXXX)
    git init -q -b main "$tmp/origin.git" --bare
    git init -q -b main "$tmp/repo"
    (
        cd "$tmp/repo"
        git config user.email t@t
        git config user.name t
        git commit --allow-empty -q -m init
        git remote add origin "$tmp/origin.git"
        git push -q origin main
        mkdir -p .loom/scripts/lib .loom/hooks
        cp "$WORKTREE_SH" .loom/scripts/worktree.sh
        if [[ -d "$SCRIPTS_DIR/lib" ]]; then
            cp -R "$SCRIPTS_DIR"/lib/* .loom/scripts/lib/ 2>/dev/null || true
        fi
        chmod +x .loom/scripts/worktree.sh
    )
    echo "$tmp/repo"
}

cleanup_repo() {
    local repo="$1"
    [[ -z "$repo" ]] && return 0
    rm -rf "$(dirname "$repo")"
}

worktree_exclude_path() {
    local worktree="$1"
    (
        cd "$worktree"
        git rev-parse --git-path info/exclude 2>/dev/null |
            while IFS= read -r exclude_path; do
                if [[ "$exclude_path" == /* ]]; then
                    echo "$exclude_path"
                else
                    echo "$worktree/$exclude_path"
                fi
            done
    )
}

install_fake_pnpm() {
    local repo="$1" exit_code="${2:-0}"
    local fake_bin="$repo/.fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/pnpm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "\$PWD/.pnpm-args"
printf '%s\n' "\$PWD" > "\$PWD/.pnpm-cwd"
printf '%s\n' "\${CI:-}" > "\$PWD/.pnpm-ci"
if [[ "$exit_code" -ne 0 ]]; then
    exit "$exit_code"
fi
mkdir -p "\$PWD/node_modules"
printf 'worktree-root\n' > "\$PWD/node_modules/.modules.yaml"
if [[ -f "\$PWD/apps/web/package.json" ]]; then
    mkdir -p "\$PWD/apps/web/node_modules"
    printf 'worktree-nested\n' > "\$PWD/apps/web/node_modules/.modules.yaml"
fi
EOF
    chmod +x "$fake_bin/pnpm"
    echo "$fake_bin"
}

add_pnpm_fixture() {
    local repo="$1"
    (
        cd "$repo"
        mkdir -p apps/web node_modules apps/web/node_modules
        printf '{"name":"root","private":true}\n' > package.json
        printf '{"name":"web"}\n' > apps/web/package.json
        printf 'lockfileVersion: "9.0"\n' > pnpm-lock.yaml
        printf 'node_modules/\n' > .gitignore
        printf 'main-root\n' > node_modules/.modules.yaml
        printf 'main-nested\n' > apps/web/node_modules/.modules.yaml
        git add package.json apps/web/package.json pnpm-lock.yaml .gitignore
        git commit -q -m "add pnpm workspace"
        git push -q origin main
    )
}

echo "Test 1-3: isolated pnpm dependencies + linkPaths + idempotency"
REPO=$(setup_repo)
add_pnpm_fixture "$REPO"
FAKE_BIN=$(install_fake_pnpm "$REPO")
(
    cd "$REPO"
    mkdir -p apps/web/src/wasm
    printf 'generated\n' > apps/web/src/wasm/index.js
    cat > .loom/config.json <<'JSON'
{ "worktree": { "linkPaths": ["apps/web/src/wasm"] } }
JSON
    PATH="$FAKE_BIN:$PATH" ./.loom/scripts/worktree.sh 62 >/tmp/wt-isolated.$$ 2>&1
)
WT="$REPO/.loom/worktrees/issue-62"
assert_real_dir "$WT/node_modules" "root node_modules is a real worktree-local directory"
assert_real_dir "$WT/apps/web/node_modules" "nested node_modules is a real worktree-local directory"
assert_grep "worktree-root" "$WT/node_modules/.modules.yaml" "root install metadata belongs to worktree"
assert_grep "worktree-nested" "$WT/apps/web/node_modules/.modules.yaml" "nested install metadata belongs to worktree"
assert_grep "main-root" "$REPO/node_modules/.modules.yaml" "main root dependency metadata is unchanged"
assert_grep "main-nested" "$REPO/apps/web/node_modules/.modules.yaml" "main nested dependency metadata is unchanged"
assert_grep "install --frozen-lockfile" "$WT/.pnpm-args" "pnpm uses frozen-lockfile install"
assert_grep "$WT" "$WT/.pnpm-cwd" "pnpm runs from the worktree"
assert_grep "true" "$WT/.pnpm-ci" "pnpm runs non-interactively with CI=true"
assert_symlink "$WT/apps/web/src/wasm" "worktree.linkPaths remains an explicit symlink"

EXCLUDE="$(worktree_exclude_path "$WT")"
assert_grep "apps/web/src/wasm" "$EXCLUDE" "exclude records explicit linkPath"
assert_not_grep "node_modules" "$EXCLUDE" "isolated root dependencies are not recorded as links"
assert_not_grep "apps/web/node_modules" "$EXCLUDE" "isolated nested dependencies are not recorded as links"

(
    cd "$REPO"
    PATH="$FAKE_BIN:$PATH" ./.loom/scripts/worktree.sh 62 >/tmp/wt-isolated-reentry.$$ 2>&1
)
LINK_COUNT=$(grep -cxF "apps/web/src/wasm" "$EXCLUDE" 2>/dev/null || echo 0)
if [[ "$LINK_COUNT" == "1" ]]; then
    pass "re-entry does not duplicate explicit linkPath excludes"
else
    fail "re-entry duplicated linkPath exclude (count=$LINK_COUNT)"
fi
cleanup_repo "$REPO"

echo ""
echo "Test 4: explicit compatibility mode preserves legacy root/nested links"
REPO=$(setup_repo)
add_pnpm_fixture "$REPO"
(
    cd "$REPO"
    cat > .loom/config.json <<'JSON'
{ "worktree": { "dependencyMode": "symlink" } }
JSON
    ./.loom/scripts/worktree.sh 63 >/tmp/wt-legacy.$$ 2>&1
)
WT="$REPO/.loom/worktrees/issue-63"
assert_symlink "$WT/node_modules" "legacy mode symlinks root node_modules"
assert_symlink "$WT/apps/web/node_modules" "legacy mode symlinks nested node_modules"
EXCLUDE="$(worktree_exclude_path "$WT")"
assert_grep "node_modules" "$EXCLUDE" "legacy root dependency link is excluded"
assert_grep "apps/web/node_modules" "$EXCLUDE" "legacy nested dependency link is excluded"
cleanup_repo "$REPO"

echo ""
echo "Test 5: invalid dependency mode fails safe to isolated install"
REPO=$(setup_repo)
add_pnpm_fixture "$REPO"
FAKE_BIN=$(install_fake_pnpm "$REPO")
(
    cd "$REPO"
    cat > .loom/config.json <<'JSON'
{ "worktree": { "dependencyMode": "mystery" } }
JSON
    PATH="$FAKE_BIN:$PATH" ./.loom/scripts/worktree.sh 64 >/tmp/wt-invalid.$$ 2>&1
)
WT="$REPO/.loom/worktrees/issue-64"
assert_real_dir "$WT/node_modules" "invalid mode uses isolated root dependencies"
if grep -q "Unknown worktree.dependencyMode 'mystery'; using isolated" /tmp/wt-invalid.$$; then
    pass "invalid dependency mode emits a safe-default warning"
else
    fail "invalid dependency mode did not emit warning"
fi
cleanup_repo "$REPO"

echo ""
echo "Test 6: missing jq cannot activate compatibility mode or linkPaths"
REPO=$(setup_repo)
add_pnpm_fixture "$REPO"
(
    cd "$REPO"
    mkdir -p apps/web/src/wasm
    printf 'generated\n' > apps/web/src/wasm/index.js
    cat > .loom/config.json <<'JSON'
{ "worktree": { "dependencyMode": "symlink", "linkPaths": ["apps/web/src/wasm"] } }
JSON

    SHIM=$(mktemp -d /tmp/loom-nojq.XXXXXX)
    for binary_name in git find dirname basename mkdir ln grep rm mv cp cat sed awk \
                       readlink pwd sort head tail wc tr cut date id sleep chmod \
                       mktemp rmdir touch env bash sh printf test true false ls stat; do
        binary_path="$(command -v "$binary_name" 2>/dev/null || true)"
        [[ -n "$binary_path" ]] && ln -s "$binary_path" "$SHIM/$binary_name" 2>/dev/null || true
    done
    PATH="$SHIM" ./.loom/scripts/worktree.sh 65 >/tmp/wt-nojq.$$ 2>&1
)
WT="$REPO/.loom/worktrees/issue-65"
assert_not_symlink "$WT/node_modules" "missing jq does not enable legacy root dependency link"
assert_not_symlink "$WT/apps/web/node_modules" "missing jq does not enable legacy nested dependency link"
assert_not_symlink "$WT/apps/web/src/wasm" "missing jq skips explicit linkPaths"
cleanup_repo "$REPO"

echo ""
echo "Test 7: failed isolated install warns but worktree creation succeeds"
REPO=$(setup_repo)
add_pnpm_fixture "$REPO"
FAKE_BIN=$(install_fake_pnpm "$REPO" 9)
RC=0
(
    cd "$REPO"
    PATH="$FAKE_BIN:$PATH" ./.loom/scripts/worktree.sh 66 >/tmp/wt-install-fail.$$ 2>&1
) || RC=$?
if [[ "$RC" -eq 0 && -d "$REPO/.loom/worktrees/issue-66" ]]; then
    pass "failed pnpm install leaves a usable worktree"
else
    fail "failed pnpm install aborted worktree creation (exit=$RC)"
fi
if grep -q "Isolated pnpm install failed" /tmp/wt-install-fail.$$; then
    pass "failed pnpm install emits a bounded warning"
else
    fail "failed pnpm install warning missing"
fi
cleanup_repo "$REPO"

echo ""
echo "Test 8: artifact-link processing remains best-effort"
REPO=$(setup_repo)
(
    cd "$REPO"
    printf '{"name":"root"}\n' > package.json
    printf 'node_modules/\n' > .gitignore
    git add package.json .gitignore
    git commit -q -m "add package"
    git push -q origin main
    mkdir -p blocked-artifact
    printf 'x\n' > blocked-artifact/file
    cat > .loom/config.json <<'JSON'
{ "worktree": { "linkPaths": ["blocked-artifact"] } }
JSON
    ./.loom/scripts/worktree.sh 67 >/tmp/wt-artifact.$$ 2>&1
)
WT="$REPO/.loom/worktrees/issue-67"
if [[ -d "$WT" ]]; then
    pass "worktree survives artifact-link processing"
else
    fail "worktree missing after artifact-link processing"
fi
assert_symlink "$WT/blocked-artifact" "configured artifact remains linked"
cleanup_repo "$REPO"

echo ""
echo "Tests run: $TESTS_RUN, Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]] || exit 1

#!/bin/bash
# python-resolve.sh - Shared Python interpreter resolution + version assertion
#                     for the Loom spawn scripts (issue #72).
#
# Why this exists:
#   `loom-tools/pyproject.toml` declares `requires-python = ">=3.10"`, but the
#   spawn scripts used to run `python3 -m loom_tools.tokens.select` under
#   whatever `python3` happened to be on PATH. Because the scripts inject
#   PYTHONPATH directly, the import succeeds under ANY interpreter — including
#   the stock macOS Command Line Tools Python 3.9. That works only by luck:
#   the first `match` statement / PEP 604 union / 3.10-only stdlib call added
#   anywhere in the loom_tools import graph turns every spawn into a
#   SyntaxError that surfaces as an unrelated-looking "Token selection failed".
#
#   Meanwhile the engine ships a correct interpreter at
#   `<engine>/loom-tools/.venv/bin/python` (created by
#   scripts/install/setup-python-tools.sh), which every `~/.local/bin/loom-*`
#   console script already uses via its shebang.
#
# Resolution order (mirrors the PACKAGE_PATH search order in the spawn
# scripts, so the interpreter and the package source come from the same tree):
#   1. $LOOM_PYTHON            — explicit operator override, always wins.
#   2. <engine>/loom-tools/.venv/bin/python, where <engine> is tried as:
#        a. script-relative:      <script_dir>/../..
#        b. recorded source path: <consumer_root>/.loom/loom-source-path
#                                 <workspace>/.loom/loom-source-path
#        c. $workspace
#   3. `python3` on PATH.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/python-resolve.sh"
#   loom_setup_python "<script_dir>" "<workspace>"   # sets PYTHON or exits 78
#
# API:
#   loom_resolve_python <script_dir> [workspace]  -> prints interpreter path
#   loom_assert_python_version <interpreter>      -> 0 ok / 1 too old or broken
#   loom_setup_python <script_dir> [workspace]    -> sets $PYTHON, exits 78 on
#                                                    a sub-3.10 / unusable
#                                                    interpreter (EX_CONFIG)

# Minimum supported Python — keep in sync with loom-tools/pyproject.toml's
# `requires-python`. Deliberately NOT env-overridable: the floor is a property
# of the packaged code, not an operator preference.
LOOM_PYTHON_MIN_MAJOR=3
LOOM_PYTHON_MIN_MINOR=10

# Logging shims: use the caller's log helpers when present (spawn-claude.sh /
# spawn-codex.sh define them), otherwise fall back to plain stderr.
_loom_python_log_info() {
    if declare -F log_info >/dev/null 2>&1; then
        log_info "$@"
    else
        echo "$*" >&2
    fi
}

_loom_python_log_error() {
    if declare -F log_error >/dev/null 2>&1; then
        log_error "$@"
    else
        echo "ERROR $*" >&2
    fi
}

# Print the interpreter that should run loom_tools modules.
# Never fails: always prints something (worst case, bare `python3`).
loom_resolve_python() {
    local script_dir="${1:-}"
    local workspace="${2:-}"

    if [[ -n "${LOOM_PYTHON:-}" ]]; then
        printf '%s\n' "$LOOM_PYTHON"
        return 0
    fi

    local consumer_root=""
    if [[ -n "$script_dir" ]]; then
        consumer_root="$(cd "$script_dir/../.." 2>/dev/null && pwd || echo "")"
    fi

    local roots=()
    [[ -n "$consumer_root" ]] && roots+=("$consumer_root")

    local recorded_file recorded
    for recorded_file in \
        "${consumer_root:+${consumer_root}/.loom/loom-source-path}" \
        "${workspace:+${workspace%/}/.loom/loom-source-path}"; do
        [[ -n "$recorded_file" && -f "$recorded_file" ]] || continue
        recorded="$(<"$recorded_file")"
        [[ -n "$recorded" ]] && roots+=("$recorded")
    done

    [[ -n "$workspace" ]] && roots+=("$workspace")

    local candidate venv_python
    for candidate in ${roots[@]+"${roots[@]}"}; do
        venv_python="${candidate%/}/loom-tools/.venv/bin/python"
        if [[ -x "$venv_python" ]]; then
            printf '%s\n' "$venv_python"
            return 0
        fi
    done

    # Last resort: bare `python3` on PATH. Resolved to an absolute path when
    # possible so a version failure names the offending binary (e.g. the macOS
    # Command Line Tools 3.9) rather than the ambiguous string "python3".
    local path_python
    if path_python="$(command -v python3 2>/dev/null)" && [[ -n "$path_python" ]]; then
        printf '%s\n' "$path_python"
    else
        printf '%s\n' "python3"
    fi
}

# Return 0 when the interpreter exists and is >= the supported floor.
# On failure, emits an operator-actionable error naming the interpreter and
# its version, and returns 1.
loom_assert_python_version() {
    local python="${1:-}"

    if [[ -n "$python" ]] && "$python" -c "import sys; sys.exit(0 if sys.version_info >= (${LOOM_PYTHON_MIN_MAJOR}, ${LOOM_PYTHON_MIN_MINOR}) else 1)" 2>/dev/null; then
        return 0
    fi

    local version=""
    if [[ -n "$python" ]]; then
        version="$("$python" --version 2>&1 || true)"
    fi
    [[ -n "$version" ]] || version="not found or not executable"

    _loom_python_log_error \
        "Python interpreter '${python:-<unset>}' is ${version}, but loom-tools requires >= ${LOOM_PYTHON_MIN_MAJOR}.${LOOM_PYTHON_MIN_MINOR}."
    _loom_python_log_error \
        "Fix: run 'scripts/install/setup-python-tools.sh' in the Loom engine checkout to create"
    _loom_python_log_error \
        "<engine>/loom-tools/.venv, or set LOOM_PYTHON to a >= ${LOOM_PYTHON_MIN_MAJOR}.${LOOM_PYTHON_MIN_MINOR} interpreter explicitly."
    return 1
}

# Resolve + assert once, exporting the result as $PYTHON. Exits 78 (EX_CONFIG,
# matching the spawn scripts' missing-token-pool convention) when the resolved
# interpreter is unusable. Idempotent: repeated calls are no-ops.
loom_setup_python() {
    local script_dir="${1:-}"
    local workspace="${2:-}"

    if [[ -n "${_LOOM_PYTHON_SETUP_DONE:-}" ]]; then
        return 0
    fi

    PYTHON="$(loom_resolve_python "$script_dir" "$workspace")"

    if ! loom_assert_python_version "$PYTHON"; then
        exit 78  # EX_CONFIG
    fi

    local source_label="PATH"
    if [[ -n "${LOOM_PYTHON:-}" ]]; then
        source_label="LOOM_PYTHON"
    elif [[ "$PYTHON" == */loom-tools/.venv/bin/python ]]; then
        source_label="engine-venv"
    fi
    # Tag the line with the calling script (spawn-claude / spawn-codex) to
    # match their existing `spawn-<runtime>: key=value` log convention.
    local tag="${0##*/}"
    tag="${tag%.sh}"
    _loom_python_log_info "${tag}: python=$PYTHON (source=$source_label)"

    _LOOM_PYTHON_SETUP_DONE=1
    return 0
}

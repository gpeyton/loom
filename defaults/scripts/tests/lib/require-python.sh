#!/bin/bash
# require-python.sh - Test helper: locate a Python >= 3.10 for suites that
#                     exercise the spawn scripts' loom_tools call paths.
#
# `loom-tools/pyproject.toml` declares `requires-python = ">=3.10"` and the
# spawn scripts enforce that floor at spawn time (issue #72), so any suite
# that drives real token / profile selection needs a conforming interpreter —
# a host whose bare `python3` is, say, the macOS Command Line Tools 3.9 would
# otherwise see every spawn fail with EX_CONFIG.
#
# Usage:
#   # shellcheck source=lib/require-python.sh
#   source "$SCRIPT_DIR/lib/require-python.sh"
#   require_python_310 || exit 1
#   export LOOM_PYTHON="$LOOM_TEST_PYTHON"
#
# Search order mirrors scripts/install/setup-python-tools.sh.

require_python_310() {
    local py
    for py in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
        if command -v "$py" >/dev/null 2>&1 &&
            "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
            LOOM_TEST_PYTHON="$(command -v "$py")"
            export LOOM_TEST_PYTHON
            return 0
        fi
    done

    echo "ERROR: no Python >= 3.10 found on PATH." >&2
    echo "  loom-tools declares requires-python = \">=3.10\" and the spawn" >&2
    echo "  scripts enforce it (issue #72). Install a conforming interpreter," >&2
    echo "  or run scripts/install/setup-python-tools.sh, before running this" >&2
    echo "  suite." >&2
    return 1
}

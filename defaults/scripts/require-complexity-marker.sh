#!/usr/bin/env bash
# require-complexity-marker.sh - Gate: an issue may not be marked curated
# without a complexity tier.
#
# The tier drives every downstream model choice, so an unclassified issue
# silently costs either quality (cheap model on money/security work) or money
# (frontier model on a file split). Making this a command the Curator MUST pass
# turns "please remember" into a check that fails loudly.
#
#   require-complexity-marker.sh <issue>     # exit 0 = has a valid tier
#                                            # exit 1 = missing/invalid
set -uo pipefail

ISSUE="${1:-}"
[[ -n "$ISSUE" ]] || { echo "usage: require-complexity-marker.sh <issue> [repo]" >&2; exit 2; }

# Resolve the repo explicitly. A bare `gh issue view` targets the default
# remote, which is wrong wherever `origin` is not where the issues live (a
# fork checkout, most obviously) — it looks up a same-numbered issue in
# another repository and reports whatever that one says.
REPO="${2:-${LOOM_REPO:-}}"
if [[ -z "$REPO" ]]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo" >&2; exit 2; }
  # shellcheck source=/dev/null
  source "$ROOT/.loom/scripts/lib/forge-helpers.sh" 2>/dev/null || true
  if declare -F forge_get_repo_nwo >/dev/null; then
    REPO="$(forge_get_repo_nwo gh 2>/dev/null || true)"
  fi
fi
[[ -n "$REPO" ]] || { echo "could not determine repo; pass it explicitly or set LOOM_REPO" >&2; exit 2; }

body="$(gh issue view "$ISSUE" -R "$REPO" --json body -q .body 2>/dev/null || true)"
tier="$(printf '%s' "$body" | grep -o 'loom:complexity=[a-z]*' | head -1 | cut -d= -f2)"

case "$tier" in
  mechanical|routine|complex)
    echo "ok: $REPO#$ISSUE is tagged $tier"
    ;;
  "")
    cat >&2 <<EOF
BLOCKED: $REPO#$ISSUE has no complexity marker.

Add exactly one of these to the issue body before applying loom:curated:

  <!-- loom:complexity=mechanical -->   a mistake is obvious on reading it
  <!-- loom:complexity=routine -->      mistake would surface in tests/review
  <!-- loom:complexity=complex -->      mistake could pass tests and review unseen

Torn between two? Take the higher one.
EOF
    exit 1
    ;;
  *)
    echo "BLOCKED: issue $ISSUE has an invalid tier '$tier' (expected mechanical|routine|complex)" >&2
    exit 1
    ;;
esac

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
[[ -n "$ISSUE" ]] || { echo "usage: require-complexity-marker.sh <issue>" >&2; exit 2; }

body="$(gh issue view "$ISSUE" --json body -q .body 2>/dev/null || true)"
tier="$(printf '%s' "$body" | grep -o 'loom:complexity=[a-z]*' | head -1 | cut -d= -f2)"

case "$tier" in
  mechanical|routine|complex)
    echo "ok: issue $ISSUE is tagged $tier"
    ;;
  "")
    cat >&2 <<EOF
BLOCKED: issue $ISSUE has no complexity marker.

Add exactly one of these to the issue body before applying loom:curated:

  <!-- loom:complexity=mechanical -->   verifiable by tests/inspection
  <!-- loom:complexity=routine -->      normal work, contained blast radius
  <!-- loom:complexity=complex -->      needs real design judgement, or wrong is costly

Torn between two? Take the higher one.
EOF
    exit 1
    ;;
  *)
    echo "BLOCKED: issue $ISSUE has an invalid tier '$tier' (expected mechanical|routine|complex)" >&2
    exit 1
    ;;
esac

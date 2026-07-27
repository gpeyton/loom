#!/usr/bin/env bash
# resolve-tier-model.sh - Print the model an issue's work must run on.
#
# Turns the Curator's runtime-neutral tier into a concrete model id, so the
# dispatch path does a lookup instead of a judgement call. Reading a document
# and "resolving" a model in your head is how model selection silently drifts;
# this makes the resolution a command whose output is either used or visibly
# absent.
#
#   resolve-tier-model.sh <issue> [runtime]     # runtime defaults to claude
#
# Resolution:
#   1. Read `<!-- loom:complexity=... -->` from the issue body. Missing or
#      unrecognised => routine (the safe middle).
#   2. Look up sweep.tierModels[<runtime>][<tier>] in .loom/config.json.
#      No entry for the runtime => print nothing, exit 3, so the caller falls
#      through to its normal chain instead of guessing a model.
#   3. Pass the result through resolve-model.sh so logical tiers become the
#      current generation rather than a stale alias.
#
# Prints ONLY the model id on stdout; diagnostics go to stderr.
set -uo pipefail

ISSUE="${1:-}"
RUNTIME="${2:-claude}"
[[ -n "$ISSUE" ]] || { echo "usage: resolve-tier-model.sh <issue> [runtime]" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo" >&2; exit 2; }
CONFIG="$ROOT/.loom/config.json"

body="$(gh issue view "$ISSUE" --json body -q .body 2>/dev/null || true)"
tier="$(printf '%s' "$body" | grep -o 'loom:complexity=[a-z]*' | head -1 | cut -d= -f2)"
case "$tier" in
  mechanical|routine|complex) ;;
  *) echo "issue $ISSUE: no valid complexity marker -> routine" >&2; tier="routine" ;;
esac

model="$(CONFIG="$CONFIG" RUNTIME="$RUNTIME" TIER="$tier" python3 - <<'PY'
import json, os
try:
    cfg = json.load(open(os.environ["CONFIG"]))
except Exception:
    raise SystemExit(3)
tiers = (cfg.get("sweep") or {}).get("tierModels") or {}
m = (tiers.get(os.environ["RUNTIME"]) or {}).get(os.environ["TIER"])
if not m:
    raise SystemExit(3)
print(m)
PY
)" || { echo "no tierModels entry for runtime=$RUNTIME tier=$tier — falling through" >&2; exit 3; }

resolver="$ROOT/.loom/scripts/resolve-model.sh"
if [[ -x "$resolver" ]]; then
  resolved="$("$resolver" "$model" 2>/dev/null)" && [[ -n "$resolved" ]] && model="$resolved"
fi

echo "resolve-tier-model: issue=$ISSUE runtime=$RUNTIME tier=$tier model=$model" >&2
printf '%s\n' "$model"

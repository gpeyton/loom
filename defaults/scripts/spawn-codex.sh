#!/usr/bin/env bash
# spawn-codex.sh - Runner for the OpenAI Codex CLI (issue #10, Phase 2 of
# epic #1: dual-runtime Claude + Codex worker support).
#
# This is the Codex sibling of spawn-claude.sh. spawn-worker.sh execs this
# script (with all passthrough args untouched) when the resolved worker type
# is "codex". It translates Loom's runner-neutral spawn contract into a
# concrete `codex` invocation.
#
# ---------------------------------------------------------------------------
# Minimum supported Codex CLI version: 0.125.0
#
#   Flag names were verified against OpenAI's Codex CLI reference
#   (developers.openai.com/codex, July 2026) and the 0.125.0 Homebrew cask
#   present on the build host. The Codex CLI surface churns between releases;
#   if a future Codex renames or removes any of the flags below, bump this
#   pin and re-verify against `codex exec --help`:
#     - `codex exec "<prompt>"`                       (non-interactive run)
#     - `-m <model>` / `--model <model>`              (model selection)
#     - `--full-auto`                                 (auto-approve, sandboxed)
#     - `--dangerously-bypass-approvals-and-sandbox`  (drop every guard)
# ---------------------------------------------------------------------------
#
# Runner contract (mirrors the five items spawn-worker.sh documents for every
# runner):
#   (a) binary name: codex
#   (b) auth env var: OPENAI_API_KEY (honored if pre-set); otherwise the
#       Codex CLI's own ChatGPT login state is used. See "Auth" below.
#   (c) prompt flag shape: the dispatcher's `-p "<prompt>"` (also `--prompt`)
#       is translated to a positional argument of the `exec` subcommand:
#       `codex exec "<prompt>"`. No `-p`: falls through to interactive `codex`.
#   (d) model flag shape: `-m <value>` / `--model <value>`. LOOM_MODEL is
#       injected as `-m <value>` unless an explicit model flag is already
#       present (mirrors spawn-claude.sh's LOOM_MODEL -> --model precedence).
#   (e) skip-permissions flag shape: Loom's convention flag
#       `--dangerously-skip-permissions` (the Claude runner's spelling) is
#       NOT understood by codex, so it is consumed here and translated to a
#       Codex permission flag (see "Permissions mapping" below).
#
# Auth (rotation is Claude-only for now):
#   This runner does NOT consult the `.loom/tokens/` pool. Provider-aware pool
#   selection is issue G's scope (a separate Phase 2 issue; another agent is
#   wiring it). Until that lands, token rotation is Claude-only: spawn-codex.sh
#   honors a pre-set OPENAI_API_KEY in the environment, and otherwise relies on
#   whatever ChatGPT login state the Codex CLI already holds (`codex login`).
#
# Permissions mapping (SAFETY-CRITICAL — do not weaken):
#   Loom automation always spawns agents with the skip-permissions convention
#   (`--dangerously-skip-permissions` for Claude). Codex must never run with
#   FEWER guards than Claude, so that convention maps to:
#     - default:                  `--full-auto`
#                                 (auto-approves actions, keeps the sandbox)
#     - LOOM_CODEX_UNSAFE=1 only:  `--dangerously-bypass-approvals-and-sandbox`
#                                 (drops the sandbox AND approvals — reserved
#                                  for fully isolated runners)
#   The bypass-everything flag is gated behind BOTH the skip-permissions
#   convention being present AND an explicit `LOOM_CODEX_UNSAFE=1` opt-in.
#   When no skip-permissions flag is passed, NO permission flag is injected
#   and Codex uses its own default (sandboxed, approval-gated) mode — more
#   guards, never fewer.
#
# Behavior on missing binary:
#   When `codex` is not on PATH, exits 78 (EX_CONFIG) with an install hint,
#   matching spawn-worker.sh's / spawn-claude.sh's EX_CONFIG convention for
#   configuration errors.
#
# Usage:
#   .loom/scripts/spawn-codex.sh -p "your prompt"
#   .loom/scripts/spawn-codex.sh -p "your prompt" --dangerously-skip-permissions
#   LOOM_MODEL=gpt-5-codex .loom/scripts/spawn-codex.sh -p "your prompt"
#   .loom/scripts/spawn-codex.sh            # interactive (bare `codex`)
#
# Env vars:
#   LOOM_MODEL          Model to pass as `codex -m <value>`. Lowest priority:
#                       an explicit `-m`/`--model` in the passthrough args
#                       always wins. When neither is set, NO model flag is
#                       emitted and the Codex CLI default is preserved.
#   LOOM_CODEX_UNSAFE   When set to 1, the skip-permissions convention maps to
#                       `--dangerously-bypass-approvals-and-sandbox` instead of
#                       `--full-auto`. Off by default.
#   OPENAI_API_KEY      Honored if pre-set (exported to the codex child).
#   LOOM_CODEX_NO_EXEC  Test/CI hook: when set, print the resolved argv the
#                       script WOULD exec (prefixed `spawn-codex would-exec:`)
#                       and exit 0 instead of exec'ing codex. Does not change
#                       production behavior.

set -euo pipefail

# --- Logging helpers (match spawn-claude.sh / spawn-worker.sh convention) ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] WARN${NC} $*" >&2; }
log_error() { echo -e "${RED}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR${NC} $*" >&2; }

# --- Argument parsing ---
# We split the incoming dispatcher args into buckets:
#   PROMPT            the prompt text extracted from -p/--prompt (exec mode)
#   PASSTHROUGH_ARGS  every other flag, forwarded to codex untouched
# and record two booleans (skip-permissions requested, explicit model present).
PROMPT=""
HAS_PROMPT=false
SKIP_PERMISSIONS=false
HAS_MODEL_ARG=false
PASSTHROUGH_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prompt)
            if [[ $# -lt 2 ]]; then
                log_error "$1 requires a value"
                exit 78  # EX_CONFIG
            fi
            PROMPT="$2"
            HAS_PROMPT=true
            shift 2
            ;;
        -p=*)
            PROMPT="${1#-p=}"
            HAS_PROMPT=true
            shift
            ;;
        --prompt=*)
            PROMPT="${1#--prompt=}"
            HAS_PROMPT=true
            shift
            ;;
        --dangerously-skip-permissions)
            # Loom's runner-neutral skip-permissions convention. Consumed here
            # (codex does not understand this Claude-specific flag) and mapped
            # to a Codex permission flag below.
            SKIP_PERMISSIONS=true
            shift
            ;;
        -m|--model)
            HAS_MODEL_ARG=true
            PASSTHROUGH_ARGS+=("$1")
            if [[ $# -ge 2 ]]; then
                PASSTHROUGH_ARGS+=("$2")
                shift 2
            else
                shift
            fi
            ;;
        -m=*|--model=*)
            HAS_MODEL_ARG=true
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
        --help|-h)
            # macOS-safe: `sed '$d'` (delete last line) instead of the GNU-only
            # `head -n -1`, matching spawn-worker.sh's help renderer.
            sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' \
                | sed '$d'
            exit 0
            ;;
        --)
            shift
            PASSTHROUGH_ARGS+=("$@")
            break
            ;;
        *)
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
    esac
done

# --- Model selection (mirrors spawn-claude.sh #3477 precedence) ---
# Precedence: explicit -m/--model in the passthrough args > LOOM_MODEL env >
# nothing (Codex CLI default — no model flag emitted at all). Exactly one
# structured `spawn-codex: model=<value>` line is emitted per spawn.
if [[ "$HAS_MODEL_ARG" == "true" ]]; then
    if [[ -n "${LOOM_MODEL:-}" ]]; then
        log_info "spawn-codex: explicit -m/--model in args wins over LOOM_MODEL='$LOOM_MODEL'"
    fi
    log_info "spawn-codex: model=explicit (from -m/--model arg)"
elif [[ -n "${LOOM_MODEL:-}" ]]; then
    PASSTHROUGH_ARGS+=(-m "$LOOM_MODEL")
    log_info "spawn-codex: model=$LOOM_MODEL (from LOOM_MODEL)"
else
    log_info "spawn-codex: model=default"
fi

# --- Permissions mapping (SAFETY-CRITICAL, see header) ---
# The skip-permissions convention maps to --full-auto by default, or to the
# bypass-everything flag ONLY when LOOM_CODEX_UNSAFE=1 is explicitly set.
PERMISSION_FLAG=""
if [[ "$SKIP_PERMISSIONS" == "true" ]]; then
    if [[ "${LOOM_CODEX_UNSAFE:-}" == "1" ]]; then
        PERMISSION_FLAG="--dangerously-bypass-approvals-and-sandbox"
        log_warn "spawn-codex: LOOM_CODEX_UNSAFE=1 — using $PERMISSION_FLAG (sandbox AND approvals dropped)"
    else
        PERMISSION_FLAG="--full-auto"
        log_info "spawn-codex: skip-permissions -> $PERMISSION_FLAG"
    fi
elif [[ "${LOOM_CODEX_UNSAFE:-}" == "1" ]]; then
    # UNSAFE requested but no skip-permissions convention present: the bypass
    # flag stays gated behind BOTH conditions, so nothing is injected. Warn so
    # the operator knows the opt-in had no effect.
    log_warn "spawn-codex: LOOM_CODEX_UNSAFE=1 set but no --dangerously-skip-permissions passed; no permission flag injected"
fi

# --- Auth (rotation is Claude-only for now; see header) ---
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    log_info "spawn-codex: using pre-set OPENAI_API_KEY"
else
    log_info "spawn-codex: no OPENAI_API_KEY set — relying on Codex CLI ChatGPT login state"
fi

# --- Binary check ---
if ! command -v codex >/dev/null 2>&1; then
    log_error "'codex' command not found in PATH."
    log_error "Install the OpenAI Codex CLI: npm install -g @openai/codex"
    exit 78  # EX_CONFIG
fi

# --- Assemble the codex invocation ---
# Non-interactive (prompt present): `codex exec [flags] "<prompt>"`.
# Interactive (no prompt):          `codex [flags]`.
# In both cases model/permission/passthrough flags precede the positional
# prompt (matching `codex exec --full-auto "<prompt>"` from the CLI docs).
CODEX_ARGS=()
if [[ "$HAS_PROMPT" == "true" ]]; then
    CODEX_ARGS+=(exec)
fi
if [[ -n "$PERMISSION_FLAG" ]]; then
    CODEX_ARGS+=("$PERMISSION_FLAG")
fi
CODEX_ARGS+=(${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"})
if [[ "$HAS_PROMPT" == "true" ]]; then
    CODEX_ARGS+=("$PROMPT")
fi

# --- Dispatch ---
if [[ -n "${LOOM_CODEX_NO_EXEC:-}" ]]; then
    # Test/CI hook: surface the resolved argv without exec'ing codex.
    echo "spawn-codex would-exec: codex ${CODEX_ARGS[*]}"
    exit 0
fi

exec codex ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"}

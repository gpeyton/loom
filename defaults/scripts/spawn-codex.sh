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
# Auth (provider-aware pool selection, issue #12):
#   Precedence, highest first:
#     1. Pre-set OPENAI_API_KEY in the environment (always honored, never
#        overwritten; selection is skipped entirely).
#     2. `.loom/tokens/` pool: `python3 -m loom_tools.tokens.select
#        --provider openai` picks an openai account (per-account provider is
#        recorded in index.json by `loom-tokens bootstrap`). The selected key
#        is exported as OPENAI_API_KEY.
#     3. Ambient auth: whatever ChatGPT login state the Codex CLI already
#        holds (`codex login`).
#
#   ASYMMETRY vs spawn-claude.sh (intentional, do not "fix"): when the pool
#   is absent, has no openai accounts, or every openai account is bad,
#   spawn-codex.sh falls through to ambient auth (tier 3) instead of
#   hard-failing. spawn-claude.sh exits 78 (EX_CONFIG) in the equivalent
#   situation because Claude rotation is the documented load-bearing auth
#   path; for Codex the pool is OPTIONAL — API-key accounts only (there is
#   no public multi-account token-file mechanism for ChatGPT-plan OAuth),
#   with `codex login` as the expected fallback.
#
#   Bad-token reporting: when a pool-selected key is in use in
#   non-interactive (-p) mode, codex output is captured and classified via
#   lib/classify-error.sh (provider table: codex). TOKEN_EXPIRED marks the
#   account bad with reason `auth` (persists until `loom-tokens unblock`);
#   TOKEN_EXHAUSTED marks it with reason `exhausted` (TTL-expires). This
#   mirrors the reason strings the Claude flow's bad-token tracking uses.
#
# Permissions mapping (SAFETY-CRITICAL — do not weaken; inverted in #31,
# epic #30 Phase 1 — full autonomy is now the default):
#   Loom automation always spawns agents with the skip-permissions convention
#   (`--dangerously-skip-permissions` for Claude), and that convention now
#   maps Codex to full autonomy by default — the same "no approvals needed"
#   posture Claude gets from `--dangerously-skip-permissions`:
#     - default:                    `--dangerously-bypass-approvals-and-sandbox`
#                                   (drops the sandbox AND approvals; matches
#                                    Loom's skip-permissions convention)
#     - LOOM_CODEX_SAFE=1 opt-out:   `--full-auto`
#                                   (restores the sandboxed, workspace-write,
#                                    approval-on-request behavior that used to
#                                    be the default)
#   Precedence when both LOOM_CODEX_SAFE=1 and LOOM_CODEX_UNSAFE=1 are set:
#   LOOM_CODEX_SAFE=1 ALWAYS WINS — safe is the more conservative choice, so
#   it takes priority regardless of ordering or of LOOM_CODEX_UNSAFE.
#   LOOM_CODEX_UNSAFE=1 is kept as a backward-compatible NO-OP ALIAS for full
#   access for one transition release: setting it alone behaves identically
#   to the new default (full access) and prints a deprecation warning
#   pointing at LOOM_CODEX_SAFE=1. It never errors and is never required for
#   autonomy.
#   Exactly one structured `spawn-codex: permissions=... source=...` log line
#   is emitted per launch so operators can grep spawn logs for the effective
#   posture.
#   When no skip-permissions flag is passed, NO permission flag is injected
#   and Codex uses its own default (sandboxed, approval-gated) mode — this
#   part is unchanged.
#
#   Full trust-boundary rationale (why full autonomy is the default, and
#   what LOOM_CODEX_SAFE=1 restores): see `.codex/GUARDRAIL-PARITY.md`.
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
#   LOOM_CODEX_SAFE     When set to 1, the skip-permissions convention maps to
#                       `--full-auto` (sandboxed) instead of the full-access
#                       default. Off by default (full access is the default).
#   LOOM_CODEX_UNSAFE   DEPRECATED no-op alias for full access (the new
#                       default). Setting it alone has no effect beyond a
#                       deprecation warning pointing at LOOM_CODEX_SAFE=1.
#                       If LOOM_CODEX_SAFE=1 is also set, LOOM_CODEX_SAFE
#                       wins. Off by default. Kept for one transition
#                       release.
#   OPENAI_API_KEY      Honored if pre-set (exported to the codex child);
#                       pool selection is skipped when set.
#   LOOM_WORKSPACE      Override repo root detection (pool lookup).
#   LOOM_SPAWN_NO_EXPORT If set, skip pool selection entirely (matches
#                       spawn-claude.sh's contract).
#   LOOM_PYTHON         Override the python interpreter (default: python3).
#   LOOM_PACKAGE_PATH   Override the loom_tools package source path.
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
# The skip-permissions convention now maps to full autonomy by default
# (--dangerously-bypass-approvals-and-sandbox), matching Claude's
# --dangerously-skip-permissions convention. LOOM_CODEX_SAFE=1 is the
# opt-out that restores the sandboxed --full-auto behavior. LOOM_CODEX_UNSAFE
# is a backward-compatible no-op alias for full access (deprecated, warns,
# never errors); LOOM_CODEX_SAFE=1 always wins if both are set.
PERMISSION_FLAG=""
if [[ "$SKIP_PERMISSIONS" == "true" ]]; then
    if [[ "${LOOM_CODEX_UNSAFE:-}" == "1" && "${LOOM_CODEX_SAFE:-}" != "1" ]]; then
        log_warn "spawn-codex: LOOM_CODEX_UNSAFE=1 is deprecated — full access is now the loom-default; use LOOM_CODEX_SAFE=1 instead to opt into the sandboxed --full-auto behavior"
    fi
    if [[ "${LOOM_CODEX_SAFE:-}" == "1" ]]; then
        PERMISSION_FLAG="--full-auto"
        log_info "spawn-codex: permissions=workspace-write approvals=on-request source=LOOM_CODEX_SAFE"
    else
        PERMISSION_FLAG="--dangerously-bypass-approvals-and-sandbox"
        log_info "spawn-codex: permissions=danger-full-access approvals=never source=loom-default"
    fi
elif [[ "${LOOM_CODEX_SAFE:-}" == "1" || "${LOOM_CODEX_UNSAFE:-}" == "1" ]]; then
    # LOOM_CODEX_SAFE / LOOM_CODEX_UNSAFE requested but no skip-permissions
    # convention present: neither has any effect without
    # --dangerously-skip-permissions. Warn so the operator knows the env var
    # had no effect (mirrors the previous LOOM_CODEX_UNSAFE-only gate).
    if [[ "${LOOM_CODEX_UNSAFE:-}" == "1" && "${LOOM_CODEX_SAFE:-}" != "1" ]]; then
        log_warn "spawn-codex: LOOM_CODEX_UNSAFE=1 is deprecated — use LOOM_CODEX_SAFE=1 instead"
    fi
    log_warn "spawn-codex: LOOM_CODEX_SAFE/LOOM_CODEX_UNSAFE set but no --dangerously-skip-permissions passed; no permission flag injected"
fi

# --- Repo root resolution (handles worktrees; mirrors spawn-claude.sh) ---
_resolve_workspace() {
    if [[ -n "${LOOM_WORKSPACE:-}" ]]; then
        printf '%s\n' "$LOOM_WORKSPACE"
        return
    fi

    local git_common_dir
    if git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"; then
        if [[ ! "$git_common_dir" = /* ]]; then
            git_common_dir="$(cd "$git_common_dir" && pwd)"
        fi
        printf '%s\n' "$(dirname "$git_common_dir")"
        return
    fi

    # Fallback: relative to this script
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

# --- Auth (provider-aware pool selection, issue #12; see header) ---
# Selected-account bookkeeping for bad-token reporting below. Empty when no
# pool token is in play (pre-set key or ambient auth).
POOL_ACCOUNT_NAME=""
WORKSPACE=""
PYTHON="${LOOM_PYTHON:-python3}"
PACKAGE_PATH=""

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    log_info "spawn-codex: using pre-set OPENAI_API_KEY"
elif [[ -n "${LOOM_SPAWN_NO_EXPORT:-}" ]]; then
    log_info "spawn-codex: LOOM_SPAWN_NO_EXPORT set — skipping pool selection"
else
    WORKSPACE="$(_resolve_workspace)"

    # Locate loom_tools package source (mirrors spawn-claude.sh's search
    # order: env override > script-relative > workspace-relative).
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _script_relative_pkg="$(cd "$_script_dir/../../loom-tools/src" 2>/dev/null && pwd || echo "")"
    PACKAGE_PATH="${LOOM_PACKAGE_PATH:-$_script_relative_pkg}"
    if [[ -z "$PACKAGE_PATH" || ! -d "$PACKAGE_PATH/loom_tools/tokens" ]]; then
        PACKAGE_PATH="${WORKSPACE}/loom-tools/src"
    fi

    # Try the openai side of the pool. Unlike spawn-claude.sh this NEVER
    # hard-fails (no EX_CONFIG): the pool is optional for Codex, and any
    # selection failure (no pool, no openai accounts, all bad, python
    # missing) falls through to ambient auth. See the header for why this
    # asymmetry is intentional.
    _selection_json=""
    if _selection_json="$(
        PYTHONPATH="${PACKAGE_PATH}${PYTHONPATH:+:$PYTHONPATH}" \
        "$PYTHON" -m loom_tools.tokens.select \
            --workspace "$WORKSPACE" --provider openai --json \
        2>/dev/null
    )"; then
        _token="$(
            printf '%s' "$_selection_json" \
            | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["key"])' \
            2>/dev/null || echo ""
        )"
        _name="$(
            printf '%s' "$_selection_json" \
            | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["name"])' \
            2>/dev/null || echo ""
        )"
        _mode="$(
            printf '%s' "$_selection_json" \
            | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["mode"])' \
            2>/dev/null || echo ""
        )"
        if [[ -n "$_token" ]]; then
            export OPENAI_API_KEY="$_token"
            POOL_ACCOUNT_NAME="$_name"
            log_info "spawn-codex: using openai pool account '$_name' (mode=$_mode)"
        else
            log_warn "spawn-codex: pool selection returned empty key — falling back to ambient Codex auth"
        fi
    else
        log_info "spawn-codex: no usable openai account in .loom/tokens/ — relying on Codex CLI ChatGPT login state"
    fi
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

# Bad-token reporting path (issue #12): when a pool-selected account is in
# use for a non-interactive run, do NOT exec — run codex as a child with
# output tee'd (same technique as claude-wrapper.sh's no-TTY path), classify
# the failure via lib/classify-error.sh's codex table, and mark the account
# bad with the existing reason strings:
#     TOKEN_EXPIRED   -> reason `auth`      (persists until loom-tokens unblock)
#     TOKEN_EXHAUSTED -> reason `exhausted` (TTL-expires)
# Interactive runs (an operator at the keyboard) keep the plain exec.
if [[ -n "$POOL_ACCOUNT_NAME" && "$HAS_PROMPT" == "true" ]]; then
    _classify_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/classify-error.sh"
    _temp_output="$(mktemp)"
    set +e
    codex ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"} 2>&1 | tee "$_temp_output"
    _exit_code=${PIPESTATUS[0]}
    set -e

    if [[ "$_exit_code" -ne 0 && -f "$_classify_lib" ]]; then
        # shellcheck source=lib/classify-error.sh
        source "$_classify_lib"
        _out_tail="$(tail -c 20000 "$_temp_output" 2>/dev/null || echo "")"
        _category="$(classify_error "$_out_tail" "$_exit_code" codex)"
        _reason=""
        case "$_category" in
            TOKEN_EXPIRED) _reason="auth" ;;
            TOKEN_EXHAUSTED) _reason="exhausted" ;;
        esac
        if [[ -n "$_reason" ]]; then
            log_warn "spawn-codex: $_category on account '$POOL_ACCOUNT_NAME' — marking bad (reason=$_reason)"
            PYTHONPATH="${PACKAGE_PATH}${PYTHONPATH:+:$PYTHONPATH}" \
                "$PYTHON" - "$WORKSPACE" "$POOL_ACCOUNT_NAME" "$_reason" <<'PY' || true
import sys
from pathlib import Path
try:
    from loom_tools.tokens.bad_tokens import mark_bad
    mark_bad(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
except Exception as exc:  # noqa: BLE001 — reporting must never mask the exit
    print(f"[spawn-codex] mark_bad failed: {exc!r}", file=sys.stderr)
PY
        fi
    fi
    rm -f "$_temp_output"
    exit "$_exit_code"
fi

exec codex ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"}

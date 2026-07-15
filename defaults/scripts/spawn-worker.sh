#!/usr/bin/env bash
# spawn-worker.sh - Worker-runner dispatcher (issue #2, Phase 1 of epic #1).
#
# Loom historically hardcoded the `claude` binary as the only spawn target.
# This script introduces a worker-runner abstraction: a worker type resolves
# to a runner script, with `claude` (via spawn-claude.sh) as the implicit
# default so existing installs see zero behavior change.
#
# Worker type resolution (highest precedence first):
#   1. --worker <type>   (or --worker=<type>; consumed here, NOT passed through)
#   2. LOOM_WORKER env var
#   3. Default: "claude"
#
# Supported runners today:
#   claude  -> spawn-claude.sh (this directory)
#   codex   -> spawn-codex.sh  (this directory; issue #10, Phase 2 of epic #1)
#
# Runner contract:
#   Every runner script that implements a worker type for this dispatcher
#   MUST document these five things in its own header comment, so a new
#   runner (e.g. a future spawn-codex.sh) can be added without re-deriving
#   the contract from scratch:
#     (a) binary name                  - the underlying CLI binary it execs
#                                         (e.g. `claude`).
#     (b) auth env var                 - the env var used to inject
#                                         credentials (e.g.
#                                         CLAUDE_CODE_OAUTH_TOKEN).
#     (c) prompt flag shape            - how a prompt is passed
#                                         (e.g. `-p "<prompt>"`).
#     (d) model flag shape             - how a model override is passed
#                                         (e.g. `--model <value>`).
#     (e) skip-permissions flag shape  - how the "skip permission prompts"
#                                         flag is passed
#                                         (e.g. `--dangerously-skip-permissions`).
#
#   spawn-claude.sh's contract (today's only runner):
#     (a) binary name: claude
#     (b) auth env var: CLAUDE_CODE_OAUTH_TOKEN
#     (c) prompt flag shape: -p "<prompt>"
#     (d) model flag shape: --model <value> (also LOOM_MODEL env; see
#         spawn-claude.sh's own header for the full precedence chain)
#     (e) skip-permissions flag shape: --dangerously-skip-permissions
#         (passed through untouched -- spawn-claude.sh does not add or
#         require it, callers supply it as part of the passthrough args)
#
#   spawn-codex.sh's contract (issue #10, Phase 2 of epic #1):
#     (a) binary name: codex
#     (b) auth env var: OPENAI_API_KEY (honored if pre-set; otherwise the
#         Codex CLI's own ChatGPT login state is used -- the .loom/tokens/
#         rotation pool is Claude-only until issue G lands)
#     (c) prompt flag shape: -p "<prompt>" is translated to the positional
#         argument of `codex exec "<prompt>"`; no -p falls through to the
#         interactive `codex` TUI
#     (d) model flag shape: -m <value> / --model <value> (also LOOM_MODEL env;
#         see spawn-codex.sh's own header for the precedence chain)
#     (e) skip-permissions flag shape: --dangerously-skip-permissions is
#         consumed by spawn-codex.sh and mapped to a Codex permission flag
#         (--full-auto by default; --dangerously-bypass-approvals-and-sandbox
#         only behind LOOM_CODEX_UNSAFE=1) -- codex does not understand the
#         Claude spelling, so it is not passed through verbatim
#
# Behavior on unknown worker type:
#   Exits 78 (EX_CONFIG) with a clear message, matching the existing
#   spawn-claude.sh EX_CONFIG convention for configuration errors.
#
# Usage:
#   .loom/scripts/spawn-worker.sh -p "your prompt"
#   .loom/scripts/spawn-worker.sh --worker claude -p "your prompt"
#   LOOM_WORKER=claude .loom/scripts/spawn-worker.sh -p "your prompt"
#
# Env vars:
#   LOOM_WORKER   Worker type to resolve (default: "claude"). Overridden by
#                 an explicit --worker <type> / --worker=<type> argument.
#
# All other arguments (including -p, --model, --dangerously-skip-permissions,
# --use-wrapper, etc.) are passed through untouched to the resolved runner.

set -euo pipefail

# --- Logging helpers (match spawn-claude.sh convention) ---
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')]${NC} $*" >&2; }
log_error() { echo -e "${RED}[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR${NC} $*" >&2; }

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Argument parsing: extract --worker/--worker=<v>, pass everything else through ---
WORKER_TYPE="${LOOM_WORKER:-claude}"
PASSTHROUGH_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --worker)
            if [[ $# -lt 2 ]]; then
                log_error "--worker requires a value"
                exit 78  # EX_CONFIG
            fi
            WORKER_TYPE="$2"
            shift 2
            ;;
        --worker=*)
            WORKER_TYPE="${1#--worker=}"
            shift
            ;;
        --help|-h)
            # Note: uses `sed '$d'` (delete last line) rather than
            # `head -n -1` -- the latter is a GNU coreutils extension and
            # errors on BSD/macOS `head`.
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

if [[ -z "$WORKER_TYPE" ]]; then
    WORKER_TYPE="claude"
fi

log_info "spawn-worker: resolving worker type '$WORKER_TYPE'"

case "$WORKER_TYPE" in
    claude)
        _runner="${_script_dir}/spawn-claude.sh"
        if [[ ! -x "$_runner" ]]; then
            log_error "Cannot find executable spawn-claude.sh at $_runner"
            exit 1
        fi
        exec "$_runner" ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}
        ;;
    codex)
        _runner="${_script_dir}/spawn-codex.sh"
        if [[ ! -x "$_runner" ]]; then
            log_error "Cannot find executable spawn-codex.sh at $_runner"
            exit 1
        fi
        exec "$_runner" ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}
        ;;
    *)
        log_error "Unknown worker type: '$WORKER_TYPE'"
        log_error "Supported worker types: claude, codex"
        exit 78  # EX_CONFIG
        ;;
esac

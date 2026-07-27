#!/bin/bash

# sweep-checkpoint.sh - Manage per-issue phase checkpoints for /loom:sweep resume.
#
# This script provides read/write/delete operations on sweep checkpoint files:
#   .loom/sweep-checkpoint/issue-<N>.json
#
# The sweep skill calls this helper at each phase boundary to record progress.
# On re-entry (after a kill, OS reboot, or token exhaustion), the sweep skill
# reads the checkpoint for each issue and skips already-completed phases per
# the skip rules documented in defaults/.claude/commands/loom/sweep.md.
#
# Checkpoint file format (atomic write via .tmp + mv):
#   {
#     "phase": "<curator-done|builder-done|judge-done|doctor-done|merge-done>",
#     "task_id": "<stable per-sweep-run id>",
#     "phase": "<curator-done|builder-done|judge-rejected|judge-done|doctor-done|merge-done>",
#     "task_id": "<task identifier, e.g. sweep PID>",
#     "timestamp": "<ISO 8601 UTC>",
#     "pr_number": <int or null>,
#     "attempt": <int, optional - omitted when not provided; absent means attempt 1>,
#     "model": "<string, optional - omitted when not provided; absent means default/unknown>"
#   }
#
# The "task_id" field (#3768) identifies the sweep RUN that wrote the checkpoint.
# It must be a STABLE per-sweep-run id (generated once at sweep start — see
# sweep-run-registry.sh), NOT the PID of a Bash subshell. The historical
# `sweep-$$` default was the wrong mental model: `$$` is re-evaluated per Bash
# tool call within a single sweep, so it could not distinguish one sweep's
# checkpoints from a concurrent peer sweep's. Callers (defaults/.claude/commands/
# loom/sweep.md) now pass a stable `--task-id "$RUN_ID"`; the field is free-form,
# so legacy checkpoints carrying a `sweep-<pid>` task_id still parse cleanly.
#
# The "attempt" field (#3481) is forward-compat bookkeeping for model
# escalation: attempt 1 is the first Builder pass, attempt 2 is the Doctor
# dispatched after a Judge rejection. Readers MUST tolerate checkpoints
# without the field (legacy checkpoints predate it) and treat absence as
# attempt 1. The v1 escalation decision derives from the
# loom:changes-requested label/phase, not this counter.
#
# The "model" field (#3482, Phase 3a observability) records the model the
# orchestrator resolved for the phase's subagent (alias like "sonnet"/"opus"
# or a pinned ID like "claude-sonnet-4-6"). Observability only — it never
# feeds back into model selection. Readers MUST tolerate checkpoints without
# the field (legacy checkpoints predate it) and treat absence as
# default/unknown.
#
# Phases are recorded *after* successful completion of the corresponding
# lifecycle phase, so "curator-done" means the curator phase succeeded for
# this issue and the next sweep should skip it.
# `judge-rejected` records a successful request-changes verdict and requires
# `--pr-number`; a resumed sweep uses that durable routing key to enter the
# single Doctor→Judge cycle without repeating the initial Judge pass.
#
# On merge-done, callers should invoke `delete` to remove the checkpoint —
# stale-checkpoint detection (closed issue + leftover checkpoint) is performed
# inline by the sweep skill (see defaults/.claude/commands/loom/sweep.md), not
# by this helper, and the next sweep entry will clean it up with a warning.
#
# Usage:
#   sweep-checkpoint.sh write <issue> <phase> [--task-id ID] [--pr-number N] [--attempt N] [--model M]
#   sweep-checkpoint.sh read <issue>
#   sweep-checkpoint.sh delete <issue>
#   sweep-checkpoint.sh phase <issue>          # Print phase string only (or empty)
#   sweep-checkpoint.sh attempt <issue>        # Print attempt number (empty if absent = attempt 1)
#   sweep-checkpoint.sh model <issue>          # Print model string (empty if absent = default/unknown)
#   sweep-checkpoint.sh exists <issue>         # Exit 0 if checkpoint exists, 1 otherwise
#   sweep-checkpoint.sh list                   # List all checkpoint issue numbers
#
# Exit codes:
#   0 - success
#   1 - usage / not found
#   2 - invalid phase
#   3 - I/O error

set -euo pipefail

VALID_PHASES=(curator-done builder-done judge-rejected judge-done doctor-done merge-done)

usage() {
    sed -n '3,55p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

# Resolve the main workspace root from both the main checkout and linked
# worktrees. `--show-toplevel` is worktree-local, while `--git-common-dir`
# points at the main checkout's .git directory from every linked worktree.
repo_root() {
    local common abs_common
    common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    if [[ -z "$common" ]]; then
        pwd
        return
    fi

    abs_common="$(cd "$common" 2>/dev/null && pwd -P)" || {
        pwd
        return
    }
    dirname "$abs_common"
}

checkpoint_dir() {
    echo "$(repo_root)/.loom/sweep-checkpoint"
}

checkpoint_file() {
    local issue="$1"
    echo "$(checkpoint_dir)/issue-${issue}.json"
}

ensure_dir() {
    mkdir -p "$(checkpoint_dir)"
}

checkpoint_timestamp() {
    local checkpoint="$1"
    sed -n 's/.*"timestamp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$checkpoint" | head -n1
}

valid_checkpoint_timestamp() {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

install_checkpoint_atomically() {
    local source="$1" target="$2"
    local tmp="${target}.migrate.tmp.$$"

    if cp "$source" "$tmp" && mv "$tmp" "$target"; then
        if ! rm -f "$source"; then
            echo "WARNING: migrated legacy sweep checkpoint to $target but could not remove $source" >&2
        fi
        return 0
    fi

    rm -f "$tmp"
    echo "WARNING: could not migrate legacy sweep checkpoint $source to $target; leaving it in place" >&2
    return 1
}

# Older versions resolved the checkpoint directory with `--show-toplevel`, so
# writes issued from a linked worktree could strand newer phase state inside
# that worktree. Reconcile those legacy files on every helper entry: the newest
# ISO-8601 timestamp wins, while malformed conflicts remain in place with a
# loud warning instead of being silently ignored.
reconcile_legacy_checkpoints() {
    local main_root canonical_dir listed_worktree worktree_root legacy_dir
    main_root="$(repo_root)"
    canonical_dir="$main_root/.loom/sweep-checkpoint"
    mkdir -p "$canonical_dir"

    while IFS= read -r listed_worktree; do
        worktree_root="$(cd "$listed_worktree" 2>/dev/null && pwd -P)" || continue
        [[ -n "$worktree_root" && "$worktree_root" != "$main_root" ]] || continue
        legacy_dir="$worktree_root/.loom/sweep-checkpoint"
        [[ -d "$legacy_dir" ]] || continue

        local legacy_file issue target legacy_ts canonical_ts
        for legacy_file in "$legacy_dir"/issue-*.json; do
            [[ -f "$legacy_file" ]] || continue
            issue="${legacy_file##*/issue-}"
            issue="${issue%.json}"
            [[ "$issue" =~ ^[0-9]+$ ]] || continue
            target="$canonical_dir/issue-${issue}.json"

            if [[ ! -f "$target" ]]; then
                if install_checkpoint_atomically "$legacy_file" "$target"; then
                    echo "WARNING: migrated legacy worktree sweep checkpoint $legacy_file to $target" >&2
                fi
                continue
            fi

            legacy_ts="$(checkpoint_timestamp "$legacy_file")"
            canonical_ts="$(checkpoint_timestamp "$target")"
            if ! valid_checkpoint_timestamp "$legacy_ts" || ! valid_checkpoint_timestamp "$canonical_ts"; then
                echo "WARNING: conflicting sweep checkpoints for issue #$issue have missing or malformed timestamps; keeping both for manual reconciliation: $target and $legacy_file" >&2
                continue
            fi

            if [[ "$legacy_ts" > "$canonical_ts" ]]; then
                if install_checkpoint_atomically "$legacy_file" "$target"; then
                    echo "WARNING: promoted newer legacy worktree sweep checkpoint for issue #$issue ($legacy_ts > $canonical_ts): $target" >&2
                fi
            else
                if rm -f "$legacy_file"; then
                    echo "WARNING: removed older legacy worktree sweep checkpoint for issue #$issue ($legacy_ts <= $canonical_ts): $legacy_file" >&2
                else
                    echo "WARNING: canonical sweep checkpoint is newer for issue #$issue, but could not remove legacy file $legacy_file" >&2
                fi
            fi
        done
    done < <(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
}

validate_issue() {
    local issue="$1"
    if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
        echo "ERROR: issue must be a positive integer (got: '$issue')" >&2
        exit 1
    fi
}

validate_phase() {
    local phase="$1"
    for valid in "${VALID_PHASES[@]}"; do
        [[ "$phase" == "$valid" ]] && return 0
    done
    echo "ERROR: invalid phase '$phase'. Valid: ${VALID_PHASES[*]}" >&2
    exit 2
}

iso_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

cmd_write() {
    local issue="${1:-}" phase="${2:-}"
    shift 2 || true
    validate_issue "$issue"
    validate_phase "$phase"

    local task_id="" pr_number="null" attempt="" model=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task-id) task_id="${2:-}"; shift 2 ;;
            --pr-number) pr_number="${2:-null}"; shift 2 ;;
            --attempt) attempt="${2:-}"; shift 2 ;;
            --model) model="${2:-}"; shift 2 ;;
            *) echo "ERROR: unknown flag '$1'" >&2; exit 1 ;;
        esac
    done

    # Last-resort fallback ONLY: sweep.md always passes a stable --task-id "$RUN_ID"
    # (see sweep-run-registry.sh). This default exists so a bare/manual write still
    # produces a parseable checkpoint; `sweep-run-$$` is deliberately labelled a
    # fallback rather than masquerading as a stable per-run id.
    [[ -z "$task_id" ]] && task_id="sweep-run-fallback-$$"
    if [[ "$pr_number" != "null" && ! "$pr_number" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --pr-number must be a positive integer or 'null'" >&2
        exit 1
    fi
    if [[ "$phase" == "judge-rejected" && "$pr_number" == "null" ]]; then
        echo "ERROR: judge-rejected requires --pr-number for resume routing" >&2
        exit 1
    fi
    if [[ -n "$attempt" && ! "$attempt" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: --attempt must be a positive integer >= 1 (got: '$attempt')" >&2
        exit 1
    fi
    # Model values are aliases (sonnet/opus/haiku) or pinned IDs
    # (claude-sonnet-4-6). Restrict the charset so the value embeds safely
    # in the hand-rolled JSON below (no quotes/backslashes/control chars).
    if [[ -n "$model" && ! "$model" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "ERROR: --model must match [A-Za-z0-9._-]+ (got: '$model')" >&2
        exit 1
    fi

    # Optional fields: omitted entirely when not provided so legacy readers
    # (and diffs against old checkpoints) stay clean.
    local attempt_json=""
    [[ -n "$attempt" ]] && attempt_json=$',\n  "attempt": '"$attempt"
    local model_json=""
    [[ -n "$model" ]] && model_json=$',\n  "model": "'"$model"'"'

    ensure_dir
    local target tmp
    target="$(checkpoint_file "$issue")"
    tmp="${target}.tmp.$$"

    cat > "$tmp" <<EOF
{
  "phase": "$phase",
  "task_id": "$task_id",
  "timestamp": "$(iso_now)",
  "pr_number": $pr_number$attempt_json$model_json
}
EOF

    mv "$tmp" "$target"
    echo "wrote $target (phase=$phase)"
}

cmd_read() {
    local issue="${1:-}"
    validate_issue "$issue"
    local target
    target="$(checkpoint_file "$issue")"
    if [[ ! -f "$target" ]]; then
        return 1
    fi
    cat "$target"
}

cmd_phase() {
    local issue="${1:-}"
    validate_issue "$issue"
    local target
    target="$(checkpoint_file "$issue")"
    [[ ! -f "$target" ]] && return 0
    # Extract phase via grep+sed to avoid jq dependency.
    sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$target" | head -n1
}

cmd_attempt() {
    local issue="${1:-}"
    validate_issue "$issue"
    local target
    target="$(checkpoint_file "$issue")"
    [[ ! -f "$target" ]] && return 0
    # Empty output means the field is absent (legacy checkpoint) = attempt 1.
    sed -n 's/.*"attempt"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$target" | head -n1
}

cmd_model() {
    local issue="${1:-}"
    validate_issue "$issue"
    local target
    target="$(checkpoint_file "$issue")"
    [[ ! -f "$target" ]] && return 0
    # Empty output means the field is absent (legacy checkpoint) =
    # default/unknown model. Mirrors cmd_attempt semantics (#3482).
    sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$target" | head -n1
}

cmd_exists() {
    local issue="${1:-}"
    validate_issue "$issue"
    [[ -f "$(checkpoint_file "$issue")" ]]
}

cmd_delete() {
    local issue="${1:-}"
    validate_issue "$issue"
    local target
    target="$(checkpoint_file "$issue")"
    if [[ -f "$target" ]]; then
        rm -f "$target"
        echo "deleted $target"
    fi
}

cmd_list() {
    local dir
    dir="$(checkpoint_dir)"
    [[ ! -d "$dir" ]] && return 0
    find "$dir" -maxdepth 1 -name 'issue-*.json' -type f 2>/dev/null \
        | sed -E 's|.*/issue-([0-9]+)\.json$|\1|' \
        | sort -n
}

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        write|read|phase|attempt|model|exists|delete|list)
            reconcile_legacy_checkpoints
            ;;
    esac
    case "$cmd" in
        write)   cmd_write "$@" ;;
        read)    cmd_read "$@" ;;
        phase)   cmd_phase "$@" ;;
        attempt) cmd_attempt "$@" ;;
        model)   cmd_model "$@" ;;
        exists)  cmd_exists "$@" ;;
        delete)  cmd_delete "$@" ;;
        list)    cmd_list "$@" ;;
        -h|--help|"") usage ;;
        *) echo "ERROR: unknown command '$cmd'" >&2; usage ;;
    esac
}

main "$@"

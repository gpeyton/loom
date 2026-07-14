#!/usr/bin/env bash
# classify-error.sh — Classify a (output, exit_code) pair into an error category.
#
# Source this file (do not exec). Defines:
#
#   classify_error <output> <exit_code> [provider] -> echoes one of:
#       SUCCESS         — exit 0 (regardless of output content)
#       TIMEOUT         — exit 124/137 (productive cycle, not a failure)
#       CWD_DELETED     — working directory was removed
#       TOKEN_EXPIRED   — 401 / OAuth token expired (skip this token)
#       TOKEN_EXHAUSTED — quota/weekly limit hit (rotate)
#       RECOVERABLE     — transient (rate limit, 5xx, network, etc.)
#       FATAL           — non-recoverable (currently never returned;
#                         reserved for future explicit FATAL signals)
#
# Design — exit-code-first ordering:
#   The original lean-genius implementation grepped output BEFORE checking
#   the exit code, which caused false positives on clean exits whose stdout
#   legitimately contained substrings like "500" or "rate limit" (issue
#   #3233). This rewrite checks the exit code first and only inspects output
#   for genuine failures (exit_code != 0). This ordering and the category
#   enum are a frozen contract — callers (spawn retry logic, bad-token
#   tracking reason strings `auth`/`exhausted`) depend on both. Do not
#   reorder the exit-code checks and do not rename/remove categories.
#
# Design — per-provider pattern tables (issue #3, epic #1 dual-runtime
# Claude+Codex support):
#   The exit-code-first engine above is provider-neutral, but the grep
#   patterns used to distinguish CWD_DELETED / TOKEN_EXPIRED /
#   TOKEN_EXHAUSTED are runner-specific text (Claude Code's exact CLI/API
#   phrasing). Those patterns now live in `_classify_error_set_patterns()`,
#   keyed by a `provider` argument (3rd positional arg, falling back to
#   `$LOOM_WORKER`, falling back to `claude`). The generic HTTP/network
#   RECOVERABLE patterns (429, 5xx, ECONNREFUSED, etc.) are provider-agnostic
#   and always apply, regardless of provider/table selection.
#
#   Supported providers:
#     claude  — default. Patterns extracted verbatim from the pre-refactor
#               implementation; behavior is bit-identical to before.
#     codex   — STUB for Phase 2 (OpenAI Codex CLI runner, epic #1). No real
#               patterns yet — see the TODO markers in
#               `_classify_error_set_patterns()` for the category mappings
#               Phase 2 must fill in (401/invalid_api_key -> TOKEN_EXPIRED,
#               rate_limit_exceeded/429 -> TOKEN_EXHAUSTED or RECOVERABLE,
#               etc.). Until then, `codex` behaves like any unknown
#               provider: falls through to the generic HTTP/network checks.
#     <other> — Unknown-provider fallback. No provider-specific patterns are
#               applied (CWD_DELETED/TOKEN_EXPIRED/TOKEN_EXHAUSTED are never
#               matched); only the generic HTTP/network RECOVERABLE patterns
#               apply. A non-zero exit that doesn't match any generic
#               pattern still falls through to the RECOVERABLE catch-all.
#
# Test vectors live in `.loom/scripts/tests/test-spawn-claude.sh`.

# shellcheck disable=SC2120  # OK that callers pass the args; we don't default.

# _classify_error_set_patterns <provider>
#
# Sets the following globals for the caller to consult:
#   _CE_PAT_CWD_DELETED, _CE_PAT_TOKEN_EXPIRED, _CE_PAT_TOKEN_EXHAUSTED,
#   _CE_PAT_NO_MESSAGES
#
# An empty value means "no provider-specific pattern for this category" —
# classify_error() below skips the corresponding grep rather than matching
# an empty pattern (which would match every line).
_classify_error_set_patterns() {
    local provider="$1"

    case "$provider" in
        claude)
            # Verbatim patterns from the pre-refactor (#3233) implementation.
            _CE_PAT_CWD_DELETED="current working directory was deleted"
            _CE_PAT_TOKEN_EXPIRED="401[^a-z]*authentication_error|OAuth token has expired|token has expired"
            _CE_PAT_TOKEN_EXHAUSTED="hit your (limit|weekly limit)|hit.your.limit"
            _CE_PAT_NO_MESSAGES="No messages returned"
            ;;
        codex)
            # STUB — OpenAI Codex CLI runner (epic #1, Phase 2). Real Codex
            # CLI output strings are not yet available; do not guess at
            # them here (issue #3 explicitly scopes actual Codex pattern
            # content out — see "Out of scope"). Documented expected
            # category mappings for Phase 2 to fill in:
            #   TODO(#1 Phase 2): 401 / invalid_api_key error type
            #                     -> TOKEN_EXPIRED
            #   TODO(#1 Phase 2): rate_limit_exceeded / 429 response
            #                     -> TOKEN_EXHAUSTED (quota) or RECOVERABLE
            #                        (transient — depends on Codex's error
            #                        body distinguishing quota vs. throttle)
            #   TODO(#1 Phase 2): workspace/sandbox removed mid-run
            #                     -> CWD_DELETED
            # Until populated, codex falls through to the generic
            # HTTP/network RECOVERABLE patterns below (same as any unknown
            # provider).
            _CE_PAT_CWD_DELETED=""
            _CE_PAT_TOKEN_EXPIRED=""
            _CE_PAT_TOKEN_EXHAUSTED=""
            _CE_PAT_NO_MESSAGES=""
            ;;
        *)
            # Unknown provider: no provider-specific patterns available.
            # Generic HTTP/network patterns (see classify_error) still
            # apply, so genuine transient failures are still caught.
            _CE_PAT_CWD_DELETED=""
            _CE_PAT_TOKEN_EXPIRED=""
            _CE_PAT_TOKEN_EXHAUSTED=""
            _CE_PAT_NO_MESSAGES=""
            ;;
    esac
}

classify_error() {
    local output="$1"
    local exit_code="$2"
    local provider="${3:-${LOOM_WORKER:-claude}}"

    # 1. Timeout from the `timeout(1)` command — productive cycle, not error
    if [[ "$exit_code" -eq 124 || "$exit_code" -eq 137 ]]; then
        echo "TIMEOUT"
        return
    fi

    # 2. Exit-code-first: a clean exit is SUCCESS regardless of output content.
    #    This is the critical fix for #3233 — the previous implementation
    #    returned RECOVERABLE for clean exits whose stdout contained "500",
    #    "rate limit", or "No messages returned". This check runs before any
    #    provider pattern table is even consulted, so it is invariant across
    #    every provider (#3 regression guard).
    if [[ "$exit_code" -eq 0 ]]; then
        echo "SUCCESS"
        return
    fi

    # --- Below here, exit_code != 0 (genuine failure). Inspect output. ---

    local _CE_PAT_CWD_DELETED _CE_PAT_TOKEN_EXPIRED _CE_PAT_TOKEN_EXHAUSTED _CE_PAT_NO_MESSAGES
    _classify_error_set_patterns "$provider"

    # Working directory deleted (worktree cleaned up while CLI ran)
    if [[ -n "$_CE_PAT_CWD_DELETED" ]] && echo "$output" | grep -qi "$_CE_PAT_CWD_DELETED"; then
        echo "CWD_DELETED"
        return
    fi

    # Token expired (401 auth error) — this specific token is bad
    if [[ -n "$_CE_PAT_TOKEN_EXPIRED" ]] && echo "$output" | grep -qiE "$_CE_PAT_TOKEN_EXPIRED"; then
        echo "TOKEN_EXPIRED"
        return
    fi

    # Token exhausted (quota used up) — rotate to a different token
    if [[ -n "$_CE_PAT_TOKEN_EXHAUSTED" ]] && echo "$output" | grep -qiE "$_CE_PAT_TOKEN_EXHAUSTED"; then
        echo "TOKEN_EXHAUSTED"
        return
    fi

    # --- Generic HTTP/network patterns — provider-agnostic, always apply ---

    # Rate limit (429) — transient, retry with backoff
    if echo "$output" | grep -qiE "rate.limit|too.many.requests|429"; then
        echo "RECOVERABLE"
        return
    fi

    # Server errors (5xx) — transient
    if echo "$output" | grep -qiE "500|502|503|504|internal.server.error|service.unavailable"; then
        echo "RECOVERABLE"
        return
    fi

    # Network errors — transient
    if echo "$output" | grep -qiE "ECONNREFUSED|ETIMEDOUT|network.error"; then
        echo "RECOVERABLE"
        return
    fi

    # "No messages returned" — transient API issue (only if exit_code != 0).
    # Provider-specific (Claude CLI phrasing); no-op when the active
    # provider's table leaves this pattern empty.
    if [[ -n "$_CE_PAT_NO_MESSAGES" ]] && echo "$output" | grep -q "$_CE_PAT_NO_MESSAGES"; then
        echo "RECOVERABLE"
        return
    fi

    # Catch-all: unknown non-zero exit, treat as recoverable in daemon mode
    echo "RECOVERABLE"
}

# Convenience predicate matching legacy callers in claude-wrapper.sh.
is_recoverable_error() {
    local classification
    classification=$(classify_error "$1" "$2" "${3:-}")
    [[ "$classification" != "FATAL" && "$classification" != "SUCCESS" ]]
}

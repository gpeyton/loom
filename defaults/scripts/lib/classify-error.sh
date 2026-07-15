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
#     codex   — OpenAI Codex CLI runner (epic #1, Phase 2, issue #10).
#               TOKEN_EXPIRED (401/invalid_api_key/Unauthorized) and
#               TOKEN_EXHAUSTED (rate_limit_exceeded/insufficient_quota/usage
#               limit) patterns are populated from OpenAI's documented API
#               error surface; see `_classify_error_set_patterns()`.
#               CWD_DELETED and NO_MESSAGES have no reliable Codex signature
#               yet and are intentionally left empty (documented, not
#               guessed). A bare 429 throttle and 5xx/network errors are
#               caught by the generic provider-agnostic RECOVERABLE patterns.
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
            # OpenAI Codex CLI runner (epic #1, Phase 2, issue #10). Patterns
            # derived from OpenAI's documented API error surface (error `type`
            # / `code` strings and HTTP statuses the Codex CLI relays verbatim
            # from the Responses API) plus observed `codex exec` failure output
            # (e.g. `stream error: exceeded retry limit, last status: 401
            # Unauthorized`, openai/codex#2896). Where a category has no
            # reliable Codex signature yet, the pattern is left empty rather
            # than guessed (issue #10: "leave it documented rather than
            # guessing") — an empty pattern is skipped by classify_error()
            # below, so the category simply never matches for codex.
            #
            #   TOKEN_EXPIRED   401 / invalid_api_key / "Incorrect API key" /
            #                   Unauthorized auth failures. This token is bad;
            #                   the caller should skip/rotate it.
            #   TOKEN_EXHAUSTED rate_limit_exceeded / insufficient_quota /
            #                   "usage limit" (weekly/plan quota used up).
            #                   NOTE: a bare `429` with no quota wording is a
            #                   transient throttle and is intentionally left to
            #                   the generic RECOVERABLE `429` pattern below —
            #                   only explicit quota-exhaustion phrasing maps to
            #                   TOKEN_EXHAUSTED (issue #10 mapping).
            #   CWD_DELETED     No reliable Codex-specific signature for a
            #                   workspace/sandbox removed mid-run is documented
            #                   yet; left empty (Claude's "current working
            #                   directory was deleted" phrasing is NOT reused —
            #                   it is Claude-CLI-specific). Populate when a real
            #                   Codex signature is observed.
            #   NO_MESSAGES     Claude-CLI-specific concept; no Codex analogue.
            #                   Left empty.
            # Transient 429/5xx/network failures are caught by the generic
            # provider-agnostic patterns in classify_error() (they always
            # apply), so codex gets RECOVERABLE for those without a table entry.
            _CE_PAT_CWD_DELETED=""
            _CE_PAT_TOKEN_EXPIRED="401[^a-z]*unauthorized|invalid_api_key|invalid api key|incorrect api key"
            _CE_PAT_TOKEN_EXHAUSTED="rate_limit_exceeded|insufficient_quota|exceeded your current quota|usage limit|quota exceeded"
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

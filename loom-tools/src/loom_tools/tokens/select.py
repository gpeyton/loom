"""Token selection algorithm — 3-tier priority.

Selection order:
    1. Ranking file (.ranking, <10 min old): pick first non-exhausted
       account, skipping bad tokens.
    2. Allowlist file (.allowlist): random pick from allowed accounts.
    3. Random pick from all .token files.

In all tiers, tokens marked bad (via bad_tokens.is_bad) are skipped.

This module is import-safe: no I/O occurs at import time. Both the daemon
(via ``import``) and the bash wrapper (via ``python3 -m``) call
``select_token`` from concurrent processes.

Worktree handling: when invoked from a worktree, callers should pass the
canonical repo root (i.e. ``git rev-parse --show-toplevel`` of the main
checkout, not the worktree). The bash wrapper uses
``git rev-parse --git-common-dir`` to derive this.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Iterable

from loom_tools.tokens.bad_tokens import is_bad
from loom_tools.tokens.providers import (
    DEFAULT_PROVIDER,
    KNOWN_PROVIDERS,
    env_var_for_provider,
    load_provider_map,
    provider_of,
)

# Ranking file is considered fresh for this many seconds.
_RANKING_FRESH_SECONDS = 600  # 10 min

# Exit code when no token is available (matches sysexits.h EX_CONFIG)
EX_CONFIG = 78


class TokenSelectionError(Exception):
    """Base class for token selection failures."""


class EmptyTokenPoolError(TokenSelectionError):
    """No tokens available — bootstrap has not been run, or all are bad."""


@dataclass(frozen=True)
class SelectedToken:
    """A token chosen by ``select_token``."""

    name: str  # basename without .token extension
    file: Path  # absolute path to .token file
    key: str  # token contents (whitespace-stripped)
    mode: str  # "ranked" | "allowlist" | "random"
    provider: str = DEFAULT_PROVIDER  # account provider (from index.json)


def _read_token_file(token_path: Path) -> str:
    """Read a .token file, stripping all whitespace defensively."""
    raw = token_path.read_text(encoding="utf-8", errors="strict")
    return "".join(raw.split())


def _file_age_seconds(path: Path) -> float | None:
    """Return file age in seconds, or None if file missing."""
    try:
        return time.time() - path.stat().st_mtime
    except FileNotFoundError:
        return None


def _list_token_files(tokens_dir: Path) -> list[Path]:
    """Return all .token files sorted by name (deterministic ordering)."""
    return sorted(tokens_dir.glob("*.token"))


def _strip_comment(line: str) -> str:
    """Drop ``#`` comments and trim whitespace."""
    line = line.split("#", 1)[0]
    return line.strip()


def _read_ranking(ranking_file: Path) -> Iterable[tuple[str, str]]:
    """Yield (name, status) pairs from the ranking file.

    Format: ``name|status`` per line. Lines starting with ``#`` are skipped.
    Malformed lines are skipped. ``status`` defaults to empty string.
    """
    try:
        for raw in ranking_file.read_text(encoding="utf-8").splitlines():
            stripped = _strip_comment(raw)
            if not stripped:
                continue
            parts = stripped.split("|", 1)
            name = parts[0].strip()
            status = parts[1].strip() if len(parts) > 1 else ""
            if name:
                yield name, status
    except OSError:
        return


def _read_allowlist(allowlist_file: Path) -> list[str]:
    """Return list of token names in the allowlist (no .token extension)."""
    out: list[str] = []
    try:
        for raw in allowlist_file.read_text(encoding="utf-8").splitlines():
            stripped = _strip_comment(raw)
            if stripped:
                out.append(stripped)
    except OSError:
        pass
    return out


def _try_ranking(
    tokens_dir: Path,
    ranking_file: Path,
    workspace_path: Path,
    rng: random.Random,
    eligible: set[str],
) -> SelectedToken | None:
    """Strategy 1: read .ranking, return first non-exhausted/non-blocked entry."""
    age = _file_age_seconds(ranking_file)
    if age is None or age >= _RANKING_FRESH_SECONDS:
        return None
    for name, status in _read_ranking(ranking_file):
        if status in ("exhausted", "blocked"):
            continue
        if name not in eligible:
            continue
        token_file = tokens_dir / f"{name}.token"
        if not token_file.is_file():
            continue
        if is_bad(workspace_path, name):
            continue
        try:
            key = _read_token_file(token_file)
        except OSError:
            continue
        if not key:
            continue
        return SelectedToken(name=name, file=token_file, key=key, mode="ranked")
    return None


def _try_allowlist(
    tokens_dir: Path,
    allowlist_file: Path,
    workspace_path: Path,
    rng: random.Random,
    eligible: set[str],
) -> SelectedToken | None:
    """Strategy 2: random pick from allowlist."""
    if not allowlist_file.is_file():
        return None
    names = _read_allowlist(allowlist_file)
    candidates: list[Path] = []
    for name in names:
        if name not in eligible:
            continue
        token_file = tokens_dir / f"{name}.token"
        if token_file.is_file() and not is_bad(workspace_path, name):
            candidates.append(token_file)
    if not candidates:
        return None
    rng.shuffle(candidates)
    for token_file in candidates:
        try:
            key = _read_token_file(token_file)
        except OSError:
            continue
        if not key:
            continue
        return SelectedToken(
            name=token_file.stem,
            file=token_file,
            key=key,
            mode="allowlist",
        )
    return None


def _try_random(
    tokens_dir: Path,
    workspace_path: Path,
    rng: random.Random,
    eligible: set[str],
) -> SelectedToken | None:
    """Strategy 3: random pick from all tokens."""
    candidates = [
        p
        for p in _list_token_files(tokens_dir)
        if p.stem in eligible and not is_bad(workspace_path, p.stem)
    ]
    if not candidates:
        return None
    rng.shuffle(candidates)
    for token_file in candidates:
        try:
            key = _read_token_file(token_file)
        except OSError:
            continue
        if not key:
            continue
        return SelectedToken(
            name=token_file.stem,
            file=token_file,
            key=key,
            mode="random",
        )
    return None


def select_token(
    workspace_path: Path | str,
    *,
    provider: str = DEFAULT_PROVIDER,
    rng: random.Random | None = None,
) -> SelectedToken:
    """Select an OAuth token using the 3-tier algorithm.

    Args:
        workspace_path: Repo root containing ``.loom/tokens/``. When called
            from a worktree, pass the canonical (main checkout) root, not
            the worktree path.
        provider: Only consider accounts belonging to this provider
            (default ``anthropic`` — unchanged behavior for existing
            callers). Accounts absent from ``index.json``, or recorded
            without a provider field, are treated as ``anthropic``.
        rng: Optional random.Random instance for deterministic testing.
            Defaults to a module-level Random seeded from os.urandom.

    Returns:
        SelectedToken with name, absolute file path, key, selection mode,
        and provider.

    Raises:
        EmptyTokenPoolError: When ``.loom/tokens/`` is missing, contains no
            ``.token`` files, no token belongs to *provider*, or every
            eligible token is marked bad.
            The bash wrapper hard-fails (exit 78) and prompts the user to
            run ``loom-tokens bootstrap`` — never silently falls back.
    """
    workspace_path = Path(workspace_path)
    tokens_dir = workspace_path / ".loom" / "tokens"

    if not tokens_dir.is_dir():
        raise EmptyTokenPoolError(
            f"Token directory does not exist: {tokens_dir}. "
            f"Run `loom-tokens bootstrap` to populate it.",
        )

    all_tokens = _list_token_files(tokens_dir)
    if not all_tokens:
        raise EmptyTokenPoolError(
            f"No .token files in {tokens_dir}. Run `loom-tokens bootstrap`.",
        )

    # Provider filter (#12). With no index.json (or entries without a
    # provider field) every account resolves to the default provider, so
    # the default-provider call sees the identical candidate set as
    # before provider-awareness existed.
    pmap = load_provider_map(tokens_dir)
    eligible = {
        p.stem for p in all_tokens if provider_of(p.stem, pmap) == provider
    }
    if not eligible:
        raise EmptyTokenPoolError(
            f"No tokens for provider '{provider}' in {tokens_dir} "
            f"({len(all_tokens)} token(s) belong to other providers). "
            f"Add ACCOUNT_PROVIDER_N={provider} accounts to .env and run "
            f"`loom-tokens bootstrap`.",
        )

    if rng is None:
        rng = random.Random(os.urandom(16))

    ranking_file = tokens_dir / ".ranking"
    allowlist_file = tokens_dir / ".allowlist"

    selected = _try_ranking(
        tokens_dir, ranking_file, workspace_path, rng, eligible
    )
    if selected is None:
        selected = _try_allowlist(
            tokens_dir, allowlist_file, workspace_path, rng, eligible
        )
    if selected is None:
        selected = _try_random(tokens_dir, workspace_path, rng, eligible)
    if selected is not None:
        return replace(selected, provider=provider)

    raise EmptyTokenPoolError(
        f"All {len(eligible)} '{provider}' tokens in {tokens_dir} are "
        f"marked bad or empty. "
        f"Inspect .bad_tokens or run `loom-tokens bootstrap --force`.",
    )


def _main(argv: list[str] | None = None) -> int:
    """CLI entry: emit the selected token as JSON or shell-export lines.

    The bash wrapper invokes us via ``python3 -m loom_tools.tokens.select``
    and parses the JSON form. ``--export`` is provided for convenience
    debugging.
    """
    parser = argparse.ArgumentParser(
        prog="python -m loom_tools.tokens.select",
        description="Select an account token from .loom/tokens/.",
    )
    parser.add_argument(
        "--workspace",
        required=True,
        help="Repo root containing .loom/tokens/.",
    )
    parser.add_argument(
        "--provider",
        choices=KNOWN_PROVIDERS,
        default=DEFAULT_PROVIDER,
        help=(
            "Only select accounts for this provider "
            f"(default: {DEFAULT_PROVIDER})."
        ),
    )
    fmt = parser.add_mutually_exclusive_group()
    fmt.add_argument("--json", action="store_true", help="Emit JSON (default).")
    fmt.add_argument(
        "--export",
        action="store_true",
        help=(
            "Emit shell `export <VAR>=...` lines. The variable is "
            "provider-specific: CLAUDE_CODE_OAUTH_TOKEN for anthropic, "
            "OPENAI_API_KEY for openai."
        ),
    )
    parser.add_argument(
        "--no-key",
        action="store_true",
        help="Omit the secret key from output (for safe inspection).",
    )
    args = parser.parse_args(argv)

    try:
        sel = select_token(args.workspace, provider=args.provider)
    except EmptyTokenPoolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EX_CONFIG

    if args.export:
        env_var = env_var_for_provider(sel.provider)
        if env_var is None:  # pragma: no cover — choices= prevents this
            print(
                f"error: no export env var known for provider "
                f"'{sel.provider}'",
                file=sys.stderr,
            )
            return EX_CONFIG
        if args.no_key:
            print(
                f"# selected={sel.name} mode={sel.mode} "
                f"provider={sel.provider} file={sel.file}"
            )
        else:
            print(f"export {env_var}={sel.key!r}")
            print(
                f"# selected={sel.name} mode={sel.mode} "
                f"provider={sel.provider} file={sel.file}"
            )
        return 0

    payload = {
        "name": sel.name,
        "file": str(sel.file),
        "mode": sel.mode,
        "provider": sel.provider,
    }
    if not args.no_key:
        payload["key"] = sel.key
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    sys.exit(_main())

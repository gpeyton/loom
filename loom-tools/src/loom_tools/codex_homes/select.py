"""Deterministic profile-pool selection for ``LOOM_CODEX_HOMES_DIR``
(issue #36 / Epic #30 Phase 2).

This is the Codex-profile counterpart of ``loom_tools.tokens.select`` —
but it selects a **directory** (a ``CODEX_HOME`` profile pre-authenticated
via ``codex login``), never a secret string. The distinction matters for
the safety requirements below.

Mechanism
---------
``LOOM_CODEX_HOMES_DIR`` points at a parent directory whose immediate
children are candidate profile directories. A profile directory is
"usable" (valid) when it contains a regular, non-empty, readable
``auth.json`` file. Selection among usable profiles is **deterministic**:
a sha256-based hash of the caller-supplied *seed* (expected to be
``LOOM_TERMINAL_ID`` or a sweep/issue id) is reduced modulo the number of
usable profiles, indexing into the **sorted** list of usable profile
names. Same seed + same directory contents => same pick, every time, on
every platform — this module deliberately does NOT use Python's builtin
``hash()`` (salted per-process via ``PYTHONHASHSEED`` unless pinned),
which would make the "same seed -> same pick" contract flaky across
process restarts.

Safety requirements (issue #36 acceptance criteria)
----------------------------------------------------
* **Never read or log ``auth.json`` contents.** This module only checks
  file *metadata* (existence, regular-file-ness, non-zero size) — it
  never opens ``auth.json`` for reading. Callers (``spawn-codex.sh``,
  ``CodexPreparer``) must symlink the file, never copy it, and must log
  only the profile *directory name* — never any path contents or file
  bytes.
* **Missing/unusable profiles never raise.** A profile without a usable
  ``auth.json`` is simply excluded from the candidate list. If the pool
  contains zero usable profiles (or the directory doesn't exist),
  ``select_profile`` returns ``None`` — the caller is expected to fall
  through to the next auth-precedence tier, not fail the spawn.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path

AUTH_FILENAME = "auth.json"

#: Exit code for "no usable profile found" — the bash caller treats any
#: non-zero exit as "fall through to the next auth tier", so the exact
#: value isn't load-bearing, but we reuse the repo's EX_CONFIG convention
#: (see loom_tools.tokens.select.EX_CONFIG) for consistency.
EX_CONFIG = 78


@dataclass(frozen=True)
class SelectedProfile:
    """A deterministically-selected Codex profile directory."""

    name: str  # basename of the profile dir (safe to log)
    path: Path  # absolute path to the profile dir
    auth_file: Path  # absolute path to <path>/auth.json (symlink target)


def _is_valid_profile_dir(candidate: Path) -> bool:
    """A profile dir is usable iff it is a directory containing a
    regular, non-empty, readable ``auth.json``.

    Never reads file *contents* — only inspects metadata — so this check
    itself cannot leak credential material.
    """
    try:
        if not candidate.is_dir():
            return False
        auth_file = candidate / AUTH_FILENAME
        if not auth_file.is_file():
            return False
        if auth_file.is_symlink() and not auth_file.exists():
            return False  # dangling symlink
        return auth_file.stat().st_size > 0
    except OSError:
        return False


def is_valid_profile_dir(candidate: Path | str) -> bool:
    """Public wrapper of :func:`_is_valid_profile_dir` (for tier-2 style
    single-directory validation, e.g. an explicit ``LOOM_CODEX_HOME`` pin).
    """
    return _is_valid_profile_dir(Path(candidate))


def list_valid_profiles(homes_dir: Path | str) -> list[str]:
    """Sorted (deterministic) names of usable immediate child profile dirs.

    Returns an empty list when ``homes_dir`` doesn't exist or is not a
    directory, or contains no usable children — never raises.
    """
    homes_dir = Path(homes_dir)
    if not homes_dir.is_dir():
        return []
    names: list[str] = []
    try:
        children = list(homes_dir.iterdir())
    except OSError:
        return []
    for child in children:
        if _is_valid_profile_dir(child):
            names.append(child.name)
    return sorted(names)


def _stable_index(seed: str, count: int) -> int:
    """Deterministic hash-mod index into a list of length ``count``.

    Uses sha256 (not the builtin, per-process-salted ``hash()``) so the
    same ``(seed, count)`` pair always produces the same index, across
    processes, platforms, and Python versions/PYTHONHASHSEED settings.
    """
    digest = hashlib.sha256(seed.encode("utf-8")).digest()
    # First 8 bytes -> unsigned 64-bit int, big-endian (matches the hex
    # equivalent int(digest.hex()[:16], 16), spelled via bytes for clarity).
    idx = int.from_bytes(digest[:8], byteorder="big", signed=False)
    return idx % count


def select_profile(homes_dir: Path | str, seed: str) -> SelectedProfile | None:
    """Deterministically select one usable profile dir under ``homes_dir``.

    Args:
        homes_dir: parent directory whose immediate children are candidate
            profile dirs (``LOOM_CODEX_HOMES_DIR``).
        seed: a stable per-caller identifier (``LOOM_TERMINAL_ID`` or a
            sweep/issue id) used to deterministically distribute
            concurrent callers across the pool. Must be non-empty —
            callers should refuse to call this with an empty seed (an
            empty seed still hashes deterministically, but every caller
            without a real identity would collide on the same profile,
            defeating the "distribute predictably" goal).

    Returns:
        The selected :class:`SelectedProfile`, or ``None`` when
        ``homes_dir`` has no usable profile (missing directory, empty
        directory, or every child lacks a usable ``auth.json``). Callers
        MUST treat ``None`` as "fall through to the next auth tier" —
        never as an error to propagate.
    """
    names = list_valid_profiles(homes_dir)
    if not names:
        return None
    idx = _stable_index(seed, len(names))
    name = names[idx]
    profile_dir = Path(homes_dir) / name
    return SelectedProfile(
        name=name,
        path=profile_dir.resolve(),
        auth_file=(profile_dir / AUTH_FILENAME).resolve(),
    )


def _main(argv: list[str] | None = None) -> int:
    """CLI entry: emit the selected profile as JSON.

    Invoked by ``defaults/scripts/spawn-codex.sh`` via
    ``python3 -m loom_tools.codex_homes.select``. Never prints
    ``auth.json`` contents — only the directory name and paths.
    """
    parser = argparse.ArgumentParser(
        prog="python -m loom_tools.codex_homes.select",
        description=(
            "Deterministically select a ChatGPT-authenticated Codex "
            "profile directory from LOOM_CODEX_HOMES_DIR."
        ),
    )
    parser.add_argument(
        "--homes-dir",
        required=True,
        help="Parent directory of candidate CODEX_HOME profile dirs.",
    )
    parser.add_argument(
        "--seed",
        required=True,
        help="Stable seed (LOOM_TERMINAL_ID or sweep/issue id) for deterministic selection.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit JSON (default output format; flag accepted for parity with tokens.select).",
    )
    args = parser.parse_args(argv)

    selected = select_profile(args.homes_dir, args.seed)
    if selected is None:
        print(
            f"error: no usable Codex profile directory under {args.homes_dir!r} "
            "(missing dir, empty dir, or no child has a usable auth.json)",
            file=sys.stderr,
        )
        return EX_CONFIG

    payload = {
        "name": selected.name,
        "path": str(selected.path),
        "auth_file": str(selected.auth_file),
    }
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())

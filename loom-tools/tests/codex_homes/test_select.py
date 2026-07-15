"""Tests for loom_tools.codex_homes.select (issue #36 / Epic #30 Phase 2).

Covers:
  - Deterministic selection (same seed + same pool contents -> same pick,
    across repeated calls and fresh processes).
  - Distribution across seeds (different seeds land on different profiles
    often enough to prove the hash-mod isn't degenerate).
  - Missing/unusable profiles are excluded, never raise.
  - Empty / missing homes-dir returns None (fall-through contract), not
    an exception.
  - CRITICAL safety guarantee: auth.json content is never read or
    surfaced anywhere in the selection result (only paths/names).
  - CLI entry point (`python -m loom_tools.codex_homes.select`) JSON
    output and non-zero exit on no-usable-profile.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from loom_tools.codex_homes.select import (
    EX_CONFIG,
    SelectedProfile,
    is_valid_profile_dir,
    list_valid_profiles,
    select_profile,
)

SECRET_MARKER = "sk-super-secret-should-never-appear-anywhere"


def _make_profile(homes_dir: Path, name: str, auth_contents: str | None) -> Path:
    """Create a profile dir under homes_dir; write auth.json unless None."""
    profile = homes_dir / name
    profile.mkdir(parents=True)
    if auth_contents is not None:
        (profile / "auth.json").write_text(auth_contents, encoding="utf-8")
    return profile


# ---------- list_valid_profiles / is_valid_profile_dir ----------


def test_list_valid_profiles_empty_dir_returns_empty(tmp_path: Path) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    assert list_valid_profiles(homes) == []


def test_list_valid_profiles_missing_dir_returns_empty(tmp_path: Path) -> None:
    assert list_valid_profiles(tmp_path / "does-not-exist") == []


def test_list_valid_profiles_filters_unusable(tmp_path: Path) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    _make_profile(homes, "good-a", f"{{{SECRET_MARKER}}}")
    _make_profile(homes, "good-b", "{another}")
    _make_profile(homes, "no-auth-file", None)  # no auth.json at all
    _make_profile(homes, "empty-auth", "")  # auth.json exists but empty
    # A plain file (not a dir) alongside the profile dirs must be ignored.
    (homes / "not-a-dir.txt").write_text("ignore me", encoding="utf-8")

    names = list_valid_profiles(homes)
    assert names == ["good-a", "good-b"], "only usable profiles, sorted"


def test_is_valid_profile_dir_true_for_usable(tmp_path: Path) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    profile = _make_profile(homes, "acct-1", "{}")
    assert is_valid_profile_dir(profile) is True


def test_is_valid_profile_dir_false_for_missing_auth(tmp_path: Path) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    profile = _make_profile(homes, "acct-1", None)
    assert is_valid_profile_dir(profile) is False


def test_is_valid_profile_dir_false_for_empty_auth(tmp_path: Path) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    profile = _make_profile(homes, "acct-1", "")
    assert is_valid_profile_dir(profile) is False


def test_is_valid_profile_dir_false_for_dangling_symlink(tmp_path: Path) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    profile = homes / "acct-1"
    profile.mkdir()
    (profile / "auth.json").symlink_to(tmp_path / "nonexistent-target.json")
    assert is_valid_profile_dir(profile) is False


def test_is_valid_profile_dir_false_for_nonexistent_dir(tmp_path: Path) -> None:
    assert is_valid_profile_dir(tmp_path / "nope") is False


# ---------- select_profile: determinism ----------


def test_select_profile_deterministic_same_seed_same_pick(tmp_path: Path) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    for i in range(5):
        _make_profile(homes, f"acct-{i}", "{}")

    picks = {select_profile(homes, "terminal-42").name for _ in range(20)}
    assert len(picks) == 1, "same seed must always pick the same profile"


def test_select_profile_deterministic_across_fresh_processes(tmp_path: Path) -> None:
    """Determinism must hold across process restarts (not just within one
    interpreter) — this is the actual production requirement, since
    concurrent spawns are separate OS processes. Guard against relying on
    anything process-local (e.g. PYTHONHASHSEED-salted hash()).
    """
    homes = tmp_path / "homes"
    homes.mkdir()
    for i in range(5):
        _make_profile(homes, f"acct-{i}", "{}")

    in_process = select_profile(homes, "sweep-issue-777").name

    src_root = Path(__file__).resolve().parents[2] / "src"
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "loom_tools.codex_homes.select",
            "--homes-dir",
            str(homes),
            "--seed",
            "sweep-issue-777",
            "--json",
        ],
        capture_output=True,
        text=True,
        env={"PYTHONPATH": str(src_root), "PATH": "/usr/bin:/bin"},
    )
    assert proc.returncode == 0, proc.stderr
    out_of_process = json.loads(proc.stdout)["name"]
    assert in_process == out_of_process


def test_select_profile_different_seeds_distribute(tmp_path: Path) -> None:
    """Not a strict uniformity test — just proves the hash-mod isn't
    degenerate (e.g. doesn't always return index 0)."""
    homes = tmp_path / "homes"
    homes.mkdir()
    for i in range(8):
        _make_profile(homes, f"acct-{i}", "{}")

    picks = {
        select_profile(homes, f"terminal-{i}").name for i in range(30)
    }
    assert len(picks) > 1, "different seeds should land on more than one profile"


def test_select_profile_stable_when_pool_contents_unchanged(tmp_path: Path) -> None:
    """Re-selecting with the same seed after re-listing the same directory
    (simulating a second spawn some time later) picks the same profile."""
    homes = tmp_path / "homes"
    homes.mkdir()
    for name in ["zeta", "alpha", "mu"]:
        _make_profile(homes, name, "{}")

    first = select_profile(homes, "consistent-seed")
    second = select_profile(homes, "consistent-seed")
    assert first == second


def test_select_profile_adding_unrelated_profile_may_reshuffle_but_is_deterministic(
    tmp_path: Path,
) -> None:
    """Growing the pool can change which index a seed maps to (expected —
    hash-mod is sensitive to `count`), but for a FIXED pool the result is
    always reproducible. This test locks in that the selection is a pure
    function of (sorted names, seed)."""
    homes = tmp_path / "homes"
    homes.mkdir()
    _make_profile(homes, "acct-a", "{}")
    _make_profile(homes, "acct-b", "{}")

    before = select_profile(homes, "seed-x").name
    # Re-run without changing anything: must reproduce.
    after = select_profile(homes, "seed-x").name
    assert before == after


# ---------- select_profile: fall-through contract ----------


def test_select_profile_returns_none_for_missing_dir(tmp_path: Path) -> None:
    assert select_profile(tmp_path / "nope", "any-seed") is None


def test_select_profile_returns_none_for_empty_pool(tmp_path: Path) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    assert select_profile(homes, "any-seed") is None


def test_select_profile_returns_none_when_all_profiles_unusable(
    tmp_path: Path,
) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    _make_profile(homes, "broken-1", None)
    _make_profile(homes, "broken-2", "")
    assert select_profile(homes, "any-seed") is None


def test_select_profile_skips_unusable_and_picks_among_usable_only(
    tmp_path: Path,
) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    _make_profile(homes, "broken", None)
    _make_profile(homes, "only-good", "{}")

    selected = select_profile(homes, "whatever-seed")
    assert selected is not None
    assert selected.name == "only-good"


# ---------- CRITICAL safety: never read/surface auth.json content ----------


def test_select_profile_never_exposes_auth_json_content(tmp_path: Path) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    _make_profile(homes, "acct-1", SECRET_MARKER)

    selected = select_profile(homes, "seed")
    assert selected is not None
    # The dataclass must carry only names/paths, never secret bytes.
    for field_value in (selected.name, str(selected.path), str(selected.auth_file)):
        assert SECRET_MARKER not in field_value

    # repr()/str() of the whole object (what a naive `log.info(selected)`
    # would print) also must never leak the secret.
    assert SECRET_MARKER not in repr(selected)
    assert SECRET_MARKER not in str(selected)


def test_cli_json_output_never_contains_auth_json_content(tmp_path: Path) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    _make_profile(homes, "acct-1", SECRET_MARKER)

    src_root = Path(__file__).resolve().parents[2] / "src"
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "loom_tools.codex_homes.select",
            "--homes-dir",
            str(homes),
            "--seed",
            "seed",
            "--json",
        ],
        capture_output=True,
        text=True,
        env={"PYTHONPATH": str(src_root), "PATH": "/usr/bin:/bin"},
    )
    assert proc.returncode == 0, proc.stderr
    assert SECRET_MARKER not in proc.stdout
    assert SECRET_MARKER not in proc.stderr
    payload = json.loads(proc.stdout)
    assert set(payload.keys()) == {"name", "path", "auth_file"}


# ---------- CLI ----------


def test_cli_exits_nonzero_on_no_usable_profile(tmp_path: Path) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()

    src_root = Path(__file__).resolve().parents[2] / "src"
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "loom_tools.codex_homes.select",
            "--homes-dir",
            str(homes),
            "--seed",
            "seed",
        ],
        capture_output=True,
        text=True,
        env={"PYTHONPATH": str(src_root), "PATH": "/usr/bin:/bin"},
    )
    assert proc.returncode == EX_CONFIG
    assert "no usable Codex profile" in proc.stderr


def test_cli_json_output_shape(tmp_path: Path) -> None:
    homes = tmp_path / "homes"
    homes.mkdir()
    _make_profile(homes, "acct-1", "{}")

    src_root = Path(__file__).resolve().parents[2] / "src"
    proc = subprocess.run(
        [
            sys.executable,
            "-m",
            "loom_tools.codex_homes.select",
            "--homes-dir",
            str(homes),
            "--seed",
            "seed",
        ],
        capture_output=True,
        text=True,
        env={"PYTHONPATH": str(src_root), "PATH": "/usr/bin:/bin"},
    )
    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout)
    assert payload["name"] == "acct-1"
    assert payload["path"].endswith("acct-1")
    assert payload["auth_file"].endswith("acct-1/auth.json")

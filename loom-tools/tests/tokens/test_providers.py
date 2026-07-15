"""Tests for per-account provider support (#12).

Covers:

* ``loom_tools.tokens.providers`` primitives (normalization, env-var
  mapping, ``index.json`` provider-map loading).
* Bootstrap round-trip of ``ACCOUNT_PROVIDER_N`` (and the anthropic
  default when the field is absent).
* Provider-aware selection: filtering in all three tiers, the openai
  export path, and backward compatibility for pools with no
  ``index.json``.
* The provider probe plugin boundary in ``check.py``: openai probe
  status mapping, mixed-provider ``run_check`` dispatch, and the
  never-abort-on-probe-failure contract.
"""

from __future__ import annotations

import json
import os
import pathlib
import random
import subprocess
import sys
from unittest.mock import patch

import pytest
import requests

from loom_tools.common.repo import clear_repo_cache
from loom_tools.tokens.bootstrap import bootstrap_tokens
from loom_tools.tokens.check import (
    AccountResult,
    probe_account_for_provider,
    probe_openai_account,
    run_check,
)
from loom_tools.tokens.providers import (
    DEFAULT_PROVIDER,
    env_var_for_provider,
    load_provider_map,
    normalize_provider,
    provider_of,
)
from loom_tools.tokens.select import EmptyTokenPoolError, select_token


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


@pytest.fixture
def mock_repo(tmp_path: pathlib.Path) -> pathlib.Path:
    """Create a mock repo with .git and .loom directories."""
    clear_repo_cache()
    (tmp_path / ".git").mkdir()
    (tmp_path / ".loom").mkdir()
    return tmp_path


def _make_workspace(
    tmp_path: pathlib.Path,
    accounts: dict[str, str],
    providers: dict[str, str] | None = None,
) -> pathlib.Path:
    """Materialize .loom/tokens/ with tokens and (optionally) an index.json.

    ``providers`` maps account name -> provider; accounts not listed get
    no index entry at all (exercising the treated-as-anthropic default).
    When ``providers`` is None no index.json is written.
    """
    tokens_dir = tmp_path / ".loom" / "tokens"
    tokens_dir.mkdir(parents=True)
    for name, key in accounts.items():
        (tokens_dir / f"{name}.token").write_text(key, encoding="utf-8")
    if providers is not None:
        index = {
            "version": 1,
            "generated_at": "2026-07-14T00:00:00Z",
            "accounts": [
                {"name": name, "file": f"{name}.token", "provider": prov}
                for name, prov in providers.items()
            ],
        }
        (tokens_dir / "index.json").write_text(
            json.dumps(index), encoding="utf-8"
        )
    return tmp_path


def _cli_env() -> dict[str, str]:
    pkg_root = pathlib.Path(__file__).resolve().parents[2] / "src"
    env = os.environ.copy()
    existing_pp = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = (
        f"{pkg_root}{os.pathsep}{existing_pp}" if existing_pp else str(pkg_root)
    )
    return env


def _mock_response(status_code: int = 200, headers: dict[str, str] | None = None):
    from unittest.mock import MagicMock

    resp = MagicMock(spec=requests.Response)
    resp.status_code = status_code
    resp.headers = headers or {}
    resp.text = ""
    return resp


# ---------------------------------------------------------------------------
# providers module primitives
# ---------------------------------------------------------------------------


class TestProvidersModule:
    def test_default_provider_is_anthropic(self) -> None:
        assert DEFAULT_PROVIDER == "anthropic"

    def test_normalize_defaults(self) -> None:
        assert normalize_provider(None) == "anthropic"
        assert normalize_provider("") == "anthropic"
        assert normalize_provider("  ") == "anthropic"

    def test_normalize_lowercases(self) -> None:
        assert normalize_provider("OpenAI") == "openai"
        assert normalize_provider(" Anthropic ") == "anthropic"

    def test_env_var_mapping(self) -> None:
        assert env_var_for_provider("anthropic") == "CLAUDE_CODE_OAUTH_TOKEN"
        assert env_var_for_provider("openai") == "OPENAI_API_KEY"
        assert env_var_for_provider("gemini") is None

    def test_load_provider_map_missing_index(self, tmp_path: pathlib.Path) -> None:
        assert load_provider_map(tmp_path) == {}

    def test_load_provider_map_corrupt_index(self, tmp_path: pathlib.Path) -> None:
        (tmp_path / "index.json").write_text("{not json", encoding="utf-8")
        assert load_provider_map(tmp_path) == {}

    def test_load_provider_map_pre_12_index(self, tmp_path: pathlib.Path) -> None:
        # index.json written before #12 has no provider field.
        index = {"version": 1, "accounts": [{"name": "agent-1", "file": "agent-1.token"}]}
        (tmp_path / "index.json").write_text(json.dumps(index), encoding="utf-8")
        pmap = load_provider_map(tmp_path)
        assert pmap == {"agent-1": "anthropic"}
        assert provider_of("agent-1", pmap) == "anthropic"

    def test_provider_of_defaults_for_unknown_account(self) -> None:
        assert provider_of("not-in-index", {"other": "openai"}) == "anthropic"


# ---------------------------------------------------------------------------
# bootstrap: ACCOUNT_PROVIDER_N round-trip
# ---------------------------------------------------------------------------


class TestBootstrapProvider:
    def test_provider_recorded_in_index(self, mock_repo: pathlib.Path) -> None:
        (mock_repo / ".env").write_text(
            "ACCOUNT_EMAIL_1=a@b.com\n"
            "ACCOUNT_KEY_1=sk-ant-oat01-aaa\n"
            "ACCOUNT_TOKEN_FILE_1=claude.token\n"
            "ACCOUNT_EMAIL_2=c@d.com\n"
            "ACCOUNT_KEY_2=sk-openai-key\n"
            "ACCOUNT_TOKEN_FILE_2=codex.token\n"
            "ACCOUNT_PROVIDER_2=openai\n",
            encoding="utf-8",
        )
        bootstrap_tokens(mock_repo)
        idx = json.loads(
            (mock_repo / ".loom" / "tokens" / "index.json").read_text()
        )
        by_name = {a["name"]: a for a in idx["accounts"]}
        assert by_name["claude"]["provider"] == "anthropic"
        assert by_name["codex"]["provider"] == "openai"

    def test_provider_round_trips_via_provider_map(
        self, mock_repo: pathlib.Path
    ) -> None:
        (mock_repo / ".env").write_text(
            "ACCOUNT_EMAIL_1=a@b.com\n"
            "ACCOUNT_KEY_1=k1\n"
            "ACCOUNT_TOKEN_FILE_1=one.token\n"
            "ACCOUNT_PROVIDER_1=OpenAI\n",  # mixed case normalizes
            encoding="utf-8",
        )
        bootstrap_tokens(mock_repo)
        pmap = load_provider_map(mock_repo / ".loom" / "tokens")
        assert pmap == {"one": "openai"}

    def test_no_provider_field_defaults_anthropic(
        self, mock_repo: pathlib.Path
    ) -> None:
        # Existing .env files with no ACCOUNT_PROVIDER_N bootstrap as before.
        (mock_repo / ".env").write_text(
            "ACCOUNT_EMAIL_1=a@b.com\n"
            "ACCOUNT_KEY_1=k1\n"
            "ACCOUNT_TOKEN_FILE_1=one.token\n",
            encoding="utf-8",
        )
        result = bootstrap_tokens(mock_repo)
        assert result.written == ["one.token"]
        idx = json.loads(
            (mock_repo / ".loom" / "tokens" / "index.json").read_text()
        )
        assert idx["accounts"][0]["provider"] == "anthropic"

    def test_provider_only_line_is_still_partial_triple(
        self, mock_repo: pathlib.Path
    ) -> None:
        # A lone ACCOUNT_PROVIDER_N does not make an account; the triple
        # (email/key/file) is still required, exactly as today.
        (mock_repo / ".env").write_text(
            "ACCOUNT_PROVIDER_7=openai\n"
            "ACCOUNT_EMAIL_1=a@b.com\n"
            "ACCOUNT_KEY_1=k1\n"
            "ACCOUNT_TOKEN_FILE_1=one.token\n",
            encoding="utf-8",
        )
        result = bootstrap_tokens(mock_repo)
        assert result.written == ["one.token"]

    def test_numbering_gap_with_providers(self, mock_repo: pathlib.Path) -> None:
        (mock_repo / ".env").write_text(
            "ACCOUNT_EMAIL_1=a@b.com\n"
            "ACCOUNT_KEY_1=k1\n"
            "ACCOUNT_TOKEN_FILE_1=one.token\n"
            "ACCOUNT_EMAIL_5=c@d.com\n"
            "ACCOUNT_KEY_5=k5\n"
            "ACCOUNT_TOKEN_FILE_5=five.token\n"
            "ACCOUNT_PROVIDER_5=openai\n",
            encoding="utf-8",
        )
        result = bootstrap_tokens(mock_repo)
        assert sorted(result.written) == ["five.token", "one.token"]
        pmap = load_provider_map(mock_repo / ".loom" / "tokens")
        assert pmap == {"one": "anthropic", "five": "openai"}

    def test_drift_entry_keeps_provider(self, mock_repo: pathlib.Path) -> None:
        (mock_repo / ".env").write_text(
            "ACCOUNT_EMAIL_1=a@b.com\n"
            "ACCOUNT_KEY_1=k1\n"
            "ACCOUNT_TOKEN_FILE_1=one.token\n"
            "ACCOUNT_PROVIDER_1=openai\n",
            encoding="utf-8",
        )
        bootstrap_tokens(mock_repo)
        token_path = mock_repo / ".loom" / "tokens" / "one.token"
        token_path.write_text("tampered", encoding="utf-8")
        bootstrap_tokens(mock_repo)
        idx = json.loads(
            (mock_repo / ".loom" / "tokens" / "index.json").read_text()
        )
        entry = idx["accounts"][0]
        assert entry.get("drift") is True
        assert entry["provider"] == "openai"


# ---------------------------------------------------------------------------
# select: provider filtering
# ---------------------------------------------------------------------------


class TestSelectProviderFilter:
    def test_default_provider_ignores_openai_accounts(
        self, tmp_path: pathlib.Path
    ) -> None:
        ws = _make_workspace(
            tmp_path,
            {"claude-1": "ka", "codex-1": "kb"},
            providers={"claude-1": "anthropic", "codex-1": "openai"},
        )
        for _ in range(10):
            sel = select_token(ws)
            assert sel.name == "claude-1"
            assert sel.provider == "anthropic"

    def test_openai_filter_ignores_anthropic_accounts(
        self, tmp_path: pathlib.Path
    ) -> None:
        ws = _make_workspace(
            tmp_path,
            {"claude-1": "ka", "codex-1": "kb"},
            providers={"claude-1": "anthropic", "codex-1": "openai"},
        )
        for _ in range(10):
            sel = select_token(ws, provider="openai")
            assert sel.name == "codex-1"
            assert sel.provider == "openai"
            assert sel.key == "kb"

    def test_no_index_json_treats_all_as_anthropic(
        self, tmp_path: pathlib.Path
    ) -> None:
        # Backward compat: pool with no index.json behaves exactly as today.
        ws = _make_workspace(tmp_path, {"a": "ka", "b": "kb"}, providers=None)
        sel = select_token(ws, rng=random.Random(42))
        assert sel.name in ("a", "b")
        assert sel.provider == "anthropic"
        with pytest.raises(EmptyTokenPoolError, match="provider 'openai'"):
            select_token(ws, provider="openai")

    def test_account_missing_from_index_treated_as_anthropic(
        self, tmp_path: pathlib.Path
    ) -> None:
        ws = _make_workspace(
            tmp_path,
            {"unindexed": "ka", "codex-1": "kb"},
            providers={"codex-1": "openai"},  # "unindexed" has no entry
        )
        sel = select_token(ws)
        assert sel.name == "unindexed"

    def test_empty_provider_pool_raises(self, tmp_path: pathlib.Path) -> None:
        ws = _make_workspace(
            tmp_path,
            {"claude-1": "ka"},
            providers={"claude-1": "anthropic"},
        )
        with pytest.raises(EmptyTokenPoolError, match="provider 'openai'"):
            select_token(ws, provider="openai")

    def test_ranking_tier_filters_by_provider(
        self, tmp_path: pathlib.Path
    ) -> None:
        # Mixed-provider ranking: the openai account ranks first, but an
        # anthropic selection must skip it and take the next entry.
        ws = _make_workspace(
            tmp_path,
            {"codex-1": "kb", "claude-1": "ka"},
            providers={"claude-1": "anthropic", "codex-1": "openai"},
        )
        rfile = ws / ".loom" / "tokens" / ".ranking"
        payload = {
            "ranked_at": "2026-01-01T00:00:00Z",
            "accounts": [
                {"name": "codex-1", "status": "", "provider": "openai"},
                {"name": "claude-1", "status": "", "provider": "anthropic"},
            ],
        }
        rfile.write_text(json.dumps(payload), encoding="utf-8")
        sel = select_token(ws)
        assert sel.name == "claude-1"
        assert sel.mode == "ranked"
        sel2 = select_token(ws, provider="openai")
        assert sel2.name == "codex-1"
        assert sel2.mode == "ranked"

    def test_allowlist_tier_filters_by_provider(
        self, tmp_path: pathlib.Path
    ) -> None:
        ws = _make_workspace(
            tmp_path,
            {"codex-1": "kb", "claude-1": "ka"},
            providers={"claude-1": "anthropic", "codex-1": "openai"},
        )
        allow = ws / ".loom" / "tokens" / ".allowlist"
        allow.write_text("codex-1\nclaude-1\n", encoding="utf-8")
        for _ in range(10):
            sel = select_token(ws)
            assert sel.name == "claude-1"
            assert sel.mode == "allowlist"

    def test_all_provider_tokens_bad_raises(self, tmp_path: pathlib.Path) -> None:
        ws = _make_workspace(
            tmp_path,
            {"claude-1": "ka", "codex-1": "kb"},
            providers={"claude-1": "anthropic", "codex-1": "openai"},
        )
        bad = ws / ".loom" / "tokens" / ".bad_tokens"
        bad.write_text("2026-01-01T00:00:00Z codex-1 expired\n", encoding="utf-8")
        # anthropic account still selectable
        assert select_token(ws).name == "claude-1"
        with pytest.raises(EmptyTokenPoolError, match="marked bad"):
            select_token(ws, provider="openai")


# ---------------------------------------------------------------------------
# select CLI: provider-appropriate --export env var
# ---------------------------------------------------------------------------


class TestSelectCliExport:
    def _run(self, ws: pathlib.Path, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                sys.executable,
                "-m",
                "loom_tools.tokens.select",
                "--workspace",
                str(ws),
                *extra,
            ],
            capture_output=True,
            text=True,
            check=False,
            env=_cli_env(),
        )

    def test_default_export_emits_claude_var(self, tmp_path: pathlib.Path) -> None:
        ws = _make_workspace(
            tmp_path,
            {"claude-1": "sk-ant-oat01-x"},
            providers={"claude-1": "anthropic"},
        )
        result = self._run(ws, "--export")
        assert result.returncode == 0, result.stderr
        assert "export CLAUDE_CODE_OAUTH_TOKEN=" in result.stdout
        assert "OPENAI_API_KEY" not in result.stdout

    def test_openai_export_emits_openai_var(self, tmp_path: pathlib.Path) -> None:
        ws = _make_workspace(
            tmp_path,
            {"claude-1": "ka", "codex-1": "sk-openai-y"},
            providers={"claude-1": "anthropic", "codex-1": "openai"},
        )
        result = self._run(ws, "--provider", "openai", "--export")
        assert result.returncode == 0, result.stderr
        assert "export OPENAI_API_KEY='sk-openai-y'" in result.stdout
        assert "CLAUDE_CODE_OAUTH_TOKEN" not in result.stdout
        assert "provider=openai" in result.stdout

    def test_json_payload_includes_provider(self, tmp_path: pathlib.Path) -> None:
        ws = _make_workspace(
            tmp_path,
            {"codex-1": "kb"},
            providers={"codex-1": "openai"},
        )
        result = self._run(ws, "--provider", "openai", "--json")
        assert result.returncode == 0, result.stderr
        payload = json.loads(result.stdout)
        assert payload["provider"] == "openai"
        assert payload["name"] == "codex-1"

    def test_openai_empty_pool_exits_78(self, tmp_path: pathlib.Path) -> None:
        ws = _make_workspace(
            tmp_path, {"claude-1": "ka"}, providers={"claude-1": "anthropic"}
        )
        result = self._run(ws, "--provider", "openai", "--json")
        assert result.returncode == 78
        assert "openai" in result.stderr

    def test_unknown_provider_rejected(self, tmp_path: pathlib.Path) -> None:
        ws = _make_workspace(tmp_path, {"a": "ka"})
        result = self._run(ws, "--provider", "gemini", "--json")
        assert result.returncode == 2  # argparse usage error


# ---------------------------------------------------------------------------
# check: openai probe plugin + mixed-provider run_check
# ---------------------------------------------------------------------------


class TestOpenAIProbe:
    def test_200_available(self) -> None:
        with patch("requests.get", return_value=_mock_response(200)):
            r = probe_openai_account("codex-1", "sk-openai-x")
        assert r.status == "available"
        assert r.provider == "openai"

    def test_401_blocked(self) -> None:
        with patch("requests.get", return_value=_mock_response(401)):
            r = probe_openai_account("codex-1", "sk-openai-x")
        assert r.status == "blocked"
        assert r.error == "auth_401"

    def test_429_rate_limited(self) -> None:
        with patch("requests.get", return_value=_mock_response(429)):
            r = probe_openai_account("codex-1", "sk-openai-x")
        assert r.status == "rate_limited"

    def test_timeout_error_not_fatal(self) -> None:
        with patch("requests.get", side_effect=requests.Timeout()):
            r = probe_openai_account("codex-1", "sk-openai-x")
        assert r.status == "error"
        assert r.error == "timeout"

    def test_5xx_error_not_fatal(self) -> None:
        with patch("requests.get", return_value=_mock_response(503)):
            r = probe_openai_account("codex-1", "sk-openai-x")
        assert r.status == "error"
        assert "503" in r.error

    def test_empty_token_blocked(self) -> None:
        r = probe_openai_account("codex-bad", "")
        assert r.status == "blocked"
        assert r.error == "bad_token_listed"

    def test_ignores_anthropic_probe_kwargs(self) -> None:
        # The dispatcher passes model/probe_prompt; openai must ignore them.
        with patch("requests.get", return_value=_mock_response(200)):
            r = probe_openai_account(
                "codex-1",
                "sk-openai-x",
                probe_prompt="hi",
                model="claude-haiku-4-5-20251001",
            )
        assert r.status == "available"


class TestProbeDispatch:
    def test_unknown_provider_is_error_not_probed(self) -> None:
        # Never send a secret to the wrong provider's endpoint.
        with (
            patch("requests.post") as post,
            patch("requests.get") as get,
        ):
            r = probe_account_for_provider("gemini", "g-1", "secret")
        assert r.status == "error"
        assert "no_probe_for_provider" in r.error
        assert r.provider == "gemini"
        post.assert_not_called()
        get.assert_not_called()

    def test_anthropic_dispatch_hits_messages_endpoint(self) -> None:
        headers = {
            "anthropic-ratelimit-tokens-5h-utilization": "0.10",
            "anthropic-ratelimit-tokens-7d-utilization": "0.20",
        }
        with patch(
            "requests.post", return_value=_mock_response(200, headers)
        ) as post:
            r = probe_account_for_provider(
                "anthropic", "claude-1", "sk-ant-oat01-x"
            )
        assert r.status == "available"
        assert r.provider == "anthropic"
        assert post.call_args.args[0].endswith("/v1/messages")


class TestRunCheckMixedProviders:
    def _pool(self, tmp_path: pathlib.Path) -> pathlib.Path:
        (tmp_path / "claude-1.token").write_text("sk-ant-oat01-a")
        (tmp_path / "codex-1.token").write_text("sk-openai-b")
        index = {
            "version": 1,
            "accounts": [
                {"name": "claude-1", "provider": "anthropic"},
                {"name": "codex-1", "provider": "openai"},
            ],
        }
        (tmp_path / "index.json").write_text(json.dumps(index))
        return tmp_path

    def test_mixed_pool_dispatches_per_provider(
        self, tmp_path: pathlib.Path
    ) -> None:
        pool = self._pool(tmp_path)
        headers = {"anthropic-ratelimit-tokens-7d-utilization": "0.10"}
        with (
            patch("requests.post", return_value=_mock_response(200, headers)),
            patch("requests.get", return_value=_mock_response(200)),
        ):
            report = run_check(pool, write_ranking=True, stagger=False)
        by_name = {a.name: a for a in report.accounts}
        assert by_name["claude-1"].status == "available"
        assert by_name["claude-1"].provider == "anthropic"
        assert by_name["codex-1"].status == "available"
        assert by_name["codex-1"].provider == "openai"
        # check --ranking includes all providers.
        ranking = json.loads((pool / ".ranking").read_text())
        assert {a["name"] for a in ranking["accounts"]} == {
            "claude-1",
            "codex-1",
        }
        assert {a["provider"] for a in ranking["accounts"]} == {
            "anthropic",
            "openai",
        }

    def test_openai_probe_failure_does_not_abort_run(
        self, tmp_path: pathlib.Path
    ) -> None:
        pool = self._pool(tmp_path)
        headers = {"anthropic-ratelimit-tokens-7d-utilization": "0.10"}
        with (
            patch("requests.post", return_value=_mock_response(200, headers)),
            patch("requests.get", side_effect=requests.ConnectionError("down")),
        ):
            report = run_check(pool, write_ranking=False, stagger=False)
        by_name = {a.name: a for a in report.accounts}
        assert by_name["claude-1"].status == "available"
        assert by_name["codex-1"].status == "error"

    def test_no_index_probes_everything_as_anthropic(
        self, tmp_path: pathlib.Path
    ) -> None:
        # Backward compat: pre-#12 pool (no index.json) probes exactly as
        # before — every account through the anthropic plugin.
        (tmp_path / "agent-1.token").write_text("sk-ant-oat01-a")
        headers = {"anthropic-ratelimit-tokens-7d-utilization": "0.10"}
        with (
            patch(
                "requests.post", return_value=_mock_response(200, headers)
            ) as post,
            patch("requests.get") as get,
        ):
            report = run_check(tmp_path, write_ranking=False, stagger=False)
        assert report.accounts[0].status == "available"
        assert report.accounts[0].provider == "anthropic"
        assert post.called
        get.assert_not_called()

    def test_account_result_to_dict_includes_provider(self) -> None:
        r = AccountResult("codex-1", "available", provider="openai")
        assert r.to_dict()["provider"] == "openai"

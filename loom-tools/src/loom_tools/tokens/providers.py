"""Per-account provider support for the token pool (#12).

The token pool historically assumed every account was an Anthropic
Claude OAuth account. Epic #1 generalizes it: each account may declare
an optional ``ACCOUNT_PROVIDER_N`` in ``.env`` (recorded by bootstrap in
``index.json``), and downstream consumers — selection, health probes,
operator CLI output — become provider-aware.

Backward compatibility is load-bearing: accounts with no recorded
provider (older ``index.json`` files, or ``.env`` triples without
``ACCOUNT_PROVIDER_N``) are treated as :data:`DEFAULT_PROVIDER`
(``anthropic``) everywhere.

This module is import-safe: no I/O at import time.
"""

from __future__ import annotations

import json
from pathlib import Path

#: Provider assumed for any account that does not declare one.
DEFAULT_PROVIDER = "anthropic"

#: Environment variable each provider's runner expects the credential in.
#: ``anthropic`` -> Claude Code OAuth token; ``openai`` -> Codex API key.
ENV_VAR_BY_PROVIDER: dict[str, str] = {
    "anthropic": "CLAUDE_CODE_OAUTH_TOKEN",
    "openai": "OPENAI_API_KEY",
}

#: Providers with first-class support (``--provider`` choices in select).
KNOWN_PROVIDERS: tuple[str, ...] = tuple(sorted(ENV_VAR_BY_PROVIDER))


def env_var_for_provider(provider: str) -> str | None:
    """Return the export env-var name for *provider*, or None if unknown."""
    return ENV_VAR_BY_PROVIDER.get(provider)


def normalize_provider(raw: str | None) -> str:
    """Normalize a raw provider string; empty/None falls back to default."""
    if raw is None:
        return DEFAULT_PROVIDER
    value = raw.strip().lower()
    return value or DEFAULT_PROVIDER


def load_provider_map(tokens_dir: Path | str) -> dict[str, str]:
    """Return ``{account_name: provider}`` from ``index.json``.

    Accounts absent from the map (or whose entry has no ``provider``
    field — e.g. an ``index.json`` written before #12) default to
    :data:`DEFAULT_PROVIDER` via :func:`provider_of`. A missing or
    unreadable ``index.json`` yields an empty map, which means *every*
    account resolves to the default provider — exactly the pre-#12
    behavior.
    """
    index_path = Path(tokens_dir) / "index.json"
    try:
        data = json.loads(index_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    accounts = data.get("accounts")
    if not isinstance(accounts, list):
        return {}
    pmap: dict[str, str] = {}
    for entry in accounts:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name")
        if not isinstance(name, str) or not name:
            continue
        provider = entry.get("provider")
        pmap[name] = normalize_provider(
            provider if isinstance(provider, str) else None
        )
    return pmap


def provider_of(name: str, pmap: dict[str, str]) -> str:
    """Resolve the provider for *name*, defaulting to :data:`DEFAULT_PROVIDER`."""
    return pmap.get(name, DEFAULT_PROVIDER)

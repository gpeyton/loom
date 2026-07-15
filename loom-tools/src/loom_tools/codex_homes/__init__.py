"""Deterministic selection over a pool of ChatGPT-authenticated Codex
``CODEX_HOME`` profile directories (``LOOM_CODEX_HOMES_DIR``, issue #36).

Complementary to ``loom_tools.tokens`` (the provider-aware OpenAI API-key
pool from #12/#18): this module never handles API keys or ``.token``
files — it only selects a directory from a pool of pre-authenticated
``CODEX_HOME`` profiles, each a directory containing an ``auth.json``
written by a prior ``codex login`` flow.

This module is import-safe: no I/O occurs at import time.
"""

from __future__ import annotations

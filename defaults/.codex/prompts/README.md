# Loom prompts for OpenAI Codex CLI

> **Deprecated (issue #35) — use the `$loom` / `$loom-sweep` skills instead.**
> OpenAI's current Codex guidance deprecates custom prompts in favor of
> **skills**. Loom now ships `../agents/skills/loom/SKILL.md` and
> `../agents/skills/loom-sweep/SKILL.md`, the documented replacement entry
> points, alongside a matching custom agent per role under
> `../agents/loom-<role>.toml`. The prompts below still work and will
> continue to during a one-release transition, but new setups should start
> with the skills, not this directory.

Thin shim prompts that expose the core Loom role entry points as Codex
slash commands. Each shim references the canonical role definition under
`.loom/roles/` (or the sweep skill file) rather than duplicating its
content — the same pattern the repo's `.claude/` shims use, so role
updates land in one place.

## One-time setup (required)

Codex discovers custom prompts ONLY in `$CODEX_HOME/prompts/`
(default `~/.codex/prompts/`); it does not scan this repo-local
directory. Codex also only reads top-level Markdown files there — no
subdirectories. Symlink (or copy) the shims once, from the repo root:

```bash
mkdir -p ~/.codex/prompts
ln -sf "$(pwd)/.codex/prompts/"*.md ~/.codex/prompts/
rm -f ~/.codex/prompts/README.md   # this README is not a prompt
```

Symlinks keep the prompts current when Loom updates them; plain `cp`
works too but needs re-copying after upgrades.

## Invocation

Type `/` in Codex and pick the prompt by filename, passing arguments
after the name — e.g. `/builder 42`, `/judge 123`, `/loom-sweep 42`.
Arguments flow into the shim via the `$ARGUMENTS` placeholder
(positional `$1`–`$9` also work).

## Current limitations (Epic #1, Phase 2)

- **No hooks**: Loom's Claude Code guardrail hooks (`.claude/settings.json`)
  have no Codex hook equivalent — Codex has no hooks system. Their safety
  intent is mapped instead to Codex's native sandbox + approval posture in
  `../config.toml`; see `../GUARDRAIL-PARITY.md` (Epic #1 Phase 3, #20) for the
  hook-by-hook covered / partial / no-equivalent classification and the
  documented residual gaps.
- **No Claude-Code-style Task-tool subagents**: `loom-sweep` under Codex
  runs the lifecycle phases sequentially in one session instead of
  dispatching Task-tool subagents (Epic #1 Phase 3). Current Codex
  clients do expose separate native, in-session collaboration primitives
  (`spawn_agent`, `wait_agent`, etc.) — those are **not** a supported
  Loom orchestration backend (issue #54); parallel Loom work always
  routes to `spawn-codex-wave.sh` instead. See
  `../.claude/commands/loom/sweep.md`'s "Codex backend policy" subsection.
- **Prompts vs skills**: Codex marks custom prompts as deprecated in
  favor of skills. The shims still work during the transition window, but
  the skills port (issue #35) has landed — see the deprecation notice at
  the top of this file for the new entry points.

The MCP server that these roles use for Loom coordination is configured
in `.codex/config.toml` (see its header for setup).

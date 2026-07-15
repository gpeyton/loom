#!/usr/bin/env bash
# Generate .mcp.json with current workspace path
# Builds the unified MCP server if dist/index.js is missing
#
# Usage:
#   ./scripts/setup-mcp.sh                          # Generate .mcp.json (Claude Code)
#   ./scripts/setup-mcp.sh --codex                   # Also emit the Codex CLI MCP entry
#                                                     # into .codex/config.toml
#   ./scripts/setup-mcp.sh --target /path/to/consumer-repo [--codex]
#                                                     # Write .mcp.json / .codex/config.toml
#                                                     # into a consumer repository instead of
#                                                     # this Loom source checkout, with
#                                                     # LOOM_WORKSPACE pointed at the consumer.
#                                                     # --workspace is accepted as an alias.
#
# The mcp-loom invocation (command/args/env) defined here is the single
# source of truth for BOTH runtimes: the `loom` server entry in .mcp.json
# (Claude Code) and the `[mcp_servers.loom]` entry in .codex/config.toml
# (OpenAI Codex CLI) are generated from the same variables below. See
# defaults/.codex/config.toml for the Codex-side documentation.
#
# `mcp-loom` itself only ever lives in the Loom SOURCE checkout (it is not
# installed into consumer repos), so args always point at this checkout's
# mcp-loom/dist/index.js regardless of --target. Only the OUTPUT location
# (where .mcp.json / .codex/config.toml get written) and LOOM_WORKSPACE
# (the env var mcp-loom uses to find the repo it operates on) move to the
# target when --target/--workspace is given. See issue #49 finding 7.

set -euo pipefail

EMIT_CODEX=false
TARGET_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex)
      EMIT_CODEX=true
      shift
      ;;
    --target|--workspace)
      if [[ $# -lt 2 ]]; then
        echo "Error: $1 requires a path argument" >&2
        exit 2
      fi
      TARGET_ARG="$2"
      shift 2
      ;;
    --target=*|--workspace=*)
      TARGET_ARG="${1#*=}"
      shift
      ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1 (supported: --codex, --target/--workspace <path>)" >&2
      exit 2
      ;;
  esac
done

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The Loom SOURCE checkout root (parent of scripts/) -- mcp-loom always
# lives here, regardless of --target.
LOOM_SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# OUTPUT_TARGET is where .mcp.json / .codex/config.toml get written, and
# what LOOM_WORKSPACE gets set to. Defaults to the Loom source checkout
# itself (unchanged, self-targeting behavior) unless --target/--workspace
# names a consumer repository.
if [[ -n "$TARGET_ARG" ]]; then
  # Expand tilde and resolve to an absolute path; must already exist.
  TARGET_ARG="${TARGET_ARG/#\~/$HOME}"
  if [[ ! -d "$TARGET_ARG" ]]; then
    echo "Error: --target/--workspace directory does not exist: $TARGET_ARG" >&2
    exit 2
  fi
  OUTPUT_TARGET="$(cd "$TARGET_ARG" && pwd)"
else
  OUTPUT_TARGET="$LOOM_SOURCE_ROOT"
fi

MCP_DIR="$LOOM_SOURCE_ROOT/mcp-loom"
MCP_ENTRY="$MCP_DIR/dist/index.js"

# Build the unified MCP server if not already built
if [[ ! -f "$MCP_ENTRY" ]]; then
  echo "MCP server not built, building mcp-loom..."
  if command -v node &> /dev/null; then
    (cd "$MCP_DIR" && npm install --silent && npm run build) || {
      echo "Warning: Failed to build mcp-loom. MCP tools will not be available." >&2
      echo "  Run manually: cd mcp-loom && npm install && npm run build" >&2
      exit 1
    }
    echo "MCP server built successfully"
  else
    echo "Warning: node not found. Cannot build mcp-loom." >&2
    echo "  Install Node.js and run: cd mcp-loom && npm install && npm run build" >&2
    exit 1
  fi
fi

# Single source of truth for the mcp-loom server invocation. Both the
# .mcp.json generation below and the --codex emission reuse these values.
# MCP_ARG always points at the source checkout (mcp-loom is never installed
# into consumer repos); MCP_ENV_LOOM_WORKSPACE follows OUTPUT_TARGET so
# mcp-loom operates on the intended repository.
MCP_COMMAND="node"
MCP_ARG="$MCP_ENTRY"
MCP_ENV_LOOM_WORKSPACE="$OUTPUT_TARGET"

# Generate .mcp.json with unified loom server
cat > "$OUTPUT_TARGET/.mcp.json" <<EOF
{
  "mcpServers": {
    "loom": {
      "command": "$MCP_COMMAND",
      "args": ["$MCP_ARG"],
      "env": {
        "LOOM_WORKSPACE": "$MCP_ENV_LOOM_WORKSPACE"
      }
    }
  }
}
EOF

echo "Generated .mcp.json with unified loom MCP server"
echo "  Output:    $OUTPUT_TARGET/.mcp.json"
echo "  Workspace: $MCP_ENV_LOOM_WORKSPACE"
echo "  Server:    $MCP_ARG"

# Optionally emit the same server entry for OpenAI Codex CLI.
#
# Codex natively loads project-scoped config from <repo>/.codex/config.toml
# for trusted projects (see defaults/.codex/config.toml for the resolution
# rules). The entry is written inside a marker-delimited block so re-running
# this script is idempotent and hand-authored content around the block is
# preserved.
if [[ "$EMIT_CODEX" == "true" ]]; then
  CODEX_DIR="$OUTPUT_TARGET/.codex"
  CODEX_CONFIG="$CODEX_DIR/config.toml"
  BEGIN_MARKER="# BEGIN LOOM MCP (generated by scripts/setup-mcp.sh --codex)"
  END_MARKER="# END LOOM MCP"

  mkdir -p "$CODEX_DIR"

  CODEX_BLOCK="$BEGIN_MARKER
# Do not edit inside this block — regenerate with: ./scripts/setup-mcp.sh --codex
# Must match the loom server entry in .mcp.json (same script, same variables).
[mcp_servers.loom]
command = \"$MCP_COMMAND\"
args = [\"$MCP_ARG\"]

[mcp_servers.loom.env]
LOOM_WORKSPACE = \"$MCP_ENV_LOOM_WORKSPACE\"
$END_MARKER"

  if [[ -f "$CODEX_CONFIG" ]] && grep -qF "$BEGIN_MARKER" "$CODEX_CONFIG"; then
    # Regenerate: strip the previous marker block (BSD awk can't take a
    # multi-line -v value, so we strip-then-append rather than replace
    # in place), preserve everything else, and append the fresh block.
    tmp_file="$(mktemp)"
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
      $0 == begin { inblock = 1; next }
      $0 == end   { inblock = 0; next }
      !inblock    { print }
    ' "$CODEX_CONFIG" > "$tmp_file"
    printf '%s\n' "$CODEX_BLOCK" >> "$tmp_file"
    mv "$tmp_file" "$CODEX_CONFIG"
    echo "Updated Codex MCP entry in .codex/config.toml"
  elif [[ -f "$CODEX_CONFIG" ]]; then
    # Existing config without our block (e.g. the installed template with
    # the commented-out entry) — append the block.
    printf '\n%s\n' "$CODEX_BLOCK" >> "$CODEX_CONFIG"
    echo "Appended Codex MCP entry to .codex/config.toml"
  else
    printf '%s\n' "$CODEX_BLOCK" > "$CODEX_CONFIG"
    echo "Generated .codex/config.toml with loom MCP entry"
  fi
  echo "  Codex config: $CODEX_CONFIG"
  echo "  Note: Codex loads repo-local .codex/config.toml for TRUSTED projects only."
fi

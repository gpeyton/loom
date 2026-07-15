# Migrating from `rjwalters/loom` v0.9.x

This guide is for an existing consumer repository whose Loom source checkout
still points at `rjwalters/loom`, especially installations created from a
v0.9.x tag. The v0.10 line removes the Python daemon/shepherd brain, adds the
Rust daemon MCP surface, and supports Claude Code and Codex as co-equal worker
runtimes.

Do not treat this as a clean reinstall. Consumer repositories often contain
project-owned hooks, role configuration, worktree cleanup, or safety rules
inside directories that Loom also manages. An uninstall-first upgrade can
delete those changes before there is a diff to review.

## 1. Inventory the current installation

Run these commands from the consumer repository before changing either
checkout:

```bash
target="$(pwd)"
source_path="$(cat .loom/loom-source-path 2>/dev/null || true)"

git status --short
git diff -- .loom .claude .codex .agents CLAUDE.md AGENTS.md loom.sh

if [ -n "$source_path" ] && [ -d "$source_path" ]; then
  git -C "$source_path" remote -v
  git -C "$source_path" describe --tags --always --dirty
  git -C "$source_path" status --short
fi
```

Record any files that intentionally differ from the installed defaults. Pay
particular attention to:

- `.loom/hooks/` and `.claude/settings.json`;
- `.loom/scripts/agent-destroy.sh`, `merge-pr.sh`, and worktree helpers;
- `.loom/config.json` and custom role files;
- root `CLAUDE.md` and `AGENTS.md` project constraints;
- `.mcp.json` and `.codex/config.toml`;
- project-specific daemon/service wrappers.

If the old source checkout is dirty or detached, leave it in place. It is a
useful rollback and comparison point.

## 2. Back up the consumer payload

The backup must include untracked files as well as Git diffs:

```bash
backup="$HOME/loom-migration-backups/$(basename "$target")-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup"

git status --short > "$backup/git-status.txt"
git diff > "$backup/tracked.patch"
git diff --cached > "$backup/staged.patch"

for path in .loom .claude .codex .agents CLAUDE.md AGENTS.md loom.sh .mcp.json; do
  if [ -e "$target/$path" ]; then
    cp -R "$target/$path" "$backup/"
  fi
done

printf 'Backup: %s\n' "$backup"
```

Commit or stash unrelated application changes separately. Do not rely only on
the installed-file manifest: older manifests could include consumer-owned
files, and a patch does not contain untracked files.

## 3. Clone the fork separately

Use a new checkout instead of repointing or overwriting the legacy one:

```bash
git clone https://github.com/gpeyton/loom.git "$HOME/.loom-engine-gpeyton"
cd "$HOME/.loom-engine-gpeyton"
git switch main
git pull --ff-only
```

Keeping distinct checkout paths makes rollback explicit and prevents a dirty
v0.9 checkout from contaminating the new build.

## 4. Build the v0.10 toolchain

```bash
cd "$HOME/.loom-engine-gpeyton"
corepack pnpm install --frozen-lockfile
pnpm daemon:build

cd mcp-loom
npm ci
npm run build
cd ..

cargo install --path loom-daemon --root "$HOME/.local" --force
./scripts/install/setup-python-tools.sh --loom-root "$HOME/.loom-engine-gpeyton"
```

Make the new Python helpers win over stale v0.9 shims. Adding the venv to
`PATH` is the least destructive option:

```bash
export PATH="$HOME/.loom-engine-gpeyton/loom-tools/.venv/bin:$HOME/.local/bin:$PATH"
hash -r

command -v loom-daemon
command -v loom-cleanup
command -v loom-orphan-recovery
loom-daemon --version
```

Loom retains `loom-recover-orphans` as a v0.10.6 compatibility alias, but
`loom-orphan-recovery` is the canonical spelling.

If shell startup files or `~/.local/bin/loom-*` symlinks point directly into
the old checkout, update them deliberately after verifying the new venv. Do
not overwrite a regular executable that is unrelated to Loom.

## 5. Apply the new payload without an uninstall-first quick reinstall

For customized legacy consumers, do **not** begin with:

```bash
./install.sh --quick "$target"
```

That path detects the existing `.loom/` directory and uninstalls it before
initialization. Use one of these reviewable approaches instead.

### Option A: full install workflow

Run the lower-level installer without `--clean`. It builds the update in a
worktree and presents the result as a pull request:

```bash
cd "$HOME/.loom-engine-gpeyton"
./scripts/install-loom.sh --yes "$target"
```

Review the PR against the backup and restore consumer-owned behavior before
merging.

### Option B: direct local initialization

For a local migration that will be reviewed as a normal Git diff:

```bash
cd "$HOME/.loom-engine-gpeyton"
version="$(node -p 'require("./package.json").version')"
commit="$(git rev-parse --short HEAD)"

LOOM_VERSION="$version" LOOM_COMMIT="$commit" \
  ./target/release/loom-daemon init --force \
  --defaults ./defaults "$target"

printf '%s\n' "$HOME/.loom-engine-gpeyton" > "$target/.loom/loom-source-path"
```

The initializer updates managed files but leaves Git with a reviewable diff.
Do not commit until project-owned protections have been reconciled.

## 6. Reconcile project-owned changes

Compare the new payload with the backup file by file. Port behavior into the
v0.10 scripts instead of copying entire v0.9 orchestration files back: the
Shepherd and Python daemon surfaces no longer exist.

Common intentional customizations include:

- destructive-command parsing and Unicode-normalized path checks;
- worktree removal that returns non-zero when cleanup fails;
- custom roles or mixed Claude/Codex terminal assignments;
- application-specific database, CI, deployment, and production constraints;
- service-manager configuration for the Rust daemon.

Remove deprecated Shepherd files only after confirming no custom content is
being lost. See
[`v0.10.0-shepherd-deprecation.md`](v0.10.0-shepherd-deprecation.md) for the
old-to-new command mapping.

## 7. Configure Claude and Codex against the consumer workspace

Both clients must launch the same built MCP server with the **consumer**
repository as `LOOM_WORKSPACE`. Absolute paths are machine-specific and
should normally remain local configuration.

Claude's `.mcp.json` entry has this shape:

```json
{
  "mcpServers": {
    "loom": {
      "command": "node",
      "args": ["/home/you/.loom-engine-gpeyton/mcp-loom/dist/index.js"],
      "env": {
        "LOOM_WORKSPACE": "/path/to/consumer-repository"
      }
    }
  }
}
```

Merge the `loom` key into an existing `.mcp.json`; do not discard unrelated
servers. Approve the project-scoped server when Claude first prompts.

Codex's project `.codex/config.toml` entry is equivalent:

```toml
[mcp_servers.loom]
command = "node"
args = ["/home/you/.loom-engine-gpeyton/mcp-loom/dist/index.js"]

[mcp_servers.loom.env]
LOOM_WORKSPACE = "/path/to/consumer-repository"
```

Trust the consumer repository in Codex, then restart both clients so they
reload project configuration.

## 8. Start and validate the Rust daemon

The v0.10 daemon runs when `loom-daemon` is invoked without a subcommand. Run
it in the foreground first so startup failures are visible:

```bash
cd "$target"
LOOM_WORKSPACE="$target" RUST_LOG=info loom-daemon
```

After the foreground smoke test, run it under your normal service manager
(`launchd`, `systemd`, or another supervised process). In v0.10.6,
`defaults/scripts/start-daemon.sh` and `stop-daemon.sh` still reference the
removed `daemon.sh`; do not use those generated compatibility wrappers until
issue #47 is resolved.

In a separate terminal, validate the migrated repository:

```bash
cd "$target"
loom-daemon validate . --strict --verbose
./.loom/scripts/validate-toolchain.sh
./.loom/hooks/test-guard-destructive.sh
./.loom/scripts/tests/test-codex-parity.sh
./.loom/scripts/tests/test-spawn-worker.sh
claude mcp get loom
codex mcp get loom
git diff --check
git status --short
```

Expected manifest drift is not automatically a failure: customized consumer
files should differ from upstream defaults. Investigate every mismatch rather
than restoring defaults blindly.

## Rollback

Stop the new daemon, restore the consumer payload from the backup, restore the
old `.loom/loom-source-path`, and put the old venv or shims back on `PATH`.
Because the legacy source checkout was preserved, rollback does not require a
network fetch or reconstruction of a dirty detached checkout.

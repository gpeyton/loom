# Getting Started with Loom

This comprehensive guide walks you through installing and setting up Loom, whether you're an end user wanting to use Loom in your repository or a contributor building Loom itself.

## Table of Contents

- [Before You Install](#before-you-install)
- [Prerequisites](#prerequisites)
- [Installation Options](#installation-options)
  - [Option 1: Download Binary (Easiest)](#option-1-download-binary-easiest)
  - [Option 2: Build from Source](#option-2-build-from-source)
  - [Option 3: Interactive Install Script](#option-3-interactive-install-script)
  - [Option 4: GUI Application](#option-4-gui-application)
- [First-Time Setup](#first-time-setup)
- [Verifying Your Setup](#verifying-your-setup)
- [Next Steps](#next-steps)
- [Using Codex with Loom](#using-codex-with-loom)
- [Troubleshooting](#troubleshooting)

## Before You Install

### What Loom Does

Loom transforms your repository into an AI-orchestrated workspace where agents coordinate through GitHub issues, PRs, and labels. Each terminal can embody a specialized role (Worker, Curator, Architect, Reviewer) working autonomously or on-demand.

### Supported worker runtimes: Claude Code and OpenAI Codex CLI

Loom supports **two co-equal worker runtimes** — [Claude Code](https://claude.com/claude-code) and the [OpenAI Codex CLI](https://developers.openai.com/codex). Neither is "primary": the coordination layer Loom depends on (GitHub/Gitea labels, git worktrees, the sweep lifecycle, the merge scripts) is runtime-neutral and behaves identically regardless of which runtime a worker uses. What differs is the per-runtime *setup* and a small set of runtime-specific dispatch surfaces:

- **Claude Code** discovers Loom roles as slash commands under `.claude/commands/loom/` and reads repository context from `CLAUDE.md`.
- **OpenAI Codex CLI** discovers repository context from `AGENTS.md` (via AGENTS.md ancestor traversal) and Loom role prompts from a project-scoped `.codex/` config plus prompt shims. See [Using Codex with Loom](#using-codex-with-loom) below for the full setup.

Both runtimes participate in the same label-driven workflow, and both get **unrestricted permissions by default** for Loom-spawned automation — Claude Code via `--dangerously-skip-permissions`, Codex via `--dangerously-bypass-approvals-and-sandbox` (set `LOOM_CODEX_SAFE=1` to opt Codex back into a sandboxed `--full-auto` posture). Where a runtime has a gap relative to the other — most notably Claude Code's guardrail hooks vs. Codex's sandbox/approval model — the safety mapping, trust-boundary rationale, and residual gaps are captured in [`defaults/.codex/GUARDRAIL-PARITY.md`](../../defaults/.codex/GUARDRAIL-PARITY.md) and summarized under [Using Codex with Loom](#using-codex-with-loom).

### What Gets Installed

Running `loom-daemon init` creates these files in your repository:

**Configuration (Commit these)**:
- `.loom/config.json` - Terminal settings and role assignments
- `.loom/roles/` - Custom agent role definitions (optional)

**Documentation (Commit these)**:
- `CLAUDE.md` - AI context document for Claude Code (11KB template)
- `AGENTS.md` - AI context document for OpenAI Codex and other AGENTS.md-aware runtimes

**Tooling (Commit these)**:
- `.claude/commands/loom/` - Claude Code slash commands for each role
- `.codex/` - Codex config (`config.toml`), prompt shims (`.codex/prompts/`, deprecated — see below), and custom agents (`.codex/agents/*.toml`)
- `.agents/skills/` - Codex skills (`loom`, `loom-sweep`) — the documented Codex entry point, replacing the deprecated `.codex/prompts/` shims
- `.github/labels.yml` - Workflow label definitions

**Gitignored (Local only)**:
- `.loom/state.json` - Runtime terminal state
- `.loom/worktrees/` - Git worktrees for isolated work
- `.loom/*.log` - Application log files

### What Gets Modified

- **`.gitignore`** - Adds patterns for `.loom/state.json`, `.loom/worktrees/`, `~/.loom/console.log`, etc.

That's it! Loom is non-invasive and everything important can be committed to version control so your team shares the same agent configuration.

## Prerequisites

### For End Users (Using Loom)

Minimal requirements to use Loom:

1. **macOS** (currently macOS-only, Linux support planned)
2. **Git repository** (any existing project)
3. **tmux** (usually pre-installed on macOS)
   ```bash
   # Verify tmux is installed
   tmux -V

   # Install if needed (macOS)
   brew install tmux
   ```
4. **A worker runtime** (optional, for AI agents) — either is a supported, co-equal choice:

   **Claude Code:**
   ```bash
   # Verify Claude Code is installed
   claude --version

   # See https://claude.com/claude-code for installation
   ```

   **OpenAI Codex CLI** (equal alternative):
   ```bash
   # Verify the Codex CLI is installed
   codex --version

   # Install via npm: npm install -g @openai/codex
   # See https://developers.openai.com/codex for installation
   ```

   You do not need both — pick the runtime you prefer. Codex setup (project trust,
   `.codex/config.toml`, the `$loom` / `$loom-sweep` skills, MCP config) is covered in
   [Using Codex with Loom](#using-codex-with-loom). The Claude-vs-Codex safety-model
   mapping (hooks vs. sandbox/approval) and the full-autonomy-by-default trust boundary
   live in [`defaults/.codex/GUARDRAIL-PARITY.md`](../../defaults/.codex/GUARDRAIL-PARITY.md).

That's all you need to use Loom!

### Requirements by Installation Method

The minimal list above applies when using a prebuilt `loom-daemon`. Installing
from a source checkout has additional build-time requirements:

| Installation path | Additional requirements |
|-------------------|--------------------------|
| Prebuilt binary | None |
| `install.sh` or source build | Node.js, pnpm, and Rust/Cargo |
| MCP server | Node.js and npm |
| Python helper/validation commands | Python 3.10+ |

The Quick Install path checks for the source-build toolchain and intentionally
does not install the Python helper environment. Run
`scripts/install/setup-python-tools.sh` when commands such as
`loom-orphan-recovery` and `loom-cleanup` are required.

### For Contributors (Developing Loom)

Additional requirements to build and contribute to Loom:

1. **Rust** (for daemon and api compilation)
   ```bash
   # Install Rust via rustup (recommended)
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

   # Verify installation
   rustc --version
   cargo --version
   ```

2. **System Dependencies**

   **macOS:**
   ```bash
   xcode-select --install
   ```

   **Linux (Ubuntu/Debian):**
   ```bash
   sudo apt update
   sudo apt install build-essential pkg-config libssl-dev
   ```

3. **Node.js** (v18 or later, for mcp-loom)
   ```bash
   # Install via nvm (recommended)
   nvm install 18

   # Verify installation
   node --version  # Should be v18+
   ```

4. **pnpm** (package manager)
   ```bash
   npm install -g pnpm

   # Verify installation
   pnpm --version
   ```

5. **GitHub CLI** (optional, for agent workflows)
   ```bash
   # macOS
   brew install gh

   # Linux - see https://cli.github.com/

   # Authenticate
   gh auth login
   ```

To verify all prerequisites:

```bash
# Check Rust (contributors only)
rustc --version && cargo --version

# Check Node.js (contributors only)
node --version

# Check pnpm (contributors only)
pnpm --version

# Check tmux (all users)
tmux -V

# Check Claude Code (optional)
claude --version

# Check GitHub CLI (optional)
gh --version
```

## Installation Options

> **Existing `rjwalters/loom` v0.9.x installation:** use the
> [legacy migration guide](../migration/from-rjwalters-v0.9.md) before running
> the interactive installer. The normal reinstall path removes the existing
> payload first and can erase consumer-owned customizations that were stored
> under Loom-managed directories.

Choose the installation method that best fits your needs:

### Option 1: Download Binary (Easiest)

Perfect for end users who want to use Loom without building from source.

```bash
# Download latest release
curl -L https://github.com/gpeyton/loom/releases/latest/download/loom-daemon -o loom-daemon
chmod +x loom-daemon

# Initialize your repository
./loom-daemon init /path/to/your/repo
```

**What this does:**
- Downloads the pre-built daemon binary
- Makes it executable
- Initializes your repository with Loom configuration

**Next:** See [First-Time Setup](#first-time-setup) to explore what was created.

### Option 2: Build from Source

For contributors or users who want the latest development version.

```bash
# Clone Loom to a persistent path used by consumer launchers
git clone https://github.com/gpeyton/loom "$HOME/.loom-engine-gpeyton"
cd "$HOME/.loom-engine-gpeyton"

# Build daemon
pnpm daemon:build

# Initialize your repository
./target/release/loom-daemon init /path/to/your/repo
```

**What this does:**
- Clones the Loom source code
- Builds the Rust daemon from source
- Initializes your repository

Keep this checkout after initialization. The installer records its absolute
path in the consumer's gitignored `.loom/loom-source-path`, and installed
Claude/Codex launchers consult that pointer when resolving shared tooling.

After pulling a newer Loom commit, rerun `pnpm daemon:build` before
reinstalling. Quick Install only builds the daemon when the release binary is
absent; an existing binary is not proof that it was built from the current
source commit.

**Next:** See [DEVELOPMENT.md](development.md) for development workflow.

### Option 3: Interactive Install Script (Recommended)

Uses the interactive install script for guided installation with two workflows.

```bash
# Clone Loom first (if you haven't)
git clone https://github.com/gpeyton/loom "$HOME/.loom-engine-gpeyton"
cd "$HOME/.loom-engine-gpeyton"

# Run interactive installer (will prompt for target repo if not provided)
./install.sh

# Or specify target repository directly
./install.sh /path/to/your/repo
```

> **Existing `.loom/` directory:** the installer enters its reinstall path.
> Quick/non-interactive flags do not make that path non-destructive. Inventory
> and back up project-owned hooks, scripts, roles, `CLAUDE.md`, and `AGENTS.md`
> policy before continuing; use the legacy migration guide for v0.9-shaped
> consumers.

**What this provides:**
- Interactive prompts for repository path
- Shows exactly what will be installed before proceeding
- Two installation methods:
  - **Quick Install (Option 1)**: Direct installation with `loom-daemon init`
  - **Full Install (Option 2)**: Automated workflow with GitHub issue, worktree, and PR
- Git repository validation
- GitHub authentication checks (for Full Install)
- Confirmation prompts at each step
- Clear error messages and recovery suggestions

**When to use Quick Install:**
- Personal projects or quick testing
- Solo development
- No need for GitHub issue tracking
- Want minimal setup

**When to use Full Install:**
- Team projects requiring review
- Want installation tracked in GitHub issue and PR
- Prefer git worktree isolation for clean separation
- Need labels automatically synced to repository
- Want to review changes before merging

The Full Install workflow:
1. Creates a GitHub issue to track the installation
2. Creates a git worktree for isolated work
3. Runs `loom-daemon init` in the worktree
4. Syncs GitHub labels from `.github/labels.yml`
5. Creates a pull request with all changes
6. Automatic cleanup if any step fails

**Advanced:** For programmatic installation without prompts, use:
```bash
# Automated full workflow (no interactive prompts)
./scripts/install-loom.sh /path/to/your/repo
```

This runs the complete Full Install workflow automatically.

**Next:** Review the output to understand what was created.

### Initialization Flags

The `loom-daemon init` command supports several flags for customization:

```bash
# Initialize current directory
loom-daemon init

# Initialize specific repository
loom-daemon init /path/to/your/repo

# Preview changes without applying them
loom-daemon init --dry-run

# Overwrite existing .loom directory
loom-daemon init --force

# Use custom defaults directory
loom-daemon init --defaults ./custom-defaults
```

## First-Time Setup

After installing Loom (via GUI or CLI), you'll find the following files in your repository:

### Workspace Configuration (`.loom/`)

```
.loom/
├── config.json       # Terminal configurations, roles, agent counter
├── roles/            # Custom role definitions (initially empty)
└── README.md         # Documentation about .loom directory
```

**What to do:**
1. Review `config.json` to understand default terminal setup
2. Leave `roles/` empty unless you want custom role definitions
3. Read `.loom/README.md` for configuration guidance

### AI Context Documentation

```
CLAUDE.md             # Technical context for Claude Code agents
AGENTS.md             # Technical context for OpenAI Codex and other AGENTS.md-aware agents
```

**What to do:**
1. Review `CLAUDE.md` (Claude Code) and/or `AGENTS.md` (Codex) to understand the codebase structure and patterns
2. Update both files with project-specific context as you build — they cover the same runtime-neutral coordination mechanics (labels, worktrees, sweep lifecycle), so keep them in sync

The installer can preserve marker-delimited content, but it cannot infer that a
Claude-only policy block must be translated into an equivalent Codex policy.
Mirror owner-mandated safety, deployment, concurrency, and production
constraints in both root files so switching runtimes cannot weaken them.

### Claude Code Configuration

```
.claude/
├── commands/
│   └── loom/         # Loom slash commands for Claude Code
└── README.md         # Documentation
```

**What to do:**
1. Explore available slash commands in `.claude/commands/loom/`
2. Add custom slash commands for your project
3. See [Claude Code docs](https://docs.claude.com/en/docs/claude-code) for details

### GitHub Configuration

```
.github/
├── labels.yml        # Label definitions for workflow coordination
└── workflows/        # CI/CD workflow templates
```

**What to do:**
1. Review label definitions in `labels.yml`
2. Sync labels to GitHub: `gh label sync -f .github/labels.yml`
3. Customize labels for your project's workflow

### Gitignore Updates

Loom automatically updates `.gitignore` with ephemeral patterns:

```gitignore
# Loom - AI Development Orchestration
.loom/state.json
.loom/worktrees/
.loom/*.log
.loom/*.sock
```

**What to commit:**
- ✅ `.loom/config.json` - Share terminal roles across team
- ✅ `.loom/roles/` - Custom role definitions
- ✅ `CLAUDE.md` - AI context documentation (Claude Code)
- ✅ `AGENTS.md` - AI context documentation (OpenAI Codex)
- ✅ `.claude/` - Slash commands and config
- ✅ `.github/` - Labels and workflows

**What to gitignore:**
- ❌ `.loom/state.json` - Runtime state (session IDs, ephemeral data)
- ❌ `.loom/worktrees/` - Git worktrees (temporary workspaces)
- ❌ `.loom/*.log` - Log files
- ❌ `.loom/*.sock` - Unix socket files

## Verifying Your Setup

After installation, verify everything is working correctly:

### 1. Check File Structure

```bash
# Verify .loom directory structure
tree .loom

# Expected output:
# .loom
# ├── README.md
# ├── config.json
# └── roles
#     ├── architect.md
#     ├── builder.md
#     ├── curator.md
#     ├── driver.md
#     ├── guide.md
#     ├── doctor.md
#     ├── hermit.md
#     └── judge.md
```

### 2. Check Configuration

```bash
# View config file (should have default terminals)
cat .loom/config.json

# Expected: JSON with nextAgentNumber and terminals array
```

### 3. Verify Gitignore

```bash
# Check gitignore was updated
grep -A 4 "Loom - AI Development Orchestration" .gitignore

# Expected:
# # Loom - AI Development Orchestration
# .loom/state.json
# .loom/worktrees/
# .loom/*.log
# .loom/*.sock
```

### 4. Test Daemon (Optional)

```bash
# Start daemon manually
loom-daemon start

# Check health
loom-daemon health

# Stop daemon
loom-daemon stop
```

### 5. Launch GUI (If Installed)

```bash
# Launch with current directory as workspace
open -a Loom --args --workspace $(pwd)

# Or launch and select workspace via UI
open -a Loom
```

## Next Steps

Now that Loom is installed and configured, you can:

### 1. Create Agent Terminals

**Via GUI:**
1. Click "+" button to add terminals
2. Click settings icon on each terminal
3. Assign roles (Builder, Judge, Curator, etc.)
4. Configure autonomous intervals if desired

**Via CLI:**
- Manually edit `.loom/config.json` to add terminals
- Define role assignments and autonomous settings
- Restart Loom to load new configuration

### 2. Set Up GitHub Labels

```bash
# Sync Loom workflow labels to GitHub
gh label sync -f .github/labels.yml

# Verify labels were created
gh label list | grep "loom:"
```

Labels enable workflow coordination between agents. See [WORKFLOWS.md](../workflows.md) for details.

### 3. Start Using Agents

#### Manual Mode (Builder, Doctor, Driver)

```bash
# Launch Claude Code with a role
claude --role builder

# Follow the Builder workflow
# 1. Find "loom:ready" issue
# 2. Claim issue (add "loom:building" label)
# 3. Create worktree: pnpm worktree <issue-number>
# 4. Implement, test, commit
# 5. Create PR with "loom:review-requested" label
```

#### Autonomous Mode (Judge, Curator, Architect, Hermit, Guide)

These roles run automatically at configured intervals:

- **Judge** (5 min) - Reviews PRs with `loom:review-requested`
- **Curator** (5 min) - Enhances issues, marks as `loom:ready`
- **Architect** (15 min) - Creates `loom:architect` proposals
- **Hermit** (15 min) - Identifies bloat, creates `loom:hermit` issues
- **Guide** (15 min) - Prioritizes issues with `loom:priority-*` labels

Configure intervals via terminal settings in the GUI.

### 4. Customize Roles

Create custom role definitions for your project:

```bash
# Create custom role
cat > .loom/roles/my-role.md <<'EOF'
# My Custom Role

You are a specialist in the {{workspace}} repository.

## Your Role

[Define the role's purpose and responsibilities]

## Your Workflow

[Define the workflow steps]
EOF

# Create metadata (optional)
cat > .loom/roles/my-role.json <<'EOF'
{
  "name": "My Custom Role",
  "description": "Brief description",
  "defaultInterval": 600000,
  "defaultIntervalPrompt": "Continue working",
  "autonomousRecommended": true,
  "suggestedWorkerType": "claude"
}
EOF
```

See [defaults/roles/README.md](../../defaults/roles/README.md) for role creation guidance.

### 5. Learn the Workflows

Read the comprehensive workflow documentation:

- [WORKFLOWS.md](../workflows.md) - Agent coordination patterns
- [Agent Archetypes](../philosophy/agent-archetypes.md) - Role philosophy
- [Git Workflow](git-workflow.md) - Branch strategy and PR process

## Using Codex with Loom

Loom installs OpenAI Codex CLI support alongside the Claude Code
configuration: a project-scoped `.codex/config.toml`, a custom agent per
role under `.codex/agents/*.toml`, and — the documented entry point for
new setups — Codex **skills** under `.agents/skills/loom/` and
`.agents/skills/loom-sweep/`. Codex runs with **unrestricted permissions
by default** (`--dangerously-bypass-approvals-and-sandbox`, no sandbox,
no approval prompts), matching the Claude Code default
(`--dangerously-skip-permissions`). Set `LOOM_CODEX_SAFE=1` in the
environment to opt a Codex worker back into a sandboxed `--full-auto`
posture. See [`defaults/.codex/GUARDRAIL-PARITY.md`](../../defaults/.codex/GUARDRAIL-PARITY.md)
for the full trust-boundary rationale and the hook-by-hook safety mapping
against Claude Code's guardrail hooks.

### Config placement: repo-local `.codex/config.toml` (vs `~/.codex` merge)

Codex reads user-level config from `~/.codex/config.toml` (or
`$CODEX_HOME/config.toml` if you relocate the Codex home), and it
natively loads **project-scoped overrides** from a repo-local
`.codex/config.toml` — but only for projects you have marked as
**trusted** in Codex. Loom relies on that native mechanism: trust the
repo in Codex and the installed `.codex/config.toml` is picked up
automatically. No merge into `~/.codex/config.toml` is required, and you
should avoid `CODEX_HOME=$(pwd)/.codex codex` (it drags auth and session
state into the repo tree).

The `loom` MCP server entry ships commented out because the `mcp-loom`
server lives in the Loom source checkout at a machine-specific path. For
the Loom source repository itself, you can materialize it with:

```bash
./scripts/setup-mcp.sh --codex
```

This writes an absolute-path `[mcp_servers.loom]` entry (idempotent,
marker-delimited) generated from the same variables as the Claude Code
`.mcp.json`.

For a **consumer repository**, run `setup-mcp.sh` from the Loom source
checkout with `--target`/`--workspace` pointed at the consumer repo:

```bash
./scripts/setup-mcp.sh --codex --target /path/to/consumer-repository
```

This writes `.mcp.json` / `.codex/config.toml` into the *consumer* repository
(not the Loom checkout) with `LOOM_WORKSPACE` set to the consumer path, while
`args` still points at `mcp-loom/dist/index.js` inside the Loom source
checkout (`mcp-loom` is never installed into consumer repos). The generated
entry looks like:

```toml
[mcp_servers.loom]
command = "node"
args = ["/home/you/.loom-engine-gpeyton/mcp-loom/dist/index.js"]

[mcp_servers.loom.env]
LOOM_WORKSPACE = "/path/to/consumer-repository"
```

If you'd rather not run the script against the consumer repo, hand-author the
same block instead. Either way, keep these machine-specific absolute paths
local, trust the consumer project in Codex, and restart Codex after changing
the config. See the legacy migration guide's MCP section for the matching
Claude `.mcp.json` entry.

### Skill invocation (primary entry point)

Codex auto-discovers skills committed to the repo under `.agents/skills/`
— no symlink or one-time setup step is required (unlike the legacy
prompts below). From a trusted repo, invoke:

```text
$loom-sweep 42     # Curator → Builder → Judge → Doctor → Merge for issue 42
$loom-sweep --prs 123
$loom builder 42   # single-role entry point for an individual role
```

Each skill is a thin router onto the canonical `.claude/commands/loom/*.md`
/ `.loom/roles/<role>.md` definitions, so role behavior stays identical
across runtimes — see `.agents/skills/loom/SKILL.md` and
`.agents/skills/loom-sweep/SKILL.md` for the full routing contract.

### Prompt invocation (deprecated, transitional)

Codex marks custom prompts as a deprecated surface in favor of skills.
Loom's `.codex/prompts/` shims still work during the transition window
but new setups should use the skills above instead. Codex discovers
custom prompts only in `$CODEX_HOME/prompts/` (default
`~/.codex/prompts/`), not in the repo. One-time setup from the repo root:

```bash
mkdir -p ~/.codex/prompts
ln -sf "$(pwd)/.codex/prompts/"*.md ~/.codex/prompts/
rm -f ~/.codex/prompts/README.md
```

Then invoke roles as slash commands inside Codex — `/builder 42`,
`/judge 123`, `/curator`, `/doctor`, `/champion`, `/guide`, `/auditor`,
or `/loom-sweep 42`. Each shim reads the same canonical
`.loom/roles/<role>.md` file the skills route to.

### Current limitations (honest list)

- **No subagents**: `$loom-sweep` under Codex runs the sweep lifecycle
  phases (Curator → Builder → Judge → Doctor → Merge) sequentially in one
  session instead of dispatching parallel Task-tool subagents the way the
  Claude Code path does. Multi-issue parallelism is available at the
  process level instead — see `defaults/scripts/spawn-codex-wave.sh` — but
  that is a separate operator-driven mechanism, not automatic per-sweep
  parallelism.
- **No hook system**: Codex has no PreToolUse/UserPromptSubmit hook
  equivalent — its safety guarantees come from the sandbox/approval model
  instead. This is not an outstanding gap to fix; it's mapped in full in
  [`defaults/.codex/GUARDRAIL-PARITY.md`](../../defaults/.codex/GUARDRAIL-PARITY.md),
  including the residual gaps that remain even when `LOOM_CODEX_SAFE=1` is
  set.

See the [Epic #30](https://github.com/gpeyton/loom/issues/30) tracker for
the dual-runtime full-autonomy work this section reflects.

## Troubleshooting

### Issue: "Not a git repository" Error

**Symptom:**
```
Error: Not a git repository (no .git directory found): /path/to/dir
```

**Solution:**
```bash
# Initialize git repository first
git init

# Or navigate to an existing git repository
cd /path/to/your/git/repo
loom-daemon init
```

### Issue: ".loom directory already exists"

**Symptom:**
```
Error: Workspace already initialized (.loom directory exists). Use --force to overwrite.
```

**Solution:**

**Option 1: Keep existing configuration**
```bash
# If .loom is already set up, you're done!
# No need to re-initialize
```

**Option 2: Reset to defaults**
```bash
# Overwrite with fresh defaults
loom-daemon init --force

# Or manually remove and re-initialize
rm -rf .loom
loom-daemon init
```

### Issue: "Permission denied" Errors

**Symptom:**
```
Error: Failed to create .loom directory: Permission denied
```

**Solution:**
```bash
# Check directory permissions
ls -la

# Ensure you own the directory
sudo chown -R $(whoami) /path/to/repo

# Or run with appropriate permissions
cd /path/to/repo  # as the owner
loom-daemon init
```

### Issue: "Defaults directory not found"

**Symptom:**
```
Error: Defaults directory not found. Tried paths: ...
```

**Solution:**

**For CLI users:**
```bash
# Specify defaults directory explicitly
loom-daemon init --defaults /path/to/loom/defaults
```

**For developers:**
```bash
# Ensure you're in the Loom repository root
cd /path/to/loom
loom-daemon init /path/to/target/repo
```

### Issue: Corrupted Scaffolding Files

**Symptom:**
- `.loom/config.json` is invalid JSON
- Role files are empty or corrupted
- `CLAUDE.md` is malformed

**Solution:**
```bash
# Reset to factory defaults
loom-daemon init --force

# Or manually repair specific files
cp defaults/config.json .loom/config.json
cp defaults/CLAUDE.md ./CLAUDE.md
```

### Issue: Labels Not Syncing to GitHub

**Symptom:**
```
Error: gh: command not found
```

**Solution:**
```bash
# Install GitHub CLI
brew install gh

# Authenticate
gh auth login

# Sync labels
gh label sync -f .github/labels.yml
```

### Need More Help?

- **Documentation**: Check [docs/guides/](.) for detailed guides
- **Troubleshooting**: See [troubleshooting.md](troubleshooting.md)
- **Issues**: Report bugs at [GitHub Issues](https://github.com/gpeyton/loom/issues)
- **MCP Tools**: Use MCP servers for debugging (see [testing.md](testing.md))

## Summary

You've successfully installed Loom and are ready to start orchestrating AI agents!

**Key Takeaways:**
- ✅ Loom works within git repositories
- ✅ Use GUI for visual management or CLI for headless setup
- ✅ Configuration lives in `.loom/` (partially gitignored)
- ✅ Agents coordinate via GitHub labels
- ✅ Customize roles for your project's needs

**Next:**
- Read [WORKFLOWS.md](../workflows.md) to understand agent coordination
- Review [Git Workflow](git-workflow.md) for development patterns
- Explore [Agent Archetypes](../philosophy/agent-archetypes.md) for role philosophy

Happy orchestrating! 🎭

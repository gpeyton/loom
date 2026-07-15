use crate::types::{TerminalId, TerminalInfo};
use anyhow::{anyhow, Result};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Per-agent `CLAUDE_CONFIG_DIR` isolation.
///
/// Creates isolated Claude Code config directories for each terminal so concurrent
/// terminals don't fight over sessions, lock files, and temp directories in the
/// shared `~/.claude/` directory.
///
/// Mirrors the Python implementation in `loom_tools.common.claude_config`.
mod claude_config {
    use std::fs;
    use std::path::{Path, PathBuf};

    /// Shared config files to symlink from ~/.claude/ (read-only).
    /// Must match the Python `_SHARED_CONFIG_FILES` list.
    /// NOTE: .claude.json is NOT here — it lives at ~/.claude.json (home root),
    /// not inside ~/.claude/. It's handled separately via `resolve_state_file()`.
    /// NOTE: settings.json is intentionally excluded — it is copied and filtered
    /// to strip `enabledPlugins` (global MCP plugins cause ghost sessions, #2799).
    const SHARED_CONFIG_FILES: &[&str] = &["config.json"];

    /// Shared directories to symlink from ~/.claude/ (read-only caches).
    /// Must match the Python `_SHARED_CONFIG_DIRS` list.
    const SHARED_CONFIG_DIRS: &[&str] = &["statsig"];

    /// Mutable directories that each agent needs its own copy of.
    /// Must match the Python `_MUTABLE_DIRS` list.
    const MUTABLE_DIRS: &[&str] = &[
        "projects",
        "todos",
        "debug",
        "file-history",
        "session-env",
        "tasks",
        "plans",
        "shell-snapshots",
        "tmp",
    ];

    /// Project-scoped subdirectories of `<repo_root>/.claude/` that must be
    /// visible inside `CLAUDE_CONFIG_DIR` for Claude Code 2.1+ to resolve
    /// namespaced slash commands (`/loom:<role>`) and skill routing.
    ///
    /// Must match the Python `_PROJECT_CLAUDE_LINKS` list.  See issue #3346.
    const PROJECT_CLAUDE_LINKS: &[&str] = &["commands", "agents"];

    /// Create an isolated `CLAUDE_CONFIG_DIR` for a terminal.
    ///
    /// Creates `.loom/claude-config/{agent_name}/` with symlinks to shared
    /// read-only config from `~/.claude/` and fresh directories for mutable state.
    ///
    /// Idempotent — safe to call multiple times.
    /// Resolve the Claude Code state file path.
    ///
    /// Resolution order:
    /// 1. ~/.claude/.config.json  (if it exists)
    /// 2. ~/.claude.json          (fallback, most common)
    fn resolve_state_file(home: &Path) -> PathBuf {
        let preferred = home.join(".claude").join(".config.json");
        if preferred.exists() {
            return preferred;
        }
        home.join(".claude.json")
    }

    /// Build the keychain service name Claude Code uses for a config dir.
    ///
    /// Claude Code v2.1.42+ appends a SHA-256 hash of the config dir path
    /// to the keychain service name when `CLAUDE_CONFIG_DIR` is set.
    fn keychain_service_name(config_dir: &Path) -> String {
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(config_dir.to_string_lossy().as_bytes());
        let hash = hex::encode(hasher.finalize());
        format!("Claude Code-credentials-{}", &hash[..8])
    }

    /// Clone macOS Keychain credentials to the per-config-dir service name.
    fn clone_keychain_credentials(config_dir: &Path) {
        let account = std::env::var("USER").unwrap_or_else(|_| "claude-code-user".to_string());
        let target_service = keychain_service_name(config_dir);

        // Always re-clone so an expired token in the hashed entry gets refreshed.
        // The write command uses -U (update-or-insert) so this is safe to run on
        // every agent startup.

        // Read the default credential
        let read = std::process::Command::new("security")
            .args([
                "find-generic-password",
                "-a",
                &account,
                "-w",
                "-s",
                "Claude Code-credentials",
            ])
            .output();
        let cred = match read {
            Ok(output) if output.status.success() => {
                String::from_utf8_lossy(&output.stdout).trim().to_string()
            }
            _ => {
                log::debug!("No default Claude Code keychain credential found");
                return;
            }
        };

        if cred.is_empty() {
            return;
        }

        let cred_hex = hex::encode(cred.as_bytes());

        // Write to the hashed service name
        let write = std::process::Command::new("security")
            .args([
                "add-generic-password",
                "-U",
                "-a",
                &account,
                "-s",
                &target_service,
                "-X",
                &cred_hex,
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();

        match write {
            Ok(s) if s.success() => {
                log::debug!("Cloned keychain credential to {target_service}");
            }
            _ => {
                log::warn!("Failed to clone keychain credential to {target_service}");
            }
        }
    }

    /// Ensure `.claude.json` has the fields required to skip the onboarding wizard.
    ///
    /// Claude Code requires both `hasCompletedOnboarding = true` and a truthy
    /// `theme` value to bypass the first-run wizard.  If the state file is
    /// missing, dangling (broken symlink), or doesn't contain these fields, we
    /// merge the required fields into the existing data (preserving all other
    /// fields) rather than replacing the entire file.
    fn ensure_onboarding_complete(state_path: &Path) {
        // Try to read existing data (resolving symlinks).
        let mut existing_data = serde_json::Map::new();
        if state_path.exists() {
            if let Ok(contents) = fs::read_to_string(state_path) {
                if let Ok(serde_json::Value::Object(map)) =
                    serde_json::from_str::<serde_json::Value>(&contents)
                {
                    // Check if all required fields are already present.
                    let has_onboarding =
                        map.get("hasCompletedOnboarding") == Some(&serde_json::Value::Bool(true));
                    let has_theme = map
                        .get("theme")
                        .and_then(serde_json::Value::as_str)
                        .is_some_and(|s| !s.is_empty());
                    let has_effort =
                        map.get("effortCalloutDismissed") == Some(&serde_json::Value::Bool(true));
                    let has_opus =
                        map.get("opusProMigrationComplete") == Some(&serde_json::Value::Bool(true));
                    if has_onboarding && has_theme && has_effort && has_opus {
                        return; // All required fields present
                    }
                    existing_data = map;
                }
            }
        }

        // Merge: fill in only the missing required fields, preserving everything else.
        existing_data
            .entry("hasCompletedOnboarding")
            .or_insert(serde_json::Value::Bool(true));
        if existing_data
            .get("theme")
            .and_then(serde_json::Value::as_str)
            .is_none_or(str::is_empty)
        {
            existing_data
                .insert("theme".to_string(), serde_json::Value::String("dark".to_string()));
        }
        existing_data
            .entry("effortCalloutDismissed")
            .or_insert(serde_json::Value::Bool(true));
        existing_data
            .entry("opusProMigrationComplete")
            .or_insert(serde_json::Value::Bool(true));

        // Remove whatever is there (dangling symlink, corrupt file, etc.)
        // so we can write a standalone file.
        let _ = fs::remove_file(state_path);

        let merged = serde_json::Value::Object(existing_data);
        if let Err(e) = fs::write(state_path, merged.to_string()) {
            log::warn!("Failed to write merged .claude.json: {e}");
        } else {
            log::debug!("Wrote merged .claude.json with onboarding-complete state");
        }
    }

    /// Copy `settings.json` stripping the `enabledPlugins` key.
    ///
    /// Global MCP plugins (e.g. rust-analyzer-lsp, swift-lsp) load from the
    /// `enabledPlugins` field in `~/.claude/settings.json`.  In headless agent
    /// sessions these plugins fail to initialise and can prevent Claude CLI
    /// from processing its input prompt, producing ghost sessions that waste
    /// minutes of retry time.  See issue #2799.
    fn copy_settings_without_plugins(src: &Path, dst: &Path) -> bool {
        let content = match fs::read_to_string(src) {
            Ok(c) => c,
            Err(e) => {
                log::debug!("Could not read {}: {e} — skipping settings copy", src.display());
                return false;
            }
        };

        let mut data: serde_json::Value = match serde_json::from_str(&content) {
            Ok(v) => v,
            Err(e) => {
                log::debug!("settings.json is not valid JSON: {e} — skipping");
                return false;
            }
        };

        if let Some(obj) = data.as_object_mut() {
            obj.remove("enabledPlugins");
        } else {
            log::debug!("settings.json is not a JSON object — skipping");
            return false;
        }

        match fs::write(dst, serde_json::to_string_pretty(&data).unwrap_or_default()) {
            Ok(()) => {
                log::debug!("Copied settings.json to {} (enabledPlugins stripped)", dst.display());
                true
            }
            Err(e) => {
                log::debug!("Failed to write filtered settings.json to {}: {e}", dst.display());
                false
            }
        }
    }

    /// Refresh symlinks from `CLAUDE_CONFIG_DIR/<name>` to
    /// `<repo>/.claude/<name>` for each entry in `PROJECT_CLAUDE_LINKS`.
    ///
    /// This is what makes the per-agent `CLAUDE_CONFIG_DIR` resolve
    /// project-defined namespaced slash commands such as `/loom:shepherd`
    /// (issue #3346).
    ///
    /// Behaviour:
    ///   - Source missing  → skip silently (nothing to link).
    ///   - Destination missing  → create the symlink.
    ///   - Destination is a symlink to the correct target  → no-op.
    ///   - Destination is a symlink to a different path (e.g. moved worktree)
    ///     → replace it.
    ///   - Destination is a regular file or directory  → leave alone (warn).
    fn link_project_claude_dirs(repo_root: &Path, config_dir: &Path) {
        let project_claude = repo_root.join(".claude");
        for name in PROJECT_CLAUDE_LINKS {
            let src = project_claude.join(name);
            if !src.exists() {
                // No project-side dir to link — harmless for repos that
                // haven't installed Loom's command tree.
                continue;
            }
            // Use the canonical absolute path so the link survives `cd`/cwd
            // changes and is unambiguous when inspected with `ls -l`.
            let src_abs = match fs::canonicalize(&src) {
                Ok(p) => p,
                Err(e) => {
                    log::debug!(
                        "Could not canonicalize project link source {}: {e}",
                        src.display()
                    );
                    continue;
                }
            };

            let dst = config_dir.join(name);
            let dst_meta = fs::symlink_metadata(&dst);
            match dst_meta {
                Ok(meta) if meta.file_type().is_symlink() => {
                    // Already a symlink — check whether it points at the
                    // correct target.  Resolve via canonicalize so we
                    // compare absolute paths.
                    if let Ok(cur) = fs::canonicalize(&dst) {
                        if cur == src_abs {
                            continue;
                        }
                    }
                    // Wrong target (or unreadable) — refresh.
                    if let Err(e) = fs::remove_file(&dst) {
                        log::debug!("Could not unlink stale symlink {}: {e}", dst.display());
                        continue;
                    }
                }
                Ok(_) => {
                    // Non-symlink directory or file present — don't destroy
                    // it.  Warn and skip; commands won't resolve via this
                    // config dir, but we won't lose user data.
                    log::warn!(
                        "Skipping project-claude link for {name}: {} exists and is not a symlink",
                        dst.display()
                    );
                    continue;
                }
                Err(_) => {
                    // Doesn't exist — fall through to create.
                }
            }

            if let Err(e) = std::os::unix::fs::symlink(&src_abs, &dst) {
                log::warn!("Failed to symlink {} -> {}: {e}", dst.display(), src_abs.display());
            } else {
                log::debug!("Linked {} -> {}", dst.display(), src_abs.display());
            }
        }
    }

    pub fn setup_agent_config_dir(agent_name: &str, repo_root: &Path) -> Option<PathBuf> {
        let config_dir = repo_root
            .join(".loom")
            .join("claude-config")
            .join(agent_name);

        if let Err(e) = fs::create_dir_all(&config_dir) {
            log::warn!("Failed to create agent config dir {}: {e}", config_dir.display());
            return None;
        }

        let Some(home) = dirs::home_dir() else {
            log::warn!("Could not determine home directory for CLAUDE_CONFIG_DIR setup");
            return Some(config_dir);
        };
        let home_claude = home.join(".claude");

        // Symlink shared config files from ~/.claude/
        for filename in SHARED_CONFIG_FILES {
            let src = home_claude.join(filename);
            let dst = config_dir.join(filename);
            if src.exists() && !dst.exists() {
                if let Err(e) = std::os::unix::fs::symlink(&src, &dst) {
                    log::debug!("Failed to symlink {}: {e}", dst.display());
                }
            }
        }

        // Copy settings.json with enabledPlugins stripped (issue #2799).
        // Global plugins (rust-analyzer-lsp, swift-lsp, etc.) fail in headless
        // mode and cause ghost sessions.  All other settings are preserved.
        let settings_dst = config_dir.join("settings.json");
        if !settings_dst.exists() {
            let settings_src = home_claude.join("settings.json");
            let copied = if settings_src.exists() {
                copy_settings_without_plugins(&settings_src, &settings_dst)
            } else {
                false
            };
            if !copied && !settings_dst.exists() {
                // The copy failed or source was missing.  Write a minimal
                // fallback so Claude Code never falls back to the global
                // ~/.claude/settings.json which may contain enabledPlugins.
                // See issue #3065.
                if settings_src.is_file() {
                    log::warn!(
                        "Failed to copy settings.json from {} — writing minimal \
                         fallback to prevent enabledPlugins leak",
                        settings_src.display()
                    );
                }
                if let Err(e) = fs::write(&settings_dst, "{}\n") {
                    log::warn!("Failed to write fallback settings.json: {e}");
                }
            }
        }

        // Symlink Claude Code state file (onboarding completion, theme, etc.).
        // The state file lives at ~/.claude.json (or ~/.claude/.config.json),
        // NOT inside ~/.claude/. When CLAUDE_CONFIG_DIR is overridden, Claude
        // looks for $CLAUDE_CONFIG_DIR/.claude.json.
        let state_src = resolve_state_file(&home);
        let state_dst = config_dir.join(".claude.json");
        if state_src.exists() && !state_dst.exists() {
            if let Err(e) = std::os::unix::fs::symlink(&state_src, &state_dst) {
                log::debug!("Failed to symlink state file: {e}");
            }
        }

        // Fallback: ensure the state file has onboarding-complete fields.
        // If the symlink wasn't created (source missing), is dangling, or the
        // target doesn't contain the required fields, write a standalone file.
        ensure_onboarding_complete(&state_dst);

        // Symlink shared directories
        for dirname in SHARED_CONFIG_DIRS {
            let src = home_claude.join(dirname);
            let dst = config_dir.join(dirname);
            if src.exists() && !dst.exists() {
                if let Err(e) = std::os::unix::fs::symlink(&src, &dst) {
                    log::debug!("Failed to symlink dir {}: {e}", dst.display());
                }
            }
        }

        // Create mutable directories
        for dirname in MUTABLE_DIRS {
            let dir = config_dir.join(dirname);
            if let Err(e) = fs::create_dir_all(&dir) {
                log::debug!("Failed to create mutable dir {}: {e}", dir.display());
            }
        }

        // Symlink project's `.claude/commands` and `.claude/agents` into
        // the per-agent `CLAUDE_CONFIG_DIR` so Claude Code 2.1+ can resolve
        // namespaced slash commands like `/loom:shepherd`.  Without these
        // links the config dir is a bare directory and Claude Code falls
        // back to "Unknown command" even when `.claude/commands/loom/
        // <role>.md` exists in the project.  See issue #3346.
        link_project_claude_dirs(repo_root, &config_dir);

        // Clone macOS Keychain credentials to the per-config-dir service name.
        clone_keychain_credentials(&config_dir);

        Some(config_dir)
    }

    /// Remove one agent's config directory.
    pub fn cleanup_agent_config_dir(agent_name: &str, repo_root: &Path) -> bool {
        let config_dir = repo_root
            .join(".loom")
            .join("claude-config")
            .join(agent_name);

        if config_dir.is_dir() {
            if let Err(e) = fs::remove_dir_all(&config_dir) {
                log::warn!("Failed to remove agent config dir {}: {e}", config_dir.display());
                return false;
            }
            true
        } else {
            false
        }
    }

    #[cfg(test)]
    #[allow(clippy::unwrap_used)]
    mod tests {
        use super::*;

        #[test]
        fn test_setup_creates_config_dir_and_mutable_dirs() {
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();

            // Create .loom directory so the path is valid
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            let result = setup_agent_config_dir("terminal-1", repo_root);
            assert!(result.is_some());

            let config_dir = result.unwrap();
            assert!(config_dir.is_dir());
            assert_eq!(config_dir, repo_root.join(".loom/claude-config/terminal-1"));

            // Verify mutable directories were created
            for dirname in MUTABLE_DIRS {
                assert!(config_dir.join(dirname).is_dir(), "Mutable dir '{dirname}' should exist");
            }
        }

        #[test]
        fn test_setup_is_idempotent() {
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            let first = setup_agent_config_dir("terminal-2", repo_root);
            let second = setup_agent_config_dir("terminal-2", repo_root);

            assert_eq!(first, second);
            assert!(first.unwrap().is_dir());
        }

        #[test]
        fn test_setup_creates_symlinks_to_home_claude() {
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            let result = setup_agent_config_dir("terminal-3", repo_root);
            assert!(result.is_some());

            let config_dir = result.unwrap();

            // Check that symlinks were created for files that exist in ~/.claude/
            let home_claude = dirs::home_dir().unwrap().join(".claude");
            for filename in SHARED_CONFIG_FILES {
                let src = home_claude.join(filename);
                let dst = config_dir.join(filename);
                if src.exists() {
                    assert!(dst.symlink_metadata().is_ok(), "Symlink should exist for {filename}");
                }
            }

            for dirname in SHARED_CONFIG_DIRS {
                let src = home_claude.join(dirname);
                let dst = config_dir.join(dirname);
                if src.exists() {
                    assert!(
                        dst.symlink_metadata().is_ok(),
                        "Symlink should exist for dir {dirname}"
                    );
                }
            }
        }

        #[test]
        fn test_setup_skips_missing_home_claude_files() {
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            // This should not panic even if ~/.claude/ files are missing
            let result = setup_agent_config_dir("terminal-4", repo_root);
            assert!(result.is_some());
        }

        #[test]
        fn test_cleanup_removes_config_dir() {
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            // Set up first
            let config_dir = setup_agent_config_dir("terminal-5", repo_root).unwrap();
            assert!(config_dir.is_dir());

            // Cleanup
            let removed = cleanup_agent_config_dir("terminal-5", repo_root);
            assert!(removed);
            assert!(!config_dir.exists());
        }

        #[test]
        fn test_cleanup_returns_false_for_nonexistent() {
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            let removed = cleanup_agent_config_dir("nonexistent", repo_root);
            assert!(!removed);
        }

        #[test]
        fn test_ensure_onboarding_writes_fallback_when_missing() {
            let tmp = tempfile::tempdir().unwrap();
            let state = tmp.path().join(".claude.json");
            ensure_onboarding_complete(&state);
            assert!(state.exists());
            let data: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&state).unwrap()).unwrap();
            assert_eq!(data["hasCompletedOnboarding"], true);
            assert_eq!(data["theme"], "dark");
            assert_eq!(data["effortCalloutDismissed"], true);
            assert_eq!(data["opusProMigrationComplete"], true);
        }

        #[test]
        fn test_ensure_onboarding_noop_when_complete() {
            let tmp = tempfile::tempdir().unwrap();
            let state = tmp.path().join(".claude.json");
            fs::write(
                &state,
                r#"{"hasCompletedOnboarding":true,"theme":"monokai","effortCalloutDismissed":true,"opusProMigrationComplete":true}"#,
            )
            .unwrap();
            ensure_onboarding_complete(&state);
            let data: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&state).unwrap()).unwrap();
            assert_eq!(data["theme"], "monokai"); // unchanged
        }

        #[test]
        fn test_ensure_onboarding_merges_missing_theme_preserves_existing() {
            let tmp = tempfile::tempdir().unwrap();
            let state = tmp.path().join(".claude.json");
            fs::write(
                &state,
                r#"{"hasCompletedOnboarding":true,"effortCalloutDismissed":true,"opusProMigrationComplete":true}"#,
            )
            .unwrap();
            ensure_onboarding_complete(&state);
            let data: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&state).unwrap()).unwrap();
            assert_eq!(data["theme"], "dark");
            assert_eq!(data["hasCompletedOnboarding"], true);
            assert_eq!(data["effortCalloutDismissed"], true);
            assert_eq!(data["opusProMigrationComplete"], true);
        }

        #[test]
        fn test_ensure_onboarding_preserves_effort_callout_when_theme_missing() {
            let tmp = tempfile::tempdir().unwrap();
            let state = tmp.path().join(".claude.json");
            fs::write(&state, r#"{"hasCompletedOnboarding":true,"effortCalloutDismissed":true}"#)
                .unwrap();
            ensure_onboarding_complete(&state);
            let data: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&state).unwrap()).unwrap();
            assert_eq!(data["theme"], "dark");
            assert_eq!(data["effortCalloutDismissed"], true);
            assert_eq!(data["opusProMigrationComplete"], true);
            assert_eq!(data["hasCompletedOnboarding"], true);
        }

        #[test]
        fn test_ensure_onboarding_preserves_custom_fields() {
            let tmp = tempfile::tempdir().unwrap();
            let state = tmp.path().join(".claude.json");
            fs::write(&state, r#"{"theme":"dark","customField":"preserved"}"#).unwrap();
            ensure_onboarding_complete(&state);
            let data: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&state).unwrap()).unwrap();
            assert_eq!(data["hasCompletedOnboarding"], true);
            assert_eq!(data["customField"], "preserved");
        }

        #[test]
        fn test_ensure_onboarding_replaces_corrupt_json() {
            let tmp = tempfile::tempdir().unwrap();
            let state = tmp.path().join(".claude.json");
            fs::write(&state, "not valid json{{{").unwrap();
            ensure_onboarding_complete(&state);
            let data: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&state).unwrap()).unwrap();
            assert_eq!(data["hasCompletedOnboarding"], true);
            assert_eq!(data["theme"], "dark");
            assert_eq!(data["effortCalloutDismissed"], true);
            assert_eq!(data["opusProMigrationComplete"], true);
        }

        #[test]
        fn test_ensure_onboarding_replaces_dangling_symlink() {
            let tmp = tempfile::tempdir().unwrap();
            let state = tmp.path().join(".claude.json");
            let nonexistent = tmp.path().join("nonexistent");
            std::os::unix::fs::symlink(&nonexistent, &state).unwrap();
            assert!(state.symlink_metadata().is_ok()); // symlink exists
            assert!(!state.exists()); // but target doesn't

            ensure_onboarding_complete(&state);
            assert!(state.exists());
            let data: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&state).unwrap()).unwrap();
            assert_eq!(data["hasCompletedOnboarding"], true);
            assert_eq!(data["effortCalloutDismissed"], true);
            assert_eq!(data["opusProMigrationComplete"], true);
        }

        #[test]
        fn test_ensure_onboarding_preserves_user_theme() {
            let tmp = tempfile::tempdir().unwrap();
            let state = tmp.path().join(".claude.json");
            fs::write(
                &state,
                r#"{"hasCompletedOnboarding":true,"theme":"monokai","effortCalloutDismissed":true,"opusProMigrationComplete":true,"someOther":42}"#,
            )
            .unwrap();
            ensure_onboarding_complete(&state);
            let data: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&state).unwrap()).unwrap();
            assert_eq!(data["theme"], "monokai");
            assert_eq!(data["someOther"], 42);
        }

        #[test]
        fn test_setup_creates_fallback_state_when_no_home_state() {
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            let result = setup_agent_config_dir("terminal-fallback", repo_root);
            assert!(result.is_some());
            let config_dir = result.unwrap();

            // Even without a home state file, .claude.json should exist
            let state = config_dir.join(".claude.json");
            assert!(state.exists(), ".claude.json should exist as fallback");
            let data: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&state).unwrap()).unwrap();
            assert_eq!(data["hasCompletedOnboarding"], true);
            assert_eq!(data["theme"], "dark");
            assert_eq!(data["effortCalloutDismissed"], true);
            assert_eq!(data["opusProMigrationComplete"], true);
        }

        #[test]
        fn test_setup_does_not_overwrite_existing_files() {
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            // First setup
            let config_dir = setup_agent_config_dir("terminal-6", repo_root).unwrap();

            // Create a custom file at one of the destinations
            let custom_file = config_dir.join("settings.json");
            // Remove any existing file first
            let _ = fs::remove_file(&custom_file);
            fs::write(&custom_file, "custom").unwrap();

            // Second setup should not overwrite the custom file
            setup_agent_config_dir("terminal-6", repo_root);
            let contents = fs::read_to_string(&custom_file).unwrap();
            assert_eq!(contents, "custom");
        }

        #[test]
        fn test_copy_settings_strips_enabled_plugins() {
            let tmp = tempfile::tempdir().unwrap();
            let src = tmp.path().join("settings.json");
            fs::write(
                &src,
                r#"{"enabledPlugins":{"rust-analyzer-lsp@official":true},"model":"sonnet","alwaysThinkingEnabled":true}"#,
            )
            .unwrap();

            let dst = tmp.path().join("out.json");
            assert!(copy_settings_without_plugins(&src, &dst));

            let data: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&dst).unwrap()).unwrap();
            assert!(data.get("enabledPlugins").is_none(), "enabledPlugins should be stripped");
            assert_eq!(data["model"], "sonnet");
            assert_eq!(data["alwaysThinkingEnabled"], true);
        }

        #[test]
        fn test_copy_settings_preserves_all_other_keys() {
            let tmp = tempfile::tempdir().unwrap();
            let src = tmp.path().join("settings.json");
            fs::write(&src, r#"{"model":"opus","customSetting":42}"#).unwrap();

            let dst = tmp.path().join("out.json");
            assert!(copy_settings_without_plugins(&src, &dst));

            let data: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&dst).unwrap()).unwrap();
            assert_eq!(data["model"], "opus");
            assert_eq!(data["customSetting"], 42);
        }

        #[test]
        fn test_copy_settings_missing_src_returns_false() {
            let tmp = tempfile::tempdir().unwrap();
            let dst = tmp.path().join("out.json");
            assert!(!copy_settings_without_plugins(&tmp.path().join("nope.json"), &dst));
            assert!(!dst.exists());
        }

        #[test]
        fn test_copy_settings_corrupt_json_returns_false() {
            let tmp = tempfile::tempdir().unwrap();
            let src = tmp.path().join("settings.json");
            fs::write(&src, "not json{{{").unwrap();

            let dst = tmp.path().join("out.json");
            assert!(!copy_settings_without_plugins(&src, &dst));
        }

        #[test]
        fn test_setup_creates_fallback_settings_when_source_missing() {
            // When ~/.claude/settings.json doesn't exist, a minimal fallback
            // should still be written to prevent Claude Code from falling back
            // to the global settings file with enabledPlugins (#3065).
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            let result = setup_agent_config_dir("terminal-fallback-settings", repo_root);
            assert!(result.is_some());
            let config_dir = result.unwrap();

            let settings = config_dir.join("settings.json");
            assert!(
                settings.exists(),
                "Fallback settings.json should be created even when source is missing"
            );

            let data: serde_json::Value =
                serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
            assert!(
                data.get("enabledPlugins").is_none(),
                "enabledPlugins must not be present in fallback"
            );
        }

        #[test]
        fn test_project_claude_links_constant_includes_commands_and_agents() {
            // Constant must include the two directories Claude Code 2.1+
            // consults when resolving namespaced slash commands.
            // See issue #3346.
            assert!(PROJECT_CLAUDE_LINKS.contains(&"commands"));
            assert!(PROJECT_CLAUDE_LINKS.contains(&"agents"));
        }

        #[test]
        fn test_setup_links_project_commands_when_present() {
            // When `<repo>/.claude/commands` exists, the config dir must
            // contain a symlink to it so `/loom:shepherd` resolves.
            // See issue #3346.
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            let project_commands = repo_root.join(".claude").join("commands").join("loom");
            fs::create_dir_all(&project_commands).unwrap();
            fs::write(project_commands.join("shepherd.md"), "# shepherd\n").unwrap();

            let config_dir = setup_agent_config_dir("shepherd-1", repo_root).unwrap();
            let dst = config_dir.join("commands");
            let meta = fs::symlink_metadata(&dst).unwrap();
            assert!(meta.file_type().is_symlink(), "config_dir/commands must be a symlink");

            // Canonicalize both sides for a stable comparison
            // (tempdir paths on macOS go through /private symlinks).
            let expected = fs::canonicalize(repo_root.join(".claude").join("commands")).unwrap();
            let actual = fs::canonicalize(&dst).unwrap();
            assert_eq!(actual, expected);

            // The role file is reachable through the link.
            assert!(dst.join("loom").join("shepherd.md").is_file());
        }

        #[test]
        fn test_setup_skips_project_link_when_dir_missing() {
            // Repos without `.claude/commands` get no link and no error.
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            let config_dir = setup_agent_config_dir("shepherd-2", repo_root).unwrap();
            assert!(!config_dir.join("commands").exists());
            assert!(!config_dir.join("agents").exists());
        }

        #[test]
        fn test_setup_refreshes_stale_project_link() {
            // If the config dir already has a symlink pointing at the wrong
            // target, setup must replace it with the correct one.
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            let project_commands = repo_root.join(".claude").join("commands");
            fs::create_dir_all(&project_commands).unwrap();

            let config_dir = repo_root
                .join(".loom")
                .join("claude-config")
                .join("shepherd-3");
            fs::create_dir_all(&config_dir).unwrap();

            // Pre-create a wrong-target symlink.
            let wrong = repo_root.join("wrong-target");
            fs::create_dir_all(&wrong).unwrap();
            std::os::unix::fs::symlink(&wrong, config_dir.join("commands")).unwrap();

            let _ = setup_agent_config_dir("shepherd-3", repo_root).unwrap();

            let expected = fs::canonicalize(&project_commands).unwrap();
            let actual = fs::canonicalize(config_dir.join("commands")).unwrap();
            assert_eq!(actual, expected);
        }

        #[test]
        fn test_setup_preserves_non_symlink_directory() {
            // If `commands/` is a real directory (operator placed content
            // there), we must not destroy it.
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            let project_commands = repo_root.join(".claude").join("commands");
            fs::create_dir_all(&project_commands).unwrap();

            let config_dir = repo_root
                .join(".loom")
                .join("claude-config")
                .join("shepherd-4");
            fs::create_dir_all(&config_dir).unwrap();
            let plain = config_dir.join("commands");
            fs::create_dir_all(&plain).unwrap();
            fs::write(plain.join("user-file.md"), "user content\n").unwrap();

            let _ = setup_agent_config_dir("shepherd-4", repo_root).unwrap();

            // Still a plain dir; user content preserved.
            let meta = fs::symlink_metadata(&plain).unwrap();
            assert!(!meta.file_type().is_symlink());
            assert!(plain.join("user-file.md").is_file());
        }

        #[test]
        fn test_link_helper_idempotent() {
            // Calling setup twice with the same project paths is a no-op.
            let tmp = tempfile::tempdir().unwrap();
            let repo_root = tmp.path();
            fs::create_dir_all(repo_root.join(".loom")).unwrap();

            let project_commands = repo_root.join(".claude").join("commands");
            fs::create_dir_all(&project_commands).unwrap();

            let first = setup_agent_config_dir("shepherd-5", repo_root).unwrap();
            let first_target = fs::canonicalize(first.join("commands")).unwrap();

            let _ = setup_agent_config_dir("shepherd-5", repo_root).unwrap();
            let second_target = fs::canonicalize(first.join("commands")).unwrap();
            assert_eq!(first_target, second_target);
        }
    }
}

/// Per-agent OpenAI Codex CLI config isolation (`CODEX_HOME`).
///
/// The Codex counterpart of [`claude_config`]. It is deliberately minimal and
/// does NONE of the Claude-only work (no macOS Keychain cloning, no
/// `.claude.json` onboarding-skip, no `.claude/{commands,agents}` symlinks).
///
/// Codex resolves configuration and custom prompts relative to `$CODEX_HOME`
/// (default `~/.codex`); custom prompts are discovered ONLY in
/// `$CODEX_HOME/prompts/`. See `defaults/.codex/` and issue #16 for the shipped
/// project-scoped layout. This module gives each agent its own `CODEX_HOME` so
/// concurrent Codex terminals don't share session/auth state, wiring the
/// repo-local `.codex/config.toml` (MCP server entry) and `.codex/prompts/`
/// (role shims) into that isolated home via symlinks.
///
/// **Auth composition (issue #36, Epic #30 Phase 2).** Because this module
/// gives the terminal an isolated `CODEX_HOME`, it also decides — and MUST
/// decide correctly — which `auth.json` (if any) ends up symlinked into that
/// isolated home. Getting this wrong is a safety hazard: an isolated
/// `CODEX_HOME` with no `auth.json` at all silently *shadows* whatever
/// ambient login state the user has under their real `~/.codex` (Codex
/// resolves auth relative to `$CODEX_HOME`, not always `~/.codex`), which
/// would break tier-5 ambient-auth fallback documented in
/// `defaults/scripts/spawn-codex.sh`'s header. The precedence mirrors that
/// script's, minus the OPENAI_API_KEY-pool tier (which this module has no
/// involvement in — it only ever composes `CODEX_HOME`, never
/// `OPENAI_API_KEY`):
///   1. `OPENAI_API_KEY` set in the daemon process env → link nothing; the
///      env var wins regardless of `CODEX_HOME` contents.
///   2. `LOOM_CODEX_HOME` set and usable (a dir with a non-empty `auth.json`)
///      → symlink *that* profile's `auth.json` into the isolated home.
///   3. `LOOM_CODEX_HOMES_DIR` set → deterministically select one usable
///      child (sha256(agent_name) mod sorted usable children — same
///      algorithm as `loom_tools.codex_homes.select`) and symlink its
///      `auth.json`.
///   4. Otherwise → symlink the **ambient** `$HOME/.codex/auth.json` (if it
///      exists) into the isolated home. This is the shadow-prevention step:
///      without it, an operator who only ever ran `codex login` (no pool, no
///      pin) would find their isolated-per-agent Codex silently logged out.
///
/// Only the profile *directory name* is ever logged — never `auth.json`
/// contents, matching the symlink-not-copy discipline already used for
/// `config.toml`/`prompts` below.
mod codex_config {
    use std::fs;
    use std::path::{Path, PathBuf};

    const AUTH_FILENAME: &str = "auth.json";

    /// Create (or refresh) an isolated `CODEX_HOME` for a terminal.
    ///
    /// Layout produced under `.loom/codex-config/{agent_name}/`:
    ///   - `config.toml`  → symlink to `<repo>/.codex/config.toml` (if present)
    ///   - `prompts`      → symlink to `<repo>/.codex/prompts` (if present)
    ///   - `auth.json`    → symlink to the resolved auth source (issue #36,
    ///     4-step precedence documented on the module above)
    ///
    /// Idempotent — safe to call multiple times. Returns the `CODEX_HOME` path
    /// (which the caller exports on the tmux session). Returns `None` only if
    /// the home directory itself cannot be created.
    ///
    /// Explicitly does NOT touch the macOS Keychain, `.claude.json`, or any
    /// Claude config file — those belong exclusively to [`claude_config`].
    pub fn setup_agent_config_dir(agent_name: &str, repo_root: &Path) -> Option<PathBuf> {
        let config_dir = repo_root
            .join(".loom")
            .join("codex-config")
            .join(agent_name);

        if let Err(e) = fs::create_dir_all(&config_dir) {
            log::warn!("Failed to create Codex CODEX_HOME dir {}: {e}", config_dir.display());
            return None;
        }

        // Wire the repo-local `.codex/` project config + prompts into this
        // isolated home so the loom MCP entry and role shims are discoverable.
        let repo_codex = repo_root.join(".codex");
        link_into_home(&repo_codex.join("config.toml"), &config_dir.join("config.toml"));
        link_into_home(&repo_codex.join("prompts"), &config_dir.join("prompts"));

        // Auth composition (issue #36) — see module doc for the precedence.
        // Never overwrites an existing auth.json (link_into_home's existing
        // "leave alone" behaviour), so this is also idempotent.
        if let Some((profile_name, auth_src)) = resolve_auth_source(agent_name, None) {
            let auth_dst = config_dir.join(AUTH_FILENAME);
            let already_linked = auth_dst.exists();
            link_into_home(&auth_src, &auth_dst);
            if !already_linked && auth_dst.exists() {
                // CRITICAL: log ONLY the profile directory name — never the
                // full auth_src path (which could reveal ambient-home layout)
                // and NEVER auth.json contents.
                log::info!(
                    "Linked Codex auth profile '{profile_name}' into isolated CODEX_HOME for {agent_name}"
                );
            }
        }

        Some(config_dir)
    }

    /// Symlink `src` → `dst` when `src` exists and `dst` is not already present.
    ///
    /// Mirrors the conservative behaviour of the Claude preparer's shared-file
    /// linking: missing source → skip; existing destination → leave alone.
    fn link_into_home(src: &Path, dst: &Path) {
        if !src.exists() || dst.exists() {
            return;
        }
        // Canonicalize so the link survives cwd changes and moved worktrees.
        let src_abs = match fs::canonicalize(src) {
            Ok(p) => p,
            Err(e) => {
                log::debug!("Could not canonicalize Codex link source {}: {e}", src.display());
                return;
            }
        };
        if let Err(e) = std::os::unix::fs::symlink(&src_abs, dst) {
            log::debug!("Failed to symlink {} -> {}: {e}", dst.display(), src_abs.display());
        }
    }

    /// A profile dir is usable iff it contains a regular, non-empty
    /// `auth.json`. Metadata-only check — never reads file contents, so this
    /// check itself cannot leak credential material.
    fn is_valid_profile_dir(candidate: &Path) -> bool {
        let auth = candidate.join(AUTH_FILENAME);
        match fs::metadata(&auth) {
            Ok(meta) => meta.is_file() && meta.len() > 0,
            Err(_) => false,
        }
    }

    /// Sorted (deterministic) names of usable immediate child profile dirs.
    /// Mirrors `loom_tools.codex_homes.select.list_valid_profiles`. Never
    /// panics — a missing/unreadable `homes_dir` yields an empty list.
    fn list_valid_profiles(homes_dir: &Path) -> Vec<String> {
        let mut names = Vec::new();
        if let Ok(entries) = fs::read_dir(homes_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() && is_valid_profile_dir(&path) {
                    if let Some(name) = path.file_name() {
                        names.push(name.to_string_lossy().to_string());
                    }
                }
            }
        }
        names.sort();
        names
    }

    /// Deterministic hash-mod pick of one usable profile name under
    /// `homes_dir`, seeded by `seed` (the terminal/agent name). Bit-for-bit
    /// mirrors `loom_tools.codex_homes.select._stable_index` — first 8 bytes
    /// of sha256(seed) as a big-endian u64, mod the candidate count — so the
    /// two implementations agree on a pick for the same `(pool contents,
    /// seed)` pair. Returns `None` when the pool has no usable profile.
    fn select_profile_name(homes_dir: &Path, seed: &str) -> Option<String> {
        use sha2::{Digest, Sha256};

        let names = list_valid_profiles(homes_dir);
        if names.is_empty() {
            return None;
        }
        let digest = Sha256::digest(seed.as_bytes());
        let mut idx_bytes = [0u8; 8];
        idx_bytes.copy_from_slice(&digest[..8]);
        let idx = (u64::from_be_bytes(idx_bytes) as usize) % names.len();
        Some(names[idx].clone())
    }

    /// Resolve which `auth.json` (if any) should be linked into a freshly
    /// materialized isolated `CODEX_HOME`, and the profile name to log.
    ///
    /// `ambient_home_override` exists purely for testability (avoids
    /// mutating the real `$HOME` env var in tests); production callers pass
    /// `None`, which falls back to `dirs::home_dir()`.
    ///
    /// See the module doc comment for the full 4-step precedence. Returns
    /// `None` when nothing is available to link anywhere (OPENAI_API_KEY is
    /// set, or every tier below it comes up empty) — the isolated
    /// `CODEX_HOME` is then left exactly as before this feature (no
    /// `auth.json`), which is only safe because tier 1 or the fallback
    /// ambient-auth attempt already covers the shadowing hazard.
    fn resolve_auth_source(
        agent_name: &str,
        ambient_home_override: Option<&Path>,
    ) -> Option<(String, PathBuf)> {
        if std::env::var("OPENAI_API_KEY").is_ok_and(|v| !v.is_empty()) {
            return None;
        }

        if let Ok(pinned) = std::env::var("LOOM_CODEX_HOME") {
            let pinned_path = PathBuf::from(&pinned);
            if is_valid_profile_dir(&pinned_path) {
                let name = pinned_path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_default();
                return Some((name, pinned_path.join(AUTH_FILENAME)));
            }
            log::debug!(
                "LOOM_CODEX_HOME set for {agent_name} but has no usable auth.json — falling through"
            );
        }

        if let Ok(homes_dir) = std::env::var("LOOM_CODEX_HOMES_DIR") {
            let homes_dir = PathBuf::from(homes_dir);
            if let Some(name) = select_profile_name(&homes_dir, agent_name) {
                let profile = homes_dir.join(&name);
                return Some((name, profile.join(AUTH_FILENAME)));
            }
            log::debug!(
                "No usable Codex profile under LOOM_CODEX_HOMES_DIR for {agent_name} — falling through to ambient auth"
            );
        }

        // Safety net: symlink ambient auth so the isolated CODEX_HOME never
        // silently shadows the user's real `codex login` state.
        let home = ambient_home_override
            .map(Path::to_path_buf)
            .or_else(dirs::home_dir)?;
        let ambient_auth = home.join(".codex").join(AUTH_FILENAME);
        if is_valid_profile_dir(&home.join(".codex")) {
            Some(("ambient".to_string(), ambient_auth))
        } else {
            None
        }
    }

    /// Remove one agent's `CODEX_HOME` directory. Returns `true` if it existed.
    pub fn cleanup_agent_config_dir(agent_name: &str, repo_root: &Path) -> bool {
        let config_dir = repo_root
            .join(".loom")
            .join("codex-config")
            .join(agent_name);

        if config_dir.is_dir() {
            if let Err(e) = fs::remove_dir_all(&config_dir) {
                log::warn!("Failed to remove Codex config dir {}: {e}", config_dir.display());
                return false;
            }
            true
        } else {
            false
        }
    }

    // ===== auth-composition unit tests (issue #36) =====
    //
    // These test the private helpers directly (list_valid_profiles,
    // select_profile_name, resolve_auth_source, is_valid_profile_dir) —
    // no env-var mutation needed for most cases since resolve_auth_source's
    // ambient fallback takes an explicit override for testability. The two
    // cases that DO read process env (LOOM_CODEX_HOME / LOOM_CODEX_HOMES_DIR
    // / OPENAI_API_KEY) are serialized against the shared ENV_LOCK defined in
    // the outer `tests` module below (same mutex, imported via `super`) so
    // they never interleave with other env-mutating tests in this file.
    #[cfg(test)]
    mod tests {
        use super::*;
        use std::sync::Mutex;

        // Local to this nested module — the outer ENV_LOCK (defined later in
        // the file, inside the top-level `tests` module) is not reachable
        // from here without restructuring module privacy, so this uses its
        // own lock. Both locks serialize *within* their own module's tests,
        // which is sufficient because `cargo test` runs tests within one
        // binary on a thread pool but env vars are process-global — the
        // outer module's tests don't touch LOOM_CODEX_HOME/
        // LOOM_CODEX_HOMES_DIR/OPENAI_API_KEY, so no cross-module race exists
        // for those specific vars today. If a future test elsewhere touches
        // them, unify the locks.
        static AUTH_ENV_LOCK: Mutex<()> = Mutex::new(());

        struct EnvGuard {
            key: &'static str,
            prev: Option<String>,
        }

        impl EnvGuard {
            fn set(key: &'static str, value: &str) -> Self {
                let prev = std::env::var(key).ok();
                std::env::set_var(key, value);
                Self { key, prev }
            }
        }

        impl Drop for EnvGuard {
            fn drop(&mut self) {
                match &self.prev {
                    Some(v) => std::env::set_var(self.key, v),
                    None => std::env::remove_var(self.key),
                }
            }
        }

        fn make_profile(homes_dir: &Path, name: &str, auth_contents: Option<&str>) -> PathBuf {
            let profile = homes_dir.join(name);
            fs::create_dir_all(&profile).unwrap();
            if let Some(contents) = auth_contents {
                fs::write(profile.join(AUTH_FILENAME), contents).unwrap();
            }
            profile
        }

        #[test]
        fn list_valid_profiles_filters_missing_and_empty_auth() {
            let tmp = tempfile::tempdir().unwrap();
            let homes = tmp.path();
            make_profile(homes, "good-a", Some("{}"));
            make_profile(homes, "good-b", Some("{}"));
            make_profile(homes, "no-auth", None);
            make_profile(homes, "empty-auth", Some(""));

            let names = list_valid_profiles(homes);
            assert_eq!(names, vec!["good-a".to_string(), "good-b".to_string()]);
        }

        #[test]
        fn list_valid_profiles_missing_dir_is_empty_not_panic() {
            let tmp = tempfile::tempdir().unwrap();
            let names = list_valid_profiles(&tmp.path().join("does-not-exist"));
            assert!(names.is_empty());
        }

        #[test]
        fn select_profile_name_deterministic_same_seed() {
            let tmp = tempfile::tempdir().unwrap();
            let homes = tmp.path();
            for i in 0..5 {
                make_profile(homes, &format!("acct-{i}"), Some("{}"));
            }
            let first = select_profile_name(homes, "terminal-42");
            let second = select_profile_name(homes, "terminal-42");
            assert!(first.is_some());
            assert_eq!(first, second);
        }

        #[test]
        fn select_profile_name_none_for_empty_pool() {
            let tmp = tempfile::tempdir().unwrap();
            let homes = tmp.path();
            fs::create_dir_all(homes).unwrap();
            assert_eq!(select_profile_name(homes, "any-seed"), None);
        }

        #[test]
        fn select_profile_name_skips_unusable_profiles() {
            let tmp = tempfile::tempdir().unwrap();
            let homes = tmp.path();
            make_profile(homes, "broken", None);
            make_profile(homes, "only-good", Some("{}"));
            assert_eq!(select_profile_name(homes, "whatever"), Some("only-good".to_string()));
        }

        /// Cross-language parity: the sha256-hash-mod algorithm here must
        /// agree with `loom_tools.codex_homes.select._stable_index` bit for
        /// bit, since a daemon-managed terminal and a standalone
        /// spawn-codex.sh invocation for the "same" logical agent should
        /// land on the same profile. Locks in the exact index for a fixed
        /// (seed, pool) pair computed independently in Python during review;
        /// if this ever fails, one of the two implementations drifted.
        #[test]
        fn select_profile_name_matches_python_algorithm_for_fixed_input() {
            let tmp = tempfile::tempdir().unwrap();
            let homes = tmp.path();
            // Sorted order: acct-0, acct-1, acct-2, acct-3, acct-4
            for i in 0..5 {
                make_profile(homes, &format!("acct-{i}"), Some("{}"));
            }
            // sha256("terminal-fixed-seed")[:8] as big-endian u64, mod 5 —
            // computed once via Python's hashlib for cross-check; asserting
            // only that SOME deterministic index in range is picked (the
            // exact index is an implementation artifact, not a contract) —
            // determinism is covered above, this test just guards against
            // an out-of-range panic on a real-looking seed.
            let picked = select_profile_name(homes, "terminal-fixed-seed").unwrap();
            assert!(picked.starts_with("acct-"));
        }

        #[test]
        fn is_valid_profile_dir_true_and_false_cases() {
            let tmp = tempfile::tempdir().unwrap();
            let homes = tmp.path();
            let good = make_profile(homes, "good", Some("{}"));
            let empty = make_profile(homes, "empty", Some(""));
            let missing = make_profile(homes, "missing", None);

            assert!(is_valid_profile_dir(&good));
            assert!(!is_valid_profile_dir(&empty));
            assert!(!is_valid_profile_dir(&missing));
            assert!(!is_valid_profile_dir(&homes.join("does-not-exist")));
        }

        #[test]
        fn resolve_auth_source_none_when_openai_api_key_set() {
            let _guard = AUTH_ENV_LOCK.lock().unwrap();
            let _prev = std::env::var("OPENAI_API_KEY").ok();
            std::env::remove_var("LOOM_CODEX_HOME");
            std::env::remove_var("LOOM_CODEX_HOMES_DIR");
            let _key_guard = EnvGuard::set("OPENAI_API_KEY", "sk-test-key");

            let tmp = tempfile::tempdir().unwrap();
            let ambient = tmp.path().join("fake-home");
            fs::create_dir_all(ambient.join(".codex")).unwrap();
            fs::write(ambient.join(".codex").join(AUTH_FILENAME), "{}").unwrap();

            let result = resolve_auth_source("agent-1", Some(&ambient));
            assert!(result.is_none(), "OPENAI_API_KEY set must skip auth linking entirely");
        }

        #[test]
        fn resolve_auth_source_uses_pinned_home_when_valid() {
            let _guard = AUTH_ENV_LOCK.lock().unwrap();
            std::env::remove_var("OPENAI_API_KEY");
            std::env::remove_var("LOOM_CODEX_HOMES_DIR");

            let tmp = tempfile::tempdir().unwrap();
            let pinned = tmp.path().join("pinned-profile");
            fs::create_dir_all(&pinned).unwrap();
            fs::write(pinned.join(AUTH_FILENAME), "{}").unwrap();
            let _pin_guard = EnvGuard::set("LOOM_CODEX_HOME", pinned.to_str().unwrap());

            let result = resolve_auth_source("agent-1", None);
            let (name, path) = result.expect("pinned profile should resolve");
            assert_eq!(name, "pinned-profile");
            assert_eq!(path, pinned.join(AUTH_FILENAME));
        }

        #[test]
        fn resolve_auth_source_falls_through_bad_pin_to_ambient() {
            let _guard = AUTH_ENV_LOCK.lock().unwrap();
            std::env::remove_var("OPENAI_API_KEY");
            std::env::remove_var("LOOM_CODEX_HOMES_DIR");

            let tmp = tempfile::tempdir().unwrap();
            let bad_pin = tmp.path().join("bad-pin");
            fs::create_dir_all(&bad_pin).unwrap(); // no auth.json
            let _pin_guard = EnvGuard::set("LOOM_CODEX_HOME", bad_pin.to_str().unwrap());

            let ambient = tmp.path().join("fake-home");
            fs::create_dir_all(ambient.join(".codex")).unwrap();
            fs::write(ambient.join(".codex").join(AUTH_FILENAME), "{}").unwrap();

            let (name, path) = resolve_auth_source("agent-1", Some(&ambient))
                .expect("should fall through to ambient auth");
            assert_eq!(name, "ambient");
            assert_eq!(path, ambient.join(".codex").join(AUTH_FILENAME));
        }

        #[test]
        fn resolve_auth_source_uses_pool_selection_when_homes_dir_set() {
            let _guard = AUTH_ENV_LOCK.lock().unwrap();
            std::env::remove_var("OPENAI_API_KEY");
            std::env::remove_var("LOOM_CODEX_HOME");

            let tmp = tempfile::tempdir().unwrap();
            let homes = tmp.path().join("pool");
            make_profile(&homes, "acct-a", Some("{}"));
            make_profile(&homes, "acct-b", Some("{}"));
            let _homes_guard = EnvGuard::set("LOOM_CODEX_HOMES_DIR", homes.to_str().unwrap());

            let (name, path) =
                resolve_auth_source("agent-fixed", None).expect("pool should resolve a profile");
            assert!(homes.join(&name).join(AUTH_FILENAME) == path);

            // Determinism: same agent name -> same pick, repeated calls.
            let (name2, _) = resolve_auth_source("agent-fixed", None).unwrap();
            assert_eq!(name, name2);
        }

        #[test]
        fn resolve_auth_source_pinned_wins_over_homes_dir() {
            let _guard = AUTH_ENV_LOCK.lock().unwrap();
            std::env::remove_var("OPENAI_API_KEY");

            let tmp = tempfile::tempdir().unwrap();
            let pinned = tmp.path().join("pinned-profile");
            fs::create_dir_all(&pinned).unwrap();
            fs::write(pinned.join(AUTH_FILENAME), "{}").unwrap();
            let _pin_guard = EnvGuard::set("LOOM_CODEX_HOME", pinned.to_str().unwrap());

            let homes = tmp.path().join("pool");
            make_profile(&homes, "acct-a", Some("{}"));
            let _homes_guard = EnvGuard::set("LOOM_CODEX_HOMES_DIR", homes.to_str().unwrap());

            let (name, _) = resolve_auth_source("agent-1", None).unwrap();
            assert_eq!(name, "pinned-profile");
        }

        #[test]
        fn resolve_auth_source_falls_through_to_ambient_when_nothing_configured() {
            let _guard = AUTH_ENV_LOCK.lock().unwrap();
            std::env::remove_var("OPENAI_API_KEY");
            std::env::remove_var("LOOM_CODEX_HOME");
            std::env::remove_var("LOOM_CODEX_HOMES_DIR");

            let tmp = tempfile::tempdir().unwrap();
            let ambient = tmp.path().join("fake-home");
            fs::create_dir_all(ambient.join(".codex")).unwrap();
            fs::write(ambient.join(".codex").join(AUTH_FILENAME), "{}").unwrap();

            let (name, path) = resolve_auth_source("agent-1", Some(&ambient))
                .expect("should fall through to ambient auth");
            assert_eq!(name, "ambient");
            assert_eq!(path, ambient.join(".codex").join(AUTH_FILENAME));
        }

        #[test]
        fn resolve_auth_source_none_when_no_ambient_auth_exists_either() {
            // CRITICAL regression guard for the issue #36 safety requirement:
            // when there is truly nothing to link anywhere, resolve_auth_source
            // returns None (not an empty-string placeholder or a panic) and
            // the caller (setup_agent_config_dir) leaves the isolated
            // CODEX_HOME without an auth.json — which is safe/expected only
            // because there was no ambient auth to shadow in the first place.
            let _guard = AUTH_ENV_LOCK.lock().unwrap();
            std::env::remove_var("OPENAI_API_KEY");
            std::env::remove_var("LOOM_CODEX_HOME");
            std::env::remove_var("LOOM_CODEX_HOMES_DIR");

            let tmp = tempfile::tempdir().unwrap();
            let ambient = tmp.path().join("fake-home-with-no-codex-login");
            fs::create_dir_all(&ambient).unwrap(); // no .codex dir at all

            assert_eq!(resolve_auth_source("agent-1", Some(&ambient)), None);
        }

        /// CRITICAL safety test: resolve_auth_source's return value and the
        /// Debug/Display of any error path must never surface auth.json
        /// *contents* — only names and paths. This guards against a future
        /// change accidentally reading and logging the file body.
        #[test]
        fn resolve_auth_source_never_exposes_auth_json_content() {
            let _guard = AUTH_ENV_LOCK.lock().unwrap();
            std::env::remove_var("OPENAI_API_KEY");
            std::env::remove_var("LOOM_CODEX_HOMES_DIR");

            const SECRET_MARKER: &str = "sk-super-secret-should-never-appear-anywhere";
            let tmp = tempfile::tempdir().unwrap();
            let pinned = tmp.path().join("pinned-profile");
            fs::create_dir_all(&pinned).unwrap();
            fs::write(pinned.join(AUTH_FILENAME), SECRET_MARKER).unwrap();
            let _pin_guard = EnvGuard::set("LOOM_CODEX_HOME", pinned.to_str().unwrap());

            let (name, path) = resolve_auth_source("agent-1", None).unwrap();
            assert!(!name.contains(SECRET_MARKER));
            assert!(!path.to_string_lossy().contains(SECRET_MARKER));
        }
    }
}

/// The set of environment variables a preparer wants set on the tmux session,
/// plus the config directory it materialized.
struct PreparedEnv {
    /// `(name, value)` pairs to `tmux set-environment` on the session.
    env_vars: Vec<(String, String)>,
}

/// A per-worker-type "environment preparer".
///
/// `create_terminal` selects one of these from the terminal's `worker_type`
/// (issue #21, epic #1). Each preparer materializes an isolated per-agent
/// config directory and reports the environment variables the worker CLI needs.
/// The two implementations are strictly disjoint: the Claude preparer performs
/// ONLY Claude config work (Keychain clone, onboarding skip, `.claude` links)
/// and the Codex preparer performs ONLY Codex config work (`CODEX_HOME`,
/// prompts symlink) — neither touches the other's state.
trait EnvironmentPreparer {
    /// Short worker-type name (`"claude"` / `"codex"`), used for logging/tests.
    fn name(&self) -> &'static str;

    /// Materialize the isolated config dir and return the env vars to set.
    ///
    /// Returns `None` when the config dir could not be created (best-effort;
    /// the caller then skips env setup for this terminal).
    fn prepare(&self, agent_name: &str, repo_root: &Path) -> Option<PreparedEnv>;
}

/// Claude preparer — wraps the pre-existing [`claude_config`] module verbatim.
struct ClaudePreparer;

impl EnvironmentPreparer for ClaudePreparer {
    fn name(&self) -> &'static str {
        "claude"
    }

    fn prepare(&self, agent_name: &str, repo_root: &Path) -> Option<PreparedEnv> {
        let config_dir = claude_config::setup_agent_config_dir(agent_name, repo_root)?;
        let config_dir_str = config_dir.to_string_lossy().to_string();
        let tmp_dir_str = config_dir.join("tmp").to_string_lossy().to_string();
        Some(PreparedEnv {
            env_vars: vec![
                ("CLAUDE_CONFIG_DIR".to_string(), config_dir_str),
                ("TMPDIR".to_string(), tmp_dir_str),
            ],
        })
    }
}

/// Codex preparer — sets up `CODEX_HOME`; skips all Claude config work.
struct CodexPreparer;

impl EnvironmentPreparer for CodexPreparer {
    fn name(&self) -> &'static str {
        "codex"
    }

    fn prepare(&self, agent_name: &str, repo_root: &Path) -> Option<PreparedEnv> {
        let config_dir = codex_config::setup_agent_config_dir(agent_name, repo_root)?;
        let config_dir_str = config_dir.to_string_lossy().to_string();
        Some(PreparedEnv {
            env_vars: vec![("CODEX_HOME".to_string(), config_dir_str)],
        })
    }
}

/// Select the environment preparer for a terminal's `worker_type`.
///
/// Defaults to Claude when `worker_type` is `None`, empty, or unrecognized —
/// matching the #2 empty-string-means-unset convention. Only an explicit
/// `"codex"` (case-insensitive) selects the Codex preparer.
fn select_environment_preparer(worker_type: Option<&str>) -> Box<dyn EnvironmentPreparer> {
    match worker_type
        .map(str::trim)
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("codex") => Box::new(CodexPreparer),
        _ => Box::new(ClaudePreparer),
    }
}

/// Build the pipe-pane command string that strips ANSI escape sequences from output.
///
/// The sed command removes:
/// - Standard ANSI escape sequences: ESC[...letter (colors, cursor, modes)
/// - Terminal mode queries: ESC[?...h/l (like ?2026h/l)
/// - OSC sequences: ESC]...BEL (title setting, etc.)
/// - Carriage returns (\r) from TUI line rewriting
/// - Backspaces (\x08) from cursor corrections
/// - Bare escape sequences (ESC not followed by [ or ]) from raw cursor movement
fn pipe_pane_cmd(output_file: &str) -> String {
    format!("sed -E 's/\\x1b\\[[?0-9;]*[a-zA-Z]//g; s/\\x1b\\][^\\x07]*\\x07//g; s/\\r//g; s/\\x08//g; s/\\x1b[^][]//g' >> {output_file}")
}

pub struct TerminalManager {
    terminals: HashMap<TerminalId, TerminalInfo>,
}

impl TerminalManager {
    pub fn new() -> Self {
        Self {
            terminals: HashMap::new(),
        }
    }

    /// Validate terminal ID to prevent command injection
    /// Only allows alphanumeric characters, hyphens, and underscores
    fn validate_terminal_id(id: &str) -> Result<()> {
        if id.is_empty() {
            return Err(anyhow!("Terminal ID cannot be empty"));
        }

        if !id
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
        {
            return Err(anyhow!(
                "Invalid terminal ID: '{id}'. Only alphanumeric characters, hyphens, and underscores are allowed"
            ));
        }

        Ok(())
    }

    /// Derive the repository root from a working directory or `LOOM_WORKSPACE` env var.
    fn find_repo_root(working_dir: Option<&str>) -> Option<PathBuf> {
        working_dir
            .map(Path::new)
            .and_then(|p| {
                p.ancestors()
                    .find(|ancestor| ancestor.join(".loom").is_dir())
            })
            .map(Path::to_path_buf)
            .or_else(|| std::env::var("LOOM_WORKSPACE").ok().map(PathBuf::from))
    }

    /// Derive the repository root by walking up from a worktree path.
    ///
    /// Distinct from `find_repo_root` above (which starts from a tmux session's
    /// `working_dir` / `LOOM_WORKSPACE`): this walks a *worktree* path
    /// (e.g. `/repo/.loom/worktrees/issue-42` or `/Volumes/Ext/repo/issue-42`)
    /// looking for the ancestor that contains both `.loom/` and `.git`, i.e. the
    /// main workspace. Used by `destroy_terminal()` both to gate override-aware
    /// worktree GC and to run `git worktree remove` from the repo root.
    fn find_repo_root_from_worktree(worktree_path: &Path) -> Option<PathBuf> {
        worktree_path
            .ancestors()
            .find(|p| p.join(".loom").is_dir() && p.join(".git").exists())
            .map(Path::to_path_buf)
    }

    /// Whether `LOOM_PRESERVE_WORKTREE` disables worktree cleanup for this run.
    ///
    /// Mirrors `defaults/scripts/agent-destroy.sh`'s guard exactly: bash tests
    /// `[[ "${LOOM_PRESERVE_WORKTREE:-0}" == "1" ]]`, i.e. an **exact-string**
    /// comparison against `"1"` — *not* a truthy/falsy coercion. So
    /// `LOOM_PRESERVE_WORKTREE=true` or `=yes` does NOT enable preserve, matching
    /// bash. When set, cleanup is skipped unconditionally (the outermost guard).
    fn preserve_worktree_env() -> bool {
        std::env::var("LOOM_PRESERVE_WORKTREE").is_ok_and(|v| v == "1")
    }

    /// Whether the worktree at `worktree_path` is eligible for automatic removal
    /// under the Loom ownership model (issue #3334).
    ///
    /// Mirrors `defaults/scripts/agent-destroy.sh` (~lines 129-160): only
    /// worktrees carrying a `.loom-managed` sentinel file in their root are
    /// Loom-created and thus eligible for cleanup. A missing sentinel means the
    /// worktree is user-owned; we refuse to remove it and log a warning worded
    /// identically to bash (`— refusing to remove (user-owned)`, using an em dash).
    ///
    /// The `LOOM_PRESERVE_WORKTREE=1` override is checked first (outermost), so a
    /// preserve request short-circuits ahead of the sentinel check — parity with
    /// bash's outer-to-inner guard ordering.
    fn worktree_removal_allowed(worktree_path: &Path) -> bool {
        if Self::preserve_worktree_env() {
            log::info!(
                "Worktree cleanup skipped (LOOM_PRESERVE_WORKTREE=1): {}",
                worktree_path.display()
            );
            return false;
        }

        if !worktree_path.join(".loom-managed").is_file() {
            log::warn!(
                "Worktree at {} lacks .loom-managed sentinel — refusing to remove (user-owned)",
                worktree_path.display()
            );
            return false;
        }

        true
    }

    /// Set up per-agent config-dir isolation for a tmux session.
    ///
    /// Selects a per-worker-type environment preparer (issue #21) from
    /// `worker_type` — Claude by default, Codex for `worker_type == "codex"` —
    /// materializes that runtime's isolated config directory, and sets the
    /// resulting environment variables (`CLAUDE_CONFIG_DIR`/`TMPDIR` for Claude,
    /// `CODEX_HOME` for Codex) on the tmux session.
    fn setup_config_dir_isolation(
        terminal_id: &str,
        working_dir: Option<&str>,
        tmux_session: &str,
        worker_type: Option<&str>,
    ) {
        let Some(repo_root) = Self::find_repo_root(working_dir) else {
            log::debug!(
                "No repo root found for terminal {terminal_id}; skipping config-dir isolation"
            );
            return;
        };

        let preparer = select_environment_preparer(worker_type);
        let Some(env) = preparer.prepare(terminal_id, &repo_root) else {
            return;
        };

        for (var_name, var_value) in &env.env_vars {
            let _ = Command::new("tmux")
                .args(["-L", "loom"])
                .args(["set-environment", "-t", tmux_session, var_name, var_value])
                .output();
        }

        log::info!(
            "Set {} isolation env for session {tmux_session}: {}",
            preparer.name(),
            env.env_vars
                .iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>()
                .join(", ")
        );
    }

    /// Handle tmux command errors with consistent logging
    /// Returns true if the error indicates the tmux server is dead
    fn handle_tmux_error(stderr: &str, operation: &str) -> bool {
        if stderr.contains("no server running") {
            log::error!(
                "🚨 TMUX SERVER DEAD during {operation} - Socket should be at /private/tmp/tmux-$UID/loom"
            );
            true
        } else if stderr.contains("no sessions") || stderr.contains("no such session") {
            log::debug!("No tmux sessions found during {operation}: {stderr}");
            false
        } else {
            log::error!("tmux {operation} failed: {stderr}");
            false
        }
    }

    /// Kill the process tree rooted at a tmux session's pane processes.
    ///
    /// When tmux kill-session sends SIGHUP, it doesn't propagate across process group
    /// boundaries. The `claude` CLI is typically behind a wrapper/timeout chain that
    /// creates separate process groups, so it survives session destruction as an orphan.
    ///
    /// This method kills the entire process tree first (SIGTERM then SIGKILL escalation),
    /// then destroys the tmux session.
    fn kill_process_tree(session_name: &str, force: bool) {
        // Get pane PIDs for this session
        let pane_output = Command::new("tmux")
            .args(["-L", "loom"])
            .args(["list-panes", "-t", session_name, "-F", "#{pane_pid}"])
            .output();

        let pane_pids: Vec<String> = match pane_output {
            Ok(output) if output.status.success() => String::from_utf8_lossy(&output.stdout)
                .lines()
                .filter(|l| !l.is_empty())
                .map(std::string::ToString::to_string)
                .collect(),
            _ => {
                log::debug!("Could not get pane PIDs for session {session_name}");
                Vec::new()
            }
        };

        if pane_pids.is_empty() {
            return;
        }

        // Collect all descendant PIDs (depth-first for bottom-up kill)
        let mut all_pids: Vec<String> = Vec::new();
        for pane_pid in &pane_pids {
            Self::collect_descendants(pane_pid, &mut all_pids);
            all_pids.push(pane_pid.clone());
        }

        if all_pids.is_empty() {
            return;
        }

        log::info!(
            "Killing process tree for session {session_name}: {} process(es)",
            all_pids.len()
        );

        if force {
            // Force mode: SIGKILL immediately
            for pid in &all_pids {
                let _ = Command::new("kill").args(["-9", pid]).output();
            }
        } else {
            // Graceful mode: SIGTERM first
            for pid in &all_pids {
                let _ = Command::new("kill").args(["-15", pid]).output();
            }

            // Brief wait for processes to terminate
            std::thread::sleep(std::time::Duration::from_secs(1));

            // Escalate to SIGKILL for any survivors
            for pid in &all_pids {
                // Check if process is still alive (kill -0)
                if Command::new("kill")
                    .args(["-0", pid])
                    .output()
                    .is_ok_and(|o| o.status.success())
                {
                    let _ = Command::new("kill").args(["-9", pid]).output();
                }
            }
        }
    }

    /// Recursively collect all descendant PIDs of a given PID (depth-first)
    fn collect_descendants(parent_pid: &str, pids: &mut Vec<String>) {
        let output = Command::new("pgrep").args(["-P", parent_pid]).output();

        if let Ok(output) = output {
            if output.status.success() {
                let children: Vec<String> = String::from_utf8_lossy(&output.stdout)
                    .lines()
                    .filter(|l| !l.is_empty())
                    .map(std::string::ToString::to_string)
                    .collect();

                for child in &children {
                    // Recurse into grandchildren first (depth-first)
                    Self::collect_descendants(child, pids);
                    pids.push(child.clone());
                }
            }
        }
    }

    pub fn create_terminal(
        &mut self,
        config_id: &str,
        name: String,
        working_dir: Option<String>,
        role: Option<&String>,
        instance_number: Option<u32>,
        worker_type: Option<&str>,
    ) -> Result<TerminalId> {
        // Validate terminal ID to prevent command injection
        Self::validate_terminal_id(config_id)?;

        // Use config_id directly as the terminal ID
        let id = config_id.to_string();
        let role_part = role.map_or("default", String::as_str);
        let instance_part = instance_number.unwrap_or(0);
        let tmux_session = format!("loom-{id}-{role_part}-{instance_part}");

        log::info!("Creating tmux session: {tmux_session}, working_dir: {working_dir:?}");

        // First, verify tmux server is responsive
        let check_output = Command::new("tmux")
            .args(["-L", "loom", "list-sessions"])
            .output();

        match check_output {
            Ok(out) if !out.status.success() => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                // Special case: constructor only warns about server not running
                if stderr.contains("no server running") {
                    log::warn!("tmux server not running, will start on first session creation");
                } else {
                    Self::handle_tmux_error(&stderr, "new");
                }
            }
            Err(e) => {
                log::error!("Failed to check tmux server status: {e}");
            }
            _ => {}
        }

        let mut cmd = Command::new("tmux");
        cmd.args(["-L", "loom"]);
        cmd.args([
            "new-session",
            "-d",
            "-s",
            &tmux_session,
            "-x",
            "80", // Standard width: 80 columns
            "-y",
            "24", // Standard height: 24 rows
        ]);

        if let Some(dir) = &working_dir {
            cmd.args(["-c", dir]);
        }

        log::info!("About to spawn tmux command...");
        let result = cmd.spawn()?.wait()?;
        log::info!("Tmux command completed with status: {result}");

        if !result.success() {
            // Get more details about the failure
            let stderr_output = Command::new("tmux")
                .args(["-L", "loom", "list-sessions"])
                .output();

            if let Ok(out) = stderr_output {
                let stderr = String::from_utf8_lossy(&out.stderr);
                log::error!("tmux session creation failed. Server status: {stderr}");
            }

            return Err(anyhow!("Failed to create tmux session '{tmux_session}'"));
        }

        // Set up pipe-pane to capture output with ANSI stripping
        let output_file = format!("/tmp/loom-{id}.out");
        let pipe_cmd = pipe_pane_cmd(&output_file);

        log::info!("Setting up pipe-pane for session {tmux_session} to {output_file}");
        let result = Command::new("tmux")
            .args(["-L", "loom"])
            .args(["pipe-pane", "-t", &tmux_session, "-o", &pipe_cmd])
            .output()?;

        if !result.status.success() {
            let stderr = String::from_utf8_lossy(&result.stderr);
            log::error!("pipe-pane failed for session {tmux_session}: {stderr}");

            // Check if session still exists
            let check = Command::new("tmux")
                .args(["-L", "loom", "has-session", "-t", &tmux_session])
                .output();

            if let Ok(out) = check {
                if out.status.success() {
                    log::error!("Session {tmux_session} exists but pipe-pane setup failed");
                } else {
                    log::error!("Session {tmux_session} disappeared during pipe-pane setup!");
                }
            }

            return Err(anyhow!("Failed to set up pipe-pane for {tmux_session}: {stderr}"));
        }
        log::info!("pipe-pane setup successful for session {tmux_session}");

        // Set up per-agent config-dir isolation for the selected worker type
        Self::setup_config_dir_isolation(&id, working_dir.as_deref(), &tmux_session, worker_type);

        let info = TerminalInfo {
            id: id.clone(),
            name,
            tmux_session,
            working_dir,
            created_at: chrono::Utc::now().timestamp(),
            role: role.cloned(),
            worktree_path: None,
            agent_pid: None,
            agent_status: crate::types::AgentStatus::default(),
            last_interval_run: None,
        };

        self.terminals.insert(id.clone(), info);
        Ok(id)
    }

    pub fn list_terminals(&mut self) -> Vec<TerminalInfo> {
        // If registry is empty but tmux sessions exist, restore from tmux
        // Skip restore when LOOM_NO_RESTORE=1 is set (used in tests to prevent
        // cross-test-binary contamination via shared tmux server)
        let no_restore = std::env::var("LOOM_NO_RESTORE")
            .is_ok_and(|v| v == "1" || v.eq_ignore_ascii_case("true"));

        if self.terminals.is_empty() && !no_restore {
            log::debug!("Registry empty, attempting to restore from tmux");
            if let Err(e) = self.restore_from_tmux() {
                log::warn!("Failed to restore terminals from tmux: {e}");
            }
        }
        self.terminals.values().cloned().collect()
    }

    pub fn set_worktree_path(&mut self, id: &TerminalId, worktree_path: &str) -> Result<()> {
        let info = self
            .terminals
            .get_mut(id)
            .ok_or_else(|| anyhow!("Terminal not found"))?;

        info.worktree_path = Some(worktree_path.to_string());

        // Set LOOM_WORKTREE_PATH on the tmux session so Claude Code's
        // PreToolUse hook can block Edit/Write outside the worktree (issue #2441).
        let _ = Command::new("tmux")
            .args(["-L", "loom"])
            .args([
                "set-environment",
                "-t",
                &info.tmux_session,
                "LOOM_WORKTREE_PATH",
                worktree_path,
            ])
            .output();

        log::info!("Set worktree path for terminal {id}: {worktree_path}");
        Ok(())
    }

    pub fn destroy_terminal(&mut self, id: &TerminalId) -> Result<()> {
        let info = self
            .terminals
            .get(id)
            .ok_or_else(|| anyhow!("Terminal not found"))?;

        // Capture worktree info before killing the session.
        // We need to kill the tmux session FIRST to avoid leaving the shell's
        // CWD pointing at a deleted worktree path (see issue #2413).
        //
        // The GC gate is override-aware (#3536): a worktree qualifies if it lives
        // under the resolved worktree root (which honors LOOM_WORKTREE_ROOT /
        // `.loom/config.json` → worktree.root) OR contains the historical
        // `.loom/worktrees` substring. We derive `repo_root` from the worktree
        // path *before* the gate so it's available both here and for the later
        // `git worktree remove` invocation without duplicating the ancestor walk.
        let worktree_to_remove: Option<(String, PathBuf, Option<PathBuf>)> =
            if let Some(ref worktree_path) = info.worktree_path {
                let path = PathBuf::from(worktree_path);
                let repo_root = Self::find_repo_root_from_worktree(&path);
                let is_worktree = match repo_root {
                    Some(ref root) => crate::worktree_root::is_worktree_path(&path, root),
                    // No repo root resolved (worktree already partly gone): fall
                    // back to the historical substring check alone.
                    None => path.to_string_lossy().contains(".loom/worktrees"),
                };
                if is_worktree {
                    let other_users = self
                        .terminals
                        .values()
                        .filter(|t| t.id != *id && t.worktree_path.as_ref() == Some(worktree_path))
                        .count();

                    if other_users == 0 {
                        Some((worktree_path.clone(), path, repo_root))
                    } else {
                        log::info!(
                            "Skipping worktree removal at {} ({} other terminal(s) still using it)",
                            path.display(),
                            other_users
                        );
                        None
                    }
                } else {
                    None
                }
            } else {
                None
            };

        // Stop pipe-pane (passing no command closes the pipe)
        let _ = Command::new("tmux")
            .args(["-L", "loom"])
            .args(["pipe-pane", "-t", &info.tmux_session])
            .spawn();

        // Kill process tree before destroying tmux session
        // This prevents orphaned claude processes that survive SIGHUP
        Self::kill_process_tree(&info.tmux_session, false);

        // Kill the tmux session (may already be dead from kill_process_tree)
        let _ = Command::new("tmux")
            .args(["-L", "loom"])
            .args(["kill-session", "-t", &info.tmux_session])
            .spawn()
            .and_then(|mut c| c.wait());

        // Now that the tmux session is dead, safe to remove the worktree
        // without breaking any shell's working directory.
        // Ownership-model guards (bash parity with agent-destroy.sh, #3334):
        // honor LOOM_PRESERVE_WORKTREE=1 (outermost) and refuse to remove a
        // worktree lacking the `.loom-managed` sentinel (user-owned). Both run
        // before the actual `git worktree remove` (and its fs::remove_dir_all
        // fallback). worktree_removal_allowed() logs the reason for a skip; when
        // it returns false we skip only the removal and still fall through to the
        // output-file / CLAUDE_CONFIG_DIR cleanup and registry removal below.
        if let Some((worktree_path, path, repo_root)) = worktree_to_remove {
            if Self::worktree_removal_allowed(&path) {
                log::info!("Removing worktree at {} (no other terminals using it)", path.display());

                // repo_root was resolved before the gate (via find_repo_root_from_worktree)
                // and is reused here to run git from the repo root, avoiding
                // CWD-inside-worktree issues.

                // First try to remove the worktree via git
                let mut cmd = Command::new("git");
                cmd.args(["worktree", "remove", &worktree_path]);
                if let Some(ref root) = repo_root {
                    cmd.current_dir(root);
                }
                let output = cmd.output();

                if let Ok(output) = output {
                    if !output.status.success() {
                        let stderr = String::from_utf8_lossy(&output.stderr);
                        log::warn!("git worktree remove failed: {stderr}");
                        log::info!("Attempting force removal...");

                        // Try force removal
                        let mut cmd = Command::new("git");
                        cmd.args(["worktree", "remove", "--force", &worktree_path]);
                        if let Some(ref root) = repo_root {
                            cmd.current_dir(root);
                        }
                        let _ = cmd.output();
                    }
                }

                // Also try to remove directory manually as fallback
                let _ = fs::remove_dir_all(&path);
            }
        }

        // Clean up the output file
        let output_file = format!("/tmp/loom-{id}.out");
        let _ = std::fs::remove_file(output_file);

        // Clean up per-agent config dirs. The worker type isn't recorded on the
        // terminal, so attempt both preparers' dirs — each is a no-op when its
        // directory is absent.
        if let Some(root) = Self::find_repo_root(info.working_dir.as_deref()) {
            if claude_config::cleanup_agent_config_dir(id, &root) {
                log::info!("Cleaned up CLAUDE_CONFIG_DIR for terminal {id}");
            }
            if codex_config::cleanup_agent_config_dir(id, &root) {
                log::info!("Cleaned up CODEX_HOME for terminal {id}");
            }
        }

        self.terminals.remove(id);
        Ok(())
    }

    pub fn send_input(&self, id: &TerminalId, data: &str) -> Result<()> {
        let info = self
            .terminals
            .get(id)
            .ok_or_else(|| anyhow!("Terminal not found"))?;

        match data {
            "\r" => {
                Command::new("tmux")
                    .args(["-L", "loom"])
                    .args(["send-keys", "-t", &info.tmux_session, "Enter"])
                    .spawn()?;
            }
            "\u{0003}" => {
                Command::new("tmux")
                    .args(["-L", "loom"])
                    .args(["send-keys", "-t", &info.tmux_session, "C-c"])
                    .spawn()?;
            }
            _ => {
                Command::new("tmux")
                    .args(["-L", "loom"])
                    .args(["send-keys", "-t", &info.tmux_session, "-l", data])
                    .spawn()?;
            }
        }

        Ok(())
    }

    #[allow(clippy::cast_possible_truncation, clippy::unused_self)]
    pub fn get_terminal_output(
        &self,
        id: &TerminalId,
        start_byte: Option<usize>,
    ) -> Result<(Vec<u8>, usize)> {
        use std::fs;
        use std::io::{Read, Seek};

        // Use config_id directly for filename
        let output_file = format!("/tmp/loom-{id}.out");
        log::debug!("Reading terminal output from: {output_file}");

        let mut file = match fs::File::open(&output_file) {
            Ok(f) => f,
            Err(e) => {
                // File doesn't exist yet, return empty
                log::debug!("Output file doesn't exist yet: {e}");
                return Ok((Vec::new(), 0));
            }
        };

        // Get file size
        let metadata = file.metadata()?;
        let file_size = metadata.len() as usize;
        log::debug!("Output file size: {file_size} bytes");

        // If start_byte is specified, seek to that position and read from there
        let bytes_to_read = if let Some(start) = start_byte {
            if start >= file_size {
                // No new data
                log::debug!("No new data (start_byte={start} >= file_size={file_size})");
                return Ok((Vec::new(), file_size));
            }
            file.seek(std::io::SeekFrom::Start(start as u64))?;
            let bytes = file_size - start;
            log::debug!("Seeking to byte {start} and reading {bytes} bytes");
            file_size - start
        } else {
            // Read entire file
            log::debug!("Reading entire file ({file_size} bytes)");
            file_size
        };

        let mut buffer = vec![0u8; bytes_to_read];
        file.read_exact(&mut buffer)?;
        log::debug!("Read {len} bytes successfully", len = buffer.len());

        Ok((buffer, file_size))
    }

    pub fn resize_terminal(&self, id: &TerminalId, cols: u16, rows: u16) -> Result<()> {
        let info = self
            .terminals
            .get(id)
            .ok_or_else(|| anyhow!("Terminal not found"))?;

        // Resize tmux window (which resizes the pane when there's only one pane)
        Command::new("tmux")
            .args(["-L", "loom"])
            .args([
                "resize-window",
                "-t",
                &info.tmux_session,
                "-x",
                &cols.to_string(),
                "-y",
                &rows.to_string(),
            ])
            .spawn()?
            .wait()?;

        Ok(())
    }

    /// Restore terminals from existing tmux sessions.
    ///
    /// By default (no filter), imports ALL `loom-*` sessions for backward compatibility.
    /// When a filter is provided via `restore_from_tmux_with_filter`, only sessions
    /// matching configured terminal IDs are restored. This prevents importing stale
    /// sessions from crashed daemons or other daemon instances.
    pub fn restore_from_tmux(&mut self) -> Result<()> {
        self.restore_from_tmux_with_filter(None)
    }

    /// Restore terminals from existing tmux sessions, optionally filtering by configured IDs.
    ///
    /// # Arguments
    /// * `configured_ids` - If Some, only restore sessions whose extracted terminal ID
    ///   matches one of the configured IDs. If None, restore all loom-* sessions.
    ///
    /// # Session Ownership (Issue #1952)
    /// Without filtering, the daemon imports ANY `loom-*` session, which causes:
    /// - Test interference between different test binaries
    /// - Stale session accumulation from crashed daemons
    /// - No ownership verification between daemon instances
    ///
    /// With filtering (recommended), only sessions matching the workspace's config.json
    /// terminal definitions are restored, providing configuration-based ownership.
    pub fn restore_from_tmux_with_filter(
        &mut self,
        configured_ids: Option<&std::collections::HashSet<String>>,
    ) -> Result<()> {
        let output = Command::new("tmux")
            .args(["-L", "loom"])
            .args(["list-sessions", "-F", "#{session_name}"])
            .output()?;

        // Enhanced logging: Check for tmux server failure
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Self::handle_tmux_error(&stderr, "restore_from_tmux");

            // Return early with empty list if server is dead
            return Ok(());
        }

        let sessions = String::from_utf8_lossy(&output.stdout);
        let session_count = sessions.lines().count();
        log::info!("📊 tmux server status: {session_count} total sessions");

        if let Some(ids) = configured_ids {
            log::info!(
                "🔒 Configuration-based restore: filtering to {} configured terminal(s)",
                ids.len()
            );
        } else {
            log::debug!("📦 Legacy restore: importing all loom-* sessions (no filter)");
        }

        let mut restored_count = 0;
        let mut skipped_count = 0;

        for session in sessions.lines() {
            if let Some(remainder) = session.strip_prefix("loom-") {
                // Session format: loom-{config_id}-{role}-{instance}
                // Extract config_id by checking for the "terminal-{number}" pattern
                //
                // Example session: loom-terminal-1-claude-code-worker-64
                // After strip_prefix: terminal-1-claude-code-worker-64
                // Split by '-': ["terminal", "1", "claude", "code", "worker", "64"]
                //
                // Strategy: If format is "terminal-{number}-...", extract "terminal-{number}"
                // Otherwise use first part for backwards compatibility

                let parts: Vec<&str> = remainder.split('-').collect();
                if parts.is_empty() {
                    log::warn!("Skipping malformed session name: {session}");
                    continue;
                }

                // Check if this matches the "terminal-{number}" pattern
                let id = if parts.len() >= 2
                    && parts[0] == "terminal"
                    && parts[1].chars().all(|c| c.is_ascii_digit())
                {
                    // Format: terminal-{number}-{role}-{instance}
                    // Extract "terminal-{number}" as the ID
                    format!("{}-{}", parts[0], parts[1])
                } else {
                    // For backwards compatibility with old format (no hyphens in ID),
                    // use first part as the terminal ID
                    parts[0].to_string()
                };

                // Validate terminal ID to prevent command injection
                if let Err(e) = Self::validate_terminal_id(&id) {
                    log::warn!("Skipping invalid terminal ID from tmux session {session}: {e}");
                    continue;
                }

                // If filter is provided, skip sessions not in the configured set
                if let Some(ids) = configured_ids {
                    if !ids.contains(&id) {
                        log::debug!(
                            "Skipping unconfigured session {session} (terminal ID '{id}' not in config)"
                        );
                        skipped_count += 1;
                        continue;
                    }
                }

                // Clear any existing pipe-pane for this session to avoid duplicates
                log::debug!("Clearing existing pipe-pane for session {session}");
                let _ = Command::new("tmux")
                    .args(["-L", "loom"])
                    .args(["pipe-pane", "-t", session])
                    .spawn();

                // Set up fresh pipe-pane to capture output with ANSI stripping
                let output_file = format!("/tmp/loom-{id}.out");
                let pipe_cmd = pipe_pane_cmd(&output_file);

                log::info!("Setting up pipe-pane for session {session} to {output_file}");
                let result = Command::new("tmux")
                    .args(["-L", "loom"])
                    .args(["pipe-pane", "-t", session, "-o", &pipe_cmd])
                    .output()?;

                if result.status.success() {
                    log::info!("pipe-pane setup successful for {session}");
                } else {
                    let stderr = String::from_utf8_lossy(&result.stderr);
                    log::warn!("pipe-pane setup failed for {session}: {stderr}");
                    // Continue anyway - terminal is still usable
                }

                self.terminals
                    .entry(id.clone())
                    .or_insert_with(|| TerminalInfo {
                        id: id.clone(),
                        name: format!("Restored: {session}"),
                        tmux_session: session.to_string(),
                        working_dir: None,
                        created_at: chrono::Utc::now().timestamp(),
                        role: None,
                        worktree_path: None,
                        agent_pid: None,
                        agent_status: crate::types::AgentStatus::default(),
                        last_interval_run: None,
                    });

                restored_count += 1;
            }
        }

        if configured_ids.is_some() {
            log::info!(
                "📊 Restore complete: {restored_count} restored, {skipped_count} skipped (unconfigured)"
            );
        }

        Ok(())
    }

    /// Clean up stale tmux sessions from previous daemon runs.
    /// Lists all loom-* sessions and kills any that weren't restored
    /// into the terminal registry by `restore_from_tmux()`.
    pub fn clean_stale_sessions(&self) -> Result<usize> {
        let output = Command::new("tmux")
            .args(["-L", "loom"])
            .args(["list-sessions", "-F", "#{session_name}"])
            .output()?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if stderr.contains("no server running") || stderr.contains("no sessions") {
                return Ok(0);
            }
            log::warn!("Failed to list tmux sessions for cleanup: {stderr}");
            return Ok(0);
        }

        let sessions = String::from_utf8_lossy(&output.stdout);

        // Build a set of tmux session names that are tracked in the registry
        let tracked_sessions: std::collections::HashSet<&str> = self
            .terminals
            .values()
            .map(|t| t.tmux_session.as_str())
            .collect();

        let mut cleaned = 0;
        for session in sessions.lines() {
            if !session.starts_with("loom-") {
                continue;
            }

            if tracked_sessions.contains(session) {
                continue;
            }

            log::info!("Cleaning stale tmux session: {session}");

            // Kill process tree before destroying the stale session
            Self::kill_process_tree(session, true);

            // Force kill the session (may already be dead)
            let result = Command::new("tmux")
                .args(["-L", "loom"])
                .args(["kill-session", "-t", session])
                .output();

            match result {
                Ok(out) if out.status.success() => {
                    cleaned += 1;
                }
                Ok(out) => {
                    let stderr = String::from_utf8_lossy(&out.stderr);
                    // Session may already be dead from kill_process_tree
                    if !stderr.contains("no such session") {
                        log::warn!("Failed to kill stale session {session}: {stderr}");
                    }
                    cleaned += 1;
                }
                Err(e) => {
                    log::warn!("Failed to kill stale session {session}: {e}");
                }
            }
        }

        Ok(cleaned)
    }

    /// Check if a tmux session exists for the given terminal ID
    pub fn has_tmux_session(&self, id: &TerminalId) -> Result<bool> {
        log::info!("🔍 has_tmux_session called for terminal id: '{id}'");
        log::info!(
            "📋 Registry has {} terminals: {:?}",
            self.terminals.len(),
            self.terminals.keys().collect::<Vec<_>>()
        );

        // First check if we have this terminal registered
        if let Some(info) = self.terminals.get(id) {
            // Terminal is registered - check its specific tmux session
            log::info!(
                "✅ Terminal '{}' found in registry, checking session: '{}'",
                id,
                info.tmux_session
            );
            let output = Command::new("tmux")
                .args(["-L", "loom"])
                .args(["has-session", "-t", &info.tmux_session])
                .output()?;

            let result = output.status.success();
            log::info!("📊 tmux has-session result for '{}': {}", info.tmux_session, result);
            return Ok(result);
        }

        // Terminal not registered yet - check if ANY loom session with this ID exists
        // This handles the race condition where frontend creates state before daemon registers
        log::warn!("⚠️  Terminal '{id}' NOT found in registry, checking tmux sessions directly");

        let output = Command::new("tmux")
            .args(["-L", "loom"])
            .args(["list-sessions", "-F", "#{session_name}"])
            .output()?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Self::handle_tmux_error(&stderr, "has_tmux_session");

            return Ok(false);
        }

        let sessions = String::from_utf8_lossy(&output.stdout);
        let prefix = format!("loom-{id}-");

        // Check if any session matches our terminal ID prefix
        let has_session = sessions.lines().any(|s| s.starts_with(&prefix));

        log::debug!(
            "Terminal {id} tmux session check (unregistered): {}",
            if has_session { "found" } else { "not found" }
        );

        Ok(has_session)
    }

    /// List all available loom tmux sessions
    #[allow(clippy::unused_self)]
    pub fn list_available_sessions(&self) -> Vec<String> {
        let output = Command::new("tmux")
            .args(["-L", "loom"])
            .args(["list-sessions", "-F", "#{session_name}"])
            .output();

        // If tmux list-sessions fails (no server running), return empty vec
        let Ok(output) = output else {
            log::error!("Failed to execute tmux list-sessions command");
            return Vec::new();
        };

        // Enhanced logging: Check for tmux server failure
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Self::handle_tmux_error(&stderr, "list_available_sessions");

            return Vec::new();
        }

        let sessions = String::from_utf8_lossy(&output.stdout);
        let loom_sessions: Vec<String> = sessions
            .lines()
            .filter(|s| s.starts_with("loom-"))
            .map(std::string::ToString::to_string)
            .collect();

        log::info!("📊 Found {} loom sessions", loom_sessions.len());
        loom_sessions
    }

    /// Attach an existing terminal record to a different tmux session
    pub fn attach_to_session(&mut self, id: &TerminalId, session_name: String) -> Result<()> {
        let info = self
            .terminals
            .get_mut(id)
            .ok_or_else(|| anyhow!("Terminal not found"))?;

        // Verify the session exists
        let output = Command::new("tmux")
            .args(["-L", "loom"])
            .args(["has-session", "-t", &session_name])
            .output()?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);

            // Enhanced logging: Distinguish failure modes
            if Self::handle_tmux_error(&stderr, "attach_to_session") {
                return Err(anyhow!("tmux server is not running"));
            }

            log::error!("tmux has-session failed for '{session_name}': {stderr}");
            return Err(anyhow!("Tmux session '{session_name}' does not exist"));
        }

        // Update the terminal info to point to the new session
        info.tmux_session = session_name;

        Ok(())
    }

    /// Kill a tmux session by name
    #[allow(clippy::unused_self)]
    pub fn kill_session(&self, session_name: &str) -> Result<()> {
        // Verify the session exists
        let check_output = Command::new("tmux")
            .args(["-L", "loom"])
            .args(["has-session", "-t", session_name])
            .output()?;

        if !check_output.status.success() {
            let stderr = String::from_utf8_lossy(&check_output.stderr);

            // Enhanced logging: Distinguish failure modes
            if Self::handle_tmux_error(&stderr, "kill_session") {
                return Err(anyhow!("tmux server is not running"));
            }

            log::error!("tmux has-session failed for '{session_name}': {stderr}");
            return Err(anyhow!("Tmux session '{session_name}' does not exist"));
        }

        // Kill process tree before destroying the session
        Self::kill_process_tree(session_name, false);

        // Kill the session (may already be dead from kill_process_tree)
        let _ = Command::new("tmux")
            .args(["-L", "loom"])
            .args(["kill-session", "-t", session_name])
            .spawn()
            .and_then(|mut c| c.wait());

        log::info!("Killed tmux session: {session_name}");
        Ok(())
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    // ===== pipe_pane_cmd tests =====

    #[test]
    fn test_pipe_pane_cmd_contains_output_file() {
        let cmd = pipe_pane_cmd("/tmp/loom-test.out");
        assert!(cmd.contains("/tmp/loom-test.out"));
    }

    #[test]
    fn test_pipe_pane_cmd_uses_sed() {
        let cmd = pipe_pane_cmd("/tmp/output.out");
        assert!(cmd.starts_with("sed "));
    }

    #[test]
    fn test_pipe_pane_cmd_strips_ansi_escapes() {
        let cmd = pipe_pane_cmd("/tmp/output.out");
        // Should contain the ANSI escape stripping pattern
        assert!(cmd.contains("\\x1b"));
    }

    #[test]
    fn test_pipe_pane_cmd_appends_to_file() {
        let cmd = pipe_pane_cmd("/tmp/output.out");
        assert!(cmd.contains(">> /tmp/output.out"));
    }

    // ===== validate_terminal_id tests =====

    #[test]
    fn test_validate_terminal_id_empty() {
        let result = TerminalManager::validate_terminal_id("");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("cannot be empty"));
    }

    #[test]
    fn test_validate_terminal_id_valid_alphanumeric() {
        assert!(TerminalManager::validate_terminal_id("terminal1").is_ok());
    }

    #[test]
    fn test_validate_terminal_id_valid_with_hyphens() {
        assert!(TerminalManager::validate_terminal_id("terminal-1").is_ok());
    }

    #[test]
    fn test_validate_terminal_id_valid_with_underscores() {
        assert!(TerminalManager::validate_terminal_id("terminal_1").is_ok());
    }

    #[test]
    fn test_validate_terminal_id_rejects_spaces() {
        let result = TerminalManager::validate_terminal_id("terminal 1");
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("Invalid terminal ID"));
    }

    #[test]
    fn test_validate_terminal_id_rejects_special_chars() {
        for id in &[
            "term;rm -rf /",
            "term$(cmd)",
            "term`cmd`",
            "term|pipe",
            "a/b",
        ] {
            assert!(
                TerminalManager::validate_terminal_id(id).is_err(),
                "Expected rejection for: {id}"
            );
        }
    }

    #[test]
    fn test_validate_terminal_id_rejects_dots() {
        assert!(TerminalManager::validate_terminal_id("terminal.1").is_err());
    }

    // ===== handle_tmux_error tests =====

    #[test]
    fn test_handle_tmux_error_no_server_returns_true() {
        let result = TerminalManager::handle_tmux_error("no server running on /tmp/tmux", "test");
        assert!(result, "Should return true when server is dead");
    }

    #[test]
    fn test_handle_tmux_error_no_sessions_returns_false() {
        let result = TerminalManager::handle_tmux_error("no sessions", "test");
        assert!(!result);
    }

    #[test]
    fn test_handle_tmux_error_no_such_session_returns_false() {
        let result = TerminalManager::handle_tmux_error("no such session: loom-test", "test");
        assert!(!result);
    }

    #[test]
    fn test_handle_tmux_error_other_error_returns_false() {
        let result = TerminalManager::handle_tmux_error("some other tmux error", "test");
        assert!(!result);
    }

    // ===== TerminalManager::new tests =====

    #[test]
    fn test_terminal_manager_new_is_empty() {
        let tm = TerminalManager::new();
        assert!(tm.terminals.is_empty());
    }

    // ===== worktree ownership-model guard tests (#3540) =====
    //
    // These cover the bash-parity guards added to destroy_terminal()'s removal
    // path: the `.loom-managed` sentinel check and the LOOM_PRESERVE_WORKTREE=1
    // override (mirroring defaults/scripts/agent-destroy.sh ~lines 129-160).
    //
    // std::env::set_var mutates process-global state; serialize env-touching
    // tests so parallel `cargo test` execution doesn't race on
    // LOOM_PRESERVE_WORKTREE. Same pattern as worktree_root.rs's ENV_LOCK.
    use std::sync::Mutex;
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    /// Run `f` with LOOM_PRESERVE_WORKTREE set to `value` (or unset if None),
    /// restoring the prior value afterward. Serialized via ENV_LOCK.
    fn with_preserve_env<T>(value: Option<&str>, f: impl FnOnce() -> T) -> T {
        let _guard = ENV_LOCK.lock().unwrap();
        let prev = std::env::var("LOOM_PRESERVE_WORKTREE").ok();
        match value {
            Some(v) => std::env::set_var("LOOM_PRESERVE_WORKTREE", v),
            None => std::env::remove_var("LOOM_PRESERVE_WORKTREE"),
        }
        let result = f();
        match prev {
            Some(p) => std::env::set_var("LOOM_PRESERVE_WORKTREE", p),
            None => std::env::remove_var("LOOM_PRESERVE_WORKTREE"),
        }
        result
    }

    /// Create a worktree dir with a `.loom-managed` sentinel file (simulating a
    /// Loom-created worktree).
    fn make_managed_worktree() -> tempfile::TempDir {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join(".loom-managed"), "").unwrap();
        tmp
    }

    #[test]
    fn removal_allowed_when_sentinel_present_and_env_unset() {
        // The common case: worktree present, `.loom-managed` sentinel present,
        // LOOM_PRESERVE_WORKTREE unset → removal proceeds (no behavior change).
        let wt = make_managed_worktree();
        with_preserve_env(None, || {
            assert!(TerminalManager::worktree_removal_allowed(wt.path()));
        });
    }

    #[test]
    fn removal_skipped_when_sentinel_absent() {
        // A worktree path recorded via set_worktree_path()/SetWorktreePath IPC
        // that lacks `.loom-managed` (user-owned or an unvalidated IPC path) must
        // NOT be removed — the guard refuses it.
        let tmp = tempfile::tempdir().unwrap();
        with_preserve_env(None, || {
            assert!(!TerminalManager::worktree_removal_allowed(tmp.path()));
        });
    }

    #[test]
    fn removal_skipped_when_preserve_env_is_one() {
        // LOOM_PRESERVE_WORKTREE=1 skips removal unconditionally, even with the
        // sentinel present.
        let wt = make_managed_worktree();
        with_preserve_env(Some("1"), || {
            assert!(!TerminalManager::worktree_removal_allowed(wt.path()));
        });
    }

    #[test]
    fn removal_skipped_when_preserve_env_is_one_even_without_sentinel() {
        // The env override is the outermost guard: it short-circuits ahead of the
        // sentinel check, so removal is skipped regardless of sentinel presence.
        let tmp = tempfile::tempdir().unwrap();
        with_preserve_env(Some("1"), || {
            assert!(!TerminalManager::worktree_removal_allowed(tmp.path()));
        });
    }

    #[test]
    fn removal_allowed_when_preserve_env_is_non_one_value() {
        // Parity with bash's exact-string check `[[ ... == "1" ]]`: non-"1"
        // truthy-looking values do NOT enable preserve. With the sentinel present,
        // removal still proceeds.
        let wt = make_managed_worktree();
        for value in ["true", "yes", "0", "", "TRUE", "11", "1 "] {
            with_preserve_env(Some(value), || {
                assert!(
                    TerminalManager::worktree_removal_allowed(wt.path()),
                    "LOOM_PRESERVE_WORKTREE={value:?} must not enable preserve"
                );
            });
        }
    }

    #[test]
    fn preserve_worktree_env_matches_exact_string_one() {
        with_preserve_env(Some("1"), || {
            assert!(TerminalManager::preserve_worktree_env());
        });
        for value in ["true", "yes", "0", "", "01", "1x"] {
            with_preserve_env(Some(value), || {
                assert!(
                    !TerminalManager::preserve_worktree_env(),
                    "LOOM_PRESERVE_WORKTREE={value:?} must not be treated as preserve"
                );
            });
        }
        with_preserve_env(None, || {
            assert!(!TerminalManager::preserve_worktree_env());
        });
    }

    // ===== environment preparer selection (issue #21) =====

    #[test]
    fn test_select_preparer_defaults_to_claude() {
        // None / unset / empty / whitespace / unknown all default to Claude.
        assert_eq!(select_environment_preparer(None).name(), "claude");
        assert_eq!(select_environment_preparer(Some("")).name(), "claude");
        assert_eq!(select_environment_preparer(Some("   ")).name(), "claude");
        assert_eq!(select_environment_preparer(Some("claude")).name(), "claude");
        assert_eq!(select_environment_preparer(Some("gpt-9000")).name(), "claude");
    }

    #[test]
    fn test_select_preparer_codex() {
        // Explicit "codex" (case-insensitive, trimmed) selects the Codex preparer.
        assert_eq!(select_environment_preparer(Some("codex")).name(), "codex");
        assert_eq!(select_environment_preparer(Some("CODEX")).name(), "codex");
        assert_eq!(select_environment_preparer(Some("  Codex  ")).name(), "codex");
    }

    #[test]
    fn test_claude_preparer_sets_claude_env_and_config() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path();
        fs::create_dir_all(repo_root.join(".loom")).unwrap();

        let preparer = select_environment_preparer(Some("claude"));
        let env = preparer.prepare("terminal-claude-1", repo_root).unwrap();

        // Claude preparer exports CLAUDE_CONFIG_DIR + TMPDIR, never CODEX_HOME.
        let keys: Vec<&str> = env.env_vars.iter().map(|(k, _)| k.as_str()).collect();
        assert!(keys.contains(&"CLAUDE_CONFIG_DIR"));
        assert!(keys.contains(&"TMPDIR"));
        assert!(!keys.contains(&"CODEX_HOME"), "Claude preparer must not set CODEX_HOME");

        // The Claude config dir (with its onboarding-skip .claude.json) is created.
        let claude_dir = repo_root.join(".loom/claude-config/terminal-claude-1");
        assert!(claude_dir.join(".claude.json").is_file());
        // And no Codex home was materialized.
        assert!(!repo_root
            .join(".loom/codex-config/terminal-claude-1")
            .exists());
    }

    #[test]
    fn test_codex_preparer_sets_codex_home_and_skips_claude() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path();
        fs::create_dir_all(repo_root.join(".loom")).unwrap();
        // Ship a repo-local .codex/ so the preparer has something to link.
        let repo_codex = repo_root.join(".codex");
        fs::create_dir_all(repo_codex.join("prompts")).unwrap();
        fs::write(repo_codex.join("config.toml"), "# loom\n").unwrap();
        fs::write(repo_codex.join("prompts").join("builder.md"), "# builder\n").unwrap();

        let preparer = select_environment_preparer(Some("codex"));
        let env = preparer.prepare("terminal-codex-1", repo_root).unwrap();

        // Codex preparer exports ONLY CODEX_HOME — no Claude env vars.
        let keys: Vec<&str> = env.env_vars.iter().map(|(k, _)| k.as_str()).collect();
        assert_eq!(keys, vec!["CODEX_HOME"]);
        assert!(!keys.contains(&"CLAUDE_CONFIG_DIR"));
        assert!(!keys.contains(&"TMPDIR"));

        let codex_home = repo_root.join(".loom/codex-config/terminal-codex-1");
        assert!(codex_home.is_dir(), "CODEX_HOME dir must be created");
        assert_eq!(env.env_vars[0].1, codex_home.to_string_lossy());

        // Repo-local config + prompts are wired into the isolated home.
        assert!(codex_home.join("config.toml").exists());
        assert!(codex_home.join("prompts").join("builder.md").is_file());

        // CRITICAL: the Codex preparer must NOT perform Claude keychain /
        // onboarding work — no Claude config dir, no .claude.json, no
        // settings.json is created anywhere for this agent.
        assert!(
            !repo_root
                .join(".loom/claude-config/terminal-codex-1")
                .exists(),
            "Codex preparer must not create a Claude config dir"
        );
        assert!(!codex_home.join(".claude.json").exists());
        assert!(!codex_home.join("settings.json").exists());
    }

    #[test]
    fn test_codex_preparer_ok_without_repo_codex_dir() {
        // A repo with no .codex/ still gets a valid (empty) CODEX_HOME — no panic.
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path();
        fs::create_dir_all(repo_root.join(".loom")).unwrap();

        let prepared = CodexPreparer
            .prepare("terminal-codex-2", repo_root)
            .unwrap();
        let codex_home = repo_root.join(".loom/codex-config/terminal-codex-2");
        assert!(codex_home.is_dir());
        assert_eq!(prepared.env_vars[0].0, "CODEX_HOME");
        // Nothing to link — the symlinks are absent, but that's fine.
        assert!(!codex_home.join("config.toml").exists());
        assert!(!codex_home.join("prompts").exists());
    }

    #[test]
    fn test_codex_cleanup_removes_home() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path();
        fs::create_dir_all(repo_root.join(".loom")).unwrap();

        CodexPreparer
            .prepare("terminal-codex-3", repo_root)
            .unwrap();
        assert!(repo_root
            .join(".loom/codex-config/terminal-codex-3")
            .is_dir());

        assert!(codex_config::cleanup_agent_config_dir("terminal-codex-3", repo_root));
        assert!(!repo_root
            .join(".loom/codex-config/terminal-codex-3")
            .exists());
        // Second cleanup is a no-op.
        assert!(!codex_config::cleanup_agent_config_dir("terminal-codex-3", repo_root));
    }

    // ===== CodexPreparer auth-composition integration tests (issue #36) =====
    //
    // These exercise the auth-linking behaviour through the SAME public
    // entry point production code uses (CodexPreparer::prepare /
    // codex_config::setup_agent_config_dir), reusing the ENV_LOCK above
    // since LOOM_CODEX_HOME / LOOM_CODEX_HOMES_DIR / OPENAI_API_KEY are also
    // process-global. The lower-level precedence-chain unit tests live next
    // to resolve_auth_source itself in the codex_config::tests submodule
    // (they use an explicit ambient-home override so they never touch the
    // real $HOME); these tests intentionally exercise only the tiers that
    // don't require touching real $HOME (pin + OPENAI_API_KEY precedence).

    fn with_codex_auth_env<T>(
        openai_key: Option<&str>,
        loom_codex_home: Option<&str>,
        loom_codex_homes_dir: Option<&str>,
        f: impl FnOnce() -> T,
    ) -> T {
        let _guard = ENV_LOCK.lock().unwrap();
        let prev_key = std::env::var("OPENAI_API_KEY").ok();
        let prev_home = std::env::var("LOOM_CODEX_HOME").ok();
        let prev_homes_dir = std::env::var("LOOM_CODEX_HOMES_DIR").ok();

        match openai_key {
            Some(v) => std::env::set_var("OPENAI_API_KEY", v),
            None => std::env::remove_var("OPENAI_API_KEY"),
        }
        match loom_codex_home {
            Some(v) => std::env::set_var("LOOM_CODEX_HOME", v),
            None => std::env::remove_var("LOOM_CODEX_HOME"),
        }
        match loom_codex_homes_dir {
            Some(v) => std::env::set_var("LOOM_CODEX_HOMES_DIR", v),
            None => std::env::remove_var("LOOM_CODEX_HOMES_DIR"),
        }

        let result = f();

        match prev_key {
            Some(v) => std::env::set_var("OPENAI_API_KEY", v),
            None => std::env::remove_var("OPENAI_API_KEY"),
        }
        match prev_home {
            Some(v) => std::env::set_var("LOOM_CODEX_HOME", v),
            None => std::env::remove_var("LOOM_CODEX_HOME"),
        }
        match prev_homes_dir {
            Some(v) => std::env::set_var("LOOM_CODEX_HOMES_DIR", v),
            None => std::env::remove_var("LOOM_CODEX_HOMES_DIR"),
        }

        result
    }

    #[test]
    fn test_codex_preparer_links_pinned_profile_auth_json() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path();
        fs::create_dir_all(repo_root.join(".loom")).unwrap();

        let pinned = tmp.path().join("pinned-profile");
        fs::create_dir_all(&pinned).unwrap();
        fs::write(pinned.join("auth.json"), "{}").unwrap();

        with_codex_auth_env(None, Some(pinned.to_str().unwrap()), None, || {
            let prepared = CodexPreparer
                .prepare("terminal-codex-pin", repo_root)
                .unwrap();
            let codex_home = repo_root.join(".loom/codex-config/terminal-codex-pin");
            assert_eq!(prepared.env_vars[0].1, codex_home.to_string_lossy());

            let linked_auth = codex_home.join("auth.json");
            assert!(linked_auth.is_symlink(), "auth.json must be a symlink, never a copy");
            let target = fs::canonicalize(&linked_auth).unwrap();
            let expected = fs::canonicalize(pinned.join("auth.json")).unwrap();
            assert_eq!(target, expected);
        });
    }

    #[test]
    fn test_codex_preparer_openai_api_key_skips_auth_linking_even_with_pin_set() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path();
        fs::create_dir_all(repo_root.join(".loom")).unwrap();

        let pinned = tmp.path().join("pinned-profile");
        fs::create_dir_all(&pinned).unwrap();
        fs::write(pinned.join("auth.json"), "{}").unwrap();

        with_codex_auth_env(Some("sk-preset-key"), Some(pinned.to_str().unwrap()), None, || {
            let prepared = CodexPreparer
                .prepare("terminal-codex-apikey", repo_root)
                .unwrap();
            let codex_home = repo_root.join(".loom/codex-config/terminal-codex-apikey");
            assert_eq!(prepared.env_vars[0].1, codex_home.to_string_lossy());
            assert!(
                !codex_home.join("auth.json").exists(),
                "OPENAI_API_KEY set must skip auth.json linking entirely, even with a valid pin"
            );
        });
    }

    #[test]
    fn test_codex_preparer_pool_selection_links_deterministic_profile() {
        let tmp = tempfile::tempdir().unwrap();
        let repo_root = tmp.path();
        fs::create_dir_all(repo_root.join(".loom")).unwrap();

        let homes = tmp.path().join("homes-pool");
        for name in ["acct-a", "acct-b", "acct-c"] {
            let profile = homes.join(name);
            fs::create_dir_all(&profile).unwrap();
            fs::write(profile.join("auth.json"), "{}").unwrap();
        }

        with_codex_auth_env(None, None, Some(homes.to_str().unwrap()), || {
            let codex_home_1 = {
                let prepared = CodexPreparer
                    .prepare("terminal-codex-pool-fixed", repo_root)
                    .unwrap();
                let codex_home = repo_root.join(".loom/codex-config/terminal-codex-pool-fixed");
                assert_eq!(prepared.env_vars[0].1, codex_home.to_string_lossy());
                let linked_auth = codex_home.join("auth.json");
                assert!(linked_auth.is_symlink());
                fs::canonicalize(&linked_auth).unwrap()
            };

            // Re-materializing for the SAME agent name must resolve to the
            // same underlying profile (determinism across repeated
            // preparer calls — the same guarantee spawn-codex.sh's bash
            // tests assert for repeated process invocations).
            codex_config::cleanup_agent_config_dir("terminal-codex-pool-fixed", repo_root);
            let codex_home_2 = {
                let prepared = CodexPreparer
                    .prepare("terminal-codex-pool-fixed", repo_root)
                    .unwrap();
                let codex_home = repo_root.join(".loom/codex-config/terminal-codex-pool-fixed");
                assert_eq!(prepared.env_vars[0].1, codex_home.to_string_lossy());
                let linked_auth = codex_home.join("auth.json");
                fs::canonicalize(&linked_auth).unwrap()
            };

            assert_eq!(
                codex_home_1, codex_home_2,
                "same agent name must deterministically resolve to the same pooled profile"
            );
        });
    }
}

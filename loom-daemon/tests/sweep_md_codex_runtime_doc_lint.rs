//! Doc-lint test for the Codex runtime-aware orchestration section of
//! `defaults/.claude/commands/loom/sweep.md` (Issue #19, Phase 3 of epic #1;
//! multi-wave fan-out resolution in Issue #24).
//!
//! Issue #19 documents two orchestration strategies (Claude Task-tool waves
//! vs process-level sequential Codex) and how the worker runtime is detected.
//! Issue #24 then resolved the multi-wave scope note by adding true
//! process-level fan-out (`defaults/scripts/spawn-codex-wave.sh`) behind an
//! opt-in gate. This test grep-checks the markdown at compile time so that:
//!
//! - Removing or renaming the runtime-aware section flags a CI failure.
//! - The AC ("`sweep.md` documents both orchestration strategies and how
//!   runtime is detected") is verifiable programmatically.
//! - The multi-wave resolution (issue #24) documents the chosen coordination
//!   substrate, the settling discipline, and the opt-in concurrency gate —
//!   and the guardrail-parity cross-reference (issue #20) stays present.
//!
//! If the section is intentionally restructured, update this test together
//! with the markdown so the doc-lint stays in sync with the contract.

#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::fs;
use std::path::PathBuf;

const SWEEP_MD_RELATIVE: &str = "../defaults/.claude/commands/loom/sweep.md";

fn read_sweep_md() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(SWEEP_MD_RELATIVE);
    fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "sweep.md not found at {} (CWD-relative path: {}): {e}",
            path.display(),
            SWEEP_MD_RELATIVE,
        );
    })
}

/// AC #1: the runtime-aware orchestration section is present and documents
/// both strategies plus runtime detection.
#[test]
fn sweep_md_has_runtime_aware_orchestration_section() {
    let content = read_sweep_md();
    assert!(
        content.contains("## Runtime-aware orchestration (Claude vs Codex"),
        "expected the `## Runtime-aware orchestration (Claude vs Codex ...)` section in \
         sweep.md — issue #19 AC requires both strategies documented"
    );
    for needle in [
        "### Runtime detection",
        "### Claude strategy",
        "### Codex strategy",
        "LOOM_WORKER",
        "roleConfig.workerType",
    ] {
        assert!(
            content.contains(needle),
            "sweep.md runtime-aware section is missing `{needle}` (issue #19 AC: \
             document how runtime is detected + both strategies)"
        );
    }
}

/// AC #3 (doc side): the daemon child-prompt encoding is documented as
/// runtime-aware with Claude byte-identical and Codex pointing at the shim.
#[test]
fn sweep_md_documents_runtime_aware_child_prompt_encoding() {
    let content = read_sweep_md();
    assert!(
        content.contains("encode_child_prompt"),
        "sweep.md should reference the `encode_child_prompt` single source of truth"
    );
    assert!(
        content.contains("byte-identical"),
        "sweep.md must state the Claude child-prompt encoding is byte-identical"
    );
    assert!(
        content.contains("openai/codex#3641"),
        "sweep.md should cite openai/codex#3641 (codex exec can't resolve slash commands)"
    );
}

/// AC #4 (doc side): the Codex model-tier mapping has a single source of
/// truth (the centralized loom-role.yml default), not a hardcoded duplicate.
#[test]
fn sweep_md_documents_codex_model_single_source_of_truth() {
    let content = read_sweep_md();
    assert!(
        content.contains("codex-model") && content.contains("loom-role.yml"),
        "sweep.md must point the Codex model tier at the centralized \
         `codex-model` default in `.github/workflows/loom-role.yml`"
    );
}

/// AC #6 + guardrail-parity: the multi-wave resolution (issue #24) and the
/// #20 guardrail-parity cross-reference are present.
#[test]
fn sweep_md_documents_scope_narrowing_and_guardrail_parity() {
    let content = read_sweep_md();
    assert!(
        content.contains("#24"),
        "sweep.md must reference the multi-wave follow-up issue #24 (AC #6)"
    );
    assert!(
        content.contains("issue #20") || content.contains("(#20)"),
        "sweep.md must cross-reference guardrail parity issue #20"
    );
    assert!(
        content.contains("LOOM_CODEX_UNSAFE"),
        "sweep.md must document that autonomous Codex write access stays opt-in \
         behind LOOM_CODEX_UNSAFE"
    );
}

/// Issue #24: the multi-wave process-level Codex fan-out resolution is
/// documented — no longer "deferred", but naming the chosen substrate, the
/// settling discipline, the opt-in concurrency gate, and the fan-out script.
/// The stale "is deferred" wording must NOT reappear once the feature ships.
#[test]
fn sweep_md_documents_multi_wave_codex_resolution() {
    let content = read_sweep_md();
    assert!(
        !content.contains("multi-wave process-level Codex orchestration is deferred"),
        "sweep.md must NOT claim multi-wave Codex orchestration is still deferred — \
         issue #24 resolved it; update this test if the section is intentionally \
         re-deferred for some other reason"
    );
    for needle in [
        "Multi-wave process-level Codex orchestration (issue #24 — resolved)",
        "spawn-codex-wave.sh",
        "LOOM_CODEX_MULTI_WAVE",
        "process-level fan-out",
    ] {
        assert!(
            content.contains(needle),
            "sweep.md must document the issue #24 multi-wave resolution: missing `{needle}`"
        );
    }
}

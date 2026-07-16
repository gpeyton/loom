//! Doc-lint test for the Codex native-agent backend policy (issue #54,
//! follow-up to umbrella #51 and to the "Codex Child Supervision Contract"
//! shipped by #52).
//!
//! Background: Loom's Codex docs used to say "Codex has no Task-tool
//! subagents" and reasoned from that premise that process-level fan-out
//! (`spawn-codex-wave.sh`) was the *only possible* way to parallelize Loom
//! work under Codex. That premise is now false — current Codex clients
//! expose native, in-session collaboration primitives (`spawn_agent`,
//! `wait_agent`, `send_message`, `followup_task`, `interrupt_agent`). A real
//! incident (umbrella #51, reproduction B) showed a root Codex session
//! choose those native primitives for a "parallel Loom agents" request
//! instead of the documented process runner, silently mixing Loom's
//! lifecycle semantics with generic native-agent supervision.
//!
//! Issue #54 resolves this with a staged answer: implement Path A now (the
//! safety baseline — process-level fan-out remains the ONLY supported
//! parallel Codex backend; native agents are explicitly prohibited for Loom
//! lifecycle dispatch) and leave Path B (native agents as a fully supported
//! second backend) as an explicit, out-of-scope forward reference.
//!
//! This test grep-checks that the canonical sweep spec:
//!
//! - No longer states the old, now-false "Codex has no subagents, full
//!   stop" framing as a technical impossibility.
//! - States the accurate, forward-compatible policy: native primitives
//!   exist but are not yet a supported Loom orchestration backend.
//! - Documents the routing rule (parallel Loom agent requests go to
//!   `spawn-codex-wave.sh`, never to native primitives) with a concrete
//!   example fixture phrased the way the acceptance criteria requires:
//!   "execute with up to N parallel Loom agents".
//! - Documents the single-backend-per-run guard (no silently mixing
//!   inline / process-level / daemon / native-agent orchestration).
//! - Documents that the backend choice is announced at sweep start and in
//!   the summary output.
//!
//! Companion tests: `sweep_md_codex_runtime_doc_lint.rs` (issue #19),
//! `sweep_md_doc_lint.rs` (Phase B, #3453).

#![allow(clippy::expect_used, clippy::unwrap_used)]

use std::fs;
use std::path::PathBuf;

const SWEEP_MD_RELATIVE: &str = "../defaults/.claude/commands/loom/sweep.md";
const GUARDRAIL_PARITY_RELATIVE: &str = "../defaults/.codex/GUARDRAIL-PARITY.md";
const LOOM_SWEEP_SKILL_RELATIVE: &str = "../defaults/.agents/skills/loom-sweep/SKILL.md";

fn read_relative(path: &str) -> String {
    let full = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(path);
    fs::read_to_string(&full)
        .unwrap_or_else(|e| panic!("failed to read {} (resolved: {}): {e}", path, full.display()))
}

fn read_sweep_md() -> String {
    read_relative(SWEEP_MD_RELATIVE)
}

/// AC: Loom no longer claims current Codex categorically lacks subagents —
/// the corrected, forward-compatible statement is present in the canonical
/// sweep spec.
#[test]
fn sweep_md_states_native_agents_exist_but_are_not_a_supported_backend() {
    let content = read_sweep_md();
    assert!(
        content.contains("Codex backend policy"),
        "sweep.md must have a 'Codex backend policy' subsection (issue #54)"
    );
    for needle in [
        "native Codex agent primitives exist",
        "not yet a supported Loom orchestration backend",
        "spawn_agent",
        "wait_agent",
        "interrupt_agent",
    ] {
        assert!(
            content.contains(needle),
            "sweep.md's Codex backend policy section is missing `{needle}` \
             (issue #54 AC: state that native agents exist but aren't a \
             supported backend, not that they don't exist)"
        );
    }
}

/// AC: the routing rule for "parallel Loom agents" requests is documented
/// with a concrete example fixture matching the acceptance-criteria phrase.
#[test]
fn sweep_md_documents_parallel_agent_routing_fixture() {
    let content = read_sweep_md();
    assert!(
        content.contains("execute with up to 3 parallel Loom agents")
            || content.contains("execute with up to N parallel Loom agents"),
        "sweep.md must contain a concrete example fixture phrased as a \
         request for 'parallel Loom agents' (issue #54 AC: tests/fixtures \
         cover this phrasing, not just prose claims)"
    );
    assert!(
        content.contains("spawn-codex-wave.sh"),
        "sweep.md's backend-policy fixture must route the parallel-agent \
         request to spawn-codex-wave.sh"
    );
}

/// AC: a single run cannot silently mix inline/process-level/daemon/
/// native-agent orchestration — the guard text is present.
#[test]
fn sweep_md_documents_no_backend_mixing_guard() {
    let content = read_sweep_md();
    assert!(
        content.contains("must not silently mix orchestration mechanisms")
            || content.contains("must not silently mix"),
        "sweep.md must document that a single Codex run cannot silently mix \
         orchestration backends (issue #54 AC)"
    );
}

/// AC: the selected backend is explicit at sweep start and visible in the
/// summary.
#[test]
fn sweep_md_documents_backend_visibility_at_start_and_summary() {
    let content = read_sweep_md();
    assert!(
        content.contains("Backend choice is explicit, not silent"),
        "sweep.md must document that the backend choice is announced, not \
         left implicit (issue #54 AC)"
    );
    assert!(
        content.contains("Backend: claude / subagent dispatch"),
        "sweep.md's Summary Output section must show a backend line as part \
         of the printed summary (issue #54 AC: visible in the summary)"
    );
}

/// The stale framing ("Codex has **no** Task-tool subagents — there is
/// nothing to dispatch ... into" as the *reason* nothing exists) must not
/// reappear verbatim as the opening sentence of the Codex strategy section.
#[test]
fn sweep_md_does_not_restate_stale_no_subagents_framing() {
    let content = read_sweep_md();
    assert!(
        !content.contains("Codex has **no** Task-tool subagents — there is nothing to dispatch"),
        "sweep.md must not restate the pre-#54 framing that treated \
         'Codex has no subagents' as if it were a categorical technical \
         impossibility — native agent primitives exist; the policy is that \
         they aren't a supported backend"
    );
}

/// AC (doc side): the GUARDRAIL-PARITY.md forward reference (added by #52)
/// is resolved into an actual policy statement, not left as a bare
/// "tracked in #54" placeholder.
#[test]
fn guardrail_parity_documents_native_agent_prohibition() {
    let content = read_relative(GUARDRAIL_PARITY_RELATIVE);
    assert!(
        content.contains("not yet a supported Loom orchestration backend")
            || content.contains("not a supported Loom orchestration backend"),
        "GUARDRAIL-PARITY.md must document the #54 decision that native \
         Codex agents are not (yet) a supported backend, not just a bare \
         forward reference to a future issue"
    );
    assert!(
        content.contains("spawn-codex-wave.sh"),
        "GUARDRAIL-PARITY.md's native-agent row must name the actual \
         required routing target (spawn-codex-wave.sh)"
    );
}

/// AC (doc side): the installed `.agents/skills/loom-sweep/SKILL.md` router
/// — the file the daemon's `encode_child_prompt` actually points Codex
/// children at — carries the same backend policy, not just the canonical
/// spec.
#[test]
fn loom_sweep_skill_documents_backend_policy() {
    let content = read_relative(LOOM_SWEEP_SKILL_RELATIVE);
    assert!(
        content.contains("Backend policy")
            && content.contains("not yet a supported Loom orchestration backend"),
        "the installed loom-sweep SKILL.md must carry the issue #54 backend \
         policy (native agents are not a supported backend; route parallel \
         requests to spawn-codex-wave.sh) since this is the file Codex \
         children are actually pointed at"
    );
    assert!(
        content.contains("spawn_agent"),
        "loom-sweep SKILL.md must name the prohibited native primitive \
         (spawn_agent) explicitly, not just gesture at 'native agents'"
    );
}

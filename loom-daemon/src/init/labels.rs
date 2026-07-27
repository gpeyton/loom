//! Marker-scoped merge for `.github/labels.yml` (issue #68).
//!
//! `.github/labels.yml` is a **shared** file: Loom ships the `loom:*` / `tier:*`
//! workflow labels that the agent lifecycle depends on, but `.github/labels.yml`
//! is also the conventional, documented place for a repository to declare its
//! own labels (`gh label sync -f .github/labels.yml`). Before this module, the
//! installer treated the file as exclusively Loom-owned: a `--force` reinstall
//! overwrote it wholesale (silently destroying consumer-authored labels), while
//! a non-force reinstall preserved it forever (so a repo that had ever touched
//! the file stopped receiving Loom's own label updates). Both failure modes are
//! fixed here.
//!
//! The remedy mirrors the marker-block pattern already shipped for
//! `CLAUDE.md` / `AGENTS.md` (see `scaffolding::LOOM_SECTION_START` /
//! `AGENTS_SECTION_START`), adapted to YAML's `#` comment syntax:
//!
//! ```yaml
//! # BEGIN LOOM LABELS
//! - name: loom:issue
//!   description: ...
//!   color: "3B82F6"
//! # END LOOM LABELS
//!
//! - name: my-project:label   # consumer-owned, never touched
//!   description: ...
//!   color: "112233"
//! ```
//!
//! Deliberately a **separate** marker pair from the CLAUDE.md/AGENTS.md ones —
//! same rationale as issue #4: independent files must be independently
//! detectable and replaceable.
//!
//! # Merge rules
//!
//! | Existing file                 | Behaviour                                                       |
//! |-------------------------------|-----------------------------------------------------------------|
//! | absent (fresh install)        | write the shipped file verbatim                                  |
//! | has BEGIN/END markers         | replace **only** the marked range; everything else is untouched  |
//! | markerless (0.10.x and older) | migrate in place (see below)                                     |
//!
//! # Markerless migration
//!
//! Every repo installed before this change has a markerless `labels.yml`, often
//! with consumer labels appended. Naively appending a marked copy of Loom's
//! block would produce duplicate `- name:` entries and break
//! `gh label sync`. Instead the migration:
//!
//! 1. Removes every entry whose label name is in the currently-shipped Loom set
//!    (these are Loom's own, and are about to be re-added inside the markers).
//! 2. Removes top-level comment lines that appear **verbatim** in the shipped
//!    block *and* carry at least one alphanumeric character (Loom's own section
//!    headers — provably Loom-authored, and re-added inside the markers, so
//!    nothing is actually lost). The alphanumeric requirement matters: the
//!    shipped block contains content-free separators (a bare `#`, a
//!    `# =====` rule) which are exactly the separators a consumer is likely to
//!    have written independently, so a verbatim match on those proves nothing.
//! 3. Splices the marked block in at the position of the first removed entry,
//!    so consumer content keeps its relative order. If the file contained no
//!    Loom labels at all, the block is appended at the end.
//!
//! Everything else — consumer entries, consumer comments, consumer ordering —
//! is preserved. The one deliberate exception is whitespace: runs of blank
//! lines are collapsed to a single blank line (see `normalize`), which is what
//! makes repeated upgrades byte-idempotent. Consumer *content* is never
//! altered, but a consumer's intentional double-blank becomes a single blank.
//!
//! The same name-based removal also runs on the marker path, so a consumer entry
//! that collides with a Loom label name outside the markers can never produce a
//! duplicate. The marked block is always authoritative for `loom:*` / `tier:*`
//! names.
//!
//! Output is normalised (runs of blank lines collapsed to one, trailing newline
//! guaranteed) so repeated upgrades are byte-idempotent.

use std::collections::HashSet;

/// Marker opening Loom's managed block in `.github/labels.yml`.
pub const LABELS_SECTION_START: &str = "# BEGIN LOOM LABELS";

/// Marker closing Loom's managed block in `.github/labels.yml`.
pub const LABELS_SECTION_END: &str = "# END LOOM LABELS";

/// A line is a marker only when the line — ignoring surrounding whitespace — is
/// exactly the marker. This prevents a label `description:` that happens to
/// quote the marker text from being mistaken for a real marker.
fn is_marker(line: &str, marker: &str) -> bool {
    line.trim() == marker
}

/// Locate the inclusive `(start, end)` line indices of the marked block.
///
/// Returns `None` unless there is exactly one ordered marker pair. A malformed
/// file is treated as markerless and goes through migration, which strips the
/// orphaned Loom marker lines before inserting one fresh, well-formed block.
fn find_marker_block(lines: &[&str]) -> Option<(usize, usize)> {
    let starts: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter_map(|(idx, line)| is_marker(line, LABELS_SECTION_START).then_some(idx))
        .collect();
    let ends: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter_map(|(idx, line)| is_marker(line, LABELS_SECTION_END).then_some(idx))
        .collect();

    match (starts.as_slice(), ends.as_slice()) {
        ([start], [end]) if start < end => Some((*start, *end)),
        _ => None,
    }
}

/// Extract the label name from a top-level `- name: X` line.
///
/// Only matches at column 0 (the shape `scripts/install/sync-labels.sh` parses).
/// Surrounding quotes and any trailing `#` comment are stripped so
/// `- name: "loom:pr"  # note` and `- name: loom:pr` compare equal.
fn entry_name(line: &str) -> Option<String> {
    let rest = line.strip_prefix("- name:")?;
    let mut value = rest.trim();

    // Strip a trailing inline comment, but only when the value is unquoted —
    // inside quotes a `#` is literal.
    if !value.starts_with('"') && !value.starts_with('\'') {
        if let Some(idx) = value.find(" #") {
            value = value[..idx].trim_end();
        }
    }

    let value = value.trim_matches(|c| c == '"' || c == '\'').trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

/// Return the inclusive end index of the entry starting at `start`.
///
/// An entry body is the run of indented, non-blank continuation lines
/// (`  description:`, `  color:`) that follow the `- name:` line. A blank line,
/// a comment at column 0, or the next `- name:` line ends the entry.
fn entry_extent_end(lines: &[&str], start: usize) -> usize {
    let mut end = start;
    let mut i = start + 1;
    while i < lines.len() {
        let line = lines[i];
        let is_continuation =
            !line.trim().is_empty() && line.starts_with([' ', '\t']) && entry_name(line).is_none();
        if !is_continuation {
            break;
        }
        end = i;
        i += 1;
    }
    end
}

/// Collect the label names declared inside a slice of lines.
fn collect_names(lines: &[&str]) -> HashSet<String> {
    lines.iter().filter_map(|l| entry_name(l)).collect()
}

/// True when a comment line carries actual content — at least one alphanumeric
/// character after the leading `#`s.
///
/// Content-free comments (a bare `#`, a `# ============` rule) are *not*
/// attributable: the shipped block contains them, but so does almost every
/// hand-commented YAML file, so a verbatim match against the shipped block is
/// no evidence at all that the consumer's copy came from Loom. Only
/// content-bearing comments are treated as provably Loom-authored and therefore
/// eligible for removal during the markerless migration.
fn is_content_comment(line: &str) -> bool {
    line.trim_start_matches('#')
        .chars()
        .any(char::is_alphanumeric)
}

/// Collect top-level (column 0) comment lines from a slice, excluding the
/// markers themselves and any content-free separator lines.
fn collect_top_level_comments<'a>(lines: &[&'a str]) -> HashSet<&'a str> {
    lines
        .iter()
        .filter(|l| {
            l.starts_with('#')
                && is_content_comment(l)
                && !is_marker(l, LABELS_SECTION_START)
                && !is_marker(l, LABELS_SECTION_END)
        })
        .copied()
        .collect()
}

/// Return the shipped Loom block (inclusive of its markers) as owned lines.
///
/// `defaults/.github/labels.yml` ships with markers. If a defaults tree somehow
/// lacks them (a hand-edited fork, an old defaults checkout), the whole shipped
/// file is wrapped so the merge still has a well-formed block to splice.
fn shipped_block_lines(shipped: &str) -> Vec<String> {
    let lines: Vec<&str> = shipped.lines().collect();
    if let Some((start, end)) = find_marker_block(&lines) {
        return lines[start..=end]
            .iter()
            .map(|l| (*l).to_string())
            .collect();
    }

    let mut wrapped = Vec::with_capacity(lines.len() + 2);
    wrapped.push(LABELS_SECTION_START.to_string());
    for line in shipped.trim_matches('\n').lines() {
        wrapped.push(line.to_string());
    }
    wrapped.push(LABELS_SECTION_END.to_string());
    wrapped
}

/// Collapse runs of blank lines to a single blank line, drop leading/trailing
/// blanks, and guarantee exactly one trailing newline.
///
/// Idempotent: running the merge twice over its own output yields identical
/// bytes, which is what makes repeated upgrades a no-op diff.
fn normalize(lines: &[String]) -> String {
    let mut out: Vec<&str> = Vec::with_capacity(lines.len());
    let mut prev_blank = false;
    for line in lines {
        let blank = line.trim().is_empty();
        if blank {
            if prev_blank || out.is_empty() {
                continue;
            }
            prev_blank = true;
            out.push("");
        } else {
            prev_blank = false;
            out.push(line);
        }
    }
    while out.last().is_some_and(|l| l.trim().is_empty()) {
        out.pop();
    }
    let mut text = out.join("\n");
    text.push('\n');
    text
}

/// Merge Loom's shipped label block into an existing `.github/labels.yml`.
///
/// `existing` is `None` for a fresh install (no file on disk). See the module
/// docs for the full rule table.
#[must_use]
pub fn merge_labels_yml(shipped: &str, existing: Option<&str>) -> String {
    let block = shipped_block_lines(shipped);

    let Some(existing) = existing else {
        // Fresh install: the shipped file is already marker-wrapped, and its
        // exact bytes are what `verify_copied_files` would compare against.
        return normalize(&shipped.lines().map(str::to_string).collect::<Vec<_>>());
    };

    let block_refs: Vec<&str> = block.iter().map(String::as_str).collect();
    let loom_names = collect_names(&block_refs);
    let loom_comments = collect_top_level_comments(&block_refs);

    let lines: Vec<&str> = existing.lines().collect();
    let marker_pos = find_marker_block(&lines);
    let had_markers = marker_pos.is_some();

    let mut kept: Vec<String> = Vec::with_capacity(lines.len());
    let mut insert_at: Option<usize> = None;

    let mut i = 0;
    while i < lines.len() {
        // The previous Loom block is excised wholesale and re-inserted here.
        if let Some((start, end)) = marker_pos {
            if i == start {
                insert_at = Some(kept.len());
                i = end + 1;
                continue;
            }
        }

        if entry_name(lines[i]).is_some() {
            let end = entry_extent_end(&lines, i);
            let name = entry_name(lines[i]).unwrap_or_default();
            if loom_names.contains(&name) {
                // Loom-owned entry: dropped here, re-added inside the markers.
                // On the markerless migration path this position is also where
                // the block gets spliced in, preserving consumer ordering.
                if !had_markers && insert_at.is_none() {
                    insert_at = Some(kept.len());
                }
                i = end + 1;
                continue;
            }
            for line in &lines[i..=end] {
                kept.push((*line).to_string());
            }
            i = end + 1;
            continue;
        }

        // A malformed marker set is deliberately handled by the markerless
        // migration path. Marker lines are Loom-owned syntax, never consumer
        // content, so discard every orphan here before inserting one canonical
        // block below. This prevents an orphan BEGIN from becoming the start
        // of a later, over-broad replacement range.
        if !had_markers
            && (is_marker(lines[i], LABELS_SECTION_START)
                || is_marker(lines[i], LABELS_SECTION_END))
        {
            i += 1;
            continue;
        }

        // Markerless migration only: drop Loom's own top-level section comments.
        // `loom_comments` holds only content-bearing lines (see
        // `is_content_comment`), so a consumer's own `#` or `# ====` separator
        // can never match here even though the shipped block contains both.
        // The lines that do match are re-added verbatim inside the block, so no
        // content is lost. On the marker path, comments outside the block are
        // consumer-owned and are never touched.
        if !had_markers && lines[i].starts_with('#') && loom_comments.contains(lines[i]) {
            i += 1;
            continue;
        }

        kept.push(lines[i].to_string());
        i += 1;
    }

    let mut merged: Vec<String> = Vec::with_capacity(kept.len() + block.len() + 2);
    match insert_at {
        Some(idx) => {
            merged.extend_from_slice(&kept[..idx]);
            merged.push(String::new());
            merged.extend(block.iter().cloned());
            merged.push(String::new());
            merged.extend_from_slice(&kept[idx..]);
        }
        None => {
            // No previous Loom block and no Loom-named entries: append.
            merged.extend(kept);
            merged.push(String::new());
            merged.extend(block.iter().cloned());
        }
    }

    normalize(&merged)
}

/// Return any label name that appears more than once in `content`.
///
/// `gh label sync` and `scripts/install/sync-labels.sh` both process entries
/// positionally; a duplicate name means the later definition silently wins and
/// the file no longer describes the repo's labels. Used by the tests as the
/// post-merge invariant.
#[must_use]
#[cfg_attr(not(test), allow(dead_code))]
pub fn duplicate_label_names(content: &str) -> Vec<String> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut dupes: Vec<String> = Vec::new();
    for line in content.lines() {
        if let Some(name) = entry_name(line) {
            if !seen.insert(name.clone()) && !dupes.contains(&name) {
                dupes.push(name);
            }
        }
    }
    dupes
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    const SHIPPED: &str = "\
# BEGIN LOOM LABELS
# Loom Workflow Labels

# Core Workflow States
- name: loom:issue
  description: Approved for work
  color: \"3B82F6\"

- name: loom:building
  description: Builder is implementing this issue
  color: \"F59E0B\"
# END LOOM LABELS
";

    /// Mirrors the real `defaults/.github/labels.yml` header shipped by #68,
    /// which opens with content-free separator lines (a `# ====` rule and a
    /// bare `#`). Those are the lines a consumer is most likely to have
    /// authored independently, so they must never be attributed to Loom.
    const SHIPPED_WITH_SEPARATORS: &str = "\
# BEGIN LOOM LABELS
# ============================================================================
# LOOM-MANAGED BLOCK -- do not edit between the BEGIN/END LOOM LABELS markers.
#
# Your own labels belong OUTSIDE the markers (above or below this block).
# ============================================================================
# Loom Workflow Labels

# Core Workflow States
- name: loom:issue
  description: Approved for work
  color: \"3B82F6\"
# END LOOM LABELS
";

    /// Extract label names in file order (test helper).
    fn names(content: &str) -> Vec<String> {
        content.lines().filter_map(entry_name).collect()
    }

    /// Everything outside the marked block — i.e. the consumer-owned region
    /// that the merge promises to leave alone (test helper).
    fn outside_markers(content: &str) -> Vec<&str> {
        let lines: Vec<&str> = content.lines().collect();
        let block = find_marker_block(&lines);
        assert!(block.is_some(), "merged output must have markers: {content}");
        let (start, end) = block.unwrap_or((0, 0));
        lines[..start]
            .iter()
            .chain(lines[end + 1..].iter())
            .copied()
            .collect()
    }

    #[test]
    fn fresh_install_writes_shipped_verbatim() {
        let merged = merge_labels_yml(SHIPPED, None);
        assert_eq!(merged, SHIPPED);
    }

    #[test]
    fn marker_upgrade_replaces_only_the_marked_range() {
        let existing = "\
# BEGIN LOOM LABELS
- name: loom:issue
  description: STALE OLD TEXT
  color: \"000000\"
# END LOOM LABELS

# My project labels
- name: area/api
  description: API surface
  color: \"112233\"
";
        let merged = merge_labels_yml(SHIPPED, Some(existing));

        assert!(merged.contains("Approved for work"), "Loom block updated");
        assert!(!merged.contains("STALE OLD TEXT"), "stale Loom text removed");
        assert!(merged.contains("# My project labels"), "consumer comment kept");
        assert!(merged.contains("- name: area/api"), "consumer entry kept");
        assert!(merged.contains("  description: API surface"));
        assert!(merged.contains("  color: \"112233\""));
        assert!(duplicate_label_names(&merged).is_empty());
    }

    #[test]
    fn markerless_migration_preserves_consumer_labels_without_duplicates() {
        // The exact 0.10.x shape: Loom's markerless block, consumer labels appended.
        let existing = "\
# Loom Workflow Labels

# Core Workflow States
- name: loom:issue
  description: Approved for work
  color: \"3B82F6\"

- name: loom:building
  description: Builder is implementing this issue
  color: \"F59E0B\"

# ---- project labels below ----
- name: feedback:static
  description: Static feedback label
  color: \"AABBCC\"

- name: area/ui
  description: UI surface
  color: \"DDEEFF\"
";
        let merged = merge_labels_yml(SHIPPED, Some(existing));

        assert!(merged.contains(LABELS_SECTION_START));
        assert!(merged.contains(LABELS_SECTION_END));
        assert!(merged.contains("# ---- project labels below ----"));
        assert!(merged.contains("- name: feedback:static"));
        assert!(merged.contains("  description: Static feedback label"));
        assert!(merged.contains("- name: area/ui"));
        assert_eq!(
            duplicate_label_names(&merged),
            Vec::<String>::new(),
            "migration must not duplicate Loom entries: {merged}"
        );
        assert_eq!(
            names(&merged),
            vec![
                "loom:issue".to_string(),
                "loom:building".to_string(),
                "feedback:static".to_string(),
                "area/ui".to_string(),
            ]
        );
    }

    /// Regression for the markerless-migration comment-deletion defect.
    ///
    /// The shipped block carries content-free separators (`# ====`, bare `#`).
    /// Matching a consumer line verbatim against those proves nothing about
    /// who wrote it, so they must survive the one-shot migration. Before the
    /// `is_content_comment` guard this test lost three consumer lines.
    #[test]
    fn markerless_migration_keeps_consumer_separator_comments() {
        let existing = "\
# Loom Workflow Labels

# Core Workflow States
- name: loom:issue
  description: Approved for work
  color: \"3B82F6\"

# ============================================================================
# PROJECT LABELS -- ours, must survive
#
# The bare '#' line above is a separator we authored.
# ============================================================================
- name: feedback:static
  description: Static feedback label
  color: \"AABBCC\"
";
        let merged = merge_labels_yml(SHIPPED_WITH_SEPARATORS, Some(existing));
        let outside = outside_markers(&merged);

        assert_eq!(
            outside.iter().filter(|l| **l == "#").count(),
            1,
            "consumer's bare '#' separator was deleted: {merged}"
        );
        assert_eq!(
            outside
                .iter()
                .filter(|l| l.starts_with("# ===") && !l.contains(char::is_alphanumeric))
                .count(),
            2,
            "consumer's '# ====' rules were deleted: {merged}"
        );
        assert!(
            outside.contains(&"# PROJECT LABELS -- ours, must survive"),
            "consumer heading was deleted: {merged}"
        );
        assert!(
            outside.contains(&"# The bare '#' line above is a separator we authored."),
            "consumer prose was deleted: {merged}"
        );

        // The guard must not cost orphan leakage: Loom's own *content-bearing*
        // headers are still removed from the consumer region and re-added
        // inside the markers.
        assert!(
            !outside.contains(&"# Loom Workflow Labels"),
            "Loom's own header leaked outside the block: {merged}"
        );
        assert!(
            !outside.contains(&"# Core Workflow States"),
            "Loom's own header leaked outside the block: {merged}"
        );

        assert!(merged.contains("- name: feedback:static"));
        assert!(duplicate_label_names(&merged).is_empty(), "{merged}");
        assert_eq!(
            merge_labels_yml(SHIPPED_WITH_SEPARATORS, Some(&merged)),
            merged,
            "still idempotent with separator-bearing shipped block"
        );
    }

    #[test]
    fn content_free_comments_are_never_attributed_to_loom() {
        assert!(!is_content_comment("#"));
        assert!(!is_content_comment("# ===================="));
        assert!(!is_content_comment("# ----"));
        assert!(!is_content_comment("#####"));
        assert!(!is_content_comment("# -- * -- * --"));
        assert!(is_content_comment("# Core Workflow States"));
        assert!(is_content_comment("# 1"));

        // The predicate is what keeps separators out of the attributable set.
        let block: Vec<&str> = SHIPPED_WITH_SEPARATORS.lines().collect();
        let collected = collect_top_level_comments(&block);
        assert!(!collected.contains("#"));
        assert!(!collected.iter().any(|l| !l.contains(char::is_alphanumeric)));
        assert!(collected.contains("# Loom Workflow Labels"));
    }

    #[test]
    fn markerless_migration_keeps_consumer_content_that_precedes_loom_labels() {
        let existing = "\
# My labels come first
- name: area/api
  description: API surface
  color: \"112233\"

# Core Workflow States
- name: loom:issue
  description: Approved for work
  color: \"3B82F6\"
";
        let merged = merge_labels_yml(SHIPPED, Some(existing));
        assert!(merged.contains("# My labels come first"));
        assert_eq!(
            names(&merged),
            vec![
                "area/api".to_string(),
                "loom:issue".to_string(),
                "loom:building".to_string(),
            ],
            "block splices in where Loom's labels were: {merged}"
        );
    }

    #[test]
    fn consumer_only_file_gets_block_appended() {
        let existing = "\
- name: area/api
  description: API surface
  color: \"112233\"
";
        let merged = merge_labels_yml(SHIPPED, Some(existing));
        assert!(merged.starts_with("- name: area/api"));
        assert!(merged.contains(LABELS_SECTION_START));
        assert_eq!(
            names(&merged),
            vec![
                "area/api".to_string(),
                "loom:issue".to_string(),
                "loom:building".to_string(),
            ]
        );
    }

    #[test]
    fn merge_is_idempotent() {
        let existing = "\
- name: area/api
  description: API surface
  color: \"112233\"
";
        let once = merge_labels_yml(SHIPPED, Some(existing));
        let twice = merge_labels_yml(SHIPPED, Some(&once));
        assert_eq!(once, twice, "second upgrade must be a no-op diff");
    }

    #[test]
    fn consumer_entry_colliding_with_a_loom_name_is_deduplicated() {
        // A consumer who hand-added `loom:issue` outside the markers must not
        // end up with two definitions -- the marked block is authoritative.
        let existing = "\
# BEGIN LOOM LABELS
- name: loom:issue
  description: old
  color: \"000000\"
# END LOOM LABELS

- name: loom:issue
  description: consumer override
  color: \"FFFFFF\"
";
        let merged = merge_labels_yml(SHIPPED, Some(existing));
        assert!(duplicate_label_names(&merged).is_empty(), "{merged}");
        assert!(!merged.contains("consumer override"));
    }

    #[test]
    fn marker_lookalike_inside_a_description_is_not_treated_as_a_marker() {
        let existing = "\
- name: docs/markers
  description: \"explains # BEGIN LOOM LABELS syntax\"
  color: \"112233\"
";
        let merged = merge_labels_yml(SHIPPED, Some(existing));
        assert!(merged.contains("explains # BEGIN LOOM LABELS syntax"));
        assert_eq!(
            merged
                .lines()
                .filter(|l| is_marker(l, LABELS_SECTION_START))
                .count(),
            1
        );
    }

    #[test]
    fn malformed_markers_migrate_without_losing_consumer_content() {
        let existing = "\
# BEGIN LOOM LABELS
# Consumer labels must survive this orphan marker.
- name: area/api
  description: API surface
  color: \"112233\"
# BEGIN LOOM LABELS
- name: loom:issue
  description: stale Loom text
  color: \"000000\"
# END LOOM LABELS
- name: area/web
  description: Web surface
  color: \"445566\"
";

        let merged = merge_labels_yml(SHIPPED, Some(existing));

        assert_eq!(
            merged
                .lines()
                .filter(|line| is_marker(line, LABELS_SECTION_START))
                .count(),
            1,
            "migration must leave exactly one BEGIN marker: {merged}"
        );
        assert_eq!(
            merged
                .lines()
                .filter(|line| is_marker(line, LABELS_SECTION_END))
                .count(),
            1,
            "migration must leave exactly one END marker: {merged}"
        );
        assert!(merged.contains("# Consumer labels must survive this orphan marker."));
        assert!(merged.contains("- name: area/api"));
        assert!(merged.contains("- name: area/web"));
        assert!(!merged.contains("stale Loom text"));
        assert_eq!(merge_labels_yml(SHIPPED, Some(&merged)), merged);
    }

    #[test]
    fn quoted_and_commented_names_normalize() {
        assert_eq!(entry_name("- name: loom:pr").as_deref(), Some("loom:pr"));
        assert_eq!(entry_name("- name: \"loom:pr\"").as_deref(), Some("loom:pr"));
        assert_eq!(entry_name("- name: loom:pr  # note").as_deref(), Some("loom:pr"));
        assert_eq!(entry_name("  - name: nested"), None, "only column 0 entries");
        assert_eq!(entry_name("# - name: commented"), None);
    }

    #[test]
    fn shipped_without_markers_is_wrapped() {
        let bare = "- name: loom:issue\n  description: x\n  color: \"3B82F6\"\n";
        let merged = merge_labels_yml(bare, Some("- name: area/api\n  color: \"112233\"\n"));
        assert!(merged.contains(LABELS_SECTION_START));
        assert!(merged.contains(LABELS_SECTION_END));
        assert!(merged.contains("- name: area/api"));
        assert!(duplicate_label_names(&merged).is_empty());
    }

    #[test]
    fn sync_labels_positional_parser_still_sees_every_entry() {
        // scripts/install/sync-labels.sh parses positionally: a `- name:` line
        // followed by exactly two more lines (description, color). The merged
        // output must never break that shape.
        let existing = "\
- name: area/api
  description: API surface
  color: \"112233\"
";
        let merged = merge_labels_yml(SHIPPED, Some(existing));
        let lines: Vec<&str> = merged.lines().collect();
        for (idx, line) in lines.iter().enumerate() {
            if entry_name(line).is_none() {
                continue;
            }
            assert!(
                lines
                    .get(idx + 1)
                    .is_some_and(|l| l.trim_start().starts_with("description:")),
                "entry at line {idx} lost its description line: {merged}"
            );
            assert!(
                lines
                    .get(idx + 2)
                    .is_some_and(|l| l.trim_start().starts_with("color:")),
                "entry at line {idx} lost its color line: {merged}"
            );
        }
    }
}

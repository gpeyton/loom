#!/usr/bin/env bash
# prune-merged-worktrees.sh - Remove lane worktrees whose work is already in main.
#
# Each lane worktree is a full checkout (repo + deps + build output), so a busy
# repo accumulates gigabytes of worktrees whose branches merged long ago. This
# removes only the ones that are provably safe to remove:
#
#   * every commit on the worktree's branch is already reachable from the
#     upstream default branch (zero unmerged commits), AND
#   * no live process is working in that directory.
#
# Anything with unmerged commits is left alone, always. Removal goes through
# `git worktree remove` so git's admin files stay consistent.
#
# Usage:
#   ./.loom/scripts/prune-merged-worktrees.sh              # prune
#   ./.loom/scripts/prune-merged-worktrees.sh --dry-run    # report only
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

cd "$(git rev-parse --show-toplevel)"

DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
UPSTREAM="origin/${DEFAULT_BRANCH}"
git rev-parse --verify --quiet "$UPSTREAM" >/dev/null || { echo "no $UPSTREAM — nothing to compare against"; exit 0; }

git fetch --quiet origin "$DEFAULT_BRANCH" 2>/dev/null || true

removed=0 kept=0
# --porcelain emits stanzas: worktree <path> / HEAD <sha> / branch <ref>
while read -r _ path; do
  read -r _ _ || true                       # HEAD line
  read -r branch_kw branch_ref || true      # branch line (or 'detached')
  read -r _ || true                         # blank separator

  [[ "$path" == "$(pwd)" ]] && continue     # never the primary checkout
  [[ "$branch_kw" == "branch" ]] || { echo "skip  $path (detached HEAD)"; kept=$((kept+1)); continue; }
  branch="${branch_ref#refs/heads/}"

  # A process actually working in here? Leave it. Compares real working
  # directories rather than command-line text, so a lane that merely *mentions*
  # the path in its prompt doesn't pin the worktree forever.
  in_use=false
  for cwd in /proc/[0-9]*/cwd; do
    target="$(readlink "$cwd" 2>/dev/null)" || continue
    [[ "$target" == "$path" || "$target" == "$path/"* ]] && { in_use=true; break; }
  done
  if $in_use; then
    echo "skip  $path (process working here)"; kept=$((kept+1)); continue
  fi

  unmerged="$(git log --oneline "$UPSTREAM..$branch" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$unmerged" != "0" ]]; then
    echo "keep  $path ($branch: $unmerged unmerged commit(s))"; kept=$((kept+1)); continue
  fi

  size="$(du -xsh "$path" 2>/dev/null | cut -f1)"
  if $DRY_RUN; then
    echo "would remove  $path ($branch, merged, $size)"
  else
    if git worktree remove --force "$path" 2>/dev/null; then
      echo "removed  $path ($branch, merged, $size)"
      removed=$((removed+1))
    else
      echo "FAILED   $path — left in place"; kept=$((kept+1))
    fi
  fi
done < <(git worktree list --porcelain)

$DRY_RUN || git worktree prune
echo "done: removed=$removed kept=$kept"

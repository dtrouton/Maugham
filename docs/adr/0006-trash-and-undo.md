# 0006 — Trash & undo design (.trash/ folder + ⌘⌥Z)

**Status:** Accepted
**Date:** 2026-05-13

## Context

Through milestone 2a, binder deletes moved files to the macOS Trash via `NSWorkspace.recycle`. That preserves the file but loses the project-internal context: the manifest entry's metadata, the item's position in the structure, and the relationship to siblings. Restoring "Chapter 7 that I deleted yesterday" meant pulling the file from Trash and manually reconstructing the manifest entry.

The research-polish brainstorm asked: should this be reversible within Maugham itself, without leaving the app?

Two patterns were considered:

- **A. Snapshot the whole manifest.** Before every destructive binder operation, snapshot the manifest to `.maugham/snapshots/`. Restoring means rolling back to a snapshot, which also rolls back unrelated edits made since.
- **B. Per-deletion trash entries.** Each deletion gets its own entry in `.maugham/.trash/` containing the file(s) plus a JSON manifest fragment describing where it came from. Restore is a per-entry operation; unrelated edits are preserved.

## Decision

**Per-deletion trash entries in `.maugham/.trash/`.** Each delete writes a `{uuid}/` folder containing the original file (or recursive group contents) plus a `manifest.json` capturing the original parent id, index, and the manifest fragment. `⌘⌥Z` restores the most-recent deletion in place. An automatic 30-day sweep removes old entries on app launch.

`⌘⌥Z` rather than plain `⌘Z` because NSTextView claims `⌘Z` for in-doc text undo when the editor has focus; trying to overload would cause flickering behavior depending on focus.

## Consequences

- **Reversibility is per-operation.** Deleting Chapter 7 and then editing Chapter 3 leaves both reversible independently.
- **Trash entries are project-local.** They sync via iCloud with the rest of the project folder. Deleting a chapter on one Mac and restoring it on another works.
- **The sweep is conservative.** 30 days, runs on launch, never deletes anything younger. Users who accidentally delete and don't notice for a few weeks are covered.
- **Restore-to-original-parent-and-index is partial.** Today, restore re-inserts at the top of the manifest. Restoring to the exact original index (when siblings have changed) is on the carry-forward list. The file itself + its metadata are reliable; the position isn't yet.
- **The `.trash/` folder is hidden from binder views.** It's project-internal state, not a binder surface. A future polish could expose a "Trash" segment for browsing, but isn't part of this milestone.
- **Orphan media on delete.** If a research item is deleted and its inline images live in the same folder, the images stay on disk. Cleanup heuristic noted as carry-forward; not yet implemented.

## References

- [Research Polish spec](../superpowers/specs/2026-05-10-research-polish-design.md)
- [Milestone memory: research-polish](../../../.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_research_polish.md) (auto-memory, not in repo)

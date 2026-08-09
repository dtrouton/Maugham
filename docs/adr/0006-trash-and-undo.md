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

## Amendment — 2026-08-09, the trash rulings (RULING-38/39/40/41/42/43/45, RULING-15)

The behavioural specification took the trash apart and Denver ruled seven questions. What changed
here, each traceable to a ruling in `experiment/RULINGS.md`:

- **⌘⌥Z is scoped to the delete ACTION, not to one item** (RULING-40), and its label follows:
  **"Restore Last Deletion"**. One gesture that deleted fifty rows comes back as fifty, or the
  command refuses and says why — it never returns part of a deletion silently. `ProjectStore`
  holds a `TrashDeletion` (the gesture's entries plus a label) rather than a single trash id.
- **A blocked restore lands BESIDE the occupant** under a deduped filename (RULING-38) instead of
  throwing Cocoa's "an item with the same name already exists" for ever. Nothing is overwritten.
- **A restore that returns less says so** (RULING-42): `restoreTrashEntry` returns a
  `TrashRestoreReport` naming dropped descendants and any item that could not come back as it was.
- **The binder and the disk agree afterwards** (RULING-41): the destination is computed from where
  the ROW is going, so a row that falls back to root takes its file with it and no folder the
  writer deleted is re-created to hold an orphan.
- **The sweep walks the trash directory** rather than `list()` (RULING-39), so an entry whose
  `meta.json` never landed expires like everything else instead of being invisible and immortal.
- **A trash entry records its SUBJECT** (`TrashSubject`, in `meta.json`, additive-optional).
  Maugham's own safety copies (`.internalArtifact` — the per-piece style files) stay out of the
  writer's Trash pane (RULING-43); a research row comes back to the research tree instead of
  decoding as a `StructureItem` and landing in the manuscript binder; and an entry whose wiring
  cannot be put back is refused loudly rather than "restored" into a success that means nothing.
- **A research LINK is restorable** (RULING-45): it has no file, so the entry is its metadata
  record (`recordManifestOnlyTrash`, `carriesFile: false`).
- **A promoted capture's original goes to the trash, not off the disk** (RULING-15) — the three
  `FileManager.removeItem` calls in `InboxStore`'s promote paths.

## References

- [Research Polish spec](../superpowers/specs/2026-05-10-research-polish-design.md)
- [Milestone memory: research-polish](../../../.claude/projects/-Users-denver-src-Maugham/memory/project_milestone_research_polish.md) (auto-memory, not in repo)

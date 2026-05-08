# Maugham Phase 2a — Binder Polish Design Spec

**Anchor:** This spec implements the *binder polish* slice of Phase 2 per `docs/superpowers/notes/2026-05-08-phase-2-breakdown.md`. The remaining Phase 2 slices (research/conflict-diff in 2b; inspector growth + word goals + statistics in 2c) are deferred.

**Goal:** Full-fidelity binder editing. Drag any item (document or group) to any new position — within siblings, into a different group, or out to root — and the filesystem keeps in lockstep through coordinated multi-file rename. Right-click adds **Duplicate** (with `"Copy of "` prefix, inline rename mode immediately on the new item). Right-click on a group adds **Tidy Filenames** to compact NN sequence gaps left by deletions; a project-wide **Tidy All Filenames** command does the same recursively from root.

After 2a, a writer can rearrange chapters by drag in seconds, recover clean filenames after extensive deletion, and clone a chapter for variant drafts — all the structural-editing operations a Scrivener user expects. Pays off the 1e DocumentStore investment immediately by exercising its coordinated multi-file-rename primitive.

---

## Out of scope (deferred)

| Feature | Lands in |
|---|---|
| Research section UI (preview pane for images/PDFs in `research/`) | 2b |
| Conflict diff view ("Show diff" button) | 2b |
| Inspector growth — tags, links, per-document word target | 2c |
| Word goals + session tracking | 2c |
| Project Statistics window | 2c |
| Drag-and-drop of files from Finder *into* the binder | future (no master-spec scheduling) |
| Multi-select drag (drag multiple items at once) | future |
| Undo for reorder/duplicate/tidy operations | future (whole-app undo strategy is a Phase 5+ topic) |

---

## Architecture

```
                  BinderView
                 /     |     \\
       drag-and-drop  context  selection
                 \\     |     /
                  v    v    v
                ProjectStore
              (mutation API)
                     |
        ┌────────────┼────────────┐
        v            v            v
   moveStructureItem  duplicateStructureItem  tidyFilenames
       │                    │                    │
       └────────┬───────────┴───────────┬────────┘
                v                       v
         RenamePlan + DocumentStore  recursive copy + DocumentStore
        (coordinator-batched         (coordinator-coordinated reads/writes
         multi-file rename)           per file)
                |                       |
                v                       v
              Filesystem (NSFileCoordinator-coordinated)
```

`ProjectStore` gains three new public mutators:
- `moveStructureItem(id:toParentId:atIndex:) async throws` — drag-reorder. Cross-group works via `toParentId` change.
- `duplicateStructureItem(id:) async throws -> StructureItem` — copy a document or group with `"Copy of "` prefix.
- `tidyFilenames(parentId:) async throws` — compact NN gaps within a group (or root if nil). Companion `tidyAllFilenames()` walks the structure tree post-order.

The hard part — multi-file rename safety — gets factored into a private `RenamePlan` value type that pre-computes the full set of (oldPath → newPath) operations, executes them through a *scratch-directory swap pattern*, and posts a single coordinated save of the manifest at the end.

---

## Drag-reorder UX

`BinderRow` becomes draggable via `.draggable(item.id)` (transferring the item id as `String`). Each row is also a drop destination via `.dropDestination(for: String.self)`. The drop intent is computed from the drop position relative to the row:

| Drop region | Action |
|---|---|
| Upper third of any row | Insert *above* the target (sibling, same parent) |
| Lower third of any row | Insert *below* the target (sibling, same parent) |
| Middle third of a **group** row | Insert as *first child* of that group (re-parent into) |
| Middle third of a **document** row | Treated as "below" — documents can't have children |
| Empty space below the binder list | Insert at root level, end |

Visual feedback uses SwiftUI's standard drop-target highlighting. Drag-reorder doesn't replace the existing context menu — both remain.

**Edge cases:**
- Dragging an item onto itself: no-op
- Dragging a group into one of its own descendants: rejected (would create a cycle); the drop closure validates ancestry and refuses
- Dragging from one project's binder to another's: not supported in 2a (single-project drag only)

---

## Multi-file rename safety: `RenamePlan` + scratch-directory swap

When NN values change for a set of siblings (drag-reorder, tidy filenames), some new paths collide with existing paths in the set. E.g., swapping chapter A and B: A's new path equals B's current path. Naive sequential renames break.

### Algorithm

```
1. Compute the full ordered set of (oldPath, newPath) pairs.
2. For each pair where newPath collides with another pair's oldPath
   (collision detection):
   a. Move oldPath → .maugham/scratch/<uuid>
   b. Record (uuid, newPath) for Phase 2
3. Phase 2: for each scratch entry, move .maugham/scratch/<uuid> → newPath.
4. Phase 3: write the manifest atomically through DocumentStore.writeManifest.
```

### Scratch directory location

`.maugham/scratch/` inside the project folder.

**Rationale**: stays on the same volume (cheap rename via `link/unlink` rather than `copy/delete`), stays inside the file presenter's purview (so iCloud sees a clean transition), recoverable by inspection if anything's left after a crash.

The scratch directory is created on demand at start of Phase 1, removed at end of Phase 3 if empty.

### Recovery on crash

If Maugham is force-quit between Phase 1 and Phase 2, scratch files remain on disk. On next `DocumentStore.open(url:)`:
- If `.maugham/scratch/` exists and contains files, log the issue and leave them in place (don't try to auto-recover). User can inspect manually.
- The manifest still references the original paths (Phase 3 hadn't run), so the project loads as it was before the rename attempt — files just appear missing for the renamed items.
- A future milestone (2c?) can add an automatic recovery pass; in 2a we accept the rare edge case.

### Group cross-group moves

For cross-group drag of a *group* (not just sibling NN renumber), the move is a single folder rename via NSFileCoordinator. Macos folder rename is atomic on the same volume. Manifest's recursive `path` rewriting handles all descendants without touching individual files. Much cheaper than file-by-file recursion.

For cross-group drag of a *document*, the file is moved between folders. Same scratch-swap pattern handles potential NN conflicts in the destination group.

### Coordination

Every filesystem operation is wrapped in `NSFileCoordinator(filePresenter: documentStore.presenter).coordinate(...)`. The coordinator is the same instance used by `performSave` and `writeManifest` from 1e — guarantees external observers (iCloud, Claude Desktop, Finder) see clean transitions.

---

## Duplicate semantics

Right-click → **Duplicate**. Behaviour:

### Document

1. Read source content via `DocumentStore.openDocument`-equivalent coordinated read (we don't necessarily want to *bind* to it; just read bytes).
2. Compute new title: `"Copy of " + source.title`.
3. Compute new filename via `FileNaming.nextDocumentFilename(title: newTitle, extension: ...)` against current siblings.
4. Write content to new path through coordinator.
5. Add manifest entry as next sibling of source.
6. Return the new `StructureItem`.

`BinderView` selects the new item and immediately enters inline rename mode (same UX as `New Document` in 1d).

### Group

1. Walk the source group's manifest subtree, collecting every descendant.
2. Generate fresh `id` for every duplicated item (avoid id collisions).
3. Recursively copy folder contents to a new sibling folder via `FileManager.default.copyItem(at:to:)` — wrapped in NSFileCoordinator.
4. Top-level group title gets `"Copy of "` prefix; descendant titles preserved.
5. Top-level group's NN comes from `FileNaming.nextGroupFolderName` against current siblings.
6. Build the manifest subtree with new ids and updated relative paths, splice it in as next sibling of source.
7. Save manifest.
8. Return the new top-level `StructureItem`.

`BinderView` selects the new top-level group and enters inline rename mode.

### Cycle prevention

Duplicating a group does not include the source itself's id in the new subtree (it's a copy, not a reference). No cycles.

---

## Tidy Filenames

### Per-group

`ProjectStore.tidyFilenames(parentId: String?) async throws`:

1. Find children of `parentId` (or root if nil) in manifest order.
2. For each child, compute target NN = `01`, `02`, ..., `0N` (zero-padded 2 digits, contiguous from 01).
3. For each child whose current NN ≠ target NN, build a `RenamePlan` entry: `(oldPath, newPath)` where newPath has the corrected NN prefix and the same slug.
4. Execute the plan (scratch-swap if collisions).
5. Save manifest.

If no children need renaming (already contiguous), the operation is a no-op (idempotent).

### Project-wide

`ProjectStore.tidyAllFilenames() async throws`:

1. Walk the structure tree post-order (deepest groups first).
2. For each group encountered, call `tidyFilenames(parentId: group.id)`.
3. Finally call `tidyFilenames(parentId: nil)` for root.

This produces a single combined `RenamePlan` execution (rather than N separate ones) so the manifest saves once at the end.

### UI surfaces

- **Right-click on a group** → "Tidy Filenames" → `tidyFilenames(parentId: group.id)`. Confirmation alert: *"Renumber the chapters in 'Act One'? Existing files will be moved to fix gaps in numbering."*
- **Right-click on empty binder root area** → "Tidy Filenames" → `tidyFilenames(parentId: nil)`. Same confirmation, scoped to root.
- **File menu → "Tidy All Filenames"** → `tidyAllFilenames()`. Stronger confirmation: *"Renumber all chapters and scenes in this project? Filenames will change for any items with gaps."*

No keyboard shortcut on the project-wide command (rare-use action).

No automatic triggering. User-initiated only.

---

## Files (created or modified)

```
Maugham/Stores/
  ProjectStore.swift                  # MODIFIED — adds moveStructureItem, duplicateStructureItem, tidyFilenames, tidyAllFilenames
  RenamePlan.swift                    # NEW — value type + executor for multi-file-rename batches
  DocumentStore.swift                 # MODIFIED — adds coordinated copy + multi-rename helpers used by RenamePlan

Maugham/Views/
  BinderView.swift                    # MODIFIED — drag/drop modifiers, Duplicate + Tidy in context menu, confirmation alerts
  BinderRow.swift                     # MODIFIED — .draggable(item.id) + .dropDestination(for: String.self)
  ProjectWindow.swift                 # MODIFIED — listen for maughamTidyAllFilenames notification

Maugham/MaughamApp.swift              # MODIFIED — File menu adds "Tidy All Filenames"
Maugham/Models/MaughamNotifications.swift  # MODIFIED — adds maughamTidyAllFilenames

MaughamTests/
  RenamePlanTests.swift               # NEW (unit, ~6 tests)
  ProjectStoreReorderTests.swift      # NEW (~5 integration tests for moveStructureItem)
  ProjectStoreDuplicateTests.swift    # NEW (~4 integration tests for duplicateStructureItem)
  ProjectStoreTidyTests.swift         # NEW (~4 integration tests for tidyFilenames)
```

3 new main-target files, 4 new test files, 5 modified main files, 0 modified test files. **Estimate: 12 tasks** for execution.

---

## Testing strategy

### Pure-logic TDD

- **`RenamePlanTests`** (~6 tests):
  - Empty plan executes successfully (no-op)
  - Plan with non-colliding renames executes in single phase
  - Plan with colliding renames uses scratch swap correctly
  - Plan detects ancestry cycle and refuses
  - Plan rejects identical (oldPath == newPath) entries as no-ops
  - Plan with mixed colliding + non-colliding executes in correct order

### Integration (real temp dir + DocumentStore)

- **`ProjectStoreReorderTests`** (~5 tests):
  - Sibling swap (chapter 1 ↔ chapter 2)
  - Multi-step reorder (chapter 5 → position 1, between existing 1 and 2)
  - Move document into a group (cross-group reparent)
  - Move group into another group (folder rename, descendants follow)
  - Move group into one of its own descendants → throws (cycle prevention)

- **`ProjectStoreDuplicateTests`** (~4 tests):
  - Duplicate a document → new file with "Copy of " title, manifest entry next sibling
  - Duplicate a group with 2 child documents → folder + 2 files copied, fresh ids throughout
  - Duplicate of a Short Story root → "Copy of " sibling at root
  - Duplicate of a deeply-nested group → folder structure preserved

- **`ProjectStoreTidyTests`** (~4 tests):
  - Tidy after delete leaves contiguous NN sequence
  - Tidy is idempotent (running twice = no second-pass changes)
  - Tidy-all walks the whole tree (gaps in three different groups all compacted)
  - Tidy preserves slug parts (only NN changes)

### Smoke-build only

- BinderRow `.draggable` + `.dropDestination` modifiers
- BinderView confirmation alerts for Tidy
- File menu "Tidy All Filenames" wiring
- Cross-group drag visual feedback (drop indicators in nested DisclosureGroups)

### Manual smoke (T-end, 8 steps)

1. Open a Novel project. Drag chapter 3 to position 1 (within Act One). Verify in Finder: filenames now `01-chapter-3.md`, `02-chapter-1.md`, `03-chapter-2.md`. Editor binding still valid for the visible chapter.
2. Drag a chapter from Act One to Act Two. File moves between folders; manifest updates; binder shows the move.
3. Drag a group ("Act Three") to be a child of another group ("Act Two"). Folder physically moves under Act Two; descendants visible at the new location.
4. Right-click a chapter → Duplicate. New "Copy of <title>" appears as next sibling, in inline rename mode. Type a new name; press Return; rename completes.
5. Right-click a group with descendants → Duplicate. New "Copy of <group>" appears with all children deep-copied with fresh ids.
6. Delete chapters 2, 4, 6 from a group. Right-click the group → Tidy Filenames → confirm. Remaining chapters renumber 01, 02, 03 contiguously.
7. File menu → Tidy All Filenames → confirm. Every group in the project gets its NN sequence compacted in one pass.
8. Force-quit Maugham mid-reorder (drag-reorder + immediately Activity Monitor). Reopen. `.maugham/scratch/` should contain stragglers; the project loads at the pre-rename state with some files appearing missing in the binder. Verify console log mentions stragglers. (Edge case acceptance test — not auto-recovery.)

---

## Open questions for plan-writing

1. **Scratch recovery**: As noted in 2a's design, no auto-recovery in this milestone — log on `DocumentStore.open` if `.maugham/scratch/` has stragglers, leave manual cleanup to the user. Plan should include this log-on-open behaviour as a small task.

2. **Drop indicator rendering in nested DisclosureGroups**: SwiftUI's drop indicators sometimes render misaligned in nested OutlineGroup/DisclosureGroup hierarchies. The plan should treat this as a known fragility — if the default highlight doesn't render cleanly, fall back to a custom overlay (an explicit blue line `Rectangle()` overlay activated when the row's drop is targeted).

3. **Confirmation alert text**: The alerts I drafted ("Renumber the chapters in 'Act One'?") use specific group titles. Plan should encode the actual SwiftUI alert binding pattern with title placeholders.

4. **Performance**: `tidyAllFilenames` on a 200-document project. The scratch-swap pattern means up to 400 filesystem ops (200 to scratch, 200 to final). NSFileCoordinator-coordinated, sequential. On local disk this is sub-second; on iCloud, could be 10–30 seconds. Plan should test this latency and consider a progress indicator if it exceeds 1 second. For 2a, accept the wait without progress UI.

5. **Drag from binder OUT to root** (drop on empty space below): the spec says this drops at root level, end. Plan should specify the exact gesture/region recognition — probably an empty `Color.clear.contentShape(Rectangle()).dropDestination(...)` filling the bottom of the List below the last row.

# Maugham — Phase 3d Design: Multi-file Screenplay

**Status:** approved 2026-05-10
**Carries forward from:** milestone-3c (single-file screenplays with scene navigator)
**Sets up:** Phase 4a Screenplay Intelligence (cross-file autocomplete)

## Goal

Pivot screenplays from single-file to scene-as-document, the same model novels use for chapters — but preserve the writer's experience of reading and editing the screenplay as one continuous Fountain stream. The binder shows scenes as draggable cards; the editor shows a single concatenated document.

This is **Scrivenings mode for screenplays**: one document on screen, multiple files on disk.

## Architecture

The 3d milestone introduces a `CompoundScreenplayDocument` abstraction that owns N child `DocumentStore`s and presents a single `NSTextStorage` to the editor. Edits route back to the child whose range owns the cursor; structural changes (new slugline, deleted slugline) propagate to the manifest and the binder.

- **On disk:** every screenplay is multi-file. One `.fountain` per scene, plus a leading `Scenes/00-title.fountain` for the title page. Order tracked in `project.maugham.json`'s `structure` array (existing pattern from novels).
- **In memory:** `CompoundScreenplayDocument` exposes a single concatenated `NSTextStorage` to the editor. An offset map tracks `(childIndex, compoundRange)` per child for edit routing.
- **In the binder:** scenes appear as draggable items, top-level `# ACT N` sections become folder groups containing their scenes, title page is the first item with a distinct icon.
- **In the editor:** one continuous Fountain stream. Auto-split happens silently when a new slugline is typed; auto-merge happens silently when a slugline is deleted.

Existing 3a-3c features all continue working unchanged: parser, per-element styling, page count, inline emphasis, syntax help. The 3c scene navigator pane is retired (the binder now serves that role).

## Data model

### Manifest extension

```swift
public struct StructureItem {
    // existing: id, title, type, path, synopsis, status, wordTarget, tags, links, children
    public var role: ItemRole?   // NEW. nil for regular items.
}

public enum ItemRole: String, Codable, Sendable {
    case titlePage
}
```

`role` is optional and additive. Older Maugham builds tolerate it via the existing schema-1 unknown-field pass-through. No `schemaVersion` bump.

### On-disk layout

```
MyScreenplay/
├── project.maugham.json
├── Scenes/                              # Screenplay-specific
│   ├── 00-title.fountain                # Title page (role: .titlePage)
│   ├── int-kitchen-day.fountain
│   ├── ext-rooftop-night.fountain
│   └── int-warehouse-dawn.fountain
└── Research/                            # Unchanged
```

### Filename conventions

- Title page: reserved name `00-title.fountain`. Numeric prefix sorts first in Finder. Never auto-renamed.
- Scenes: derived from slugline via existing `FileNaming.kebabCase` (e.g., `INT. KITCHEN — DAY` → `int-kitchen-day.fountain`). Dedupe collisions with `-2`, `-3` suffixes.
- No numeric prefix on scenes — order lives in the manifest, not the filename. Drag-reorder doesn't touch disk.

### Manifest example

A 3-act screenplay with title page and acts:

```json
"structure": [
  { "id": "...", "type": "document", "title": "Title Page",
    "path": "Scenes/00-title.fountain", "role": "titlePage" },
  { "id": "...", "type": "group", "title": "ACT ONE", "children": [
    { "id": "...", "type": "document", "title": "INT. KITCHEN — DAY",
      "path": "Scenes/int-kitchen-day.fountain" },
    { "id": "...", "type": "document", "title": "EXT. GARDEN — DAY",
      "path": "Scenes/ext-garden-day.fountain" }
  ]},
  { "id": "...", "type": "group", "title": "ACT TWO", "children": [...] }
]
```

`StructureItem.id` (UUID) is the stable identity. `path` is cosmetic — slugline rename triggers file rename, but the `id` doesn't change so binder selection survives.

## Compound editor

```swift
@MainActor
public final class CompoundScreenplayDocument: Observable {
    private(set) var children: [DocumentStore]   // Manifest order
    private(set) var textStorage: NSTextStorage  // The compound stream
    private var offsetMap: [ChildSlice]          // (childIndex, compoundRange)
    
    func attach(to textView: NSTextView)
    func childAndLocalRange(forCompound range: NSRange) -> (DocumentStore, NSRange)
    func currentSceneId(forCursor: Int) -> StructureItem.ID?
    // ... edit routing, scene split/merge
}

private struct ChildSlice {
    let childIndex: Int
    let compoundRange: NSRange
}
```

### Concatenation rule

Children's text joined in manifest order with `\n\n` separator (Fountain already requires blank-line separation between elements, so this is natural). Title page first, then acts, then scenes within acts in order.

### Edit routing

Every NSTextStorage mutation gets translated:

1. The compound owns the storage; intercept `replaceCharacters(in:with:)`.
2. Convert the compound range to per-child local ranges via the offset map.
3. Apply the edit to each affected child's own NSTextStorage.
4. Recompute offsets.
5. Trigger that child's debounced autosave (existing `DocumentStore` machinery).

Edits that cross a scene boundary (e.g., select across the join, paste new content) get split into two child edits. Edits that delete a separator are detected as a merge signal (see auto-merge below).

### Auto-split (typing a new slugline mid-scene)

The parser already runs on every change. If the parsed `FountainScript` reveals a `sceneHeading` whose location falls mid-child rather than at child start:

1. Cut the child's text at the slugline.
2. Create a new child file (`Scenes/<slug>.fountain`) with the right-hand portion.
3. Insert a new `StructureItem` into the manifest at the position derived from the slugline's location in the act.
4. Notify the binder.

The writer sees no interruption — the editor is unchanged because the compound stream is unchanged. The new file appears in the binder.

### Auto-merge (deleting a slugline)

If a scene child's first line is no longer a `sceneHeading` after an edit:

1. Append the child's content to the previous scene child.
2. Delete the orphaned file.
3. Remove its `StructureItem` from the manifest.

**Edge case — first scene loses its slugline:** never merge into the title page. The file stays as a headless scene (renders as action with no heading) until the writer types a new slugline or deletes the content entirely.

### Cursor → scene mapping

The compound exposes `currentSceneId(forCursor: Int) -> StructureItem.ID?` so the inspector and binder selection track the active scene. Selection in the binder scrolls the compound editor to that scene's compound-range start.

### External file changes

When `NSFilePresenter` reports a scene file changed externally, only that child reloads. The compound recomputes offsets, the editor diffs the displayed text in that child's range. Pending local edits trigger the existing conflict resolution flow scoped to that child only — concurrent conflicts in different scenes resolve independently.

### No visual scene boundary marker

The slugline IS the boundary. Seamless writing flow — the compound is invisible to the writer.

## Binder

The binder gets a small but coherent extension:

### Tree shape

- **Title page** (always first, `role: .titlePage`): rendered with a distinct icon (SF Symbol `doc.text`). Cannot be dragged into an act folder. Cannot be renamed (title fixed at "Title Page"). Selecting it scrolls the editor to compound offset 0.
- **Acts** (top-level groups, `type: .group`): standard folder rendering with expand/collapse. Drag scenes in/out, drag the whole act to reorder.
- **Scenes** (documents inside or outside acts): row shows the slugline as the title, with `p.4 · 1¼p` annotations on the trailing edge — same format the 3c scene navigator used. The navigator's value-add is fully absorbed.

### Selection follows cursor

When the writer types in the compound editor, the binder selection updates to highlight the scene the cursor currently lives in (via `currentSceneId(forCursor:)`). Conversely, clicking a scene scrolls the editor to that scene's start. This matches Scrivener's Scrivenings behavior.

### Drag-and-drop

- Drag a scene within its act, between acts, or out to top level — manifest reorders, compound recomputes, file stays put on disk.
- Drag an act to reorder among its peers — manifest array shuffles.
- Drag a scene into a non-act group → no-op (acts are the only valid screenplay groups for now).
- Title page can't be dragged.

### Binder actions

Right-click contextual menu, also reflected in File menu:

- **New Scene** (right-click on a scene or act): creates an empty `Scenes/untitled-scene-N.fountain` and inserts a placeholder `INT. UNTITLED — DAY` slugline so it's a valid scene. Cursor jumps there.
- **New Act**: creates an empty group with a placeholder title; user types the real act name.
- **Duplicate** (existing): copies the file + manifest entry with `(copy)` suffix.
- **Delete**: removes the file (after confirm) and the manifest entry. If the deleted scene was the only one in an act, the act stays as an empty folder.
- **Rename** (existing, double-click row): rewrites the slugline in the file and renames the disk file via the existing rename pipeline.

### Scene navigator retirement

`BinderSegment.scenes` segment from 3c is removed. Picker on screenplay projects becomes `Manuscript / Research` again, like novels. `Manuscript` now naturally shows the per-scene structure. One source of truth.

### Inspector

Same fields as novel chapters — title (read-only for screenplays since it mirrors the slugline), synopsis, status, tags. Word target swaps to a **page target** for screenplay scenes (e.g., "1.5 pages"). Page count + length annotations also surface here, mirroring the binder row.

## Migration

Existing single-file screenplay projects auto-migrate on first 3d open — transparent to the writer. Detection rule:

```
manifest.type == .screenplay && structure.count == 1 && structure[0].path ends with ".fountain"
```

### Migration flow

1. **Backup.** Rename the original `.fountain` to `.fountain.bak` in place. If any later step fails, restore the backup and abort migration with an error banner ("Migration failed, kept original file"). Backups stay on disk so the writer can recover.

2. **Parse.** Run the existing `FountainTokenizer` over the original content to produce a `FountainScript` (lines + titlePage).

3. **Title page extraction.** If `script.titlePage` is non-nil, write its key-value lines to `Scenes/00-title.fountain`. Otherwise create an empty `00-title.fountain` with placeholder keys (`Title:` empty, etc.) so the writer can fill it in later.

4. **Scene splitting.** Walk `script.lines` segmenting on `.sceneHeading`:
   - Each scene file gets its slugline + everything up to (but not including) the next `.sceneHeading` or end-of-file.
   - Filename derived via `FileNaming.kebabCase(slugline)`. Dedupe collisions with `-2`, `-3`.
   - Write each scene file to `Scenes/`.

5. **Act grouping.** Walk the parsed lines for `.section(level: 1)` markers (`# ACT N`). Each act becomes a `StructureItem` group; scenes between this `#` and the next `#` (or end) become its children. Scenes that appear before any `#` go to top-level (no act parent).

6. **Pre-scene action.** Action paragraphs that appear *before* any slugline go into a new file `Scenes/_preamble.fountain` (underscore prefix sorts after `00-` but before scenes, marks it as a less-canonical artifact). Regular scene file (no slugline), allowing the writer to keep or absorb it later.

7. **Manifest rewrite.** Replace the single-item `structure` array with the new title-page → acts → scenes structure. Save manifest atomically (write-to-temp + rename).

8. **Cleanup.** If everything succeeded, the `.fountain.bak` stays on disk for one launch session, then is silently removed on the next clean open.

### Edge cases

- **Empty screenplay** (no scenes, no title page): create just `00-title.fountain` with placeholder keys. No `_preamble`.
- **Title page only** (no slugline anywhere): same as empty + the title page content. Writer adds scenes from the binder later.
- **Scenes only, no title page block in source**: empty title page document is still created (every screenplay has one in 3d), with empty fields the writer can fill via Inspector.
- **Migration failure** (write error, disk full): restore backup, surface error banner, leave manifest untouched.

## Cross-cutting concerns

**Page count.** `CompoundScreenplayDocument.estimatedPageCount` sums each child's contribution (existing `FountainScript.estimatedPageCount` per scene). The number is approximate at scene boundaries — Final Draft repaginates the joined script. Accept ~5% drift, same accuracy class as 3a. Per-scene length in binder rows uses the existing `sceneLength(startingAt:)` helper, scoped to the scene's local script.

**Autosave.** Unchanged per-child. The compound routes edits to the right child, that child's `DocumentStore` debounces its 750ms write, and only the affected file hits disk.

**Conflict resolution.** External changes detected per-file via `NSFilePresenter` — already in place. The existing `ConflictDiffSheet` (3b) opens scoped to the affected scene. If two scenes have concurrent conflicts, they queue sequentially.

**Find / Replace.** `NSTextView`'s find machinery operates on the compound `NSTextStorage` — one stream, one search. Replacements route through the edit router transparently.

**Word count + session metrics.** Operate on the compound text, no change.

## Out of scope (deferred)

Explicitly **not** in 3d:

- **Compile to single `.fountain`** — export action that joins all scenes into one shareable file. Phase 5 (Scrivener parity).
- **Cross-file character autocomplete** — surfacing characters from sibling scene files. Phase 4a (Screenplay Intelligence).
- **Multi-file diff sheet** — showing all concurrently-conflicted scenes in one view. Phase 5.
- **Outline minimap / structure mode** — secondary navigator showing acts/sequences. Phase 4a.
- **FDX import** producing a multi-file project — straight Fountain only. Phase 4.
- **Scene numbers, dual dialogue, MORE / CONT'D** — production-side. Phase 4.

## Testing strategy

### Unit tests (`MaughamTests/`)

- `CompoundScreenplayDocumentTests` — edit routing, offset map recompute, range translation, cursor → scene mapping
- `AutoSplitTests` — typing a slugline mid-scene produces correct file + manifest update
- `AutoMergeTests` — deleting a slugline merges into prior scene; first-scene-no-slugline preserves the file as headless
- `MigrationTests` — single-file → multi-file: with/without title page, with/without acts, with preamble, empty file, title-page-only, malformed Fountain
- `BinderActionsTests` — new scene, new act, rename slugline propagates to file, drag-reorder updates manifest
- `PageCountTests` — compound page count sums per-scene; per-scene length in binder rows matches `sceneLength(startingAt:)`

### Integration tests

- End-to-end migration: open a real 3a-style screenplay fixture, verify all files written + manifest correct
- End-to-end edit: type INT., verify file created and editor compound text unchanged
- End-to-end conflict: simulate external write to one scene, verify isolated diff sheet

### Manual smoke before tagging

- Drag-reorder scenes within and across acts
- New Scene / New Act from binder context menu
- Rename slugline → file rename + manifest path update
- Delete scene with confirm
- Open a 3c single-file screenplay → auto-migrates correctly
- Title page edits via inline editor and via Inspector form, both update the file
- Find/Replace across all scenes
- iCloud-style external write to one scene file

**Target:** 465 → ~520 tests passing (rough estimate; ~50 new tests across the categories above).

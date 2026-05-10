# Maugham — Research Polish Milestone (Group 1)

**Status:** approved 2026-05-10
**Group:** 1 — Editing flow polish
**Sets up:** continued Group 1 work (Phase 4a Screenplay Intelligence) and Group 4 safety polish (snapshots, backups)

## Goal

Three small, high-trust improvements that make Maugham feel more like a daily-driver writing tool:

1. **Plain-text note creation in research** — eliminate the "I can only import existing files" friction.
2. **Inline images in research notes** — paste a reference image while outlining a character, see it in a preview pane.
3. **Trash & undo for binder operations** — accidentally deleted Chapter 7 should be recoverable.

Each feature is independently shippable; they bundle into one milestone because they touch the same surfaces (research browser, binder) and ship as one coherent "polish pass."

## Architecture

Three loosely-coupled feature areas:

- **Feature A** — additive: new `addResearchTextNote` method on `ProjectStore`, new "New Note" item in ResearchView's context menu.
- **Feature B** — additive: new `ImagePasteHandler` utility, new `ResearchNotePreviewPane` SwiftUI view, override of `MaughamTextView.paste(_:)` to intercept image content.
- **Feature C** — changes the semantics of existing delete operations (route through trash instead of hard-deleting), adds a new `TrashStore` value type, adds a new conditional `BinderSegment.trash`.

All three share Maugham's "plain text on disk is the source of truth" philosophy — nothing in this milestone introduces binary or rich-text formats. Pasted images are written as standard PNG/JPEG files, referenced via Markdown.

## Feature A — New Text Note

### User-facing behavior

- Right-click in research browser → "New Note" → creates a new `.md` file with default title `Untitled Note` (numeric dedup) → enters rename mode immediately → typing commits the rename and updates the file's path on disk.
- If right-click happens on a group, the note is created inside the group.
- The note opens in the editor with cursor at the start.

### Data model

- ResearchItem with `type: .asset`, `kind: .document`, populated `path` and `addedAt`.
- File written to `research/<slug>.md` (top-level) or `research/<group-slug>/<slug>.md` (inside a group).
- File created as zero-byte `.md` initially.

### Public API

New on `ProjectStore`:

```swift
public func addResearchTextNote(
    parentId: String?,
    title: String = "Untitled Note"
) async throws -> ResearchItem
```

Mirrors `addResearchItem` and `addResearchAsset` structure. Dedup on title collision via numeric suffix (`Untitled Note 2`, `Untitled Note 3`).

### UI integration

ResearchView's existing context menu gains a "New Note" entry alongside "New Group" / "Import File". Triggers rename mode on creation (existing pattern via `renamingItemId`).

## Feature B — Inline images in research notes

### User-facing behavior

- While editing a research note (`.md` ResearchItem with `kind: .document`), the writer pastes an image (e.g., copied from a browser, screenshot, Photos).
- Maugham saves the image as a sibling file in a `<slug>_assets/` folder and inserts a Markdown reference at the cursor.
- Optional preview pane (toggled via `⌘ Shift P`) renders the note's Markdown with images displayed inline.
- Editor itself stays plain text — the writer sees `![](./<slug>_assets/image-20260510-153045.png)` in the editor; the preview is the visual surface.

### Disk layout

```
research/
├── sarahs-character.md
├── sarahs-character_assets/
│   ├── image-20260510-153045.png
│   └── image-20260510-153207.jpg
├── john-character.md
└── john-character_assets/
    └── image-20260510-160102.png
```

The `_assets/` folder is created lazily on first paste. Sibling-to-note placement means the note + its images travel together if copied or moved.

### Image filename

`image-YYYYMMDD-HHMMSS.<ext>`, extension derived from pasteboard content type:
- `public.png` or `kUTTypePNG` → `.png`
- `public.jpeg` or `kUTTypeJPEG` → `.jpg`
- Fallback → `.png` (re-encode the NSImage as PNG)

Second-precision timestamps; rapid-fire paste sequences (rare) would collide — handle via a per-second counter suffix only if needed.

### Markdown reference inserted

`![](./<slug>_assets/image-<timestamp>.<ext>)` — relative path with `./` prefix so the renderer treats it as note-relative. Alt text left empty for the writer to fill in.

### Paste interception

`MaughamTextView` (in `EditorSurface.swift`) overrides `paste(_:)`:

```swift
override func paste(_ sender: Any?) {
    if let handler = coordinator?.imagePasteHandler,
       let image = NSImage(pasteboard: .general) {
        handler(image)
        return
    }
    super.paste(sender)
}
```

The `imagePasteHandler` is installed by `ProjectWindow` when the active document is a research note (kind: `.document`). For manuscript documents and screenplays, no handler is installed and standard paste flows through.

### `ImagePasteHandler` utility

```swift
public struct ImagePasteHandler {
    /// Persist an NSImage as PNG/JPEG sibling to the given note path,
    /// return the Markdown reference to insert at the cursor.
    public static func saveAndReference(
        image: NSImage,
        forNoteAt notePath: String,
        in projectURL: URL
    ) throws -> String
}
```

Pure function; easy to unit-test with a temp directory fixture.

### Preview pane

`ResearchNotePreviewPane` SwiftUI view:

- Visible only when (a) the active document is a research note AND (b) `researchPreviewVisible` is true.
- Toggled via `⌘ Shift P` (P for Preview). State persisted in UIState as `researchPreviewVisible: Bool` (defaults to false).
- Reads the note's text on change (debounced 200ms via existing DebounceScheduler).
- Splits content paragraph-by-paragraph:
  - Empty lines → vertical spacing
  - Lines matching `^!\[.*\]\(./[^)]+\)$` (solo image reference) → `Image(nsImage: ...)`
  - Mixed text + inline image references → composed via `NSAttributedString` with `NSTextAttachment` for images, wrapped in `Text(AttributedString(...))`
  - Plain markdown lines → `Text(AttributedString(markdown:))` with `interpretedSyntax: .inlineOnly`

### Rename propagation

Renaming a note (via the existing rename pipeline) must also rename its sibling `<slug>_assets/` folder and update any internal Markdown references in the note's content that pointed at the old folder name.

Implementation: `renameResearchItem` detects when an item's path-derived slug changes AND a sibling `_assets/` folder exists; moves the folder; reads the note's content; runs a regex-replace on `./<old-slug>_assets/` → `./<new-slug>_assets/`; writes the updated content back.

## Feature C — Trash & undo

### User-facing behavior

- Delete a manuscript item or research item → file moves to project's `.trash/` folder (instead of hard delete) → manifest entry removed.
- `⌘Z` immediately after a delete restores it (binder context).
- Trash binder segment appears when `.trash/` has entries; lists trashed items with "Restore" and "Permanently Delete" per-row actions.
- Trash entries silently swept after 30 days at app launch.

### Disk layout

```
<project root>/
├── project.maugham.json
├── manuscript/
├── research/
└── .trash/
    ├── 20260510-153045-doc-a1b2c3d4/
    │   ├── meta.json
    │   └── Chapter7.md
    └── 20260509-094230-research-e5f6g7h8/
        ├── meta.json
        └── sarahs-character.md
```

`.trash/` is dot-prefixed to stay hidden from default Finder view. Each entry is its own subdirectory named `<YYYYMMDD-HHMMSS>-<original-id>/`:

- `meta.json` records the original ResearchItem or StructureItem JSON plus `originalParentId: String?` and `originalIndex: Int`.
- The original file (or folder tree, for groups containing children) sits alongside.

### `TrashStore`

```swift
@MainActor
public struct TrashStore {
    let projectURL: URL

    func moveToTrash(
        fileRelativePath: String,
        itemMetadata: Data,
        originalParentId: String?,
        originalIndex: Int,
        displayTitle: String
    ) async throws -> TrashEntry

    func restore(trashId: String) async throws -> TrashEntry
    func permanentlyDelete(trashId: String) async throws
    func sweep() async throws  // removes entries older than 30 days
    func list() async throws -> [TrashEntry]
}

public struct TrashEntry: Identifiable, Sendable {
    public let id: String                   // folder name
    public let trashedAt: Date
    public let originalRelativePath: String
    public let displayTitle: String
    public let itemMetadata: Data
    public var daysRemaining: Int { /* 30 - days since trashedAt */ }
}
```

`ProjectStore` owns a `let trashStore: TrashStore`, delegates trash work to it.

### `ProjectStore` API changes

- `deleteStructureItem(id:)` and `deleteResearchItem(id:)` now route through `trashStore.moveToTrash` instead of `FileManager.removeItem`.
- New methods:
  - `restoreLastDeleted() async throws` — uses cached `lastDeletedTrashId`
  - `restoreTrashEntry(id:) async throws` — explicit restore
  - `permanentlyDeleteTrashEntry(id:) async throws`
  - `emptyTrash() async throws` — permanent-deletes all entries
- New observable property: `trashEntries: [TrashEntry]` — populated on load + after trash mutations.

### `lastDeletedTrashId`

In-memory `String?` on ProjectStore. Set when any delete moves an item to trash. Cleared when a new delete happens (most-recent supersedes) or when restore is called.

Survives only within one session — re-launch wipes it. Older items still recoverable via Trash view.

### `BinderSegment.trash`

New enum case alongside `.manuscript`, `.research`, `.scenes` (`.scenes` retained for UIState compat as established in 3c).

`BinderPaneToggle` shows the picker conditionally:
- When `store.trashEntries.isEmpty` is true: picker is `Manuscript / Research`.
- When non-empty: picker is `Manuscript / Research / Trash`.

This way the Trash segment doesn't clutter the UI for writers who haven't deleted anything yet.

### `TrashView`

SwiftUI view rendered when `binderSegment == .trash`. List of `TrashEntry`s with:
- Row title (original `displayTitle`)
- Caption: "Trashed N days ago — sweep in M days"
- Per-row Restore button
- Per-row Permanently Delete button (with confirmation modal)
- Toolbar "Empty Trash" button (also confirms)

### `⌘Z` for Restore Last Deleted

Add to `MaughamApp.commands`:

```swift
CommandGroup(after: .undoRedo) {
    Button("Restore Last Deleted Item") {
        NotificationCenter.default.post(
            name: .maughamRestoreLastDeleted, object: nil)
    }
    .keyboardShortcut("z", modifiers: .command)
    .disabled(/* needs reactive binding to lastDeletedTrashId */)
}
```

ProjectWindow subscribes to the notification and calls `store.restoreLastDeleted()`.

**Risk:** SwiftUI's command dispatch with `⌘Z` may conflict with NSTextView's built-in text undo. NSTextView handles `⌘Z` itself when it has focus, which should suppress the SwiftUI command. If implementation reveals dispatch conflicts, fallback is `⌘ Option Z`. The Trash view is the durable recovery path either way.

### 30-day sweep

Runs at `ProjectStore.load`. Walks `.trash/` subdirectories, parses timestamp prefix from each folder name, compares against `Date()` using `Calendar.current` (timezone-aware). Folders older than 30 days are deleted via `FileManager.default.removeItem`. Sweep failures (e.g., locked files) are logged and skipped, not fatal.

## Cross-cutting concerns

### Undo manager scope

The text-editor undo manager (built into NSTextView) handles typing-undo within a document. The new "Restore Last Deleted Item" command is a separate concept — it's about restoring deleted binder items, not text edits. They share the `⌘Z` shortcut but are routed by first responder. Verify this works cleanly during implementation.

### Manifest schema

Adding `BinderSegment.trash` is enum-additive; UIState decoding tolerates unknown values. No schema version bump.

ResearchItem and StructureItem are unchanged.

### Autosave

When the writer types into a brand-new research note, the existing 750ms debounced autosave (DocumentStore from 1e) writes to disk. No changes needed.

When a paste-image happens, the image file is written synchronously (it's not in the autosave loop — that's text only). The Markdown reference is inserted into the editor and saved on next autosave tick.

### Find / Replace

Unchanged. The image references are plain Markdown text and participate in Find normally.

### Conflict resolution

Unchanged. Each note is its own DocumentStore-backed file; per-file conflict scoping (existing) handles external changes including image-reference changes.

## Out of scope (deferred)

- **Image resizing / compression on paste.** Large screenshots saved as-is. A later "image management" milestone could add automatic resizing.
- **Animated GIF playback.** First frame static. Animation deferred.
- **Non-image rich paste handling.** Text paste behavior unchanged — plain text falls through to standard NSTextView paste.
- **Configurable trash retention.** Hardcoded 30 days. A future "preferences" pass could expose it.
- **Multi-step undo for binder operations.** Only the most recent delete is undoable via `⌘Z` in-session; older items recoverable via Trash view. Full operation history (rename undo, move undo, etc.) is a separate effort.
- **Drag image out of preview to clipboard.** One-way for now.
- **Image alt-text editing UI in preview.** Markdown supports it; the preview doesn't edit it.
- **Apply trash semantics to image attachments themselves.** Pasted images are hard-deleted when their parent note is permanently deleted; intermediate (note in trash) means the assets folder also sits in trash with its parent.

## Testing strategy

### Unit tests

- `TrashStoreTests` — moveToTrash writes to expected path with meta.json; restore brings file + metadata back; permanentlyDelete removes the entry; sweep removes only entries older than 30 days; list returns newest-first; corrupt meta.json is skipped from list without crashing.
- `ImagePasteHandlerTests` — saves PNG and JPEG; filename uses timestamp format; returns expected Markdown reference; creates `_assets/` folder lazily; handles fallback re-encode for non-PNG/JPEG.
- `ProjectStoreResearchNotesTests` — `addResearchTextNote` writes zero-byte `.md` to expected path, adds correct ResearchItem, dedups title collisions, handles invalid parentId by appending at root.
- `ProjectStoreTrashTests` — `deleteStructureItem` and `deleteResearchItem` route through trash; `restoreLastDeleted` brings the most recent back to original parent + index; `trashEntries` observable updates correctly.
- `RenameWithAssetsTests` — renaming a note also renames its `_assets/` folder; internal Markdown refs updated.
- `TrashSweepOnLoadTests` — pre-populate `.trash/` with old + recent entries; instantiate ProjectStore; verify only recent entries remain.

### Integration tests

- End-to-end research note: create via context menu → rename → paste image → close window → reopen project → image still rendered in preview.
- End-to-end trash round-trip: delete Chapter 7 → restoreLastDeleted → Chapter 7 back at original position in manuscript.
- Trash view actions: trash 3 items → Trash view shows 3 → Restore one → Trash view shows 2 → manuscript shows restored item.

### Manual smoke before tagging

1. Right-click research → "New Note" → enters rename mode → type name → file exists on disk under `research/<slug>.md`.
2. Paste image into note → file in `<slug>_assets/`, Markdown ref at cursor.
3. Toggle preview pane with ⌘ Shift P → image renders inline; toggle off — pane hidden.
4. Multi-paragraph note with mixed text + image refs → preview renders correctly.
5. Delete chapter from manuscript binder → moves to `.trash/`; Trash segment appears in picker.
6. ⌘Z → chapter back in manuscript binder at original position.
7. Delete two items → ⌘Z restores only the second; first still in Trash view → Restore it from Trash view → manuscript has both back.
8. Close window + reopen → Trash view still shows non-restored entries.
9. Trash view → Permanently Delete → confirm modal → entry gone from `.trash/`.
10. Trash view → Empty Trash → confirm → all entries gone.
11. Pre-set a `.trash/` entry's timestamp to 31 days ago → next launch → swept silently.
12. Rename a note with assets → assets folder renamed → preview still shows images via the updated refs.
13. Phase 3c features (parser, page count, inline emphasis, syntax help) unaffected.

Target: 466 tests → ~485 tests passing (rough estimate; ~19 new tests across the categories above).

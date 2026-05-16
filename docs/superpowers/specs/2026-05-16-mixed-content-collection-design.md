# Mixed-Content Collection — Group 3 milestone

**Goal:** Make `ProjectType.collection` functional. A Collection holds a flat list of **pieces**: each piece is either a loose mixed-content document (prose or screenplay, with its own optional research subfolder) or a reference to a standalone Maugham project. Get the writer using this on their actual short story collection — some pieces prose, some screenplay, some big enough to warrant their own project window.

**Anchors:** Group 3 of [`docs/roadmap.md`](../../roadmap.md) (Mixed-content collection). Builds on [ADR 0005](../../adr/0005-right-pane-mode-swap.md) (right-pane mode-swap pattern, reused). [ADR 0008](../../adr/0008-id-prefix-cleanup.md) (canonical ID scheme, in effect). New constraint recorded as [ADR 0009](../../adr/0009-collection-references-mac-local.md) (cross-Mac bookmark portability limitation).

**Out of scope (explicit):** Compile / cross-piece drag of research items / per-piece SessionLog / Outline mode for Collection windows / submission tracker / inline reference editing / cross-Mac bookmark portability beyond best-effort path fallback. See § 12.

---

## Decisions locked during brainstorm

1. **Both halves of the hybrid ship together** — loose pieces AND project references. A Collection becomes fully functional after this milestone.
2. **Folder-per-piece** — every loose piece is a folder under `pieces/`, even when it has no research yet. Uniform shape; adding research later just drops a file. Project references are also folder-shaped (containing a `.maugham-link.json`).
3. **Binder = Pieces / Research / Find / Trash.** Research has two sections: Shared (collection-wide) and `<active piece title>` (piece-scoped). Outline mode in the right pane is hidden in Collection windows.
4. **References open in a new Maugham window** when clicked. The Collection stays open as a coordinating table-of-contents.
5. **Inspector is polymorphic per piece kind** (prose / screenplay / reference). Goal indicator shows the active piece's metric (words for prose, pages for screenplay); hidden for references and when no piece is selected.
6. **`manifest.targets` is unused for Collections** — per-piece targets live on `StructureItem`.
7. **Loose pieces can be promoted to standalone projects** (§ 8). Right-click affordance, atomic move, the Collection's manifest entry is rewritten as a reference.
8. **Cross-Mac bookmark portability is best-effort.** Security-scoped bookmarks are Mac-local; absolute-path fallback covers same-iCloud-path cases; otherwise the reference is marked unresolved. See ADR 0009.

---

## Architecture

A Collection project owns a flat list of pieces in `manifest.structure`. Each piece is one of:

- **Loose piece** — folder under `pieces/` containing one main doc (`.md` or `.fountain`) plus an optional `research/` subfolder. `StructureItem.pieceKind = .loose`.
- **Project reference** — folder under `pieces/` containing a `.maugham-link.json` pointing at an external Maugham project. `StructureItem.pieceKind = .reference`.

`ProjectStore` gains Collection-specific mutations (`addLoosePiece`, `addProjectReference`, `promotePieceToProject`, `resolveReference`). `ProjectWindow` gains Collection-specific binder and Inspector rendering. The editor pane uses existing `WritingModeFactory` for per-file mode selection (already does the right thing based on extension).

Existing Novel / Short Story / Screenplay behavior is unchanged. New `StructureItem` fields are all optional; `pieceKind == nil` means "this is a manuscript chapter/scene/group, behave as before."

---

## Manifest schema changes

`StructureItem` gains four additive optional fields:

```swift
public var pageTarget: Int?               // for screenplay pieces; mirrors wordTarget
public var pieceKind: PieceKind?          // .loose / .reference; nil = legacy manuscript item
public var linkedProjectPath: String?     // for .reference pieces only
public var linkedProjectBookmark: Data?   // security-scoped bookmark, .reference pieces only
```

New enum:

```swift
public enum PieceKind: String, Codable, Sendable {
    case loose
    case reference
}
```

**Existing fields stay as-is.** A piece's `path` still points at the doc Maugham opens when the piece is clicked:
- For loose pieces: `pieces/<NN>-<slug>/<slug>.<ext>` (the main doc).
- For references: `pieces/<NN>-<slug>/.maugham-link.json` (the link file).

This keeps existing on-disk operations (rename → renames the folder + main doc, delete → moves folder to trash) working uniformly across loose and reference pieces.

**Per-piece metadata reused from existing `StructureItem` fields:**
- `title`, `synopsis`, `status`, `tags`, `wordTarget`, `links`
- New: `pageTarget` for screenplay pieces

**`children` stays `nil` for pieces.** No nested pieces — the Collection structure is flat.

**Schema version stays at 1.** Additive optional fields don't require a bump.

---

## On-disk layout

```
My Anthology/
├── project.maugham.json
├── pieces/
│   ├── 01-the-lighthouse-keeper/         ← loose prose piece
│   │   ├── the-lighthouse-keeper.md
│   │   └── research/
│   │       ├── lighthouse-notes.md
│   │       └── seabird-sounds.mp3
│   ├── 02-the-visit/                     ← loose screenplay piece
│   │   ├── the-visit.fountain
│   │   └── research/                     (empty until populated)
│   ├── 03-voicemail-transcript/          ← loose prose, no research yet
│   │   └── voicemail-transcript.md
│   └── 04-the-long-one/                  ← project reference
│       └── .maugham-link.json
├── research/                              ← shared / collection-wide research
│   └── thematic-notes.md
└── .maugham/                              ← project-internal state (existing)
    ├── ui-state.json
    ├── sessions.json
    ├── conflicts/
    └── .trash/
```

- Every loose piece is a folder. Adding research later drops files into the existing `research/` subfolder; no folder-vs-file promotion drama.
- Main doc filename matches the piece title slug. Same `Slugifier` Maugham already uses.
- `NN-` numeric prefix follows the Novel chapter scheme. Reorder triggers `Tidy Filenames` to keep them contiguous.
- Project reference folders contain only the `.maugham-link.json` file.
- Top-level `research/` mirrors a Novel's `research/` — flat files plus optional group subfolders.
- Per-piece `pieces/<slug>/research/` has the same internal structure as the top-level `research/`.

---

## Binder + Inspector polymorphism

### Binder segments (Collection windows)

- **Pieces** — replaces "Manuscript." Flat list. Each row: piece-kind icon, title, status dot, optional word/page count badge. Right-click + `+` button affordances for adding new pieces.
- **Research** — two sections:
  - **Shared** — collection-wide research items (from top-level `research/`)
  - **`<active piece title>`** — piece-scoped research from `pieces/<active>/research/`; header dynamic with selection
  - When no piece is selected, only the Shared section renders.
- **Find** — cross-collection search via existing `ProjectSearchEngine`. Walks all piece main docs + shared research + per-piece research.
- **Trash** — restorable deletes for pieces and research items. Same `.maugham/.trash/` mechanism as Novel; deleting a piece moves the entire piece folder.

### Pieces icons

- Prose piece: `doc.text` (or close equivalent)
- Screenplay piece: `film` (or close equivalent)
- Project reference: `link` (or close equivalent)

Final SF Symbol choices during implementation.

### Inspector polymorphism (right pane, `⌘⌥1`)

- **Prose-piece inspector** — title, kind label ("Prose"), synopsis, status, tags, **word target** Stepper, word_count read-out, linked-research summary.
- **Screenplay-piece inspector** — title, kind label ("Screenplay"), synopsis, status, tags, **page target** Stepper, page_count (parsed via `FountainTokenizer().parse(text).estimatedPageCount`), linked-research summary.
- **Reference inspector** — title (editable), kind label ("Linked project"), target path (truncating middle, copy button), resolution status (✓ Resolved with last-modified date, or ⚠ Unresolved), **Open in New Window** button (primary), **Reveal in Finder** button, **Re-link…** button, **Remove** destructive button.
- **No piece selected** — empty-state placeholder.

### Right-pane modes

The mode-swap pattern from [ADR 0005](../../adr/0005-right-pane-mode-swap.md) is reused with a Collection-specific tweak: Outline mode is hidden in Collection windows (pieces are flat; outline doesn't apply). Picker shows two segments instead of three:

- `⌘⌥1` Inspector (polymorphic per piece kind, see above)
- `⌘⌥2` Linked Research (piece-scoped)
- `⌘⌥3` — disabled / hidden

### Editor pane

- Selected loose piece → editor opens the piece's main doc. `WritingModeFactory` selects mode by extension.
- Selected reference → editor shows a "Linked project" placeholder card with an Open in New Window button (mirrors Inspector primary action, just larger).
- No selection → "Select a piece to start writing" empty state.

### Goal indicator (bottom-right capsule)

- **Hidden** when no piece is selected, or when a reference is selected.
- **Prose piece selected:** word_count vs. word_target, today's words (project-wide SessionLog total — per-piece sessions are out of scope).
- **Screenplay piece selected:** page_count vs. page_target.

---

## Creation flow + project type chooser

### Welcome window: Create Collection

The New Project sheet's Collection card subtitle updates to: *"Multiple stories or scripts in one project. Mix prose and screenplay; reference other Maugham projects."* New Collections start empty: `pieces/` directory created, `research/` directory created, manifest with `type: collection` and `structure: []`.

Empty-state in the Pieces segment when `structure: []`: *"Add your first piece. Right-click here or use the + button."*

### Adding pieces

Three actions surfaced via Pieces segment `+` button, right-click menu, and File menu:

| Action | Result |
|---|---|
| **New Prose Story** (`⌘N` context override) | Creates `pieces/<NN>-untitled-story/untitled-story.md` + empty `pieces/<NN>-untitled-story/research/`. Inline-rename mode active. |
| **New Screenplay** (`⌘⇧N`) | Creates `pieces/<NN>-untitled-script/untitled-script.fountain` + empty research/. Inline-rename. |
| **Link Existing Project…** | NSOpenPanel → picks a Maugham project folder → writes `pieces/<NN>-<slug>/.maugham-link.json` with security-scoped bookmark, reads target manifest for title + synopsis. |

`⌘N` is conditionally overridden inside a Collection window to mean "New Prose Story" (current `⌘N` "New Project" remains active when no Collection window is focused). Standard AppKit conditional commands.

### Adding research

Within the Research segment:

- `+` button when a piece is selected → creates a `.md` note inside `pieces/<active-piece>/research/`.
- `+` button with no piece selected → creates in the Shared section (top-level `research/`).
- Drag from Finder onto the segment → drops into Shared or the active piece's section based on drop target.
- Right-click → New Text Note / Add Link… / Import File…

### Reorder

Drag pieces up/down in the Pieces segment. Filenames keep the `NN-` prefix; on drop, `Tidy Filenames` runs automatically (existing 2a machinery).

### Delete

Right-click → Delete → moves the entire piece folder to `.maugham/.trash/` with a manifest fragment. `⌘⌥Z` restores. For a reference, only the reference folder is moved; the underlying linked project is untouched.

---

## Project references

### Storage

Each reference is a folder `pieces/<NN>-<slug>/` containing one file:

```json
// .maugham-link.json
{
  "version": 1,
  "title": "The Long One",
  "path": "/Users/denver/Documents/The Long One",
  "bookmark": "<base64 security-scoped bookmark data>",
  "linkedAt": "2026-05-16T13:45:00Z"
}
```

`path` is the absolute path at link time — used for display in the Inspector and as a fallback when the bookmark fails. `bookmark` is `NSURL.bookmarkData(options: .withSecurityScope, ...)` so the reference survives the target project being moved on the same Mac and works under sandbox restrictions.

### Manifest entry

```swift
StructureItem(
    id: "doc-<id>",
    title: "The Long One",                  // editable in the Collection; see below
    type: .document,
    pieceKind: .reference,
    path: "pieces/04-the-long-one/.maugham-link.json",
    linkedProjectPath: "/Users/denver/Documents/The Long One",
    linkedProjectBookmark: <Data>
)
```

**Title source of truth:** the Collection's manifest entry owns the display title. The `.maugham-link.json` title is seeded from the linked project's own manifest at link-time and stored for diagnostic fallback (useful when the reference is unresolved and Maugham wants to show *something* sensible). Editing the title in the Collection's reference Inspector updates the Collection's manifest entry only — the link file's title and the linked project's own manifest are not touched.

### Click behavior

1. `ProjectStore.resolveReference(_:)` calls `URL(resolvingBookmarkData:options:.withSecurityScope, ...)`. If the bookmark resolves: post `.maughamOpenProject` with the resolved URL — Maugham's existing project-opening flow (from milestone 1d) handles the new window.
2. If the bookmark fails:
   - Try `URL(fileURLWithPath: linkedProjectPath)` as fallback. If a project exists there: silently refresh the bookmark, post `.maughamOpenProject`.
   - If the path also fails: Inspector marks the reference unresolved. Clicking the row shows an alert ("This linked project can't be found at `<path>`. Re-link to its new location?") with Re-link and Remove buttons. The folder under `pieces/` stays until the user decides.

### Re-linking

Inspector's "Re-link…" button replaces `.maugham-link.json` with a fresh bookmark + path + linkedAt for whatever folder the user picks. Title can be edited inline.

### Cross-Mac caveat

Security-scoped bookmarks are Mac-local. A Collection containing references that you sync via iCloud to another Mac will land with bookmarks that don't resolve. The `path` fallback may or may not work depending on whether the target project is at the same absolute path (iCloud Drive paths often are). If the path also fails, the reference is unresolved and the user re-links. **Recorded as [ADR 0009](../../adr/0009-collection-references-mac-local.md).**

---

## Promote loose piece to standalone project

### Trigger

Right-click a loose piece → **Promote to Standalone Project…**. Disabled for references (already standalone) and grayed out if the piece's main doc is currently open in another window.

### Flow

1. **NSSavePanel** opens with the piece's slug pre-filled as the default folder name; default parent = parent of the current Collection folder. User picks a destination.

2. **Maugham stages the new project** under `<destination>/.maugham-staging-<uuid>/`. Stage contents:

   ```
   .maugham-staging-<uuid>/
   ├── project.maugham.json     ← fresh manifest, seeded from piece metadata
   ├── manuscript/
   │   └── <slug>.<ext>          ← piece's main doc, renamed under manuscript/
   ├── research/                  ← piece's research/ subfolder moved here
   │   └── …
   └── notes/                    ← empty
   ```

3. **New manifest seeded from the piece:**
   - `type`: `.shortStory` for `.md` pieces, `.screenplay` for `.fountain` pieces
   - `title`: piece title
   - `author`: inherited from Collection's manifest
   - `created`: now
   - `modified`: now
   - `structure`: single `StructureItem` for the manuscript doc, carrying over the piece's `synopsis`, `status`, `tags`, `wordTarget`/`pageTarget`
   - `research`: enumerated from the moved research subfolder
   - `targets`: derived from the carried-over wordTarget/pageTarget

4. **Validate** by loading the staged project via `ProjectStore.load(from:stagingURL)`. If validation fails, roll back (delete staging, no manifest changes). If it succeeds, atomically `replaceItemAt` to the final destination.

5. **Files moved (not copied):**
   - `<Collection>/pieces/<slug>/<slug>.<ext>` → `<destination>/manuscript/<slug>.<ext>`
   - `<Collection>/pieces/<slug>/research/` → `<destination>/research/` (whole subtree)
   - Use `FileManager.moveItem` for each step. Pending autosave flushed via `documentStore.flushPendingSave` and `documentStore.close` before moving.

6. **Convert Collection's piece into a project reference:**
   - Write `<Collection>/pieces/<slug>/.maugham-link.json` with title + absolute path + fresh security-scoped bookmark + linkedAt = now.
   - Update the Collection's manifest entry: `pieceKind: .loose` → `.reference`. Clear `synopsis`/`status`/`wordTarget`/`pageTarget` (those now live in the new project's manifest). Populate `linkedProjectPath` + `linkedProjectBookmark`.
   - The piece folder under `pieces/` now contains only the link file.

7. **Open the new project in a new window automatically.** The Collection window's Inspector for the now-converted reference updates immediately.

### Safety / rollback

- Pre-flight: if the piece's main doc is open in any window, flush and close before starting.
- If any step fails: staging is deleted, the Collection's manifest is not touched, the piece folder is restored intact (we move files atomically, last-step-first, with rollback on failure).
- Implementation pattern borrowed from `ClaudeDesktopConfig.merge` (atomic temp-then-rename writes).

### Test surface added

- Promote a prose piece → new project of type `.shortStory` exists with the doc under `manuscript/`, research migrated, Collection manifest entry now `.reference` with valid bookmark.
- Promote a screenplay piece → same but type `.screenplay`.
- Promotion failure (target path unwritable, target validation fails) → Collection unchanged, no leftover staging folder.
- Re-opening the Collection after promotion → reference resolves cleanly to the new project.

---

## MCP integration notes

The 14 existing MCP tools all need to behave correctly against Collection projects. Most "just work" because they read `manifest.structure` and `manifest.research`:

- `list_projects` reports Collection as `type: "collection"`.
- `get_outline` returns pieces as top-level nodes (flat — no children). The `modified` mtime is derived from the piece's main doc.
- `read_document` works on a piece's main doc (path in manifest points at it).
- `list_research` returns Shared research + per-piece research, structurally mirrored from disk.
- `search_text` walks all piece main docs.
- `find_references` and `list_all_links` walk wiki-link tokens in piece main docs and linked-research backrefs across pieces.
- `add_note(parent_group_id: nil)` lands in the Collection's Shared research folder by default. To land in a piece's per-piece research, the caller passes a synthetic parent_group_id formatted as the piece's id. (Decision deferred for implementation: confirm or extend the parent_group_id contract — for now, "land in shared if ambiguous" is the conservative default.)
- `link_research` / `unlink_research` work on per-piece `linkedResearchIds` arrays.
- `list_scenes` returns scenes parsed only from screenplay-kind pieces.
- `get_session_stats` stays project-wide for now (per-piece sessions are out of scope).

References that aren't open in another Maugham window are invisible to MCP — they don't appear in `list_projects` because the registry only tracks open projects. This is intentional and matches the live-only architecture from [ADR 0003](../../adr/0003-mcp-live-only-unix-socket.md). Future polish could expose references as "linked but not currently open" entries; out of scope here.

---

## Testing strategy

Mostly XCTest integration-flavored with temp-dir fixtures. Target ~30–40 new tests.

**Manifest + StructureItem:**
- New optional fields round-trip via Codable. Old manifests decode with nil defaults.
- PieceKind round-trips.

**Collection creation:**
- `ProjectStore.load` on a fresh Collection initializes `pieces/` and `research/`.

**Piece creation:**
- `addLoosePiece(title:mode:)` creates the folder + main doc + empty research/, adds manifest entry. Slug dedup with `-2`/`-3` suffix.
- `addProjectReference(targetURL:)` reads target manifest, writes `.maugham-link.json` with bookmark, adds manifest entry. Fails cleanly if target is missing a `project.maugham.json`.

**Reference resolution:**
- Bookmark resolves → returns resolved URL.
- Bookmark fails, path resolves → silently re-bookmarks, returns URL.
- Both fail → returns nil with unresolved status.

**Piece deletion + restore:**
- Delete moves entire piece folder to `.maugham/.trash/`.
- `⌘⌥Z` restores piece folder + manifest fragment.

**Per-piece research:**
- Adding a research note with active piece → lands in `pieces/<slug>/research/`.
- Adding a research note in Shared section → lands in top-level `research/`.

**Inspector + goal indicator polymorphism:**
- Prose piece exposes wordTarget Stepper + word_count.
- Screenplay piece exposes pageTarget Stepper + page_count.
- Reference shows reference Inspector.
- Goal indicator hides for references.

**Promotion:**
- Prose promotion → new `.shortStory` project; Collection entry now `.reference`.
- Screenplay promotion → new `.screenplay` project; Collection entry now `.reference`.
- Promotion failure → Collection unchanged, no leftover staging.
- Post-promotion: reference resolves to the new project.

**Find:**
- `ProjectSearchEngine` walks piece main docs + Shared research + per-piece research.

**Reorder:**
- Drag-reorder updates `NN-` prefixes; `Tidy Filenames` collapses gaps.

**MCP smoke (subset):**
- `get_outline` on a Collection returns pieces as flat top-level nodes with `modified` mtime.
- `read_document` returns piece text.
- `add_note` lands in Shared by default; in piece research when `parent_group_id` is a piece id.

UI integration is exercised via manual smoke at the end of the milestone (same pattern as MCP foundation's T17).

---

## Out of scope (explicit deferrals)

- **Compile** — assemble Collection into Word/EPUB/PDF. Group 3, separate milestone.
- **Cross-piece research drag** — move a research item from piece A to piece B. Workaround today: delete + re-create.
- **Per-piece SessionLog** — sessions stay project-wide. Per-piece sessions can come later if it bites.
- **Outline mode for Collection windows** — pieces are flat. Outline doesn't apply.
- **Reference inline preview / editing** — references open in a new window only.
- **Cross-Mac bookmark portability beyond best-effort** — see ADR 0009. Re-link affordance covers the gap.
- **Submission tracker** — Group 3 separate milestone.
- **Mixed-content evolution of existing projects** — Novel/Short Story/Screenplay projects don't gain piece semantics. Only Collection does.

---

## Carry-forwards to milestone memory at tag

- Final manifest shape with new optional StructureItem fields
- ProjectStore API additions (`addLoosePiece`, `addProjectReference`, `promotePieceToProject`, `resolveReference`)
- Bookmark resolution behavior (success / silent re-bookmark / unresolved)
- Promotion atomic-rename pattern
- Cross-Mac caveat (already in ADR 0009)
- MCP `add_note(parent_group_id)` semantics for piece-scoped research (whichever the implementation lands on)

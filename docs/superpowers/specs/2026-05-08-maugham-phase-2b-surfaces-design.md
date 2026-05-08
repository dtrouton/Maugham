# Phase 2b — Surfaces Design

**Date:** 2026-05-08
**Status:** Approved during brainstorm; ready for implementation plan.
**Anchor:** Builds on `2026-05-07-maugham-master-design.md` Phase 2 ("Novel Project Depth"). Sub-milestone 2b per `2026-05-08-phase-2-breakdown.md`.

---

## Goal

Two new surfaces in the project window:

1. **Research browser** — a peer view to the manuscript binder for collecting and previewing reference material (images, PDFs, text, audio, links). Files live under the project's existing `research/` folder; the manifest's existing `research: [ResearchItem]` gains its first writers and readers.
2. **Conflict diff sheet** — wires the disabled `Show diff` button in `ConflictBanner` to a real side-by-side line diff over the local vs external versions of a conflicted document.

These two surfaces ship as one milestone because both are net-new SwiftUI surfaces with limited pure-logic units. The implementation plan should still order them sequentially: research first (larger scope), conflict diff second.

---

## 1. Research browser

### 1.1 Placement

The binder pane gains a 2-button segmented control at the top:

```
┌─────────────────────────┐
│  Manuscript │ Research  │   ← segmented control
├─────────────────────────┤
│  Chapter 1              │
│  Chapter 2              │   ← rows, swap based on segment
│  ▼ Act One              │
│    Scene 1              │
└─────────────────────────┘
```

Default segment is `Manuscript` for parity with milestone 1d behaviour. The selection persists per project window via `DocumentStore.uiState` (existing UIState gains a `binderSegment: BinderSegment` field with values `.manuscript` / `.research`, default `.manuscript`).

When the user clicks a research row, the editor pane switches from `EditorHost` to a `ResearchPreview` view dispatching on the asset's `kind`. When the user clicks back to Manuscript and selects a manuscript item, the editor pane switches back. Selection state per segment is independent — switching segments restores the per-segment selected item.

### 1.2 Asset preview renderers

`ResearchPreview` is a switch on `ResearchItem.kind`:

| `kind` | Renderer | Framework |
|---|---|---|
| `image` | `ImagePreview` — `NSImageView` wrapped in `NSScrollView` for pinch-zoom | AppKit |
| `pdf` | `PDFPreview` — `PDFKit.PDFView` with continuous mode and toolbar disabled | PDFKit |
| `document` | `TextPreview` — read-only NSTextView with ProseMode tokenizer reused | AppKit + `MarkdownTokenizer` |
| `audio` | `AudioPreview` — `AVPlayer` + custom transport bar (play/pause/scrub/elapsed-time) | AVFoundation |
| `link` | `LinkPreview` — `WKWebView` with title bar showing the URL | WebKit |
| `group` (selected) | Empty state: "Select an item to preview." | — |

Each preview is read-only in 2b. Editing happens through the inspector (caption, tags) — see §1.6.

### 1.3 Hierarchical structure

Research mirrors the manuscript binder's hierarchy:
- A `group` (`ResearchItem.type == .group`) contains other items via `children`.
- An `asset` (`ResearchItem.type == .asset`) is a leaf with a `kind`.

Drag-reorder, drag-into-group, and drag-out-to-root all work the same as 2a's manuscript binder — except the on-disk semantics are simpler.

### 1.4 On-disk semantics

Research files do **not** use NN- prefixes. The manifest tracks order; Finder's view of `research/` is informational, not load-bearing. So:

- **Sibling reorder:** manifest-only update; no file rename.
- **Cross-group drag (asset):** physical file move via `DocumentStore.executeRenamePlan` with a single-step plan.
- **Cross-group drag (group):** physical folder move + manifest tree mutation.
- **No "Tidy Filenames" pass** — there are no NN gaps to fix.

This means research drag-drop is strictly cheaper than 2a manuscript drag-drop. It still routes through `DocumentStore` for iCloud safety on cross-group moves.

### 1.5 Adding items

Four input paths, all in scope:

#### Drag-from-Finder
Drop a file or folder onto the research pane. Each top-level item dropped:
- File → copies into `project/research/<group-path>/<filename>` via `DocumentStore.executeCopy`. Filename slugified (lowercase, dashes; extension preserved verbatim, e.g. `IMG_4521.HEIC` → `img-4521.heic`). New `ResearchItem(type: .asset, kind: <inferred>)` appended to the dropped target's children (or root if dropped on empty space).
- Folder → recursive copy; each file becomes an asset; sub-folders become `.group` items. (Capped at 1000 items per drop to avoid runaway imports; if exceeded, an alert offers "Import first 1000 / Cancel".)
- The asset `kind` is inferred from extension via a small `ResearchKindInference` helper:
  - `.image` for `jpg/jpeg/png/heic/heif/gif/webp/tiff/bmp`
  - `.pdf` for `pdf`
  - `.document` for `txt/md/markdown/rtf`
  - `.audio` for `mp3/m4a/wav/aac/flac/aiff/ogg`
  - else: skipped with a log warning (we don't want to import binaries we can't preview)

#### Right-click context menu
On the research pane (and on individual rows):
- **New Group** — empty group at the click target's level.
- **Add File…** — `NSOpenPanel`; multi-select allowed; same import path as drag-from-Finder.
- **Add Link…** — small sheet with title (text field) + URL (text field). Validates URL is parseable; creates a `ResearchItem(type: .asset, kind: .link)` with `url` set.
- **Rename** / **Delete** / **Duplicate** — same patterns as the manuscript binder.

#### Paste (⌘V on the research pane)
- Image clipboard → `pasted-<ISO8601>.png` written into research folder; new image asset.
- URL clipboard → new link asset (title is the URL host).
- Plain text clipboard → `pasted-<ISO8601>.md` with the text; new document asset.

#### File menu → Add Research File…
Identical to the right-click "Add File…", reachable from the menu bar. Visible whenever a project window is frontmost.

### 1.6 Inspector

When a research item is selected, the inspector pane swaps from manuscript-mode to research-mode. Fields:

- **Title** — single-line text field, edits flow through `ProjectStore.updateResearchItem`.
- **Caption** — multi-line text field; persists to `ResearchItem.caption`.
- **Tags** — chip-style row with comma-separated input; persists to `ResearchItem.tags`.
- **URL** — visible only for `.link` assets; editable.
- **Added** — read-only date display from `ResearchItem.addedAt`.
- **File path** — read-only relative path display, with a "Show in Finder" button.

The inspector slot is the same as manuscript mode; the variant is selected by the active `BinderSegment`. The two selections (`selectedItemId` for manuscript, `selectedResearchId` for research) are tracked independently on `ProjectWindow`, so switching segments restores per-segment selection rather than zeroing it.

### 1.7 Project types

All four project types (Single Document, Short Story, Novel, Screenplay) get the Manuscript/Research toggle. All four scaffold `research/` on disk via `ProjectFactory`. Single Document is the edge case — its manuscript binder is one row — but the research browser is the value-add for those projects, so the toggle still appears.

### 1.8 Out of scope for 2b
- Drag-from-research-into-manuscript-editor (e.g., insert markdown image link). Future milestone.
- The `notes/` folder. Separate surface; deserves its own brainstorm.
- Word counts on research items (research isn't part of word goals).
- Search across research items.
- Research item versioning / history.

---

## 2. Conflict diff sheet

### 2.1 Trigger

`ConflictBanner` currently has a disabled `Show diff` button (`Maugham/Views/ConflictBanner.swift:27`). Wire it:

- **Document conflict** — button enabled; click opens `ConflictDiffSheet` as a SwiftUI `.sheet` over the project window. Closing returns to the banner.
- **Manifest conflict** — button hidden (a JSON diff is not useful to a writer; manifest conflicts are silent-reload anyway).

The banner exists for both conflict types today. The `ConflictBanner` view gains a `showDiffEnabled: Bool` parameter and conditionally renders the button.

### 2.2 Layout

Side-by-side, two panes:

```
┌─────────────────────────────────────────────────────────┐
│  Chapter 2 — diff       cloud saved 2m ago         (×) │
├──────────────────────────┬──────────────────────────────┤
│  Mine                    │  Cloud                       │
│  12  The lighthouse...   │  12  The lighthouse...       │
│  13  watching the storm  │  13  watching the storm      │
│  14  Margaret pulled..   │  14  Margaret drew the wool. │  ← red/green
│  15  She had not seen..  │  15  She had not seen..      │
│  16  Three long years.   │  16  The bell tolled once.   │  ← red only
│  17  The bell tolled..   │  17                          │
├──────────────────────────┼──────────────────────────────┤
│  [ Keep mine ]           │  [ Use cloud ]               │  ← buttons-under-pane
└──────────────────────────┴──────────────────────────────┘
```

- **Sheet header**: file path + "cloud saved Xm ago" + close button (×). No footer "Cancel" — closing returns to the banner.
- **`Keep mine`** is the primary (blue) button under the left pane; **`Use cloud`** is secondary under the right pane. Buttons-under-pane removes the "which side does this apply to?" pause.
- **Removed lines** (lines that exist only in mine) get a red-tinted background and render only in the Mine pane.
- **Added lines** (lines that exist only in cloud) get a green-tinted background and render only in the Cloud pane.
- **Context lines** render plain in both panes.
- **Hunk gaps** are visualized with a thin separator and the gap's line range (`. . . 23 lines unchanged . . .`) when N>3 context lines wouldn't fit.

### 2.3 Diff algorithm

`LineDiff` is a pure-logic type at `Maugham/Stores/LineDiff.swift`:

```swift
public struct LineDiff: Equatable, Sendable {
    public enum LineKind: Equatable, Sendable {
        case context
        case removed   // present in mine only
        case added     // present in cloud only
    }

    public struct DiffLine: Equatable, Sendable {
        public let kind: LineKind
        public let mineLineNumber: Int?    // nil if added (cloud only)
        public let cloudLineNumber: Int?   // nil if removed (mine only)
        public let text: String
    }

    public struct Hunk: Equatable, Sendable {
        public let lines: [DiffLine]
    }

    public let hunks: [Hunk]
    public let totalMineLines: Int
    public let totalCloudLines: Int

    public init(mine: String, cloud: String, contextRadius: Int = 3)
}
```

Implementation uses Foundation's `CollectionDifference` over `[String]` lines (split by `\n`). The result is reshaped into hunks with `contextRadius` lines of unchanged content above and below each change. Adjacent change runs that share context windows merge into a single hunk.

**Test discipline for `LineDiff`** (pure logic, full TDD):
- Identical strings → 0 hunks.
- One-line addition → 1 hunk with the right line numbers.
- One-line removal → 1 hunk.
- One-line replacement → 1 hunk with both removed and added.
- Multiple non-adjacent changes → multiple hunks.
- Adjacent changes that share context → merged hunks.
- Trailing newline preservation.
- Empty mine vs non-empty cloud (and vice-versa).

### 2.4 Rendering

`ConflictDiffSheet` is a SwiftUI view:
- Takes a `LineDiff` and a `ConflictState` (for path + timestamp + the two text bodies).
- Renders two scroll views side-by-side. Each scroll view is a `LazyVStack` of monospace text rows; row backgrounds reflect kind.
- **Scroll-sync** — scrolling one pane scrolls the other in lockstep. Implementation via `ScrollViewReader` + observed `scrollOffset` state in both directions, debounced to avoid feedback loops. (If scroll-sync proves finicky to implement cleanly, the plan can downgrade to "left scrolls, right follows" with a clear caller-of-truth — but bidirectional is the target.)
- The two action buttons sit in pane footers; clicking calls `documentStore.resolveConflictKeepMine()` / `resolveConflictUseCloud()`, then dismisses.

### 2.5 Out of scope for 2b
- Word-level intra-line diff highlighting.
- Character-level diff.
- Three-way merge / interactive hunk resolution.
- Diff for manifest conflicts.
- Syntax highlighting in the diff view (plain monospace is enough).

---

## 3. Architecture summary

### 3.1 New types

| Type | Location | Purpose |
|---|---|---|
| `BinderSegment` | `Maugham/Models/BinderSegment.swift` | enum `manuscript`/`research`; persisted in `UIState` |
| `ResearchKindInference` | `Maugham/Stores/ResearchKindInference.swift` | extension-string → `AssetKind` (pure) |
| `ResearchView` | `Maugham/Views/ResearchView.swift` | research-mode binder pane |
| `ResearchRow` | `Maugham/Views/ResearchRow.swift` | row template (icon + title + drag/drop) |
| `ResearchPreview` | `Maugham/Views/ResearchPreview.swift` | dispatch on AssetKind to renderer |
| `ImagePreview`, `PDFPreview`, `TextPreview`, `AudioPreview`, `LinkPreview` | `Maugham/Views/research/` | per-kind renderers |
| `BinderPaneToggle` | `Maugham/Views/BinderPaneToggle.swift` | segmented control wrapping BinderView and ResearchView |
| `InspectorResearchPanel` | `Maugham/Views/InspectorResearchPanel.swift` | research-mode inspector |
| `AddResearchLinkSheet` | `Maugham/Views/AddResearchLinkSheet.swift` | title+URL input |
| `LineDiff` | `Maugham/Stores/LineDiff.swift` | pure line-diff → hunks |
| `ConflictDiffSheet` | `Maugham/Views/ConflictDiffSheet.swift` | the sheet UI |

### 3.2 Modified types

| Type | Change |
|---|---|
| `UIState` | adds `binderSegment: BinderSegment` (default `.manuscript`); schemaVersion bumps to `2`; `loadOrEmpty` handles v1 by defaulting the new field |
| `ProjectStore` | adds research mutators: `addResearchItem`, `moveResearchItem`, `duplicateResearchItem`, `deleteResearchItem`, `updateResearchItem`. Also `importResearchFiles(_:to:)` for multi-file Finder drops |
| `InspectorView` | conditional rendering: manuscript vs research panel based on selection origin |
| `ConflictBanner` | adds `onShowDiff: (() -> Void)?`; renders the button only when non-nil (manifest conflicts pass nil) |
| `ProjectWindow` | adds `@State showingDiffSheet: Bool`, `@State selectedResearchId: String?` (independent from `selectedItemId`); passes `onShowDiff` to banner; renders `ConflictDiffSheet` |
| `MaughamApp` | File menu adds "Add Research File…" command (posts notification) |

### 3.3 Test discipline

- **Pure logic, full TDD:** `LineDiffTests` (~10 tests), `ResearchKindInferenceTests` (~6 tests), `BinderSegment`/`UIState v2` migration tests (~3 tests).
- **Integration (real `NSFileCoordinator` + temp dirs):** `ProjectStoreResearchTests` covering add file, add link, move within siblings (manifest-only), move cross-group (physical move), delete, duplicate, import-from-Finder folder recursive.
- **Smoke-build only:** all SwiftUI views (per established 1d/1e/2a pattern). Manual smoke covers UI seam bugs.

### 3.4 Estimated scope

~14–16 implementation tasks. Sub-ordering:
1. Pure logic foundations (LineDiff, ResearchKindInference, BinderSegment)
2. UIState v2 migration
3. ProjectStore research mutators
4. ResearchView + ResearchRow + drag/drop wiring
5. BinderPaneToggle + ProjectWindow integration
6. Per-kind preview views (5 of them)
7. Inspector research panel
8. Add Link / Add File / Paste paths
9. ConflictBanner wiring + ConflictDiffSheet
10. End-to-end smoke + tag

---

## 4. Acceptance criteria (smoke test outline)

Once milestone-2b ships, this 10-step smoke confirms health:

1. Open a Novel. Click `Research` segment. Empty state shows.
2. Drag a JPEG from Finder into the research pane. Image asset appears; clicking renders inline at fit-to-pane.
3. Drag a PDF in. Click; PDFKit preview renders, pages scroll.
4. Right-click → New Group. Drag the PDF into the group. File physically moves; preview still works.
5. Right-click → Add Link… title "Maugham Wiki" URL "https://en.wikipedia.org/wiki/W._Somerset_Maugham". Click; WKWebView loads.
6. Paste an image from clipboard (⌘V). New `pasted-…png` appears.
7. Click `Manuscript`. Binder restores. Selection of the manuscript document restores the manuscript editor.
8. Click `Research` again. Per-segment selection restored.
9. Edit the manuscript externally so a conflict fires. Banner appears. Click `Show diff`. Side-by-side diff sheet opens; left/right scroll-sync works; Keep mine button on left dismisses sheet + banner with mine kept.
10. Repeat the conflict; click Use cloud. Cloud version persists; mine archived under `.maugham/conflicts/`.

If all 10 pass, milestone 2b is healthy.

---

## 5. Open considerations

These don't block the plan but are flagged for future milestones:

- **Research search.** With many items, finding a specific reference is hard. A search box at the top of the research pane is a natural Phase-2c or 3 add.
- **Research item versioning.** If a user replaces a referenced URL with a new version, current behaviour is destructive. Future iCloud-aware versioning could log replaced links to `.maugham/research-history/`.
- **Notes pane.** Each project has `notes/` scaffolded with no UI. A separate brainstorm should design notes' surface — likely closer to the manuscript editor than to research.
- **Drag research into editor.** Inserting a markdown image link or a transclusion reference. Substantive feature; Phase 3 territory.

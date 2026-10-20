# Report foundations, plan 3a: writing report elements in the editor

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a writer can write and see every report element in the manuscript editor:
- the elements are styled;
- typing them is never mangled;
- Insert Table, Insert Footnote and Insert Figure… work;
- dragging or pasting an image makes a figure backed by research;
- Tab and Return work inside tables, which tidy themselves;
- a research item's citation details are editable in the inspector and over MCP.

**Architecture:**
- Styling extends the TextKit 1 prose pipeline (`MarkdownTokenizer` → `Token.Kind` → `ProseMode`), with no glyph hiding or attachments.
- Commands edit the text view directly (the screenplay Tab-cycle route): one native undo step, through the membrane, with no new `applyExternalText` caller.
- Table text formatting is one Core function, which plan 3b's grid editor reuses.
- Figures are made through the existing `ProjectStore.addResearchAsset` (which copies via `DocumentStore.executeCopy`).
- Citation details get one store door, used by both the inspector and MCP.

**Plan 3b** (written after this plan is built, CLAUDE.md rule 11) covers:
- the citation and cross-reference pickers (the app's first in-editor picker);
- the resolved labels drawn beside citations and cross-references;
- the grid editor;
- the in-editor diagnostics.

**Tech stack:** Swift, AppKit (TextKit 1), SwiftUI, MaughamCore, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-19-report-foundations-design.md`. §4 is amended 2026-10-20 with Denver's two decisions:
- tables re-align on Tab, Return or leaving the table, never mid-keystroke;
- citations and cross-references keep their raw text visible, styled quietly, with the resolved label drawn beside it. That label is plan 3b.

Also read §3.1 (forms) and §3.4 (citation fields).

## Verified starting point (main @ fe4d665d)

A full survey with file:line references is in the controller's scratchpad. The facts a task needs are restated in that task.

- **There is no in-editor picker, drag-and-drop or Insert/Format menu today.** All menus are in `Maugham/MaughamApp.swift` `.commands {}` (≈:173). `KeyboardShortcuts.swift` is the shortcut census, and `DocSyncTests.test_paneShortcutsDocumentedInTheInAppCheatsheet` enforces it.
- **The tokenizer runs over the whole document every keystroke; only the paint is windowed.**
  - `retokenizeAndStyle` (`EditorCoordinator+Typography.swift` ≈:105).
  - `changedParagraphWindow` widens by **line**, not by blank-line block.
  - `MarkdownTokenizer.addMatches` lets the first claim win.
  - The pass order is: rule, heading, emphasis, code, link, wiki, checkbox, todo, list, blockquote.
  - `ProseMode.attributes(for:palette:baseFont:)` is the only exhaustive switch over `Token.Kind`.
- **Smart typography mangles report syntax today.** `SmartTypography.transform` turns `--` into `—` with no context check, so typing `|---|` gives `|—-|` and the table silently dies.
- **Two text-mutation routes exist.** This plan uses route A only.
  - **A** (`EditorCoordinator+TabCycle.swift` ≈:143–158): call `shouldChangeText` and `storage.replaceCharacters` on the text view, then `didChangeText`, set the selection, and re-assert it on the next runloop with a skip flag. This gives one native undo step, keeps the typing history, and goes through the membrane.
  - **B** (`Document.setParagraph`) wipes the typing undo history (ADR 0023 D1).
- **Research:**
  - `ProjectStore.addResearchAsset(parentId:fromURL:) async throws -> ResearchItem` copies and creates the item.
  - The scope-aware variant is `createResearchAsset(scope:fromURL:)` (`ResearchScope.swift`).
  - `updateResearchItem(id:title:caption:tags:url:)` has no citation parameter.
  - `trashedResearchCitationKeys()` is internal.
  - No MCP tool edits research fields, and `list_research` returns no citation.
- **Figure paths:** the reader is `FigureImageResolver.resolve(_:piecePath:projectURL:allowed:)` in `Maugham/Publish/`. Paths are relative to the piece's file, so `manuscript/ch1.md` → `../research/x.png`. A Collection piece uses its own `pieces/<x>/research/`.
- **`ProseMode` is shared** by the manuscript editor, `ResearchNoteEditor` (a primary editor that answers window commands) and `StatementEditorHost`. Styling appears in all three, but **insert commands must act only on a manuscript surface**.
- **The phone never edits manuscripts**, so nothing in this plan touches `MaughamPhone/`.

## Global constraints

- **Plan code is a contract.** Verify every existing signature before using it. New names are defined under each task's *Interfaces*.
- **Every new census or guard has a planted-offender control**, and the implementer runs the disable experiment and reports it.
- **Tripwires:**
  - **1, 26:** no attachments and no `NSTextStorage` tricks; storage stays plain text.
  - **2, 3, 6:** no new observable state on `EditorHost`; no heavy work in a binding setter.
  - **5:** no `NSPopover`.
  - **7:** no new `applyExternalText` caller.
  - **14:** moves and deletes go through the typed mover. Copies use `executeCopy`.
  - **33:** no press-then-wait tests and no synthesised clicks outside the allow-lists.
- **Typing cost has a budget.** Task 2 adds a fixture-free prose tokenize budget test, and every later task keeps it green.
- **Route A only for commands.** Each command is one native undo step, places the caret deliberately, and is refused by the membrane in a read-only posture, translation review or review mode. Menu items are disabled there.
- **Insert commands act only on a manuscript surface,** never on a research note or a statement.
- **Text-on-disk forms are exactly spec §3.1.** A table never contains a blank line (one op-log paragraph). A figure line is `![Caption](relative/path){#fig:name}` on its own paragraph.
- **Gates:**
  - Iterate with `./scripts/test.sh only <Class>`.
  - Run `./scripts/test.sh core` after a Core change.
  - Run `./gen.sh` after adding files.
  - The final task runs `./scripts/test.sh full` and `./scripts/test.sh phone`.
  - After any `ProjectWindow.body` change, run a local Release build (CLAUDE.md).

## Rulings this plan makes

- **R-3a-1 Shortcuts** (verify each is free first, then add to `KeyboardShortcuts.swift`):
  - Insert Table ⌘⇧T
  - Insert Footnote ⌘⇧N
  - Insert Figure… ⌘⇧I
- **R-3a-2 The menu.** A new `CommandMenu("Insert")` after Edit, the app's first. It holds Table, Footnote, Figure…, and a separator reserved for plan 3b's Citation… and Cross-Reference….
- **R-3a-3 Figure destination.**
  - A loose manuscript piece's image goes to the project's `research/` folder (top level).
  - A Collection piece's image goes to that piece's own research folder.
  - The research item is linked to the document (`linkResearch(researchId:toDocumentId:)`), as the binder's drop does.
- **R-3a-4 Figure label.**
  - The new figure gets `{#fig:<name>}`. The name is derived from the file stem: lower-case ASCII with non-name characters turned into `-`.
  - It is made unique against the project's existing `fig:` labels by appending `-2`, `-3`, and so on.
  - The caption placeholder `Caption` is selected after insertion.
- **R-3a-5 Insert Table** writes a 3-column table: a header row `| Column 1 | Column 2 | Column 3 |`, its delimiter row, one empty body row, and a `Table: Caption {#tbl:table-N}` line with N unique. The caret lands in the first header cell, with its text selected.
- **R-3a-6 Insert Footnote:**
  - It inserts `[^n]` at the caret, where n is the lowest positive integer not used as a footnote label in this document.
  - It appends a definition paragraph `[^n]: ` directly after the current paragraph, separated by one blank line, with the caret placed there.
  - All of this is one replace, so it is one undo step.
- **R-3a-7 Citation key edits.** A key must be `CitationKey.isValid` and unique against `(live keys − this item's own) ∪ trashed keys`.
  - Clearing the key while other fields are set is refused, with the words "A citation needs a key".
  - Removing all citation details sets `citation = nil`.
  - **Suggest** fills the key from `CitationKey.suggest`.
- **R-3a-8 Smart typography** never fires:
  - on a line whose first non-space character is `|`;
  - inside a `{#…}` block;
  - immediately after `@fig:`, `@tbl:` or `@sec:` followed by name characters.

  Elsewhere it is unchanged.

## Review focus

1. **Typing feel:** a 250 KB manuscript full of report syntax still tokenizes inside the budget, and the windowed paint equals the whole-document paint for edits inside a table, a citation, a footnote definition and a figure line. Pinned in Task 2.
2. **Undo:** each command (Insert Table, Insert Footnote, Insert Figure, a re-align, a new row) is exactly one ⌘Z step, and the writer's earlier typing undo survives it. Pinned in Tasks 4–6.
3. **A read-only book** (a narrowed piece, translation review, review mode) refuses every command. The menu items are disabled, and nothing reaches the op log. Pinned in Task 4.
4. **A research note or statement** never receives an Insert command, even though it shares `ProseMode`. Pinned in Task 4.
5. **A dropped image path that a figure line names** resolves through `FigureImageResolver` from that document, for a root-level story, a `manuscript/` chapter and a Collection piece. Pinned in Task 6.

---

### Task 1: Smart typography leaves report syntax alone

**Files:** `Maugham/Editor/Tokenizer/SmartTypography.swift`; tests in `MaughamTests/SmartTypographyTests.swift`.

- [ ] **Implement R-3a-8.** `transform` already receives `currentText` and the replacement range. Decide from the current line's text and the caret position inside it.
- [ ] **Write the tests.**
  - Typing `|---|`, `| :-- | --: |` and `|:-:|` character by character stays literal.
  - `{#fig:a--b}` and `@fig:a--b` stay literal.
  - `---` on a prose line still gets today's behaviour (pinned, unchanged).
  - Smart quotes inside a table cell still curl, which is harmless and left unchanged.
- [ ] **Run the gate and commit.** Run `./scripts/test.sh only SmartTypographyTests` and then `./scripts/test.sh`. Commit with the message `editor: smart typography leaves table rows, labels and cross-references alone`.

### Task 2: Tokens and styling for report elements

**Files:** `Maugham/Editor/Token.swift`, `Maugham/Editor/Tokenizer/MarkdownTokenizer.swift`, `Maugham/Editor/ProseMode.swift`. Tests: `MaughamTests/MarkdownTokenizerTests.swift` (or a new `ReportTokenizerTests.swift`), `MaughamTests/Editor/WindowedTypographyEquivalenceTests.swift`, `MaughamTests/Performance/TypingLatencyProbeTests.swift`.

**Interfaces (produced):** new `Token.Kind` cases. Exact names are the implementer's to choose, but each kind below must exist:
- the table's syntax (pipes and delimiter row);
- the table's header-row text;
- the table caption line;
- a footnote reference;
- a footnote definition's label;
- a citation;
- a cross-reference;
- the figure line's syntax;
- a trailing `{#…}` attribute block.

No associated value may change without a text change (the `TokenRestyleWindow` oracle compares `(kind, length)`).

- [ ] **Passes.**
  - Add them before the link and list-marker passes, so `[@a](x)` and a row starting `- |` are claimed correctly.
  - Inline markers come from `ManuscriptInlineScanner.scan` (it already skips code spans) over each blank-line block.
  - Tables and figures come from `ManuscriptBlocks.parse` per block, gated by a cheap check: the block contains `|`, or it starts with `![` or `[^`. Map line indices to UTF-16 offsets yourself.
  - A heading's trailing `{#sec:x}` is re-claimed as the attribute kind, not heading text.
- [ ] **Styling (`ProseMode.attributes(for:)`):**
  - Pipes and the delimiter row are muted (the theme's punctuation colour).
  - The header row is bold.
  - The caption line is muted italic.
  - A footnote reference is small, raised with `.baselineOffset` and the smaller font, and tinted.
  - A footnote definition's label is muted.
  - Citations and cross-references get a quiet tint (theme colour, with no background box this plan).
  - Figure syntax and `{#…}` are muted.

  Use theme colours that already exist, and add a palette entry only if none fits. Check both light and dark themes.
- [ ] **Window equivalence.** If a header row's bold depends on block context, either compute it per token (tokens are whole-document) or widen the paint window to the enclosing block. `WindowedTypographyEquivalenceTests` must get table, citation, footnote and figure cases and stay green.
- [ ] **Budget.** Add a fixture-free test that tokenizes the 250 KB `generateProse` corpus, extended with tables, citations, footnotes and figures. It asserts a budget: measure the current time on this machine and set the budget at about 2× with headroom, stated in the test, so it catches a quadratic regression, not noise. If the new passes push the existing O(tokens²) overlap check over budget, fix the overlap check (e.g. a sorted-interval check) in this task.
- [ ] **Tokenizer tests:**
  - every element;
  - a marker in backticks stays code;
  - an email address and `@sarah` are not cross-refs;
  - a table directly after prose with no blank line is not a table, per the parser rule;
  - the Fountain mode is unaffected.
- [ ] **Gate and commit.** Run `./scripts/test.sh`, then commit with the message `editor: report elements are tokenized and styled`.

### Task 3: Citation details: one store door, the inspector and MCP

**Files:**
- Store: `Maugham/Stores/ProjectStore+Research.swift` (or a new `ProjectStore+Citation.swift`).
- Inspector: `Maugham/Views/InspectorResearchPanel.swift` (new subviews are allowed in a new file).
- MCP: a new tool file in `Maugham/MCP/Tools/`, plus `ListResearchTool.swift` and `MCPToolCatalog`.
- Tests are new.

**Interfaces (produced):**
```swift
// ProjectStore
public enum CitationEditError: Error, Equatable { case invalidKey, duplicateKey(String), needsAKey }
public func updateCitation(researchId: String, _ citation: CitationInfo?) async throws   // R-3a-7; nil removes
public func suggestedCitationKey(for researchId: String) async -> String               // CitationKey.suggest over live ∪ trashed
```

- [ ] **The store door** validates per R-3a-7 against `manifest.research.citationKeys` (minus the item's own key) unioned with `trashedResearchCitationKeys()`. It saves through the existing manifest write path (`encodeForDisk`, schema floor; plan 1). Piece-scoped research items (Collections) must work too: check how `mutateResearchItem` finds them.
- [ ] **The inspector** gets a "Citation" section in `InspectorResearchPanel`, after Caption and URL:
  - Key, a text field with a Suggest button;
  - Authors, through the existing `InspectorTagsField` chip list;
  - Source title;
  - Publisher;
  - Year, a numeric field;
  - Accessed, the app's first `DatePicker(displayedComponents: .date)`, with a clear button;
  - Pages.

  Commits follow the panel's existing draft and commit pattern. A refused edit shows its reason inline and keeps the draft.
- [ ] **MCP.**
  - Add an `update_research_citation` tool with arguments `{project_id, research_id, citation: {key, authors, source_title, publisher, year, accessed (ISO date), pages} | null}`. It goes through the same store door, and errors map to invalid-argument.
  - `list_research` returns `citation` when it is present.
  - Register the tool in `MCPToolCatalog.all`.
  - Update every tools-list count or census that derives from the catalogue, and the MCP AREA guide and skills text if they list tools. MCP never touches manuscript text, and this tool edits only the research manifest, which is allowed.
- [ ] **Tests:**
  - the store door's rules: valid, invalid, a duplicate against a live item, a duplicate against a trashed item, its own key unchanged, clearing everything, and "needs a key";
  - a Collection piece's research;
  - MCP round-trip;
  - `list_research` shape;
  - the inspector's pure validation and formatting helpers.

  There are no press-then-wait tests.
- [ ] **Gate and commit.** Run `./gen.sh` and then `./scripts/test.sh`. Commit with the message `research: citation details are editable in the inspector and over MCP`.

### Task 4: The Insert menu, Insert Table and Insert Footnote

**Files:**
- `Maugham/MaughamApp.swift` (the `CommandMenu`);
- `Maugham/Resources/KeyboardShortcuts.swift`;
- `Maugham/Models/MaughamNotifications.swift`;
- `Maugham/Editor/` (a new `EditorCoordinator+Insert.swift`);
- the focused value for enabled state, published where the window publishes its others (`ProjectWindow`);
- `docs/guide/reference.md`.

Tests are new.

**Interfaces (produced):**
```swift
// Pure text builders (Mac Editor, testable without a view):
enum ReportInsert {
    static func table(nextLabelNumber: Int) -> String                       // R-3a-5
    static func footnote(in paragraph: String, caret: Int, existingLabels: Set<String>)
        -> (replacement: String, replacedRange: NSRange, caret: NSRange)    // R-3a-6, ranges relative to the paragraph
}
```

- [ ] **The menu** follows R-3a-1 and R-3a-2. Each item posts a key-window `MaughamEvent`. The coordinator observes it with the recipe "Add a window command the editor answers" (token held and removed in `detach()`, gated by `respondsToWindowCommands`), and **also** requires a manuscript surface. Use whatever reliably distinguishes it (e.g. a non-nil `paragraphRangeProvider` or a new explicit flag set only by `EditorHost`'s manuscript configuration). Pin it with a census or a test that a research-note configuration doesn't answer.
- [ ] **Enabled state.** Publish a focused value saying whether the key window's active editor may insert into a manuscript. It combines the posture `allows(.writeText)` with not-translation-review and not-review-mode. Menu items read it. The coordinator's membrane still refuses on its own, as defence in depth.
- [ ] **Route A edit.** Each insert is one `replaceCharacters`, so it is one undo step. It sets the caret, using the TabCycle skip-flag pattern so `textDidChange`'s cursor restore doesn't move it. A table that is inserted mid-paragraph splits the paragraph: the table goes on its own block, with blank lines before and after as needed.
- [ ] **Tests:**
  - the pure builders;
  - one undo step, with earlier typing undo surviving, driven on a mounted editor through `TestWindow` without synthesised clicks: post the command, then assert;
  - refused in a read-only posture, in translation review and in review mode;
  - a research-note editor ignores the command;
  - footnote numbering skips used labels;
  - the shortcut census.
- [ ] **Gate and commit.** Run `./gen.sh`, `./scripts/test.sh`, and a Release build if `ProjectWindow.body` changed. Commit with the message `editor: an Insert menu with Table and Footnote`.

### Task 5: Moving through tables, and keeping them tidy

**Files:**
- Core: `Packages/MaughamCore/Sources/MaughamCore/TableText.swift` (new);
- `Maugham/Editor/EditorCoordinator.swift` (the `doCommandBy` prose arms);
- a new `EditorCoordinator+Tables.swift`.

Tests: Core and Mac.

**Interfaces (produced; plan 3b's grid editor reuses these):**
```swift
public struct TableText: Equatable, Sendable {
    public var header: [String]; public var alignments: [TableAlignment]; public var rows: [[String]]
    public var caption: String?; public var label: ManuscriptLabel?
    public init?(parsing block: String)                 // nil if the block isn't a table (via ManuscriptBlocks)
    public func formatted() -> String                   // column-aligned pipes, delimiter from alignments, caption line; never a blank line
    public static func cell(at utf16Offset: Int, in block: String) -> (row: Int, column: Int)?   // row 0 = header; delimiter row = nil
    public static func offset(ofCell row: Int, _ column: Int, in formatted: String) -> Int      // start of the cell's text
}
```

- [ ] **`TableText` lives in Core**, so publishing, the grid editor and any later phone or MCP use share it (tripwire 19).
  - `formatted()` pads cells to the column's display width. Use grapheme count; a CJK width approximation isn't required, but say so in the doc comment.
  - The delimiter row is written from the alignments (`:--`, `:-:`, `--:`, `---`).
  - A `|` inside cell text is escaped `\|`.
  - Round trip: `TableText(parsing: t.formatted()) == t`.
  - Run `./scripts/test.sh core` and `phone`.
- [ ] **Tab, Shift-Tab and Return.** Add prose arms in `textView(_:doCommandBy:)`. They act only when the caret is inside a table token range from `lastTokens`; otherwise they return false, as today.
  - Tab moves to the next cell's text, and at the last cell it does nothing.
  - Shift-Tab moves to the previous cell.
  - Return at the end of a body row inserts a new empty row after it and moves the caret into its first cell. Return elsewhere behaves normally.
  - **Each of these first re-aligns the table** (R-3a tidy): if `formatted()` differs from the current block, replace the block in one `replaceCharacters`, then map the caret to the same cell through `offset(ofCell:)`.
  - A move with nothing to re-align is selection-only and makes no undo step.
- [ ] **Leaving the table** also re-aligns. In `textViewDidChangeSelection`, when the caret moves from inside a table to outside it and the table is not tidy, schedule the re-align on the next runloop, as Route A with its own single undo step, so it never runs inside the selection callback's stack.
  - Never re-align while a marked-text (IME) composition is active.
  - Never re-align in a read-only posture; the membrane refuses.
- [ ] **Tests:**
  - Core: format, round trip, the cell and offset functions with Unicode cells, an escaped pipe, a ragged row.
  - Mac (mounted editor via `TestWindow`, driven by `doCommand(by:)` calls, no synthesised keys beyond the allow-lists):
    - Tab and Shift-Tab positions;
    - Return adds a row;
    - one undo step per re-align, and earlier typing undo survives;
    - leaving the table tidies it;
    - Tab outside a table still inserts a tab;
    - an IME composition is not disturbed.
- [ ] **Gate and commit.** Run `./scripts/test.sh`, then commit with the message `editor: tables move by cell and tidy on Tab, Return and leaving`.

### Task 6: Figures from a file, a drop or a paste

**Files:**
- `Maugham/Editor/EditorSurface.swift` (`MaughamTextView` drag and paste);
- a new `Maugham/Editor/FigureIngest.swift`;
- the insert handler from Task 4;
- `EditorHost` (handler wiring);
- `Maugham/Publish/FigureImageResolver.swift` only if a shared relative-path helper belongs beside it.

Tests are new.

**Interfaces (produced):**
```swift
enum FigureIngest {
    /// The figure line's path, relative to the document (R-3a-3); round-trips through FigureImageResolver.
    static func relativePath(fromDocument docPath: String, toResearch researchPath: String) -> String
    static func figureLabel(stem: String, existing: Set<String>) -> ManuscriptLabel        // R-3a-4
    static func figureLine(path: String, label: ManuscriptLabel) -> String                  // "![Caption](path){#fig:name}"
}
```

- [ ] **Insert Figure… (⌘⇧I)** opens an `NSOpenPanel` limited to images, using the project's panel-configuration struct pattern (CLAUDE.md: a test asserts a value struct, never a panel).
- [ ] **Drop.** `MaughamTextView` accepts a dragged image file URL. Use `isIngestableImage` from `ImagePasteHandler`. Ask the membrane first: a refused drop shows the no-entry cursor. Never let AppKit insert the path or an attachment as text. A drop that isn't an image falls back to today's behaviour.
- [ ] **Paste.** The manuscript editor gets a figure handler for pasted image data. It writes a temporary PNG as `ResearchPasteImporter` does, and keeps the "nil means handled" rule so no U+FFFC reaches the op log. Research notes and statements keep their existing `_assets/` handler unchanged.
- [ ] **The ingest** runs `createResearchAsset(scope:fromURL:)` (or `addResearchAsset`) per R-3a-3, then `linkResearch`. It builds the figure line, writes it as its own paragraph at the drop point or caret through Route A (one undo step), and selects `Caption`. The project's existing `fig:` labels for R-3a-4 come from the documents' derived text via `ManuscriptBlocks`; keep that off the main-thread hot path if it's slow.
  - If the copy fails, nothing is written and the error is surfaced the way other editor errors are.
  - Undoing the insert leaves the research item in place, which is acceptable and stated in the user guide.
- [ ] **Tests:**
  - `relativePath` for a root `story.md`, `manuscript/ch1.md` and a Collection piece, each verified by calling `FigureImageResolver.resolve` on the result;
  - label uniqueness;
  - the panel configuration value;
  - an ingest end to end on a temporary project: the item exists, it is linked, the line is in the document, and there is one undo step;
  - a refused drop in a read-only posture;
  - a pasted image produces no U+FFFC.
- [ ] **Gate and commit.** Run `./gen.sh` and `./scripts/test.sh`. Commit with the message `editor: Insert Figure, image drop and paste make research-backed figures`.

### Task 7: A thumbnail under each figure line

**Files:** a new `Maugham/Editor/FigureThumbnailOverlay.swift`, the coordinator's overlay installation (the review-overlay precedent), and `ProseMode` (paragraph spacing on figure lines).

- [ ] **Reserve the space.** The figure line's paragraph gets extra `paragraphSpacing` from the figure token's styling (an attribute, not a character), sized for a thumbnail of at most 120 pt tall at column width.
- [ ] **Draw the thumbnail** in an overlay view modelled on `AnnotationMarkRenderer`:
  - `isFlipped`;
  - `hitTest` returns nil;
  - it draws only figures in the visible glyph range;
  - it repaints on text change and on scroll.

  Images are resolved through `FigureImageResolver` from the document's own path. Thumbnails are cached, keyed by path plus modification date, and decoded off the main thread with ImageIO thumbnailing, never full decode (tripwire 4).
- [ ] **Unresolvable images.** A missing or unresolvable image draws a small muted "Image not found" box rather than nothing.
- [ ] **Focus dim.** The thumbnail honours focus dimming by drawing at the paragraph's alpha.
- [ ] **Tests:**
  - the cache, keyed and bounded;
  - the layout maths (pure);
  - one mounted test that the overlay installs on a manuscript and draws nothing when no figure is visible.

  No pixel snapshots.
- [ ] **Gate and commit.** Run `./scripts/test.sh` and commit with the message `editor: figure lines show a thumbnail beneath them`.

### Task 8: Docs and the full gate

- [ ] **Editor AREA guide:**
  - Map rows for the new files.
  - Rules:
    - commands use Route A;
    - inserts act on manuscripts only;
    - tables tidy on Tab, Return and leaving, never mid-keystroke;
    - thumbnails are an overlay, never an attachment;
    - the tokenize budget.
- [ ] **Other AREA guides:**
  - Views: the Insert menu and the focused value.
  - MCP: the new tool.
  - Stores: the citation door.
  - Core: `TableText`.
- [ ] **User guide:**
  - writing a table, with Tab and Return;
  - footnotes;
  - figures, by Insert, drop or paste;
  - citations, including filling in a source's citation details in the inspector;
  - cross-references, typed by hand for now.

  Describe only what ships: no pickers yet.
- [ ] **Keyboard reference** (`docs/guide/reference.md`) gets the three new shortcuts.
- [ ] **DocBudget ceilings** are set to the actual `wc -w`, with reasons, and contain no milestone tags.
- [ ] **Full gates:** run `./scripts/test.sh full`, `./scripts/test.sh phone` and `./scripts/test.sh core`.
- [ ] **Commit** with the message `docs: editor guides and user guide for writing report elements`.

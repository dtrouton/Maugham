# Report foundations, plan 3b: references, labels, the grid and checks in the editor

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** in the manuscript editor the writer can:
- **pick a source** by typing `[@` or using Insert ▸ Citation…;
- **pick a figure, table or section** by typing `@` and a letter, or using Insert ▸ Cross-Reference…;
- **see** "(Gartner 2026)" or "Figure 3" faintly beside each raw marker;
- **edit a table in a grid** (Edit Table…), including pasting cells copied from Excel, Numbers or Sheets;
- **see problems** in the text (an unknown key, a dangling cross-reference, a duplicate label, a missing footnote definition), each marked with an underline that explains itself on hover.

**Architecture:**
- **One host-side reference index** per window holds the project's citation entries and cross-reference targets, with editor-side numbers. It is cached on the research and derived-text versions, and the coordinator reads it through closures, never per keystroke.
- **The pickers** are the app's first in-editor completion list: a plain `NSView` in the scroll view (tripwire 5: no `NSPopover`). Their keys are routed first in `doCommandBy`, and the trigger comes from the typed character.
- **Labels and problem underlines** are display-only. Labels come from an overlay; underlines are layout-manager temporaries on underline keys. Neither changes the text or the paint inputs.
- **The grid editor** is a SwiftUI sheet that `EditorHost` presents through an async host closure. Its save is one `applyCommandEdit`.

**Tech stack:** Swift, AppKit (TextKit 1), SwiftUI, MaughamCore, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-19-report-foundations-design.md` §4. §4 was amended 2026-10-20: raw markers stay visible with the resolved label beside them, and tables tidy on Tab, Return or leave. This plan builds on plan 3a, `docs/superpowers/plans/2026-10-20-report-foundations-plan3a-editor-writing.md`, which is built and on local main at e3c8e99c. Never restate plan 3a's API; verify it in the code.

## Verified starting point (main @ e3c8e99c)

The controller's survey `plan3b-survey.md` has file:line for each item below. It is copied into the plan's SDD workspace.

- **Route A:** `applyCommandEdit(replacing:with:selecting:actionName:landing:)` with `CommandLanding.immediate/.deferred(writerMoved:)` (`EditorCoordinator+Insert.swift`). It gives one undo step, uses an explicit bracket at level 0, and sets no coordinator flag.
- **The Insert menu:**
  - Defined in `MaughamApp.swift` (`InsertMenuButtons`, with a comment reserving Citation… and Cross-Reference…). Its events are `maughamInsertTable/Footnote/Figure`.
  - The focused value is `mayInsertReportElement`, and the gate is `InsertMenuGate.isEnabled(...)`.
  - On the coordinator side:
    - `insertCommandContext()` checks `answersInsertCommands` and `anotherTextInputHasTheFocus`;
    - the flag census is `InsertCommandTests.answersInsertCommandsFiles`.
- **`projectLabelsElsewhere`:**
  - It returns labels only, walks every document per call, and includes `.reference` pieces. Publishing excludes those pieces.
  - It is built in `EditorHost` from live or derived text through `ReportInsert.labelsElsewhere`.
- **Tokens:**
  - Plan 3a's report kinds carry no payload; keys and labels are re-read from the text.
  - In a mixed bracket the citation token covers only the first key's item, so use `ManuscriptInlineScanner.scanGroups` for the whole bracket.
  - `tableBlockRange(containing:in:)` is a binary search.
  - Figure lines and marks are derived in `lastTokens.didSet`.
  - `tokensDescribeAnEarlierText` is set while an edit is mid-flight.
- **`doCommandBy`.** In prose today it is only `return handleTableCommand(...)`. Esc arrives as `cancelOperation:`, and possibly as `complete:`, which opens AppKit's own completion window and must be swallowed.
- **Overlays:**
  - `FigureThumbnailOverlay` is the model for install, layout and repaint, and for drawing only the visible range.
  - `SelectionToolbarView` is added to the scroll view but is never hidden on scroll, resize or focus loss.
- **Numbers:** `PublishResolution` (in Maugham/Publish) numbers figures and tables by plain counting over `publishablePieces()` order with `ManuscriptBlocks.parse`. Sections depend on the shallowest heading and on `numberSections`. Citations get a/b letters from the whole book's cited set. `ElementWords` gives "Figure"/"Slika".
- **Diagnostics:**
  - `ManuscriptIndex` (Core) has no production caller.
  - Its "column" is internal, a block offset.
  - `applyTranslationDimming` clears all `.foregroundColor` temporaries, so diagnostics must use underline keys.
- **Sheets:** a `.keyWindow` post from inside a sheet is dropped (Views AREA), so a result can't be posted back. `EditorHost` can present a sheet and await it, like the `figureImporter` precedent.
- **Gaps:**
  - No tab-separated-text parser exists.
  - `TableText.formatted()` drops a label when the caption is nil, and doesn't handle newlines in cells.
- **Docs budget:** the Views AREA guide is at 7,999 of its 8,000-word hard cap; the Editor AREA guide is at its ceiling. Move narrative to `docs/history/` rather than raise a cap.

## Global constraints

- **Plan code is a contract.** Verify every existing signature before use. New names are given under each task's *Interfaces*.
- **Every new census or guard** has a planted-offender control and a disable experiment, reported.
- **Tripwires:**
  - 1 and 26: no attachments or glyph hiding; storage stays plain text.
  - 2, 3 and 6: nothing new observable on `EditorHost`; no heavy work in a binding setter.
  - 4: nothing uncached per row or per keystroke.
  - 5: no `NSPopover`.
  - 7: no new `applyExternalText` caller.
  - 33: no press-then-wait tests and no synthesised clicks outside the allow-lists.
- **No new per-keystroke cost** proportional to the project. Per keystroke the editor may touch only this document's tokens. Project data comes from the cached index.
- **Every write is one `applyCommandEdit`:** one undo step, refused by the membrane in a read-only posture or in review/translation review. Menu items follow `InsertMenuGate`.
- **Insert and edit commands act on a manuscript surface only,** and only when it is the focused primary editor (plan 3a's `insertCommandContext`).
- **Gates:**
  - `./scripts/test.sh only <Class>` while iterating;
  - `./scripts/test.sh core` after a Core change;
  - `./gen.sh` after adding files;
  - a Release build after a `ProjectWindow.body` change;
  - the final task runs `full`, `core` and `phone`.

## Rulings this plan makes

Denver was asleep. Each ruling is reversible and recorded for his morning review.

- **R-3b-1 Where the faint label goes.** The label is drawn small (about 0.65× the body size), muted, in the line-spacing gap directly **beneath** the end of the raw marker. Drawing it "after" the marker would overlap the next word, because no room can be reserved without glyph tricks.
  - When the paragraph's line spacing leaves less room than the label's height, the label is shown only while the caret is inside the marker or the pointer hovers it, as a small tag drawn above the line.
  - Labels never change layout.
- **R-3b-2 Editor numbers.**
  - Figures and tables: "Figure n" and "Table n" count in publishing order. That is `publishablePieces` binder order, excluding reference pieces, with the default edition (no imprint exclusions).
  - Sections: show the heading's own text, not a number.
  - Citations: `CitationStyle.inText` with a/b letters disambiguated over the citations used across the project's manuscripts.
  - Words come from `ElementWords` in the book's source language.
  - A label that can't be resolved shows nothing; the problem underline shows instead.
  - The editor's numbers can differ from an imprint's PDF. That is accepted and stated in the guide.
- **R-3b-3 Insert Table** keeps plan 3a's direct template. **Edit Table…** (menu, ⌘⌥⇧T) and a **double-click on a table's delimiter row** open the grid. Double-clicking inside a cell still selects a word.
- **R-3b-4 Problem marks.**
  - Unknown key, unresolved cross-reference, duplicate label, and missing, duplicate or unused footnote definition get a dotted underline: red for a problem a Report refuses on, amber for the others, matching `PublishProblem.isError(profile:)`.
  - The project's profile decides which colour.
  - Hovering shows the problem's sentence as a tooltip.
  - There is no separate list in the editor; the publishing desk's problems list remains the list.
- **R-3b-5 Picker triggers.**
  - `[@` opens the citation picker.
  - `@` followed by a letter opens the cross-reference picker, when the `@` is at a word start: after whitespace, `(`, `[` or `;`, or at line start. It is never after an email-like character.
  - Typing `;` inside an open citation bracket reopens the picker for the next key.
  - Return or Tab accepts. Esc closes. ↑ and ↓ move. Typing filters.
  - Closing the picker leaves the typed text exactly as typed.
- **R-3b-6 Picker contents.**
  - **Citation picker:** live research items that have a citation key. The filter matches key, authors and source title. Each row shows "Author Year — Title" and the key.
  - **Cross-reference picker:** labelled figures, tables and sections across the project, in publishing order. Each row shows "Figure 3 — caption" (or the section's title) and the label.
  - An empty result shows "No matching sources". The citation version adds "add citation details in the research inspector".

## Review focus

1. **Typing feel.**
   - Opening, filtering and closing a picker on a 250 KB manuscript in a 50-document project costs no project-wide work per keystroke.
   - Labels and underlines repaint without a whole-document restyle.
   - Pinned in Tasks 1, 2 and 6.
2. **Keys never collide.**
   - In a table cell with the picker open, Tab and Return accept the pick. With the picker closed, they move cells as before.
   - Esc never opens AppKit's completion window.
   - IME composition is never interrupted.
   - Pinned in Task 2.
3. **The grid save is safe.**
   - If the table changed while the sheet was open, the save is refused with a sentence and nothing is written.
   - The save is one ⌘Z step.
   - A label survives when there is no caption.
   - Pasted cells with tabs and quotes land in the right cells.
   - Pinned in Task 5.
4. **Labels match publishing for a default book.** For a three-chapter fixture, the editor's "Figure n" and "Table n" equal `PublishResolution`'s numbers. Pinned in Task 1.
5. **No marker misfires.** These never open a picker or get underlined:
   - an email address;
   - `@sarah`;
   - `[@` typed inside backticks;
   - a marker in a research note or a statement.

   Pinned in Tasks 2, 3, 4 and 6.

---

### Task 1: The reference index

**Files:**
- Create `Maugham/Editor/ReferenceIndex.swift` (pure model and builder) and `Maugham/Views/ReferenceIndexHost.swift` (cache and invalidation; or fold into `EditorHost` if smaller).
- Modify `EditorSurface.ParagraphProviders`, `EditorCoordinator` (closures) and `EditorHost`.
- Test: `MaughamTests/Editor/ReferenceIndexTests.swift`.

**Interfaces (produced):**
```swift
struct ReferenceIndex: Equatable, Sendable {
    struct Source: Equatable, Sendable { let key: String; let label: String /* "(Smith 2026a)" text without parens? see contract */; let authorsLine: String; let title: String }
    struct Target: Equatable, Sendable { let label: ManuscriptLabel; let text: String /* "Figure 3" or a heading's text */; let detail: String /* caption or title */; let docId: String; let order: Int }
    let sources: [Source]                 // live research items with a key, sorted by authorsLine
    let targets: [Target]                 // publishing order
    func source(forKey: String) -> Source?
    func target(for: ManuscriptLabel) -> Target?
    let version: Int                      // bumps when anything above changes
    static func build(structure: [StructureItem], research: [ResearchItem], text: (StructureItem) -> String?, words: ElementWords...) -> ReferenceIndex
}
// Coordinator side: var referenceIndex: (() -> ReferenceIndex)?   — cheap: returns the host's cached value
```

**Contract:**
- [ ] **What the index holds.**
  - The builder walks publishable manuscript pieces in publishing order. That is `publishablePieces`' rules: reference pieces and screenplays are excluded. Verify by reading `ProjectStoreASTSource`.
  - It parses each piece with `ManuscriptBlocks.parse` and numbers figures and tables by plain counting (R-3b-2). Sections use their heading text.
  - Citation labels come from `CitationStyle.disambiguated` over the keys actually cited anywhere in those pieces (`ManuscriptInlineScanner.scan`), plus uncited sources undisambiguated. Choose the exact `label` text shape and document it.
- [ ] **Caching.**
  - The host caches the index and rebuilds it off the main thread when `store.manifest.research` changes, when any piece's derived text changes, or when the open document's text settles (the 350 ms metrics edge or deferred settle; never per keystroke).
  - The open document uses its live text.
  - The coordinator gets the cached value through a closure.
  - When the version changes, the host pushes a redraw trigger to the coordinator through `EditorControl`, following the `annotationsVersion` precedent. Research data is not text-derived, so ADR 0017's rule D1 allows it.
- [ ] **Replace the old closure** `projectLabelsElsewhere`'s per-call walk with the index for `fig:` and `tbl:` uniqueness, in both Insert Table and figure ingest. Keep it as a thin derived function, and keep its tests green.
- [ ] **Tests:**
  - **Fidelity:** a three-chapter fixture has the same figure and table numbers as `PublishResolution.resolve` over the same project (review focus 4).
  - Reference pieces are excluded.
  - a/b letters.
  - Uncited sources.
  - Version bumps.
  - The rebuild runs off the main actor.
  - A 50-document project builds inside a stated budget, measured as a scaling ratio, not wall-clock.
- [ ] **Commit:** run `./gen.sh` and `./scripts/test.sh`, then commit with the message `editor: a reference index of the project's sources and targets`.

### Task 2: The completion list (shared picker infrastructure)

**Files:** create `Maugham/Editor/CompletionListView.swift` (a plain `NSView`) and `Maugham/Editor/EditorCoordinator+Completion.swift`; modify `EditorCoordinator.swift` (`doCommandBy`, `shouldChangeTextIn`, `textDidChange`, selection changes) and `EditorSurface.swift` (install). Test: `MaughamTests/Editor/CompletionListTests.swift`.

**Interfaces (produced):**
```swift
struct CompletionItem: Equatable { let title: String; let subtitle: String; let insertion: String }
protocol CompletionSource { func items(matching query: String) -> [CompletionItem]; var emptyMessage: String { get } }
// Coordinator: openCompletion(source:, triggerRange: NSRange)  /  closeCompletion()  /  isCompletionOpen
```

**Contract:**
- [ ] **The view.**
  - A plain `NSView` list, at most 8 rows visible, scrolling inside.
  - It is added to the scroll view and positioned under the caret from `firstRect(forCharacterRange:)` (flipped above it near the bottom edge).
  - It is VoiceOver-labelled: an accessibility role of list and rows with their titles.
  - It closes on scroll, window resize, focus loss, selection moving out of the trigger range, an `applyExternalText`, posture becoming read-only, and Esc.
- [ ] **Key routing first in `doCommandBy`, before the table arms.** While the list is open:
  - ↑ and ↓ move;
  - Return and Tab accept;
  - Esc (`cancelOperation:`) closes.
  - Also swallow `complete:` always in prose, so AppKit's completion window can never open.
  - When the list is closed, everything behaves as today.
- [ ] **The trigger.**
  - Record the single character the writer typed in `shouldChangeTextIn`: a typing replacement of length 1, not undo or redo, not inside `applyCommandEdit`, and no marked text.
  - In `textDidChange`, after the retokenize, ask the registered sources whether the text before the caret opens one (Tasks 3 and 4 register).
  - Never trigger inside a code span (check the tokens), in a non-manuscript surface (`answersInsertCommands`), or while `hasMarkedText`.
- [ ] **Accept.** Replace the trigger range through the query with `insertion`, via `applyCommandEdit(.immediate)`. That is one undo step: typing `[@smi` then accepting gives `[@smith2026]` and the typed characters stay their own undo steps.
- [ ] **Tests:**
  - Pure, for each of: positioning maths; key routing with the list open and closed, including in a table cell; `complete:` swallowed; no trigger in code or a research note; close paths; one undo step on accept.
  - A mounted test drives `doCommand(by:)` and `insertText` directly, with no synthesised keys beyond the allow-lists.
- [ ] **Commit:** run `./gen.sh` and `./scripts/test.sh`, then commit with the message `editor: an in-editor completion list`.

### Task 3: The citation picker

**Files:** create `Maugham/Editor/CitationCompletion.swift`; modify `MaughamApp.swift` (Insert ▸ Citation…), `MaughamNotifications.swift`, `KeyboardShortcuts.swift` and `docs/guide/reference.md`. Tests are new.

**Contract:**
- [ ] **Source and trigger.** A `CompletionSource` over `ReferenceIndex.sources` (R-3b-6). The trigger is R-3b-5:
  - `[@` opens it;
  - `;` inside an open bracket reopens it.

  Accepting inserts the key and leaves the caret before `]` if the bracket is already closed. Otherwise it inserts `key]`.
- [ ] **Insert ▸ Citation… (⌘⇧C).** Verify the shortcut is free and add it to the census. It inserts `[@` at the caret through `applyCommandEdit` and opens the picker. It follows `InsertMenuGate`.
- [ ] **Filter.** Match key, author and title prefixes, case- and diacritic-insensitive. The empty state shows R-3b-6's message.
- [ ] **Tests:**
  - The trigger and its non-triggers: an email, `@sarah`, backticks.
  - The `;` continuation.
  - Insertion shapes.
  - The filter.
  - The menu command.
  - The empty state.
- [ ] **Commit:** run `./scripts/test.sh` and commit with the message `editor: a citation picker`.

### Task 4: The cross-reference picker

**Files:** create `Maugham/Editor/CrossReferenceCompletion.swift`; modify the same menu, event and census files as Task 3. Tests are new.

**Contract:**
- [ ] **Source and trigger.** A `CompletionSource` over `ReferenceIndex.targets`. The trigger is R-3b-5: `@` plus a letter, at a word start. The query is everything after `@` (`fi` matches `fig:` labels as well as captions). Accepting inserts `@fig:name`.
- [ ] **Insert ▸ Cross-Reference… (⌘⇧X).** Verify the shortcut is free. It inserts `@` and opens the picker with every target listed.
- [ ] **Tests:**
  - Never after an email-like character.
  - Publishing order.
  - Captions and titles shown.
  - Labels across documents.
  - The menu command.
- [ ] **Commit:** run `./scripts/test.sh` and commit with the message `editor: a cross-reference picker`.

### Task 5: The grid editor

**Files:**
- Core: `TableText.swift` (fixes) and a new `TableClipboard.swift` (tab-separated parse).
- Mac: a new `Maugham/Views/TableGridEditor.swift` (SwiftUI sheet), `EditorHost` (present and await), `EditorCoordinator+Tables.swift` (Edit Table…, double-click), `EditorSurface.swift` (`mouseDown` double-click on a delimiter row), and the menu, event and census files.
- Tests: Core and Mac.

**Interfaces (produced):**
```swift
public enum TableClipboard { public static func rows(fromTabSeparated text: String) -> [[String]] }   // quotes, embedded tabs/newlines per Excel's TSV
// Coordinator: var tableEditor: ((TableText) async -> TableText?)?   — set by EditorHost; nil = cancelled
```

**Contract:**
- [ ] **Core fixes.**
  - `formatted()` writes the caption line when there is a label but no caption (`Table: {#tbl:x}`).
  - A newline inside a cell becomes a space.
  - Pin both round trips.
  - `TableClipboard` handles Excel's quoting.
  - Run `./scripts/test.sh core` and `phone`.
- [ ] **Edit Table… (⌘⌥⇧T, verify it is free)** and a double-click on the table's delimiter row (R-3b-3) open the sheet on the caret's table.
  - Pin the double-click route with a source census, as plan 3a's checkbox-click census is pinned (tripwire 33), not with a synthesised click.
  - Outside a table the command does nothing.
- [ ] **The sheet** is a SwiftUI `Grid` of text fields with:
  - add and remove row and column;
  - move a row or column up, down, left or right (buttons; drag is optional);
  - per-column alignment;
  - header row editing;
  - caption and label fields (label validated by `ManuscriptLabel.isValidName`, unique against the index);
  - Paste Cells, which fills from the selected cell using `TableClipboard`.

  Cancel and Save are `.cancelAction` and `.defaultAction`.
- [ ] **Save.**
  - Re-find the table by an anchor shifted through edits, as plan 3a's figure anchor tracker does.
  - If the table's text changed since the sheet opened, refuse with the sentence "The table changed while you were editing it" and write nothing.
  - Otherwise make one `applyCommandEdit(.immediate)` with `formatted()`.
- [ ] **Tests:**
  - Core: the clipboard cases (quotes, embedded tab or newline, ragged rows) and the round trips.
  - Mac: the grid model's pure operations (a view model behind the sheet); save as one undo step; refused on change; a read-only posture blocks Save; the double-click census with a planted offender.
- [ ] **Commit:** run `./gen.sh`, `./scripts/test.sh`, and a Release build if `ProjectWindow.body` changed. Commit with the message `editor: a grid editor for tables`.

### Task 6: Labels beside markers, and problem underlines

**Files:** create `Maugham/Editor/ReferenceLabelOverlay.swift` and `Maugham/Editor/ManuscriptChecks.swift` (pure per-document checks); modify `EditorCoordinator+Typography.swift` (a settle hook for underlines) and the install code. Tests are new.

**Contract:**
- [ ] **Labels (R-3b-1).**
  - An overlay modelled on `FigureThumbnailOverlay` draws, for each visible citation, cross-reference and footnote-reference token, the resolved text from `ReferenceIndex`:
    - citation: `inText`;
    - cross-reference: `Target.text`;
    - footnote: its number in this document's order.
  - The label is drawn beneath the token's end in the line gap when it fits; otherwise only on caret-in or hover, as a tag above the line.
  - It honours focus dim.
  - It repaints on text change, scroll and index version, never by restyling.
  - Its layering is below the completion list and above thumbnails.
  - Manuscripts only.
- [ ] **Checks (R-3b-4).**
  - `ManuscriptChecks.problems(in tokens:, text:, index:) -> [(range: NSRange, kind: PublishProblem.Kind)]` covers: unknown key, unresolved cross-reference, a label defined here and also elsewhere (duplicate), and missing, duplicate or unused footnote definitions in this document. It reuses `PublishProblem.Kind`, and its words, so the editor and the publish desk say the same thing.
  - It runs on the settle edge, never per keystroke.
  - It paints with layout-manager temporaries `.underlineStyle` (dotted pattern) and `.underlineColor`. It never touches `.foregroundColor` temporaries.
  - It clears its own temporaries first.
  - Tooltips use `addToolTip(_:owner:userData:)` rects, rebuilt with the underlines.
- [ ] **Tests:**
  - Label placement maths (pure).
  - The fit and no-fit rule.
  - The checks: each kind, plus negatives (email, code span, a research note gets none).
  - Underline temporaries don't disturb translation dimming, as a coexistence test.
  - The settle hook is not per keystroke (a counter).
  - Severity colours follow the profile.
- [ ] **Commit:** run `./gen.sh` and `./scripts/test.sh`, then commit with the message `editor: resolved labels beside markers, and problem underlines`.

### Task 7: Docs and the full gate

- [ ] **Editor AREA guide:**
  - Map rows for the new files.
  - Rules:
    - picker keys first in `doCommandBy`;
    - no `NSPopover`;
    - the index is the only project data the editor reads;
    - labels and underlines are display-only and never paint inputs;
    - the grid save is refused when the table changed.
  - Keep it at its ceiling by moving narrative to `docs/history/editor.md`.
- [ ] **Views AREA guide:** the grid sheet and the index host. It is at its hard cap, so move older reason clauses to `docs/history/views.md` as earlier tasks did.
- [ ] **User guide:**
  - the pickers;
  - the labels, including where they draw and why;
  - the problem underlines;
  - the grid editor and pasting from spreadsheets;
  - the note that editor numbers follow the whole book and an edition may differ.

  Describe only what ships. Update the keyboard reference.
- [ ] **DocBudget ceilings** at the actual `wc -w`, with reasons. No milestone tags.
- [ ] **Full gates:** `full`, `core` and `phone`. Then commit with the message `docs: guides and user guide for pickers, labels, the grid and editor checks`.

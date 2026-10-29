# Report plan 8b — drags, Use in document, Research tables in the grid, and legacy research figures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** finish the Figures area. Research items become figures by drag or menu, and figures go back to Research by drag (confirmed once). A new Insert ▸ Existing Figure… places any figure's line at the caret. A Research CSV opens in the same grid and saves back to its file. Old figure lines that point into `research/` show in the Figures section with "Move into Figures", and a snapshot whose Research source changed says so. Plan 8 is then complete.

**Architecture:**
- **Use in document makes an unused figure; placing is the editor's job.** Every route in (drag onto Figures, a Research row's menu, the Research inspector, "Move into Figures") calls `useInDocument` with a label-safe name. The figure appears as "—" in the Figures section, and Insert ▸ Existing Figure… puts its line at the caret through route A (one ⌘Z). Denver's ruling, 2026-10-29.
- **The grid gets a host seam.** `FigureGridController` talks to a `FigureGridHost` protocol. `FigureDocument` conforms unchanged; a new `ResearchTableHost` keeps a table in memory, registers its own undo, and saves the CSV (and its sidecar, with the new hash) through the coordinated file save.
- **Legacy lines are listing rows without records.** The window-level index already carries their paths; the listing grows a legacy row kind, and "Move into Figures" retargets the line through the closed-piece writer.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit, MaughamCore, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §4.1, §4.2 (coming back), §4.3 last bullet, §4.4, §7 (Drag, Research tables). Plan 8a (built, pushed bf9a36f9): `docs/superpowers/plans/2026-10-28-report-plan8a-figures-section-centre-inspector.md`. Survey of the built code: `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan8b-survey.md` (re-verify each line number).

## Global Constraints

- **Denver's rulings:**
  - **D8b-1 (2026-10-29) placement:** Use in document from anywhere outside the editor makes the figure unused ("—"). Insert ▸ Existing Figure… is the one way to place a line from Research or the Figures section: a picker listing every figure (unused first), inserting at the caret.
  - **D8-2 (2026-10-28):** dropping a figure on Research confirms once ("Send Table 3 to Research? Its line leaves the text. This can't be undone."). Dragging a Research item to Figures needs no confirmation.
  - **D8-3 (2026-10-28):** Research CSVs edit in the grid in plan 8, with undo while the grid is open; the guide says saved changes are not versioned until plan 9.
- **Spec intent, verbatim where it binds:** Research item → Figures = Use in document; Figure → Research = Send to Research; dragging within the Figures list does not renumber. Research tables open in the same grid editor in the centre; "editing saves to the file, with formulas as `=` cells. There is no op log for Research." Legacy figures appear tagged "in Research" with a "Move into Figures" action; nothing moves automatically. Snapshots from Research show the same "changed" note when their source item changes.
- **Names:** a figure made from Research takes a label-safe name (`ManuscriptLabel.isValidName`), derived through `FigureIngest.figureName` and de-duplicated, so its line's `{#tbl:…}`/`{#fig:…}` label equals the record name (send, rename and relabel depend on it). "Move into Figures" keeps the line's existing label name when it is label-safe and free.
- **Research CSV writes:** only on an actual edit, never on open; keep the file's separator (comma, semicolon, tab) and write UTF-8; rewrite the sidecar with the new content hash in the same save, keeping `figureId`, `name` and `caption`; call `documentStore.invalidateFigureCards()` after the write lands so pins flip to "changed".
- **Hard invariants / tripwires:** writes through the typed mover / coordinated file save (14, 58); text edits in closed pieces only through `holdManuscriptsForFigureText` / `openManuscriptForWriting` (posture, 52 — classify every new writer call site in the census, never dodge); posture through the one door (47, 51) — `FigureActions.mayEdit` / `windowRefusesWrites`; no new `EditorHost` state (6); tree rows from cached values (4), Button/tag rule (9); drop-modifier order and provider-route censuses (#109) stay green; Core stays platform-free (19 — the snapshot flag is Core); no press-then-wait tests (33).
- **Tests:** real delivery paths; `TestWindow`/`TestTemp`; `./gen.sh` after adding files; `ProjectWindow.body` changes via a modifier + local Release build.
- **Docs:** `Maugham/Views/AREA.md` is at 7,995/8,000 — the first task that adds a Views file trims it first (rationale into `docs/history/views.md`); new prose prefers `Maugham/Editor/AREA.md`. DocBudget ceilings numbers only. Help describes only what ships.

## Review Focus

1. **A Research table titled "Q3 revenue (draft)" dragged onto Figures, then placed, renamed, sent back, and brought back:** the name is label-safe, the line's label matches it at every step, the line leaves on send and the figure returns unused on bring-back. Tasks 1, 3, 4.
2. **Edit a Research CSV that a figure pins (`research:model!B9`), close the grid:** the file and sidecar are rewritten once, the pinning figure's card and tree tag say "changed" without any other edit, Compare shows old and new. A semicolon CSV stays semicolon. Tasks 6, 7.
3. **Drop a figure on Research while it is open in the centre grid, then answer Cancel; then drop again and confirm:** Cancel changes nothing and the grid stays; Confirm folds the grid, sends, and the subject repairs; a refused send leaves the centre showing the figure. Tasks 2, 5.
4. **Move into Figures on a legacy line in a closed chapter on a read-only share:** refused with the share's reason, nothing created. With write rights: the figure is created and the line retargeted in one action; if the line write is refused, the figure exists unused and the writer is told. Task 8.
5. **Insert ▸ Existing Figure… for a figure already placed elsewhere:** the picker marks it used ("Table 2 · Chapter 1"); inserting places a second line (allowed — one figure, two uses), numbered once. In a screenplay the command is absent. Task 3.

---

### Task 1: Store foundations — label-safe names, the line writers, the snapshot flag
**Files:** `Maugham/Stores/ProjectStore+FigureResearch.swift` (`useInDocument` and `bringBack` take `name: String?`; when nil they derive a label-safe, de-duplicated name via `FigureIngest.figureName`/`vacantFigureName` for tables as images already do), `Maugham/Stores/ProjectStore+Search.swift` (`FigureTextChange` gains `.insertLine(piece:at:line:)` and `.retargetLine(piece:lineIndex:oldPath:newPath:)`; a `holdManuscriptsForFigureText` variant that targets one chosen piece; census rows if a new call site appears), Core `Table/FigureCardModel.swift` + `Stores/DocumentStore+Figures.swift` `figureCardInputs()` (a snapshot whose `source` item's file hash differs from `source.contentHash`, or whose source is gone, is "changed"; hashed off the main actor in the fill; image figures carry the flag too).
- [ ] Failing tests: a title with spaces/parentheses → a valid label name; a collision → `-2`; insert/retarget edits in an open and a closed piece (posture refused → nothing written); a snapshot source edit flips `changed`, an untouched one doesn't, a deleted source flips it; `./scripts/test.sh core` for the Core part.
- [ ] Gates; commit.

### Task 2: The residual — a refused send from inside the centre grid
**Files:** `Maugham/Editor/FigureCentreGrid.swift` (`take()` passes `close: { leaveForASend() }`), `Maugham/Editor/FigureGridController.swift` (`onSendRefused` fired from the send's catch), `Maugham/Editor/FigureWindow.swift` (`mount` wires it to `windows.sendRefused(figureId)`). A figure window's refused send closes the window today: keep that, say it in the report.
- [ ] Failing test: the grid's own Send to Research, store refusing → the centre shows the figure again with the refusal said; a successful send repairs the subject (existing).
- [ ] Gates; commit.

### Task 3: Insert ▸ Existing Figure…
**Files:** `Maugham/MaughamApp.swift` `InsertMenuButtons` (new item, prose manuscripts only — `answersInsertCommands`), a picker (new `Maugham/Editor/ExistingFigurePicker.swift`: every non-parked figure from the window's `FigureListing`, unused first then reading order, each row "— Q3 revenue (unused)" / "Table 2 · Cash flows · Chapter 1"; type-to-filter), `EditorCoordinator+Insert.swift` (insert the line at the caret through route A with `separatingFigureLines`, one ⌘Z, using `FigureIngest.figureLine` and `relativePath`; the line's label is the record name), KeyboardShortcuts/reference.md if it gets a shortcut (none required).
- [ ] Failing tests: the menu item on the real menu path inserts at the caret and one ⌘Z removes it; the picker's order and labels; absent in a screenplay and in a read-only/Review editor; a placed figure's number appears in the tree after the settle.
- [ ] Gates; commit.

### Task 4: Use in document and bring back, from Research
**Files:** Research row context menu (`ResearchRow`/tree verbs: "Use in Document" for table/image/pdf items; for a parked figure's working copy the same item reads "Bring Back to Figures"), `Maugham/Views/InspectorResearchPanel.swift` (the same action as a button), a shared helper beside `FigureActions` (e.g. `FigureActions.useInDocument(researchItemId:)`) that calls the store, reveals the new figure in the Figures section (`revealFigure`) and reports refusals through the tree alert; census rows for each new `useInDocument(`/`bringBack(` call site.
**Contract:** the figure's home piece is the piece whose Research holds the item (piece-scoped Research), else nil (unused, home decided at placement by the existing rule — verify what `piece: nil` means in the store and say so); CSV problems from the read (`problems`, `overwritten`) are said once.
- [ ] Failing tests: menu and inspector both create an unused figure and reveal it; bring-back of an unchanged parked copy restores its history; a non-figure kind has no item; posture refusal is said.
- [ ] Gates; commit.

### Task 5: The drags
**Files:** `Maugham/Views/TreeDropIntent.swift` (`classify` gains a `figures:` lookup; `Target.figuresSection`, `.figureRow(String)`; `Intent.useInDocument(researchId:)`, `.sendFigureToResearch(figureId:scope:group:)`; new `Reason`s — not a figure kind, already in Figures, within-Figures no renumber), `Maugham/Views/BinderTreeDrops.swift` (perform: Use in document through Task 4's helper; Send through `FigureActions.sendToResearch` after the confirmation), the Figures header and figure rows' `.dropDestination(for: String.self)` mounted from `FigureSection.swift`/`FigureRow.swift` (string-only; keep the #109 and provider-route censuses green), the confirmation alert (D8-2) beside `pendingError` (`state.pendingFigureSend`), the group-row case (send to the scope root, then `moveResearchItems` into the group; if the move fails the item stays at the root and the writer is told).
- [ ] Failing tests: the classifier grid extended for every target × figure id / research id; drop Research table → Figures header creates an unused figure; drop figure → Research header asks, Cancel changes nothing, Confirm sends and the subject repairs; drop figure → piece fold/row uses that piece's Research; a figure dropped within Figures is refused; posture-refused writer sees no confirmation and a reason.
- [ ] Gates; commit.

### Task 6: The grid's host seam
**Files:** new `Maugham/Editor/FigureGridHost.swift` (protocol: `figureId`, observable `state`, `projectURL`, `isClosed`, `awaitPendingUndoWork`, the mutators the controller calls, `refreshPins`; capability flags the controller asks before offering figure-only commands: rename, send, pins, caption, name field), `FigureDocument` conformance (no behaviour change), `FigureGridController` typed against the protocol. Census spellings in `TripwireGrepTests` (`manuscriptWriterCallSites` keys the controller's calls by spelling) stay identical.
**Contract:** pure refactor — every existing figure-grid test passes unchanged; the disable experiment is "make `FigureDocument` the only conformer and delete the protocol use" → compile.
- [ ] Gates (full); commit.

### Task 7: Research tables in the grid
**Files:** new `Maugham/Editor/ResearchTableHost.swift` (conforms to `FigureGridHost`: reads the CSV through the store's decoder and `TableCSV.read`, applies the sidecar when its hash matches, applies edits with Core's table mutators, registers undo on the grid's own stack, debounced save through `DocumentStore.scheduleFileSave`/`performFileSave` writing `TableCSV.renderResearch` with the file's own separator, then the sidecar with the new hash, then `invalidateFigureCards()`; flush on leaving the subject, on window close and on ⌘Q), `ProjectWindow.researchCentreRoute` (`.table(item:path:)` for `.table` items; `ResearchSubjectCentre` and `ResearchSubjectInspector.preview(of:)` follow; the routing census updated), the grid mounted in the Research centre with figure-only commands hidden (no rename, send, pins, caption, ⤢), read-only when `!persona.editsResearchInTheCentre` or the share is view-only, `ResearchPreview`'s "until the Research grid exists" comment retired. No `FigureWindows` hold (Research tables are not figures).
- [ ] Failing tests: open writes nothing; an edit saves once after the debounce with the separator kept and formulas as `=` cells; the sidecar's hash follows; a pinning figure flips to "changed"; undo in the grid, flush on leaving; a file that can't be read shows the read error, never an empty grid (RULING-7 precedent); Review and view-only are read-only.
- [ ] Gates; commit.

### Task 8: Legacy research figures and "Move into Figures"
**Files:** `Maugham/Editor/FigureListing.swift` (a `LegacyRow` for each `.outsideFigures` line: piece, line index, path, caption, the Research item it resolves to if any; a pure helper matching the line's standardised target to `ResearchItem.path`), the Figures section and `FigureRow` (legacy rows tagged "in Research", selectable as nothing new — their row's menu offers "Move into Figures" and "Show in Text"; the section shows when legacy rows exist even with no records), `FigureActions.moveIntoFigures(_:)` (Task 1's `useInDocument(name:)` with the line's label name, then `.retargetLine` on that piece; the second step's refusal leaves the figure unused and says so), the inspector is not needed for legacy rows.
- [ ] Failing tests: a legacy line lists with its tag; Move into Figures creates the figure and retargets the line in a closed piece; posture refusal creates nothing; a path matching no Research item offers no Move (says "The file isn't in Research"); the line now resolves to the figure and numbers.
- [ ] Gates; commit.

### Task 9: Docs and the guide
**Files:** `Maugham/Views/AREA.md` (trim first if not already; rules for the drags, legacy rows), `Maugham/Editor/AREA.md` (host seam, ResearchTableHost, Insert ▸ Existing Figure), `docs/guide/research.md` (Use in Document, Bring Back, editing a Research table — "saved changes aren't versioned yet"), `docs/guide/structure-and-binder.md` (the drags and the confirmation, legacy rows and Move into Figures), `docs/guide/editor-and-focus.md` (Insert ▸ Existing Figure…), `docs/tripwires.md` if a census grew (report any CLAUDE.md row needed — do not edit CLAUDE.md), DocBudget numbers only.
- [ ] Edit; gates; commit.

## After the last task
- Whole-branch review. Seams: Task 5's confirmation × Task 2's refusal × the centre grid; Task 7's file save × pins (Task 1's flag) × bring-back's sidecar hash rule (a grid-edited working copy comes back without its sidecar formats — accept or fix, and say which); Task 3's insert × the listing's numbering and the tree's unused tag; Task 8's retarget × the editor open on that piece.
- `./scripts/test.sh full`, `./scripts/test.sh phone`, local Release build.
- Plan 8 complete: report to Denver with the smoke list for 8a and 8b.

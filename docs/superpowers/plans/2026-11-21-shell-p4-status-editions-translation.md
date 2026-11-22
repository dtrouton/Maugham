# Status, Editions and Translation (shell plan 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The window answers "what needs me?" at every altitude: the tree marks the rows that have something to resolve; the Book's Status and each edition's Status lay the pieces out; an edition is a subject with its own two faces, so the Department desk goes; a piece can be read in a language with its source under each paragraph, and its To resolve is that language's questions and changes, headed by that round's letter; every piece keeps its latest letter per language and per pass. With these, the two interim homes of plan 3 close and To resolve's list is reachable everywhere.

**Architecture:** Storage first (the per-piece round letters), then per-piece aggregates read without loading (one window leaf, one value the rows look up), then the centre's views (the Book's Status widened, the edition's Book and Status, a toolbar view switch), then the edition and the piece-in-a-language as To resolve scopes with new item kinds, then the deletions (the desk, translation review), then the fold's carries and the test-host builders. Pure functions decide scope, items, presence and status rows; views take values.

**Tech Stack:** Swift, SwiftUI, AppKit, PDFKit/Core Graphics (named destinations). No new dependency. MaughamCore unchanged.

**Spec:** `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md` ("The tree", "The centre, by subject", "To resolve", "The toolbar", "Translation", "Project types", "Where today's surfaces go"). Built on ADRs 0035, 0036, 0037. Every signature below was read at `a7981ae7`; a name marked **new** is created by the task that lists it under Produces.

## How this plan is cut

Plan 4 of 5 on `claude/shell-without-personas`. Twelve tasks, so it is split in this file:

- **4a — Status and the edition (Tasks 1–6).** The builders first (every later mounted test uses them), then storage, aggregates, the two Status views and the edition as a To resolve scope. After Task 6 the desk is no longer mounted.
- **4b — Translation and the carries (Tasks 7–12).** The desk's last verbs and its deletion, the piece in a language (two tasks: the editor surface, then its To resolve), the fold's carries, the two pre-existing defects and the flakes, then the record.

The cut falls where the edition's faces exist and the desk is unmounted but not yet deleted: 4b's first task deletes a view nothing mounts, so no task builds anything to be replaced. One branch; nothing is pushed, merged or tagged by any task; the branch merges only when all five plans are whole. No test-data migrations (tripwire 11).

**Plan 5, not here:** the margin setting and the ADR 0027 §1 amendment; the guide, tour, help and cheat sheet; the whole-menu review (it will revisit the ⌘⌥ map this plan touches, File ▸ Add Language…, View ▸ "To Resolve: Questions" and the dynamic "To Resolve: <Language> Edition"; ⌘⌥L's silence where a scope has no questions; and the tree's ⌘↓ "Open in Centre" (Task 10), which has no menu item yet).

**Merge gate (Task 7 review M7):** the bundled in-app Help still describes the deleted Department desk (about 49 mentions across `docs/guide/publish-department.md`, `publishing.md`, `translation-review.md`, `right-pane.md`, `review-passes.md`, `sense-pass.md`; also `docs/roadmap.md`). The branch does not merge until plan 5 rewrites them (workflow rule 7).

## Global Constraints

- The hard invariants in `CLAUDE.md` stand. **No second manuscript `Document`.** Every new reader (presence, Status rows, the edition's items, the Scenes fold) reads store-level sources: `ProjectStore.listAnnotationsAcrossProject()`, `.listTasksAcrossProject(filter:)` (`ProjectStore+Tasks.swift:223`), `DiagnosticsStore.live(docId:currentText:)` (`DiagnosticsStore.swift:542`), `currentParagraphState(documentId:store:documentStore:projectURL:)` (`MCP/Tools/TranslationTools.swift:28`, open document else derived), `TranslationStore`, `TranslationRoundStore`, `EditionStatus`. `ResolveReaderTests.test_noResolveSourceLoadsADocument` is extended to each new reader file.
- **Read anywhere, act on the open piece** (plan 2's rule) holds for every new item kind that writes a manuscript `Document`. A translation write, a design verb and a glossary adoption are not manuscript writes and act wherever they are listed, asked of their existing posture (`TranslationAuthorVerbs.decide`, `DesignGateVerbs`).
- `EditorHost` gains no state (tripwire 6); `EditorSurface.applyExternalText` keeps one call site (tripwire 7). The translated surface stays one-way threaded state, derived in `recomputeTranslatedSurface` (`EditorHost.swift:1108`).
- No uncached per-row work (tripwire 4): presence, Status rows and the Scenes fold are computed once per key in a `.task`, and rows do a dictionary or set lookup.
- `List(.sidebar)` rows select by tag or act by `Button(.plain)`, never `.onTapGesture` (tripwire 9).
- Hide, don't disable; ask `Posture` (tripwires 47, 51). Notifications through `MaughamEvent` with a scope (tripwire 21). A synced path reaches disk through `SafeRelativePath` (tripwire 58).
- Tests are pure functions, censuses or mounted measurements read synchronously; **never press a control and wait for its effect** (tripwire 33). A mounted test builds its view through the one builder Task 1 makes for that host.
- **A deleted view's tests are retired or re-made, never dropped wholesale**: every assertion that polices behaviour that still ships moves onto the live code first, and the task report maps each old suite.
- `DocBudgetTests` word ceilings (`Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`): `Maugham/Views/AREA.md` is at 7,980 of 7,985, `Maugham/Compiler/AREA.md` 7,946 of 7,951, `Maugham/Stores/AREA.md` near 7,992. Every addition is paid for by a cut; the desk's and translation review's entries are the cuts. Never raise a ceiling.
- Read before editing: the area guide each path's row in `CLAUDE.md` names; for Tasks 6, 8 and 9 also the translation register filings under `register/` and RULING-54.
- **Every implementer, every task:** run `./scripts/test.sh` **in the foreground** with a 600000 ms timeout, never in the background and never raw `xcodebuild test`; run `./gen.sh` after adding or deleting any file; commit before reporting.
- Every commit message ends with exactly these two lines:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

## Review Focus

1. **A whole-book translation run, then a second run on one chapter.** The first run's letter for every other chapter is still reachable (Task 2); the edition's Status shows each chapter's own latest round (Task 5); the chapter's To resolve heads with its own newest letter (Task 9).
2. **The tree after a check and a round across a 30-chapter book with most chapters closed.** The dot is on exactly the chapters with open notes, to-dos or live strains, refreshes on a peer's sync, and costs one read per key, never one per row (Task 3).
3. **An edition with a piece faced.** The centre scrolls the typeset book to that piece; To resolve lists that piece's questions in that language, never the source's; Brief stays the piece's (Tasks 5, 6).
4. **A piece switched to a language and then edited elsewhere.** The read-only surface refreshes, the source lines under each paragraph never become editable, the caret maps to the right paragraph with source lines interleaved, and `applyExternalText` is called once per swap (Task 8).
5. **A failed promotion.** The Collection window keeps a live `DocumentStore` (presenter installed, registry open) after both a refusal and a success (Task 11).

---

## Plan 4a — Status and the edition

### Task 1: One builder per view host, and the census that keeps tests on it

The whole-branch review's C1 was a dead feature hidden by tests that built `PulledUpView` without the argument production always passes. This closes the class.

**Files:**
- Modify: `MaughamTests/TestSupport/RightColumnFixture.swift` (every argument `ProjectWindow.detailColumn` passes, `ProjectWindow.swift:1857`: `pulledUpMemory`, `figureTree`, `paletteWallCard`, `briefFocus`, `drawsFigure`, `revealFigure`, `pullUp` through `ProjectWindow.pullUp(_:subject:showInspector:position:memory:)` with a real `PulledUpMemory`).
- Create: `MaughamTests/TestSupport/ViewHostFixtures.swift` — **new** `PulledUpFixture.view(...)`, `RightColumnControlFixture.control(...)`, `TreeHostFixture.binder(...)`, `.collection(...)`, `.scenes(...)`, `.fold(...)`. Each passes exactly the arguments and environment values its one production site passes: `RightColumn.swift:412` (`PulledUpView`, including `canvasDetails`), `RightColumn.swift:253` (`RightColumnControl`, including `closedCanvasWrites` and `canvasModel`), `BinderPaneToggle.swift:107` (`BinderView(store:subject:treeState:canvasKeyboard:)`), `CollectionBinderPaneToggle.swift:83`, `BinderPaneToggle.swift:114` (`SceneNavigatorPane`), `BinderView.swift:257` / `CollectionPiecesPane.swift:252` (`BinderPieceFold`), with `.environment(\.windowCanvas, …)` as `ProjectWindow.swift:231` sets it and `\.rowThumbnailRoot` as the hosts set it.
- Create: `MaughamTests/HostBuilderCensusTests.swift`.
- Modify: every suite that builds one of these hosts by hand (found by grep at HEAD: `PulledUpViewTests`, `PulledUpDeliveryPathTests`, `RightColumnMountingTests`, `RightColumnPaneWidthTests`, `ReviewRoundCockpitTests`, `DetailColumnWidthTests`, `BinderPieceFoldTests`, `BinderTreeDropRoutingTests`, `ResearchNewTableTests`, and the fourteen `BinderView(` / eleven `CollectionPiecesPane(` / six `SceneNavigatorPane(` suites).

**Consumes:** the production call sites above; `TestWindow.make`/`.mount` (the one window builder).

**Produces:** the fixtures above. Defaults are allowed only for values production itself varies (a subject, a width, a store); an argument production always passes has no default in the fixture.

**Contract:**
- `HostBuilderCensusTests.test_noTestBuildsAViewHostByHand`: outside `TestSupport/`, no test source contains `RightColumn(`, `PulledUpView(`, `RightColumnControl(`, `BinderView(`, `CollectionPiecesPane(`, `SceneNavigatorPane(` or `BinderPieceFold(` in code (string literals in source-scanning censuses such as `WiringCensusTests` are on a named allow-list, each with its reason).
- `test_eachFixturePassesWhatProductionPasses`: for each host, the set of argument labels at the one production call site equals the set at its fixture's call site, and the set of `.environment(\.` keys applied around it matches. A new production argument fails this until the fixture passes it.
- `DetailColumnWidthTests` mounts its own split view by design; if it must keep a hand-built `RightColumn`, it goes on the allow-list with its reason, as tripwire 33's lists do.
- A planted offender (a temp file string containing `PulledUpView(`) and a control (the fixture file) prove the census reads.

- [ ] **Step 1:** Write the census and both parity tests; run them; expected red (today's hand builds and missing arguments).
- [ ] **Step 2:** Build the fixtures; move each suite onto them. Where a suite's assertion changes outcome under production's arguments (the review's list: Back appears, a canvas selection no longer covers without `canvasSelectionIsNewer`), keep the assertion's intent and say in the report what moved.
- [ ] **Step 3: Disable experiment.** Delete `canvasDetails:` from `PulledUpFixture.view`; `test_eachFixturePassesWhatProductionPasses` and `PulledUpDeliveryPathTests.test_theCentresDetailsStandAboveAPulledUpNoteAsTheColumnBuildsIt` go red. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground, 600000 ms). Commit `shell p4 task 1: one builder per view host, and a census that keeps tests on it`.

**Tripwires:** 33 (no new waits; the moved suites keep their allow-list entries or lose them), `WiringCensusTests` (source-scan strings allow-listed, not rewritten).
**Hand check:** none (test-only).

---

### Task 2: Round letters per piece

**Seat.** Before: after a whole-book run into Serbian, the desk shows the newest round only, and the store's ring of ten per language has dropped most chapters' letters. A second editor's round on a chapter files the first editor's round into a ring that keeps no letter. After: every chapter's latest finished round in each language, and each editor's latest round on each chapter, letter included, is kept and readable.

**Files:**
- Modify: `Maugham/Stores/TranslationRoundStore.swift`, `Maugham/Compiler/DiagnosticsStore.swift`, `Maugham/MCP/Tools/TranslationTools.swift` (`translation_status` reads each document's round through the new reader; description updated), `Maugham/Stores/AREA.md`, `Maugham/Compiler/AREA.md` (the round-ring lines, rewritten not appended).
- Test: `MaughamTests/TranslationRoundStoreTests.swift` (add), `MaughamTests/Compiler/DiagnosticsStoreRoundTests.swift` (add or create beside the existing sidecar tests).

**Consumes:** `TranslationRoundStore.append(_:) throws` (`:61`; called once per finished round from `TranslationPipelineEnvironment+Project.swift:73`), `.update(_:) throws` (`:83`; `TranslationRoundActions.swift:230`), `.latest(language:docId:)` (`:51`), `Ledger { nextNumber, rounds }`, `ringSize = 10`; `DiagnosticsStore.replace(run:diagnostics:docId:)` (`:379`), `FileContent { check, round, clauseHistory, rounds }`, `roundHistoryDepth = 5` (`:668`), `standingRound(docId:)` (`:696`).

**Produces:**
```swift
// TranslationRoundStore
struct Ledger: Codable { var nextNumber: Int; var rounds: [TranslationRound]
                         var latestByPiece: [String: TranslationRound] }   // new field, decodeIfPresent ?? [:]
func latestFinished(language: String, docId: String) -> TranslationRound?  // new
func latestFinishedByPiece(language: String) -> [String: TranslationRound] // new
func trend(language: String, docId: String) -> [Int]                       // new: noteCount of that piece's rounds in the ring, oldest first
// DiagnosticsStore
func latestRounds(docId: String) -> [CompilerRun]   // new: the standing round, then each other pass's latest finished round, newest first
```

**Contract:**
- A round is "finished" when `endedAt != nil` and it was not cancelled (`wasCancelled == false`). `append` of a finished round writes it to `latestByPiece[round.docId]` as well as the ring; a cancelled one goes only to the ring. `update` writes through to both places it is found, and finds a round in `latestByPiece` after it has aged out of the ring (so a verb on an old chapter's report never says `roundGone` while the chapter's latest round is that round).
- The diagnostics sidecar keeps, per document, the latest round per pass (`FileContent.latestRoundByPass: [String: CompilerRun]`, decodeIfPresent): `replace` files the superseded round there under its `passId` before the ring takes its `RoundRecord`. A round with no `passId` is not kept there. The check slot and the delta marker are untouched (`Compiler/AREA.md` "a round neither reads nor moves" the marker).
- No new file, no new sync surface: both stores stay where they are (`.maugham/translations/rounds/`, the per-device diagnostics sidecar). Old files read with an empty map.
- `translation_status` reports each document's `latestFinished`, so its per-document round is no longer "newest in the ring for any chapter".

- [ ] **Step 1: Failing tests.** `test_aWholeBookRunKeepsEveryChaptersLatestRound` (append 12 rounds over 12 docs, ring 10; every doc's `latestFinished` answers), `test_aCancelledRoundIsNotTheLatestFinished`, `test_updateFindsARoundThatAgedOutOfTheRing`, `test_anOldLedgerReadsWithNoLatestRounds`, `test_trendIsThePiecesOwn`; `test_aSecondPassesRoundKeepsTheFirstPassesLetter`, `test_aRoundWithNoPassIsNotKeptByPass`, `test_aCheckMovesNothingInTheLatestRounds`.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Disable experiment.** Skip the `latestByPiece` write in `append`; the whole-book test goes red. Restore.
- [ ] **Step 4:** `./scripts/test.sh` (foreground, 600000 ms). Commit `shell p4 task 2: every piece keeps its latest round letter, per language and per pass`.

**Tripwires:** 17 (no shared JSONL; these are a JSON ledger and a per-device sidecar, unchanged in kind), 11 (no migration: decodeIfPresent).
**Hand check:** none until Tasks 5 and 9 draw them.

---

### Task 3: The tree's "something to resolve" mark

**Seat.** Before: after a check or a round across the book the tree says nothing; only the Inbox row carries a dot, and the Book's To resolve is the only overview. After: each chapter row with anything waiting carries one small dot beside its stage dot; a Part row carries it when any chapter under it does; the Book row when the book's own to-dos or an unowned figure's notes wait; in a screenplay each scene row whose span holds an item. Never a number (design "The tree"). Owed by ADR 0035 ("Not yet built": "its one 'to resolve' dot on rows") and appraisal item 13.

**Files:**
- Create: `Maugham/Views/Resolve/ResolvePresence.swift` (**new** pure `ResolvePresence` and the window leaf `ResolvePresenceWatch`).
- Modify: `Maugham/Views/BinderTreeSections.swift` (`BinderTreeSectionsState` gains `var presence: ResolvePresence.Marks = .none`), `Maugham/Views/BinderRow.swift` (beside `statusDot`, `:133`), `Maugham/Views/PieceRow.swift` (beside its status dot, `:89`), `Maugham/Views/SceneNavigatorPane.swift` (script row and scene rows), `Maugham/Views/ProjectRowLabel.swift` or `TreeTopRows.swift` (the Book row), `Maugham/Views/ProjectWindow.swift` (mount `ResolvePresenceWatch` beside `PulledUpWatch`, so it runs with the tree hidden).
- Test: `MaughamTests/Resolve/ResolvePresenceTests.swift`; mounted rows through `TreeHostFixture`.

**Consumes:** `ResolveReader.read(scope:store:documentStore:diagnostics:) -> ResolveSnapshot` (`ResolveReader.swift:139`) at the Book's scope (`ResolveScope.of(.project, …)`); `ResolveReadKey` and `ResolveListDecisions.readKey(scope:annotationsToken:store:documentStore:diagnostics:localName:)` (`ResolveListDecisions.swift:45`); the `.maughamAnnotationsChanged` project event that bumps `ResolvePane`'s `annotationsToken` (`ResolvePane.swift:423`); `ProjectStore.countsOn(_:owners:)`, `figureNoteOwners(_:)`; `ParagraphOffsets.starts(sequence:paragraphs:)`, `.sceneIndex(starts:sceneStarts:)`; `FountainScript.sceneSummaries()`.

**Produces:**
```swift
enum ResolvePresence {
    struct Marks: Equatable { var pieces: Set<String>; var book: Bool; var scenes: Set<Int>; static let none: Marks }
    static func marks(_ snapshot: ResolveSnapshot, structure: [StructureItem],
                      figureOwners: [String: String?], sceneIndex: [String: Int]?) -> Marks
    static func partHasMark(_ groupId: String, marks: Marks, structure: [StructureItem]) -> Bool
}
```

**Contract:**
- One read per key, on the window: the key is the Book scope's `ResolveReadKey` plus each open piece's `annotationsVersion` and `tasksVersion` (the list key's splice inputs) plus the parsed script's scene starts. Rows look up `marks.pieces.contains(id)`; a Part's mark is computed in `marks`, not per row.
- A figure's notes mark the piece that owns it (`countsOn`); an unowned figure's notes and the Book's to-dos mark the Book row. A reference piece never carries the mark.
- A scene is marked when an item's paragraph falls in it (`sceneIndex`); items before the first slugline mark the script row only.
- Unreadable pieces (`snapshot.unreadableDocIds`) carry no mark and no claim of emptiness: their row keeps its existing unreadable treatment.
- The dot: 5 pt, secondary ink, after the stage dot, `accessibilityLabel` "Something to resolve". With nothing waiting, nothing is drawn (a quiet chapter stays quiet).

- [ ] **Step 1: Failing tests.** Pure: `test_aChapterWithAnOpenNoteIsMarked`, `test_aClosedChaptersToDoMarksIt`, `test_aLiveStrainMarksAndAStaleOneDoesNot`, `test_aFiguresNoteMarksItsOwningPiece`, `test_theBooksOwnToDosMarkTheBookRow`, `test_aPartIsMarkedWhenAChildIs`, `test_aSceneIsMarkedWhereItsItemsFall`, `test_aReferencePieceIsNeverMarked`. Census: `test_thePresenceReadIsOnTheWindowNotARow` (no row file calls `ResolveReader`), `test_noPresenceSourceLoadsADocument`. Mounted (`TreeHostFixture.binder`): a book with one marked chapter draws exactly one "Something to resolve" element.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Disable experiment.** Return `.none` from `marks`; the mounted count goes to zero and fails. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground). Commit `shell p4 task 3: the tree marks what has something to resolve`.

**Tripwires:** 4, 9, 30 (keyed on revisions, never a redraw counter), 21.
**Hand check:** 1 below.

---

### Task 4: The Book's Status, widened; the centre's view switch in the toolbar

**Seat.** Before: Status is the review board (passes and open notes), reached from a segmented picker in the Book view's own header. After: Status reads across each piece: its stage (the same dot and word as the tree), each pass, open notes, open to-dos. A Part's Status is the same over its chapters. A screenplay's Status is its one script row (thin, as the design says). The switch between Cards, Outline and Status is in the toolbar, where the design puts it, and only while the centre has views.

**Files:**
- Modify: `Maugham/Views/Review/ReviewBoardPane.swift` (stage column first; open to-dos column after open notes; `intrinsicWidth(passCount:)` counts both), `Maugham/Views/CentreColumn.swift` (the `.task` that reads `openNotesCounts`, `:535`, also reads open to-dos per piece), `Maugham/Views/ProjectAltitudePane.swift` (its header loses the picker; the title stays), `Maugham/Views/ProjectWindow.swift` (toolbar item), `Maugham/Models/BookView.swift` (**new** `EditionView`), `Maugham/Stores/UIState.swift` (**new** `editionView`, decodeIfPresent `.book`).
- Create: `Maugham/Views/CentreViewSwitch.swift`.
- Test: `MaughamTests/Review/ReviewBoardPaneTests.swift` (add), `MaughamTests/CentreViewSwitchTests.swift`.

**Consumes:** `ReviewBoardPane(title:structure:passes:openNotes:unreadableDocIds:onOpenNotes:onNavigate:onSetState:onRunRound:posture:)`; `ProjectStore.openNotesSummaries(in:)` (`ProjectStore+Annotations.swift:131`); `listTasksAcrossProject(filter:)`; `ReviewStatus.derived(passStates:passes:legacyStatus:)`, `StatusSwatch.color(for:)`/`.label(for:)`; `ProjectWindow.altitudeView(subject:bookView:structure:)` (`:1631`); `ProjectAltitudePane.offersStatus`.

**Produces:**
```swift
enum EditionView: String, Codable, Sendable, CaseIterable { case book, status }   // in BookView.swift
enum CentreViewSwitch {                       // pure half; the view is a toolbar Picker
    enum Offer: Equatable { case book(BookView), edition(EditionView), none }
    static func offer(subject: WindowSubject, bookView: BookView, editionView: EditionView,
                      structure: [StructureItem]) -> Offer
}
```

**Contract:**
- The toolbar switch shows exactly where `altitudeView` answers non-nil (the Book, a Part, an edition) and nowhere else; an edition offers Book and Status (Task 5 draws its Status), the Book and a Part offer Cards, Outline and Status. Icons with help text, as the old header's. Hidden, not disabled, elsewhere. Writes `bookView` / `editionView` through `updateUIState` as the header did.
- A Status row's open-to-dos cell counts the piece's open to-dos (a figure's to-dos count on its owner, `countsOn`); a click opens the chapter with To resolve on Mine (the open-notes cell's route, with `.mine`). The stage cell draws the tree's dot and the word.
- Closed pieces cost no load: to-dos come from the task walk, read once in the same `.task` as the notes.

- [ ] **Step 1: Failing tests.** `test_theStatusRowsCarryTheStageThePassesNotesAndToDos`, `test_aFiguresToDoCountsOnItsOwner`, `test_theSwitchIsOfferedOnlyWhereTheCentreHasViews` (table over every `BinderSubject` kind), `test_anEditionOffersBookAndStatus`, `test_theAltitudeHeaderHasNoPicker` (source census on `ProjectAltitudePane.swift`).
- [ ] **Step 2: Implement.** `ProjectWindow.body` changes: run the Release build (`xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO`) once before reporting, per `CLAUDE.md`.
- [ ] **Step 3: Disable experiment.** Make `offer` return `.none` for a Part; the table goes red at the Part row. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground). Commit `shell p4 task 4: the Book's Status reads stage, passes, notes and to-dos; the view switch is in the toolbar`.

**Tripwires:** 4, 6 (the altitude layer keeps one mount: the view is an associated value, `CentreRoute.swift:36`), `CentreRouteTests`.
**Hand check:** 2.

---

### Task 5: The edition's centre — its own book, its Status, the piece clicked, Compile…

**Seat.** Before: every edition shows the same newest PDF; clicking a chapter while an edition is the centre moves the faces but the book does not move; an edition's Status shows Cards; Compile… and the imprint picker live on the desk. After: each edition shows its own language's books; clicking a chapter scrolls the typeset book to where it starts; Status lists each chapter's translation (fresh / stale / missing), its latest round (number, date, how it ended), open questions, changes to look at, a short trend, and its publishing settings; Compile… and the imprint picker sit in the edition's book header beside the publication picker.

**Files:**
- Modify: `Maugham/Publish/PublishPreviewResolver.swift` (filter by edition), `Maugham/Views/Publish/PublishPreviewCentre.swift` (header gains Compile… and the imprint picker; the page to show), `Maugham/Views/research/PDFPreview.swift` (an optional page to go to), `Maugham/Views/Publish/PublishCentreModel.swift` (owns the compile runner and the imprint selection, moved from `DepartmentPaneHost`'s `@State compileRunner`, `:138`), `Maugham/Views/ProjectWindow.swift` (`publishCentre(…)` `:1573` and `altitudeView` `:1631` take `editionView`; `centreRoute` passes it), `Maugham/Views/CentreRoute.swift`, `Maugham/Views/CentreColumn.swift` (draws `EditionStatusView` for an edition's `.status`).
- Create: `Maugham/Publish/PDFAnchors.swift`, `Maugham/Views/Publish/EditionStatusView.swift`, `Maugham/Views/Publish/EditionStatusRows.swift`.
- Test: `MaughamTests/Publish/PDFAnchorsTests.swift` (real tectonic compile: `try await TectonicProbe.requireReady()`; `FontWarmup.ensure()` if text is styled), `MaughamTests/Publish/EditionStatusRowsTests.swift`, `MaughamTests/CentreRouteTests.swift` (add).

**Consumes:** `PublishPreviewResolver.readablePDFs(store:projectURL:)` (`:97`) and `.shown(_:in:)`; `Publication.language: String?`, `.imprint`; the paragraph anchor contract `p-<tag>-<¶id>` (`EmissionContract.anchorContract`, `EmissionContract.swift:651`); `EditionStatus.documentRows(documentIds:layerScope:store:projectURL:) async -> DocumentReport` (`:315`) and `DocumentRow { fresh, stale, missing, verbatim, orphans, openQueries }`, `UnreadableDocument`; Task 2's `latestFinishedByPiece(language:)`, `trend(language:docId:)`; `DepartmentPaneHost.select(imprint:in:)` (`:1237`), `.imprintNames(in:)` (`:1277`), `.scopedDocumentIds(_:imprint:…)` (`:1322`); `DeskCompileRunner` (`DeskCompileRunner.swift:24`) and `DepartmentCompileSheet`; `PiecePublishSettings`; `PieceRowSheet.publishing(_:)` (`PieceRowMenus.swift:104`), presented by the window (`TreeWindowWiring.swift:22`); `ClickRule.resolve` (an edition centre keeps `open` and moves `faces`, `ClickRule.swift:34`).

**Produces:**
```swift
enum PDFAnchors {   // reads the /Names /Dests tree (and a legacy /Dests dictionary) through CGPDFDocument
    static func pageIndex(of names: [String], in document: PDFDocument) -> Int?   // the first name that resolves
    static func pieceAnchors(docId: String, bodyTag: String, sequence: [String]) -> [String]  // "p-<tag>-<¶id>", in order
}
enum EditionStatusRows {
    struct Row: Equatable, Identifiable { let piece: StructureItem; let translation: EditionStatus.DocumentRow?
        let latestRound: TranslationRound?; let changesToLookAt: Int; let trend: [Int]; var id: String { piece.id } }
    static func rows(structure: [StructureItem], report: [EditionStatus.DocumentRow],
                     rounds: [String: TranslationRound], trends: [String: [Int]]) -> [Row]
}
```

**Contract:**
- **Per-language books.** An edition shows only its own publications: a translated edition those whose language is its tag (case-insensitive), a bilingual book in each of its languages' editions, the Source edition those with no language or the source tag. Read how `DeskCompileRunner` records a bilingual compile's `language` before writing the filter, and say what you found. With none: the existing `neverCompiled` notice, now true per edition.
- **The piece clicked.** With an edition open and a piece on the faces, the centre goes to the page where the piece's first anchored paragraph lands (`pieceAnchors` over the piece's `sequence` from `currentParagraphState`, no load). A piece with no anchor in that PDF (compiled before anchors, or outside the imprint) leaves the page where it is and the header says "<Title> is not in this book". Resolved off the main actor, once per (publication, piece).
- **Covers over Status.** With `editionView == .status`, `publishCentre` answers the problems, round and design-gate covers in their existing order and never `.books` or `.notice` (those are the Book view's). Status is a view, never a cover (`CentreRouteTests`).
- **Status rows** come from one `EditionStatus.documentRows` read per key (the manifest's modified time, the translations folder's latest write, the rounds ledger's) in `.task`; "changes to look at" counts the latest round's departures with no outcome. The trend is the piece's own (Task 2). Unreadable chapters are named above the rows (the desk's standing line, RULING-54). The publishing column shows the piece's table-of-contents and start-on settings; its click opens `PieceRowSheet.publishing`, offered where `PieceRowMenus` offers Publishing… (restructure permission), plain text elsewhere. The Source edition's Status has the publishing column only.
- **A Status row's click opens the chapter read in this edition's language** (Task 8's switch; until Task 8 lands it opens the chapter, and Task 8 adds the language). See Question 3.
- **Compile…** opens `DepartmentCompileSheet` for this edition's language (the Source edition: the book's language), with the imprint picker beside it; the compile runs on the window's `PublishCentreModel`, so it survives the column and the desk going. Problems still cover the centre when the compile settles, as today.

- [ ] **Step 1: Failing tests.** `test_aDestinationNamedForAPiecesFirstParagraphGivesItsPage` (compile a three-chapter book, anchors resolve to pages in order), `test_aPieceWithNoAnchorAnswersNil`, `test_eachEditionShowsOnlyItsOwnBooks`, `test_theSourceEditionShowsTheUntranslatedBooks`, `test_statusIsNeverCoveredByTheBookOrItsNotice`, `test_theStatusRowsCarryTranslationRoundChangesAndTrend`, `test_anUnreadableChapterIsNamedNotEmpty`, `test_theCompileRunnerLivesOnTheWindow` (census: no `DeskCompileRunner()` in `Views/Publish/DepartmentPaneHost.swift`).
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Disable experiment.** Return the unfiltered list from the per-edition filter; `test_eachEditionShowsOnlyItsOwnBooks` goes red. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground); Release build (ProjectWindow body). Commit `shell p4 task 5: an edition shows its own book, its Status, and the chapter you click`.

**Tripwires:** 4, 58 (`PublishPreviewResolver.fileURL(of:in:)` stays the path door), `PublishPreviewCentreTests`, `CentreRouteTests`.
**Hand check:** 3, 4.

---

### Task 6: The edition's To resolve

**Seat.** Before: with an edition selected, the To resolve position shows the desk (design row, language rows, compile), and To resolve's own list cannot be reached: ⌘⌥A/D/T drop their filter. After: an edition's To resolve is one list like any other: the translator's questions by chapter, the changes the latest rounds made that you have not looked at, glossary proposals, a design proposal awaiting a decision, the last compile's problems. Its head says where the edition stands (the translator's latest letter for a language; for the Source edition, the designer's latest line) and offers Run: a round of the whole book in that language, or for the Source edition a design round with an optional direction. The filters work, and so do ⌘⌥A, ⌘⌥D, ⌘⌥T.

**Files:**
- Modify: `Maugham/Views/Resolve/ResolveScope.swift`, `ResolveItem.swift`, `ResolveFilter.swift`, `ResolveReader.swift`, `ResolveGrouping.swift`, `ResolveHead.swift`, `ResolvePane.swift`, `Maugham/Views/RightColumnContent.swift` (the `.desk` arm and `RightColumnContent.desk(language:)` go), `Maugham/Views/RightColumn.swift` (the desk mount at `:556–578` goes; the `.desk` hint goes), `Maugham/Views/ProjectWindow.swift` (`positionAsk` keeps filters on every ground: the interim loss ends), `Maugham/Views/TreeEditionRows.swift` (an edition row carries Task 3's mark when its list is not empty).
- Create: `Maugham/Views/Resolve/ResolveEditionItems.swift` (rows and verbs for the four new kinds).
- Test: `MaughamTests/Resolve/ResolveEditionTests.swift`; add to `ResolveScopeTests`, `RightColumnMountingTests`.

**Consumes:** `ResolveScope.of(_:structure:projectType:)` (`:29`; `.edition` answers `.outside` today); `RightColumnContent.of(position:subject:translationLanguage:structure:projectType:)` (`:42`); `ResolveHeadShape` (`ResolveHead.swift:7`); `TranslationRound.DepartureRecord`, `.GlossaryProposalRecord`, `.summary`, `.collatorOverall`; `TranslationRoundReport.departureRows(_:…)`, `.proposalRows(_:)`; `TranslationRoundActions` and `TranslationAuthorVerbs.decide(…)` (`TranslationRoundActions.swift:142`); `DesignProposalStore.Proposal`, `DesignGateVerbs`; `PublishCentreModel.show(proposal:)`, `.show(round:)`, `.show(problems:)`; `TranslationPipeline.runBook(documentIds:language:) -> Bool` (`:210`), `.cancel()`; `DesignerOrchestrator` (the desk's `runDesign(direction:)` `:988` and `requestDesignChanges(_:)` `:1019` are the verbs to move, with `DepartmentTranslationOffers.decide` `:1417` and `DepartmentRunState.bookRefusal`); Task 2's readers; Task 5's compile problems on `PublishCentreModel`.

**Produces:**
```swift
// ResolveScope (new cases)
case edition(language: String, isSource: Bool, docIds: [String])
static func of(_ faces: BinderSubject, readIn language: String?, sourceLanguage: String,
               structure: [StructureItem], projectType: ProjectType) -> ResolveScope   // replaces of(_:structure:projectType:)
// ResolveItem (new cases)
case translationChange(docId: String, language: String, round: Int, TranslationRound.DepartureRecord)
case glossaryProposal(docId: String, language: String, round: Int, TranslationRound.GlossaryProposalRecord)
case designProposal(DesignProposalStore.Proposal)
case compileProblem(TectonicLogParser.Diagnostic)
// ResolveSource (new cases): .changes, .design, .compile
// ResolveHeadShape (new case): .edition(language: String, isSource: Bool)
```
(`readIn` is nil in this task except for an edition faced; Task 9 adds the piece read in a language.)

**Contract:**
- **Contents.** A translated edition: open notes with that `language` (the questions) and, from each chapter's latest finished round in that language, departures with no outcome (changes) and glossary proposals neither adopted nor skipped; grouped by chapter in manuscript order, a chapter's questions then its changes. Every edition, the Source included: a pending design proposal (book level, first) and the last compile's problems (book level). The Source edition has no questions or changes.
- **Lifetimes** (design "Two lifetimes"): changes and glossary proposals are replaced by the chapter's next round and draw with the check's lifetime mark; a design proposal is replaced by the next design round; compile problems by the next compile; questions stay until settled.
- **Verbs** are the round report's and the gate's, reused, never re-spelled: a change's Fine / Keep mine / Make it a rule / the reader's or collator's right (each via `TranslationRoundActions`, posture from `TranslationAuthorVerbs.decide`); a glossary proposal's Adopt / Skip; a design proposal's Show (the gate covers the centre) / Adopt / Discard; a problem's Show (the problems cover). Each that files says where (`FiledUnder`; the destination comes from the write's return value, never a literal: this also fixes the round report's hard-coded filing line, ADR 0037 "Not yet built"). A change row's click goes to its paragraph in that language (`TranslationReveal`), which opens the piece.
- **Head.** Translated edition: "<Language> edition", the translator's newest letter among the chapters' latest rounds (the round's `summary`, else `collatorOverall`, signed with the translator's name, `EditionStatus.translatorName`), its date and chapter, Open the report (the round cover), then Run round (whole book, `TranslationPipeline.runBook` over the imprint-scoped manuscript ids) and Cancel while running; Run is hidden where `DepartmentTranslationOffers` refuses. Source edition: the designer's name and latest line (`DepartmentDesignRow`'s), a direction field, Run design and Request changes, Cancel; hidden where the desk hid them.
- **Filters.** Questions, Changes, Design, Compile chips appear only when present. ⌘⌥A, ⌘⌥D, ⌘⌥T apply on every ground; `positionAsk`'s "drop the filter" branch is deleted with its test re-made as "a filter whose source is absent selects nothing and is not left to fire later" (the existing `selection(for:chips:…)` nil rule).
- **The faces' title line** reads "<Language> edition" (exists, `RightColumnSubjectLine.title`).
- An edition row in the tree carries Task 3's mark while its list holds anything.

- [ ] **Step 1: Failing tests.** `test_anEditionsListHoldsItsLanguagesQuestionsOnly`, `test_aChaptersChangesComeFromItsOwnLatestRound`, `test_anAdoptedProposalIsNotListed`, `test_aPendingDesignProposalIsInEveryEditionsList`, `test_theSourceEditionHasNoQuestions`, `test_changesDrawWithTheReplacedLifetime`, `test_aChangeFiledAsARuleSaysTheEditionBrief`, `test_theEditionHeadOffersRunWhereTheTranslatorMay`, `test_theSourceHeadOffersADesignRound`, `test_keyFiltersApplyWithAnEditionOnTheFaces`, `test_theDeskIsNoLongerMounted` (census: no `DepartmentPaneHost(` outside its own file), `test_noEditionSourceLoadsADocument`. Mounted via `RightColumnFixture`: an edition faced shows `ResolvePane` with the head.
- [ ] **Step 2: Implement.** Retire the desk's mounted tests per the Global Constraint (the rows' assertions move onto the head's and items' tests; the run-state rules onto `DepartmentRunState`'s pure tests, which stay); map each in the report.
- [ ] **Step 3: Disable experiment.** Drop the `language ==` filter in the edition read; `test_anEditionsListHoldsItsLanguagesQuestionsOnly` goes red. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground). Commit `shell p4 task 6: an edition's To resolve; the desk is no longer mounted`.

**Tripwires:** 4, 21, 47/51 (offers from posture), `RightColumnMountingTests.test_theControlIsTheOneOrderUnderEverySubject`, `test_eachOldPaneKeyLandsWhereTheMapSays` (re-made for ⌘⌥K in Task 7), `ReviewPassEditorTests`' call-site counts if a verb gains a caller.
**Hand check:** 5, 6.

---

### Task 6a: Brief's foot, without the how-to lines (Denver, 2026-11-21)

Added after the plan was written; build it after Task 6. Denver's ruling: drop the clutter; what matters is that set values are visible and History is findable; teaching belongs at the moment of action.

**Before → after (the writer's seat).** A new chapter's Brief today: the line, Going for, then "What you answer in To resolve is filed here.", "Nothing is attached to this chapter yet…", "Set a target", "Add tags", "Publishing settings", and a History link — on every new piece, for ever. After: the line, Going for, and ONE quiet foot line.

**Files:** `Maugham/Views/Brief/BriefDetails.swift`, `Maugham/Views/Brief/BriefDecidedSection.swift` (`emptyLine`), `Maugham/Views/Brief/BriefPieceView.swift`, the Resolve row/verb that files an answer (find the one writer of a Decided entry), their tests. Read the built code first; the names below are contracts, the code decides the shape.

**Contract.**
- **The foot line** is one line of secondary ink: the piece's SET values, then the doors. Target set → its words ("3,000 words"); tags set → the tags, truncating in the middle; nothing set → the single word "Details". Then "History". Each value opens the sheet it opens today (`pieceRowSheet`, the window's one presenter); "Details" opens a menu of the three sheets (Target…, Tags…, Publishing…), each offered exactly where `PieceRowMenus.items` offers it (posture). Publishing is reached only through that menu and the row menu; it has no row of its own.
- **Decided** draws only when something is filed. `emptyLine` and its heading-when-empty go.
- **Attached research** draws only when something is attached. Both empty-attachment sentences go.
- **Teaching at the moment of action:** when an answer in To resolve is filed to Decided, the row's confirmation says "Filed in Brief" as a button that shows Brief (`position = .brief`) for the piece it was filed on. If To resolve already confirms a filing, extend that line; do not add a second confirmation. It stands until the writer's next act in the list, never on a timer.
- A pure function gives the foot line's parts from (target, tags, offers); test it as a table: nothing set; target only; tags only; both; a reviewer's posture (values read as text, no doors it may not use); a Part and the Book (whatever Brief shows for them today — keep parity).

**Tests.** The table above; a mounted Brief built through Task 1's host builder for a fresh piece asserting the foot is one line and that neither sentence nor an empty Decided heading is in the tree; one for a piece with a target and tags; the filing confirmation's rule as a pure test plus a wiring census that its button writes the position and nothing else. No press-then-wait (tripwire 33). **Disable experiment:** restore `emptyLine`'s draw and see the fresh-piece test go red.
**Tripwires:** 4, 47/51, the `pieceRowSheet` presenter census, DocBudgetTests (Views/AREA.md ceiling), any test pinning the removed strings (delete those assertions with the strings; say which).
**Hand check:** a brand-new chapter's Brief is the line, Going for and one foot line; set a target and tags and they appear in the foot; answer a note and "Filed in Brief" takes you there.

---

## Plan 4b — Translation and the carries

### Task 7: The desk's last verbs find their homes; the desk is deleted

**Seat.** Before: adding a language, naming a translator or the designer, and Claude's proposed edition briefs live only on the desk. After: **Add Language…** is the Editions section's `+` and the Source row's menu; an edition's Brief shows who is cast and offers **Rename…** for the translator (and on the Source edition, the designer) where the desk offered it; a proposed edition brief shows on that edition's Brief as the book's proposals do, and a proposal for a language with no edition yet shows on the Source edition's Brief with its door.

**Files:**
- Delete: `Maugham/Views/Publish/DepartmentPane.swift`, `DepartmentPaneHost.swift` (its statics that still have callers move first: `select(imprint:in:)`, `imprintNames`, `scopedDocumentIds`, `openBrief(language:in:)` `:1346`, `proposedLanguages` `:1375`, `proposedWithoutRow` `:1387`, `needsTranslatorName`, `languageAlreadyOnTheDesk`, `DepartmentTranslationOffers`), and whatever only they used.
- Modify: `Maugham/Views/TreeEditionRows.swift` (header `+` menu, row context menu), `Maugham/Views/Brief/BriefEditionView.swift` (cast with Rename…, proposal line), `Maugham/Views/RightColumn.swift` (the `ResolveHint` enum and its two lines go), `Maugham/Views/ProjectWindow.swift` and `Maugham/MaughamApp.swift` (⌘⌥K), `Maugham/Views/AREA.md` (the desk's entries go; this pays for Tasks 3–6).
- Test: `MaughamTests/TreeEditionRowsTests.swift` (add), `MaughamTests/Brief/BriefEditionTests.swift` (add), `RightColumnMountingTests` (re-made key map).

**Consumes:** the desk's verbs at `DepartmentPaneHost.swift:745` (`askForALanguage`), `:757` (`askToRename`), `:771` (`askToRenameTheDesigner`), `:782–:960` (cast confirm, name, add), `DepartmentCastSheet`/`DepartmentCastPrompt`/`DepartmentCastAnswer`; `BriefEditionView` (reads the cast today, "changed only on the desk", ADR 0037); `StatementProposalBanner`.

**Produces:** **new** `EditionCastVerbs` (the moved cast verbs, one home, used by the tree menu and Brief).

**Contract:**
- Every verb the desk offered has exactly one new home or is named as gone with a reason in the report; nothing it offered is silently lost (census: each `DepartmentDesk.*Title` string that names a verb maps to a surviving call site or to the report's "gone" list).
- Rename and Add Language are hidden where the desk hid them.
- ⌘⌥K: To resolve with the faces moved to the edition the window is reading in (Task 8), else the Source edition; ⌘⌥L: To resolve on Questions. No hint lines (`RightColumn.ResolveHint` deleted). The whole-menu review in plan 5 may revisit both.

- [ ] **Step 1: Failing tests.** `test_addLanguageIsTheEditionsPlus`, `test_theTranslatorIsRenamedFromTheEditionsBrief`, `test_aProposedEditionBriefShowsOnItsEditionsBrief`, `test_aProposalWithNoEditionShowsOnTheSourceBrief`, `test_everyDeskVerbHasAHome`, `test_cmdOptKShowsTheReadingEditionsToResolve`.
- [ ] **Step 2: Implement; delete; retire the desk's suites per the Global Constraint.**
- [ ] **Step 3: Disable experiment.** Remove the `+` menu's Add Language; `test_everyDeskVerbHasAHome` goes red. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground). Commit `shell p4 task 7: the desk's verbs find their homes, and the desk goes`.

**Tripwires:** 21, 47/51, `DocBudgetTests` (Views/AREA.md must end at or under 7,985), `NoPersonaCensusTests`.
**Hand check:** 7.

---

### Task 8: A piece read in a language

**Seat.** Before: View ▸ Translation Review… opens a dialog of languages; the window enters a mode with a capsule over the text ("Reviewing · Serbian"), the right column becomes a different pane, and the source of the paragraph under the caret shows there. After: a language switch in the toolbar on a piece that has translations (Source, then each language); choosing one shows that language's text, read-only, with the source in secondary ink under each paragraph (View ▸ Show Source Under Translation, on by default, remembered per project); choosing Source returns. No mode, no capsule; the toolbar switch says what you are reading. Moving to another chapter that has the same language keeps it; one that does not returns to Source (Question 2). A running round shows in the toolbar as one quiet indicator ("Translating · Serbian · Chapter 3, re-reading", or an editor's round), because one round runs at a time across the book and the desk that showed it is gone.

**Files:**
- Modify: `Maugham/Editor/TranslationBadgeLayout.swift` (an entry carries its source; ranges split), `Maugham/Editor/EditorCoordinator+TranslationBadges.swift` (source ranges drawn in secondary ink as a temporary attribute, as missing paragraphs are dimmed), `Maugham/Views/EditorHost.swift` (`reviewBadgeEntries` `:1171` builds source-under text; the surface joins it), `Maugham/Editor/EditorControl.swift` (`translationLanguage` `:51` stays the one value; **new** `showsSourceUnder: Bool`), `Maugham/Views/TranslationReviewModifier.swift` → renamed `ReadingLanguageModifier.swift` (the picker dialog and `TranslationReviewIndicator` go; reveal stays), `Maugham/Views/TranslationReveal.swift`, `Maugham/Models/MaughamNotifications.swift` (`maughamEnterTranslationReview`/`Exit`/`ShowTranslationPicker` renamed `maughamReadInLanguage`/`maughamReadInSource`; the picker one deleted), `Maugham/MaughamApp.swift` (the menu item becomes View ▸ Read In ▸ …, a focused-value submenu, and the Show Source toggle), `Maugham/Views/ProjectWindow.swift` (toolbar), `Maugham/Stores/UIState.swift` (`showsSourceUnderTranslation`, decodeIfPresent true).
- Delete: `Maugham/Views/TranslationReviewIndicator.swift` (its `displayLabel(forLanguageTag:)` moves to `TreeEditionRows.title(forLanguage:)` or one shared spelling; there must be one).
- Create: `Maugham/Views/LanguageSwitch.swift`, `Maugham/Views/RunningRoundIndicator.swift`, **new** `ReadingLanguage` (pure).
- Test: `MaughamTests/Editor/TranslationSourceUnderTests.swift`, `MaughamTests/ReadingLanguageTests.swift`, `MaughamTests/RunningRoundIndicatorTests.swift`; `EditorHostTranslationSurfaceTests` (add).

**Consumes:** `TranslationBadgeLayout.Entry(paragraphId:text:status:)`, `.ranges(entries:)` (`:47`, "\n\n" separators); `TranslationReviewPaneLogic.selectedEntry(cursorLocation:entries:)`; `TranslatedDocument.Entry { translatedText, sourceText, status }`; `RenderFilter.stripTaskAnchorsInline`; `TranslationStore.languages(forDocId:in:)` (Core, `TranslationStore.swift:75`); `TranslationReveal.plan(_:subject:)`, `.perform(…)`; `TranslationPipeline.status` (`:143`, `.running(docId:language:leg:book:)`), `TranslatorOrchestrator.isRunning`, the compiler's `RunState` run cases (`Compiler/AREA.md` "RunState's run cases carry a RunKind").

**Produces:**
```swift
// TranslationBadgeLayout
struct Entry { let paragraphId: String; let text: String; let source: String?; let status: TranslationStatus }
struct BadgeRange { let paragraphId: String; let range: NSRange; let sourceRange: NSRange?; let status: TranslationStatus }
enum ReadingLanguage {
    /// The language the faces are read in: an edition open in the centre (not the Source) gives its tag;
    /// a piece open and faced gives the switched language; else nil.
    static func of(subject: WindowSubject, switched: String?, sourceLanguage: String) -> String?
    /// What the switch keeps when the open piece changes.
    static func carried(_ switched: String?, toPieceWith languages: [String]) -> String?
}
```

**Contract:**
- **The surface.** With source-under on, each paragraph's block is its translated text, a newline, its source text; blocks are joined by "\n\n" as today. `BadgeRange.range` covers the translated text only (so the badges and `selectedEntry` keep meaning "this paragraph"); `sourceRange` covers the source line and is drawn in `secondaryLabelColor` by temporary attribute, re-applied when the surface changes. The surface stays read-only (the coordinator's translation membrane, `EditorSurface.swift:504–525`, unchanged), a missing paragraph shows its source once (not twice), and the swap still goes through the one `applyExternalText` site.
- **The switch** shows only on a piece open and faced that has at least one translation; it lists Source and the piece's languages; the reveal routes (a round report row, a publish problem, a Used-in link) still land on a paragraph in a language through `TranslationReveal`, now posting `maughamReadInLanguage`.
- **Leaving a piece** applies `ReadingLanguage.carried`, replacing today's unconditional reset (`TranslationReviewModifier`'s `onChange(of: openDocId)`).
- **The running indicator** reads the pipeline's and the orchestrators' existing state; nothing new is stored; it is hidden when nothing runs; its click opens the running piece's To resolve. Focus mode hides it with the rest of the chrome.
- This changes nothing about what AI text may be drawn: the read-only translated surface is today's translation review surface, moved out of a mode.

- [ ] **Step 1: Failing tests.** `test_eachBlockIsTheTranslationThenItsSource`, `test_theBadgeRangeCoversOnlyTheTranslation`, `test_theCaretInASourceLineSelectsItsParagraph`, `test_aMissingParagraphShowsItsSourceOnce`, `test_sourceUnderOffIsTodaysSurface` (byte-identical to the pre-change join), `test_theSurfaceSwapsThroughTheOneExternalTextSite` (call count), `test_theLanguageCarriesToAPieceThatHasIt`, `test_anEditionOpenIsReadInItsLanguage`, `test_theSourceEditionIsReadInNoLanguage`, `test_theIndicatorNamesTheRunningRound`, `test_noTranslationReviewNamesRemain` (census over `Maugham/`: `TranslationReview`, `translationReview`, except the renamed modifier's history comment if any).
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Disable experiment.** Let `ranges` include the source line in `range`; `test_theBadgeRangeCoversOnlyTheTranslation` and the caret test go red. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground); Release build. Commit `shell p4 task 8: a piece read in a language, its source under each paragraph; translation review goes`.

**Tripwires:** 2 (the switch writes `editorControl.translationLanguage` and nothing writes back), 3, 6, 7, 21, `EditorHostTranslationSurfaceTests`, `ManuscriptForceCensusTests` (the reveal receiver's name).
**Hand check:** 8, 9.

---

### Task 9: To resolve for a piece in a language

**Seat.** Before: in translation review the right column is a separate pane (the paragraph's source, spot-checks, table cells, the language's queries, orphans), and To resolve is out of reach. After: To resolve is the same list, scoped to this chapter in this language: its questions and the latest round's changes and glossary proposals, headed by that round's letter (the round letter per piece of Task 2), with Run round (this chapter, this language), Spot-check this paragraph (gloss, collation) and the table cells for the paragraph under the caret; translations left over from deleted paragraphs are one group with Clear. The same list shows when an edition is open and a chapter is on the faces (design: "the faces follow the piece").

**Files:**
- Modify: `Maugham/Views/Resolve/ResolveScope.swift` (**new** case), `ResolveReader.swift`, `ResolveItem.swift` (**new** case), `ResolveHead.swift`, `ResolvePane.swift`, `ResolveEditionItems.swift` (shared rows), `Maugham/Views/RightColumnContent.swift` (`.translationReview` goes; `of(position:subject:translationLanguage:…)` takes `readIn:` instead), `Maugham/Views/RightColumn.swift` (the `TranslationReviewPane` mount at `:512` goes).
- Delete: `Maugham/Views/TranslationReviewPane.swift` (`TranslationReviewPaneLogic`'s `openQueries`, `orphanRows`, `purgeOrphans`, `reply(to:with:in:undoManager:)` and `selectedEntry` move to `ResolveEditionItems.swift` or stay as statics with callers; the spot-check and cells sections move under the head).
- Test: `MaughamTests/Resolve/ResolvePieceInLanguageTests.swift`; retire `TranslationReviewPaneTests` per the Global Constraint.

**Consumes:** Task 6's item kinds and verbs; Task 2's `latestFinished(language:docId:)`; Task 8's `ReadingLanguage.of`; `SpotCheck.Outcome`, the pane's gloss and collation calls; `TranslationCellsSection`; `ResolveHead.latestLetter(check:round:)` (`:70`) and Task 2's `latestRounds(docId:)`.

**Produces:**
```swift
case pieceInLanguage(docId: String, language: String)     // ResolveScope
case leftOver(docId: String, language: String, paragraphId: String, staleText: String)   // ResolveItem
// ResolveHeadShape: .pieceInLanguage(docId: String, language: String)
```

**Contract:**
- **Scope.** `ResolveScope.of(_:readIn:sourceLanguage:…)` answers `.pieceInLanguage` when the faces are a piece and `readIn` is a language. The list holds only that language's items for that piece; the writer's to-dos and the source's notes are not in it (they are one Source switch away).
- **Head.** That chapter's latest finished round in that language: its letter (summary, else collator's overall, signed), number, date, Open the report; then Run round (`TranslatorOrchestrator.runTranslation(docId:language:)`, `:474`) on the open piece where `DepartmentTranslationOffers` allows, else "Open this chapter to run a round on it" (plan 2's line); Cancel while it runs; Spot-check (gloss, collation) on the caret's paragraph and its table cells, open piece only.
- **Editors' letters (the milder half of Task 2).** At a piece's ordinary head, with `latestRounds(docId:)` holding more than one pass's letter, a menu "Earlier letters" lists each pass's latest by editor and round number; choosing one draws it in the letter section until the faces change. One line, hidden with one letter.
- **Left over** rows act only on the open piece (`purgeOrphans` asks `refuseUnlessTranslatable`), plan 2's rule.

- [ ] **Step 1: Failing tests.** `test_aPieceReadInSerbianListsOnlySerbianItems`, `test_theHeadIsThatChaptersOwnLatestRound` (after a whole-book run and a second chapter run), `test_anEditionWithAChapterFacedIsThatChapterInThatLanguage`, `test_runIsHiddenWhereTheTranslatorMayNot`, `test_leftOverRowsActOnlyOnTheOpenPiece`, `test_earlierLettersListsEachPassesLatest`, `test_earlierLettersIsHiddenWithOneLetter`, `test_theTranslationReviewPaneIsGone` (census).
- [ ] **Step 2: Implement; delete; retire suites with the mapping.**
- [ ] **Step 3: Disable experiment.** Answer `.piece` for `readIn` non-nil; the Serbian-only test goes red. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground). Commit `shell p4 task 9: a chapter read in a language has its own To resolve, headed by its round's letter`.

**Tripwires:** 4, 47/51, `RightColumnMountingTests` (content table), `WiringCensusTests`.
**Hand check:** 10, 11.

---

### Task 10: The fold's carries — a script's Scenes, a palette card in a region, keys

**Seat.** (a) A screenplay inside a Collection shows its fold flat, with no scenes; after, its fold is always grouped, Scenes first (each slugline a row; a click opens the script at that scene), then Research and the rest. (b) A palette card set inside a canvas region lists under the fold's Palette group, while the region pulled up shows it among its cards; after, it lists under its region row. (c) Arrow keys reach research rows in a fold but skip cards, regions, palette pins and figures; after, the arrow keys select them and selecting pulls the row up beside, as a research row does.

**Files:**
- Modify: `Maugham/Views/PieceFoldContents.swift` (`PieceFoldGroup.scenes`, `PieceFoldEntry.scene`, `entries(docId:shelf:…)` `:342`, `build(store:projectRoot:)` `:289`), `Maugham/Views/BinderPieceFold.swift` (scene rows; tags), `Maugham/Views/BinderTreeSections.swift` (`BinderTreeSelection.binding` `:1683` and `resolved(…)` `:1580` over **new** `TreeRowTag`), `Maugham/Views/BinderView.swift`, `CollectionPiecesPane.swift`, `SceneNavigatorPane.swift` (the `List` selection type), `Maugham/Views/AREA.md`, `docs/adr/0037-brief-and-the-pulled-up-thing.md` (decision 18's "a palette card inside a region still lists under Palette" is superseded; "Not yet built" loses the Scenes line).
- Test: `MaughamTests/PieceFoldIndexTests.swift` (add), `MaughamTests/BinderTreeSelectionTests.swift` (add), mounted via `TreeHostFixture`.

**Consumes:** `PinnedSection.regionId`, `PinnedReference.kind` (`.palette(cardId)`); `PieceFoldEntry.pulledUp` (`PieceFoldContents.swift:68`); `PieceFoldLayout.of(_:alwaysGroups:)` (`:138`); `ProjectStore.researchRouting(for:projectType:)`; `FountainTokenizer().parse(_:)` (Core) and `sceneSummaries()`; `currentParagraphState`; `ResolveNavigation.go(toDocId:paragraphId:)` (`ResolveNavigation.swift:100`); `ClickRule.pullUp(_:current:)` (`ClickRule.swift:73`); `BinderTreeSectionsState.selection: Set<BinderSubject>` (`:933`); `DocumentFormat.ofManuscript(path:).isScreenplay`.

**Produces:**
```swift
case scenes                                                       // PieceFoldGroup, first in order
case scene(docId: String, paragraphId: String, heading: String)   // PieceFoldEntry; group .scenes; pulledUp nil
enum TreeRowTag: Hashable { case subject(BinderSubject); case pullUp(PulledUp) }
```

**Contract:**
- (a) A screenplay piece in a Collection (`DocumentFormat.ofManuscript(path:).isScreenplay`) is always grouped and its Scenes group lists its sluglines in order, read from the piece's text without a load, once per `PieceFoldIndex.Key` plus the piece's op-log revision. A scene row is a `Button(.plain)` that opens the script at the slugline's paragraph (`ResolveNavigation.go`), as a link row travels. A standalone screenplay is unchanged (its tree is the Scenes navigator).
- (b) In `entries`, a `.palette` reference inside a section with a `regionId` joins that region's cards; one outside any region lists under Palette; one id once, region first (the shelf's order). The fold's region row and `PulledUpRegionView` agree (review M2's rule).
- (c) **The route: tag the rows** (the fix report's first route), with a tree-local tag type rather than new `BinderSubject` cases. Card, region, palette-pin and fold-figure rows carry `.tag(TreeRowTag.pullUp(entry.pulledUp!))`; every other tree row carries `.subject(…)`. The binding maps `.subject` writes through today's `resolved(…)` unchanged and a `.pullUp` write to `ClickRule.pullUp`, so arrowing onto a card pulls it up exactly as arrowing onto a research row does today. The rows' `Button(.plain)` press (`pressed(_:)`, the second-press double-click) stays for the mouse. `BinderSubject` and the persisted `WindowSubject` are untouched. Why this route: arrow keys move the `List`'s own selection, which a test can drive and read synchronously (`selectRowIndexes`, then read the subject); focusable buttons inside the outline view cannot be verified headless (the fix report's reason).
- The pulled-up row draws the `beside` outline as research rows do (`BinderTreeSelection.outlined`).

- [ ] **Step 1: Failing tests.** `test_aCollectionScriptsFoldIsAlwaysGroupedWithScenesFirst`, `test_aSceneRowOpensTheScriptAtItsSlugline` (pure: the destination), `test_theScenesFollowAnEditOfTheScript` (key moves), `test_aPaletteCardInARegionListsUnderItsRegion`, `test_aPaletteCardOutsideARegionListsUnderPalette`, `test_thePulledUpRegionAndItsFoldRowAgree`, `test_aPullUpTagWritePullsTheRowUp`, `test_aSubjectTagWriteIsTodaysClick` (table over the existing `resolved` cases), `test_everyFoldPullUpRowCarriesATag` (census on `BinderPieceFold.swift`). Mounted (`TreeHostFixture.binder`): `selectRowIndexes` on a fold card's row, then read `subject.beside` synchronously.
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Disable experiment.** Remove the `.tag` from the card row; the census and the mounted read go red. Restore.
- [ ] **Step 4:** `./scripts/test.sh` (foreground). Commit `shell p4 task 10: a script's fold has its scenes, a region holds its palette cards, the keys reach every fold row`.

**Tripwires:** 3 (the binding setter calls only `resolved` / `ClickRule.pullUp`), 4, 9, 31 (no membership change), `ReviewPassEditorTests`' `pullUp(` site count, `BinderTreeMultiselectMountTests` (re-made in Task 11).
**Hand check:** 12, 13, 14.

---

### Task 11: A failed promotion leaves the store open; the three once-only failures

**Seat.** Promote a Collection piece to its own project and let it fail (a full disk, a name collision at the manifest write): the alert says why, and today the Collection window carries on over a closed `DocumentStore`, its file presenter removed, every open `Document` closed under its editor, so typing goes nowhere and a peer's sync is not seen. The same is true after a promotion that succeeds. After: the window's store stays live either way.

**Confirmed at HEAD by reading:** `ProjectStore.promotePieceToProject(pieceId:destination:afterStaging:)` (`ProjectStore+CollectionPieces.swift:275`) step 1 calls `await docStore.close()` (`:334`) on the window's whole `DocumentStore`; `DocumentStore.close()` (`DocumentStore.swift:828`) drains `openDocuments`, closes figures and removes the presenter. The failure path (`rollbackPromotionStaging`, called at `:493`) moves files back and never reopens; the success path returns and the window (`ProjectWindow.swift:1240`) keeps the same store. Nothing reinstalls the presenter (`DocumentStore.swift:584` is the only install, in `open(url:)`).

**Files:**
- Modify: `Maugham/Stores/ProjectStore+CollectionPieces.swift`, `Maugham/Stores/DocumentStore.swift` (**new** `closeForPromotion(piecePath:figureIds:) async` and `resumeAfterPromotion()`, or one scoped verb; see contract), `Maugham/Stores/AREA.md`.
- Modify (flakes): `Maugham/Editor/EditorSurface.swift` (`paste(_:)` `:904`: read from a passed pasteboard), `MaughamTests/StatementImageIngestTests.swift`, `MaughamTests/LockedResearchSurfaceTests.swift`, `MaughamTests/Editor/FigureCommandTests.swift`, `MaughamTests/Editor/FigureGridFocusTests.swift`, `MaughamTests/BinderTreeMultiselectMountTests.swift`, `MaughamTests/TripwireGrepTests.swift` (allow-lists).
- Test: `MaughamTests/PromotePieceTests.swift` (add; the `afterStaging:` seam exists for exactly this).

**Contract (promotion):**
- The promotion closes only what it moves: the piece's own `Document` (flushed, closed, unregistered), the carried intent (already under its gate), the piece's own figures' open hosts. Other open documents stay open, and the presenter stays installed or is suspended for the staging moves and reinstalled in a `defer` that runs on success and failure alike. Choose suspension only if a test shows the presenter misreads the staging moves; say which in the report.
- `test_aFailedPromotionLeavesTheStoreLive` (fail via `afterStaging:` occupying the manifest path, then: another piece's open `Document` is not closed, the presenter is installed, a write to a second piece autosaves), `test_aSuccessfulPromotionLeavesTheCollectionLive`, `test_thePromotedPiecesDocumentIsClosed`. Disable experiment: put back the whole-store close; the first two go red.
- Tripwire 14: the staging moves keep their `// internal-move:` markers.

**Contract (the three once-only failures),** per `CLAUDE.md`'s stance (fix an invariant guard; delete the rest and cull the shape). Each was seen to fail once in a full gate (`StatementImageIngestTests.test_anImagePastedIntoVisualLanguageLandsInItsOwnWell`, 15.6 s; `FigureGridFocusTests.test_reviewFocus1_aFormulaTypedThenReturnEscEsc`, 0.57 s; `BinderTreeMultiselectMountTests.test_twoNotesSelectedInTheTreeAreWhatTheBatchVerbsActOn`, 0.41 s). First run each 30 times alone (a script file looping `./scripts/test.sh` with `-only-testing`; no `xcodebuild` in a loop's own command line) and once more inside the full gate; record what failed.
- **Image paste: an invariant guard (the picture lands in the well and its ref in the op log). Fix.** The tests write `NSPasteboard.general`, which every process on the machine shares (the writer's own ⌘C or a Universal Clipboard arrival during a gate replaces it). `paste(_:)` reads `.general` through **new** `paste(from pasteboard: NSPasteboard)`, which tests call with a uniquely named pasteboard. Census `test_noTestWritesTheGeneralPasteboard` across `MaughamTests/` (the three files above move).
- **Review Focus 1: an invariant guard (a review-required focus rule). Fix the race the runs show**; if 30 runs do not reproduce, read the first failing assertion's premise (`firstResponder` after Return; `scrollOffset` after 29 downs) against `FigureGridMountedTestCase`'s window activation, and make the premise explicit (`TestWindow.activate(_:)`) rather than adding a wait.
- **Multiselect batch: the press-then-wait shape** (`select(rows:in:until:)` writes `selectRowIndexes` then `pumpUntil`s SwiftUI's write-back; `waitOut(0.4)` in its default). **Delete the shape**: every test in the file that selects and then waits goes; the rule it guards stays pinned by pure tests of `BinderTreeSelection.resolved` (two `⌘`-clicks keep the window's subject; the acting set is `selectionForRow`'s) and by one synchronous mounted premise (`allowsMultipleSelection`). Remove the file's tripwire-33 allow-list entries, if any.

- [ ] **Steps:** failing tests; implement; disable experiments as above; `./gen.sh`; `./scripts/test.sh` (foreground) and `./scripts/test.sh full` (foreground) for the culls. Commit `shell p4 task 11: a promotion leaves the Collection's store live; three once-only failures settled`.

**Tripwires:** 14, 33, `PromotePieceFigureTests`, `StatementGateOrderTests`.
**Hand check:** 15.

---

### Task 12: The record

**Files:**
- Create: `docs/adr/0038-status-editions-and-translation.md`.
- Modify: `docs/adr/README.md`; `docs/adr/0035-*.md` and `0036-*.md`, `0037-*.md` ("Not yet built", "Interim homes", the interim loss, decisions 18 and 19's superseded lines, "Known limits"); `Maugham/Views/AREA.md`, `Maugham/Compiler/AREA.md`, `Maugham/Stores/AREA.md`, `Maugham/Publish/AREA.md` (map entries for every file created, deleted or renamed); `docs/INDEX.md` if it names the desk or translation review; the register's translation and annotations claims that name the desk or the review pane (fixing a filing closes the loop in the same branch, `CLAUDE.md`).

**Contract:** ADR 0038 records, as built: the per-piece round letters and where they live; the tree's mark; the Book's and the edition's Status; the edition and the piece-in-a-language as To resolve scopes and their four item kinds; the per-language book and the scroll to a piece; the toolbar's view switch, language switch and running-round indicator; the desk's and translation review's deletion and where each verb went; the fold's carries; the promotion fix; the flake verdicts; and the calls below, each marked as the agent's or the owner's. It does not describe the margin setting, the guide or the menu review as built. `docs/guide/` is not edited (plan 5 rewrites it).

- [ ] **Steps:** write; `./scripts/test.sh full` (foreground, 600000 ms; no skips); Release build. Commit `shell p4 task 12: ADR 0038 and the record`.

**Tripwires:** `DocBudgetTests` (all ceilings), `DocSyncTests`, ADR index census.

---

## Hand checks owed to the owner

Plans 1–3's hand checks stand. This plan adds:

1. Run a check on two chapters and a round on a third, then close them all: those three rows carry a small dot beside the stage dot, a Part over one of them does too, and the others carry none. Settle a chapter's last note: its dot goes. In a screenplay, a scene with a note carries the dot.
2. The toolbar switch on the Book: Cards, Outline, Status. Status reads stage, each pass, notes and to-dos per chapter; click a to-do count: the chapter opens on Mine. Click a chapter (Cards, Outline or Status): it opens.
3. An edition with a compiled book in its language: only that language's books are in the picker. Click a chapter in the tree: the book scrolls to where it starts. A chapter outside the imprint says so.
4. The edition's Status: translated counts, latest round, questions, changes, trend and publishing settings per chapter; Compile… and the imprint picker in the book's header; a failed compile covers the centre with its problems.
5. Select a translated edition: To resolve lists its questions and changes by chapter, the translator's latest letter at the head, Run Whole Book with the line under it ("Runs every chapter of the book: N chapters", or the chosen imprint's count and name when the compile bar's imprint picker stands on one). Mark a change Fine, then quickly Fine another in the same chapter: both go, and neither comes back. Keep mine on a third, Make a fourth a rule ("Filed under the Serbian edition brief", a link): each leaves the list at once and does not come back on scrolling or collapsing the chapter; Open the report shows them as "Ruled.". Adopt a glossary term, then Skip another in the same round: the first stays adopted, and the edition brief holds it once. Click a question: its paragraph opens in Serbian. Settle the last thing in the edition: the Serbian row's dot in the tree goes, and the edition's Status no longer counts it. ⌘⌥A/D/T work here (a chip the edition lacks leaves your filter as it was).
6. Select the Source edition: the designer's line and Run design with a direction; a pending proposal is in the list (and in every edition's) with Show, Approve and Discard; Discard asks first. Show covers the centre with the gate; approve it there, then press Discard in the list: refused ("no longer waiting"), and the gate still offers Revert. A compile that lands with only warnings dots no edition and lists nothing; a refused compile lists its errors in every edition and dots every edition row.
7. (Task 7) The Editions header's `+` sits in line with Research's and the Palette's and opens the sheet in one press (also the Source row's right-click, and File ▸ Add Language…): type `it` — Calvino and his reader and collator fill in — Add Language: the Italian edition appears under Editions, selected, with To resolve saying no round has run and offering Run Whole Book, its line ending "· 7 legs · ~N words briefed". Add `it` again: no alert — the window selects Italian and shows its Brief, nobody renamed. On an older book with publishing never set up and no translation, the Editions header and its `+` are still there; ask Claude to propose a German brief there: the Source row appears and its Brief offers Add German… (which lands on German's Brief with the proposal waiting) and Discard (which asks first). Propose a Spanish brief for an existing Spanish edition: the Spanish row reads "Proposed" beside its dot, and Brief's segment carries its dot while Spanish is faced. Fail a Serbian run (disconnect mid-round): Serbian's To resolve head says "Round N · failed while translating — <why>" in red with Open the report, and the older letter under it is labelled the last finished round's. Rename the translator: earlier letters keep the old name; the next round signs the new. On Italian's Brief, Cast ▸ Change…: the sheet starts from the three names; rename the translator; the Brief shows the new name. On the Source's Brief, Designer ▸ Change…: rename Tschichold. Ask Claude to propose an edition brief for Spanish (an edition) and one for German (none): Spanish's Brief shows the banner with Adopt/Discard; the Source's Brief reads "Claude proposed a brief for an edition in German." with Add German… (opens the sheet on `de`) and Discard. ⌘⌥L: To resolve on Questions. ⌘⌥K on a chapter: the View menu reads "To Resolve: English Edition" and it shows the Source's To resolve; with the Serbian edition open in the centre it reads "…Serbian Edition". Narrow the right column to its minimum on each Brief: nothing runs off the edge. Nowhere in the app says "desk".
8. On a translated chapter, the toolbar's language switch (it reads "Source" with a book icon; it is absent on a chapter with no translation): choose Serbian; the text is Serbian, read-only, with the English under each paragraph in grey; a grey reading position (not a typing caret) moves with the arrows; a quiet line over the text reads "Serbian translation · read-only · N paragraphs out of date · … · To change it, write in Source — the next Serbian round carries it over." with Read Source at its end (narrow the window: the line shortens, Read Source stays). Type, paste, drop text, Edit ▸ Spelling, a Service, Writing Tools, ⌘F's Replace: nothing lands (no Replace is offered). Scroll halfway down without clicking, choose Serbian, then Read Source: the same paragraph stays at the same height both ways; put the caret mid-paragraph and do the same: the caret stays in that paragraph. Type a sentence, ⌃⌘L to Serbian, ⌃⌘L back to Source, ⌘Z: the sentence is undone. The switch's menu and View ▸ Show Source Under Translation turn the grey lines off and on — in a second window on the book too; quit and reopen: kept for this book. View ▸ Read In ▸ … and ⌃⌘L do what the switch does. A stale paragraph has an amber dot, its translation in amber-tinted ink, and its current English under it; VoiceOver on it says "Out of date…"; an untranslated one shows its English once, lighter, with a hollow dot ("Not translated yet…"). Select across two paragraphs and copy: only the Serbian is on the pasteboard; select inside a grey line and copy: that English. The footer's word count is the Serbian's. ⌘⌥F a word, click a match: the chapter reads in Source and the match is selected. In a screenplay read in Serbian, a Scenes row lands on its scene's Serbian; sluglines, cues and dialogue are styled as in the source, each with its English a blank line under it; the Scenes list does not double. In review mode, select Serbian text: the toolbar offers only Translator's note, and no note highlights fall on the Serbian. A table or a figure is not repeated in grey. Click into a grey line: To resolve's caret group is that paragraph's. Go to the next chapter: still Serbian if it has a translation, else Source. With an edition's Status open, click a chapter: it opens read in that edition's language. Make the translations folder unreadable (`chmod 000 .maugham/translations`): the switch shows a warning and says so in its menu.
9. Start a whole-book translation run: the toolbar says what is running ("Translating · Serbian · “Chapter Three” (3 of 12), re-reading"), in every window on the book; narrow the window: it shortens to "Serbian 3/12" (full text in its tooltip) and the language switch never goes into the toolbar's overflow; click it: that chapter opens read in Serbian with To resolve showing. In a second window on the same book press Run Whole Book: it says a Serbian round is running and starts nothing. Write in chapter 4 in one window while another window reads chapter 4 in Serbian: typing stays smooth, the Serbian window's grey lines catch up a moment after each pause, and its scroll and selection stay put. Cancel from To resolve's head: the indicator goes. ⌘\ hides it with the toolbar. Run an editor's round (⌃⌘R): the toolbar names the pass's editor ("Perkins’s round · “…”, reading").
10. A chapter read in Serbian: To resolve holds only Serbian questions and the round's changes (a question and a change on one paragraph under that paragraph's group; a glossary term under "Whole chapter"), headed by "Serbian translation" and that chapter's own round letter, even after a whole-book run and a second run on another chapter. Cancel a run on this chapter: the head says so in its words above the earlier letter. Press Run: the line under it says what it runs and costs ("Runs this chapter into Serbian · ~N words…"); a second window's Run says a round is running. The head's "N paragraphs out of date · M not translated yet" opens to links that land on each paragraph in Serbian; delete a translated paragraph in Source, come back: "1 translation left over from a deleted paragraph" with its text shown and Clear, which asks first ("Clear 1 left-over translation? Its paragraph no longer exists.") and then removes it (absent for a reviewer); with five left over, the count shows the first two and "and 3 more". Make a left-over's paragraph come back in another window before confirming: Clear refuses ("These translations changed…") and clears nothing. Make the translations folder unreadable: the head says it could not be read, and "This paragraph" says spot-checks need the translation on screen. Run on Chapter 7, then read Chapter 3 in Serbian: its head says "Translating “Chapter Seven” into Serbian…" with no Cancel and no Run, and Chapter 7's round keeps going; Chapter 7's own head has Cancel. A whole-book run that has Chapter 3 still to come gives Chapter 3's head Cancel. Run's cost never shows another chapter's figure after you move. With the Serbian edition's head open during a one-chapter run, its leg line names the chapter. Put the caret in a paragraph: "This paragraph" with its chip, Gloss and Ask the Collator (move the caret while one is out: the answer does not land under the new paragraph); a table's line shows its cells; turn View ▸ Show Source Under Translation off: the source appears there. Reply to a question: refused for a reviewer in words, never silently. ⌘⌥L lands on Questions; ⌘⌥A/D/T change nothing. With nothing listed, the line says why — and if the chapter's tree row has its dot, that its source has notes open. With an edition open, click a chapter: the same list; its questions have no Reply and the head says "Open this chapter to answer its questions" (with none, "…to run a round on it"), which opens it read in Serbian. While the chapter you just opened is still loading, its head says "Opening…", never "Open this chapter". Narrow the column to its minimum: nothing runs off the edge.
11. Run two different editors' rounds on one chapter: the head's "Earlier letters" lists the first editor's letter ("Perkins · round 2"), and choosing it shows it labelled "An earlier letter" (with "The latest letter" to go back); another chapter starts on its latest. With one letter, no menu.
12. A Collection with a script: the script's fold is grouped with Scenes first ("Scenes (N)"); a scene opens the script there, from any centre. Type a new slugline in the script and pause: the Scenes group gains it. A prose piece beside it has no Scenes group.
13. Put a palette card inside a canvas region bound to a chapter: the fold lists it under the region, not Palette, and the region pulled up beside lists it in the same place. (A card ALSO pinned to the chapter lists once, under Palette — the shelf's first claim.)
14. Arrow keys through a chapter's fold, with the right column showing a pulled-up thing: cards, a picture, a region, a palette pin and a figure are each reached and selected at once; pause on one (~⅓ s) and it replaces what is pulled up; arrow quickly through five and only the last is pulled up, and ⌘[ goes back past none of the rows merely passed. With the column on To resolve or Brief (or hidden), arrowing only selects: the column never opens or changes. The same for research notes in the Research section and in folds. Return (or Space) on a selected row pulls it up now and shows the column; Return again puts it away (the row stays selected). ⌘↓ opens the selected row in the centre (a card or region: the canvas with it selected). The centre and the faces never move on an arrow. **Click safety (review I1):** a single click on a fold card that is not up comes up and STAYS up; a single click on the one up puts it away; a double-click opens it in the centre; after a click, ↓ continues from the clicked row. While renaming a note, Return commits the rename and pulls nothing up. VoiceOver on a card row reads "Card: <title>" and says what activating it does.
14a. Drop-target feedback — the drop look is a DASHED ring (filled for "into"), or an insertion line with a hollow dot at its left end; nothing standing in the tree (the open row's fill, the faces' and the pulled-up row's solid outline, the selection) is dashed. Drag a research note over a chapter: dashed and filled (it will be linked); over the chapter it is already linked to: nothing. Drag a chapter over another chapter: a line above it in its top third, below it in its lower two thirds; over a Part: a line above in the top third, the Part filled in the middle third (it goes in), a line below in the bottom third. In a Collection, a piece over a piece: line above in the top half, below in the bottom half. Drag a note over a shared research note: line above or below where it lands; over a research group: line above, filled in the middle (into the group), line below. A Finder file over a research group: filled only in its middle third, a plain dashed ring at its edges (it lands in the group's container). A note over the Research header after dragging it out of a fold: filled; over Figures: nothing; a table over Figures: filled; anything over "No cards yet.": nothing. Drag over the open chapter's row and over a selected row: the look reads clearly on both, light and dark. Every look you see is the drop that lands; every target that shows nothing springs the drag back.
14b. The Canvas row: with the Inbox in the centre, drag a capture onto the tree's Canvas row — it fills while you hover; the capture leaves the Inbox and the Canvas row gains a RED dot (the Inbox's "new" look, not the accent "to resolve" dot); open the Canvas: the card is selected and in view, loose, outside every region, and the dot is gone. Do the same with a research note, a research picture and a Finder photo. With the canvas already in the centre, drop a note on the Canvas row: it lands and no dot appears. A Finder text file or PDF over the Canvas row shows nothing and springs back. A chapter dragged over it shows nothing. With a canvas layout this build cannot read, nothing is accepted.
15. (Task 11) A Collection with three pieces in two windows: Story B open in one, typing; Story A open in the other. Promote Story A from its window. **Success:** the new project opens in its own window; the Collection window's centre shows Story A's reference card (Open); Story B's window never stopped (no reload, no "Loading…"); open Story C in either window — it loads; quit and relaunch: every word is there. **Failure** (choose a destination inside a locked folder — Finder ▸ Get Info ▸ Locked): the alert gives the reason; nothing moved. (A failure after files moved — not reachable by hand; the tests drive it — reads "“Story A” couldn’t be promoted: <why> Everything was put back where it was.", or names the folder holding what could not go back, or "“Story A” is now a project at <path>, but the Collection couldn’t be changed to point at it…".) Story A's centre shows "Loading…" only for the moment the promotion runs, then its text again, editable; Story B never stopped. Let an edit to Story B sync in from another Mac: the window shows it. Then: Esc on a dimmed canvas, close that window, open another project and press Esc in a text field: it is not eaten.
16. Smoke: launch → New project → Novel → "Smoke" → type a sentence → ⌘Q → relaunch → open from Recents → sentence intact.
17. (Task 6a) A brand-new chapter's Brief: the line, Going for, and one quiet line at the foot reading "Details · History" — no "Decided", no "What you answer…", no "Nothing is attached…". Click Details: Tags…, Add Link…, Target…, Publishing… (Publishing… only where publishing is set up). Set a target of 3,000 and tags rome, draft: the foot reads "3,000 words · rome, draft · Details · History", each value opens its sheet, Details still lists every sheet, and right-clicking the line offers them too. Narrow the column to its minimum: the tags read "2 tags", and Details and History stay whole on screen. Hover: each door brightens. With Keyboard navigation on, Tab reaches the foot's doors; VoiceOver reads "Word target: 3,000 words", "Tags: rome, draft", "History".
18. (Task 6a) Answer a finding in a chapter's To resolve: the line under the head reads "Filed in Brief" in the accent colour; leave it a minute — it stays; click it — Brief shows that chapter with the answer under Decided. Back in To resolve, click anything in the list: the line goes. From the Book's list it reads "Filed in “<chapter>”'s Brief"; on an edition, "Filed under the Spanish edition brief" still.

---

## Calls made in this plan, for Denver to check

1. **The design proposal is listed in every edition's To resolve**, not only the Source's: today its gate covers the centre of any edition, and every edition's pages use the design. Cost if wrong: one filter line.
2. **Translator's changes and glossary proposals carry the check's lifetime** (replaced by the chapter's next round). Cost: a mark's style.
3. **Source under each paragraph is on by default**, remembered per project. Cost: one default.
4. **The view switch moves to the toolbar** (the design's place) and leaves the Book view's header. Cost: a header picker to restore.
5. **Keyboard reach tags the fold's pull-up rows with a tree-local tag** rather than new `BinderSubject` cases or focusable buttons (reason in Task 10). Link and scene rows stay buttons (they travel; arrowing onto one would move the centre). Cost: the selection type of three hosts.
6. **The promotion closes only what it moves.** Cost if a hidden reader needed the whole store closed: a narrower close to widen, with a red test to show where.
7. **The flakes:** two invariant guards fixed (image paste, Review Focus 1), one shape culled (multiselect select-then-wait). Cost: one mounted proof of ⌘-click multiselect becomes pure.
8. **⌘⌥L is To resolve on Questions; ⌘⌥K is the reading edition's To resolve** (else the Source's). The hint lines go. Plan 5's menu review may change both.
9. **"Earlier letters" at a piece's head** is how the milder half (editors' rounds) is reached: one menu, hidden with one letter. Cost: one control.
10. **A running round shows in the toolbar** (the design's standing indicator), built here because the desk that showed run state goes. Cost: one toolbar item.
11. **A finished round means ended and not cancelled**; a failed round's partial letter still counts. Cost: one predicate.
12. **The Source edition's Status shows the publishing column only.** Cost: a sparse view.
13. **A piece read in a language keeps left-over translations and out-of-date / not-yet-translated paragraphs as head lines, not list items** (Task 9; the plan's `ResolveItem.leftOver` was not built). Reason: the list is exactly what marks a row (the edition's dot and the empty line read one predicate, `ResolveEditionItems.items`), and listing these would make every chapter with a stale paragraph look like it waits on the writer — they are settled by a run (stale, missing) or by a Clear (left-overs), not by a decision; marking them would also mean deriving every chapter's translation for the tree. Cost if wrong: a new item kind and its row, and that derive per piece in the presence read.

## Questions for Denver

1. **Where should the designer's Run live now the desk goes?** Recommendation: at the head of the Source edition's To resolve (with its direction field), because a design round raises a proposal you then decide on in the same list. The alternative is Visual Language pulled up, where the design is described. This changes Task 6's head.
2. **Should a chapter read in a language stay in that language when you move to the next chapter?** Recommendation: yes, when the next chapter has that translation, else Source; reading an edition chapter by chapter is the use. The alternative is always back to Source (today's behaviour). This changes `ReadingLanguage.carried` in Task 8.
3. **A click on a chapter in an edition's Status: open it read in that edition's language, or in the source?** Recommendation: in the edition's language (you were looking at that edition). Your 2026-11-16 rule makes the Status an overview you navigate from, so it opens the chapter either way; the question is only the language. This changes one line in Tasks 5 and 8.

4. **(Task 11 review, pre-existing; taken to you as its own piece of work, not built here)** A promoted piece's op log never travels: its history, checkpoints, annotations (open notes and Claude's), to-dos and translations stay in the Collection under the old id, and the new project starts from the `.md` alone — a peer's ops that synced while the piece was closed are not in it.

## Denver's answers (2026-11-21)

1. The designer's Run: at the head of the Source edition's To resolve, as recommended.
2. A chapter read in a language stays in that language on the next chapter when it has the translation, else Source, as recommended.
3. A click on a chapter in an edition's Status opens it in the edition's language, as recommended.
4. The two ADR 0035 leftovers no plan owned — drop-target feedback on the tree, and a drop on the Canvas row as the capture-to-canvas route — join Task 10. Its implementer derives the contract from ADR 0035's "Not yet built" lines and the built drop routes, and pins each with a test.
5. Brief's how-to lines go: Task 6a.

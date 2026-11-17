# To Resolve (shell plan 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One right-column face, To resolve, replaces the Annotations, Diagnostics and Tasks panes: what has been raised about the faces' subject, read without loading any document, grouped by where it sits, filtered by source, following the caret.

**Architecture:** A pure reader turns store-level data (the project annotation walk, the project task walk, the diagnostics sidecar) into `ResolveItem`s for a `ResolveScope`; pure functions group, filter and collapse them; one view draws the result in one `ScrollView`. Verbs that are `Document` methods are offered only on the piece the centre has open; a row on any other piece is readable and its click opens that piece. The three pane shells go; their verbs, dialogs and sheet state move to `Maugham/Views/Resolve/`.

**Tech Stack:** Swift, SwiftUI, AppKit. No new dependency. MaughamCore unchanged.

**Spec:** `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md` ("To resolve", "Constraints"). Built on ADR 0035. Signatures below were verified at `5c0210f6`; the reconnaissance is `.superpowers/sdd/plan2-recon.md` (sections A, B, C, F, G).

## How this plan is cut

Plan 2 of 5 on `claude/shell-without-personas`. Plan 3 does Brief, the pulled-up thing, the fold, ⌘2/⌘3 and the death of the pane picker and `DetailSegment`. Every task builds final behaviour; between tasks the branch must compile and pass `./scripts/test.sh`.

**Consequence to know:** the check's clause readings (holds / strains / silent beside each intent sentence) and the conformance section's Open Intent button belong to Brief (spec, "What Denver decided": the reading is marked on the intent in Brief). This plan keeps the strains, as findings; the holds/silent display is absent until plan 3.

## Global Constraints

- The hard invariants in `CLAUDE.md` stand. **No second `Document` load:** To resolve never calls `Document.load`, `withAnnotationDocument`, or any transient act-and-close load, and never holds a `Document` beside the editor's (recon A.10). It acts only through the `Document` `DocumentStore.document(forDocId:)` already returns.
- **Nothing AI-produced is drawn on the manuscript or its chrome** (constitution must-not #2, ADR 0027 §1). A row click moves the caret through the existing navigation event; the editor receives a position, never a payload.
- `EditorHost` gains no state (tripwire 6). The caret is read from `Document.cursorLocation` and `Document.paragraphId(at:)` (`Maugham/OpLog/Document.swift:28`, `:1111`), as `ProjectWindow.paragraphIdForFooter` does.
- No uncached per-row work (tripwire 4): the project walks and the grouping run once per refresh key, never in a row or per caret move.
- No `List(.sidebar)` and no `.onTapGesture` for row activation (tripwire 9); rows activate through `Button(.plain)`.
- Hide, don't disable; ask `Posture` (tripwires 47, 51). A manuscript writer outside the editor asks its posture first (tripwire 52): moved mutators keep their classification in `TripwireGrepTests.test_everyGuardedDocumentMutatorIsClassified`; never widen it.
- Tripwire 34: the check's reader comes from `AuthorReader`, the round's editor from the cockpit's active pass; the head shows both and neither feeds the other.
- Tests are pure functions, censuses, or mounted measurements; never press-then-wait (tripwire 33).
- `NoPersonaCensusTests` stays green. No raw `maugham.*` notification outside `MaughamEvent` (tripwire 21).
- Read `Maugham/Views/AREA.md` before editing under `Maugham/Views/`. Read `register/reconciliation/Annotations.claims.json` and `Annotations.filings.json`, and RULING-29, -31, -34 and -54 in `register/RULINGS.md`, before any task that changes how notes are shown or acted on (Tasks 1, 4, 6, 7).
- `./gen.sh` after adding or deleting any file. `./scripts/test.sh` in the foreground only; never raw `xcodebuild test`, never a background gate.
- Rows keep today's appearance; this plan restyles nothing beyond the one caption line Task 6 names.

## Review Focus

1. **A piece with 300 open notes.** One refresh builds the list once; past 12 items the filters are single-choice and only the caret's group is open. Test in Task 3.
2. **A narrowed or shared book whose posture refuses a verb.** The open piece's rows hide what the posture refuses; Keep as lesson follows the lessons ledger's posture; the head hides Run and the ladder's menus. Test in Task 4.
3. **A screenplay.** Rows group by scene; paragraphs before the first slugline group together; the offsets used agree with the editor's to the character, task anchors and emoji included. Tests in Task 2.
4. **A note anchored to a paragraph since deleted.** It is listed under "No longer in the text" at the end of its piece, never dropped, never filed under Whole chapter. Test in Task 2.
5. **The Canvas in the centre with the faces on a piece.** The piece's items show, with no verbs but Answer and Keep as lesson, no caret group, and a row click opens the piece on its paragraph. Tests in Tasks 3 and 4.

---

## What To resolve shows

| Item | Read from (no load) | Source (filter) | Lifetime |
|---|---|---|---|
| A note (`Annotation`, open) | `ProjectStore.listAnnotationsAcrossProject()` | Questions if `language != nil`; else Checks if `compilerRunId != nil && compilerRound == nil`; else Mine if `AnnotationOwnership.isOwn(_:localName:)`; else its pass if `reviewPassId != nil`; else Others | until settled |
| A check finding (`Diagnostic`, `.conformanceStrain`) | `DiagnosticsStore.live(docId:currentText:)` after `load(docId:)` | Checks | **replaced by the next check** |
| A to-do (`WriterTask`, `.open`) | `ProjectStore.listTasksAcrossProject(filter:)` (closed pieces included; its header comment says otherwise and is stale, recon A.2) | Mine | until settled |

A check's continuity questions, reader reports and letter questions are notes with a `compilerRunId`: they show once, as notes, captioned as from the check, and they last until settled. Only sidecar strains carry the "replaced by the next check" caption. The first matching source wins, in the column's order.

---

## Carried from plan 1

- **A palette card open beside the centre is editable while the window is locked** (recon E: `PaletteCardEditor` beside has no Lock gate). Task 4 closes it: the beside palette card asks the same `isLocked` the centre's card asks, with `test_lockRefusesAPaletteCardEditBeside` in `LockTests`. Hide, don't disable.
- Plan 1's stopgap (`faces == open` gating the document panes, final-review I2) is removed in Task 7 for the three panes this plan replaces; History, Translation and References keep it until plan 3.

---

### Task 1: The reader — what a scope holds, without a load

**Files:**
- Create: `Maugham/Views/Resolve/ResolveItem.swift`, `Maugham/Views/Resolve/ResolveScope.swift`, `Maugham/Views/Resolve/ResolveReader.swift`
- Test: `MaughamTests/Resolve/ResolveScopeTests.swift`, `MaughamTests/Resolve/ResolveReaderTests.swift`

**Interfaces — consumes** (verified): `ProjectStore.listAnnotationsAcrossProject() -> ProjectAnnotationsSnapshot` (`annotations: [ProjectAnnotation]`, `unreadableDocIds`, `sequences: [String: [String]]`, `figureCells`); `ProjectStore.listTasksAcrossProject(filter: TaskFilter) -> [WriterTask]`, `TaskFilter(scope: .document(docId:) | .project, statuses: [.open])`, `ProjectStore.projectTasksDocId`; `DiagnosticsStore.load(docId:)`, `.live(docId:currentText:) -> [Diagnostic]`, `.version`; `currentParagraphState(documentId:store:documentStore:projectURL:) throws -> (sequence:, paragraphs:, projectURL:)`; `StructureItem.pieceKind`.

**Produces:**

```swift
enum ResolveItem: Identifiable, Equatable {
    case note(ProjectAnnotation)
    case finding(docId: String, Diagnostic)
    case todo(WriterTask)
    var id: String { get }            // kind-prefixed, unique across kinds
    var docId: String { get }         // a to-do with no anchor is ProjectStore.projectTasksDocId
    var paragraphId: String? { get }  // note.paragraphId, finding.anchor?.paragraphId, todo.anchor?.paragraphId
    var isReplacedByTheNextCheck: Bool { get }   // .finding only
}
enum ResolveScope: Hashable {
    case piece(docId: String)
    case pieces(docIds: [String], includesBookLevel: Bool)  // the Book (true) or a Part (false), manuscript order
    case figure(id: String)
    case elsewhere(docId: String)    // a Collection piece with pieceKind == .reference
    case outside                     // an edition, the Canvas, the Inbox, the Palette
    static func of(_ faces: BinderSubject, structure: [StructureItem], projectType: ProjectType) -> ResolveScope
    var docIds: [String] { get }
}
struct ResolveSnapshot: Equatable {
    let items: [ResolveItem]
    let sequences: [String: [String]]
    let paragraphText: [String: String]   // the .piece scope's paragraphs only, for group titles and the letter
    let unreadableDocIds: [String]
}
enum ResolveReader {
    static func snapshot(scope: ResolveScope, annotations: ProjectAnnotationsSnapshot,
                         tasks: [WriterTask], findings: [String: [Diagnostic]],
                         paragraphText: [String: String]) -> ResolveSnapshot          // pure
    @MainActor static func loadFindings(scope: ResolveScope, diagnostics: DiagnosticsStore)  // .task only, never body
    @MainActor static func read(scope: ResolveScope, store: ProjectStore,
                                documentStore: DocumentStore, diagnostics: DiagnosticsStore?) -> ResolveSnapshot
}
```

**Contract:** `of` maps `.item(id)` naming a document to `.piece`, a `.reference` piece to `.elsewhere`, a group to `.pieces` over its document descendants, `.project` to `.pieces(includesBookLevel: true)` over every document (a screenplay's Book is `.piece` over its one script), `.figure(id)` to `.figure`, everything else to `.outside`. `.elsewhere` pieces contribute nothing at Book or Part scope. Only open notes and open to-dos are items. Figure notes appear at Book scope and figure scope only. `read` reads each doc's paragraphs once via `currentParagraphState` (open document, else `derivedCache`) to serve `live(currentText:)`, and registers nothing.

- [ ] **Step 1: Write the failing tests.** `test_aPieceScopeHoldsThatPiecesOpenNotesTodosAndFindings`, `test_aBookScopeHoldsEveryPieceAndTheBookLevelTodos`, `test_aPartScopeHoldsOnlyItsOwnPiecesAndNoBookLevelTodos`, `test_aCheckMintedNoteAppearsOnceAsANote`, `test_onlyASidecarStrainIsReplacedByTheNextCheck`, `test_aStrainWhoseAnchorTextChangedIsDropped`, `test_settledNotesAndDoneTodosAreNotItems`, `test_editionCanvasInboxPaletteAreOutside`, `test_aReferencePieceIsElsewhereAndAddsNothingToTheBook`, `test_aScreenplaysBookIsItsScript`, `test_aFigureScopeHoldsThatFiguresNotes`, `test_anUnreadablePieceIsNamedNotEmpty` (RULING-54), `test_readingAClosedPieceRegistersNoDocument` (fixture project, closed piece with one note and one to-do: both read; `documentStore.document(forDocId:)` stays nil), `test_noResolveSourceLoadsADocument` (census over `Maugham/Views/Resolve/` for `Document.load(`, `.load(url:`, `withAnnotationDocument`, `withStatementDocument`, with a planted offender the grep must catch).
- [ ] **Step 2: Run `./gen.sh && ./scripts/test.sh`.** Expected: the new tests fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Disable experiment.** Make `snapshot` ignore the scope's `docIds` for `.pieces`; confirm the Part test fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit** — `shell p2 task 1: To resolve reads a scope without loading a document`.

---

### Task 2: Grouping — by paragraph, by scene, by piece

**Files:**
- Create: `Maugham/Views/Resolve/ResolveGrouping.swift`, `Maugham/Views/Resolve/ParagraphOffsets.swift`
- Test: `MaughamTests/Resolve/ResolveGroupingTests.swift`, `MaughamTests/Resolve/ParagraphOffsetsTests.swift`

**Interfaces — consumes:** Task 1's types; `AnnotationQueueOrder.sorted(_:sequence:)`; `FountainScript.sceneSummaries() -> [SceneSummary]` (`line: FountainLine`, `line.range: NSRange`, `line.content`); `RenderFilter.stripTaskAnchorsInline`.

**Produces:**

```swift
struct ResolveGroup: Identifiable, Equatable {
    enum Key: Hashable {
        case bookLevel, wholePiece(docId: String), paragraph(docId: String, paragraphId: String)
        case scene(docId: String, index: Int), beforeFirstScene(docId: String)
        case removed(docId: String), piece(docId: String), figure(id: String)
    }
    let key: Key; let title: String; let items: [ResolveItem]
    var id: Key { key }
}
enum ResolveGrouping {
    static func groups(_ snapshot: ResolveSnapshot, scope: ResolveScope, structure: [StructureItem],
                       sceneIndex: [String: Int]?, sceneTitles: [String]) -> [ResolveGroup]
}
enum ParagraphOffsets {
    static func starts(sequence: [String], paragraphs: [String: String]) -> [String: Int]
    static func sceneIndex(starts: [String: Int], sceneStarts: [Int]) -> [String: Int]  // absent = before the first scene
}
```

**Contract:**
- `.piece`: `wholePiece` ("Whole chapter"; "Whole script" in a screenplay) first, then one group per paragraph in `sequence` order (title: the paragraph's text; the view truncates), then `removed` ("No longer in the text") for items whose paragraph is not in the sequence. A screenplay (`sceneIndex != nil`) groups by `scene` (title: the slugline) with `beforeFirstScene` ("Before the first scene") first.
- `.pieces`: `bookLevel` ("The book") first when included, then one `piece` group per piece in manuscript order (title: the piece's title), then one `figure` group per figure with notes. Inside a piece group: whole-piece items, then paragraph order, then removed.
- Inside any group: notes in `AnnotationQueueOrder` order, then findings, then to-dos by `priority`. Empty groups are not emitted.
- `starts` is `Document.displayRange(forParagraphId:)`'s rule: stripped text, UTF-16 lengths, a two-unit `"\n\n"` separator. Scene starts are `sceneSummaries().map { $0.line.range.location }` of the window's script (`ProjectWindow.lastParsedScript`, from the editor or `ScreenplayScriptSource`).

- [ ] **Step 1: Write the failing tests.** `test_wholeChapterLeadsThenParagraphsInManuscriptOrder`, `test_aNoteOnADeletedParagraphGroupsUnderNoLongerInTheText`, `test_aBookGroupsByPieceInManuscriptOrderWithBookLevelTodosFirst`, `test_figureNotesFollowThePiecesAtBookScope`, `test_aScreenplayGroupsByScene`, `test_paragraphsBeforeTheFirstSluglineGroupBeforeTheFirstScene`, `test_paragraphOffsetsMatchTheDocumentsDisplayRange` (a loaded fixture `Document` with a task anchor and an emoji: every `starts[pid] == displayRange(forParagraphId: pid)?.location`), `test_sceneIndexAgreesWithTheEditorsParseOfTheSameText` (parse the fixture's `displayText` with `FountainTokenizer`).
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Disable experiment.** Drop the separator's `+ 2`; confirm the parity test fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit** — `shell p2 task 2: items group by paragraph, scene or piece`.

---

### Task 3: Filters, density, the caret's group, and the keys' requests

**Files:**
- Create: `Maugham/Views/Resolve/ResolveFilter.swift`
- Test: `MaughamTests/Resolve/ResolveFilterTests.swift`

**Interfaces — consumes:** Tasks 1–2; `ReviewPass` (`id`, `name`); `store.manifest.effectiveReviewPasses`; `AnnotationOwnership.isOwn(_:localName:)`.

**Produces:**

```swift
enum ResolveSource: Hashable { case pass(String), mine, checks, questions, others }
enum ResolveKeyFilter: String, Sendable { case rounds, checks, mine, questions }
enum ResolveFilter {
    static let singleChoiceThreshold = 12
    static func source(of item: ResolveItem, localName: String) -> ResolveSource       // the table above
    static func chips(_ items: [ResolveItem], passes: [ReviewPass], localName: String) -> [ResolveSource]
    static func isDense(_ items: [ResolveItem]) -> Bool                                 // count > singleChoiceThreshold
    static func normalized(_ selection: Set<ResolveSource>, chips: [ResolveSource], dense: Bool) -> Set<ResolveSource>
    static func toggled(_ selection: Set<ResolveSource>, _ chip: ResolveSource, dense: Bool) -> Set<ResolveSource>
    static func visible(_ items: [ResolveItem], selection: Set<ResolveSource>, localName: String) -> [ResolveItem]
    static func selection(for key: ResolveKeyFilter, chips: [ResolveSource], activePassId: String?, dense: Bool) -> Set<ResolveSource>
    static func cursorGroup(paragraphId: String?, docId: String, sceneIndex: [String: Int]?, groups: [ResolveGroup]) -> ResolveGroup.Key?
    static func expanded(_ groups: [ResolveGroup], cursor: ResolveGroup.Key?, dense: Bool) -> Set<ResolveGroup.Key>
    static func clearsUnreadChecks(selection: Set<ResolveSource>) -> Bool              // empty or contains .checks
}
```

**Contract:**
- `chips`: only sources with items in scope, in the order: each pass in `effectiveReviewPasses` order, Mine, Checks, Questions, Others.
- Small list (`!dense`): any subset; empty means everything. Dense: exactly one; `normalized` keeps the first selected chip in chip order, or the first chip when none is selected. Density is counted over the scope's items, unfiltered.
- `expanded`: small list, every group; dense, the caret's group, or the first group when there is no caret group. The view adds groups the writer opens by hand.
- `selection(for:)`: `.rounds` is every pass chip (dense: the active pass's chip if present, else the first pass chip); `.checks`, `.mine`, `.questions` select that chip. A requested chip that is absent selects nothing (everything shows).
- `cursorGroup`: the caret's paragraph's group (its scene in a screenplay); `nil` with no caret.

- [ ] **Step 1: Write the failing tests.** `test_everyItemHasExactlyOneSourceInTheTablesOrder`, `test_aWritersOwnNoteDuringAPassIsMine`, `test_aCheckMintedNoteIsAChecksItemNotAPassItem`, `test_aTranslatorsQuestionIsAQuestion`, `test_chipsAreOnlySourcesWithItemsInTheColumnsOrder`, `test_twelveItemsAreNotDenseThirteenAre`, `test_aSmallListAllowsAnySubsetAndEmptyMeansAll`, `test_aDenseListKeepsExactlyOneFilter`, `test_aSmallListOpensEveryGroup`, `test_aDenseListOpensOnlyTheCaretsGroup`, `test_aDenseListWithNoCaretOpensTheFirstGroup`, `test_threeHundredNotesCollapseToTheCaretsGroup` (Review Focus 1), `test_theCaretsParagraphNamesItsSceneInAScreenplay`, `test_eachKeyRequestSelectsItsSource` (small and dense), `test_unreadChecksClearOnlyWhenChecksAreShown`.
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Disable experiment.** Compare `>=` in `isDense`; confirm the twelve test fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit** — `shell p2 task 3: filters by source; density past twelve; the caret's group`.

---

### Task 4: The verbs, lifted; act only on the open piece

**Files:**
- Create: `Maugham/Views/Resolve/ResolveVerbGate.swift`, `Maugham/Views/Resolve/ResolveNavigation.swift`, `Maugham/Views/Resolve/ResolveNoteVerbs.swift` (today's `AnnotationsPaneVerbs`, moved and renamed), `Maugham/Views/Resolve/ResolveDialogs.swift` (today's `AnnotationsPaneDialogs`, `AnnotationsPane.AnnotationTarget`, `FigureNoteTarget`), `Maugham/Views/Resolve/ResolveTaskVerbs.swift` (from `TasksPane.swift`: toggle, archive, delete, the create sheet's act, `apply(intent:dragged:in:allTasks:)`, `TaskDropIntent`, `TaskRowVerbs`, `TaskCreationScopes`, `flipInlineCheckbox`, `flipFountainTodoDone`, `archiveProjectTask`, `archiveAllDone`), `Maugham/Views/Resolve/AnnotationRowHost.swift` (one note row and its wiring, extracted from `AnnotationListView`)
- Modify: `Maugham/Views/AnnotationRow.swift` (`.onTapGesture` → `Button(.plain)` over the row's text, verb controls outside it; drop `verbsEnabled`/`verbsDisabledReason`), `Maugham/Views/AnnotationListView.swift` (`AnnotationRowWiring.onKeepAsLesson: (String, Annotation) -> Void`, no `Document`), `Maugham/Views/AnnotationsPane.swift`, `Maugham/Views/TasksPane.swift`, `Maugham/Views/DiagnosticsPane.swift` (`promote` becomes a static taking the `Document`), `MaughamTests/TripwireGrepTests.swift` (tripwire 52 classification follows the moved functions)
- Test: `MaughamTests/Resolve/ResolveVerbGateTests.swift`, `MaughamTests/Resolve/ResolveNavigationTests.swift`; re-point the existing `TaskDropIntent` and task-verb tests

**Interfaces — consumes** (verified): `AnnotationRowVerbs.decide(posture:isOwn:rulingStatement:lessons:)`; `TaskRowVerbs.decide(kind:posture:)`; `TaskCreationScopes.decide(document:project:)`; `DiagnosticsPane.offersAnAnswer(docId:posture:)`, `.offersAnAnswer(_:)`, `.offersATask(_:)`, `.commitAnswer(_:to:docId:store:world:diagnostics:)`; `DocumentStore.posture(forDocId:as:)`; `ManuscriptNavigation.docIdKey`; `QueueLedgerVerbs.keepAsLesson`.

**Produces:**

```swift
enum ResolveVerbGate {
    static func mayAct(onDocId docId: String, subject: WindowSubject, isRegistered: (String) -> Bool) -> Bool
    static func noteVerbs(_ decided: AnnotationRowVerbs, mayAct: Bool) -> AnnotationRowVerbs   // !mayAct: keepAsLesson only
    static func findingVerbs(answer: Bool, promote: Bool, mayAct: Bool) -> (answer: Bool, promote: Bool)
    static func taskVerbs(_ decided: TaskRowVerbs, mayAct: Bool, isBookLevel: Bool) -> TaskRowVerbs
}
enum ResolveNavigation {
    static func payload(for item: ResolveItem, firstParagraph: String?) -> [String: String]?
    static func go(_ item: ResolveItem, firstParagraph: String?)   // posts through MaughamEvent only
}
struct ResolveLessonTarget: Identifiable { let docId: String; let annotation: Annotation; var id: String }
```

**Contract:**
- `mayAct` is `subject.open == .item(docId)` and the document is registered. Book-level to-dos keep exactly today's verbs (the project stream needs no `Document`); figure notes keep `FigureRowGate` unchanged.
- Off the open piece a note offers Keep as lesson only (if the ledger's posture allows), a finding offers Answer only, a to-do offers nothing. Hidden, never disabled. `AnnotationScopePolicy.closedPieceReason` loses its last reader (deleted in Task 7).
- `payload` always names `doc_id` and `paragraph_id`; a whole-piece item uses the piece's first paragraph; a book-level to-do has none. A note also posts `.maughamNavigateToAnnotation` first, as today. Receivers are unchanged: `ManuscriptNavigation` opens the named piece, which is how a row on another piece opens it on that paragraph.
- The old panes now call the moved types; nothing is copied. `keepLessonSheet` holds a `ResolveLessonTarget`.

- [ ] **Step 1: Write the failing tests.** `test_aNoteOnAnotherPieceOffersOnlyKeepAsLesson`, `test_aNoteOnTheOpenPieceOffersWhatThePostureDecides`, `test_aNarrowedPostureHidesDispositionsEvenOnTheOpenPiece` (Review Focus 2: a reviewer-rung `Posture`, `mayAct` true), `test_keepAsLessonFollowsTheLedgersPosture`, `test_aFindingOnAnotherPieceOffersAnswerButNoTask`, `test_aTodoOnAnotherPieceOffersNothing`, `test_aBookLevelTodoKeepsTodaysVerbs`, `test_withTheCanvasCentredTheFacesPieceIsReadableAndUnactionable` (Review Focus 5: `open == .canvas`, `faces == .item(p)` → `mayAct` false), `test_keepAsLessonFilesForAClosedPieceWithNoDocument`, `test_aRowPayloadAlwaysNamesItsDocument`, `test_aWholePieceRowLandsOnTheFirstParagraph`, `test_aDropAcrossTwoPiecesIsRefused`.
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Move and implement.** Run `./gen.sh` after the moves.
- [ ] **Step 4: Disable experiment.** Make `noteVerbs` ignore `mayAct`; confirm a test fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit** — `shell p2 task 4: the queue's verbs move to To resolve and act only on the open piece`.

---

### Task 5: The head — where it stands, the latest letter, Run

**Files:**
- Create: `Maugham/Views/Resolve/ResolveHead.swift`
- Modify: `Maugham/Views/AnnotationsPaneStrips.swift` (the cockpit, `PassOrderNudgeRow` and the round's `letterSection` move out), `Maugham/Views/DiagnosticsPane.swift` (the check's letter host moves out), `Maugham/Views/DiagnosticsPaneHeader.swift` (its Run posts the command)
- Test: `MaughamTests/Resolve/ResolveHeadTests.swift`; re-point `ReviewRoundCockpitTests`, `AnnotationsPassOrderNudgeVerbsTests`

**Interfaces — consumes** (verified): `PassLadder(item:passes:onSet:)`, `PassLadder.offersRulings(under:)`; `DiagnosticsStore.lastCheck(docId:)`, `.lastRound(docId:)` (`CompilerRun.at`, `.letter`); `LetterSection` (`letter`, `runId`, `signature`, `currentText`, `onJump`, `onAcceptExercise: ((Letter.Habit) -> Void)?`, `onAddTurnClause`, `addToIntentTitle`, `onKeep`, …); `ReviewRoundCockpit(passes:activePassId:round:phase:reportLine:runSince:runProgress:reportTiming:onRun:onSetActivePass:onCancel:compilerModel:onCompilerModelChange:letterLine:letterDisclosure:ask:)`; `DiagnosticsPaneHeader`, `DiagnosticsDriftLine`; `MaughamEvent.postRun(_ command: RunCommand)`.

**Produces:**

```swift
enum ResolveHead {
    static func latestLetter(check: CompilerRun?, round: CompilerRun?) -> CompilerRun?  // newer `at` among non-empty letters; a tie goes to the check
    static func openPieceCount(_ items: [ResolveItem], scope: ResolveScope) -> Int       // distinct pieces; book-level and figures excluded
    static func bookLine(openPieces: Int) -> String
}
struct ResolveHeadView: View   // inputs listed in the contract
```

**Contract:**
- A piece: the derived status and `PassLadder` (`onSet` is a closure threaded from `RightColumn`, nil where `offersRulings` refuses: `PassStateWriterCensusTests` is unchanged), `PassOrderNudgeRow`, `DiagnosticsDriftLine`; then the latest letter in `LetterSection`, its `currentText` from the snapshot's `paragraphText`, `onAcceptExercise` nil unless `mayAct`; then Run: `ReviewRoundCockpit` with no letter of its own, and below it `DiagnosticsPaneHeader` (the check's reader, depth, Ask and status, the only home they have).
- Both Run buttons post `MaughamEvent.postRun` (`.runRound` / `.freshEyes`, `.checkWriting` / `.reread`), so an unopened piece gets the command's existing `.pieceWouldNotOpen` answer and no second delivery path remains. The cockpit's is hidden where `posture(forDocId:).allows(.runRound)` is false.
- Book or Part: one line, nothing else. `bookLine`: "Nothing to resolve", "1 piece has something to resolve", "N pieces have something to resolve".
- The translator's round letter is not drawn here: it is a `TranslationRound` (drawn by `TranslationRoundReportView`), not a `Letter`, it is kept per language rather than per piece, and it belongs to a piece switched to a language, which a later plan builds.

- [ ] **Step 1: Write the failing tests.** `test_theLatestLetterIsTheNewerRunWithALetter`, `test_aRunWithAnEmptyLetterYieldsToTheOther`, `test_aTieGoesToTheCheck`, `test_theBookLineCountsPiecesNotItems`, `test_bookLevelTodosAndFiguresAreNotCountedAsPieces`, `test_theHeadsRunButtonsPostTheCommands` (source census: `ResolveHead.swift` contains `postRun(` and no `runRequested(`), `test_anAcceptedExerciseIsOfferedOnlyOnTheOpenPiece`.
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 5: Commit** — `shell p2 task 5: the head — the ladder, the latest letter, Run`.

---

### Task 6: The list

**Files:**
- Create: `Maugham/Views/Resolve/ResolvePane.swift`, `Maugham/Views/Resolve/ResolveFilterBar.swift`, `Maugham/Views/Resolve/ResolveSettledSection.swift`
- Modify: `Maugham/Views/DiagnosticsPaneSections.swift` (`DiagnosticRow` becomes internal)
- Test: `MaughamTests/Resolve/ResolvePaneTests.swift`; add the filter bar to `MaughamTests/Views/RightColumnPaneWidthTests.swift`

**Interfaces — consumes:** Tasks 1–5. **Produces:** `ResolvePane(store:documentStore:subject:script:diagnostics:orchestrator:world:compilerModel:onCompilerModelChange:onSetPassState:onSetActivePass:request:)` where `request: Binding<ResolveRequest?>`, and

```swift
enum ResolveRequest: Equatable { case filter(ResolveKeyFilter), focus(groupOwnerId: String) }
struct ResolveRefreshKey: Hashable   // scope, open doc's annotationsVersion and tasksVersion,
                                     // projectTasksVersion, diagnostics.version, an event token
```

**Contract:**
- Head, filter bar, then one `ScrollView` + `LazyVStack` inside a `ScrollViewReader`. Not a `List`. Groups are sections; a collapsed group is its title and a count, and opens on click.
- Rows: a note through `AnnotationRowHost`, captioned "From the check" when its source is Checks; a finding through `DiagnosticRow`, captioned "Replaced by the next check"; a to-do through `TaskRow`. Activation is `ResolveNavigation.go`.
- Refresh: `.task(id: ResolveRefreshKey)` builds snapshot, groups and chips once into `@State`; `.onProjectEvent(.maughamAnnotationsChanged)` bumps the event token (the walk's cache is not observable, recon A.1); `.task(id: scope)` calls `loadFindings`. In a screenplay the same build computes `ParagraphOffsets.sceneIndex(starts: starts(sequence:paragraphs:), sceneStarts:)` from `script`.
- The caret: when `mayAct` on the faces' piece, `paragraphId(at: cursorLocation)` gives `cursorGroup`; `.onChange` of that key scrolls it into view and marks it. Nothing scrolls on a caret move inside one group.
- `request` is applied once and set to nil: `.filter` through `selection(for:)`, `.focus` scrolls to and opens that piece's or figure's group.
- To-do drag-reorder keeps today's `.draggable`/`.dropDestination` (they do not need a `List`), offered only when `reordersTodos` holds.
- Bulk selection and its bar as today, over the open piece's notes, only when the scope is `.piece` and `mayAct`. The New To-do button follows `TaskCreationScopes`.
- **Settled** (RULING-29, -31, -34): a collapsed section at the end, `.piece` scope and `mayAct` only, holding the open `Document`'s resolved notes (Reopen, Revert), its withdrawn notes (`withdrawnAnnotations()`, Restore) and its done to-dos.
- Empty states (tripwire 15 frames): `.outside` — "To resolve gathers what has been raised about a piece, a Part or the Book: notes, checks, to-dos and questions. Choose one in the tree."; `.elsewhere` — "This piece belongs to another project. Open that project to see what it raises."; a piece with nothing and no standing check — `DiagnosticsColdStartOffer`; otherwise "Nothing to resolve." Unreadable pieces are named in one line above the list.
- `diagnostics.markRead(docId:kind: .check)` on appear and on a selection change, when `clearsUnreadChecks`.

**Produces (pure):** `static func reordersTodos(visible: [ResolveItem], selection: Set<ResolveSource>, mayAct: Bool) -> Bool` — the selection is exactly `[.mine]`, every visible item is a to-do of one piece, and `mayAct`.

- [ ] **Step 1: Write the failing tests.** `test_todosReorderOnlyUnderMineAloneWithinOneOpenPiece`, `test_theRefreshKeyMovesOnEveryInputThatChangesTheList`, `test_aFocusRequestOpensThatPiecesGroup`, `test_theSettledSectionIsOfferedOnlyOnTheOpenPiece`, `test_anOutsideSubjectSaysWhatToResolveIsAbout`, `test_toResolveIsNotASidebarListAndNoRowTaps` (census over `Maugham/Views/Resolve/` and `AnnotationRow.swift` for `List(`, `.listStyle(.sidebar)`, `.onTapGesture`; planted control), `test_theFilterBarFitsTheColumnFloor` (mounted at 240pt, the width suite's pattern).
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Disable experiment.** Drop `.maughamAnnotationsChanged` from the key; confirm the refresh test fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit** — `shell p2 task 6: the To resolve list`.

---

### Task 7: Mounting, keys, and the three panes deleted

**Files:**
- Modify: `Maugham/Models/DetailSegment.swift` (gain `.resolve` first in `pickerOrder`, icon `tray`, help "To resolve — what has been raised and waits on you (⌘1)"; lose `.annotations`, `.diagnostics`, `.tasks`; `.diagnostics` leaves `needsADocument`), `Maugham/Views/DetailPaneToggle.swift` (the `.resolve` arm; To resolve is offered whatever the faces' piece; the unread count becomes a dot on `.resolve`), `Maugham/Views/RightColumn.swift` (threads `lastParsedScript` and `resolveRequest` to the pane), `Maugham/Views/CentreColumn.swift` (the board's open-notes click: `.resolve` and `.focus(pieceId)`), `Maugham/Views/ProjectWindow.swift` (`@State resolveRequest: ResolveRequest?` replaces `annotationScopeRequest`; the `.maughamSetDetailSegment` receiver reads the filter key), `Maugham/MaughamApp.swift`, `Maugham/Events/MaughamEvent.swift` (`resolveFilterKey`, `postResolve(_ filter: ResolveKeyFilter)` posting `.maughamSetDetailSegment`), `Maugham/Resources/KeyboardShortcuts.swift`, `Maugham/Views/Publish/TranslationRoundReportView.swift:509` (`postResolve(.questions)`), `Maugham/Stores/UIState.swift` (default and decode fallback `.resolve`), `Maugham/MCP/Tools/AnnotationCreationTools.swift:22, :175` ("Annotations pane" → "To resolve")
- Delete: `AnnotationsPane.swift`, `AnnotationsPaneQueues.swift`, `AnnotationsPaneStrips.swift`, `AnnotationsPaneStatics.swift` (survivors move to `Resolve/`), `AnnotationListView.swift`, `Review/AnnotationsQueueToolbar.swift`, `Review/AnnotationScope.swift`, `TasksPane.swift`, `TasksPaneToolbar.swift`, and `DiagnosticsPane`'s view: the type becomes `enum CheckNarrative` holding the statics its extensions declare (`DiagnosticsPaneCopy.swift`, `DiagnosticsPaneVerbs.swift` follow the rename)
- Tests: `MaughamTests/Resolve/ResolveMountingTests.swift`; re-make `DetailSegmentOrderTests`, `PaneKeyspaceTests` (its ⌘⌥P control reads `postSegment(.history)`), `DocSyncTests.test_segmentMentionCheckWouldFireOnPlantedOffender` (precondition on `history`), `WiringCensusTests` (the conformance section's entry goes), `UIStateTests`, `UIStateDetailPersistenceTests`, `ReviewBoardRoutingTests`, `TreeScrollStabilityTests`, `ResearchSubjectRevealTests` and `FigureSubjectPlacementTests` (probe segment `.history`), `AssistantColumnTests`, `DiagnosticsPaneTests` (static cases re-pointed to `CheckNarrative`; mounted ones deleted), `RightColumnPaneWidthTests` (Tasks toolbar cases go); delete `AnnotationScopeTests`, `DetailPaneToggleTasksTests`, `AnnotationsQueueToolbarWidthTests`

**Contract:**
- ⌘1: a View menu item `postSegment(.resolve)`. ⌘⌥A, ⌘⌥D, ⌘⌥T keep their keys and post `postResolve(.rounds)`, `(.checks)`, `(.mine)`. `selectDetailSegment(` keeps its count of three (`ReviewPassEditorTests`): the receiver selects `.resolve` through it and then sets `resolveRequest`.
- The figure inspector's Show notes selects `.resolve` (the figure is already the faces). `TranslationRoundReportView`'s Open queue asks for Questions.
- The plan-1 stopgap goes for To resolve only; References, Translation and History keep `needsADocument`.
- `docs/guide/` is not edited: its stale ⌘1 row already satisfies `test_everyShortcutInTheAppHasAReferenceRow`, and plan 4 rewrites the guide.

- [ ] **Step 1: Write the failing tests.** `test_commandOneSelectsToResolve`, `test_eachOldPaneKeyOpensToResolveWithItsFilter` (source census of `MaughamApp.swift`), `test_toResolveIsOfferedWhenTheFacesPieceIsNotOpen`, `test_theUnreadDotLandsOnToResolve`, `test_aRetiredSegmentDecodesToToResolve`, `test_noDeletedPaneTypeSurvives` (census: `AnnotationsPane`, `TasksPane`, `DiagnosticsPane`, `AnnotationScope`, `closedPieceReason` appear nowhere under `Maugham/`; planted control).
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement, delete, `./gen.sh`, re-make the listed tests.**
- [ ] **Step 4: Disable experiment.** Route ⌘⌥D to `.mine`; confirm a test fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit** — `shell p2 task 7: To resolve takes the right column; three panes deleted`.

---

### Task 8: The record

**Files:**
- Create: `docs/adr/0036-to-resolve.md`
- Modify: `docs/adr/README.md`, `docs/adr/0035-the-subject-not-the-persona.md` ("The right column" and "Not yet built": To resolve and the faces' store-level read are built; the stopgap now covers References, Translation and History only), `Maugham/Views/AREA.md` (map entries for `Resolve/`; deleted files out; "Add a right-column pane" recipe kept true; within its word ceiling), `Maugham/Stores/AREA.md:120`, `Maugham/Compiler/AREA.md` (where it names the deleted panes), `docs/tripwires.md` (rows naming deleted files or tests), `register/reconciliation/Annotations.claims.json` / `.filings.json` (each claim naming the old pane, the This Piece / All Pieces switch or the closed-piece reason: re-pointed or retired; list them in the handback)

**Contract:** ADR 0036 records, as built: show without loading, act only on the open piece; the source table and the two lifetimes; grouping; density at 12; the caret; the head; the keys; Settled under RULING-29/34; what was deleted; the clause-reading gap until Brief. No guide, tour or help edits.

- [ ] **Step 1: Write and sweep.** **Step 2: `./scripts/test.sh`** (doc censuses). Expected: green. **Step 3: Commit** — `shell p2 task 8: ADR 0036 and the area guides`.

---

### Task 9: The gate

- [ ] **Step 1:** `./scripts/test.sh full`. Expected: 0 failures, no skips.
- [ ] **Step 2:** `./scripts/test.sh phone`. Expected: green.
- [ ] **Step 3:** Release build (`ProjectWindow.body` changed): `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`. Expected: BUILD SUCCEEDED.
- [ ] **Step 4:** Whole-branch review of the plan-2 diff against this plan and the spec, naming the seams below.
- [ ] **Step 5:** No merge, push or tag. Report to Denver for the hand validation; write plan 3 against the built code.

---

## Seams the whole-branch review must name

1. **Task 1 × Task 6 — freshness.** A note Claude adds over MCP to a closed piece, or a check finishing on it, must appear without reopening anything: the walk's cache is not observable, so only the event token and `diagnostics.version` can carry it.
2. **Task 4 × Task 6 — the open piece.** A row click on another piece opens it; its verbs must appear once the editor registers the `Document`, and never before (no window where a press reaches a nil `Document` or a different piece's).
3. **Task 3 × Task 7 — a key's request against an unbuilt list.** ⌘⌥D on a cold window arrives before the first snapshot: the request must survive until chips exist, then normalise under density.
4. **Task 5 × Task 7 — Run and tripwire 34.** Both head buttons go through `postRun`; the check's header and the cockpit sit in one view and must each read only their own loop's reader.

## Open questions for Denver

1. Some notes are none of a pass, Mine, Checks or Questions (Claude's notes written with no pass active, a collaborator's unpassed note); under single-choice filtering they would be unreachable, so the plan adds an **Others** filter shown only when such notes exist — recommend keeping it.
2. Until Brief lands (plan 3), the check's holds/silent clause readings are not shown anywhere — recommend accepting the gap for the hand validation rather than building a clause list in To resolve that Brief would replace.

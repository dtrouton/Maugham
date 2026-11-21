# Brief, the Pulled-Up Thing and the Fold (shell plan 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The right column finished: three positions (To resolve, Brief, the pulled-up thing) selected by ⌘1/⌘2/⌘3, no pane picker; Brief shows what the faces' subject is held to, with the latest check's reading marked on the intent; one pulled-up item beside the centre; a piece's fold in the tree holds its material.

**Architecture:** Pure functions decide Brief's scope and contents (read from statements and the manifest, never a manuscript load), the clause marks, the fold's contents and grouping, and what each right-column position shows. `WindowSubject.beside` becomes the pulled-up thing (`PulledUp`), which generalises today's beside research/figure and the study column. Then the views, then the mount that deletes `DetailSegment`, `DetailPaneToggle`, the inspector and the study column, then the record and the gate.

**Tech Stack:** Swift, SwiftUI, AppKit. No new dependency. MaughamCore unchanged.

**Spec:** `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md` ("Brief", "The pulled-up thing", "The tree", "The toolbar", "Where today's surfaces go", "Constraints", "What Denver decided", "My calls"). Built on ADRs 0035 and 0036. Signatures were verified at `c2013add`. The reconnaissance (`.superpowers/sdd/plan2-recon.md` D, E, F, G) predates plan 2's build; where it and the source disagree this plan follows the source, noted inline as **(recon stale)**.

## How this plan is cut

Plan 3 of 5 on `claude/shell-without-personas`. After it the owner tries the whole window by hand. Ten tasks; Task 9 is the heaviest (the mount and every deletion) and is kept whole because the picker cannot die in halves. Every task builds final behaviour; between tasks the branch compiles and `./scripts/test.sh` is green. Views built in Tasks 4, 5 and 7 are mounted in Task 9, as plan 2 built `ResolvePane` in Task 6 and mounted it in Task 7.

**Two interim mounts, flagged for Denver (Open question 1):** until plan 4, the Department desk (`DepartmentPaneHost`) is what the To resolve position shows while an edition is the faces, and the translation review pane (`TranslationReviewPane`) is what it shows while translation review is on. Both are existing views mounted unchanged in the position the design gives their successors; nothing new is built for them.

## Global Constraints

- The hard invariants in `CLAUDE.md` stand. **No second manuscript `Document`:** nothing in `Maugham/Views/Brief/`, the fold or the pulled-up view calls `Document.load`, `withAnnotationDocument` or any transient manuscript load, or holds a manuscript `Document` beside the editor's. A statement's own `Document` (loaded by `StatementEditorHost` under `lockStatementOpen`) is not a manuscript and is the existing second-editor case.
- **Reading without loading.** Brief reads a piece's line from `StructureItem.synopsis`, its intent and decisions with `ProjectStore.statementText(of:)` (the live statement `Document` if one is open, else `derivedCache.displayText`; `ProjectStore+Statements.swift:87`), the check's reading from `DiagnosticsStore.lastCheck(docId:)` after `load(docId:)` in `.task`, and live paragraph ids with `currentParagraphState` (open document, else derived). None needs the piece's manuscript. So **Brief edits the line, the intent and the decisions of a piece that is not open**: each is a manifest write or a statement write, asked of the statement's own posture (`documentStore.posture(forDocId: StatementEditorHost.postureDocId(kind:scope:statements:))`). Plan 2's rule (manuscript verbs only on the open piece) is untouched.
- **Nothing AI-produced is drawn on the manuscript or its chrome** (constitution must-not #2, ADR 0027 §1). The clause marks are drawn only in Brief's Going for while Brief is in the right column: never in the centre cover, never on `IntentStrip`. A mark is app-drawn from one of three words and carries no model text; its tooltip is app copy.
- `EditorHost` gains no state (tripwire 6). Each editor obeys `Maugham/Editor/AREA.md` "Two editors in one window": Brief's intent editor and a pulled-up statement are `StatementEditorHost` (already a second editor); a pulled-up research note is `ResearchNoteEditor` with `isSecondEditorInItsWindow: true`. Two hosts never mount one statement: where the statement is in the centre cover, Brief and the pulled-up view draw a placeholder instead of an editor.
- Hide, don't disable; ask `Posture` (tripwires 47, 51, 52). Lock (`WindowLock.refusesEdits(isLocked:)`) covers a pulled-up research note, palette card, table and figure exactly as it covers them in the centre.
- No uncached per-row work (tripwire 4): the fold's contents are built once per `PieceFoldIndex.Key` in `.task`, the line index once per manifest change, never in a row or `body`.
- No `List(.sidebar)` row taps (tripwire 9): fold rows that are not `List` tags activate through `Button(.plain)`.
- No raw `maugham.*` notification outside `MaughamEvent` (tripwire 21). `NoPersonaCensusTests` stays green.
- Tests are pure functions, censuses or mounted measurements; never press-then-wait (tripwire 33).
- **A deleted view's tests are retired or re-made, never dropped wholesale.** Every assertion that polices behaviour that still ships moves onto the live code first (plan 2's Task 7 lost seven guards). Task 9 maps each old suite.
- Read before editing: `Maugham/Views/AREA.md`, `Maugham/Editor/AREA.md` ("Two editors in one window"), and for Tasks 6 and 9 the Annotations register filings and RULING-29, -31, -34, -54.
- `./gen.sh` after adding or deleting any file. `./scripts/test.sh` in the foreground only; never raw `xcodebuild test`, never a background gate. `./scripts/test.sh core` is not needed (MaughamCore is unchanged).
- `DocBudgetTests` word ceilings: `Maugham/Views/AREA.md` 7,985, `Maugham/Editor/AREA.md` 6,814 (both near full); every addition is paid for by a cut.
- Every commit message ends with exactly these two lines:
  ```
  Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

## Review Focus

1. **An intent edited after the check.** The marks vanish (the run's `intentSnapshot` no longer hashes to the statement text) and never land on the wrong sentence; a quote found twice marks its first occurrence only; a quote not found marks nothing. Tests in Task 1.
2. **A piece that is not open** (the Canvas in the centre, or the Book on the faces with another piece open). Brief reads and edits the line, intent and decisions with no manuscript load, and the marks arrive once the sidecar loads in `.task`. Tests in Tasks 1 and 4.
3. **One statement in two places.** The intent opened in the centre while Brief is in the right column; What I've Learned pulled up while it is also in the centre cover. Exactly one `StatementEditorHost` binds it; the other place draws a placeholder. Tests in Tasks 3 and 5.
4. **A chapter with forty things pinned to it, one of them gone.** The fold groups past six with counts; a pin whose research was trashed is dropped by `PinnedReferences`' dangling rule; a canvas card deleted while pulled up shows a missing state with Close. Tests in Tasks 2 and 7.
5. **The column at 240pt** with a 200-character pulled-up title, Lock on and a narrowed posture. The control fits (the title truncates in the middle), a pulled-up research note under Lock is read-only, a posture that refuses statement edits hides Edit and the line field. Tests in Tasks 7 and 9.

---

## What each right-column position shows

| Position (key) | Faces / state | Shows |
|---|---|---|
| To resolve (⌘1) | translation review on, faces' piece open | `TranslationReviewPane` (interim, plan 4 replaces) |
| To resolve | faces is an edition | `DepartmentPaneHost` (interim, plan 4 replaces) |
| To resolve | anything else | `ResolvePane` (unchanged from plan 2) |
| Brief (⌘2) | a piece; a Part; the Book; an edition; a Collection reference piece; anything else | piece Brief; Part Brief; Book Brief; edition Brief; "belongs to another project"; outside empty state |
| Pulled up (⌘3) | something pulled up (`subject.beside`) | that item, with its details, under `BesideHeader` (Open in Centre, Close) |
| Pulled up | nothing pulled up, the centre holds the canvas / a figure / a research item / a Collection reference piece | the centre's own details: `RegionInspectorPane`; `FigureInspector`; `ResearchSubjectInspector(showsPreview: false)`; `ReferencePieceInspector` |
| Pulled up | nothing pulled up, nothing of the above | "Nothing pulled up" empty state |

A screenplay's Book Brief is its script's Brief (ADR 0036 decision 3's rule for To resolve, applied the same way).

---

## Controller's amendments (2026-11-18, before review by Denver)

- **Backlinks are kept.** The old inspector's "Linked from" is not dropped: a piece's fold (Task 2, Task 7) lists links in both directions, outgoing and incoming, the incoming ones marked as such. The design sends "links" to the fold and does not say one direction only.
- **Tasks 4–10 are held until Denver has answered the open questions**; Tasks 1–3 are pure and do not depend on them, except Task 3's canvas-card editability (open question 4), which is built so that either answer is a one-line change.

---

### Task 1: Brief's model — scope, the line, decisions, the check's marks

**Files:**
- Create: `Maugham/Views/Brief/BriefScope.swift`, `Maugham/Views/Brief/BriefLine.swift`, `Maugham/Views/Brief/BriefDecisions.swift`, `Maugham/Views/Brief/ClauseMarks.swift`, `Maugham/Views/Brief/BriefReader.swift`
- Modify: `Maugham/Views/IntentStrip.swift` (`line(store:docId:subject:isNoChromeOn:)` returns `BriefLine.display`), `Maugham/Views/CorkboardGrid.swift:41` and `Maugham/Views/OutlineTable.swift:73` (read a line index built in `.task(id: store.manifest.modified)`; the outline column is titled "Line"), `Maugham/MCP/Tools/ProjectTools.swift:360` (the `synopsis` field carries `BriefLine.display`; its description says so)
- Test: `MaughamTests/Brief/BriefScopeTests.swift`, `BriefLineTests.swift`, `BriefDecisionsTests.swift`, `ClauseMarksTests.swift`, `BriefReaderTests.swift`

**Interfaces — consumes** (verified): `StructureItem.synopsis: String?`; `IntentStrip.line(from statementText: String?) -> String?` (the opening rule, `IntentStrip.swift:229`) and `IntentStrip.maximumLength = 90`; `StatementEssay.half(of:)`, `.carriesRulings(_:)`; `ProjectStore.statement(kind:scope:)`, `.statementText(of:) throws`, `.effectiveIntent(forDocId:)`; `RulingsStratum.rows(in:) -> [Ruling]`; `Ruling(id:text:ruledOn:provenance:)`; `LessonsLedger.kind(of:) -> .lesson | .choice | .retired(Date?)`; `DiagnosticIngest.ClauseStatus(clauseQuote:status:refs:)` (status `"holds" | "strains" | "silent"`); `CompilerRun.intentSnapshot: String?`, `.clauseStatuses`; `DerivedWorld.sourceHash(of:)` (the hash `IntentDrift.mayTrailDraft` compares); `BibleStratum.facts(for:in:)`; `ResolveScope.of(_:structure:projectType:)` (for the screenplay rule).

**Produces:**

```swift
enum BriefScope: Hashable {
    case piece(docId: String)
    case part(groupId: String, docIds: [String])      // manuscript order
    case book
    case edition(language: String)
    case elsewhere(docId: String)                      // a Collection piece with pieceKind == .reference
    case outside                                       // Inbox, Canvas, Palette, a figure, research
    static func of(_ faces: BinderSubject, structure: [StructureItem], projectType: ProjectType) -> BriefScope
}
enum BriefLine {
    static func display(synopsis: String?, intentEssay: String?) -> String?    // trimmed synopsis, else IntentStrip.line(from:)
    @MainActor static func index(store: ProjectStore) -> [String: String]     // docId → display line; `.task` only
}
struct BriefDecision: Identifiable, Equatable {
    enum Origin: Hashable { case book, piece(docId: String), lessons, firstReader, edition(language: String) }
    let ruling: Ruling
    let origin: Origin
    var id: String { get }                               // origin + ruling.id
}
enum BriefDecisions {
    static let showing = 3
    static func newestFirst(_ rulings: [Ruling]) -> [Ruling]
    static func split(_ rulings: [Ruling]) -> (showing: [Ruling], folded: [Ruling])
    static func standing(_ rulings: [Ruling], kind: Statement.Kind) -> [Ruling]
    static func origins(of decisions: [BriefDecision], structure: [StructureItem]) -> [BriefDecision.Origin]
    static func filtered(_ decisions: [BriefDecision], by origin: BriefDecision.Origin?) -> [BriefDecision]
}
struct ClauseMark: Equatable {
    enum Kind: Equatable { case strains, silent }
    let kind: Kind
    let range: NSRange            // UTF-16, in the paragraph given
    let clauseQuote: String
}
enum ClauseMarks {
    static func applies(run: CompilerRun?, statementText: String?) -> Bool
    static func marks(in paragraph: String, clauses: [DiagnosticIngest.ClauseStatus]) -> [ClauseMark]
}
struct BriefSnapshot: Equatable {
    let scope: BriefScope
    let line: String?                         // the stored synopsis, nil when empty
    let intentText: String?                   // the whole statement (nil: none yet)
    let intentEssay: String?                  // StatementEssay.half
    let decisions: [BriefDecision]            // newest first
    let bookIntentEssay: String?              // "what applies from the Book" (piece and Part only)
    let bookDecisions: [Ruling]
    let unconfirmedReadings: Int              // BibleStratum.facts(for:in:).count
    let unreadable: [String]                  // statement ids that would not read (RULING-54)
}
enum BriefReader {
    @MainActor static func read(scope: BriefScope, store: ProjectStore, bible: BibleStore?) -> BriefSnapshot
}
```

**Contract:**
- `of`: `.item(id)` naming a document → `.piece`; a `.reference` piece → `.elsewhere`; a group → `.part` over its document descendants; `.project` → `.book`, except a screenplay's Book, which is `.piece` over its script (as `ResolveScope.of` decides it); `.edition(lang)` → `.edition`; everything else → `.outside`.
- `display`: a synopsis that trims to empty is absent (`updateInspector` cannot clear to nil and stores `""`). An existing synopsis is the line with no migration.
- `newestFirst`: dated rulings by `ruledOn` descending; undated (hand-typed) after them in file order. `split`: the first `showing` and the rest. `standing` for `.lessons` drops `.retired` entries; other kinds keep all. `origins`: in the order book, pieces in manuscript order, lessons, first reader, editions by language tag; only origins that have a decision.
- `BriefReader`: `.piece` reads the piece intent (`statement(kind: .intent, scope: .document(id))`), not the effective one, plus the book intent for the quiet line; `.part` reads each child piece's intent decisions (a Part has no intent of its own); `.book` reads the book intent, and every standing decision from each piece intent, `.lessons`, `.firstReader` and each `.editionBrief(lang)` in `store.manifest.statements`; `.edition` reads `.editionBrief(language)`. A statement that throws is named in `unreadable` and never read as empty.
- `applies`: true iff `run.intentSnapshot` and `statementText` are both present and hash equal under `DerivedWorld.sourceHash(of:)`.
- `marks`: `holds` gives no mark. A quote matches if its folded form is a substring of the paragraph's folded form, where folding maps curly quotes and apostrophes to straight, collapses whitespace runs to one space, lowercases, and the quote is trimmed of surrounding quotation marks and trailing `.,;:!?`. The range is mapped back through the fold to the original paragraph's UTF-16 offsets. First occurrence only; where a strains and a silent range overlap, strains wins; an empty quote matches nothing.

- [ ] **Step 1: Write the failing tests.** `test_aDocumentIsAPieceAGroupIsAPartAndTheProjectIsTheBook`, `test_aScreenplaysBookIsItsScript`, `test_aReferencePieceIsElsewhere`, `test_theCanvasInboxPaletteAFigureAndResearchAreOutside`, `test_anExistingSynopsisIsTheLine`, `test_anEmptySynopsisFallsBackToTheIntentsOpening`, `test_noSynopsisAndNoIntentIsNoLine`, `test_theLineIndexIsBuiltOutsideBody` (census: `CorkboardGrid.swift` and `OutlineTable.swift` call `BriefLine.index(` only inside a `.task`), `test_decisionsAreNewestFirstAndUndatedLast`, `test_threeShowAndTheRestFold`, `test_aRetiredLessonIsNotStanding`, `test_theBookFilterListsOnlyOriginsThatHaveDecisions`, `test_marksApplyOnlyWhileTheIntentIsTheTextTheCheckRead` (Review Focus 1), `test_holdsIsNoMarkStrainsIsSolidSilentIsDotted`, `test_aQuoteMatchesAcrossCurlyQuotesWhitespaceAndCase`, `test_aQuoteFoundTwiceMarksOnlyTheFirst`, `test_aQuoteNotInTheParagraphMarksNothing`, `test_aRangeIsInTheParagraphsOwnUTF16Offsets` (a paragraph with an emoji before the quote), `test_strainsWinsAnOverlapWithSilent`, `test_aPartReadsItsChaptersDecisionsAndHasNoIntent`, `test_theBookGathersEveryStandingDecisionByOrigin`, `test_anUnreadableStatementIsNamedNotEmpty` (RULING-54), `test_readingAClosedPiecesBriefRegistersNoManuscriptDocument` (fixture project, closed piece with an intent and two rulings: both read; `documentStore.document(forDocId:)` stays nil) (Review Focus 2), `test_noBriefSourceLoadsAManuscriptDocument` (census over `Maugham/Views/Brief/` for `Document.load(`, `.load(url:`, `withAnnotationDocument`, with a planted offender the grep must catch), `test_theMCPListingCarriesTheLine`.
- [ ] **Step 2: Run `./gen.sh && ./scripts/test.sh`.** Expected: the new tests fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Disable experiment.** Make `applies` return true when the snapshot is present whatever its hash; confirm the Review Focus 1 test fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit.**
  ```
  shell p3 task 1: Brief's model — the scope, the line, decisions, the check's marks

  Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

---

### Task 2: The fold's contents and its grouping

**Files:**
- Create: `Maugham/Views/PieceFoldContents.swift`
- Modify: `Maugham/Views/BinderTreeSections.swift` (`BinderTreeSectionsState` gains `foldIndex: PieceFoldIndex` and `expandedFoldGroups: Set<PieceFoldGroupKey>`, neither persisted, as `expandedPieceFolds` is not)
- Test: `MaughamTests/PieceFoldContentsTests.swift`

**Interfaces — consumes** (verified): `PinnedReferenceResolver.pins(forDocId:store:projectRoot:) -> PinnedShelf` (the one assembler, `ReferencesPaneTests.test_thePinnedProjectionIsAssembledInExactlyOneProductionFile`); `PinnedShelf.sections: [PinnedSection]` (`title: String?`, `references: [PinnedReference]`); `PinnedReference.Kind` `.research(itemId:) | .palette(cardId:) | .photo(path:) | .scrap(nodeId:)`; `TreeSectionDerivation.pieceFold(for:structure:research:projectType:)` (`.contained` / `.linked` / `.none`); `ProjectStore.figureNoteOwners(_:) -> [String: String?]` over `store.manifest.figures`; `StructureItem.links: [String]?`; `store.liveCanvas?.sceneRevision`; `store.manifest.modified`.

**Produces:**

```swift
enum PieceFoldEntry: Identifiable, Equatable {
    case research(id: String, title: String, owned: Bool)   // owned: a Collection piece's own; else linked shared research
    case card(PinnedReference, regionTitle: String?)         // .scrap / .photo, or a research card bound by a region
    case palette(id: String, title: String)
    case figure(id: String, name: String)
    case link(pieceId: String, title: String)
    var id: String { get }
    var group: PieceFoldGroup { get }
}
enum PieceFoldGroup: String, CaseIterable { case research, cards, palette, figures, links }
struct PieceFoldGroupKey: Hashable { let docId: String; let group: PieceFoldGroup }
struct PieceFoldGroupRun: Equatable { let group: PieceFoldGroup; let entries: [PieceFoldEntry] }
enum PieceFoldLayout: Equatable {
    case rows([PieceFoldEntry])
    case groups([PieceFoldGroupRun])
    static let groupsAbove = 6
    static func of(_ entries: [PieceFoldEntry]) -> PieceFoldLayout
}
struct PieceFoldIndex: Equatable {
    struct Key: Hashable { let modified: Date?; let sceneRevision: Int? }
    let entries: [String: [PieceFoldEntry]]       // docId → entries, in PieceFoldGroup order
    static let empty: PieceFoldIndex
    @MainActor static func build(store: ProjectStore, projectRoot: URL) -> PieceFoldIndex
    static func entries(shelf: PinnedShelf, fold: TreeSectionDerivation.PieceFold,
                        figures: [FigureRecord], links: [String], structure: [StructureItem],
                        research: [ResearchItem]) -> [PieceFoldEntry]      // pure
}
```

**Contract:**
- Entries in group order Research, Cards, Palette, Figures, Links; within a group, shelf order (research: linked then owned, manifest order; cards: region sections in the shelf's order, then loose cards), figures by name, links in `StructureItem.links` order. A research id in both the shelf and the piece fold appears once. A link to a piece that no longer exists is dropped.
- `owned` is `fold.semantic == .contained`; a novel's linked research is `owned: false`. The two must draw differently (Task 7).
- `of`: six or fewer entries are `.rows`; past six, `.groups` holding only non-empty groups.
- `build` runs once per `Key` from the tree hosts' `.task(id:)`; never from a row or `body`.
- `BinderTreeSectionsState.foldOwner(of:)` and `reveal` keep reading `TreeSectionDerivation.pieceFold` for research ids, unchanged.

- [ ] **Step 1: Write the failing tests.** `test_entriesComeInGroupOrder`, `test_aCollectionPiecesResearchIsOwnedANovelsIsLinked`, `test_aResearchIdPinnedTwiceAppearsOnce`, `test_aCardInARegionCarriesTheRegionsTitle`, `test_aFigureOwnedByThePieceIsInItsFold`, `test_aLinkToADeletedPieceIsDropped`, `test_sixEntriesAreRowsSevenAreGroups`, `test_fortyPinsGroupWithCountsAndNoEmptyGroup` (Review Focus 4), `test_aPinWhoseResearchWasTrashedIsNotAnEntry`, `test_theIndexIsBuiltOnlyInATask` (census: `PieceFoldIndex.build(` appears only inside `.task` in `BinderView.swift` and `CollectionPiecesPane.swift`), `test_theFoldIndexKeyMovesOnAManifestOrSceneChange`.
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Disable experiment.** Change `groupsAbove` comparison to `>=`; confirm the six/seven test fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit.**
  ```
  shell p3 task 2: a piece's fold holds its material, grouped past six

  Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

---

### Task 3: The pulled-up thing and the three positions

**Files:**
- Create: `Maugham/Models/PulledUp.swift`, `Maugham/Models/RightColumnPosition.swift`, `Maugham/Views/RightColumnContent.swift`, `Maugham/Views/CentreItem.swift`
- Modify: `Maugham/Models/WindowSubject.swift` (`beside: PulledUp?`; `lastClicked`; `validated` takes the structure for `.history(docId:)`), `Maugham/Models/ClickRule.swift`, `Maugham/Views/BinderTreeSections.swift`, `Maugham/Views/FigureSubjectColumns.swift`, `Maugham/Views/ResearchSubjectColumns.swift`, `Maugham/Views/CentreColumn.swift`, `Maugham/Views/CanvasClaudeArrivalModifier.swift`, `Maugham/Views/ProjectWindow.swift`, `Maugham/Views/ResearchRevealModifier.swift`, `Maugham/Views/SubjectValidationModifier.swift`, `Maugham/Views/PaletteWallState.swift` (each reader of `.beside` asks `.treeSubject`, `.researchID` or `.figureID`), `Maugham/Views/CentreRoute.swift` (`CentreCover.centreItem(CentreItem)`; `centreRoute` gains `centreItem: CentreItem? = nil`), `Maugham/Stores/UIState.swift` (`rightColumnPosition: RightColumnPosition = .resolve`, tolerant decode; `detailSegment` stays until Task 9), `Maugham/Views/PieceFoldContents.swift` (`PieceFoldEntry.pulledUp`)
- Test: `MaughamTests/RightColumn/PulledUpTests.swift`, `RightColumnContentTests.swift`, `CentreItemTests.swift`; re-point `ClickRuleTests`, `WindowSubjectTests`, `ResearchSubjectRoutingTests`, `FigureSubjectPlacementTests`, `SubjectRestoreTests` where they build a `beside`

**Interfaces — consumes** (verified): `WindowSubject(open:faces:beside:besideIsLatest:)`, `.lastClicked`, `.validated(structure:researchIDs:figureIDs:editionLanguages:)`; `ClickRule.resolve(_:gesture:current:structure:projectType:)`, `.navigate(to:current:structure:projectType:)`; `ProjectWindow.researchSubjectPlacement(subject:)`, `.figureSubjectPlacement(subject:)`, `.openingBesideInCentre(_:structure:projectType:)`, `.closingBeside(_:)`; `CentreCover` cases; `ProjectWindow.centreRoute(subject:bookView:projectType:structure:preview:proposal:round:problems:)`; `PinnedReference.Kind`; `Statement.Kind`, `Statement.Scope`.

**Produces:**

```swift
public enum PulledUp: Hashable, Codable, Sendable {
    case research(String)              // a note, a table or a palette card: a research item
    case figure(String)
    case canvasScrap(nodeId: String)
    case canvasPhoto(path: String)
    case lessons, firstReader, visualLanguage
    case history(docId: String)
    public init?(treeSubject: BinderSubject)     // .research, .figure; nil otherwise
    public var treeSubject: BinderSubject? { get }
    public var researchID: String? { get }
    public var figureID: String? { get }
}
public enum RightColumnPosition: String, Codable, CaseIterable, Sendable {
    case resolve, brief, pulledUp
    var systemImageName: String { get }   // "tray", "target", "pin"
    var helpText: String { get }          // "To resolve — what has been raised and waits on you (⌘1)",
                                          // "Brief — what this is held to (⌘2)",
                                          // "Pulled up — the one thing you pulled up from the tree (⌘3)"
    var keyEquivalent: Character { get }  // "1", "2", "3"
}
public enum PullUpRequest: String, CaseIterable, Sendable { case lessons, firstReader, visualLanguage, historyOfTheFaces }
enum CentreDetails: Equatable { case canvas, figure(String), research(String), referencePiece(String) }
enum RightColumnContent: Equatable {
    case resolve, translationReview, desk(language: String)
    case brief(BriefScope)
    case pulledUp(PulledUp)
    case centreDetails(CentreDetails)
    case nothingPulledUp
    static func of(position: RightColumnPosition, subject: WindowSubject, translationLanguage: String?,
                   structure: [StructureItem], projectType: ProjectType) -> RightColumnContent
    static func centreDetails(_ subject: WindowSubject, structure: [StructureItem],
                              projectType: ProjectType) -> CentreDetails?
    static func positionAfterSubjectChange(_ position: RightColumnPosition, from old: WindowSubject,
                                           to new: WindowSubject, previousFace: RightColumnPosition,
                                           structure: [StructureItem], projectType: ProjectType) -> RightColumnPosition
    static func pulledUp(for request: PullUpRequest, subject: WindowSubject) -> PulledUp?
    static func facesForTheStrip(_ subject: WindowSubject, structure: [StructureItem]) -> WindowSubject
}
extension PieceFoldEntry {
    var pulledUp: PulledUp? { get }   // .research/.palette → .research(id); a scrap or photo card → .canvasScrap / .canvasPhoto;
                                      // a research card → .research(id); nil for .figure and .link
}
enum CentreItem: Equatable { case statement(kind: Statement.Kind, scope: Statement.Scope), history(docId: String) }
extension ProjectWindow {
    static func openingInCentre(_ item: CentreItem, subject: WindowSubject) -> WindowSubject
    static func centreItemAfterOpenChange(_ item: CentreItem?, from old: BinderSubject, to new: BinderSubject) -> CentreItem?
    static func statementIsInTheCentre(kind: Statement.Kind, scope: Statement.Scope, centreItem: CentreItem?) -> Bool
}
```

**Contract:**
- `beside` keeps every rule it has (persists across subject changes until closed; only a change writes it; `besideIsLatest`); its type widens. `lastClicked` is `beside.treeSubject` when `besideIsLatest` and the pulled-up item is a tree row, else `faces`. `ClickRule` writes `.research(id)` as today and compares through `PulledUp(treeSubject:)`. `validated` drops a `.history(docId:)` whose piece is gone and keeps canvas, statement items (a missing canvas node is the pulled-up view's empty state, Task 7). A persisted subject whose `beside` will not decode as `PulledUp` decodes with `beside == nil` (no migration, tripwire 11).
- `RightColumnContent.of` is the table above, exhaustive. `.desk` when `subject.faces` is `.edition(lang)`; `.translationReview` when `translationLanguage != nil` and `faces == open` names a piece.
- `positionAfterSubjectChange`, first matching rule: a new, different non-nil `beside` → `.pulledUp`; `beside` cleared while `.pulledUp` is shown and the new subject has no centre details → `previousFace`; faces moved onto `.canvas` → `.pulledUp`; otherwise unchanged. (This replaces `revealResearchColumn`'s segment write and plan 1's "leaving an edition takes the desk" rule, which has nothing left to coerce.)
- `pulledUp(for:)`: `.historyOfTheFaces` is `.history(docId:)` of the faces' piece, else of the open piece, else nil (the key is then inert).
- `facesForTheStrip`: the line above the prose is about `open`; a click on it sets `faces = open` when `open` is a piece, so Brief shows that piece.
- `openingInCentre`: `.statement(.intent, .document(id))` and `.history(id)` set `open = faces = .item(id)`; every other statement sets `open = faces = .project`. The centre item is drawn as a cover over the editor route; a publish cover wins while it stands. `centreItemAfterOpenChange` clears the item on any later change of `open`.

- [ ] **Step 1: Write the failing tests.** `test_aResearchAndAFigureRoundTripThroughTheTreeSubject`, `test_aStatementOrHistoryPulledUpIsNotWhatTheTreeSelects`, `test_lastClickedIgnoresAPulledUpStatement`, `test_clickingTheRowPulledUpPutsItAway`, `test_aPulledUpThingPersistsAcrossSubjectChanges`, `test_aSubjectSavedByPlan2StillDecodes` (a `windowSubject` JSON with `"beside":{"research":{"_0":"r1"}}` in today's encoding decodes to `.research("r1")`, or to nil if the encoding differs; never throws), `test_historyOfAPieceThatIsGoneIsPutAway`, `test_eachPositionShowsWhatTheTableSays` (every row of the table), `test_theDeskShowsOnlyWhileAnEditionIsTheFaces`, `test_translationReviewShowsOnlyOnTheOpenPiece`, `test_pullingSomethingUpMovesTheColumnToIt`, `test_closingItReturnsToTheFaceBefore`, `test_closingItOverTheCanvasKeepsTheCanvasDetails`, `test_clickingTheCanvasRowShowsItsDetails`, `test_historyKeyPullsUpTheFacesPieceElseTheOpenOne`, `test_theStripClickPutsTheFacesOnTheOpenPiece`, `test_openingTheIntentInTheCentreOpensItsPiece`, `test_aCentreItemClearsWhenTheCentreMoves`, `test_aPublishCoverWinsOverACentreItem`, `test_aFoldEntryPullsUpWhatItNames` (Task 2's `pulledUp`), `test_aRetiredPositionDecodesToToResolve`.
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.** Run `./gen.sh`.
- [ ] **Step 4: Disable experiment.** Make `lastClicked` return `faces` always; confirm the canvas-light test in `ClickRuleTests` (re-pointed) fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit.**
  ```
  shell p3 task 3: what is beside becomes the pulled-up thing; three positions decided

  Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

---

### Task 4: Brief for a piece and a Part

**Files:**
- Create: `Maugham/Views/Brief/BriefPane.swift` (the scope switch; this task fills `.piece`, `.part`, `.elsewhere`, `.outside`), `Maugham/Views/Brief/BriefPieceView.swift`, `Maugham/Views/Brief/GoingForView.swift`, `Maugham/Views/Brief/BriefDecidedSection.swift`, `Maugham/Views/Brief/BriefPartView.swift`
- Modify: `Maugham/Views/BibleStratum.swift` (the button reads "Confirm", the design's word; the verb is unchanged)
- Test: `MaughamTests/Brief/BriefPaneTests.swift`, `MaughamTests/Brief/GoingForTests.swift`

**Interfaces — consumes:** Task 1; Task 3's `CentreItem`, `statementIsInTheCentre`; `StatementEditorHost(store:documentStore:kind:scope:posture:)`; `StatementEditorHost.postureDocId(kind:scope:statements:)`, `.locksEditing(_:)`; `RulingsStratumView(rulings:kind:scope:store:world:posture:liveParagraphIds:)`; `BibleStratumView(facts:scope:store:bible:world:posture:)`; `ProjectStore.updateInspector(id:synopsis:...)`; `DiagnosticsStore.load(docId:)`, `.lastCheck(docId:)`, `.version`; `MarkdownBlockParser.parse(_:)`; `currentParagraphState(documentId:store:documentStore:projectURL:)`.

**Produces:**

```swift
struct BriefPane: View {
    init(store: ProjectStore, documentStore: DocumentStore, scope: BriefScope,
         diagnostics: DiagnosticsStore?, bible: BibleStore?, world: DeclaredWorldStore?,
         centreItem: CentreItem?,
         onOpenInCentre: @escaping (CentreItem) -> Void,
         onPullUp: @escaping (PulledUp) -> Void,
         onShowStrain: @escaping (_ docId: String, _ clauseQuote: String) -> Void,
         onOpenBrief: @escaping (BinderSubject) -> Void)
}
enum GoingForMode: Equatable { case reading, editing, inTheCentre }
extension GoingForView {
    static func mode(hasMarks: Bool, editingRequested: Bool, inTheCentre: Bool, hasIntent: Bool) -> GoingForMode
    static let strainsHelp = "The draft pulls against this"        // app copy; no model text
    static let silentHelp = "Nothing in this draft touches it"
}
```

**Contract:**
- **A piece, in fixed order.** (1) The line: one `TextField` ("A line for the cards and the outline — optional") writing `updateInspector(id:synopsis:)` on commit, hidden under a posture that refuses `.editStatement` on the piece intent, else always editable (today's inspector gates nothing; the posture gate is new and matches the statements beside it). (2) **Going for**: `.reading` when the latest check's marks apply (`ClauseMarks.applies`) and at least one mark exists — the essay's paragraphs drawn as `Text(AttributedString)` with strains underlined solid and silent underlined `.patternDot`, an "Edit" button beside the heading; otherwise `.editing`, the `StatementEditorHost` for `(.intent, .document(id))` in place (an empty intent is an empty editor that mints on first keystroke, as today). Leaving the editor returns to `.reading` only if marks still apply (after an edit they do not). `.inTheCentre` when `statementIsInTheCentre`: a line "Open in the centre" and nothing else (Review Focus 3). Open in Centre is a header button calling `onOpenInCentre(.statement(kind: .intent, scope: .document(id)))`. A strains mark is a link (`OpenURLAction` on a `maugham-mark:` URL carrying the mark's index); its click calls `onShowStrain(docId, clauseQuote)`. A silent mark shows its help and goes nowhere: nothing in To resolve corresponds to it. (3) **Decided**: `BriefDecisions.split`; the showing ones and, under a "N earlier" disclosure, the rest, drawn by `RulingsStratumView` (so edit/revoke/orphan behave as today). (4) Two quiet lines, each a disclosure that opens in place: "From the book" (the book intent's essay and the book's decisions, read-only here; hidden when both are empty) and "What Claude has read" (count; opens `BibleStratumView` for the piece scope; hidden when zero).
- **A Part**: no Going for. Each child piece with decisions as a section titled with the piece's title (a button: `onOpenBrief(.item(id))`), its decisions newest first; then "From the book".
- **Elsewhere**: "This piece belongs to another project. Its brief is that project's." **Outside**: "Brief holds what a piece, a Part, the Book or an edition is held to. Choose one in the tree." (tripwire 15 frames).
- Refresh: `.task(id:)` keyed on the scope, `store.manifest.modified`, the scope's statement ids' `derivedCache` tokens through `statementText`, `diagnostics.version` and `bible.version`; `diagnostics.load(docId:)` in `.task(id: scope)`; never in `body` (tripwire 4).

- [ ] **Step 1: Write the failing tests.** `test_aPieceBriefDrawsLineGoingForDecidedThenTheQuietLines` (mounted, order read off the accessibility tree), `test_goingForReadsWithMarksOnlyWhileTheyApply`, `test_anEditedIntentShowsTheEditor`, `test_theIntentInTheCentreLeavesAPlaceholderNotASecondEditor` (Review Focus 3: one `StatementEditorHost` mounted across centre cover and Brief), `test_aMarkCarriesNoModelText` (census: `GoingForView.swift` draws marks from `ClauseMark.Kind` and the two help constants only; no `clauseQuote` reaches a `Text`), `test_aStrainsMarkAsksForItsFinding`, `test_aSilentMarkGoesNowhere`, `test_theLineFieldHidesUnderARefusingPosture`, `test_aClosedPiecesIntentIsEditable` (Review Focus 2: mounted with the piece not open; the host binds the statement; `documentStore.document(forDocId:)` stays nil), `test_threeDecisionsShowTheRestFold`, `test_aPartGathersItsChaptersDecisions`, `test_theQuietLinesHideWhenEmpty`, `test_bibleReadingsSayConfirm`, `test_outsideAndElsewhereSayWhatBriefIsAbout`.
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.** Run `./gen.sh`.
- [ ] **Step 4: Disable experiment.** Make `mode` ignore `inTheCentre`; confirm the Review Focus 3 test fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit.**
  ```
  shell p3 task 4: Brief for a piece and a Part, with the check's reading on the intent

  Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

---

### Task 5: Brief for the Book and an edition; a statement in the centre

**Files:**
- Create: `Maugham/Views/Brief/BriefBookView.swift`, `Maugham/Views/Brief/BriefEditionView.swift`, `Maugham/Views/CentreItemCover.swift`
- Modify: `Maugham/Views/Brief/BriefPane.swift` (`.book`, `.edition` arms), `Maugham/Views/CentreColumn.swift` (draws `.centreItem` over the editor route: `StatementPane(store:documentStore:kind:subject:bible:world:)` for a statement, `HistoryPane(...)` for history, under a header with Close), `Maugham/Views/ProjectWindow.swift` (`@State centreItem: CentreItem?`, passed to `centreRoute`; `.onChange(of: subject.open)` applies `centreItemAfterOpenChange`)
- Test: `MaughamTests/Brief/BriefBookTests.swift`, `MaughamTests/Brief/BriefEditionTests.swift`, `MaughamTests/RightColumn/CentreItemCoverTests.swift`

**Interfaces — consumes:** Tasks 1, 3, 4; `StatementPane(store:documentStore:kind:subject:bible:world:)` (memberwise; `StatementPane.swift:33-49`); `HistoryPane(projectURL:activeDocId:allDocIds:device:session:docPaths:documentStore:)`; `EditionStatus.translatorName(for:in:)`, `.readerName(for:in:)`, `.collatorName(for:in:)`; `DepartmentPaneHost.sourceLanguage(imprint:in:pieceIDs:)` and `PublishConfigStore.read(in:)` (read in `.task`, as `TreeEditionRows` does); `StatementProposalStore(projectURL:).pending(for: .visualLanguage)` and `.maughamStatementProposalsChanged`.

**Contract:**
- **The Book**: Going for is the book intent's editor (`(.intent, .project)`) with Open in Centre; no marks (a check reads per piece). Decided is every standing decision (`BriefSnapshot.decisions`) under one filter menu: All, The book, one item per piece that has decisions (in manuscript order), What I've Learned, First Reader, one item per edition language; the choice is remembered for the life of the view. Each decision row names its origin in a caption. Then three lines that pull up: "What I've Learned" (`onPullUp(.lessons)`), "First Reader" (`.firstReader`), "Visual Language" (`.visualLanguage`, with a dot while a visual-language proposal is pending, the dot the picker carried). Then "What Claude has read" for `.project`.
- **An edition**: the edition brief through `StatementPane(kind: .editionBrief(language), subject: .project)` (its essay, its rulings and the glossary they hold), then the cast as read-only lines (translator, reader, collator by name; changing them stays on the desk), then "Visual Language" pulling up. The source edition has no brief: it shows "The source edition is the book itself." and the Visual Language line.
- **The centre cover**: one `StatementEditorHost` per statement (Review Focus 3): when the cover holds a statement, the Brief and the pulled-up view draw "Open in the centre" for it. Close clears `centreItem`; any change of `open` clears it.

- [ ] **Step 1: Write the failing tests.** `test_theBooksBriefIsItsIntentThenEveryStandingDecision`, `test_theFilterOffersEachOriginThatHasADecision`, `test_aDecisionNamesWhereItWasMade`, `test_theThreeBookStatementsPullUp`, `test_theVisualLanguageLineCarriesTheProposalDot`, `test_anEditionsBriefIsItsBriefGlossaryCastAndVisualLanguage`, `test_theSourceEditionHasNoBrief`, `test_theCastIsReadNotWritten` (census: `BriefEditionView.swift` contains no `DepartmentCastSheet(` and no manifest write), `test_aStatementInTheCentreIsACoverOverTheEditor` (route test: `EditorHost` keeps its mount), `test_closingTheCoverOrMovingTheCentreClearsIt`, `test_whatIveLearnedPulledUpAndInTheCentreBindsOnce` (Review Focus 3).
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.** Run `./gen.sh`.
- [ ] **Step 4: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 5: Commit.**
  ```
  shell p3 task 5: Brief for the Book and an edition; a statement opens in the centre

  Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

---

### Task 6: Answering moves an item across; To resolve's carries

**Files:**
- Create: `Maugham/Views/Brief/FiledUnder.swift` (the sentence and `FiledNotice`, a one-line view)
- Modify: `Maugham/Views/Resolve/ResolvePane.swift` (`ResolveRequest` gains `.focusFinding(docId: String, clauseQuote: String)`; a `@State filedNotice` shown under the head; the bulk bar over the open piece's notes inside a Book or Part list), `Maugham/Views/Resolve/ResolveListDecisions.swift` (the focus key for a finding), `Maugham/Views/Resolve/CheckNarrativeVerbs.swift`, `Maugham/Views/Resolve/ResolveNoteVerbs.swift`, `Maugham/Views/Resolve/ResolveHead.swift` (letter verbs report their filing), `Maugham/Views/QueryRuling.swift`, `Maugham/Views/FirstReaderRuling.swift`, `Maugham/Views/QueueLedgerVerbs.swift`, `Maugham/Views/TurnClauseOffer.swift`, `Maugham/Views/Publish/TranslationRoundReportView.swift` (Make it a rule shows its notice on the report), `Maugham/Views/Brief/BriefPieceView.swift` (Confirm shows its notice)
- Test: `MaughamTests/Brief/FiledUnderTests.swift`; add to `MaughamTests/Resolve/ResolvePaneTests.swift`

**Interfaces — consumes** (verified): `CheckNarrative.commitAnswer(_:to:docId:store:world:diagnostics:) async -> String?` (files `(.intent, .document(docId))`; `CheckNarrativeVerbs.swift:174`, **(recon stale: was `DiagnosticsPane.commitAnswer`)**); `QueryRuling.commit(_:answering:in:store:undoManager:) async -> String?` (`.editionBrief(language)`); `FirstReaderRuling.commit(...)` (`.firstReader`); `QueueLedgerVerbs.keepAsLesson(_:from:store:world:) async -> String?` and `.makeChoice(...)` (`.lessons`); `TurnClauseOffer.handler(letter:run:docId:store:world:voice:filedRunId:postureOf:onFiled:onFailure:)` (destination `TurnClauseOffer.scope(store:docId:)`); `TranslationRoundActions.makeRule: (TranslationRound, String) async -> Outcome` (`.editionBrief`); `BibleStratum.bless(_:forScope:store:bible:world:)`; `ResolveRequest` (`.filter`, `.focus(groupOwnerId:)`); `ResolveVerbGate.mayAct(onDocId:subject:isRegistered:)`; `AnnotationsBulkBar`.

**Produces:**

```swift
struct FiledDestination: Equatable { let kind: Statement.Kind; let scope: Statement.Scope }
enum FiledUnder {
    static func sentence(_ destination: FiledDestination, faces: BinderSubject,
                         structure: [StructureItem], projectType: ProjectType,
                         firstReaderName: String?) -> String
    static let lingers: Duration = .seconds(6)
}
```

**Contract:**
- Sentences: the faces' own piece intent → "Filed under this chapter's intent" (the noun is the one To resolve's whole-piece group uses for the project type: chapter, script, piece); another piece's → "Filed under “<title>”'s intent"; `(.intent, .project)` → "Filed under the book's intent"; `.lessons` → "Filed under What I've Learned"; `.firstReader` → "Filed under <name>'s instructions" ("Filed under First Reader" with no name); `.editionBrief(lang)` → "Filed under the <Language> edition brief" (the language's display name, as `QueryRuling.confirmation(language:)` spells it).
- Each verb that files — Answer (a finding, a translator's query, a first reader's note), Add to intent, Keep as lesson, a choice, Make it a rule, Confirm — reports its `FiledDestination` on success; nothing else about the verb changes. The notice is shown where the verb was pressed (To resolve under the head; the round report under the row's section; Brief under the quiet line) for `lingers` or until the next verb, and outlives the row the next read removes. Where the destination is in the faces' own Brief, the notice is a button that selects Brief (Task 9 wires the position; until then the button posts nothing and is hidden).
- `.focusFinding` opens the group holding the finding whose `clauseQuote` matches, on that piece; if none matches (answered, dismissed, or dropped when its anchor text changed) it selects the Checks filter on that piece's group. Applied once and set to nil, like the other requests.
- In a Book or Part list that holds the open piece, the bulk bar is offered over the open piece's notes (`mayAct` true for them only), as at piece scope (carried from plan 2).

- [ ] **Step 1: Write the failing tests.** `test_aFindingsAnswerSaysItFiledUnderThisChaptersIntent`, `test_answeringFromTheBookNamesThePiece`, `test_eachDestinationHasItsSentence` (every `Statement.Kind` the verbs file to), `test_aScreenplaySaysScript`, `test_theNoticeOutlivesTheRow` (pure: the notice's lifetime is independent of the snapshot), `test_everyFilingVerbReportsWhereItFiled` (census over the six verb files: each success path hands a `FiledDestination` to its caller), `test_aStrainFocusOpensItsFindingsGroup`, `test_aStrainWithNoFindingFallsBackToChecks`, `test_theBulkBarIsOfferedOverTheOpenPieceInsideABookList`, `test_theBulkBarNeverActsOnAPieceThatIsNotOpen`.
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Disable experiment.** Make `sentence` ignore `faces`; confirm the from-the-Book test fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit.**
  ```
  shell p3 task 6: answering says where it filed; a strain mark finds its item

  Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

---

### Task 7: The fold in the tree, and the pulled-up view

**Files:**
- Create: `Maugham/Views/PulledUpView.swift` (moves `BesideHeader` here from `RightColumn.swift`)
- Modify: `Maugham/Views/BinderPieceFold.swift` (draws `PieceFoldLayout`), `Maugham/Views/BinderView.swift:247-275` and `Maugham/Views/CollectionPiecesPane.swift:238-262` (the fold shows when the index has entries; `.task(id: PieceFoldIndex.Key)` builds the index), `Maugham/Views/TreeSectionDerivation.swift` (doc comments only; `pieceFold` stays the research source), `Maugham/Views/ResearchNoteEditor.swift` (`var isSecondEditor: Bool = false` → `EditorSurfaceConfiguration.isSecondEditorInItsWindow`), `MaughamTests/TripwireGrepTests.swift` (`editorSurfaceMountSites` comment: `ResearchNoteEditor.swift` is primary in the centre and second when pulled up)
- Test: `MaughamTests/RightColumn/PulledUpViewTests.swift`, `MaughamTests/BinderPieceFoldTests.swift` (re-made)

**Interfaces — consumes:** Tasks 2, 3; `ResearchSubjectInspector(store:itemID:showsPreview:figureTree:figureWritesRefused:documentStore:readOnly:shareIsReadOnly:typography:window:presence:)`; `ResearchNoteEditor(store:documentStore:path:itemId:previewVisible:lockEditing:shareIsReadOnly:)`; `ProjectWindow.researchCentreRoute(id:in:)` (`.paletteCard`, `.note`, `.table`, `.preview`, `.missing`); `PaletteCardSurface.of(readOnly:)`; `FigureSubjectSurface(...)`, `FigureInspector(...)` (as `RightColumn.figureSubject` builds them today); `StatementPane(...)`; `HistoryPane(...)`; `ImagePreview` and the scrap text read `AssistantColumn.subject(for:store:projectRoot:)` does today; `CanvasModel.reveal(.node(CanvasNodeID(_:)))`; `ClickRule.resolve(_:gesture: .openInCentre, ...)`; `ProjectWindow.closingBeside(_:)`; `ResearchTreeNode(...)` as `BinderPieceFold` mounts it.

**Produces:** `PulledUpView(store:documentStore:subject:centreItem:canvasModel:editorControl:figureListing:figureGridPresence:figureWindows:window:isLocked:figureTree:bible:world:onOpenInCentre:)` with `subject: Binding<WindowSubject>`, `onOpenInCentre: (CentreItem) -> Void`; and `static func title(of: PulledUp, store: ProjectStore) -> String`.

**Contract:**
- **The fold.** `.rows`: each entry a row; `.groups`: one disclosure per group titled "Research (n)", "Cards (n)", "Palette (n)", "Figures (n)", "Links (n)", expansion in `expandedFoldGroups`. Research rows keep `ResearchTreeNode` (a `List` tag, `.research(id)`), with owned rows as today and linked rows drawn with a `link` glyph, secondary title colour and the help "Linked from Research" (the novel/collection difference). Card and palette rows are `Button(.plain)` that write `subject.beside` (the click rule's dismissal applies: a second click on the row pulled up puts it away). Figure rows select `.figure(id)` (a figure takes the centre). Link rows navigate (`ClickRule.navigate(to: .item(id))`) and offer Remove Link in their menu. The chevron shows only when the index has entries for the piece.
- **The pulled-up view.** Under `BesideHeader(title:openInCentre:close:)` (title truncates in the middle):
  - `.research(id)`: by `researchCentreRoute` — a note is `ResearchNoteEditor(isSecondEditor: true, lockEditing: WindowLock.refusesEdits(isLocked:))` above `InspectorResearchPanel` (its citation and versions); a palette card is `PaletteCardEditor`/`PaletteCardReadHost` by `PaletteCardSurface`; a table is the grid (read-only under Lock); a preview kind is `ResearchPreview`. Never the item the centre shows (the placement's existing rule).
  - `.figure(id)`: `FigureSubjectSurface` over `FigureInspector` (its uses), as today.
  - `.canvasScrap` / `.canvasPhoto`: read-only (the scrap's words; the photo); Open in Centre opens the canvas and calls `canvasModel.reveal(.node(...))` for a scrap; a node no longer on the canvas shows "This card is no longer on the canvas." with Close (Review Focus 4).
  - `.lessons`, `.firstReader`, `.visualLanguage`: `StatementPane(kind:, subject: .project)`; Open in Centre is `onOpenInCentre(.statement(kind:, scope: .project))`; while the cover holds it, the placeholder line.
  - `.history(docId:)`: `HistoryPane` for that piece, open or not (fewer verbs when closed; it reads the `Document` optionally, `HistoryPane.swift`); Open in Centre is `onOpenInCentre(.history(docId:))`.

- [ ] **Step 1: Write the failing tests.** `test_aFoldWithSevenEntriesShowsGroupsWithCounts`, `test_linkedResearchLooksDifferentFromOwned` (the linked row carries the `link` glyph and help; the owned row does not), `test_aCardRowPullsTheCardUpAndASecondClickPutsItAway`, `test_aLinkRowGoesToThePiece`, `test_noFoldRowUsesATapGesture` (census over `BinderPieceFold.swift`, planted control), `test_anEmptyFoldHasNoChevron`, `test_aPulledUpNoteIsASecondEditor` (the mounted note's surface has `usesPrivateUndoManager` true), `test_aPulledUpNoteIsReadOnlyUnderLock` (Review Focus 5), `test_aPulledUpPaletteCardFollowsLock`, `test_aMissingCanvasCardSaysSoAndCloses`, `test_historyPullsUpForAClosedPiece` (closes plan 1's stopgap for History), `test_aPulledUpStatementInTheCentreDrawsThePlaceholder`, `test_everyPulledUpKindHasOpenInCentre`, `test_theTitleTruncatesInTheMiddle`.
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.** Run `./gen.sh`.
- [ ] **Step 4: Disable experiment.** Pass `isSecondEditor: false` from `PulledUpView`; confirm `test_aPulledUpNoteIsASecondEditor` fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit.**
  ```
  shell p3 task 7: the fold holds the piece's material; the pulled-up view

  Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

---

### Task 8: The old inspector, dispersed

**Files:**
- Create: `Maugham/Views/PieceTargetMenu.swift` (the format labels move here from `PieceInspector.swift:6-34`), `Maugham/Views/PieceRowMenus.swift` (Tags…, Add Link…, Publishing ▸)
- Modify: `Maugham/Views/EditorStatusFooter.swift` (the right label is a menu: the piece's word target, or page target for a screenplay), `Maugham/Views/ProjectWindow.swift:1287` (passes the open piece and the store), `Maugham/Views/OutlineTable.swift` (a Tags column), `Maugham/Views/BinderView.swift:326` and `Maugham/Views/CollectionPiecesPane.swift:188` (the row menus gain the three items), `Maugham/Views/Resolve/ResolveHead.swift` (the "whose piece this is" line under the ladder, from `PieceWriters.read` in `.task(id: store.url)`), `Maugham/Views/Publish/InspectorPublishSection.swift` (its body is reused by the Publishing submenu's sheet; renamed `PiecePublishSettings`)
- Test: `MaughamTests/PieceTargetMenuTests.swift`, `MaughamTests/PieceRowMenusTests.swift`; re-point `InspectorPublishSectionTests`

**Interfaces — consumes** (verified): `ProjectStore.updateInspector(id:synopsis:tags:wordTarget:pageTarget:links:) async throws` (targets: 0 → nil; tags and links: empty → nil); `GoalIndicatorState` (`docWordTarget`, `pageTarget`, `isScreenplay`); `EditorStatusFooter.rightLabel(for:)`; `InspectorTagsField(tags:...)`; `InspectorLinksSection`'s add-link search (moved into the menu's sheet); `PieceWriters.read(projectURL:pieces:)`, `.sentence(for:)`, `.rowTitle`; `PermitControl.pieces(in:)`; `TreeStructureVerbs` (`structureVerbs(for:)`).

**Contract:**
- **Targets** live on the status line under the text: the right label opens a menu offering "Set Word Target…" (prose) or "Set Page Target…" (screenplay) with the old stepper's range and step, and "Clear Target". The footer shows only with the editor, so a target is set on the open piece.
- **Tags**: a Tags column in the Outline view (comma-joined, read) and "Tags…" in the piece's row menu (a sheet with `InspectorTagsField`).
- **Links**: "Add Link…" in the row menu (the inspector's search, as a sheet); links show and are removed in the fold (Task 7). Backlinks ("Linked from") are not carried: the design names links only. Recorded in ADR 0037.
- **Publishing**: "Publishing…" in the row menu opens `PiecePublishSettings` (the inspector's publish section, unchanged) in a sheet. Its permanence is Open question 2.
- **Whose piece this is**: To resolve's head, under the ladder, only where `PieceWriters` draws a sentence (today's rule).
- **Project Settings…** is already in the app menu (`MaughamApp.swift:241`); nothing moves.
- Every new menu item is offered by the row's existing `TreeStructureVerbs` (hidden, never disabled). `PassStateWriterCensusTests` gains no file.

- [ ] **Step 1: Write the failing tests.** `test_theFooterOffersAWordTargetForProseAndAPageTargetForAScript`, `test_clearingATargetStoresNil`, `test_theOutlineHasATagsColumn`, `test_theRowMenuOffersTagsLinksAndPublishingWhereTheVerbsAllow`, `test_aRefusingPostureHidesTheMenuItems`, `test_whoseLineIsInTheHeadOnlyWhereThereAreSeveralWriters`, `test_noRowMenuItemWritesAPassState` (census).
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.** Run `./gen.sh`.
- [ ] **Step 4: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 5: Commit.**
  ```
  shell p3 task 8: targets to the status line, tags to the outline, links and publishing to the row

  Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

---

### Task 9: The right column finished — three positions, the keys, the picker deleted

**Files:**
- Create: `Maugham/Views/RightColumnControl.swift`
- Modify: `Maugham/Views/RightColumn.swift` (the body is the control over `RightColumnContent.of`'s arm; the roster, bible and world environment move with it; `researchOrSubject`, `inspectorPane`, `collectionInspector` go; `BesideHeader` already moved), `Maugham/Views/ProjectWindow.swift` (`@State rightColumnPosition`, `previousFace`; `selectPosition(_:showInspector:position:)` replaces `selectDetailSegment`; the receivers; restore reads `uiState.rightColumnPosition`; `openPromotedArtifact`'s statement marks: intent → Brief, the three book statements → pulled up; `openFirstReaderIfRequested` pulls up First Reader; the translation-review flip selects `.resolve`), `Maugham/Events/MaughamEvent.swift` (`postPosition(_:)`, `postPullUp(_:)`, `postResolve(_:)` posting the position; `postDetailSegment` and `detailSegmentKey` go), `Maugham/Models/MaughamNotifications.swift` (`maughamSetRightColumn`, `maughamPullUp`), `Maugham/MaughamApp.swift` (⌘1/⌘2/⌘3 and the ⌘⌥ map below), `Maugham/Resources/KeyboardShortcuts.swift`, `Maugham/Stores/UIState.swift` (`detailSegment` removed), `Maugham/Views/IntentStrip.swift` (click: `facesForTheStrip`, then Brief), `Maugham/Views/DiagnosticsPaneSections.swift:84` (the drift line selects Brief), `Maugham/Views/PostureStandingLine.swift:185` (pulls up History), `Maugham/Views/CentreColumn.swift:388`, `Maugham/Views/CanvasClaudeArrivalModifier.swift:180`, `Maugham/Views/ResearchSubjectColumns.swift:140-146` (`revealResearchColumn` goes; `positionAfterSubjectChange` decides), `Maugham/Views/ResearchRevealModifier.swift`, `Maugham/Views/WindowEscapeArbiter.swift` (`.assistantColumn` becomes `.pulledUp`: Esc closes the pulled-up thing while its position shows), `Maugham/Canvas/CanvasEventView.swift`, `Maugham/MCP/Tools/StatementProposalTools.swift:23,27,109` and `Maugham/MCP/Tools/VisualLanguageTools.swift:55` (where things are now: the Book's Brief, Visual Language pulled up (⌘⌥V); the desk while an edition is open)
- Delete: `Maugham/Models/DetailSegment.swift`, `Maugham/Views/DetailPaneToggle.swift`, `Maugham/Views/InspectorView.swift`, `Maugham/Views/PieceInspector.swift`, `Maugham/Views/IntentAffordanceRow.swift`, `Maugham/Views/InspectorLinksSection.swift`, `Maugham/Views/AssistantColumn.swift`, `Maugham/Views/ReferencesPane.swift` (keep `PinnedReferenceResolver`)
- Test: `MaughamTests/RightColumn/RightColumnMountingTests.swift`; the suites mapped below

**Interfaces — consumes:** Tasks 1–8; `ResolvePane(store:documentStore:subject:script:diagnostics:orchestrator:world:compilerModel:onCompilerModelChange:onSetPassState:onSetActivePass:request:)` and its `var` closures; `DepartmentPaneHost(store:documentStore:projectURL:subject:translator:runLog:designer:pipeline:onShowProposal:onShowRound:onShowProblems:onCompileSettled:)` and `TranslationReviewPane(document:control:store:coldCall:documentStore:projectURL:model:world:)` (mounted unchanged, as `DetailPaneToggle` mounts them at HEAD); `RegionInspectorPane(...)` as `RightColumn.canvasInspector` builds it; `ReferencePieceInspector(store:pieceId:)`; `DetailPaneToggle.unreadDocId(subject:store:)`'s rule and `DiagnosticsStore.unreadCount(docId:kind:)` (the dot moves to the control).

**Contract:**
- **The control**: three segments in one row — To resolve (`tray`), Brief (`target`), and the pulled-up segment (`pin` plus `PulledUpView.title`, truncated in the middle, when something is pulled up; the icon alone otherwise). It fits 240–480pt (icons only below the width where the title fits). A dot (never a number) on To resolve while the faces' checks are unread; on Brief while a visual-language proposal is pending. The control holds no shortcut (`PaneKeyspaceTests`).
- **Keys** (Open question 3): ⌘1 To resolve, ⌘2 Brief, ⌘3 the pulled-up position. ⌘⌥A, ⌘⌥D, ⌘⌥T unchanged (To resolve on Rounds, Checks, Mine). ⌘⌥I and ⌘⌥N select Brief. ⌘⌥G, ⌘⌥Y, ⌘⌥V pull up What I've Learned, First Reader, Visual Language. ⌘⌥H pulls up the faces' piece's History. ⌘⌥E opens the faces' piece's fold in the tree and scrolls to it. ⌘⌥L and ⌘⌥K select To resolve (the translation review and the desk show there). Every key reveals a hidden column, as today. `selectPosition(` has two call sites (the declaration aside): the position receiver and the strip/drift hand-off through it; `pullUp(` names its own.
- **Carried from plan 1, closed here:** History works for a piece that is not open (Task 7); References is the fold (Task 7, a store-level read); Translation shows only in translation review, where its piece is open by definition. `needsADocument` has nothing left to gate and goes with `DetailSegment`.
- **Test mapping** (every suite that names a deleted type; nothing is deleted before its live guards are moved):
  - `DetailSegmentOrderTests` → retired; its live rules re-made in `RightColumnContentTests` (Task 3) and `RightColumnMountingTests`: the one order (positions' `allCases`), the desk only with an edition, a requested position lands under every subject, every position and pull-up has a menu shortcut (reads `MaughamApp.swift`), the unread dot lands on To resolve.
  - `PaneKeyspaceTests` → keep all four checks, re-pointed at `RightColumnControl.swift`; its ⌘⌥P anchor reads the Tasks item's `postResolve(.mine)`.
  - `DocSyncTests` → `test_detailSegmentCasesDocumentedInRightPaneMd` re-pointed at `RightColumnPosition.swift` with a named pending list `["pulledUp"]` (the guide is rewritten in plan 5): it asserts the pending list is exactly the cases the guide lacks, so it goes red when the guide gains it; its planted-offender test re-pointed; the `>= DetailSegment.allCases.count` floors become a named list of the View menu's ⌘⌥ letters at HEAD.
  - `DetailPaneColumnHeightCensusTests`, `RightColumnPaneWidthTests` → walk every `RightColumnContent` arm through the mounted `RightColumn` (planted offenders kept); add the control with a 200-character pulled-up title at 240, 280 and 480 (Review Focus 5).
  - `TripwireGrepTests` → the `DetailPaneToggle.swift` shape census is re-pointed at `RightColumn.swift`; `test_mountSnapCallSitesCensus` and its planted twin retire (positions are always offered, nothing snaps); `editorSurfaceMountSites` keeps three files with `ResearchNoteEditor.swift` now setting the flag when pulled up.
  - `WiringCensusTests` → entries re-pointed: `selectPosition(`'s three tokens, the position receiver, `openFirstReaderIfRequested` pulling up, the strip and drift line posting the position, the roster entry (`@Environment(AgentRoster.self)`, `{ roster?.designer }`, `designer: designer`) moved to where the desk is mounted.
  - `AssistantColumnTests`, `StudyColumnMountTests`, `ReferencesPaneTests` (pane rows) → re-made in `PulledUpTests`, `PulledUpViewTests` and `BinderPieceFoldTests`: a pin pulls up its item, Esc closes it, a pull-up reveals the column, the dead-width-key decode test stays in `UIStateTests`; the projection census stays.
  - `ResearchSubjectRevealTests`, `FigureSubjectPlacementTests`, `CanvasClaudeBannerTests` (`detailSegment = .inspector` token) → `positionAfterSubjectChange` and the position token.
  - `ReviewPassEditorTests` → the one-spelling test counts `selectPosition(`.
  - `InspectorViewTests`, `InspectorPassLadderTests`, `InspectorIntentAffordanceTests`, `PostureSurfaceTests` (inspector cases; drop its dead line, plan 2's parked minor), `PassStateWriterCensusTests` (the file list loses `InspectorView` and `PieceInspector`; never widened), `SubjectValidationTests`, `ProjectKindSitePinsTests`, `CompilerRunCommandTests` → each assertion moved to its new home: the ladder's posture pins to `ResolveHead`, the synopsis to Brief's line (Task 4), the intent affordance to Brief's empty Going for, the reference piece to the centre's details, the links section to the row menu (Task 8).
  - `UIStateTests`, `UIStateDetailPersistenceTests`, `SubjectRestoreTests`, `BinderSubjectTests` → `rightColumnPosition` round-trips; a file carrying `detailSegment` decodes and ignores it.
  - `StatementPaneTests`, `StatementMountFixture`, `StatementDraftHandoffTests`, `StatementPaneSelectionDeliveryTests`, `StatementImageIngestTests`, `TreeScrollStabilityTests`, `ProjectAltitudePaneTests`, `ReviewRoundCockpitTests`, `TranslatorEnvironmentTests`, `AnnotationsPassOrderNudgeVerbsTests`, `RegionBindingTests`, `ResolveMountingTests`, `ResolveNavigationTests`, `PalettePaneTests`, `IntentStripTests`, `DiagnosticsPaneTests`, `TestSupport/SourceTree.swift` → mount through `RightColumn` with a position instead of `DetailPaneToggle` with a segment; assertions unchanged.

- [ ] **Step 1: Write the failing tests.** `test_commandOneTwoThreeSelectThePositions`, `test_eachOldPaneKeyLandsWhereTheMapSays` (source census of `MaughamApp.swift`), `test_theControlFitsAt240WithALongTitle` (Review Focus 5), `test_theUnreadDotLandsOnToResolve`, `test_theProposalDotLandsOnBrief`, `test_theStripOpensTheOpenPiecesBrief`, `test_aStatementMarkOpensBriefOrPullsUp`, `test_escapeClosesThePulledUpThing`, `test_noDeletedTypeSurvives` (census: `DetailSegment`, `DetailPaneToggle`, `InspectorView`, `PieceInspector`, `IntentAffordanceRow`, `AssistantColumn`, `ReferencesPane`, `postDetailSegment`, `selectDetailSegment` appear nowhere under `Maugham/`; planted control), `test_theRightColumnShowsWhatTheContentTableSays` (mounted, one probe per arm).
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement, delete, `./gen.sh`, re-make the mapped suites.**
- [ ] **Step 4: Disable experiment.** Bind ⌘⌥H to Brief; confirm the key-map census fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh` and `./scripts/test.sh full`.** Expected: green, no skips beyond the baseline.
- [ ] **Step 6: Commit.**
  ```
  shell p3 task 9: the right column is three positions; the pane picker and the inspector are gone

  Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

---

### Task 10: The record and the gate

**Files:**
- Create: `docs/adr/0037-brief-and-the-pulled-up-thing.md`
- Modify: `docs/adr/README.md`; `docs/adr/0035-the-subject-not-the-persona.md` and `docs/adr/0036-to-resolve.md` ("Not yet built" and "The right column": what plan 3 built; ADR 0036's MCP `add_note` → the four creation tools `add_comment`, `add_suggested_change`, `add_query`, `add_craft_note`, and "outlines" → "draws selected" — plan 2's parked minors); `Maugham/Views/AREA.md` (map entries for `Brief/`, `PulledUpView`, `RightColumnControl`, `RightColumnContent`; the deleted files out; the recipe "Add a right-column pane" replaced by "Add something to pull up"; within 7,985 words); `Maugham/Editor/AREA.md` ("Two editors in one window": a pulled-up research note; within 6,814); `Maugham/Compiler/AREA.md`, `Maugham/Publish/AREA.md`, `Maugham/Stores/AREA.md` where they name the deleted panes or `postDetailSegment`; `CLAUDE.md:165` (the Models row names `RightColumnPosition` and `PulledUp`, not `DetailSegment`); `docs/constitution.md:50` (the honest note's "a right-pane mode for every `DetailSegment` case" becomes the three positions); `docs/tripwires.md` rows naming deleted files or tests; `register/reconciliation/Annotations.claims.json` (the three claims still saying "the pane"), both register JSON files' final newline (plan 2's parked minor), and every claim or filing that names the Inspector, the Intent pane, References or the study column (`OpLog`, `Promotion`, `Rewind.verification`): re-pointed or retired, listed in the handback.

**Contract:** ADR 0037 records, as built: the three positions and the content table; Brief per scope and what it reads without loading; what Brief edits for a piece that is not open (the line, the intent, the decisions, Confirm: no manuscript `Document` is needed); **the clause marks, ruled by Denver on 2026-11-16 to be within constitution must-not #2: app-drawn from one of three words, no model text, only while Brief is in the right column, never in the centre or on the line above the prose; plan 5's amendment to ADR 0027 §1 cites this ADR**; the snapshot rule and the first-occurrence rule; the filing sentences; the pulled-up thing (what it holds, that it persists until closed, Open in Centre for each kind, the research note as a second editor, canvas cards read-only); the fold; the inspector's dispersal (backlinks not carried); the keys; the two interim mounts (desk, translation review) and plan 4 replacing them; the decisions made during the build. No guide, tour or help edits.

- [ ] **Step 1: Write and sweep.**
- [ ] **Step 2: `./scripts/test.sh`** (doc censuses, `DocBudgetTests`). Expected: green.
- [ ] **Step 3: Commit.**
  ```
  shell p3 task 10: ADR 0037 and the area guides

  Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```
- [ ] **Step 4: The gate.** `./scripts/test.sh full` (0 failures, no skips beyond the baseline); `./scripts/test.sh phone` (green); the Release build (`ProjectWindow.body` changed): `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED.
- [ ] **Step 5: Whole-branch review** of the plan-3 diff against this plan and the spec, naming the seams below.
- [ ] **Step 6:** No merge, push or tag. Report to Denver for the hand validation.

---

## Seams the whole-branch review must name

1. **Task 3 × Tasks 7 and 9 — every reader of `beside`.** The tree's outline, the canvas's lit region (`lastClicked`), the research reveal, Claude's Show (it clears `beside`), the palette wall's close (writes `beside` only on a change), validation on load. A pulled-up statement or History must never become what the tree selects or the canvas lights.
2. **Tasks 4, 5 and 7 — one statement, one host.** Brief's intent, the centre cover and a pulled-up statement can name the same statement; `StatementEditorHost.gateArrival` refuses a second binding, so the placeholder must be decided before mount, never discovered by a refusal.
3. **Task 6 × plan 2's refresh — the notice and the row.** An answered finding leaves on the next read; the notice must outlive it, and an Answer from a Book list must name the piece, not "this chapter".
4. **Task 2 × Task 7 — the fold index and the tree.** Built once per key; a research note dragged into a fold, a card bound on the canvas and a figure's owner changing each move the key; `reveal`/`foldOwner` still find research.
5. **Task 1 × Task 4 × ADR 0027 §1 — where marks may appear.** Only Brief's reading view; `IntentStrip` keeps its String-and-Bool input; the centre cover draws no marks.
6. **Task 9 — the deleted guards.** Each mapped suite's live assertions survive somewhere; the reviewer checks the mapping list line by line against the diff.

## Hand-check list for the owner (plans 1–3)

**The subject (plan 1)**
1. Open a novel. Click a chapter in the tree: it opens in the centre. Click the Book row: Cards, Outline or Status shows. Click a chapter there: it opens.
2. Click Canvas, then a chapter in the tree: the canvas stays, its region lights, and the right column is about the chapter.
3. With the canvas open, click a slugline in a screenplay's Scenes: the script opens on that scene, first click.
4. Look at the tree's two states: the row open in the centre (tinted) and the row you last clicked (selected). Say if the fill should be on the open row instead.
5. Turn Lock on (toolbar). Try to edit a research note, a palette card and a table: refused. Typing in the chapter still works (Lock does not lock the manuscript text; say if it should).
6. ⌘R runs a check; ⌃⌘R runs a round. While a round runs, read the two "is running" lines and say if the wording is right.
7. Put a capture in the Inbox: its row shows one dot. Confirm there is no drag from a capture onto the canvas in one window (Send to Canvas remains).
8. Ask Claude to Show a canvas region while a note is pulled up: the note is put away and the region's details show.

**To resolve (plan 2)**
9. ⌘1 on a chapter with notes, a check's findings and to-dos: one list, "Whole chapter" first, then by paragraph; move the caret and the list follows.
10. On the Book, click a row for another chapter: that chapter opens in the centre and the Book's list stays; its rows gain their verbs. Its bulk bar is offered (new in plan 3).
11. With more than twelve items, the filters become one-at-a-time and only the caret's group is open.
12. Mark notes Do / Discuss / Decline; the triage control appears and names its choice; declined notes stay in the list.
13. Stet a note: it stays for a moment, offering Reopen only, then leaves.
14. Run a round and watch notes arrive: no stutter; the list turns dense at the thirteenth.
15. Look at the head: one model menu; no Check Writing button (⌘R is the check). Say if you want the button back.
16. A note on another chapter: its click lands on the paragraph, not the exact words.
17. On a translation round report, press Open the queue: the round's chapter opens with Questions selected.
18. In a shared book, change someone's standing and look at a closed chapter's notes on the Book's list: say if the old verdict lingering until the next change matters.

**Brief, the pulled-up thing, the fold (plan 3)**
19. ⌘2 on a chapter: the line, Going for, Decided, then "From the book" and "What Claude has read". Type a line; it shows on the card, in the outline and above the prose. Clear it; the opening of the intent shows instead.
20. Run a check, then ⌘2: sentences the draft pulls against are underlined solid, ones it says nothing about dotted. Click a solid one: To resolve opens on that finding. Edit the intent: the marks go until the next check.
21. Answer a finding in To resolve: it says "Filed under this chapter's intent", and the answer is under Decided in Brief.
22. Keep a letter's habit as a lesson, Add to intent, Make it a rule on a round report, and Confirm something Claude has read: each says where it filed.
23. ⌘2 on the Book: the book's intent and every decision, filterable by where it was made; open What I've Learned, First Reader and Visual Language from it.
24. ⌘2 on a Part (its chapters' decisions) and on an edition (its brief, glossary, cast and Visual Language).
25. Open the intent in the centre from Brief; write at length; close it.
26. With the canvas open, click a chapter and edit its intent and line in Brief without opening the chapter.
27. Open a chapter's fold in the tree: its research, cards, palette cards, figures and links; past six, groups with counts. In a novel the research is marked as linked; in a collection it is the piece's own.
28. Click a research note in the fold: it is pulled up beside the chapter and you can edit it; with Lock on, you cannot. Click a card: it shows read-only, with Open in Centre.
29. Change chapters: the pulled-up thing stays until you close it (Close or Esc). Pull up History (⌘⌥H) for a chapter that is not open.
30. Narrow the right column to its minimum with a long-titled note pulled up: the three positions still fit; the title shortens in the middle.
31. The word target is on the status line under the text; tags are a column in the Outline view and in a chapter's right-click menu; links and Publishing… are in that menu.
32. Try each old ⌘⌥ key and say whether it lands where you expect (see Open question 3).
33. Bind a canvas region to a chapter: the chapter's fold shows it as one row with a count, its chevron opening to its cards top to bottom; click the row and the region is pulled up, its scraps in full, pictures at column width, notes as titles you can click.
34. Pictures show thumbnails: a picture on the canvas bound to a chapter (and one inside a region), and an image in Research, show a small picture in the tree in place of the photo glyph, with rows no taller than their neighbours; a PDF still shows its glyph. Photo captures in the Inbox (and in its Trash) show a larger one. Replace an image file in Finder, then fold and unfold: the new picture shows.
35. **The faces, named:** with the canvas open, click a chapter. To resolve and Brief each start with the chapter's title; click the Book, a Part and an edition and the line follows (an edition reads "Spanish edition"). The pulled-up position has no such line: its header names its item.
36. **A chapter that is not open:** with the canvas open, click a chapter with notes. To resolve's head reads "Open this chapter to answer its notes" as a link; click it: the chapter opens and its notes gain Accept, Reject and Answer. On the Book's To resolve, each chapter group that is not open has the same line under its heading; click one: the chapter opens and the Book's list stays.
37. **The control's names:** with nothing pulled up, the control reads "To resolve" and "Brief" in words at every column width. Pull a long-titled note up and narrow the column: the names go back to icons before the note's title does.
38. **⌘3 with nothing pulled up:** the empty state says how to pull something up (a note, card, region or figure in a piece's fold; ⌘⌥G, ⌘⌥Y, ⌘⌥V, ⌘⌥H). Try one of the keys it names.
39. **The View menu:** the right column's items are in three groups (To Resolve…, Brief…, Pull Up…) behind dividers, then the tree's (Open the Piece's Fold, Research, Palette, Outline, Inbox). ⌘⌥0 reads "Hide Right Column" when it shows and "Show Right Column" when it does not. ⌘⌥I puts the cursor in the chapter's line; ⌘⌥N in Going for's editor (after a check, it opens the editor over the marks). ⌘⌥K on a chapter says "No edition is selected…" in To resolve; select an edition and ⌘⌥K shows the desk.
40. **Lock:** View ▸ Lock Research and Figures (⌘⌥⇧L) flips the toolbar padlock, and the menu item then reads "Unlock Research and Figures". Hover the padlock: its tooltip says your manuscript stays editable. Type in the chapter while locked: it still takes your words.
41. **A covered pulled-up note:** pull a note up, open the canvas, select a region. The column shows the region's details under a slim line "<note's title> is pulled up" with Show it; press it: the region is deselected on the canvas and the note is back.
42. **History is findable:** right-click a chapter in the tree that is NOT the one in the centre: the menu ends with History; choose it: that chapter's History is pulled up, not the open chapter's. ⌘2 on a chapter: History is the last line of its Brief; on the Book, History pulls up the project's.
43. **Details:** ⌘2 on a chapter with no target and no tags: Details reads "Set a target" and "Add tags"; each opens the same sheet the row menu's Target… and Tags… open. Set both: Details shows "Word target: 2,000" and "Tags: …". With publishing set up, "Publishing settings" opens Publishing…. With the canvas or the sidebar hidden (⌘\ focus), the sheets still open. In a screenplay, the script's Details shows the page target.
44. **The proposal notice:** have Claude propose a visual language. The Brief segment's dot shows; every Brief (a chapter, a Part, the Book, an edition) opens with "Claude proposed a visual language. Pull it up to adopt or discard."; the link pulls Visual Language up. Adopt or discard it: the notice and the dot go together.
45. **Going for grows:** paste five paragraphs into a chapter's Going for. The editor grows to hold them and the column scrolls; there is no scroll bar inside the editor. Type at the end of a long intent: the column follows the cursor. Scroll the column with the pointer over the editor: it scrolls. The button beside the heading reads "Open in Centre".
46. **Decided before anything is filed:** ⌘2 on a new chapter: "Decided" shows with "What you answer in To resolve is filed here." Answer a note in To resolve: the line gives way to the answer. A new Book's Brief says the same.
47. **The empty fold:** ⌘2 on a chapter with nothing in its fold: the foot of its Brief says to drag a research note onto it in the tree or set a canvas region's Piece to it. Do the first: the line goes and the fold shows the note. In a short story with no research, the line says adding research instead.
48. **A figure in a fold:** click a figure in a chapter's fold: it is pulled up beside and the chapter stays in the centre, with To resolve and Brief still about the chapter. Click it again: it is put away. Double-click it: it opens in the centre, and nothing is left beside. Click the same figure in the tree's Figures section: it opens in the centre, as before.
49. **Double-click in a fold:** with the canvas closed, double-click a scrap, a picture and a region in a chapter's fold, one at a time: the canvas opens with that item selected each time, and nothing flickers or stays beside. Double-click a palette card in a fold: it opens in the centre.
50. **Back:** pull up a region, click a note's title inside it: the note replaces the region, and an arrow shows at the left of its header ("Back to <the region>" on hover). Press it: the region is back. Pull up three things in a row and press Back twice: you walk back through them; at the first, the arrow is gone. Close what is pulled up and press ⌘[: it comes back. Delete a note you pulled up earlier: Back skips it. View ▸ Pull Up Previous is greyed when there is nothing to go back to.
51. **The centre's details under a pulled-up note:** open a figure in the centre and pull a note up. Above the note, one line reads "Details of <the figure's name>", closed. Open it: the figure's details share the column with the note. Change chapters and come back to the figure: still open. Do the same with a research item and (in a Collection) a reference piece in the centre. With nothing pulled up, the figure's details fill the position as before.
52. **Claude's cards in a closed canvas:** pull up a canvas region bound to a chapter, close the canvas, and ask Claude to add cards to that region: the region beside shows the new cards at the same moment the chapter's fold does. The same for a pulled-up card's words.
53. **Details with the tree out of sight:** open Find in Project (it replaces the tree), then use a chapter's Brief Details lines: the Tags, Target, Add Link and Publishing sheets open. The same with the sidebar hidden.
54. **The tree's left edge lines up:** in a novel with research linked to a chapter, a card and an edition, look down the tree's left edge: a chapter's fold triangle, Research's chevron and Palette's sit in one column, and the words "Research", "Palette" and "Editions" start at one x, all three in the same small grey bold. Close and reopen Research and Palette: nothing moves sideways. Click Palette's title: the row turns accent-filled, its title and triangle read white, and the wall opens. Click Palette's triangle: the cards fold and the centre stays put. A note under Research, a card under Palette and English under Editions start level with each other, right of the titles; the two `+` buttons end at one x. In a Collection, the same against a piece's triangle.
55. Smoke: launch → New project → Novel → "Smoke" → type a sentence → ⌘Q → relaunch → open from Recents → sentence intact.

## Open questions for Denver

1. Until plan 4 builds the edition's faces and the piece-in-a-language view, should the Department desk show in the To resolve position while an edition is selected, and the translation review pane there while translation review is on? I recommend yes: both are today's views mounted unchanged where their successors will go, and without them publishing and translation review have no home for your hand-check.
2. Per-piece publishing settings (table of contents, start on) go to the edition's Status view in plan 4; until then, should they be "Publishing…" in a piece's right-click menu? I recommend yes, and keeping that menu item after plan 4 as the per-piece twin of the Status column.
3. The ⌘⌥ keys: I recommend ⌘⌥A/D/T open To resolve on Rounds/Checks/Mine (as now), ⌘⌥I and ⌘⌥N open Brief, ⌘⌥G/Y/V pull up What I've Learned/First Reader/Visual Language, ⌘⌥H pulls up History, ⌘⌥E opens the piece's fold in the tree, and ⌘⌥L and ⌘⌥K open To resolve (where translation review and the desk show) — do you want any of these different?
4. A canvas card pulled up beside the text: I recommend read-only there with Open in Centre to edit it on the canvas (a card's words live in the canvas's shared text, which a second editor beside the manuscript would put at risk), with research notes and palette cards editable beside as you decided — is that right?

# The Subject Takes Over (shell plan 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the four personas and make the tree's subject the one thing that decides what the window shows.

**Architecture:** Every question the code asks of `Persona` today is re-asked of two values: the window's subject (what is open, what the right column is about, what is open beside) and a Lock flag. `Persona`, its bar, its memory, its modifier, its event and its keys are deleted outright, not adapted. The right column's pane picker is left as it is, with one membership, and is replaced wholesale in plan 2.

**Tech Stack:** Swift, SwiftUI, AppKit. No new dependency.

**Spec:** `docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md`. Read "The model", "The tree", "The centre, by subject", "The toolbar" and "Constraints" before any task.

## How this milestone is cut

Denver's ruling (2026-11-16): slices exist only where validation needs them; no interim design. So:

- **One branch, `claude/shell-without-personas`, merged only when the whole design is built.** `main` stays releasable for hardening fixes.
- **Every task builds final behaviour.** Nothing is built to be replaced, and nothing is adapted to coexist with personas. Between tasks the branch may be odd to use; it must compile and pass the gate.
- **Plans, each written against the code the last one left:**
  1. *This plan.* The subject replaces the persona: routing, tree rows, click rule, Lock, Run.
  2. The right column: To resolve (the real merged, paragraph-grouped, cursor-following list), Brief, the pulled-up thing, the fold. `DetailSegment` and the old panes are deleted. ⌘1–3.
  3. Status views, scope at Book, Part and edition, the translation surfaces, round letters kept per piece.
  4. The margin setting and the ADR 0027 amendment, the guide, tour and help, the final sweep.
- **Denver validates twice by hand:** after plan 2 (the first point the window is the new thing) and at the end. No smoke script is owed for this plan.

## Global Constraints

- The hard invariants in `CLAUDE.md` stand. No change to manuscripts, the op log, permits, posture, or the phone.
- `EditorHost` and the canvas keep one mount each and their identities across every subject change (`Maugham/Views/AREA.md`, "The centre column"; tripwires 6, 27, 30).
- Hide, don't disable; ask `Posture` (tripwires 47, 51).
- No uncached per-row work in tree rows (tripwire 4); no `.onTapGesture` in a sidebar list (tripwire 9).
- No raw `maugham.*` notification outside `MaughamEvent` (tripwire 21).
- Read `Maugham/Views/AREA.md` before editing under `Maugham/Views/` or `Maugham/Models/`; read the claims filings under `register/` for any module you change behaviour in.
- Run `./gen.sh` after adding or deleting any source or test file. Use `./scripts/test.sh`, never raw `xcodebuild test`.
- A test never presses a mounted control then waits (tripwire 33). Routing is tested as pure functions.
- No migration of stored UI state. Old keys are ignored on decode.
- Retire or re-make a persona test; never patch one to keep its name.

## Review Focus

1. **A project saved by today's build** (UI state carrying `persona` and `personaMemory`, and a `selectedSubject`) opens on the same piece with nothing lost and no error. Test in Task 1.
2. **Clicking a piece while the Canvas or an edition is the centre** must not replace the centre; the faces move to that piece. Clicking a piece while the Book's Cards or Outline is the centre must open it. Tests in Task 1.
3. **A subject that names something deleted or on another device** (a removed piece, a language with no translation left) falls back to the Book, never to an empty centre. Tests in Tasks 1 and 3.
4. **A read-only share, a narrowed book, or a piece owned by someone else** still locks by posture with Lock off, and Lock on never unlocks anything. Test in Task 5.
5. **⌘R with no project window in front, or with the Canvas, an edition or the Inbox as the centre**, is a no-op or runs on the faces' piece; it never runs a round. Test in Task 5.

---

## What the persona decides today, and what asks instead

This table is the contract for Tasks 2, 5 and 6. Each left-hand name is a member of `Persona` (`Maugham/Models/Persona.swift`) or a function taking `persona:`.

| Today | Asked of | Answer |
|---|---|---|
| `centresTheCanvas` | subject | `open == .canvas` |
| `showsManuscriptDocuments` | subject | `open` is a piece, a Part or the Book |
| `previewsThePublishedBook` | subject | `open` is `.edition` |
| `showsTheReviewBoard` | Book view | `bookView == .status` while `open` is the Book or a Part |
| `showsPaletteWall` + `showsPaletteWall` window state | subject | `open == .palette` |
| `showsIntentStrip` | subject | `open` is a piece |
| `showsExports` | nothing | The Exports footer shows whenever publishing is initialised |
| `studiesPinnedReferences` | nothing | Always true |
| `editsResearchInTheCentre`, `editsFigures` | Lock | `!isLocked` |
| `panes`, `defaultPane`, `coerce`, `PersonaMemory` | nothing | One order, `DetailSegment.pickerOrder`; one remembered segment |
| `RunKind.of(persona:)`, `RunMenuTitles` | the command | Each command names its kind |
| `researchSubjectPlacement`, `figureSubjectPlacement` | click rule | Research opens beside; a figure takes the centre; double-click takes the centre |
| `treeTravelDestination`, `paletteWallDoorTravels`, `ManuscriptNavigation.destination(from:)` | click rule | No travel exists; going to a paragraph sets `open` to its piece |
| `inspectorRoute(persona:)`, `editorRoute(persona:)` | subject | As `centresTheCanvas` above |

---

### Task 1: The subject model and the click rule

Pure types and functions. Nothing is wired.

**Files:**
- Modify: `Maugham/Models/BinderSubject.swift`
- Create: `Maugham/Models/WindowSubject.swift`, `Maugham/Models/ClickRule.swift`, `Maugham/Models/BookView.swift`
- Modify: `Maugham/Stores/UIState.swift`
- Test: `MaughamTests/ClickRuleTests.swift`, `MaughamTests/WindowSubjectTests.swift`; extend `MaughamTests/BinderSubjectTests.swift`, `MaughamTests/UIStateTests.swift`

**Interfaces — produces:**

```swift
// BinderSubject gains four cases. Existing accessors return nil for them.
case inbox
case canvas
case palette
case edition(language: String)   // the source language is an edition too

public enum BookView: String, Codable, Sendable, CaseIterable { case cards, outline, status }

public struct WindowSubject: Equatable, Codable, Sendable {
    public var open: BinderSubject      // what the centre shows
    public var faces: BinderSubject     // what the right column is about
    public var beside: BinderSubject?   // reference material opened beside
    public static let book = WindowSubject(open: .project, faces: .project, beside: nil)
    /// Any part naming something that no longer exists becomes the Book (open, faces) or nil (beside).
    public func validated(structure: [StructureItem], researchIDs: Set<String>,
                          figureIDs: Set<String>, editionLanguages: Set<String>) -> WindowSubject
}

public enum ClickRule {
    public enum Gesture { case click, openInCentre }   // openInCentre = double-click or the control
    public static func resolve(_ clicked: BinderSubject, gesture: Gesture,
                               current: WindowSubject, structure: [StructureItem],
                               projectType: ProjectType) -> WindowSubject
}
```

`BinderSubject` must become `Codable` if it is not; check how `UIState.selectedSubject` is stored today and keep that encoding for the existing four cases.

**The rule `resolve` implements** (spec, "The model" and "What Denver decided"):

| Clicked | Centre now | Result |
|---|---|---|
| any, `openInCentre` | any | `open = clicked`, `faces = clicked`; `beside` unchanged, except cleared if it equals `clicked` |
| a piece | `.canvas` or `.edition` | `open` unchanged, `faces = clicked` (clause 1) |
| a piece | anything else, including the Book's views | `open = faces = clicked` |
| a research item | any | `beside = clicked`; `open`, `faces` unchanged (clause 2) |
| a figure, `.project`, a Part, `.inbox`, `.canvas`, `.palette`, `.edition` | any | `open = faces = clicked` |

A screenplay's scene is not a `BinderSubject` today; it stays a scroll within the script and is out of this function. Palette and canvas cards are not `BinderSubject` cases either; leave them to plan 2's pulled-up thing.

**UIState:** add `windowSubject: WindowSubject` and `bookView: BookView`; remove the stored `persona`, `personaMemory` and `selectedSubject` properties from encode. Decode: if `windowSubject` is absent, build it from a legacy `selectedSubject` (`open = faces = that`), else `.book`. Legacy `persona` keys are ignored. `outlineLayout` (`.table`/`.cards`) is read once as a legacy seed for `bookView` (`.table → .outline`, `.cards → .cards`) and no longer written. Persona's stored properties are deleted here only if nothing else compiles against them; otherwise leave them for Task 6 and say so in the commit.

- [ ] **Step 1: Write the failing tests.** `ClickRuleTests`: one test per row of the table above, plus `test_aPieceClickedOverTheBooksCardsOpensThePiece`, `test_aResearchClickNeverMovesTheFaces`, `test_openInCentreOnTheBesideItemClearsBeside`. `WindowSubjectTests`: `test_aRemovedPieceFallsBackToTheBook`, `test_aRemovedBesideItemBecomesNil`, `test_anEditionWhoseLanguageIsGoneFallsBackToTheBook`. `UIStateTests`: `test_aLegacyStateWithPersonaAndSelectedSubjectDecodesToThatSubject`, `test_aLegacyStateWithNoSubjectDecodesToTheBook`, `test_windowSubjectRoundTrips`, `test_legacyOutlineLayoutSeedsTheBookView`.
- [ ] **Step 2: Run `./gen.sh && ./scripts/test.sh`.** Expected: the new tests fail to compile.
- [ ] **Step 3: Implement the types above.**
- [ ] **Step 4: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 5: Commit** — `shell p1 task 1: the window's subject and the click rule`.

---

### Task 2: The centre routes by subject

**Files:**
- Modify: `Maugham/Views/CentreRoute.swift`, `Maugham/Views/ProjectWindow.swift` (the static routing functions: `publishCentre`, `reviewCentreShowsBoard`, `subjectShowsAltitude`, `showsStatusFooter`, `inspectorRoute`, `editorRoute`, `showsPaletteWallCentre`), `Maugham/Views/ResearchSubjectColumns.swift`, `Maugham/Views/FigureSubjectColumns.swift`, `Maugham/Views/CentreColumn.swift`, `Maugham/Views/RightColumn.swift`, `Maugham/Views/ProjectAltitudePane.swift`, `Maugham/Views/IntentStrip.swift`, `Maugham/Views/ScreenplayScriptSource.swift`, `Maugham/Views/CanvasCollapseModifier.swift`, `Maugham/Views/CanvasPromotionModifier.swift`, `Maugham/Views/ResearchRevealModifier.swift`, `Maugham/Views/Publish/PublishPreviewCentre.swift`, `Maugham/Views/PaletteWallState.swift`, `Maugham/Views/InboxPane.swift`
- Tests, re-made over `WindowSubject`: `CentreRouteTests`, `ResearchSubjectRoutingTests`, `FigureSubjectPlacementTests`, `ReviewBoardRoutingTests`, `PublishPreviewCentreTests`, `ProjectAltitudeCentreTests`, `Canvas/CanvasRouteTests`, `Canvas/CanvasCollapseTests`, `Canvas/PromotionCommandTests`, `IntentStripTests`, `ScreenplayScriptSourceTests`, `ResearchSubjectRevealTests`

**Interfaces:**
- Consumes: Task 1's `WindowSubject`, `BookView`.
- Produces:

```swift
static func centreRoute(subject: WindowSubject, bookView: BookView,
                        projectType: ProjectType, structure: [StructureItem],
                        preview: PublishPreviewResolution,
                        proposal: DesignProposalStore.Proposal? = nil,
                        round: TranslationRound? = nil,
                        problems: [TectonicLogParser.Diagnostic]? = nil) -> CentreRoute
```

`CentreRoute` gains `case inbox`. The palette wall is `subject.open == .palette`; the separate `showsPaletteWall` window state and `PaletteWallState`'s persona-change handlers go. The review board stops being a cover: `CentreCover.reviewBoard` is deleted and the board is the altitude pane's third view (`bookView == .status`), with the header's picker offering Cards, Outline, Status. A Part as `open` shows the same pane over its own chapters. An edition's covers keep their existing precedence, and `publishCentre` reads the edition's language from the subject; it no longer requires the tree to sit on the Book.

Every function in the Files list that takes `persona:` takes `subject:` (and `bookView:` or `isLocked:` where the table above says so) and asks the table's answer. Where a function took both `persona` and `subject: BinderSubject?`, the `BinderSubject` it read is `subject.open`, except the right column's document, which is `subject.faces`.

`ProjectWindow` still owns a `persona` state after this task (Task 6 deletes it); it is passed nowhere this task touched.

- [ ] **Step 1: Re-make the listed tests** as pure-function tests over `WindowSubject`. Each old suite's distinct behaviours are kept as cases; assertions of the form "only persona X does Y" become "only subject kind X does Y". Add `test_theInboxSubjectRoutesToTheInbox`, `test_aPartShowsTheAltitudeOverItsOwnChapters`, `test_statusIsAViewAndNeverACover`, `test_anEditionShowsItsBookWhateverTheFacesAreOn`, `test_theCanvasStaysTheCentreWhenTheFacesMoveToAPiece`.
- [ ] **Step 2: Run `./scripts/test.sh`.** Expected: compile failures in the re-made suites.
- [ ] **Step 3: Change the signatures and bodies.** Mount `InboxPane` for `.inbox` in `CentreColumn`.
- [ ] **Step 4: The disable experiment.** Make `centreRoute` ignore `subject.open == .canvas`; confirm a test fails; restore.
- [ ] **Step 5: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 6: Commit** — `shell p1 task 2: the centre routes by subject`.

---

### Task 3: The tree's rows and the click

**Files:**
- Modify: `Maugham/Views/BinderView.swift`, `Maugham/Views/BinderTreeSections.swift`, `Maugham/Views/BinderPaneToggle.swift`, `Maugham/Views/CollectionBinderPaneToggle.swift`, `Maugham/Views/BinderRow.swift`, `Maugham/Views/TreeTravel.swift`, `Maugham/Views/TreeSectionDerivation.swift`, `Maugham/Views/SubjectValidationModifier.swift`, `Maugham/Views/ProjectWindow.swift`
- Create: `Maugham/Views/TreeTopRows.swift` (Inbox and Canvas rows), `Maugham/Views/TreeEditionRows.swift`
- Tests: `MaughamTests/TreeTopRowsTests.swift`, `MaughamTests/TreeEditionRowsTests.swift`; re-make `TreeTravelTests`, `PaletteWallDoorTests`, `PlanBinderTabTests`, `ProjectSubjectReachabilityTests`, `TreeFindOverlayTests`, `TreeScrollStabilityTests` where they name a persona

**Interfaces:**
- Consumes: `ClickRule.resolve`, `WindowSubject`.
- Produces: the tree takes `subject: Binding<WindowSubject>` in place of `selectedSubject: Binding<BinderSubject?>`; `TreeEditionRows.languages(store:) -> [String]` (source language first, then each language `EditionStatus.languageRows` reports, in its order).

**Contract:**
- Row order: the Book; Inbox; Canvas; the manuscript; Figures; Research; Palette; Editions; then the existing foot. Inbox shows only when the project has an inbox; Editions only when publishing is initialised or a translation exists.
- A click calls `ClickRule.resolve(_, gesture: .click, …)`; a double-click calls it with `.openInCentre`. `TreeTravel`'s window-level double-click monitor is kept as the delivery mechanism and loses its persona argument and `treeTravelDestination`.
- Two row states, visibly different: `open` (filled selection) and `faces` when it differs from `open` (outlined). `beside` uses the outlined state too.
- The Palette section's "open wall" door becomes selecting the Palette row. The Exports footer stays where it is and loses its persona gate.
- `SubjectValidationModifier` calls `WindowSubject.validated(…)` wherever it validates the subject today.
- Inbox, Canvas and edition rows are `Button(.plain)` rows (tripwire 9) and take no per-row computed work; the edition language list is computed once per change of the store's translation state, not per row.

- [ ] **Step 1: Write the failing tests.** `test_rowOrderIsBookInboxCanvasManuscriptFiguresResearchPaletteEditions`, `test_theSourceLanguageIsTheFirstEdition`, `test_noEditionsRowsBeforePublishingOrATranslationExists`, `test_aDoubleClickOnAResearchRowTakesTheCentre`, `test_aClickOnAResearchRowOpensItBeside`, `test_thePaletteRowOpensTheWall`, `test_theFacesRowIsMarkedWhenItDiffersFromTheOpenRow`.
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 5: Commit** — `shell p1 task 3: Inbox, Canvas and Editions are rows; one click rule`.

---

### Task 4: Beside, and going to a place

**Files:**
- Modify: `Maugham/Views/RightColumn.swift`, `Maugham/Views/AssistantColumn.swift`, `Maugham/Views/ResearchSubjectColumns.swift`, `Maugham/Views/ReferencesPane.swift`, `Maugham/Views/ManuscriptNavigation.swift`, `Maugham/Views/ParagraphNavModifier.swift`, `Maugham/Views/CanvasClaudeArrivalModifier.swift`, `Maugham/Views/DetailPaneToggle.swift`
- Tests: re-make `AssistantColumnTests`, `StudyColumnMountTests`, `ManuscriptNavigationTests`, `ReferencesPaneTests`, `Canvas/CanvasClaudeBannerTests`

**Contract:**
- `subject.beside` shows in the right column through the placement that today serves "beside the canvas" (`ResearchSubjectPlacement.besideTheCanvas`, renamed `.beside`), for every centre. It carries a visible **Open in Centre** button that calls `ClickRule.resolve(_, gesture: .openInCentre, …)` and a close button that sets `beside = nil`.
- The study column (`AssistantColumnModel.studied`) is presented whenever something is studied; `AssistantColumn.isPresented` loses `persona`.
- The right column's panes read their document from `subject.faces`.
- `ManuscriptNavigation.destination` loses `from persona:`; going to a paragraph returns a `WindowSubject` with `open = faces = .item(docId)`. Its `Destination.persona`, `memory` and `movesPersona` go.
- Claude's canvas arrival (`CanvasClaudeArrivalModifier`) sets `open = .canvas` where it set `.plan`.

- [ ] **Step 1: Write the failing tests.** `test_aBesideItemShowsWhateverTheCentreIs`, `test_openInCentreMovesTheBesideItemToTheCentre`, `test_theFacesReadTheFacesSubjectNotTheOpenOne`, `test_goingToAParagraphOpensItsPiece`, `test_theStudyColumnIsPresentedWhateverTheCentre`, `test_aClaudeArrivalOpensTheCanvas`.
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 5: Commit** — `shell p1 task 4: reference material opens beside; a place opens its piece`.

---

### Task 5: Lock, and Run as two commands

**Files:**
- Create: `Maugham/Views/LockToggle.swift`
- Modify: `Maugham/Views/FigureActions.swift`, `Maugham/Views/FigureInspector.swift`, `Maugham/Views/FigureSection.swift`, `Maugham/Views/FigureSubjectColumns.swift`, `Maugham/Views/Palette/PaletteWallView.swift`, `Maugham/Views/BinderTreeSections.swift` (`offersNewTable`), `Maugham/Editor/ResearchTableGrid.swift`, `Maugham/Views/CentreColumn.swift`, `Maugham/Views/RightColumn.swift`, `Maugham/Compiler/RunKind.swift`, `Maugham/Views/CompilerRunModifier.swift`, `Maugham/MaughamApp.swift`, `Maugham/Models/MaughamNotifications.swift`, `Maugham/Events/MaughamEvent.swift`, `Maugham/Views/DiagnosticsPane.swift`, `Maugham/Views/ProjectWindow.swift`
- Delete: `Maugham/Models/RunMenuTitles.swift`, `MaughamTests/RunMenuTitlesTests.swift`
- Tests: `MaughamTests/LockTests.swift`; re-make `ReviewAdjudicationTests`, `RunKindTests`, `CompilerRunCommandTests`, `Views/FigureInspectorTests`, `Views/ResearchNewTableTests`, `Editor/FigureCentreGridTests`, `Editor/ResearchTableGridTests`, `Canvas/CanvasEditGateTests`

**Contract — Lock:**
- `@State var isLocked = false` on `ProjectWindow`: per window, not stored, off at launch.
- A toolbar toggle (`lock` / `lock.open`), hidden in focus mode.
- It locks exactly what the Review persona locks today: every site reading `editsResearchInTheCentre` or `editsFigures`. It does **not** lock the manuscript text in this plan: the spec's "covering the text" has no existing mechanism behind it that is known to be a plain text lock (`EditorControl.isManualReviewMode` is the candidate; read it and report what it does in the task's handback, do not wire it).
- Posture locks are unchanged and independent; Lock on can only add refusals.

**Contract — Run:**
- `RunKind.of(persona:)` is deleted. The four menu items in File are fixed titles and each posts its own kind: **Check Writing** ⌘R (check), **Reread** ⇧⌘R (check, fresh eyes), **Run Round** ⌃⌘R (round), **Fresh Eyes** ⌃⇧⌘R (round, fresh eyes). Confirm ⌃⌘R and ⌃⇧⌘R are unbound before using them; if either is taken, leave that item without a key and say so.
- A run acts on `subject.faces` when it names a piece; otherwise it is a no-op at the receiver, as today with no window in front.
- Tripwire 34 stands: neither run resolves its reader from the other loop's memory.
- `FocusedPersonaKey` and `FocusedValues.persona` are deleted with the menu's last reader.

- [ ] **Step 1: Write the failing tests.** `test_lockOffByDefaultAndNotStored`, `test_lockRefusesAResearchNoteEdit`, `test_lockRefusesAFigureWrite`, `test_lockRefusesNewTable`, `test_postureRefusalHoldsWithLockOff`, `test_lockNeverPermitsWhatPostureRefuses`, `test_commandRAlwaysRequestsACheck`, `test_runRoundAlwaysRequestsARound`, `test_aRunWithTheCanvasOpenAndNoPieceOnTheFacesIsANoOp`, `test_aRunWithTheCanvasOpenRunsOnTheFacesPiece`.
- [ ] **Step 2: Run.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `./scripts/test.sh`.** Expected: green.
- [ ] **Step 5: Commit** — `shell p1 task 5: Lock replaces Review's read-only surfaces; Run is two commands`.

---

### Task 6: The personas are deleted

**Files:**
- Delete: `Maugham/Models/Persona.swift`, `Maugham/Models/PersonaMemory.swift`, `Maugham/Views/PersonaBar.swift`, `Maugham/Views/PersonaModifier.swift`; tests `PersonaTests`, `PersonaMemoryTests`, `PersonaModifierTests`, `PersonaPaneRegistryTests`, `PersonaKeyspaceTests`, `Views/DetailPaneTogglePersonaTests`
- Modify: `Maugham/Models/DetailSegment.swift`, `Maugham/Views/DetailPaneToggle.swift`, `Maugham/Views/ProjectWindow.swift`, `Maugham/MaughamApp.swift`, `Maugham/Models/MaughamNotifications.swift`, `Maugham/Events/MaughamEvent.swift`, `Maugham/Stores/UIState.swift`, `Maugham/Compiler/CompilerPrompt.swift`, `Maugham/Canvas/CanvasInteraction.swift`, `Maugham/Views/Review/ReviewBoardPane.swift`, `Maugham/Views/BinderView.swift`, `Maugham/MCP/CanvasTools.swift`, and every remaining file `grep -rlE "\bPersona\b|persona" Maugham --include='*.swift'` lists
- Tests: `MaughamTests/NoPersonaCensusTests.swift`, `MaughamTests/DetailSegmentOrderTests.swift`; fix the remaining test files that name a persona (`TripwireGrepTests`, `WiringCensusTests`, `AltitudeKeyspaceTests`, `DesignGateTests`, `StatementPane*Tests`, `StatementMountFixture`, `FindMatchScrollTests`, `TreeTrashDisclosureTests`, `ManuscriptForceCensusTests`, `PublishProblemsViewTests`, `AnnotationScopeTests`, `DiagnosticsPaneTests`, `DetailPaneColumnHeightCensusTests`, `ProjectKindSitePinsTests`, `Canvas/ItemInspectorTests`, `Canvas/CanvasViewMountingSurfaceTests`, `Canvas/RegionBindingTests`, `Views/RightColumnPaneWidthTests`)

**Contract:**
- `DetailSegment` gains `static let pickerOrder: [DetailSegment]`: the canonical order from `PersonaPaneRegistryTests.canonicalPaneOrder`, with `.diagnostics`, `.references`, `.lessons`, `.firstReader` and `.department` placed where the persona lists had them, and `.inbox` removed (the case is deleted; the Inbox is a row). `DetailPaneToggle.visibleSegments` returns it, minus `.department` unless `subject.open` is an edition, minus the manuscript-only panes when `faces` names no document. One remembered segment in `UIState`.
- The ⌘1–4 menu items, `maughamSetPersona`, `MaughamEvent.personaKey`, `postPersona`, and the toolbar's persona bar are deleted. ⌘1–4 are left unbound; plan 2 binds ⌘1–3.
- Every ⌘⌥ pane key keeps working; `PersonaKeyspaceTests.test_everyDetailSegmentHasAMenuShortcut`'s assertion moves into `DetailSegmentOrderTests`.
- `CompilerPrompt` and the MCP tool description in `CanvasTools.swift` stop naming a persona; the description says "the canvas is the centre".
- Tripwire greps in `TripwireGrepTests` that exist only to police personas are deleted with a one-line note in `docs/tripwires.md`; greps that police something else and merely mention a persona are re-pointed.
- **`NoPersonaCensusTests.test_noProductionSourceNamesAPersona`** greps `Maugham/` and `Packages/MaughamCore/Sources` for the word `Persona` and the identifiers `persona`, `.plan`-as-persona being out of scope; it carries a planted-offender control (a string the grep must catch) and an allow-list that is empty.

- [ ] **Step 1: Write `NoPersonaCensusTests` and `DetailSegmentOrderTests`.** Run; expected: the census fails listing every remaining file.
- [ ] **Step 2: Delete and fix until the census is empty and the build is clean.**
- [ ] **Step 3: Run `./gen.sh && ./scripts/test.sh`.** Expected: green.
- [ ] **Step 4: Commit** — `shell p1 task 6: the personas are deleted`.

---

### Task 7: The record

**Files:**
- Create: `docs/adr/0035-the-subject-not-the-persona.md`
- Modify: `docs/adr/README.md`, `docs/adr/0005-*.md`, `docs/adr/0025-*.md`, `docs/adr/0031-*.md` (a superseded-in-part line each), `Maugham/Views/AREA.md`, `Maugham/Compiler/AREA.md`, `CLAUDE.md` (the `Maugham/Models/**` row), `docs/INDEX.md`, `docs/tripwires.md`, any `register/` claim or ruling that states persona behaviour (flip or retire each; list them in the handback)

**Contract:** ADR 0035 records: the subject model and click rule as built; Lock; Run as two commands; what was deleted; and that the right column, Status, translation and the margin are later plans of the same milestone. It does not describe anything unbuilt as built. The guide, the welcome tour and Claude's help text are **not** touched here: the branch does not ship until plan 4, which rewrites them.

- [ ] **Step 1: Write the ADR and sweep the listed docs.**
- [ ] **Step 2: Run `./scripts/test.sh`** (doc censuses run in the suite). Expected: green.
- [ ] **Step 3: Commit** — `shell p1 task 7: ADR 0035 and the area guides`.

---

### Task 8: The gate

- [ ] **Step 1:** `./scripts/test.sh full`. Expected: 0 failures, no skips.
- [ ] **Step 2:** `./scripts/test.sh phone` (UIState and `BinderSubject` live where the phone can see them only if they are in MaughamCore; run it regardless). Expected: green.
- [ ] **Step 3:** Release build, because `ProjectWindow.body` changed: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`. Expected: BUILD SUCCEEDED.
- [ ] **Step 4:** Whole-branch review of the full diff against this plan and the spec. Name these seams to the reviewer: Task 2 × Task 3 (a subject the tree can set that the route does not handle); Task 3 × Task 4 (`faces` and `beside` both outlined); Task 5 × Task 6 (a refusal site that read a persona and now reads nothing).
- [ ] **Step 5:** No merge, push or tag. Report to Denver and write plan 2 against the built code.

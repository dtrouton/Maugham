# Shell Finish Plan 3b — the centre rule completes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The stage-3 remainder ships whole: Plan's tree travels to Author on a double-click and its wall door travels too, Publish's centre shows the compiled book, the canvas finally lights a research subject's card, Review's research/card centre stops editing, a reveal can open a Collection fold and scroll the tree to what it opened, a find match gets the full arrival posture, and the Link Research… route a fix wave deleted comes back with a keyboard.

**Architecture:** Spec `docs/superpowers/specs/2026-08-08-shell-finish-design.md` §4/§5/§9 stage 3, second plan of two (rule 12; 3a is built and merged — `docs/superpowers/plans/2026-08-10-shell-finish-stage3a-altitude.md`). Derived per rule 11 from a four-agent survey of the built code (2026-08-12: canvas-highlight / window-routing / publish-catalog / tree-interaction seams); every line number below was read from HEAD (`2288cd83`). Key survey facts the tasks stand on: `CanvasSubject.resolve` collapses `.research` to `.wholeProject` at `CanvasSubject.swift:89` and the card↔research join is O(1) (`CanvasNodeID.item(id)`, `CanvasNode.swift:34-36`); the persona has ONE full-fold writer (`PersonaModifier`) plus two sanctioned bypass writers, each pinned by censuses a new writer must join; the wall closes on ANY persona change AND any subject change (`PaletteWallModifier`, `ProjectWindow.swift:638ff`), so the Open-Wall travel opens the wall inside that same observer, one pass after the switch; the publications catalog loads ASCENDING (`PublicationStore.swift:13-16` — latest is `.last`), a catalog row can outlive its file, and `PDFPreview` (`Maugham/Views/research/PDFPreview.swift`) is directly reusable; Review's research-note and palette-card centres are fully EDITABLE today (`ResearchNoteEditor.swift:56` says so in a comment); the fold's disclosure is SwiftUI-private in two places (`BinderView.swift:189-203`, `ResearchTree.swift:94`'s nil default) and `reveal`'s guard (`BinderTreeSections.swift:855`) passes any manifest research id; no `ScrollViewReader` exists anywhere; the same `.research(id)` tag is deliberately mounted twice in a novel's `List` (fold + shared section), so a scroll target must be unambiguous by construction.

**Tech Stack:** Swift 6 / SwiftUI + PDFKit, XCTest, mounted-window tests on the parallel scheme.

## Global Constraints

- Contracts not bodies; TDD; `./scripts/test.sh` per task, `full` before merge; Release build after any `ProjectWindow.body`-subtree change; `./gen.sh` after adding Swift files (new files in Tasks 3, 5, 9); commit per task; **no push**.
- **No `default:`** on any switch over `BinderSubject`, `Persona`, `DetailSegment`, `CanvasSubject`, `ResearchSubjectPlacement` — the no-default discipline carries into every new case.
- **The registry does not move in 3b**: `Persona.panes`, `canonicalPaneOrder`, `DetailSegment.allCases` are untouched. Anything that seems to need a new pane is mis-derived — 3b's surfaces are centre overlays and tree furniture.
- **Mount identity is the standing hazard**: `manuscriptEditor(` appears exactly twice in `ProjectWindow.swift` (decl + call), `EditorHost(` exactly once, `ProjectAltitudePane(` exactly once — the source-scan tests (`ProjectAltitudeCentreTests:909`, `RegionBindingTests`) stay green; new centre surfaces are overlay layers INSIDE `manuscriptEditor`'s ZStack, never new `editorPane` arms. `PromotionCommandTests.swift:356`'s census token `"subject: CanvasSubject.resolve("` must keep matching after Task 1's signature widening (it is a prefix; it does).
- **Recorded decisions (Denver, 2026-08-10), verbatim scope**: the travel rule — in Plan, double-click any tree row goes to Author with that subject; Open Wall in Plan goes to Author with the wall open, opened AFTER the persona switch lands. Publish's whole-book preview — the most recent compiled PDF via PDFKit; a piece subject shows the SAME preview; degrade to altitude when nothing has been compiled yet; per-piece page-jump is a follow-up beyond this plan. Review adjudicates — it doesn't edit research or palette cards from its own columns.
- **Design calls this plan makes** (each argued in its task; Denver can veto any before its task runs):
  1. A research subject DIMS the board with its card lit — §4's "its card highlighted on the board" rides the existing dim, following §4.1's group precedent (dimmed-without-piece-binding already ships: a group's sweep makes a plain region).
  2. The no-node degrade is STANDING CHROME (`CanvasBindingOffer`'s shape, a second message set), not undim — undim would make the writer's click indistinguishable from the project row.
  3. A RESTORED research subject dims exactly as a restored piece subject does today ("the dim is entered by a click" distinguishes unresolvable ids, not restores) — but the restore does NOT move the camera (a restore is not an arrival, `ResearchRevealModifier`'s own rule).
  4. Publish with nothing compiled behaves exactly as 3a left it (altitude for non-document subjects, editor for a document) — Denver's "degrade to altitude" is the project row's degrade; degrading a DOCUMENT subject to altitude would make every corkboard click in uncompiled Publish a dead affordance. With a compiled PDF, every subject reaching the manuscript arm shows the preview — including `.research`/`.palette`, whose Publish placement becomes `.nothingMoves` (spec §4's "—" row): the centre shows the persona's own project rendering, which is the degrade rule's purpose ("the centre never renders nothing").
  5. A find RESEARCH match gains the full arrival posture (tree reveal + scroll request); the column reveal already follows from the subject observers; the overlay stays up — closing it stays the writer's.
  6. The fold-reveal fix is BOUND disclosure state, not guard-narrowing alone — a reveal can open a Collection piece's fold; the guard ALSO narrows, so an id in no tree still moves nothing.
  7. Scroll-to-section ships: ⌘⌥R/⌘⌥P and every reveal caller write a one-shot scroll request; whichever tree host is mounted consumes it (including on remount, for requests written while the find overlay covered the column).
  8. Link Research… ships as a document-row context-menu verb (rows whose routing is `.sharedPlusLink`) plus the resurrected picker sheet (`git show 4dfcab8f~1:Maugham/Views/ResearchLinkPickerSheet.swift`), with its `try?` error-swallowing replaced by the tree's shared-alert discipline.
- Tripwire 9 with its full record: the double-click gesture goes on the row's LABEL LEAF, never the row container — `TaskRow.swift:36-45` records a row-wide `simultaneousGesture(TapGesture(count: 2))` eating drag initiation across the whole row interior, and every binder row is draggable across its whole surface (`BinderRow.swift:76`, `ResearchRow.swift:76`, `PieceRow.swift:74`). Tripwires 15 (`ContentUnavailableView` full-frame), 16 (rename focus untouched), 21 (every new event posts through `MaughamEvent` with a declared scope; receivers use the helpers), 30 (nothing scene-proportional off a redraw counter — the arrival reveal fires per subject CHANGE, never per frame). Tripwire 11: no migrations (no schema moves in this plan; `UIState` untouched).
- **T3's standing rule**: no new reader of the tree's `state.selection` raw — the travel payload is the row's own tag; scroll targets come from `reveal`'s return.
- Mounted tests obey the CI-display rule (1024pt runner — read premises off the window actually got; skip by name where the display can't afford it).
- Flakes: the wall-clock family is discriminated BY NAME (handoff list: `DeclaredWorldDeriverTests`, `ClaudeCLISessionTests.test_aSilentDeathSaysOnlyWhatItKnows`, the MCP clock pair) before any branch blame; check for other sessions' builds (`ps ax | grep xcodebuild`) before believing a starvation-shaped failure.
- Subagent models: opus tasks 1, 2, 4, 5, 7; sonnet tasks 3, 6, 8, 9; haiku task 10; reviewers haiku for docs/small diffs, sonnet for mounted-UI diffs.

---

### Task 1: The canvas learns a research subject

**Files:**
- Modify: `Maugham/Canvas/CanvasSubject.swift` (`:40` enum, `:65` `pieces`, `:76` `dimsTheBoard`, `:86-107` `resolve`), `Maugham/Canvas/CanvasHighlight.swift` (`:80-106` `resolve`), `Maugham/Views/ProjectWindow.swift:1538-1539` (the one mapping call)
- Test: rewrite `MaughamTests/Canvas/CanvasHighlightTests.swift:55-60`; re-cut `MaughamTests/SubjectValidationTests.swift:213,218` and `MaughamTests/SubjectRestoreTests.swift:165-173`

**Interfaces:**
- Produces: `case research(String)` on `CanvasSubject`; `pieces` returns `[]` for it (a research id is not a `boundPieceID` and must never leak into piece-shaped derivations); `dimsTheBoard` returns `true` for it.
- `static func resolve(_ subject: BinderSubject?, in structure: [StructureItem], research: [ResearchItem]) -> CanvasSubject` — signature gains `research:`. `.research(id)` maps to `.research(id)` iff `TreeWalk.contains(id: id, in: research)`, else `.wholeProject` — the "an id the tree cannot find is not a subject at all" ruling, same as an unresolvable `.item` (`CanvasSubject.swift:98`).
- `CanvasHighlight.resolve`'s research arm: `nodes` is `[CanvasNodeID.item(id)]` when `scene.node(CanvasNodeID.item(id)) != nil`, else empty; `regions` and `lines` empty. The join is `CanvasNodeID.item(_:)` (`CanvasNode.swift:34-36`) — O(1), unique by construction, and can never hit an `.owned` node (owned ids are minted, not derived).

**Contracts:**
- [ ] A research subject whose card is on the canvas: `isFiltering` true, exactly that node lit, no regions, no lines. A sweep during it still returns `.create(bindingTo: nil)` — `CanvasInteraction.sweepOutcome`'s `guard case .piece` (`CanvasInteraction.swift:733`) already answers this; assert it, don't touch it (§4.1's "the canvas never guesses a piece the writer never named", the group precedent this design call rides).
- [ ] A research subject with no card on the canvas: `litNothing` true (Task 2 hangs chrome off this).
- [ ] `CanvasHighlightTests:55-60` rewrites into: a FINDABLE research id resolves to `.research(id)` and dims; an UNFINDABLE one stays `.wholeProject` undimmed (keep the old claim as the control for the missing-id case — the fixture at `:36-44` holds no research, so it needs a research fixture too).
- [ ] The neighbours stand unmodified: `:46-51` (project row), `:100-107` (deletion is not a click), `:113-122` (empty group still dims).
- [ ] Escape asks for the whole board over a research dim (`dimsTheBoard` drives `CanvasView.swift:1771` and the monitor arming at `:502`) and writes `.project` exactly as it does from a piece dim (`:448-467`'s pinned literals unmoved).
- [ ] The source-scan census at `CanvasHighlightTests:274-320` (three `.onChange` triggers, `rebuildHighlightAndTree()` caller count == 4, `CanvasHighlight.resolve` exactly once in `CanvasView.swift`) stays green — this task adds data to `resolve`, never a trigger.
- [ ] AX: through `CanvasAccessibility.elements`, the lit card carries no `dimmedTerm` and every other node does ("outside the binder's selection", `CanvasAccessibility.swift:279`).
- [ ] `SubjectValidationTests:213,218` / `SubjectRestoreTests:165-173` re-derive: a VALID restored research id now dims (design call 3); a REPAIRED-to-`.project` subject still does not. State in the report which assertions moved and why.
- [ ] `ProjectWindow.swift:1538` hands `research: store.manifest.research`; `PromotionCommandTests:356`'s token still matches.
- [ ] Release build (ProjectWindow.body subtree); commit.

### Task 2: The absent card says so, and the present one comes into view

**Files:**
- Modify: `Maugham/Canvas/CanvasBindingOffer.swift` (`:20-73`), `Maugham/Canvas/CanvasView.swift` (`:481-483` mount, `:611` subject onChange, `:880-899`/`:1550-1560` the two reveal shapes)
- Test: `MaughamTests/Canvas/CanvasBindingOfferTests.swift`; extend `MaughamTests/Canvas/CanvasCompositionTests.swift`'s hit-test-opt-out count assertion (must not move)

**Interfaces:**
- Produces on `CanvasBindingOffer`: `struct Message: Equatable { let headline: String; let instruction: String }` and `static func message(subject: CanvasSubject, highlight: CanvasHighlight) -> Message?` — the ONE decision function. Piece arm returns the existing strings verbatim (`:22`/`:27`); research arm returns `headline: "This item isn't on this canvas yet."`, `instruction: "Drag its row from the tree to place it."` when `litNothing`; group and wholeProject arms return `nil` (§4.1's rule for groups, unchanged). `isOffered` collapses into `message(...) != nil` or retires; `CanvasBindingOfferView` renders a `Message`.
- Arrival reveal: when the subject CHANGES to `.research(id)` and `model.scene.node(.item(id))` exists, the view moves the camera through the same path the drop-reveal drives (`camera.bring(origin, toViewPoint: CanvasCamera.revealViewPoint)`, `CanvasCamera.swift:50`; zoom untouched). Fires from a subject `.onChange` WITHOUT `initial: true` — a restored subject must not yank the camera on window-open (design call 3's second half; a restore is not an arrival).

**Contracts:**
- [ ] Piece-with-no-bindings offer unchanged — existing `CanvasBindingOfferTests` green unmodified except where `isOffered` was renamed.
- [ ] Research subject, card absent → the research message; card present → no chrome at all.
- [ ] A group still never gets chrome (the `:54` control stands).
- [ ] The chrome stays BENEATH `CanvasEventView` in the ZStack; `CanvasCompositionTests`' count of hit-testing opt-outs above that line does not move.
- [ ] Mounted: select a research row whose card sits far off-screen → the card arrives at `revealViewPoint`; select the SAME row again → no camera move (onChange semantics); drag the card afterwards → the camera never re-centers (no per-frame reveal, tripwire 30).
- [ ] Window relaunch with a research subject persisted → the board dims to the card but the camera stays where the writer left it.
- [ ] The `rebuildHighlightAndTree()` caller-count census (`CanvasHighlightTests:309`) still reads 4 — the reveal is a separate observer, not a fourth rebuild caller.
- [ ] Commit.

### Task 3: The travel rule — double-click, Plan to Author

**Files:**
- Create: `Maugham/Views/TreeTravel.swift` (the modifier + the receiver's static)
- Modify: `Maugham/Views/BinderRow.swift`, `Maugham/Views/PieceRow.swift`, `Maugham/Views/ResearchRow.swift` (label leaves), `Maugham/Views/BinderView.swift:130-133` (project row label), `Maugham/Views/BinderTreeSections.swift` (palette card row label, `:227` region), `Maugham/Events/MaughamEvent.swift` (payload key), `Maugham/Views/ProjectWindow.swift` (receiver)
- Test: new `MaughamTests/TreeTravelTests.swift`; re-cut the three censuses named below

**Interfaces:**
- Produces: `.maughamTreeTravel`, posted `.keyWindow`-scoped with payload `["subject": BinderSubject]` (tripwire 21 — scope declared at the post site), from a `treeTravelOnDoubleClick(_ subject: BinderSubject)` view extension applying `.onTapGesture(count: 2)` to the LABEL LEAF it modifies. The subject posted is the ROW'S OWN tag, never read from `state.selection` (T3's rule).
- Receiver: `static func treeTravelDestination(persona: Persona) -> Persona?` on `ProjectWindow` (or `TreeTravel`) — `nil` unless `persona.centresTheCanvas` (the travel rule is Plan's; everywhere else the double-click means nothing beyond the click), else `.author`. The mounted receiver writes `selectedSubject = subject` and moves the persona through `PersonaModifier.applyPersonaChange` — a deliberate writer move records the departing position, `ManuscriptNavigation.go`'s reasoning (`Maugham/Views/ManuscriptNavigation.swift`; the AREA.md rule: every persona writer calls `applyPersonaChange` or states why not).

**Contracts:**
- [ ] Mounted, Plan, novel: double-click a chapter row → Author, that chapter in the editor; the project row → Author + altitude; a research note row → Author + `ResearchNoteEditor` in the centre; a palette card row → Author + the card editor. A single click still only selects (the dim moves, the persona stays) — the first click of the double-click is that click.
- [ ] A drag still initiates from the row INTERIOR on every row kind touched — the TaskRow trap (`TaskRow.swift:36-45`), one mounted drag assertion per kind.
- [ ] In Author, a double-click is a no-op (the persona guard) — one control.
- [ ] Scene rows need NOTHING and get nothing: `SceneNavigatorPane` rows already navigate through `ManuscriptNavigation` on a single click, which already moves Plan→Author (`ManuscriptNavigationTests:104`) — assert in the report, not in code.
- [ ] Census re-cuts, all three: `TripwireGrepTests.test_theWindowsPersonaIsWrittenOnlyFromTheClosedSetOfDecisionSites` gains the receiver; `ManuscriptForceCensusTests`' receiver array gains it (the 3a plan's recorded carry); `PaletteWallDoorTests.test_neitherBypassWriterClosesTheWallItself` adds `TreeTravel.swift` to the never-mentions-`showsPaletteWall` set (the wall close rides `PaletteWallModifier`'s persona observer — this writer must not re-spell it).
- [ ] The departing Plan position is recorded (one `applyPersonaChange`-shaped assertion — ⌘1 brings the writer back to the tree they were arranging).
- [ ] Release build; commit.

### Task 4: The travel rule — Open Wall in Plan

**Files:**
- Modify: `Maugham/Views/BinderTreeSections.swift` (the Palette section header's `openWallButton` — today disabled in Plan with a tooltip), `Maugham/Views/ProjectWindow.swift` (`PaletteWallModifier`, `:638ff`; one new window `@State`)
- Test: `MaughamTests/PaletteWallDoorTests.swift` re-cuts + one new mounted travel case

**Interfaces:**
- The door in Plan becomes ENABLED; its action there requests travel: persona → `.author` through `applyPersonaChange` (same discipline as Task 3) plus `wallTravelPending = true` (window `@State`, never persisted). Outside Plan the door is unchanged (opens in place, no persona move). The `.help` tooltip's text changes from "why disabled" to "opens in Author".
- Produces: `static func applyWallTravelOnPersonaChange(pending: inout Bool, showsPaletteWall: inout Bool)` — consumed INSIDE `PaletteWallModifier`'s existing `.onChange(of: persona)` handler, AFTER `closePaletteWallOnPersonaChange` runs: if pending, clear it and set `showsPaletteWall = true`. The wall opens in the pass after the switch landed — Denver's "opened AFTER the persona switch lands" implemented inside the ONE owner of the wall's lifecycle, so no ordering rests on cross-modifier delivery (tripwire 2's shape). The travel writes NO subject (the wall closes on any subject change — the modifier's own second observer).

**Contracts:**
- [ ] Mounted, Plan: click Open Wall → persona is Author, the wall covers the centre, the inspector is stashed per `applyPaletteWallChange`'s open arm, the status footer is hidden (existing rule, `ResearchSubjectRoutingTests:339`'s shape).
- [ ] The token is consumed exactly once: after the travel, ⌘1 back to Plan then ⌘2 → the wall does NOT reappear (`test_theMountedModifierClosesTheWallOnAnyPersonaChange`, `PaletteWallDoorTests:274`, still green).
- [ ] Esc still closes the travelled-to wall; a subject click under it still closes it.
- [ ] `test_theHeadersOpenWallButtonIsDisabledInPlan` (`PaletteWallDoorTests:131`) is REWRITTEN to the travel behaviour — the disabled arm is gone, and the test name must stop claiming it.
- [ ] The door outside Plan: one control that Author's door still opens in place with no persona write.
- [ ] Release build; commit.

### Task 5: Publish's centre is the book

**Files:**
- Create: `Maugham/Views/Publish/PublishPreviewCentre.swift`, `Maugham/Publish/PublishPreviewResolver.swift`
- Modify: `Maugham/Models/Persona.swift` (one new predicate), `Maugham/Views/ProjectWindow.swift` (`manuscriptEditor` ZStack `:1482-1516`, `showsStatusFooter` `:1266`, one new refresh modifier), `Maugham/Views/ResearchSubjectColumns.swift` (`:94-101`, the placement's publish arm)
- Test: new `MaughamTests/PublishPreviewCentreTests.swift`; re-cuts in `ProjectAltitudeCentreTests` (`:90`, `:361`, `:563`), `ResearchSubjectRoutingTests` (`:73`, `:140`), `ProjectSubjectReachabilityTests`

**Interfaces:**
- Produces: `Persona.previewsThePublishedBook: Bool` — true only for `.publish`, the ONE spelling every gate reads (`centresTheCanvas`'s discipline; no `== .publish` at any use site — the Exports footer stays the sole name-gate).
- `PublishPreviewResolver.latestReadablePDF(store: PublicationStore, projectURL: URL) async -> Publication?` — walks `load()` from the TAIL (the catalog is ascending `compiledAt`, `PublicationStore.swift:13-16`; `ListPublicationsTool` uses `suffix(limit)` for the same reason); returns the first row with `format == .pdf` whose resolved file exists AND `PDFDocument(url:) != nil`. Both guards are load-bearing: a catalog row can outlive its file (`ExportsListView`'s Delete removes the file, never the JSONL), and unknown formats decode to `.pdf` (`PublishConfig.swift:133-136`). Path resolution is the `PublicationTools.swift:162-165` idiom.
- Window state: `@State publishPreview: Publication?`, owned by a new `PublishPreviewModifier` refreshing on: window load (`.task`), `.onProjectEvent(.maughamPublicationCompleted, url:, window:)` (posted AFTER the catalog append — `CompileOrchestrator.swift:509→517`; receive via the ADR 0021 helper with the `WindowAccessor` idiom, `ExportsListView.swift:22-26,78-81`), and arrival into the publish persona (`.onChange(of: persona)`) — which also covers the file-deleted-since staleness without a watcher.
- `PublishPreviewCentre(publication: Publication, projectURL: URL)` — a header (project title, `v{version}`, language when non-nil, `compiledAt` formatted) over the existing `PDFPreview(fileURL:)` (`Maugham/Views/research/PDFPreview.swift:1-21` — reused, never copied), opaque, full-frame.
- Routing: `researchSubjectPlacement`'s publish arm returns `.nothingMoves` (spec §4's "—" row) so `.research` subjects fall through to the manuscript arm. `manuscriptEditor`'s ZStack gains the preview as a THIRD layer above altitude, gated `persona.previewsThePublishedBook && publishPreview != nil` — subject-independent (Denver: a piece subject shows the SAME preview). `subjectShowsAltitude` itself is untouched; with no preview, Publish behaves exactly as 3a left it (design call 4).
- `showsStatusFooter` grows one more refusal: false while the preview overlay shows (same argument as altitude — every reading the doc comment at `:1192-1199` lists is about a document in the centre; the comment grows this one alongside).

**Contracts (the truth table, mounted):**
- [ ] Publish + compiled PDF: `.project` → preview; a DOCUMENT subject → the same preview; a group → preview; `.research`/a palette card → preview (the placement is `.nothingMoves`; assert the arm above no longer takes it — `test_aResearchSubjectIsTakenByTheArmAboveInEveryPersona` (`ResearchSubjectRoutingTests:140`) re-cuts to every persona EXCEPT publish).
- [ ] Publish + nothing compiled: `.project`/group → altitude; a document → the editor; `.research` → altitude (it now reaches `subjectShowsAltitude`, which answers true for a non-document). The corkboard click-through in uncompiled Publish still opens the chapter (`ProjectAltitudeCentreTests:563`'s re-cut keeps its click).
- [ ] Author and Review truth tables unchanged — `test_aDocumentSubjectIsTheEditorAndNeverAltitude` (`:90`) narrows its persona set to Author/Review with a publish-uncompiled control; `test_reviewAndPublishShowTheSameAltitudeAsAuthor` (`:361`) re-derives (Review keeps altitude always; Publish only uncompiled).
- [ ] `EditorHost` is torn down ZERO times across a preview↔editor↔altitude round trip (extend the Task-2-of-3a host-lifetime recorder across the new overlay); the `manuscriptEditor(`/`EditorHost(` source-scan censuses unchanged.
- [ ] The footer never shows over the preview; it still shows over a document in uncompiled Publish.
- [ ] Compile-completes refresh: with the window on Publish, a `.maughamPublicationCompleted` post lands the new publication without relaunch (integration-level; `PublishingStores._resetForTesting()` in setUp/tearDown — the singleton leaks across tests, `PublishingStores.swift:42-48`).
- [ ] A catalog row whose file was deleted resolves PAST it to the next-newest readable PDF, or to nil (altitude) when none remains.
- [ ] `ProjectSubjectReachabilityTests`: the publish `.nothingMoves` placement is exempt by that test's own rule; assert the tree can still write the subject away.
- [ ] Release build; commit.

### Task 6: Review adjudicates — the read-only centre

**Files:**
- Modify: `Maugham/Models/Persona.swift` (one new predicate), `Maugham/Views/ResearchSubjectColumns.swift` (`ResearchSubjectCentre`, `:210-238`), `Maugham/Views/ResearchNoteEditor.swift` (posture pass-through; the `:33-34`/`:56` comments that say "research notes have no review posture" become false and must move with the code), `Maugham/Views/Palette/PaletteWallView.swift` (the card arm)
- Test: new `MaughamTests/ReviewAdjudicationTests.swift`; extend `ResearchSubjectRoutingTests`

**Interfaces:**
- Produces: `Persona.editsResearchInTheCentre: Bool` — false only for `.review`; the ONE spelling, read by `ResearchSubjectCentre`'s mount and `PaletteWallCentre`'s card arm (never `== .review` at a use site).
- `ResearchSubjectCentre` gains `let readOnly: Bool` (threaded from the mount off the predicate). When true: the `.paletteCard` arm mounts `PaletteCardReadView(card:images:)` (`Maugham/Views/Palette/PaletteCardReadView.swift:26-28`; `AssistantColumn.swift:200` is the loading precedent for `images:`) instead of `PaletteCardEditor`; the `.note` arm passes `lockEditing: true` into `ResearchNoteEditor`, which forwards it to its own `EditorControl` (`EditorControl.lockEditing`, `Maugham/Editor/EditorControl.swift:21` — the field exists and defaults false). `.preview` and `.missing` arms unchanged (already read-only).
- `PaletteWallCentre` in Review: a card click shows `PaletteCardReadView` under the existing back-chevron header instead of the editor.

**Contracts:**
- [ ] Review, research note in the centre: typing lands nothing, text remains selectable/scrollable (a LOCKED editor, not a hidden one — §4's "reference view").
- [ ] Review, palette card in the centre and on the wall: no editable field, no mutation verb reachable.
- [ ] Author unchanged (both editors still edit); Plan's beside-the-canvas preview unchanged; Publish is Task 5's (`.nothingMoves` — the centre never mounts these there).
- [ ] The TREE's verbs stay live in Review — creation/rename/delete belong to the tree in every persona (stage 2a's rule); one control test pins a rename from Review's tree still landing.
- [ ] The right-column `InspectorResearchPanel` is deliberately out of scope (metadata panel, not the content editor) — recorded in the report, not silently.
- [ ] `PaletteCardReadView` now has three mounts (assistant column, Review centre, Review wall) — if its props creak under the third, fix the shape, don't fork the view.
- [ ] Commit.

### Task 7: The fold opens for a reveal

**Files:**
- Modify: `Maugham/Views/BinderTreeSections.swift` (`BinderTreeSectionsState` `:773-874`; `reveal` `:851-871`), `Maugham/Views/BinderView.swift:189-203` and `Maugham/Views/CollectionPiecesPane.swift:215-229` (the fold `DisclosureGroup`s take bindings), `Maugham/Views/BinderPieceFold.swift` (`:41-67` — pass `expandedGroups`), `Maugham/Views/ProjectWindow.swift:2343-2349` (`openResearchItem`) and `:2695-2705` (`handleShowLatestMCPNote`) — the two `reveal` call sites widen
- Test: extend `MaughamTests/BinderTreeSectionsTests.swift`, `MaughamTests/ResearchSubjectRevealTests.swift`, `MaughamTests/BinderPieceFoldTests.swift`

**Interfaces:**
- Produces on `BinderTreeSectionsState`: `var expandedPieceFolds: Set<String>` (document ids, open ids only, default empty — folds start closed exactly as the no-binding initialisers left them; a stale id sits harmlessly, `selection`'s own rule) and `func foldExpansion(of documentId: String) -> Binding<Bool>` mirroring `ResearchTreeNode.expansion(of:)`'s shape (`ResearchTree.swift:118-127`). Both fold `DisclosureGroup`s (`BinderView`, `CollectionPiecesPane`) take `isExpanded: state.foldExpansion(of: item.id)`.
- `BinderPieceFold` passes `expandedGroups: $state.expandedResearchGroups` into its `ResearchTreeNode` (`ResearchTree.swift:94`'s nil default stops applying to folds) — fold-internal groups join the same set the shared section uses; ids are distinct across the manifest by construction.
- `reveal` widens and narrows at once: `@discardableResult func reveal(_ itemId: String, structure: [StructureItem], research: [ResearchItem], projectType: ProjectType) -> BinderSubject?` — returns the row the tree can now show (`.research(id)` for a shared/palette id; `.item(ownerDocId)` for a piece-scoped id, whose fold it opened; `nil` when the id lives in no tree — the NARROWED guard, closing the spurious shared-section move the handoff recorded at `:311-317`). Ownership resolves through `TreeSectionDerivation` (`sharedResearchRoots`, `pieceFold(for:structure:research:projectType:)`) — the one lookup, never a second path-prefix spelling. Task 8 consumes the return as the scroll target.

**Contracts:**
- [ ] A piece-scoped research id: reveal opens that piece's fold plus its ancestor groups and does NOT touch `researchSectionExpanded` — the regression test states the old symptom (the shared section used to open onto nothing).
- [ ] A shared id and a palette id: behaviour unchanged (section + ancestor groups / palette section).
- [ ] An id in NO tree: nothing moves, return nil.
- [ ] Reveal still only opens; collapsing stays the writer's click — and the writer's fold chevron round-trips through the bound state (mounted: click open, click closed, state agrees both times).
- [ ] A `.linked` (novel) fold: a linked note reveals via the SHARED section — the fold's duplicate row (`BinderPieceFold.swift:50-58`) stays untouched; both rows still highlight as the one subject.
- [ ] Claude's Show on a Collection piece's note (mounted): the fold opens and the row exists on screen.
- [ ] The pairing census (`TripwireGrepTests.test_everyBinderTreeMountsBothHalvesOfTheSections`) still passes untouched.
- [ ] Commit.

### Task 8: Arrival is visible — scroll, and the find posture

**Files:**
- Modify: `Maugham/Views/BinderTreeSections.swift` (state + the target enum), `Maugham/Views/BinderView.swift`, `Maugham/Views/CollectionPiecesPane.swift`, `Maugham/Views/SceneNavigatorPane.swift` (each: `ScrollViewReader` around the `List`, consume, `.id()`s), `Maugham/Views/ProjectWindow.swift` (`:348-356` ⌘⌥R/⌘⌥P; `:835-841` the find-match handler; the two reveal callers feed scroll from Task 7's return)
- Test: extend `MaughamTests/AltitudeKeyspaceTests.swift` and `MaughamTests/ResearchSubjectRevealTests.swift`; new find-posture cases beside `TreeFindOverlayTests`

**Interfaces:**
- Produces: `enum TreeScrollTarget: Hashable { case researchHeader; case paletteHeader; case row(BinderSubject) }` (Hashable, not just Equatable — the header cases are `.id()` values) and `var scrollRequest: TreeScrollTarget?` on `BinderTreeSectionsState` — a one-shot: whichever tree host is mounted consumes it (`proxy.scrollTo(_, anchor: .center)`, then nil). Consumption hangs on BOTH `.onChange(of: state.scrollRequest)` AND mount (`.task`/`.onAppear`) — the find overlay REPLACES the column (`BinderPaneToggle.swift:47-51`), so a request written while it covers the tree is consumed when the tree remounts.
- `.id()` targets, unambiguous by construction: the two section headers carry `.id(TreeScrollTarget.researchHeader/.paletteHeader)`; structure rows `.id(BinderSubject.item(id))`; SHARED-SECTION research rows `.id(BinderSubject.research(id))` — the fold's duplicate row carries NO `.id` (the same `.research(id)` tag is deliberately mounted twice in a novel's `List`; a `scrollTo` over two identical ids is ambiguous). A piece-scoped reveal scrolls to the OWNING piece's row — exactly what Task 7's `reveal` returns.
- Writers: ⌘⌥R/⌘⌥P set their section expanded (existing, still refused under `treeFindActive`) AND `scrollRequest = .researchHeader`/`.paletteHeader`; `openResearchItem`/`handleShowLatestMCPNote` set `.row(revealResult)` when reveal returned one; the find-match handler (below) likewise.
- The find posture (design call 5): the `.maughamFindMatchSelected` handler (`ProjectWindow.swift:835-841`) gains, on BOTH arms of `matchSubject` (`:1324-1336`): `treeState.reveal(...)` + the scroll request from its return. The research arm thereby gets the full arrival posture (`openResearchItem`'s own shape); the column reveal already follows from the subject observers; the manuscript arm's editor scroll stays `EditorCoordinator`'s (its independent observer). The overlay stays up — no `applyCloseFind` here.

**Contracts:**
- [ ] Mounted: ⌘⌥R with the Research section closed and scrolled far off-screen → the section expands AND its header lands on screen.
- [ ] Claude's Show on an off-screen nested note → the row is on screen after reveal + scroll; on a Collection piece note → the PIECE row is.
- [ ] Find, research match: subject written, section expanded beneath the overlay, and — after Esc closes the overlay — the pending scroll is consumed on remount and the selected row is visible (one mounted end-to-end).
- [ ] Find, manuscript match: everything it did before, plus its tree row scrolls; the editor's text scroll is untouched (`EditorCoordinator`'s observer, not this handler's).
- [ ] The one-shot: an unrelated state change after consumption does not re-scroll; two requests in a row land the second.
- [ ] The overlay stays up across a match click (existing behaviour, now pinned beside the new posture).
- [ ] No new reader of `state.selection` raw (T3's rule) — the census that guards it stays green.
- [ ] All three hosts consume (the screenplay tree has the same sections); CI-display rule respected on the mounted scroll assertions.
- [ ] Commit.

### Task 9: Link Research… returns

**Files:**
- Restore: `Maugham/Views/ResearchLinkPickerSheet.swift` (from `git show 4dfcab8f~1:Maugham/Views/ResearchLinkPickerSheet.swift`, rewritten as below)
- Modify: `Maugham/Views/BinderTreeSections.swift` (`BinderTreeSectionsState` gains `var linkPickerDocumentId: String?`; `BinderTreeSectionsPresentations` gains the sheet), `Maugham/Views/BinderView.swift:238-261` (document-row context menu)
- Test: new `MaughamTests/ResearchLinkPickerTests.swift`

**Interfaces:**
- The verb: "Link Research…" on DOCUMENT rows only, and only where `ResearchScope.researchRouting(for:)` answers `.sharedPlusLink` (`ResearchScope.swift:20-24`) — a Collection's contained pieces and a screenplay's single file offer no link verb, the same boundary `BinderTreeDrops` already enforces on the drag path. The verb sets `state.linkPickerDocumentId`.
- The sheet: the restored UI (search field, kind-icon rows, per-row `.switch` toggles, Done) with TWO changes from the deleted original: the `try?`-swallowed `linkResearch`/`unlinkResearch` calls route through the tree's error discipline instead (a store throw surfaces via `state.pendingError` and the shared alert — `BinderTreeVerbs.perform`'s shape, `BinderTreeSections.swift:704`), and the presentation attaches in `BinderTreeSectionsPresentations` (a sheet inside a lazy `List` is presented from a view the list may unmount — the pairing census's own reason). Store APIs unchanged: `linkableResearchItems(forDocumentId:)` (`ResearchScope.swift:210`), `linkedResearchIds(forDocumentId:)` (`ProjectStore+Structure.swift:866`), `linkResearch`/`unlinkResearch` (`ProjectStore+Structure.swift:823/:845`).

**Contracts:**
- [ ] A novel chapter row's context menu shows "Link Research…"; the picker opens, searches by title, toggles link/unlink live; Done dismisses.
- [ ] A store throw surfaces in the shared alert (planted throwing store) — the deleted sheet's silent `try?` does not return.
- [ ] The verb is reachable by keyboard/VoiceOver (the context menu — the modality the 3a fix wave recorded as narrowed; state the VoiceOver route in the report).
- [ ] No verb on: a group row, a Collection piece row, any screenplay row — one assertion per boundary.
- [ ] The document's fold reflects a fresh link without relaunch (the linked fold draws `linkedResearchIds` off the live manifest).
- [ ] The pairing census (`test_everyBinderTreeMountsBothHalvesOfTheSections`) still passes; no host mounts the sheet locally.
- [ ] Commit.

### Task 10: Docs catch up

**Files:**
- Modify: `docs/guide/structure-and-binder.md` (the travel rule, Link Research…), `docs/guide/research.md` (Review's read-only centre, the link verb), `docs/guide/right-pane.md` + persona/getting-started pages as touched (Publish's preview centre, the wall door's travel), `docs/roadmap.md` (the 3a entry grows 3b; stage 3 closes), `CLAUDE.md` (the Views and Canvas rows), `Maugham/Views/AREA.md`, `Maugham/Canvas/AREA.md` — including the STALE line at `:314` (it says `rebuildHighlight()` and "those two `.onChange`s"; reality is `rebuildHighlightAndTree()` and three triggers — the survey flagged it; fix it while the dim section is open anyway)
- Test: `DocSyncTests` stays green

**Contracts:**
- [ ] Docs describe what SHIPS, not what's planned (workflow rule 7) — write each page against the built behaviour of the merged tasks, not this plan's prose.
- [ ] No prose COUNTS introduced anywhere — name members or point at the census (the standing lesson; tripwire 32's cell is the cautionary record).
- [ ] `docs/guide/reference.md`: no shortcut changed MEANING in 3b (⌘⌥R/⌘⌥P gained a scroll, same meaning) — verify the three 3a rows still read true and say so in the report.
- [ ] CLAUDE.md's Canvas row gains the research-highlight case and its degrade chrome; the Views row gains the travel rule, the preview centre, the read-only Review centre, the bound fold state, and the picker's return — each as pointers, not restatements.
- [ ] Roadmap: stage 3's line flips with the 3b scope named; the "3b is deliberately unplanned and owed" sentence dies.
- [ ] Commit.

---

## After the tasks — the whole-branch review, seams named

Dispatch it WITH these seams (the ledger discipline — every branch since M1A has paid for this):

1. **Four persona writers** (`PersonaModifier`, `ManuscriptNavigation.go`, `CanvasClaudeArrivalModifier.show`, the `TreeTravel` receiver) × the wall/collapse observers (`PaletteWallModifier`, `CanvasCollapseModifier`) — does any pair compose into a stuck inspector stash, a reappearing wall, or a `columnVisibility` left collapsed? Task 4's pending-token is the newest moving part; drive travel → Esc → travel → ⌘1 → ⌘2 through the mounted window.
2. **The preview overlay × altitude × footer × navigation INTO Publish** — a wiki-link or annotation row followed from Publish now lands on the whole-book preview, not a scrolled editor (`ManuscriptNavigation`'s scroll half reaches an editor that is covered). Intended fallout of Denver's piece-subject decision; verify it degrades sanely and record it.
3. **The research dim × restore/validation × the arrival reveal** — a relaunch with a research subject persisted must dim without moving the camera; a research id deleted while selected must fall to `.wholeProject` through `SubjectValidationModifier` with the chrome gone.
4. **`reveal`'s widened signature × the find handler × scroll consumption on overlay teardown** — the request written under the overlay must survive the tree's remount exactly once.
5. **Review read-only × the wall × `PaletteCardReadView`'s third mount** — no mutation path via the wall's Review arm; the shared view serves three masters without forking.
6. **Publish's `.nothingMoves` × `ResearchRevealModifier` × a restored research subject in Publish** — nothing forces a pane, nothing renders nothing.

Merge only after the full gate (`./scripts/test.sh full`) and the review's fix wave; Denver's smoke closes the milestone (stage 3 whole = 3a's recorded smoke list + this plan's mounted contracts, consolidated at handoff time).

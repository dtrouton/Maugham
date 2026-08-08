# Shell Finish Plan 2a — the tree grows

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The one tree exists: Research and Palette become sections of every binder tree, each piece unfolds to its own research, selection of any of it is the window's one subject with one sweep, and dragging a note between a fold and the shared section is the shipped scope move given its gesture.

**Architecture:** Spec `docs/superpowers/specs/2026-08-08-shell-finish-design.md` §3/§9 stage 2, delivered as TWO plans (rule 12 — the whole stage is ~13 tasks). **2a grows the tree beside the still-living strip** (the stage-1 precedent: an interim the next plan makes permanent); **2b — planned after 2a builds, per rule 11 — kills the strip, the segment registries and the per-persona binder memory, makes find an overlay and trash a foot disclosure, and does the guide sweep.** Nothing in 2a edits `Persona.binderSegments(for:)` or the picker.

**Tech Stack:** Swift 6 / SwiftUI, XCTest, mounted-window tests on the parallel scheme.

## Global Constraints

- Contracts not bodies; TDD; `./scripts/test.sh` per task, `./scripts/test.sh full` before merge; Release build after any `ProjectWindow.body` change; commit per task; **no push**.
- **One new `BinderSubject` case, not two.** Palette cards ARE research items (`PaletteCard.id = researchItemId`, `Packages/MaughamCore/Sources/MaughamCore/PaletteCard.swift:95`; `addPaletteCard` is `addResearchTextNote` under `research/palette/`, `ProjectStore+Palette.swift:51`). A `.paletteCard` case would be a second name for the same id. `.research(String)` names any research item; rendering resolves card-vs-note by the path-prefix rule already shipped at `ProjectWindow.swift:1251-1256` — the same argument `BinderSubject.swift:42-47` makes for document-vs-group.
- **No `default:` on any switch over `BinderSubject`** — the no-default discipline carries (CLAUDE.md Views row).
- **The fold's meaning follows `ProjectStore.researchRouting(for:)`** (`ResearchScope.swift:45-66`), never a new rule: `.pieceFolder` (collection loose piece) → contained roots, drag-in is a move; `.sharedPlusLink` (novel chapter) → linked items, drag-in is a link; `.sharedOnly` (short story/screenplay) → no fold, no per-piece target.
- **Tree drop routing is lookup-and-refuse, not prefix.** Both id spaces in the tree (structure, research) are incumbents whose bare-`String` payloads are shipped contracts (`ResearchRow.swift:64` feeds `CanvasDrop`'s `itemID` lookup and `LinkedResearchPane.swift:192`); re-prefixing them breaks two external consumers. The `CanvasDrop.swift:25-40` ruling ("a second id space arrives prefixed") governs NEW spaces; here the tree routes by manifest lookup and refuses misses loudly — the same shape `CanvasDrop.decide` uses.
- **2a is single-select.** Research multiselect (batch move/delete) stays alive in `ResearchView`/`CollectionResearchPane` behind the strip; **2b must preserve that capability when it kills those panes** — this is a named carry, not a drop.
- **The binder column's width range stays** (`ProjectWindow.swift:158-160`). It is one spelling that never varies by persona or pane — the felt bug the width rule answers doesn't exist on the left. Recorded decision; revisit only if Denver feels it.
- Tripwire 16 (rename focus), tripwire 4 (no per-row I/O — palette cards load via `.task(id: store.manifest.modified)`), the drop-ordering rules (`.dropDestination(for: String.self)` mounted BEFORE `.onDrop(of: [.fileURL, .image])`, `CollectionResearchPane.swift:105-123`; an empty `Section`'s section-level drop never fires, `:76-85`).
- Subagent models: opus for tasks 4–7 (SwiftUI composition on the Editor-adjacent window), sonnet for 1–3, haiku task 8; reviewers haiku.

---

### Task 1: `.research` joins the subject

**Files:**
- Modify: `Maugham/Models/BinderSubject.swift`, `Maugham/Stores/UIState.swift:177-241` (codec), `Maugham/Canvas/CanvasSubject.swift:86-104`, `Maugham/Views/SceneNavigatorPane.swift:175-199` (the two projection functions)
- Test: `MaughamTests/BinderSubjectTests.swift`, `MaughamTests/Canvas/CanvasHighlightTests.swift`

**Interfaces:**
- Produces: `BinderSubject.research(String)`; `var researchID: String?` (nil for `.project`/`.item`). `itemID` KEEPS meaning "structure item id" and returns nil for `.research` — its doc comment says so, since every existing reader assumes structure (`activeItemID`, `OutlineTable.swift:32`, `CanvasSubject.resolve` callers). `activeDocId(for:)` therefore yields `noDocumentSubject` for a research subject with no code change — assert it, don't re-derive it.

**Contracts:**
- [ ] The codec gains a THIRD discriminated key (`selectedResearchItemId`), no schema bump: `.item` keeps writing legacy `selectedItemId`, `.project` its flag. An old build reading a new file sees nil subject → lands `.project` via its own `validSubject` — tolerant by construction. Tests: every subject round-trips; the research case touches neither legacy key; `test_theNewCaseDidNotCostASchemaBump` extended.
- [ ] Every switch over the enum answers for `.research` with no `default:`. `CanvasSubject.resolve` answers `.wholeProject` — the dim is entered only by a piece/group click (`CanvasSubject.swift:42-46`'s own posture); the stage-3 card highlight is a new `CanvasSubject` case, not this task's. `SceneNavigatorPane`'s pure projections treat `.research` as pass-through-foreign for now (listSelection nil / write keeps current); Task 4 revises when the pane hosts research rows.
- [ ] `OutlineTable.rowSelection` (`OutlineTable.swift:30-34`) re-read: `get` via `itemID` is already research-safe (nil), `set` only ever writes `.item` — comment records it.
- [ ] Commit.

### Task 2: One sweep, all of it

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift:2230-2240` (`validSubject`), `:2411` (restore), `Maugham/Views/SubjectValidationModifier.swift`
- Test: `MaughamTests/SubjectValidationTests.swift`, `MaughamTests/SubjectRestoreTests.swift`

**Interfaces:**
- Produces: `static func validSubject(_:in structure: [StructureItem], research: [ResearchItem]) -> BinderSubject` — `.research(id)` valid iff `TreeWalk.find(id:in: research)` hits (the exact existence check the centre already uses at `ProjectWindow.swift:1248`); invalid → `.project`, same landing as a dangling item.
- Produces: `SubjectValidationModifier.fingerprint` covers `structure` ids ∪ `research` ids (one sorted, separator-joined hash — stays blind to title/order/nesting so rename/reorder/scope-move cannot fire it; a scope MOVE keeps the id, so a subject survives its own rescope — assert that).

**Contracts:**
- [ ] Both callers of `validSubject` (restore `:2411`, sweep `SubjectValidationModifier.swift:52`) pass research; no third spelling appears.
- [ ] Mounted tests close the recorded gap (**no test anywhere pins a research or palette selection sweep today**): delete a selected research note → subject sweeps to `.project`; delete a selected palette card → same; an out-of-band store arrival (the MCP/merge path `SubjectValidationTests` already models for structure) → same. The hand-rolled `pruneSelectionAfterDelete` pair (`ResearchView.swift:294`, `CollectionResearchPane.swift:462`) stays untouched — it guards the OLD panes' own `@State` until 2b deletes them.
- [ ] Commit.

### Task 3: The section derivations, pure

**Files:**
- Create: `Maugham/Views/TreeSectionDerivation.swift`
- Modify: `Maugham/Views/ResearchTree.swift:37` (`ResearchTreeNode` grows a tag closure)
- Test: `MaughamTests/TreeSectionDerivationTests.swift` (new)

**Interfaces:**
- Produces: `enum TreeSectionDerivation` with pure statics, all taking manifest values (no store, testable without disk):
  - `sharedResearchRoots(research: [ResearchItem], projectType: ProjectType) -> [ResearchItem]` — top-level roots MINUS the palette group (`role == .paletteGroup` — first-ever palette filter on a research surface: today `ResearchView.swift:19` renders it inside the tree, the spec makes Palette its own section) and MINUS, for collections, roots under any `pieces/` prefix (the `CollectionResearchPane.sharedItems()` rule at `:286`, hoisted).
  - `pieceFold(forDocumentId:manifest:store-free inputs) -> PieceFold` where `struct PieceFold { let items: [ResearchItem]; let semantic: Semantic }`, `enum Semantic { case contained, linked, none }` — derived from the routing: `.pieceFolder` → `pieceResearchSectionRoots` shape (tree, groups expandable), `.sharedPlusLink` → resolved `linkedResearchIds`, `.sharedOnly`/reference-piece/throw → `.none`. NOTE: `pieceResearchSectionRoots`/`researchRouting` live on `ProjectStore` — extract their pure cores or take pre-fetched inputs; the task's report defends which, but the derivation itself must be unit-testable per project type without a window.
- Produces: `ResearchTreeNode` parameterized with `tagFor: (ResearchItem) -> ...` (or a generic tag) so `ResearchView` keeps tagging bare `String` (its `Set<String>` selection — zero behavior change, its tests hold) while the tree tags `.research(item.id)`.

**Contracts:**
- [ ] Exhaustive unit tests per project type: novel, collection (loose + reference piece), short story, screenplay; palette group never in shared roots; a collection's piece-scoped roots appear in no shared list.
- [ ] Commit.

### Task 4: The sections mount

**Files:**
- Modify: `Maugham/Views/BinderView.swift` (after `outline(items:)`), `Maugham/Views/CollectionPiecesPane.swift`, `Maugham/Views/SceneNavigatorPane.swift` (sections + projection revision), `Maugham/Views/ProjectWindow.swift:984/:992` (new-note actions select the subject)
- Test: `MaughamTests/BinderProjectRowTests.swift`, `MaughamTests/CollectionProjectRowTests.swift`, `MaughamTests/SceneNavigatorProjectRowTests.swift`, new mounted cases

**Contracts:**
- [ ] All three tree hosts append a **Research** `Section` and a **Palette** `Section` below their existing rows. The project row stays row zero (sections sit BELOW — the measured `BinderView.swift:12-32` constraint was about wrapping the head, not appending; every mounted row-count assertion updates in the same commit). Research rows are `ResearchTreeNode` tagged `.research`; palette rows are flat, titled per card, tagged `.research(card.id)`, loaded via `.task(id: store.manifest.modified)` (the `PaletteBinderList.swift` shape — no per-row I/O).
- [ ] `SceneNavigatorPane`'s projections widen: a `.research` write passes through (its List now contains rows that mean it); the planted-offender test gets a research twin.
- [ ] Section headers carry the creation affordances as context menus: Research → New Note / New Group / Add File / Add Link (the `ResearchTreeActions` verbs, wired to the same store APIs `ResearchView` uses); Palette → New Card (kind menu, `PaletteBinderList.swift:24-33`'s menu relocated/duplicated). Creating from a header selects the new thing: `selectedSubject = .research(newId)`. The `addSharedNoteAction`/`addPieceNoteAction` window actions ALSO set the subject (they keep setting `selectedResearchId` for the still-living panes — both, until 2b).
- [ ] Empty sections: header always present (the tree is stable furniture); when empty, one faint placeholder row that is a full-width drop target (the `CollectionResearchPane.swift:76-85` lesson — a section-level drop on an empty Section never fires).
- [ ] Each host fills ONE `ResearchTreeActions` bundle for its sections (rename / duplicate / delete / Move-to submenu / the creation verbs), wired to the same store APIs the old panes use — `CollectionResearchPane`'s wiring is the prototype; `internalDrop`/`externalDrop` closures are stubs until Task 7 fills them (a stub REFUSES, never no-ops silently).
- [ ] Inline rename on research rows reuses `ResearchRow` unmodified (tripwire 16 intact).
- [ ] Mounted test: in EVERY persona (the strip still varies segments, the tree does not — mount each host directly), clicking a research row writes `.research(id)` through the real `List(selection:)` binding; clicking a palette row likewise; the project row still selects `.project`.
- [ ] Release build (ProjectWindow.body changed); commit.

### Task 5: The centre follows a research subject

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift` (`existingEditorSwitch` `:1211-1297`, `existingInspectorSwitch` `:1899-1935`, one new routing helper)
- Test: new `MaughamTests/ResearchSubjectRoutingTests.swift` (mounted, per persona)

**Interfaces:**
- Produces: `static func researchCentreRoute(id: String, manifest:) -> ResearchCentreRoute` — `enum ResearchCentreRoute { case paletteCard(String), note(ResearchItem), missing }`, the `:1251-1256` path-prefix rule (`ProjectStore.paletteFolderPath`) extracted to ONE function so the (still-living) `.research` segment arm and the new subject arm cannot drift. Both call it.

**Contracts:**
- [ ] Where the centre is NOT the canvas (`!binderSegment.centresTheCanvas` — Author/Review/Publish today), a `.research` subject takes precedence over the segment switch: centre renders `PaletteCardEditor` (card) or `ResearchNoteEditor` (note) or `ResearchPreview` per the route; right column renders `InspectorResearchPanel`. This is spec §4's Author cell shipped early; Review's read-only refinement is stage 3.
- [ ] Where the centre IS the canvas (Plan's `.canvas`/`.tree`), the canvas STAYS MOUNTED — a `.research` subject must not swap the centre and destroy the one canvas identity (`CanvasTreeSegmentMountTests`' measured contract). Instead the RIGHT column previews the item (spec §4's Plan cell: "preview in the right column" — mount `ResearchPreview`/`InspectorResearchPanel` in the inspector arm). The board stays undimmed (Task 1's `.wholeProject` resolution).
- [ ] `metrics` zeroing on non-document subjects (`ProjectWindow.swift:323-334`) already covers `.research` via `selectionIsDocument` — assert, don't re-implement.
- [ ] Mounted delivery tests: one per persona — select a research row, assert the actual mounted editor/preview (the mode-UX lesson: model the real delivery path, not the route function alone). Include the palette-card-in-research-tree case (the lost-update precedent the `:1251-1256` comment records).
- [ ] Release build; commit.

### Task 6: The piece unfolds

**Files:**
- Modify: `Maugham/Views/BinderView.swift` (`outline`/`row(for:)`), `Maugham/Views/CollectionPiecesPane.swift`
- Test: mounted cases in the Task 4 suites + `TreeSectionDerivationTests`

**Contracts:**
- [ ] A piece row whose `pieceFold.semantic != .none` AND `items` non-empty renders as a `DisclosureGroup`: the piece row itself (unchanged `BinderRow`/`PieceRow`, still draggable/renamable), unfolding to its research items tagged `.research` — collection loose pieces show contained roots (tree shape, nested groups expand), novel chapters show linked items (flat). An empty fold renders NO chevron (noise); the piece row is still a drop target (Task 7), which is the affordance for the first item.
- [ ] Reference pieces in a collection and all of short story/screenplay: no fold — assert per project type.
- [ ] The fold is derived per render from the manifest (no cached parallel state); per-row cost is a manifest walk, not I/O (tripwire 4) — if profiling shows O(N²) on large structures, memoize keyed on `manifest.modified`, not on ids (tripwire 22's spirit).
- [ ] Mounted: selecting a folded research item writes `.research(id)`; deleting it sweeps (Task 2's machinery, now reachable from a fold).
- [ ] Commit.

### Task 7: Drag is scope

**Files:**
- Create: `Maugham/Views/TreeDropIntent.swift`
- Modify: `Maugham/Views/BinderView.swift`, `Maugham/Views/CollectionPiecesPane.swift` (drop targets on piece rows, fold regions, the shared Research section + its empty row)
- Test: `MaughamTests/TreeDropIntentTests.swift` (new, exhaustive), mounted wiring census

**Interfaces:**
- Produces: `enum TreeDropIntent` with one pure classifier: `static func classify(payloadId: String, target: Target, structure: [StructureItem], research: [ResearchItem], projectType: ProjectType) -> Intent` where `enum Target { case pieceRow(String), sharedSection, researchRow(String) }` and `enum Intent { case rescope(ids: [String], to: ResearchMoveTarget), link(researchId: String, toDocumentId: String), unlink(researchId: String, fromDocumentId: String), researchReorder, structureReorder, refuse(Reason) }`.

**Contracts:**
- [ ] Routing is by manifest lookup: payload id found in `research` → research intents (a research id on a `.researchRow`/group target within the same scope → `.researchReorder`, delegated to the EXISTING `internalDrop`/`moveResearchItems` reorder path — the tree does not reinvent it); found in `structure` → `structureReorder` (delegated to the EXISTING `DropIntent.classify`/`store.moveStructureItem` path — this task does not touch structure reorder); found in neither → `.refuse(.unknownId)` — refused drops render as rejection (return false), never a silent no-op (the publishing-namespace lesson: fail loudly on silent no-op).
- [ ] Per routing truth: collection loose piece target → `.rescope(to: .piece(id))` via `store.moveResearchItems(ids:to:atIndex:)` (`ProjectStore+ResearchMove.swift:101` — validate-first, typed mover, role-bearing refusals all inherited, and the mover's own refusals surface as a shake/no-op with the reason logged); novel chapter target → `.link`; drag from a novel fold to the shared section → `.unlink`; drag from a collection fold to shared → `.rescope(to: .sharedRoot)`; short-story/screenplay piece targets → `.refuse(.sharedOnly)`. Insertion indices go through `ResearchSelectionSync.postRemovalInsertionIndex` (`ResearchTree.swift:155` — three shipped off-by-ones say so).
- [ ] Scope moves leave `linkedResearchIds` untouched (the dormant-link semantics, `ProjectStore+ResearchMove.swift:270-276`) — one test pins that a drag-rescope does not silently unlink.
- [ ] Drop-target mounting order per the census'd rules: `.dropDestination(for: String.self)` before any `.onDrop`; the empty shared section's placeholder row is the target.
- [ ] `classify` is tested exhaustively: every `Target` × {research id, structure id, unknown id} × the four project types; plus a planted offender (a classify that routes by id-shape instead of lookup) proving the tests can tell.
- [ ] The subject survives its own rescope (Task 2's fingerprint blindness — one mounted test drags a selected note into a fold and asserts selection holds).
- [ ] Commit.

### Task 8: Reconcile and hand forward

**Files:**
- Modify: `Maugham/Views/AREA.md` (if present — check; else CLAUDE.md's Views row), `docs/superpowers/notes/2026-08-08-session-handoff.md` (or a fresh 2a handoff note)
- Test: none (docs)

**Contracts:**
- [ ] Record in the handoff the named carries for **2b**, verbatim list: the strip's true death + `binderSegments`/`binderHome`/`PersonaMemory.binder` deletion; find as tree overlay (a REAL writer for the overlay state — `findActive` today has zero true-writers, `ProjectWindow.swift:92/:710`, and the Esc route CANNOT be the canvas arbiter while the query field holds focus, `CanvasEscapeMonitor.swift:96-101` refusal 3 — it needs its own delivery, with a mounted real-Esc test); trash as foot disclosure (Empty Trash toolbar item relocation, `TrashView.swift:14-21`; the restored-`UIState.binderSegment` values `"find"`/`"trash"` on existing machines must decode tolerantly); **multiselect batch move/delete must survive the panes' death**; re-points for `openResearchItem` `:2052`, `handleShowLatestMCPNote` `:2351`, the find-research-match known gap `:714-737`; `Persona.showsManuscriptDocuments` re-based when the registry dies (`Persona.swift:547` — its discriminator vanishes with the registry); the docs sweep list (explore notes: `getting-started.md:16/:24/:26/:28/:30`, `research.md:3/:5`, `sense-pass.md:30-32`, `right-pane.md:28/:49/:51`, `structure-and-binder.md:26`, `screenplay.md:15`, `publishing.md:15`, `reference.md` keys); the `Exports` footer's new gate; CLAUDE.md's Views-row switch list (it says eight, there are nine — `showsSceneNavigator(for:)` is missing; fix when the switches change).
- [ ] Note the recorded decisions: binder width range stays; 2a single-select; `.wholeProject` for research subjects on the canvas until stage 3's highlight case.
- [ ] Commit.

---

**Whole-branch review** (mandatory — seventeen consecutive finds), dispatch NAMING the seams: Task 1's codec × Task 2's validator (which ids are valid must agree); Task 4's rows × Task 5's routing (a row tagged `.research` must land somewhere in EVERY persona — walk each); Task 5 × the canvas identity (a research click in Plan must not remount the board); Task 6's fold semantic × Task 7's drop intent (a fold that RENDERS linked items while a drop MOVES would corrupt a novel's shared research); the still-living `ResearchView`/`CollectionResearchPane` × the tree (two surfaces over one manifest — old pane selection state is theirs, the subject is the window's; no cross-writes). Then merge unpushed; ledger + handoff line. **2b is planned only after this builds.**

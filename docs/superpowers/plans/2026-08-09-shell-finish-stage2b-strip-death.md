# Shell Finish Plan 2b — the strip's true death

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The segment strip, the per-persona binder registries, and the old research/palette panes die; find becomes an overlay of the one tree and trash a disclosure at its foot; every capability the dying panes carried (multiselect, external drops, paste, the palette wall) survives on the tree.

**Architecture:** Spec `docs/superpowers/specs/2026-08-08-shell-finish-design.md` §3/§6/§9 stage 2, second plan (2a built the tree; this plan removes its rivals). Derived from the post-2a census (this session) — key facts: `findActive` has ZERO true-writers, making the picker's find-gate and both toggles' find-exit arms dead code, so the overlay state is NEW construction; the tolerant `UIState`/`PersonaMemory` decodes ALREADY absorb removed enum cases (no migration, tripwire 11); every multiselect capability bottoms out in already-plural store APIs (`moveResearchItems`, `deleteResearchItems`) so the work is view-layer only; `BinderTreeSectionsTests.test_theOldPanesStillAcceptTheDropsTheyCanRoute` is the anti-vacuity CONTROL for the tree's refusal test and must be replaced in the same commit that deletes `ResearchView`. **Capability-preserving tasks (1–5) land BEFORE the kill (7)** so no commit removes a writer-facing capability even transiently.

**Tech Stack:** Swift 6 / SwiftUI, XCTest, mounted-window tests on the parallel scheme.

## Global Constraints

- Contracts not bodies; TDD; `./scripts/test.sh` per task, `full` before merge; Release build after any `ProjectWindow.body`-subtree change; commit per task; **no push**.
- **No `default:`** on any switch over `BinderSubject`, `Persona`, `TreeOverlay` (new), or any surviving `BinderSegment` predicate while the enum lives; the no-default discipline carries to every replacement (spec §6).
- **Order is load-bearing**: Tasks 1–5 give the tree the dying panes' capabilities; Task 6 re-bases predicates behavior-neutrally; only Task 7 deletes. A task must not depend on a later task's deletion.
- **The find overlay's Esc cannot route through the canvas arbiter** while the query field holds focus (`CanvasEscapeMonitor.swift:96-101` refusal 3 lets Esc through to text fields by design) — it needs its own delivery, proven by a mounted real-Esc test (the mode-UX delivery-path lesson).
- **Recorded decisions**: Exports footer shows where it shows today — every persona but Plan (`persona != .plan` exactly reproduces the pre-2b visibility, since Author/Review/Publish's one segment WAS the document home); the manuscript-status footer keeps Denver's 2026-08-02 ruling that an open find must not blank the goal capsule; the palette-name collision stays PARKED (Denver's call, not this plan's).
- **Deferred to stage 3, deliberately**: keyspace re-points (⌘⌥R/⌘⌥P/⌘⌥O, spec §5), registry thinning of the RIGHT pane, project-altitude centre. The right-pane `PalettePane`/`ResearchPane` are untouched here.
- Tripwire 16 (rename focus), tripwire 9 (no `.onTapGesture` rows), tripwire 4 (no per-row I/O), the drop-ordering censuses, tripwire 11 (no migrations — the tolerant decodes at `UIState.swift:227` and `PersonaMemory.swift:100` already absorb removed cases).
- Subagent models: opus tasks 1, 3, 4, 6, 7; sonnet tasks 2, 5, 8, 9; reviewers haiku for docs/small, sonnet for mounted-UI diffs.

---

### Task 1: Find is an overlay of the tree

**Files:**
- Modify: `Maugham/Views/BinderPaneToggle.swift`, `CollectionBinderPaneToggle.swift` (overlay mount above/instead of the tree), `Maugham/Views/ProjectSearchView.swift` (Esc + close unification), `Maugham/Views/ProjectWindow.swift:691/:709-713/:738-756` (open/close/match handlers)
- Test: new `MaughamTests/TreeFindOverlayTests.swift`; salvage `BinderSegmentPickerMountTests:727`'s contract (⌘⌥F reaches find's content with no picker)

**Interfaces:**
- Produces: `@State treeFindActive: Bool` on `ProjectWindow` (the overlay's REAL writer — `findActive` today has zero true-writers and its gates are dead code; delete `findActive` in the same commit), threaded to both toggles. While active, `ProjectSearchView` REPLACES the tree in the left column (spec: results replace it; Esc restores — the canvas-dim posture: deliberately entered, deliberately left). `binderSegment` is NOT written by ⌘⌥F any more; the `.find` case stays in the enum until Task 7 but nothing selects it.

**Contracts:**
- [ ] ⌘⌥F sets `treeFindActive = true` in every persona (the strip never mediates); ✕ and Esc both close via ONE path (`.maughamCloseFind` handler sets false; the ✕ posts it as today).
- [ ] Esc delivery: `.onExitCommand` on the overlay (or an equivalent view-level route — NOT the canvas arbiter, NOT an app-wide key equivalent, argued down at `CanvasEscapeMonitor.swift:36-42`); a mounted test synthesizes a REAL Esc keypress with the query field focused and asserts the overlay closes and the tree returns. If field-focused Esc first clears the field (AppKit cancel), a second Esc must close — pin whichever behavior ships.
- [ ] A match click writes the SUBJECT: manuscript match → the existing `.maughamNavigateToDocument` path (unchanged); research match → `selectedSubject = .research(id)` (closing the recorded gap at `ProjectWindow.swift:714-737` — the centre now follows the match's source through 2a's placement; delete the gap comment, its fix is real). `selectedResearchId` writes at `:750` retargeted.
- [ ] The manuscript-status footer stays visible while the overlay is open (Denver's 2026-08-02 ruling, `BinderSegment.swift:161`'s value carried onto the new basis in Task 6).
- [ ] The overlay survives a persona switch (it is window state, not segment state) — test.
- [ ] Commit.

### Task 2: Trash is a disclosure at the tree's foot

**Files:**
- Modify: `Maugham/Views/BinderPaneToggle.swift`, `CollectionBinderPaneToggle.swift` (foot mount), `Maugham/Views/TrashView.swift` (rows reused; the `ToolbarItem` at `:14-21` relocates)
- Test: new `MaughamTests/TreeTrashDisclosureTests.swift` (first-ever mounted trash coverage — the census found none)

**Contracts:**
- [ ] A `DisclosureGroup` at the tree's foot, present only when `!store.trashEntries.isEmpty` (the same expression the picker gate used), collapsed by default, rendering `TrashView`'s row content (title + "sweep in N days" + Restore / Permanently Delete context menu — reuse the row view, don't fork it).
- [ ] "Empty Trash" moves into the disclosure's header row (a button beside the label) — the window-toolbar `ToolbarItem` is deleted with a comment naming the move.
- [ ] Emptying the trash (restore-all, sweep, Empty Trash) removes the disclosure; the tree does not jump scroll position — assert row-count deltas only.
- [ ] Trash rows write no subject; browsing the trash never changes the centre (test: subject holds while the disclosure is open/interacted).
- [ ] `.trash` segment stays in the enum until Task 7 but nothing selects it (the two toggles' trash-emptied `.onChange` arms die HERE, since the segment is unreachable once ⌘⌥F stops writing `.find` and nothing writes `.trash` — verify by grep census in the test).
- [ ] ⌘⌥Z restore-last-deleted unchanged (`ProjectWindow.swift:679-683` untouched) — one test drives it with the disclosure mounted.
- [ ] Commit.

### Task 3: The tree learns multiselect

**Files:**
- Modify: `Maugham/Views/BinderTreeSections.swift` (`selectionForRow`, `BinderTreeSelection`), `BinderView.swift`, `CollectionPiecesPane.swift`, `SceneNavigatorPane.swift` (List selection type)
- Test: extend `MaughamTests/BinderTreeSectionsTests.swift` + `ResearchSelectionTests` patterns

**Interfaces:**
- Produces: all three tree hosts bind `List(selection: Set<BinderSubject>)`; the window's `selectedSubject: BinderSubject?` derives through pure `BinderTreeSelection` statics generalizing the shipped `ResearchSelectionSync.previewId` anchor semantics (single → it; grown set → keep the prior anchor if still selected, else ordered-first; empty → nil; a nil/untagged write still refuses — the 2a rule generalizes, it does not fork). Programmatic subject writes (navigation, restore, creation) set the set to `[subject]`.

**Contracts:**
- [ ] `selectionForRow` returns the ORDERED research members of the current set when the clicked row is in it (the `ResearchSelectionSync.orderedSelection`/`expandedDragIds` semantics — descendants of a selected group collapse, the shipped rule), else `[rowId]` — batch drag, "Delete N Items", and multi "Move to ▸" all flow through the EXISTING plural verbs (`moveResearchItems(ids:to:atIndex:)`, `deleteResearchItems(ids:)`) exactly as the old panes did; no new store API.
- [ ] Batch verbs offer only on homogeneous research selections; a set containing the project row or a structure item degrades every research verb to single-row (structure batch ops don't exist — don't invent them).
- [ ] The sweep prunes the SET (dead ids drop; the derived subject follows the anchor rule) — extend `SubjectValidationModifier`'s machinery, one sweep still.
- [ ] Mounted: ⌘-click two notes in the standard tree → "Delete 2 Items" appears and works; drag-multi into a collection fold rescopes both; the subject anchor survives a grown set. All three hosts get at least the selection-shape test.
- [ ] Single-click behavior is byte-identical to 2a (every existing mounted selection test stays green unmodified — they are the regression net for this task).
- [ ] Commit.

### Task 4: External drops, paste, and folder import land on the tree

**Files:**
- Modify: `Maugham/Views/BinderTreeSections.swift:322-325/:364` (the refusals + the panel), `Maugham/Views/BinderTreeDrops.swift`, `Maugham/Views/BinderPieceFold.swift`, `TreeDropIntent.swift` (external targets)
- Test: extend `BinderTreeDropRoutingTests` + `TreeDropIntentTests`; transfer the `bothDropKinds` census (`TripwireGrepTests:2390`) guarantee to the tree files

**Contracts:**
- [ ] External Finder-file/browser-image drops route by target, through `DropClassification` with `[.fileURL, .image]` providers (never `.dropDestination(for: URL.self)` — the canvas lesson), mounted AFTER the string destination on every shared target (the ordering census transfers):
  shared section header/placeholder/group row → `importResearchFiles(toParentId:)` (root or that group); collection piece row / contained-fold row → `importPieceResearchFiles` (the store API whose only caller today is the pane this plan deletes — this task gives it its tree caller BEFORE Task 7 removes the old one); novel chapter row/fold → import to shared + `linkResearch` in one act; short-story/screenplay piece targets → refuse (sharedOnly, as internal drops do).
- [ ] Root paste (⌘V of image/file/text/URL) re-homes: the window-level paste that `ResearchView.swift:317-378` owned fires when the subject is `.research` or the Research section has focus, creating in shared research exactly as the pane did (same `handlePaste` decision table — MOVE the logic, don't rewrite it; its tests move with it).
- [ ] Folder import: the tree's Add File panel allows directories again (`canChooseDirectories = true`, the `ResearchView.swift:252` behavior — 2a's `false` at `BinderTreeSections.swift:364` was an unflagged narrowing; restore parity and say so in the report).
- [ ] Every refusal remains loud (`-> Bool` censuses hold); the fold's external drop carries the fold's own `documentId` (the `.foldRow` shape from 2a).
- [ ] Commit.

### Task 5: The palette wall keeps a door

**Files:**
- Modify: `Maugham/Views/BinderTreeSections.swift` (Palette header affordance), `Maugham/Views/ProjectWindow.swift` (`applyPaletteSegmentChange:1669-1686` → re-keyed stash, wall centre mount `:1290-1308`)
- Test: new cases in `ResearchSubjectRoutingTests` / a small `PaletteWallDoorTests`

**Interfaces:**
- Produces: `@State showsPaletteWall: Bool` on `ProjectWindow` — the wall's post-segment door. The Palette section header gains an "Open Wall" affordance (button in the header, mirrored in its context menu). Deliberately-entered-left posture: Esc or any subject change closes it.

**Contracts:**
- [ ] Open: centre shows `PaletteWallView` full-width in Author/Review/Publish; in Plan the affordance is disabled with a tooltip (Plan's centre is the canvas — spec §4; the wall in Plan is stage 3's call). Selecting a card on the wall keeps today's behavior (`selectedPaletteCardId` → card editor centre with the back-to-Wall bar, `:1274-1290`'s shape).
- [ ] The inspector auto-hide/stash (`inspectorWasVisibleBeforePalette`) re-keys on `showsPaletteWall` transitions instead of `== .palette` (`clearsPaletteStash:2884` re-based; the pure function keeps its shape and tests).
- [ ] The wall closes on: Esc (same delivery decision as Task 1 — reuse, don't fork), subject change, persona change to Plan. Nothing else force-opens it.
- [ ] `.palette` segment stays in the enum until Task 7; nothing selects it after this task (grep census).
- [ ] Commit.

### Task 6: Predicates re-base while the enum still stands

**Files:**
- Modify: `Maugham/Models/Persona.swift` (new predicate), the 7 `centresTheCanvas` call sites (census §1c), `Maugham/Views/ScreenplayScriptSource.swift:59-60`, `ProjectWindow.swift:1149-1153` (`showsStatusFooter`), `ResearchSubjectColumns.swift:68-82` (placement reduction), `Maugham/Views/ManuscriptNavigation.swift:71`, both Exports footers (`BinderPaneToggle.swift:87-91` twin)
- Test: re-cut the affected halves of `CanvasCollapseTests`, `ManuscriptNavigationTests`, `BinderSegmentDocumentHomeTests`, `ScreenplayScriptSourceTests`, `ResearchSubjectRoutingTests`

**Interfaces:**
- Produces: `Persona.centresTheCanvas: Bool` (exhaustive over the four personas, true only for `.plan`) — the replacement basis for the segment predicate; and an explicit successor to `showsManuscriptDocuments` whose falsification test survives (the census's warning: deleting the registry must NOT degenerate `ManuscriptNavigationTests.test_theRuleIsAboutTheDocumentHome_notAboutAnyParticularPersona` into a tautology — keep the static's synthetic-input form so the discriminator still discriminates).

**Contracts:**
- [ ] Each of the seven `centresTheCanvas` callers re-bases on the persona predicate with BEHAVIOR IDENTICAL in every reachable state (in 2b, Plan's segments are `.canvas`/`.tree` both true, other personas' homes both false — the equivalence is exact; assert it once as a bridge test while both spellings exist, delete the bridge in Task 7).
- [ ] `showsSceneNavigator` collapses to `treePane(for:) == .sceneNavigator` (project type alone); `ScreenplayScriptSource.needsDerivation` follows.
- [ ] `showsStatusFooter`'s segment half re-bases: "the centre holds a manuscript document" = subject-is-document AND NOT persona.centresTheCanvas AND no overlay exception — with `.find`'s carried ruling (overlay open → footer stays). `BinderSegmentDocumentHomeTests`' exhaustive footer guard re-cuts against the new basis with its anti-vacuity control intact.
- [ ] `researchSubjectPlacement` reduces: `keepsItsOwnResearchSelection` deleted (its own doc comment scheduled this); `leftPaneWritesTheSubject` re-expressed — the trap-guard's QUESTION survives as "with the find overlay open, can the writer still clear the subject?" and `ProjectSubjectReachabilityTests:272`'s no-room-without-a-door test re-bases on persona × overlay states instead of segments.
- [ ] Exports footer: `persona != .plan && PublishStarter.isInitialized(...)` — reproduces today's visibility exactly (recorded decision); the two source-text censuses that pin the old spelling re-cut.
- [ ] Commit (Release build — ProjectWindow.body subtree).

### Task 7: The kill

**Files:**
- Delete: `Maugham/Views/BinderSegmentPicker.swift`, `Maugham/Views/ResearchView.swift`, `Maugham/Views/CollectionResearchPane.swift`, `Maugham/Views/Palette/PaletteBinderList.swift`
- Modify: `Maugham/Models/BinderSegment.swift` (the enum dies; `treePane(for:)` survives relocated — it is a `ProjectType` switch the hosts still need), `Persona.swift:385-523` (`binderSegments`/`binderHome` deleted), `PersonaMemory.swift` (binder half), `ProjectWindow.swift` (`binderSegment` state + persistence + `applyPersonaChange` thinning + `openResearchItem:2092`/`handleShowLatestMCPNote:2395` re-points + `selectedResearchId` deletion), `UIState.swift` (field dropped — stored keys go inert under the hand-rolled decoder, no migration), both toggles (collapse to: tree + find overlay + trash foot + Exports footer), `ManuscriptNavigation.swift`, `CanvasClaudeArrivalModifier.swift:176`
- Test: compile-driven sweep

**Contracts:**
- [ ] `BinderSegment` is GONE (or reduced to nothing but a relocated `treePane` helper — prefer gone; `TreePane` stands alone). Every dead predicate, the picker, the registries, the memory's binder half, the `Change.binderSegment` field, the UIState field and its `.onChange` persist go together. `openResearchItem`/`handleShowLatestMCPNote` write `selectedSubject = .research(id)` (+ reveal: expand the right section — reuse the tree's existing disclosure state if cheap, else select-only and note it).
- [ ] `selectedResearchId` dies (census: its only readers are the two arms deleted here; its five writers were re-pointed in Tasks 1/7). `selectedPaletteCardId` SURVIVES (the wall still uses it — census §5).
- [ ] The anti-vacuity control `BinderTreeSectionsTests:342` is REPLACED in this commit (its comment names this task): the tree's refusal test gets a control that genuinely accepts — the old panes are gone, so build it on a filled `BinderTreeVerbs` (a bundle whose drop verbs route) rather than a resurrected pane.
- [ ] `CanvasClaudeArrival.show` re-bases to persona-only; `ManuscriptNavigation.destination` re-bases to persona + subject with its census tests (`TransientSegmentReturnTests:351`'s salvage) re-cut.
- [ ] Dead test files deleted (`BinderSegmentPickerMountTests`, `PersonaBinderSegmentTests`, `TransientSegmentReturnTests`, `CanvasTreeSegmentMountTests`, `CanvasPersonaTests`) WITH their three salvages re-homed first (find-reaches-content → Task 1's suite if not already; the two `allCases where !centresTheCanvas` anti-degeneration loops → re-cut on persona in `CanvasCollapseTests` or a small successor; navigation census → `ManuscriptNavigationTests`). Case-literal sweeps per the census list (`UIStateTests:113/:129/:136`, `CanvasSegmentTests:28`, `BinderSubjectTests:162/:174`, …).
- [ ] `RegionBindingTests:1003`'s two-switch census and `TripwireGrepTests:1586/:3038`'s file lists re-cut per the census's per-test notes.
- [ ] Commit (Release build).

### Task 8: The guards land on their new bases

**Files:**
- Modify/create: the rewritten suites the census classifies (~13 files) that Task 7 could only make compile
- Test: this task IS tests

**Contracts:**
- [ ] Every guard the census marks "rewritten on a new basis" has a successor asserting the same PROTECTION: the placement matrix (persona × overlay × subject-kind, replacing the five-segment list whose reasons were all about dead panes); no-room-without-a-door (persona × find-overlay states); the footer exhaustives with anti-vacuity controls; PersonaMemory forward-compat re-based on the detail map (`PersonaMemoryTests:220` survives); the two anti-degeneration loops for `inspectorRoute`/`editorRoute` on the persona basis.
- [ ] A grep census over `Maugham/` proves no production spelling of `BinderSegment`, `binderSegments(`, `binderHome(`, `findActive`, or `selectedResearchId` survives (planted-offender companion; comment-stripping per the house pattern).
- [ ] `./scripts/test.sh full` green (documented flakes only, discriminator applied by name).
- [ ] Commit.

### Task 9: The docs catch up with the world

**Files:**
- Modify: `docs/guide/getting-started.md` (:16/:24/:26/:28/:30), `research.md` (:3/:5), `sense-pass.md` (:30-32), `right-pane.md` (:28/:49/:51), `structure-and-binder.md` (:26), `screenplay.md` (:15), `publishing.md` (:15), `reference.md` (keys unchanged — verify), `CLAUDE.md` (Views row: the switch list dies with the switches; describe the tree/overlay/disclosure; the count-the-switches instruction re-points), `Maugham/Views/AREA.md` (tree entry updated: overlay, disclosure, multiselect, external drops, the wall's door), the session handoff (2b closes; stage 3 carries recorded: keyspace re-points, registry thinning, project altitude, palette-name collision still Denver's, wall-in-Plan)
- Test: `DocSyncTests` if any gate applies

**Contracts:**
- [ ] Every guide sentence the census/transients report flagged is rewritten to describe what SHIPS (help describes what ships, not plans); no segment-picker prose survives anywhere in `docs/guide/`.
- [ ] CLAUDE.md's Views row rewritten against the post-2b shape (the stale eight-switch list and the `BinderSegment` prose go; the transient-restore rule sentence goes; point at AREA.md).
- [ ] Handoff addendum: "2b built, stage 3 owed" with Denver's 2b smoke list (find overlay open/Esc/match-follows-source in both id spaces; trash disclosure incl. Empty Trash; multiselect batch move/delete; external drop on a fold vs shared; paste; the wall's door; persona switches holding the one tree).
- [ ] Commit.

---

**Whole-branch review** (mandatory — eighteen consecutive finds), dispatch NAMING the seams: Task 1's overlay × Task 6's footer/reachability bases (find open in every persona); Task 3's Set selection × 2a's sweep and drop `selectionForRow` (anchor rule vs fingerprint); Task 4's external routes × Task 7's pane deletion (no import path lost — walk each of the census §5 capabilities to its new home); Task 5's wall × Task 6's persona predicate (Plan's disable) × Task 7's `selectedPaletteCardId` survival; Task 6's bridge equivalence × Task 7's deletion of the bridge; Task 7 × Task 8 (every salvage named in the census actually re-homed — read the census §7 list against the tree, not the ledger). Then merge unpushed; ledger + handoff. **Stage 3 is planned only after this builds (rule 11).**

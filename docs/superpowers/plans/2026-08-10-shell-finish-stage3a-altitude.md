# Shell Finish Plan 3a — the altitude and the thinning

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The project row's dead click becomes *zoom out*: a project-altitude corkboard/outline fills the CENTRE in every manuscript-centred persona, the `.outline` right-pane case and Author's Research/Palette pane registrations die, the tree owns its disclosure state so a reveal can finally expand it, and ⌘⌥O/⌘⌥R/⌘⌥P re-point to the things their letters always meant.

**Architecture:** Spec `docs/superpowers/specs/2026-08-08-shell-finish-design.md` §4/§5/§6/§9 stage 3, first plan of two (rule 12 — the whole stage is far past the cap; **3b is planned only after 3a builds**, rule 11). Derived from the four-agent census of 2026-08-10 (registry / centre-routing / canvas / gesture) — key facts: `.outline` is ALREADY in no persona's registry (it left in stage 1; `PersonaPaneRegistryTests` lists it `deliberatelyUnregistered`), so its "thinning" is killing the `DetailSegment` case, the `hideOutline` machinery and the ⌘⌥O binding, while Author's `.research`/`.palette` registrations are the real registry change; the centre's route function is subject-blind (`editorRoute` takes no subject) and Author's `.project` cell today is `EditorHost`'s "Select a document." placeholder; the centre is a ViewBuilder if/else chain where **every arm is a distinct view identity**, so the altitude must ride INSIDE arm 5 (a new arm would run `EditorHost.onDisappear` — `doc.close()`, unregister, abandon — on every project↔chapter hop); tree expansion state does not exist anywhere (all `DisclosureGroup`s/`Section`s use the no-binding initialisers), so the reveal carry is CREATING state, not sharing it.

**Tech Stack:** Swift 6 / SwiftUI, XCTest, mounted-window tests on the parallel scheme.

## Global Constraints

- Contracts not bodies; TDD; `./scripts/test.sh` per task, `full` before merge; Release build after any `ProjectWindow.body`-subtree change; commit per task; **no push**.
- **No `default:`** on any switch over `BinderSubject`, `Persona`, `DetailSegment` — the no-default discipline carries through every case removal (spec §6).
- **Order is load-bearing** (the 2b lesson): capability tasks (1–3 altitude, 4 expansion owner, 5 re-points) land BEFORE the kill (6). No commit removes a writer-facing capability even transiently.
- **Mount identity is the hazard**: `RegionBindingTests.test_theCanvasIsBuiltInExactlyOnePlacePerColumn` (`RegionBindingTests.swift:1012`) must stay green, and the missing twin for the editor gets added in Task 2 — `manuscriptEditor(`/`EditorHost(` are uncounted today, so a second `EditorHost(` in `ProjectWindow.swift` would ship silently.
- **Recorded decisions (Denver, 2026-08-10)**: the travel rule — in Plan, double-click any tree row goes to Author with that subject; Open Wall in Plan goes to Author with the wall open — is **3b's**, not this plan's; Publish's whole-book PDF preview (latest export via PDFKit, degrade to altitude) is **3b's**; Review's project cell degrades to the altitude view now (its read-through overview is M3's); a GROUP subject in a manuscript-centred persona shows the altitude view too (spec §4's degrade rule — the centre never renders nothing — replacing today's "Select a document inside this group" placeholder).
- **Deferred to 3b, deliberately**: the double-click hop + Open Wall travel (+ their `ManuscriptForceCensusTests` array entry), the canvas research-highlight `CanvasSubject` case (census delivered; `CanvasHighlightTests.swift:55-60` is the test 3b rewrites), Review's read-only research/card routing, Publish's preview, the find-match posture under the centre rule.
- Tripwire 4 (no per-row I/O), 9 (no `.onTapGesture` for selection — `TaskRow.swift:56`'s additive `count: 2` shape is 3b's precedent, not needed here), 15 (`ContentUnavailableView` full-frame + top-aligned VStack), 16 (rename focus), 30 (nothing scene-proportional off a redraw counter). New mounted tests obey the CI-display rule (runner is 1024pt — read premises off the window actually got; skip by name where the display can't afford it).
- Tripwire 11: no migrations — `UIState`/`PersonaMemory` tolerant decodes absorb removed `DetailSegment` cases; stored `outlineLayout` keeps its key (the altitude pane reuses it).
- Subagent models: opus tasks 2, 3, 4; sonnet tasks 1, 5, 6; haiku task 7; reviewers haiku for docs/small, sonnet for mounted-UI diffs.

---

### Task 1: `OutlinePane` becomes `ProjectAltitudePane`

**Files:**
- Rename/modify: `Maugham/Views/OutlinePane.swift` → `Maugham/Views/ProjectAltitudePane.swift` (struct renamed too); `Maugham/Views/OutlineTable.swift`, `Maugham/Views/CorkboardGrid.swift` (reused unchanged unless a contract below forces a touch)
- Modify: `Maugham/Views/DetailPaneToggle.swift:399` (the `.outline` arm's one-line rename — the right-pane mount stays ALIVE until Task 6; behaviour-neutral interim, the 2a precedent)
- Test: new `MaughamTests/ProjectAltitudePaneTests.swift` (salvage `ProjectSubjectReachesThePanesTests`' two outline cases — see Task 3)

**Interfaces:**
- Produces: `struct ProjectAltitudePane` with the same props the census records for `OutlinePane` (`store`, `@Binding var layout: OutlineLayout`, `@Binding var selectedSubject: BinderSubject?` — `OutlinePane.swift:6-7`) plus one addition: `let title: String` for the header (the project's own name at altitude, not the pane label "Outline").
- The cards↔table toggle stays exactly as built (`OutlinePane.swift:35-51`): segmented `Picker` over `OutlineLayout`, persisted via `store.documentStore?.updateUIState { $0.outlineLayout = … }` — it becomes the spec's "centre-local control" simply by the pane moving. `OutlineLayout` (`Maugham/Models/OutlineLayout.swift`) and `UIState.outlineLayout` (`UIState.swift:28`) are untouched.

**Contracts:**
- [ ] Data derivation unchanged: `TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document })` — documents only, computed in the pane, no per-row I/O (tripwire 4).
- [ ] Empty state keeps tripwire 15's full treatment (the pane is a canonical example in `TripwireGrepTests:1034-1052` — the census there follows the rename in the same commit).
- [ ] `CorkboardGrid`'s adaptive grid (`GridItem(.adaptive(minimum: 180))`) fills a full-width centre without change — assert card count/layout sanity at a centre-typical width, reading the width off the window actually got (CI-display rule).
- [ ] The right-pane `.outline` arm still renders it (rename only, no behaviour change) — existing `DetailPaneTogglePersonaTests` stay green unmodified.
- [ ] Commit.

### Task 2: The centre shows altitude — inside the arm, never as a new one

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift:1374-1395` (`manuscriptEditor`), `:1213-1221` (`showsStatusFooter`)
- Test: new `MaughamTests/ProjectAltitudeCentreTests.swift` (mounted); extend `MaughamTests/Canvas/RegionBindingTests.swift:1012`'s census with the editor's missing half

**Interfaces:**
- Produces: `static func subjectShowsAltitude(persona: Persona, subject: BinderSubject?, structure: [StructureItem]) -> Bool` on `ProjectWindow` — true iff `persona.showsManuscriptDocuments` AND the subject resolves to no single document: `nil`, `.project`, or an `.item` that is a group (`TreeWalk.find` says `.folder`) or dangling. `.research` never reaches it (the research placement arm at `ProjectWindow.swift:1338` sits above arm 5 and takes those subjects first — assert, don't re-guard).
- The mount is a `ZStack` inside `manuscriptEditor`: `EditorHost` stays mounted underneath with its `selectedItemId` exactly as today; `ProjectAltitudePane` overlays (opaque, full-frame) when `subjectShowsAltitude`. **This is the census's chosen shape**: today's project↔chapter hop stays inside arm 5 with the same `EditorHost` instance (its nil-placeholder arm at `EditorHost.swift:239` is what altitude covers), and a sixth ViewBuilder arm would be a distinct view identity running the `onDisappear` teardown (`EditorHost.swift:259-289`) on a gesture the writer will use constantly.

**Contracts:**
- [ ] Mounted, Author: subject `.project` → altitude visible (corkboard or table per `outlineLayout`), the "Select a document." placeholder never visible; subject a document → editor visible, altitude gone; back to `.project` → altitude again — and across that whole round-trip `EditorHost` is torn down ZERO times (an `.onAppear` recorder on the host, the `ResearchSubjectRoutingTests:475-479` canvasLoads pattern).
- [ ] A GROUP subject shows altitude (the degrade rule); a reference piece in a Collection still takes arm 4 (`ReferencePlaceholderCard`) — altitude does not swallow it.
- [ ] Review and Publish render the same altitude for `.project` (recorded decision: Review's overview is M3's; Publish's preview is 3b's — the degrade ships now so the centre never renders nothing).
- [ ] Plan is untouched: `centresTheCanvas` takes arm 3 before arm 5 — one mounted assertion that Plan's `.project` still mounts the canvas, not altitude.
- [ ] `showsStatusFooter` refuses while altitude shows: the third clause at `ProjectWindow.swift:1219` (`centreItemID == nil`) currently answers TRUE for `.project`, which would float a word-count footer over a corkboard — the function grows the altitude question and the doc comment's argument (`:1192-1199`: all four readings are about a document) is cited in the test name.
- [ ] The census extension: `occurrences(of: "EditorHost(") == 1` and `occurrences(of: "ProjectAltitudePane(") == 2` (right-pane arm + centre, until Task 6 drops it to 1 — the count is re-cut there) over `ProjectWindow.swift` + `DetailPaneToggle.swift`, beside the canvas census with the same planted-offender discipline.
- [ ] Release build (ProjectWindow.body subtree); commit.

### Task 3: Click-through, and the write-back premise re-derived

**Files:**
- Modify: nothing expected in production (`CorkboardGrid.swift:25-27` and `OutlineTable.swift:36-40` already write `selectedSubject` — the same-arm swap in Task 2 is what makes the click OPEN the chapter); the task is tests + any fix they force
- Test: `MaughamTests/ProjectAltitudeCentreTests.swift` (extend), re-home the two `ProjectSubjectReachesThePanesTests` outline cases (`:42`, `:57`)

**Contracts:**
- [ ] Mounted, Author: from altitude, click a corkboard card → subject becomes `.item(id)` and the EDITOR shows that document (the spec's "click a card → that chapter opens"), same `EditorHost` instance (Task 2's recorder). Same via an outline-table row click. Use the `SceneNavigatorProjectRowTests:722-742` click-synthesis shape; mind the CI-display rule (its click cases are the two that hung on the old runner image).
- [ ] The `.project` subject survives merely OPENING altitude in both layouts — `OutlineTable.rowSelection` is a lossy `Binding<String?>` projection (`Table` cannot carry a `BinderSubject`), and the old right-pane tests pinned exactly this (`test_theOutlinePaneDoesNotClearTheProjectSubjectJustByOpening` and its corkboard twin). Their premise is re-derived against the CENTRE mount: the doc comment names the projection and why the centre is now the surface whose own selection cannot represent the subject that summoned it.
- [ ] Review and Publish: one click-through assertion each (a card click lands that persona's piece cell — today's editor; 3b refines Publish's).
- [ ] Commit.

### Task 4: The tree owns its disclosure state — and the reveal finally reaches it

**Files:**
- Modify: `Maugham/Views/BinderTreeSections.swift` (`BinderTreeSectionsState:653-687` + the two `Section`s at `:67-122`/`:135`), `Maugham/Views/ResearchTree.swift:88` (research group `DisclosureGroup`), `Maugham/Views/ProjectWindow.swift:2222-2227` (`openResearchItem`), `:2573-2580` (`handleShowLatestMCPNote`), `Maugham/Views/ResearchRevealModifier.swift`
- Test: extend `MaughamTests/BinderTreeSectionsTests.swift`; new mounted reveal cases in `MaughamTests/ResearchSubjectRevealTests.swift`

**Interfaces:**
- Produces, on `BinderTreeSectionsState` (already `@Observable`, already threaded to all three hosts — the census names it the right home, with `selection`'s own justification at `:670-684` applying verbatim): `var researchSectionExpanded: Bool` (default true), `var paletteSectionExpanded: Bool` (default true), `var expandedResearchGroups: Set<String>`, and `func reveal(_ itemId: String, research: [ResearchItem])` — expands the owning section plus every ancestor group of the item (ancestors walked via `TreeWalk`, the manifest lookup the tree already uses).
- The two `Section`s convert to `Section(isExpanded:)`; research-group `DisclosureGroup`s take the binding. **Structure groups and the piece folds stay on the no-binding initialisers** — nothing needs to write them, and converting state nobody writes is surface without a customer.

**Contracts:**
- [ ] `openResearchItem` and `handleShowLatestMCPNote` call `state.reveal(...)` beside their existing subject write + column reveal — the gap their doc comment records (`ProjectWindow.swift:2204-2211`) closes, and the comment is replaced by the design. `ResearchRevealModifier`'s restore case still does NOT force anything (a restore is not an arrival).
- [ ] Mounted: collapse the Research section, then Claude-arrival Show (`handleShowLatestMCPNote`) → the section expands, the item's row exists in the tree, the right column reveals as before. Same for an item nested in a collapsed group.
- [ ] Collapsing a section never writes the subject and never moves the centre (the trash-disclosure discipline).
- [ ] `Section(isExpanded:)` under `.listStyle(.sidebar)` changes header chrome — the row-index/inset fixtures the census names (`BinderProjectRowTests`, `BinderTreeIndentationTests`, `ProjectSubjectReachabilityTests:47`'s `emptySectionRows`) re-cut in this commit if the shape moved; say in the report whether it did.
- [ ] The `TripwireGrepTests` pairing census for `.binderTreeSections(store:state:selectedSubject:)` already covers the threading — assert it still passes, add nothing.
- [ ] Commit.

### Task 5: The keyspace keeps its promises

**Files:**
- Modify: `Maugham/MaughamApp.swift:231/:233/:243` (the three bindings), `Maugham/Views/ProjectWindow.swift` (receivers), `Maugham/Events/MaughamEvent.swift` (if a new name is needed), `docs/guide/reference.md:34/:35/:39` (same commit — spec §5's rule)
- Test: extend `MaughamTests/ManuscriptNavigationTests.swift`-adjacent receiver tests; `DocSyncTests` stays green

**Interfaces:**
- Produces: ⌘⌥O posts a `.keyWindow`-scoped event whose receiver sets `selectedSubject = .project` (the outline's new home is the project row — the altitude centre follows from Task 2; in Plan it lands the undimmed board, which is Plan's project rendering); ⌘⌥R posts one that sets `state.researchSectionExpanded = true` + scrolls the tree to the Research section header; ⌘⌥P the same for Palette. Receivers use the `MaughamEvent` helpers exclusively (ADR 0021 — scope declared at the post site, no hand-rolled filters).
- The three panes these keys used to open are still alive until Task 6 — the keys re-point FIRST (a keyless pane is reachable via the picker; a re-pointed key must never dangle), the 2b ordering discipline.

**Contracts:**
- [ ] Each shortcut still lands the writer on the thing the letter always meant — one mounted test per key, driven through the real menu command path (the mode-UX delivery-path lesson: model menu/key delivery, not the handler alone).
- [ ] ⌘⌥R/⌘⌥P work with the find overlay CLOSED and are refused (no-op, no crash) while it covers the column — the overlay is the tree's replacement, not its sibling.
- [ ] `docs/guide/reference.md`'s three rows describe the new meanings in the SAME commit; `DocSyncTests`' one-directional gate cannot catch a stale row (census fact) — the task's report quotes the three new rows as evidence.
- [ ] Commit.

### Task 6: The kill — `.outline` dies whole, Author's Research/Palette registrations leave

**Files:**
- Delete: `Maugham/Views/LinkedResearchPane.swift`, `Maugham/Views/Palette/PalettePane.swift` (registration-less views with no other mounts — verify by grep before deleting; the census's inventory says the `.research`/`.palette` arms are their only callers)
- Modify: `Maugham/Models/DetailSegment.swift` (`.outline`, `.research`, `.palette` cases + icons + help text), `Maugham/Views/DetailPaneToggle.swift` (three `segmentContent` arms; `hideOutline` prop/param and its uses at `:207-210/:222/:247/:250`; `snappedSelection:280-293`; `outlineLayout` prop/param), `Maugham/Models/Persona.swift:238-239` (Author's membership) + the doc comments naming the demoted `.outline` (`:135-137/:191/:276`), `Maugham/Views/ProjectWindow.swift:1969` (`hideOutline:` call site) + `:111` (`outlineLayout` stays — the centre reads it), `Maugham/Models/PersonaMemory.swift:50` (the `hideOutline` sentence goes inert — delete it)
- Test: compile-driven sweep + the named re-cuts below

**Contracts:**
- [ ] The three cases are GONE; every switch over `DetailSegment` still compiles with no `default:` (the compiler is the census).
- [ ] `PersonaPaneRegistryTests` re-derives: `canonicalPaneOrder` drops the three; the Author literal at `:170-171` re-cuts; `deliberatelyUnregistered` (`:46`) goes EMPTY, which fires the anti-vacuity guard at `:73` — the guard is REWRITTEN in this commit, not deleted: the unregistered-but-reachable mechanism (`visibleSegments(including:)`'s append) survives for `.translation`'s forced entry, so the census re-bases on "every case is registered somewhere OR named in a forced-entry list", with `.translation`'s entry as its non-vacuous member. `designMatrix:417-418`, `notYetDelivered`, and `test_aPaneRegisteredInNoPersonaIsStillReachable:235` (pinned specifically for `.outline`) re-cut or retire per that rework.
- [ ] `PersonaMemory` tolerant decode absorbs stored `.outline`/`.research`/`.palette` segments (tripwire 11 — assert one restore of each lands the persona's `defaultPane`, no migration).
- [ ] Task 2's mount census re-cuts: `ProjectAltitudePane(` drops to exactly 1 (the centre); `DetailPaneToggle` no longer names it.
- [ ] `TripwireGrepTests:1631-1703` (the two-snaps tripwire whose planted offenders embed `hideOutline:` signatures) re-cuts; `:3609-3610`'s census keeps naming `CorkboardGrid`/`OutlineTable` (they live).
- [ ] The ⌘⌥ letters: the three bindings were re-pointed in Task 5; assert no `postSegment(.outline)`/`(.research)`/`(.palette)` spelling survives anywhere (grep census with planted offender, the house pattern).
- [ ] Fixture holders that carried `outlineLayout`/`hideOutline` only to satisfy inits (`StatementMountFixture.swift:490`, `ResearchSubjectRevealTests.swift:312`, `DetailPaneColumnHeightCensusTests:43-47/:81`, `PersonaMemoryTests:129`, `PersonaModifierTests:30/:77`, `ManuscriptNavigationTests:134`) sweep in this commit.
- [ ] Release build; commit.

### Task 7: The docs catch up with the world

**Files:**
- Modify: `docs/guide/right-pane.md` (outline/research/palette pane prose), `docs/guide/structure-and-binder.md` (the project row's new function), `docs/guide/reference.md` (verify Task 5's rows landed; sweep for stragglers), `CLAUDE.md` (Views row: altitude centre, the thinned registry, the disclosure owner), `Maugham/Views/AREA.md` (ProjectAltitudePane entry; BinderTreeSectionsState's expansion fields; the keyspace re-points; retire the OutlinePane bullet), `docs/roadmap.md` (stage 3a line), the stage-3 handoff note (3a built; 3b owed with its recorded decisions: the travel rule, Publish's whole-book preview, the canvas highlight case + its census, Review read-only routing, find posture)
- Test: `DocSyncTests` green

**Contracts:**
- [ ] Every guide sentence describing the outline as a right pane, or Research/Palette as Author panes, is rewritten to what SHIPS; no ⌘⌥O-opens-a-pane prose survives.
- [ ] CLAUDE.md's Views row: the altitude centre and the disclosure owner described; counts stay pointed at code (`DetailSegment.allCases`, the registry test), never restated as numbers.
- [ ] Handoff addendum lists Denver's 3a smoke: project row in Author/Review/Publish → corkboard fills the centre, toggle to table, click a card → chapter opens, ⌘Z-safe typing after the hop; footer absent over altitude; group row → altitude; ⌘⌥O/⌘⌥R/⌘⌥P land their new meanings; collapse Research section then Claude Show → section expands; Plan untouched (project row → undimmed board).
- [ ] Commit.

---

**Whole-branch review** (mandatory — nineteen consecutive finds), dispatch NAMING the seams: Task 2's ZStack × `EditorHost`'s load-generation machinery (a superseded load landing while altitude covers the host); Task 2's `subjectShowsAltitude` × the research placement arm above it (a `.research` subject must never reach altitude, in any persona); Task 3's click-through × Task 4's disclosure state (a corkboard click while the tree is collapsed); Task 5's re-points × Task 6's case deletions (no dangling `postSegment` spelling, keys re-pointed before their panes died in the commit ORDER, not just the task order); Task 6's registry rework × `PersonaMemory` restore (a stored dead segment on a real machine); the altitude pane in THREE personas × `showsStatusFooter` (footer state through persona switches while the subject stays `.project`). Then merge unpushed; ledger + handoff. **3b is planned only after this builds (rule 11).**

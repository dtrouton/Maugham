# M3 Plan 1 — the spine and the board

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Review passes become real: a typed pass list on the manifest, per-piece pass state, a derived status that retires the free string, and `ReviewBoardPane` — the pieces × passes board at Review's project altitude, with chips that navigate on click and set state from their menu.

**Architecture:** Spec `docs/superpowers/specs/2026-08-14-m3-review-passes-design.md` §2–§4, §7, first plan of three (rules 11/12 — P2/P3 are written only after this builds). Derived from a two-agent survey of HEAD `432be54a` (model/projection seam; board/routing seam) — every line number below was read from that HEAD. Key survey facts the tasks stand on: `StructureItem`'s Codable is fully synthesized, so a new non-optional field would throw `keyNotFound` on every existing manifest — new fields are OPTIONAL (the `tags`/`links` shape); `PassState` lives in a file rewritten on every edit, which is `ResearchRole`'s situation exactly, so it takes the LOSSLESS `.unknown(String)` shape (`ResearchItem.swift:18-51`), never `SynthesisSource`'s lossy sentinel; the status-writer census (`PersonaPaneRegistryTests:249-378`) pins Inspector-only writes of `status:` and its argument must be re-made, not deleted; `subjectShowsAltitude` is persona-blind past one bit, and the persona-answering gate precedent is `Persona.previewsThePublishedBook`'s exhaustive switch (`Persona.swift:455-479`); the arm-scan tests bound `manuscriptEditor(` by `declaration(named:)` and `PublishPreviewCentreTests:1198-1237` asserts the book is the LAST layer — the board slots BETWEEN altitude and the book; `.contextMenu` is unreachable from a headless test (`BinderView.swift:306-310`), so chip verbs are an exposed factory asserted directly; no current centre surface preserves group structure — the board's row derivation is new and pure.

**Tech Stack:** Swift 6 / SwiftUI, XCTest, mounted-window tests on the parallel scheme.

## Global Constraints

- Contracts not bodies; TDD; `./scripts/test.sh` per task, `full` before merge; Release build after any `ProjectWindow.body`-subtree change; `./gen.sh` after adding Swift files; commit per task; **no push**.
- **The schema bump and its cost, decided up front (the `statements` precedent, `ProjectManifest.swift:95-102`):** `reviewPasses` + `passStates` are fields an older build's re-save would silently DROP — losing a writer's chip states across a collection. Honest refusal beats silent loss: `ProjectManifest.currentSchemaVersion` bumps **5 → 6** (Task 1), the SCHEMA CONTRACT comment grows the 5→6 row, and **M3's release becomes a paired Mac + phone release** (shipped phone builds refuse a v6 manifest via `decodeGuardingSchema` until updated — the M1A pattern, done before). Nothing about this plan's code forces the release date; the pairing binds whenever M3 ships.
- **No `default:`** on switches over `Persona`, `BinderSubject`, `PassState`, `OutlineLayout`, or the new `ReviewStatus` — exhaustive everywhere; `PassState.unknown(String)` is a case, not a default.
- **The board reads the manifest and UI state only** — no per-chip I/O, no document opens (tripwire 4). The spec's open-notes count column is **deliberately deferred to P2**, where the cross-document annotation machinery is built with a proper cache; counting today would open every document on the window's body path. P2's plan inherits this as its first named carry.
- **Mounted-click tests obey the activation premise** (CLAUDE.md build flow, 2026-08-13): the click helpers read `NSApp.isActive` off the machine and skip by name when activation is unattainable; `TreeTravelTests.click(at:)` is canonical.
- Tripwire 15 (`ContentUnavailableView` full-frame — the census walks all of `Maugham/`, `TripwireGrepTests:1035`); tripwire 11 (no migrations — legacy `status` strings are read as fallback, never rewritten; absent `reviewPasses` means the presets, computed, not written); tripwire 12 (the projection is a typed enum); tripwire 19 (model types live in MaughamCore; the phone never writes the manifest, verified — no phone code change).
- **Census re-cuts this plan owns, named:** the `manuscriptEditor` arm scans (`ProjectAltitudeCentreTests:958-998`, `PublishPreviewCentreTests:1198-1237`) gain the board's literals with the book still LAST; `RegionBindingTests:1050-1063`'s mount counts gain `ReviewBoardPane( == 1`; `test_reviewAndPublishShowTheSameAltitudeAsAuthor` (`ProjectAltitudeCentreTests:408`) re-derives (Review's altitude is the board now); the status-writer census re-derives around `setPassState` (Task 4).
- Subagent models: opus tasks 2, 4, 6, 7, 8; sonnet tasks 1, 3, 5, 9; reviewers sonnet for mounted-UI diffs, haiku for small/mechanical.

---

### Task 1: `ReviewPass` — the pass list on the manifest

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/ReviewPass.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ProjectManifest.swift` (`:42` schema version + the SCHEMA CONTRACT comment `:15-41`; the hand-written `init(from:)` `:195-210`; `encode(to:)`'s key set)
- Test: new `Packages/MaughamCore/Tests/MaughamCoreTests/ReviewPassTests.swift`; extend `SchemaEvolutionToleranceTests.swift`

**Interfaces:**
- Produces: `public struct ReviewPass: Codable, Equatable, Identifiable, Sendable { public let id: String; public var name: String }` — position is array order, no order field. `public static let presets: [ReviewPass]` — ids `"structural"`, `"line"`, `"copyedit"`, `"proof"`, names "Structural", "Line", "Copyedit", "Proof". Preset ids are STABLE contract (P3's round records cite them).
- `ProjectManifest.reviewPasses: [ReviewPass]` decoded `decodeIfPresent(...) ?? []` (the `statements` template at `:206`); `public var effectiveReviewPasses: [ReviewPass]` — stored when non-empty, else `ReviewPass.presets`. An absent or emptied list MEANS the presets, computed, never written back (tripwire 11); customization is what writes the array.
- `currentSchemaVersion` = 6; the contract comment gains the 5→6 row citing this plan and the paired-release consequence.

**Contracts:**
- [ ] A v5 manifest with no `reviewPasses` key decodes clean; `effectiveReviewPasses == ReviewPass.presets`.
- [ ] A manifest with a custom list round-trips it byte-stable through `makeEncoder()`.
- [ ] A v7 manifest refuses via `SchemaTooNewError` (existing test stands); v6 accepts.
- [ ] `swift test --package-path Packages/MaughamCore` green; both schemes build (the version literal appears in no test as a magic number — assert version-relative, the 2026-08-09 lesson).
- [ ] Commit.

### Task 2: `PassState` on the piece — lossless, optional, reference-aware

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/PassState.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/StructureItem.swift` (field + memberwise init default), `Maugham/Stores/ProjectStore+CollectionPieces.swift:567` (convert-to-project copies `passStates` beside `status`) and `:660` (convert-to-reference clears it beside `status`)
- Test: new `Packages/MaughamCore/Tests/MaughamCoreTests/PassStateTests.swift`; extend the collection-piece conversion tests that pin `:567`/`:660`'s status behaviour (find them by those behaviours)

**Interfaces:**
- Produces: `public enum PassState: Codable, Equatable, Sendable { case inProgress, done, skipped, unknown(String) }` — the `ResearchRole` lossless shape copied exactly (`ResearchItem.swift:18-51`): hand-written `rawValue`, `init(from:)` decoding an unrecognized string to `.unknown(raw)`, `encode(to:)` re-emitting it verbatim. Doc comment states WHY lossless: the manifest is rewritten on every structural edit, and a lossy sentinel would clobber a newer build's state on the next save.
- `StructureItem.passStates: [String: PassState]?` — optional (synthesized decoder stays untouched; the `tags` shape), keyed by pass id, absent-or-missing-key means untouched.

**Contracts:**
- [ ] An unrecognized state string survives decode → re-encode byte-identical (the lossless pin, `ResearchRole`'s own test shape).
- [ ] A manifest without the field decodes clean; one with it round-trips.
- [ ] Convert-to-reference clears `passStates` exactly where it clears `status`; convert-to-project carries it.
- [ ] `swift test` + both schemes; commit.

### Task 3: The projection — one status, derived, four swatches converge

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/ReviewStatus.swift`; `Maugham/Views/StatusSwatch.swift`
- Modify: `Maugham/Views/OutlineTable.swift:51-53,77-83`, `Maugham/Views/BinderRow.swift:129-135`, `Maugham/Views/CorkboardGrid.swift:35`, `Maugham/Views/PieceRow.swift:70-74` (the four duplicate switches converge on the one helper)
- Test: new `Packages/MaughamCore/Tests/MaughamCoreTests/ReviewStatusTests.swift`; a `TripwireGrepTests`-style census that no view file keeps a private `statusColor` switch (planted-offender companion)

**Interfaces:**
- Produces: `public enum ReviewStatus: String, Sendable { case draft, revising, final }` and `public static func derived(passStates: [String: PassState]?, passes: [ReviewPass], legacyStatus: String?) -> ReviewStatus` in MaughamCore (phone-reachable if ever wanted, tripwire 19): no states → legacy fallback (`"revising"`/`"final"` map; anything else → `.draft`); any pass `.inProgress` or a mix of touched/untouched → `.revising`; every pass in `passes` `.done` or `.skipped` → `.final`; `.unknown` counts as touched-but-open (never silently final).
- `StatusSwatch.color(for: ReviewStatus) -> Color` — app-side, the ONE switch; the four call sites pass `ReviewStatus.derived(...)`.

**Contracts:**
- [ ] Projection truth table exhaustively tested, including: all-skipped → `.final` (the spec's recorded edge — deliberate adjudication); `.unknown` present → never `.final`; legacy `"final"` with no states → `.final`; legacy garbage → `.draft`.
- [ ] The four views render identical colors for identical inputs before/after (behaviour-neutral for legacy projects with no pass states).
- [ ] The no-second-switch census + planted offender.
- [ ] Commit.

### Task 4: `setPassState` — the verb, the inspector ladder, and the census re-made

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Metadata.swift` (new verb beside `updateInspector`, `:11-38`'s four-beat shape), `Maugham/Views/PieceInspector.swift:87-98` and `Maugham/Views/InspectorView.swift:137-157` (the status picker becomes the pass ladder), `Maugham/Models/Persona.swift:303-330` (the Review-keeps-the-inspector argument re-made), `MaughamTests/PersonaPaneRegistryTests.swift:249-378` (the census re-derives)
- Test: extend `MaughamTests/` inspector tests beside the census

**Interfaces:**
- Produces: `public func setPassState(id: String, passId: String, _ state: PassState?) async throws` on `ProjectStore` — guard-find → `mutateItem` (nil state removes the key; an emptied map becomes nil, not `[:]`) → `manifest.modified` → `saveManifest()`. Deliberately NOT a new `status:` argument on `updateInspector` — `status` has no writers after this task.
- The inspector's status section becomes the ladder: one row per `effectiveReviewPasses` entry with a state control (menu: untouched / in progress / done / skip), plus the projected `ReviewStatus` rendered read-only where the picker was. Both inspector files route through `setPassState`.
- The census re-derives: `statusWritingFiles` retires with its argument; its successor pins `setPassState(`'s production callers as a closed set — `PieceInspector.swift`, `InspectorView.swift`, and (Task 8) `ReviewBoardPane.swift` — with the planted-offender discipline, and `Persona.swift:303-330`'s prose is rewritten to the new argument (Review keeps the inspector because the LADDER lives there).

**Contracts:**
- [ ] `status:` has zero production writers (grep-level assert in the re-derived census); `updateInspector`'s `status:` parameter is REMOVED (compiler sweeps the call sites).
- [ ] Setting a state from the inspector persists through a manifest round-trip; nil removes; the projection updates live in the outline swatch (one mounted assertion).
- [ ] The re-derived census + planted offender; `Persona.swift`'s prose matches.
- [ ] Commit.

### Task 5: The active pass — UI state, `PersonaMemory`'s shape

**Files:**
- Create: `Maugham/Models/ActivePassMemory.swift`
- Modify: `Maugham/Stores/UIState.swift` (one property + key + encode/decode line, `:224-230`'s tolerant shape; NO schema bump — the `:50-55` no-bump rule), `Maugham/Views/ProjectWindow.swift` (`@State` + hydration in `load()` beside `:3122`'s `outlineLayout` seed)
- Test: extend `MaughamTests/` UIState round-trip tests

**Interfaces:**
- Produces: `struct ActivePassMemory: Codable, Equatable, Sendable` — `PersonaMemory`'s tolerant keyed-map shape copied exactly (`PersonaMemory.swift:33-97`: `[String: String]` on the wire, unreadable → empty, unknown entries drop individually): `func activePass(forPiece: String) -> String?`, `mutating func record(piece: String, passId: String)`. Stored pass ids that no longer exist in `effectiveReviewPasses` are ignored at READ (the stale-id-sits-harmlessly rule), never swept.
- `ProjectWindow` threads it via `updateUIState` on write (the outlineLayout pattern, named at `ProjectWindow.swift:49`).

**Contracts:**
- [ ] Round-trips; tolerates garbage; no UIState schema bump; a stale pass id reads as nil.
- [ ] Commit.

### Task 6: The routing — Review's altitude is the board

**Files:**
- Modify: `Maugham/Models/Persona.swift` (one new predicate), `Maugham/Views/ProjectWindow.swift:1696-1757` (`manuscriptEditor` gains the layer BETWEEN altitude and the publish switch), plus the gate static beside `publishCentre` (`:1430-1452`'s shape)
- Test: re-cut `MaughamTests/ProjectAltitudeCentreTests.swift` (`:408`, `:958-998`), `MaughamTests/PublishPreviewCentreTests.swift:1198-1237`, `MaughamTests/Canvas/RegionBindingTests.swift:1050-1063`; new `MaughamTests/ReviewBoardRoutingTests.swift`

**Interfaces:**
- Produces: `Persona.showsTheReviewBoard: Bool` — exhaustive switch, true only for `.review`, with `previewsThePublishedBook`'s doc-comment argument (`Persona.swift:455-479`): a third independent fact about the centre, never derived from the other predicates and never `== .review` at a use site. And `static func reviewCentreShowsBoard(persona: Persona, subject: BinderSubject?, structure: [StructureItem]) -> Bool` — `showsTheReviewBoard && subjectShowsAltitude(...)`, composing the ONE document-resolution rule exactly as `publishCentre` does.
- The mount: `ReviewBoardPane` (Task 7) as an opaque full-frame layer with its own `.background(...)`, between the altitude layer and the publish switch — the book stays LAST (the ordering assertion), and in Review the board covers the corkboard exactly as the book covers it in Publish.

**Contracts:**
- [ ] Mounted, Review: `.project` / a group / nothing → the board visible, corkboard covered, editor host never torn (extend the host-lifetime recorder across board↔editor hops — and the hop test WAITS FOR THE STATE IT ASSERTS, the 2026-08-13 wait/assert lesson); a document subject → the editor exactly as today.
- [ ] Author and Publish unchanged — `:408`'s re-derivation asserts Author keeps the corkboard, Publish keeps its own truth table, and only Review shows the board.
- [ ] The arm scans re-cut: `"ReviewBoardPane("` + `"Self.reviewCentreShowsBoard("` literals in the arm; book-is-last ordering still asserted; whole-file `ReviewBoardPane( == 1`, `manuscriptEditor( == 2`.
- [ ] `showsStatusFooter` needs NO new clause (`:1379-1391`'s argument: the board only shows where altitude already silenced it) — asserted, not assumed.
- [ ] The ejection trap: no persona write anywhere in the new code — the persona-decision census (`TripwireGrepTests`) passes untouched.
- [ ] Release build; commit.

### Task 7: `ReviewBoardPane` — rows, chips, groups, references

**Files:**
- Create: `Maugham/Views/Review/ReviewBoardPane.swift`, `Maugham/Views/Review/ReviewBoardRows.swift`
- Test: new `MaughamTests/ReviewBoardRowsTests.swift`, `MaughamTests/ReviewBoardPaneTests.swift`

**Interfaces:**
- Produces: `ReviewBoardRows.derive(structure: [StructureItem]) -> [Row]` — pure, no store (the `TreeSectionDerivation` discipline): pre-order walk emitting `Row { kind: .group(depth:) | .piece | .reference; item }` — groups preserved as header rows with depth (no current view does this; the walk is new and its tests are exhaustive over nesting, empty groups, and Collections). Reference pieces (`pieceKind == .reference`) emit `.reference`.
- `ReviewBoardPane(store:selectedSubject:activePass:onSetState:onNavigate:)` — header (project title + pass-name column headers from `effectiveReviewPasses`), then rows: group headers indent; piece rows render one chip per pass (state glyph from `passStates`, projection-consistent colors via `StatusSwatch`) ; reference rows render thin and chip-less; empty project → `ContentUnavailableView` with tripwire 15's full treatment (the census walks all of `Maugham/` — automatic).
- Chips are `Button`s (`CorkboardGrid:24-27`'s shape — never `.onTapGesture`); no drops accepted anywhere on the board.

**Contracts:**
- [ ] `derive` truth table: nesting depths, a group holding only references, an empty structure, tree order preserved.
- [ ] Mounted: chips render per (piece × pass) with correct states; reference rows have zero chips; the pane scrolls (rows in a `ScrollView`/`List`, wide pass sets scroll horizontally inside the pane, never the window — the responsive rule).
- [ ] No store reads beyond `manifest` + cached word counts if shown (tripwire 4 — assert no `Document`/file I/O on the body path by construction: the pane takes value inputs).
- [ ] Commit.

### Task 8: Chip interactions — click navigates, menu sets

**Files:**
- Modify: `Maugham/Views/Review/ReviewBoardPane.swift`, `Maugham/Views/ProjectWindow.swift` (the mount's closures: navigate writes `selectedSubject` + `ActivePassMemory.record` via `updateUIState`; set-state calls `store.setPassState`)
- Test: extend `MaughamTests/ReviewBoardPaneTests.swift`; the Task 4 census gains `ReviewBoardPane.swift` as its third closed-set member

**Interfaces:**
- Produces: `ReviewBoardChipVerbs` (a value type in `ReviewBoardPane.swift`) — the exposed verb factory (`BinderView.swift:306-316`'s discipline: `.contextMenu` is headless-unreachable, so the menu items come from `chipMenuItems(for piece: passId: current:) -> [ChipVerb]` asserted directly): untouched/in-progress/done/skip, current state checkmarked, each calling `onSetState`.
- Chip CLICK: `onNavigate(pieceId, passId)` → `selectedSubject = .item(pieceId)`, active pass recorded — subject write only, never persona (ejection trap), and the payload is the chip's own identity, never read from any selection state (T3's rule).
- The advisory-order nudge is P2's (it lives in the queue pane) — this task adds NOTHING about ordering.

**Contracts:**
- [ ] Verb factory truth table (all four verbs, checkmark on current, `.unknown` current shows all four with none checked).
- [ ] Mounted: chip click opens that chapter in the already-mounted host (the `:488` shape) and records the active pass in ui-state; set-state via the verb persists and the chip re-renders; a reference row offers no verbs.
- [ ] Census re-cut lands (`ReviewBoardPane.swift` joins the closed set; planted offender still fires).
- [ ] Release build (ProjectWindow.body); commit.

### Task 9: The pass editor — rename, add, delete, reorder

**Files:**
- Modify: `Maugham/Views/ProjectSettingsSheet.swift` (a Review Passes section — the sheet is the established home for project-level settings, `:27-116`), `Maugham/Stores/ProjectStore+Metadata.swift` (one verb: `setReviewPasses(_ passes: [ReviewPass])`, four-beat shape)
- Test: new `MaughamTests/ReviewPassEditorTests.swift`

**Interfaces:**
- Produces: a list editor over `effectiveReviewPasses` — rename in place, add (id minted as a slug of the name, uniquified), delete, drag-reorder; Save writes the whole array via `setReviewPasses`. Deleting ALL passes writes `[]`, which reads as the presets again (Task 1's rule — surfaced in the sheet's footer text so it isn't a surprise). Piece states keyed by a deleted pass id sit harmlessly (never swept — the stale-id rule) and the board simply stops showing that column.
- Every new data type has its UI surface (workflow rule 8): `ReviewPass` is inspectable and editable here; `PassState` on the board and ladder.

**Contracts:**
- [ ] Rename preserves id (states survive a rename); add mints unique ids (two "Line edit" passes get distinct ids); reorder round-trips; delete-all → presets shown, `[]` stored.
- [ ] A deleted pass's states linger in the manifest untouched and reappear if the pass id is re-added (documented behaviour, asserted).
- [ ] `Maugham/Views/AREA.md` gains the board + ladder + editor bullets in this commit (the slice's own docs; the guide sweep stays P3's).
- [ ] Commit.

---

## After the tasks — the whole-branch review, seams named

1. The status retirement × every `status` reader (MCP `get_outline` still reports the RAW string until P3 widens it — a legacy-vs-projection disagreement window; verify it's read-only display and record it).
2. The schema bump × the paired-release constraint × `decodeGuardingSchema` on both platforms — drive a v6 manifest through the phone's decode path in a test.
3. The board layer × the publish layer in the same ZStack — persona-switch round trips (Review board up → ⌘4 → book up → ⌘3 back) with the host never torn.
4. The census re-derivation (Task 4) × `PersonaPaneRegistryTests`' other status-argument tests — nothing else quotes the retired argument.
5. `setPassState` writers closed set × Task 8's third member — the planted offender fires on a fourth.

# Session handoff — "ui-shell", 2026-08-04 → 2026-08-08

*Written at Denver's request before a context clear. This session ran from the
M2 brainstorm through the compiler's second draft to the shell finish's first
stage. Paste the "Read these" block into the next session's start.*

## State

**Local `main` is at `7458490f`, 91 commits ahead of origin. NOTHING is
pushed, nothing tagged** — Denver: "we will push this when happy." The paired
Mac + phone release gate (manifest schema 4, standing since M1A) is unchanged;
nothing in this session added a schema bump, so one push + one paired release
covers everything since `f2b2b5e`.

What those 91 commits contain, in order of landing:
1. **M2 — the compiler** (spec `2026-08-04-m2-author-compiler-design.md`):
   warm `claude -p` loop, Diagnostics pane, promote-to-task, intent strip,
   References pane + assistant column, ADRs 0027/0028.
2. **The wet-ink fix** (smoke-found: ⌘R now flushes the pending burst).
3. **The compiler's second draft, all three stages** (spec
   `2026-08-07-compiler-second-draft-design.md`, closing handoff
   `2026-08-07-second-draft-handoff.md`): the declared world (rulings /
   derivation / bible / strata), the run rebuilt (conformance against derived
   clauses, quotes-not-ids, the atomic switch), drift-as-pattern, bless
   convergence, streamed sections, cold start, the derivation deadline.
4. **The assistant column is Author-only** (Denver's ruling, 2026-08-08).
5. **The shell finish, Stage 1** (spec `2026-08-08-shell-finish-design.md`):
   one persisted window-aware right-column width; a choiceless segment strip
   renders nothing, divider included.

## Read these, in this order (next session)

1. `docs/superpowers/specs/2026-08-08-shell-finish-design.md` — the approved
   shell-finish design. Stage 1 is BUILT; **Stages 2–3 are deliberately
   unplanned** (rule 11): plan Stage 2 (the tree) against the built code.
2. `docs/superpowers/notes/2026-08-07-second-draft-handoff.md` — the second
   draft's closing handoff with the 7-item full-loop smoke.
3. `MEMORY.md` + CLAUDE.md's invariants and tripwires, as always.

## The work still open

**Stages 2–3 of the shell finish** (the reason the spec exists):
- Stage 2 — the one tree: Pieces (each unfolding to its research) / Research /
  Palette; `BinderSubject` widened to three id spaces (kills the unswept
  selection bug); drag-is-scope; find/trash as transients; the strip's true
  death. Carries recorded in the spec + these session finds: `findActive` has
  zero production writers (dead wiring adjacent to the transients);
  `docs/guide/getting-started.md:16`'s segment-picker sentence needs the
  stage-2 docs sweep; the BINDER column still has a range spelling
  (`ProjectWindow.swift:146`) — decide in stage 2 whether it gets the same
  one-width treatment.
- Stage 3 — the centre rule: project altitude (corkboard moves to the centre),
  per-persona subject rendering, the Plan double-click hop, registry thinning,
  keyspace re-points (⌘⌥R/⌘⌥P/⌘⌥O per spec §5).

**Smokes owed (Denver, consolidated):**
- The second draft's 7-item full-loop list (its handoff, top section) + the
  standing M2-era and pre-M2 subject-sweep remainders (same file, "Standing
  items").
- Stage 1's own: drag the right column once, switch personas and ⌘\ — the
  width holds; on a wide display, drag past 292 (the seventeenth Critical's
  regression test in the flesh); Author/Review/Publish show no strip and no
  hairline; ⌘⌥F still summons Find with the strip appearing for it.

**Decisions parked:** the push + paired release (Denver's call, when happy);
strip freshness for closed statements (ruled closed-unless-observed);
Stage 2/3 sequencing is next unless Denver redirects.

## Process — what this session paid for and the next should inherit

- **Seventeen consecutive whole-branch reviews found a Critical**, every one a
  cross-task seam (the last hid between one task's own two fix rounds). The
  review is not optional and its dispatch must name the seams to walk.
- **The silent-stall pattern**: subagents idle without reporting when they
  wait on anything (tail-buffered pipes, monitors that miss exits, plain
  drift). The countermeasures that worked: every dispatch ends with "never
  idle silently — poll actively"; the controller arms a clock-based
  background backstop (10–15 min sleep + state check) for any agent quieter
  than expected, and checks tree state (commits + report file) rather than
  trusting idle notifications. Denver caught a 2-hour stall before I did
  once; the backstops exist so that never recurs.
- **Diagnose-before-fix paid twice at full price**: the wet-ink bug and the
  width fix both falsified their own leading hypotheses under measurement
  ("a range is not a width"). Pin falsified hypotheses as tests.
- **The prose-count discipline keeps catching real defects** — including a
  comment warning against prose counts, and a review report's own counts.
- **The clock-flake pair** (`MCPColdStartTests` /
  `MCPBinaryIntegrationTests`) still fails under a loaded full suite and
  passes in isolation; apply the discriminator by name before blaming a
  branch. Baseline at this handoff: ~4,845 Mac / 482 Core / 233 phone.

## Post-handoff addendum, 2026-08-08 evening — rebased onto remote's test framework

Remote main gained five test-framework commits (parallel Mac workers,
`RunLoopPump`, condition waits, the canvas mounting suite split three ways,
`scripts/test.sh`). **Local main was rebased onto it** (`--rebase-merges`,
topology preserved; backup at `backup/pre-rebase-2026-08-08` until confident).
One real conflict: `Canvas/AREA.md`'s Escape paragraph — resolved as our
arbiter text carrying remote's renamed suite
(`CanvasViewMountingEditingTests`), verified against the tree. **The full
parallel run is green**: 4,839 passed, one failure = the documented
`MCPColdStartTests` clock flake (passed in isolation, discriminator run).
Our 92 commits' tests met seven workers with zero collisions. **The test
command is now `./scripts/test.sh` (fast) / `./scripts/test.sh full`
(pre-merge gate, ~2.75 min)** — the next session should use it everywhere the
old flat `-only-testing` xcodebuild spellings appear in these notes.

## 2a built, 2b owed — addendum, 2026-08-09

**Stage 2a of the shell finish** (plan
`docs/superpowers/plans/2026-08-08-shell-finish-stage2a-tree-grows.md`) is
built on `feat/shell-finish-stage2a`, HEAD `9bb2115d`, tasks 1–7 merged and
review-clean, **not merged to main, not pushed**. It grows the tree beside
the still-living strip: `.research(String)` joins `BinderSubject` with the
one sweep widened to cover it (Tasks 1–2); Research and Palette sections plus
a per-piece research fold now sit at the foot of every persona's tree (Tasks
3/4/6); a `.research` subject reaches the centre and the right column in
every persona, including Plan, where it previews beside the still-mounted
canvas rather than replacing it (Task 5); and a drag across the tree is the
writer's verb for scope — link/unlink/rescope, one pure classifier, routing
by lookup and refusing loudly on a miss (Task 7). `Maugham/Views/AREA.md`
gained a new "The binder tree" section naming the pieces
(`BinderTreeSections`/`BinderTreeVerbs`/`BinderPieceFold`/
`TreeSectionDerivation`/`TreeDropIntent`/`BinderTreeDrops`/
`BinderTreeSelection`) and the censuses that guard each seam — read that
before touching any of it.

**Whole-branch review is still owed before this merges** (plan's own closing
line: "2b is planned only after this builds"), dispatched naming the seams
the plan calls out: Task 1's codec × Task 2's validator (which ids are valid
must agree); Task 4's rows × Task 5's routing (a row tagged `.research` must
land somewhere in EVERY persona); Task 5 × the canvas identity (a research
click in Plan must not remount the board); Task 6's fold semantic × Task 7's
drop intent (a fold that RENDERS linked items while a drop MOVES would
corrupt a novel's shared research); the still-living
`ResearchView`/`CollectionResearchPane` × the tree (two surfaces over one
manifest, no cross-writes).

### Carries for 2b

- **The strip's true death**: kill `BinderSegment`'s **picker** and
  `Persona.binderSegments(for:)`; delete `Persona.binderHome(for:)` and
  `PersonaMemory.binder`'s segment-restore machinery in
  `applyPersonaChange` — per-persona segment memory has nothing left to
  remember once there is no picker.
- **Find as a tree overlay, not a segment** — needs a REAL writer for the
  overlay state. `findActive` today has zero true-writers
  (`ProjectWindow.swift:92` the `@State`, `:710` the one site that clears
  it — both held steady through 2a; re-grep before trusting either number
  in 2b). The Esc route cannot be the canvas arbiter while the query field
  holds focus: `CanvasEscapeMonitor.swift:96-101`'s refusal 3
  (`!isEditingText(ourWindow.firstResponder)`) explicitly refuses while
  text editing owns first responder, so find's Esc needs its own delivery
  path, with a mounted real-Esc test — not a synthesized notification.
- **Trash as a foot disclosure, not a segment**: relocate the Empty Trash
  toolbar item (`TrashView.swift:14-21`) to wherever the disclosure's own
  chrome lives. The persisted `UIState.binderSegment` values `"find"`/
  `"trash"` on existing machines must decode tolerantly once the segment
  enum's shape changes under them (`UIState.swift`'s existing
  `(try? …) ?? .manuscript` decode is the precedent to follow).
- **Multiselect batch move/delete must survive the old panes' death.** 2a is
  deliberately single-select (`BinderTreeVerbs.selectionForRow` returns
  `[id]`); the capability lives only in `ResearchView`/
  `CollectionResearchPane` today, and 2b deletes both.
- **Re-points**: `openResearchItem` (was `:2052` at 2a's start, now
  `Maugham/Views/ProjectWindow.swift:2091` — 2a's edits shifted it ~40
  lines; re-grep rather than trust either number), `handleShowLatestMCPNote`
  (was `:2351`, now `:2393`), and the find-research-match known gap (was
  `:714-737`, now `:714-738`, substance unchanged) — a research match sets
  `selectedResearchId` and nothing else while `.find`'s centre is
  `EditorHost` regardless. Task 5 removed the compounding half ("closing
  find used to slam the binder onto the manuscript") but left the
  underlying gap on purpose, per the comment at that site — it wants
  `.find` a centre column that follows the match's source, which is a
  redesign of find's routing, not a line fix.
- `Persona.showsManuscriptDocuments(for:)` (`Persona.swift:547`) needs
  re-basing once the `binderSegments` registry it reads dies — its
  discriminator vanishes with the registry.
- **The docs sweep** (unchanged list, still owed):
  `getting-started.md:16/:24/:26/:28/:30`, `research.md:3/:5`,
  `sense-pass.md:30-32`, `right-pane.md:28/:49/:51`,
  `structure-and-binder.md:26`, `screenplay.md:15`, `publishing.md:15`,
  `reference.md` keys. **Checked for Task 8**: none of these is false yet.
  2a is additive beside the strip, so the segment-picker prose these lines
  describe is still literally true; 2b's strip death is what falsifies
  them, not 2a.
- **The `Exports` footer's new gate** (`segment ==
  .documentHome(for: type)`, `BinderPaneToggle.swift`/
  `CollectionBinderPaneToggle.swift`) needs a new home once segments die —
  it is currently a derivation over `BinderSegment`, which won't exist in
  its current form.
- **CLAUDE.md's Views-row switch list is missing one member**: it names the
  switches a new `BinderSegment` case must answer (`displayName(for:)`,
  `pickerSymbolName`, `isTransient`, `centresTheCanvas`,
  `showsManuscriptStatusFooter`, both binder toggles, `ProjectWindow`'s
  editor and inspector switches) but not `showsSceneNavigator(for:)`
  (`Maugham/Models/BinderSegment.swift:114`). Fix the list when the
  switches themselves change in 2b — the cell already carries its own
  "count the switches, don't trust this list" caveat, so this is a note
  for the fix, not an urgent correction.

### Recorded decisions (2a)

- Binder column width range stays one spelling with no per-persona variance
  (`ProjectWindow.swift:158-160`) — the felt bug the width rule answers
  doesn't exist on the left.
- 2a is single-select; the tree's selection is the window's one subject.
- `CanvasSubject.resolve` answers `.wholeProject` for a `.research` subject
  until stage 3 gives the canvas its own highlight case for a research item.
- Link-before-unlink precedence on a drag out of a novel's fold to the
  shared section: answering the "is it linked" question first (rather than
  "lift out of the group") is deliberate — the one line to flip in
  `TreeDropIntent.outOfScope` if a writer reports the other expectation.
- `.find`/`.trash` do NOT let a research subject take their centre — the
  final-review fix wave (`73e10dbd`) keyed placement on
  `BinderSegment.leftPaneWritesTheSubject`, which returns both segments to
  pre-branch centre behaviour. (T5 had briefly generalized them; the
  generalization was what trapped a subject in `.canvas`/`.trash`, the
  eighteenth branch Critical.) `.find` still writes the subject only for a
  manuscript match — the asymmetry to revisit when 2b makes find an overlay.
- **The palette-name collision is RESOLVED (Denver's ruling, 2026-08-09,
  post-2b)**: refuse, not adopt — a shared-root research group whose minted
  path would collide with `research/palette` throws at creation and rename,
  case-insensitively; `ensurePaletteGroup` is the one unchecked minter.
  Merged `d0860761`.

### Denver's smoke list for 2a

- A palette card selected from the tree in Plan shows the card EDITOR in
  the right column (the fix wave routed the inspector half through
  `researchCentreRoute`; the raw-markdown preview is gone) — check it
  reads well beside the canvas.
- The intent strip in Author still shows the project's line over a selected
  research note (no doc id to show instead) — true but worth a look.
- ⌘⌥F in Author with a research item selected shows the document (the
  research subject stands down in `.find`/`.trash` after the fix wave).
- In Plan's Canvas segment, arrive carrying a research subject (select a
  note in Structure, switch to Canvas): the canvas inspector must be
  reachable and region/scrap clicks must work — the eighteenth Critical's
  repro, now guarded.
- Rename a linked note from a novel's SHARED section: exactly one rename
  field opens (linked fold rows are read-only views — no Rename there,
  deliberately; Duplicate/Delete remain).
- Reorder inside a novel chapter's fold bounces (the fold renders link
  order, which isn't settable until 2b's reorder API); reorder inside a
  collection piece's fold works.
- Live drag precedence (header vs. rows, novel fold vs. shared section) is
  unverifiable headless — needs a hands-on drag.
- Drag a note between a piece's fold and the shared section, in both a
  Collection and a novel — containment-move and link/unlink should feel and
  look different, and both should look right.
- The subject surviving its own rescope — drag the selected note into a
  fold and selection should hold rather than jump.

## 2b built — stage 3 owed — addendum, 2026-08-09

**Stage 2b of the shell finish** (plan
`docs/superpowers/plans/2026-08-09-shell-finish-stage2b-strip-death.md`) is
built on `feat/shell-finish-stage2b`, HEAD `b1d56e59`, tasks 1–9 merged and
review-clean, **not merged to main, not pushed**. The strip is gone: find is
an overlay of the whole tree (`ProjectWindow.treeFindActive`), trash is a
foot disclosure below the Research/Palette sections, the tree is multiselect
(`Set<BinderSubject>`, the window's one subject *derived* from it), a drag
onto the tree is scope (Finder files, browser bitmaps, paste, and Add File's
folder import all reach the same creation verbs `TreeDropIntent` already
routed internal drags through), and the Palette section's header keeps a door
onto a palette wall — a full-window card grid — in Author/Review/Publish,
disabled in Plan. `BinderSegment`, its picker, `Persona.binderSegments`/
`binderHome`, and `PersonaMemory`'s binder half are deleted, not deprecated;
two closed-set `TripwireGrepTests` censuses (named in `Maugham/Views/AREA.md`)
guard against either coming back. Docs caught up in this task (T9): the guide
sweep, CLAUDE.md's Views row, `Maugham/Views/AREA.md`'s binder-tree section,
and this addendum.

**Stage 3 carries forward verbatim** (spec `2026-08-08-shell-finish-design.md`
§9's third stage; none of this is stage 2b's to touch):
- **Keyspace re-points** — ⌘⌥R/⌘⌥P/⌘⌥O per spec §5, once the right-pane
  registry thins.
- **Right-pane registry thinning** — spec §5's second half; not started.
- **Project altitude / corkboard-to-centre** — the centre rule spec §9 names
  as stage 3's core: project altitude moves the corkboard into the centre
  column, still unbuilt.
- **The Plan double-click hop** — spec-named, still unbuilt.
- **The wall-in-Plan question** — the palette wall is disabled (not hidden)
  in Plan because Plan's centre column is already the canvas; whether the
  wall should ever be reachable there, and how, is stage 3's call.
- **The palette-name collision is RESOLVED** — Denver ruled refuse-not-adopt
  post-2b (2026-08-09): creation and rename of a shared-root group refusing
  the reserved path case-insensitively, `ensurePaletteGroup` the one
  unchecked minter, merged `d0860761`. Off stage 3's list.
- **The T7-noted select-only re-point, if a reveal is ever wanted** —
  `openResearchItem` (a wiki-link, the Inspector's Links row, the stats
  window navigating to a research item) selects the item without expanding
  its section in the tree to show it. Recorded as a deliberate scope cut in
  T7's report rather than an oversight: reaching into a host's disclosure
  state from the window would be a fourth writer of state three tree hosts
  already share, for a row the writer may not even be looking at — the
  subject is what both columns read regardless, so the item opens either
  way. Revisit if a writer reports losing track of where the selection
  landed.
- **T3's named risks, still live**: (1) the tree's `.link`/`.unlink` batch
  is a sequential loop over single-item store calls, not a plural verb — a
  mid-loop throw leaves earlier links applied and surfaces only via the
  shared alert; a plural store verb would close this. (2) a stale id can sit
  in `BinderTreeSections`' selection state until the next click — inert
  today by construction, but the rule for any NEW reader is to route through
  `shown`/`resolved`/`actingResearchIds`, never read the raw stored set,
  because those three derive from the live manifest and a raw read would
  not.
- **T4's minor deferred, still live**: the `.sharedAndLink` import loop
  (Finder files dropped on a novel chapter, which both imports to shared
  research AND links) is not fully atomic — a partial import-without-link is
  possible on a mid-loop throw, surfacing via the shared alert; `BinderRow`/
  `PieceRow` carry an asymmetric guard on empty drop providers.
- **T3's deviation, ruled sound but worth re-checking if multiselect grows
  new call sites**: no set-pruning sweep for the tree's `Set<BinderSubject>`
  selection — argued and reviewed as stale-proof because `ordered` and
  `actingResearchIds` both walk the live manifest on every read, so a
  deleted id simply can't come out of either, sweep or no sweep.

**Denver's 2b smoke list** (consolidated from the ledger's accumulated
flags — nothing here has been hands-on verified):
- **Find overlay** — ⌘⌥F opens it in every persona (not just the ones that
  used to carry a `.find` segment); Escape closes it in one press from
  anywhere inside the search field; a match click follows its source in
  both id spaces — a manuscript hit opens the document, a research hit
  routes the subject the way any other research selection does
  (`researchSubjectPlacement`: beside the canvas in Plan, the centre
  elsewhere).
- **Trash disclosure** — browse entries, Restore a row, Empty Trash, all
  from the foot disclosure's own chrome; a restore that returns less than
  was deleted shows the shortfall message at that moment (RULING-42
  surfacing) rather than silently dropping rows.
- **Multiselect** — ⌘-click two research notes → "Delete 2 Items"; a batch
  drag of a multi-selection into a fold moves the whole selection, not just
  the row that was dragged.
- **External drops** — a Finder file dropped on a chapter row links it (and
  imports to shared research); the same file dropped on a Collection piece
  rescopes it into that piece's own research folder; a browser-rendered
  image drops as an image; paste (⌘V, including a plain URL paste — newly
  alive as of T4, was silently dead before) lands the same way; a folder
  imports through **Add File…**, not through drag (a dropped folder still
  silently no-ops — a pre-existing store gap, not new in 2b).
- **The wall's door** — "Open Wall" in the Palette section header takes over
  the centre column in Author (and Review, and Publish); Escape closes it;
  it's disabled with an explanatory tooltip in Plan; the manuscript status
  footer is hidden underneath it rather than showing a stale goal capsule
  through it (Task 8's fix).
- **The `.find`/`.trash` centre reversal** — in 2a, `.find` and `.trash`
  segments deliberately refused to let a research subject take their
  centre (the fix for the 2a Critical). In 2b neither is a segment with a
  centre of its own any more — find is a column-wide overlay, trash a foot
  disclosure — so the question that reversal answered no longer has
  anywhere to be asked. Worth confirming in the flesh that no stale research
  subject shows through the find overlay or over the trash list.
- **The paste gate accepts `.project` as a stand-in for "no research focus
  selected"** — pasting with the project row selected still lands
  somewhere sane rather than refusing; not obviously the right long-term
  behaviour, flagged rather than fixed.
- **No whole-column catch-all drop** — dropping a file on blank tree space
  (not on any row) does nothing; the tree's blank space belongs to the
  manuscript, not to research import. Confirm this reads as "nothing
  happened" rather than as a bug.
- **Plan's research-subject preview replacing the region inspector** — T7's
  one deliberate behaviour change: selecting a research item in Plan now
  replaces the canvas's region/scrap/line inspector with the research
  preview, in every case (previously this only worked by dragging the
  writer onto an old pane). Confirm the preview reads well beside the
  canvas and that returning to a region/scrap afterward brings its
  inspector back correctly.

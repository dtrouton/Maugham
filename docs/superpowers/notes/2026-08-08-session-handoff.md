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
- `.find`/`.trash` now let a research subject take their centre too, rather
  than staying manuscript-only — flagged for Denver's smoke, not decided
  outright as a UX improvement.
- **The palette-name collision is surfaced, not decided**: a research group
  titled "Palette" takes the path `research/palette` and collides with the
  palette folder itself (pre-existing, confirmed still live). Task 8 does
  not resolve it — either `ensurePaletteGroup` should adopt/dedupe that
  folder, or group creation should refuse the reserved name. Denver's call.

### Denver's smoke list for 2a

- Palette card previews as raw markdown (front matter and all) in Plan's
  right column when selected from the tree — works, not pretty; a compact
  tile would read better.
- The intent strip in Author still shows the project's line over a selected
  research note (no doc id to show instead) — true but worth a look.
- `.find` and `.trash` now let a research subject take the centre.
- Live drag precedence (header vs. rows, novel fold vs. shared section) is
  unverifiable headless — needs a hands-on drag.
- Drag a note between a piece's fold and the shared section, in both a
  Collection and a novel — containment-move and link/unlink should feel and
  look different, and both should look right.
- The subject surviving its own rescope — drag the selected note into a
  fold and selection should hold rather than jump.

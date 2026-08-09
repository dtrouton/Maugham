# Session handoff — "ui-changes", 2026-08-08 → 2026-08-09: stage 2 closes, stage 3 opens

*Written at Denver's request. This session picked up the 2026-08-08 handoff,
built BOTH halves of the shell finish's stage 2 (plans 2a and 2b), reconciled
four origin merges, and landed the palette-name ruling. Paste the "Read
these" block into the next session's start.*

## State

**Local `main` is ~130 commits ahead of origin. NOTHING is pushed** —
Denver: "we will push this when happy"; the smokes below are the gate. What
they contain, in order: the 2a plan + milestone (the tree — sections,
widened subject, one sweep, folds, drag-is-scope; merged `1cf19122`); the
2b plan + milestone (the strip's true death — find overlay, trash
disclosure, multiselect, external input, the wall's door, the kill; merged
`acdd7662`); FIVE origin merges folded en route (the behavioural-spec
layer, phase-2's trash rework, phase-3's register rename, the gap-rulings
reconciliation at `c873e206`, and the RULING-52 Publications sweep at
`d379b2fe` — compilers now refuse an occupied destination by default via
`replacesExistingOutput:`, `CompileOrchestrator.Outcome` gained
`.cancelled`, thrown compile errors surface as `.failed` with a ledger);
Denver's palette-name ruling (`d0860761`). Local main is reconciled through
origin `050b3293`. Last full gates: clean (one chronic flake family,
discriminated by name every time — see "Flakes" below).

**Two-clone topology**: the behavioural-spec/register sessions work in
`~/src/experiments/Maugham`, a SEPARATE clone. Their pushes cannot carry this
clone's work. When Denver gives the push word here, this clone's main is
already reconciled through origin `cfc7c859`; if origin has moved again,
merge it first and **run `./gen.sh` before the gate if the merge adds Swift
files** (this session ate one all-red gate learning that).

## Read these, in this order (next session)

1. `docs/superpowers/specs/2026-08-08-shell-finish-design.md` — §4 (the
   centre-renders-the-subject table) and §5 (keyspace) are stage 3's spec;
   §9's stage-3 line names the scope. **Stage 3 is deliberately unplanned
   (rule 11): plan it against the built code.**
2. `Maugham/Views/AREA.md`'s binder-tree section — the built left column
   stage 3 stands on (tree, overlay, disclosure, multiselect, reveal rule).
3. The two stage-2 plans for what exists and why:
   `docs/superpowers/plans/2026-08-09-shell-finish-stage2b-strip-death.md`
   (and 2a beside it).
4. `MEMORY.md` + CLAUDE.md's invariants and tripwires, as always.

## Stage 3 — the centre rule (spec §4/§5/§9)

- **Project altitude**: clicking the project row in Author shows the
  corkboard/outline in the CENTRE, full width, cards↔table as a
  centre-local toggle; click a card → that chapter opens. Review's project
  row → read-through overview (M3's queue later); Publish's → whole-book
  preview. The centre never renders nothing (§4's degrade rule).
- **Per-persona subject rendering**: Plan gets the research-card highlight
  on the board (a NEW `CanvasSubject` case — 2a deliberately answers
  `.wholeProject` for research until this exists); Review's research/card
  view becomes read-only; Publish renders previews per §4's row.
- **The Plan double-click hop**: double-click a piece in Plan's tree →
  Author with that piece open (one gesture, the subject carries).
- **Registry thinning**: Outline/Corkboard leave the right-pane registry
  everywhere (they are the altitude centre now); Author's Research/Palette
  panes leave (the tree + References own that job);
  `PersonaPaneRegistryTests.canonicalPaneOrder` updates once.
- **Keyspace re-points** (§5): ⌘⌥R focuses the tree's Research section,
  ⌘⌥P Palette, ⌘⌥O selects the project row — `docs/guide/reference.md` in
  the same commit as each re-point.

## Carries into stage 3 (accumulated, verified live at handoff)

- **The wall-in-Plan question** — the palette wall's door is disabled (not
  hidden) in Plan; whether/how the wall is ever reachable there is stage
  3's design call.
- **`.find`'s subject asymmetry** — a find match writes the subject only
  for manuscript matches' navigation; research matches select without the
  full navigation posture. Revisit under the centre rule.
- **The select-only re-points** — `openResearchItem`/`handleShowLatestMCPNote`
  now REVEAL the right column (the 19th Critical's fix) but still don't
  EXPAND the tree's Research section to the item; a reveal-in-tree wants a
  single owner for the disclosure state three views share.
- **PARKED, ruled non-blocking**: a sub-100ms window on window-open where a
  find-match event landing before the subject seed would skip the reveal
  (self-heals on the next click; `progress`-ledger ruling recorded in the
  2b milestone memory).
- **Store gaps flagged by the 2b reviews**: `.link`/`.unlink` batch is a
  sequential loop (mid-loop throw leaves earlier links applied, surfaces
  via alert); `.sharedAndLink` external import is likewise non-atomic; a
  FOLDER dropped on a Collection piece silently no-ops
  (`importPieceResearchFiles` has no folder branch — wants a loud refusal
  at minimum); no piece-scoped "New Group" store API exists and an empty
  fold has no creation affordance; `BinderRow`/`PieceRow` guard empty
  providers asymmetrically vs the section targets.
- **T3's standing rule**: any NEW reader of the tree's `state.selection`
  must route through `shown`/`resolved`/`actingResearchIds` — never read
  the stored set raw.

## Flakes and machine hygiene (inherited, all discriminated)

- The wall-clock family fails under loaded gates and passes in isolation,
  every sighting: `DeclaredWorldDeriverTests` (both deadline tests),
  `ClaudeCLISessionTests.test_aSilentDeathSaysOnlyWhatItKnows`, and the
  CLAUDE.md-documented MCP clock pair. Apply the discriminator BY NAME
  before blaming a branch. Two NEW names joined on the day's ~15th gate,
  both instant fixture-loading failures under load, both green in
  isolation: `GitHubReleasesAPITests.test_parseValidResponse` and
  `FountainScriptPageCountTests.test_referenceFixture_pageCountWithinFivePercent`
  — one sighting each; if either recurs on a QUIET machine it is real.
- **Orphan checks must include `maugham-mcp`**: a 10-hour orphaned
  DerivedData mcp binary held the shared dev socket and poisoned gates for
  a whole night. `ps ax | grep -E "xcodebuild|maugham-mcp|MacOS/Maugham"`;
  kill only DerivedData-path processes, never `/Applications`.
- **Never kill a run on one ps snapshot** — sample CPU over 10s AND check
  the log/xcresult advanced; one healthy 6-worker run died to a
  pattern-matched glance. The gate lock protects gates from gates, not
  from a bare xcodebuild on the same DerivedData (build.db lock).
- Subagents stall silently on tail-buffered pipes and monitors that miss
  exits: log unbuffered to a file, poll the file, and the controller
  checks tree state (commits + report file), not idle notifications.

## Process — what stage 2 paid for

- **Nineteen consecutive whole-branch Criticals** (18th: a subject the
  writer couldn't put down; 19th: a subject with no surface at all). Both
  were N-tasks-compose-wrong seams; both reviews were dispatched WITH the
  seams named. Keep doing that, and keep the mounted guard on the REAL
  container (both Criticals hid behind probes that skipped the production
  gate — the delivery-path lesson, twice more).
- Version literals in tests fire on unrelated upstream bumps — assert
  version-relative (upstream's own pattern).
- Deleting a rule can break a census two directories away; only the full
  gate sees it. And a census that catches your own refactor mid-task is
  the census earning its keep — fix the shape, not the census.
- xcodebuild swallows MaughamTests emit-module diagnostics: a
  `SwiftEmitModule failed` with no error text is real; re-run the printed
  `Failed frontend command:` directly.

## Denver's smoke — the consolidated LIVE list (2a+2b union, post-fix-wave)

**Tree & subject** — click through Pieces/Research/Palette rows in every
persona; a collection piece's fold (contained, nested groups expand) vs a
novel chapter's fold (linked, flat, read-only rows); drag the SELECTED note
into a fold — selection holds.
**Find** — ⌘⌥F in every persona: overlay replaces the tree, no strip
anywhere; Esc closes in ONE press with the field focused; a manuscript
match navigates; a research match follows to the centre (Author) / reveals
the right column (Plan).
**Trash** — delete a chapter and a note; the foot disclosure appears;
browsing changes nothing above it; restore THE LAST entry when files are
missing → the shortfall message must appear (the toast, not silence);
Empty Trash confirms; ⌘⌥Z ("Restore Last Deletion") still lands.
**Multiselect** — ⌘-click two notes → "Delete 2 Items"; batch-drag two
notes into a collection fold; a set containing the project row degrades
the research verbs to single.
**External input** — Finder file onto a novel chapter row (imports shared
+ links) vs a collection piece row (imports INTO the piece); a browser
image; ⌘V of text AND of a URL (URL paste was silently dead before 2b);
Add File choosing a FOLDER; a note dropped on a group row ENTERS the group.
**Palette** — Duplicate/Delete from a card's tree row; drag a card onto
Plan's canvas; Open Wall in Author (status footer hides under it), Esc
closes it; the button is disabled in Plan with a tooltip; open the wall
then jump personas ANY way (⌘2, a Claude-arrival Show, a history
navigation) — the wall never reappears over the manuscript; creating or
renaming a group to "Palette" (any case) refuses with the reserved-name
message.
**The reveal (the 19th Critical's fix)** — in Plan with the right pane on
Inbox: click a research row → the inspector column reveals showing the
item; Claude `add_note` then Show → same; relaunch with a research subject
persisted → the pane does NOT force itself (restore is not an arrival).
**Deliberate behaviours a smoke might flag (not bugs)** — `.find`/trash
centre shows the document again (the research-centre experiment was
reverted with the trap fix); ⌘V lands in shared research when the subject
is the project; the tree's blank space takes no drops (targets are rows,
headers, placeholders); in Plan a selected research item's preview replaces
the region inspector until the subject clears.

**Plus the standing older lists, unchanged and still owed**: the second
draft's 7-item full-loop smoke (its handoff, top section) and the M2-era
remainders (same file, "Standing items").

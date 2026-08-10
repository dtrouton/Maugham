# Session handoff — "ui-changes", 2026-08-08 → 2026-08-09: stage 2 closes, stage 3 opens

*Written at Denver's request. This session picked up the 2026-08-08 handoff,
built BOTH halves of the shell finish's stage 2 (plans 2a and 2b), reconciled
four origin merges, and landed the palette-name ruling. Paste the "Read
these" block into the next session's start.*

## State

**PUSHED 2026-08-09 late: origin took the whole line (`c0a38d05..2900afb1`,
146 commits, fast-forward) on Denver's word after his live smoke.** The
paired Mac + phone RELEASE (the M1A manifest-bump gate) remains separate
and untagged — that is the next release decision, not this push's.
What the line contains, in order: the 2a plan + milestone (the tree — sections,
widened subject, one sweep, folds, drag-is-scope; merged `1cf19122`); the
2b plan + milestone (the strip's true death — find overlay, trash
disclosure, multiselect, external input, the wall's door, the kill; merged
`acdd7662`); FIVE origin merges folded en route (the behavioural-spec
layer, phase-2's trash rework, phase-3's register rename, the gap-rulings
reconciliation at `c873e206`, and the RULING-52 Publications sweep at
`d379b2fe` — compilers now refuse an occupied destination by default via
`replacesExistingOutput:`, `CompileOrchestrator.Outcome` gained
`.cancelled`, thrown compile errors surface as `.failed` with a ledger);
Denver's palette-name ruling (`d0860761`); two more smoke-find fixes (the
fold indentation, `0c6903a3`; the unbreakable-height pane bug + its
registry-walking census, `892d4f91`); and two further reconciliations —
the Inbox register sweep, then the RULING-54 op-log slice — bringing
local main to origin `c0a38d05`. **RULING-54 made `statementText` (and
kin) THROW**: our four call sites adapted to the fringe-reader shape
(`try?` with the reason recorded), with ONE residual recorded at
`CompilerEnvironment+Project.swift`'s briefing closure — a
declared-but-unreadable intent briefs as undeclared without a run-side
signal; if that silence matters, the closure wants a throwing signature
(register queue). One more one-sighting flake joined the ledger:
`ScreenplaySingleParseTests.test_applyTypography_usesPassedScript_notReparse`. Last full gates: clean (one chronic flake family,
discriminated by name every time — see "Flakes" below).

**Two-clone topology**: the behavioural-spec/register sessions work in
`~/src/experiments/Maugham`, a SEPARATE clone; coordinate merges over the
sockets as this session did. Standing rule either way: **run `./gen.sh`
before the gate if a merge adds Swift files** (this session ate one
all-red gate learning that).

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

**2026-08-10: DONE.** Denver marked this list, the second draft's 7-item
full-loop smoke, and the M2-era remainders all complete; v0.27.0 +
phone-v0.8.0 released the same day. No smoke debt carries into stage 3.
The two parked DECISIONS (assistant column scope; strip freshness) remain
open — they were never smoke items.

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

**Plus the standing older lists**: the second draft's 7-item full-loop
smoke (its handoff, top section) and the M2-era remainders (same file,
"Standing items") — **both marked done 2026-08-10 with the list above.**

## Addendum, 2026-08-10: stage 3a built, 3b owed

*Written at the end of stage 3a's seven-task plan
(`docs/superpowers/plans/2026-08-10-shell-finish-stage3a-altitude.md`),
merged unpushed on `claude/shell-finish-3a-altitude`
(`6871db10..19092ce1`). This is the addendum stage 3's own section above
promised — read it alongside that section rather than in place of it.*

### What 3a built

- **The project row's dead click became *zoom out*** (Tasks 1–3): `OutlinePane`
  is renamed `ProjectAltitudePane` and moved into the CENTRE column. Selecting
  the project row, a group, or nothing — in Author, Review, or Publish — fills
  the centre with the corkboard/outline (cards↔table toggle stays centre-local,
  `OutlineLayout` unchanged) instead of `EditorHost`'s "Select a document"
  placeholder; clicking a card or a table row opens that chapter, in the SAME
  `EditorHost` instance (`ProjectWindow.manuscriptEditor`'s `ZStack` — never a
  sixth `ViewBuilder` arm, which would tear the host down on every
  project↔chapter hop). Plan is untouched: `centresTheCanvas` takes the canvas
  arm first, so the project row there still shows the undimmed board.
  `showsStatusFooter` refuses while altitude shows.
- **The tree owns its disclosure state** (Task 4): `BinderTreeSectionsState`
  gained `researchSectionExpanded`/`paletteSectionExpanded`/
  `expandedResearchGroups`, and `reveal(itemId:research:)` opens whatever it
  takes for a row to be on screen (the owning section plus every ancestor
  group). `openResearchItem` and Claude's Show (`handleShowLatestMCPNote`)
  now call it beside their existing subject write, closing the reveal-without-
  expansion gap this handoff's carries section recorded. It only ever opens —
  collapsing stays the writer's own click, and a restore never forces it.
- **The keyspace re-points** (Task 5): ⌘⌥O now sets `selectedSubject =
  .project` (the altitude view's entry point) instead of opening a pane;
  ⌘⌥R/⌘⌥P now expand the tree's Research/Palette sections instead of opening
  one. All three are refused (no-op, no crash) while `treeFindActive` covers
  the tree. `docs/guide/reference.md` rows 34/35/39 carry the new meanings.
- **The kill** (Task 6): `DetailSegment.outline`/`.research`/`.palette`,
  `LinkedResearchPane.swift`, and `Palette/PalettePane.swift` are deleted
  outright — not demoted. Author's registry drops to `[.diagnostics, .intent,
  .references, .tasks, .history, .inspector]` (`Persona.panes`,
  `PersonaPaneRegistryTests.canonicalPaneOrder`). `PalettePane`'s two
  sense-glyph statics survive, moved to the new `PaletteCardReadView.swift`
  (`AssistantColumn`'s caller). `PersonaMemory`/`UIState` tolerant decodes
  absorb a stored dead segment with no migration (tripwire 11).
- **Docs caught up** (Task 7, this commit): the guide's outline/research/
  palette-as-right-pane prose is rewritten throughout (`right-pane.md`
  retitled "The Right Column"; `research.md`, `structure-and-binder.md`,
  `getting-started.md`, `sense-pass.md`, `compiler.md`'s cross-links);
  CLAUDE.md's Views row and `Maugham/Views/AREA.md` gained the altitude
  centre, the disclosure owner, and the keyspace re-points; `Persona.swift`'s
  Author-case narrative no longer describes Research/Palette as live panes.

### A finding along the way, not fixed in this task

`Maugham/Views/ResearchLinkPickerSheet.swift` — the picker sheet that used to
offer "Link Research…" from `LinkedResearchPane`'s **+** button — has **zero
production callers** after Task 6's deletion. Linking an *existing* shared
research item to a document is still possible (drag its row from the tree's
Research section onto the document's own row — `BinderTreeDrops.swift` calls
`ProjectStore.linkResearch`; promoting a canvas card/region into a novel
chapter also links it), but the picker-sheet affordance itself is dead code
with no path to it. Worth a decision: wire it somewhere (a document row's
context menu?) or delete it. Docs were written against what's reachable
(the drag), not against the orphaned sheet.

### 3b — owed, recorded decisions verbatim (Denver, 2026-08-10)

Carried from stage 3a's plan (`2026-08-10-shell-finish-stage3a-altitude.md`,
Global Constraints) — **3b is planned only after 3a builds (rule 11)**, and
these are the decisions already made, not open questions:

- **The travel rule**: in Plan, double-click any tree row travels to Author
  with that subject open; Open Wall in Plan travels to Author with the wall
  open (opened AFTER the persona switch lands, since the wall closes on
  persona changes).
- **Publish's whole-book preview**: the most recent compiled PDF via PDFKit;
  a piece subject shows the same preview; degrade to altitude when nothing
  has been compiled yet. Per-piece page-jump is a follow-up beyond that.
- **The canvas research-highlight case**: a new `CanvasSubject` case for
  Plan's board (2a deliberately answers `.wholeProject` for research until
  this exists) — the census identified `CanvasHighlightTests.swift:55-60` as
  the test 3b rewrites — plus the no-node degrade design question (standing
  chrome vs. undim).
- **Review's read-only research/card routing** — Review adjudicates; it
  doesn't edit research or palette cards from its own columns.
- **The find-match posture under the centre rule** — a manuscript match
  navigates through the centre; a research match's posture (select vs. full
  navigation) needs re-deriving against the altitude view now that the centre
  can show something other than a document.

### Denver's 3a smoke (recorded for the next session to run)

Project row in Author/Review/Publish → corkboard fills the centre; toggle to
table; click a card → chapter opens; typing after the hop is ⌘Z-safe; footer
absent over altitude; group row → altitude; ⌘⌥O/⌘⌥R/⌘⌥P land their new
meanings; collapse the Research section then Claude Show → section expands;
Plan untouched (project row → undimmed board); find overlay: tree selection/
expansion survives open/close (the Task 4 behaviour change). **Not yet run —
this addendum records the list, not a result.**

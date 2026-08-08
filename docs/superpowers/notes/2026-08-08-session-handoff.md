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

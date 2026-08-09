# Hygiene + Rename Durability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close issues #27 (tripwire-25 grep guard + doc-truth) and #31 (renameResearchPath joint dedup) in one small branch.

**Architecture:** One new `TripwireGrepTests` census with planted-offender self-check; three roadmap corrections + one CLAUDE.md pointer fix; `researchDedupedNotePair` generalized into `renameResearchPath` so `.md` and `_assets` destinations dedup jointly before any move commits.

**Tech Stack:** Swift / XCTest, Mac scheme only.

**Spec:** `docs/superpowers/specs/2026-08-09-hygiene-and-rename-dedup-design.md` — read first. S3 is already fixed (nothing here); the DocSync reconciler is declined (do not build it).

## Global Constraints

- TDD where behavior changes (Tasks 1 and 3); doc edits verified by reading.
- The grep census follows the file's OWN sibling pattern — read TW13/14/17's entries and the planted-offender meta-test section (`MaughamTests/TripwireGrepTests.swift:298+`) before writing; match their comment-exclusion and scanning approach exactly.
- Tripwire 14: all file moves in `renameResearchPath` already route through the typed mover — do NOT change the move calls, only the slug/destination choice.
- Fast loop `./scripts/test.sh`; single class `-only-testing:MaughamTests/<Class>`; **full gate `./scripts/test.sh full` at the end of Task 3** (green before merge; test.sh full runs core then Mac — the mid-run process handoff is a phase transition, not a restart).
- No new files anywhere → no `./gen.sh`.
- Commit per task; end bodies with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: TW25 grep guard (F2)

**Files:**
- Modify: `MaughamTests/TripwireGrepTests.swift` (new census + planted-offender meta-test in the `:298+` self-check section)

- [ ] Step 1: Read the file's TW13/14/17 censuses and one planted-offender meta-test end-to-end.
- [ ] Step 2: Write the census: scan production `.swift` under `Maugham/Canvas/` (production only — exclude none of the canvas files; there are no legitimate uses) for `.scaleEffect(` and for `.magnification` ASSIGNMENT (`magnification =` / `.magnification(`), excluding comment lines the way the siblings do. Failure message cites tripwire 25 and ADR 0026 and names the offending file:line.
- [ ] Step 3: Write the planted-offender meta-test: a temp source file containing `content.scaleEffect(camera.zoom)` run through the same scanning helper → the census logic flags it (mirror how the `:300` op-log-filename meta-test structures this).
- [ ] Step 4: RED check — plant a real offender in a Canvas file locally, watch the census fail, revert (verify `git diff` clean), then GREEN: `-only-testing:MaughamTests/TripwireGrepTests`.
- [ ] Step 5: Also update CLAUDE.md's tripwire-25 row: its "Enforced / more" cell gains the census name (the row currently cites only the spike note/ADR/CanvasCameraTests).
- [ ] Step 6: Commit `test(tripwires): tripwire 25 gets its grep guard — the silent one is silent no longer (F2)`.

---

### Task 2: doc-truth batch (F3, F4, S4, S8)

**Files:**
- Modify: `docs/roadmap.md` (:11 MCP-clock `•`→`✓`; the M1C left-open line ~:55; a new Group-3 line for PR #17), `CLAUDE.md` (Canvas cell's "count the arms" pointer), `MaughamTests/Canvas/PromotionCommandTests.swift` (ONLY if the kind-count assertion is a one-liner against an existing enumeration — check for a `Promotion.targets`-like array; otherwise skip, prose-only)

- [ ] Step 1: roadmap:11 — flip to `✓` with one line: resolved 2026-08-08 by per-class parallel workers (burn-in evidence in `docs/superpowers/notes/2026-07-29-mcp-clock-dependent-tests.md`'s Resolution section); match the roadmap's own ✓-entry style.
- [ ] Step 2: the M1C left-open line — reword "naming and deleting a line are mouse-only" to the accurate "a line has no route to be SELECTED except the mouse (and therefore none to delete it without one); ⌫ deletes a selected line" (verify current wording first; F4's point is select-only vs delete-only).
- [ ] Step 3: New Group-3 roadmap line: publish-pipeline improvements (PR #17, merged 2026-07-23, `read_preview_page` — the 51→52 tool-ledger step). Match neighboring entries' voice; place it chronologically.
- [ ] Step 4: CLAUDE.md Canvas cell — the "Count the arms in `PromotionCommandTests`' wiring census" sentence: correct it to say the census counts wiring SITES (eight at last count, but say "sites" not a number), and that the promotable subject KINDS live in `Promotion.targets`' arms. Check `PromotionCommandTests` for an existing site enumeration; add a kind-count one-liner only if trivial.
- [ ] Step 5: Verify each edit by re-reading; run `-only-testing:MaughamTests/DocSyncTests` (roadmap/CLAUDE.md edits must not trip its gates) and `-only-testing:MaughamTests/PromotionCommandTests` if touched.
- [ ] Step 6: Commit `docs: the roadmap stops lying about three things, and a pointer says what its census counts (F3+F4+S4+S8)`.

---

### Task 3: renameResearchPath joint dedup (#31) + the gate

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Research.swift:664+` (`renameResearchPath`'s slug choice), possibly `Maugham/Stores/ProjectStore+ResearchMove.swift:286` (`researchDedupedNotePair` — generalize its signature if needed rather than duplicating its logic; it is `static`)
- Test: wherever `renameResearchPath` is currently tested (`grep -rln "renameResearchPath" MaughamTests/` — join that file)

- [ ] Step 1: Read `renameResearchPath` whole, `researchDedupedNotePair` whole, and `Maugham/Stores/AREA.md`'s mover section (mandatory).
- [ ] Step 2: RED — the repro test: create a research note with an assets dir; plant an orphaned `<target-slug>_assets/` directory at the rename destination's assets path (no `.md` beside it); rename the note. TODAY: the `.md` moves, the assets move throws, manifest↔disk diverge — assert the divergence to prove the repro, then flip the assertions to the desired behavior: BOTH `.md` and `_assets` land at a jointly-vacant deduped slug, manifest matches disk, no throw.
- [ ] Step 3: GREEN — route the rename's slug choice through `researchDedupedNotePair` (generalized if its current shape assumes the move context — keep ONE implementation; a second copy is the drift W2 existed to kill). The dedup check runs BEFORE the `.md` move commits. Do not touch the move calls themselves (typed mover, tripwire 14).
- [ ] Step 4: Regression pass — the full class(es) covering `renameResearchPath` + the W2 `moveResearchItems` suites (find via `grep -rln "moveResearchItems" MaughamTests/`).
- [ ] Step 5: **Full gate** `./scripts/test.sh full` — green required, capture counts.
- [ ] Step 6: Commit `fix(stores): a rename dedups its note and assets jointly — W2's last sibling closes (#31)`.

---

## Post-plan (standing workflow)

- Whole-branch review (small diff — seams: the census's exclusion rules vs the planted offender; the generalized dedup helper vs its W2 call sites), fix wave if needed, finishing-a-development-branch.
- Close #27 AND #31 at merge (one comment each; #27's notes S3 already-fixed + reconciler-declined).
- Smoke (Denver, tiny): rename a research note that has images while a stray `_assets` folder with the target name sits beside it — both land renamed, nothing lost.

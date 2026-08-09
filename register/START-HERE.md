# START HERE — the behavioural-specification experiment

Handoff written 2026-08-08. Read this, then `RECONCILE.md`, then carry on.
**The standing plan is `PLAN.md`** — four phases with exit conditions, approved by Denver
2026-08-08; this file carries the live queue and state, the plan carries the arc.

## What this is, in four sentences

Maugham's behavioural specification is being built as two layers. **Claims** are verified facts about
what the code does, each pinned by a passing test — cheap and machine-generable. **Rulings** are human
product decisions about what *should* be true, authored by Denver — expensive and scarce.
**Reconciliation** runs the rulings over the claims; the mismatches are the output.

The experiment is testing whether that division of labour produces a better specification than either
layer alone, and how much of a codebase a small ruling set actually reaches.

## Where everything lives

Everything is under `register/`. **For its first 47+ phases the experiment changed zero
production files.** That era ended deliberately on 2026-08-08, with Denver's approval, when the
fix loop first ran (M4-RW-002, commit `7f741db4`) and consumption was wired into CLAUDE.md, two
AREA.md files and CI. The discipline that replaces it: **production changes ride the fix loop** —
a ruling authorising them, a pinned production test, and the claim + filing flipped in the same
branch. Characterisation of a NEW module still changes nothing outside `register/`.

| | Path | Note |
|---|---|---|
| **Rulings — source of truth** | `01-claims-ledger.json` → `_meta.rulings` | count the keys, not this cell — `RULINGS.md`'s header carries the generated count |
| **Rulings — readable** | `RULINGS.md` | **GENERATED.** Do not hand-edit |
| Regenerate the above | `scripts/23-generate-rulings.py` | verifies no ruling or clause is dropped; exits non-zero if any is |
| **Claims + filings** | `reconciliation/<Module>.{claims,filings}.json` | one pair per module |
| Filing template + disciplines | `reconciliation/PROTOCOL.md`, `RECONCILE.md` | 6 fields, 5 disciplines |
| Characterisation tests | `ExperimentTests/` (MaughamCore), `MaughamTests/Claims/` (app layer, permanent residents) | see "Running the tests" |
| Pre-claims decision surveys | `sweep2/*.json` | **leads, not facts** — see the warning below |
| Phase reports | `00-` … `24-*.md` | numbered in order |

**Two `RULINGS.md` decoys.** `reconciliation/RULINGS.md` and `sweep2/RULINGS.md` are frozen snapshots
of a *damaged* extraction, kept as evidence. Each now has a `FROZEN-SNAPSHOT.md` beside it explaining
why. **Read `register/RULINGS.md` and nothing else.**

## State of play

### Modules reconciled

<!-- BEGIN GENERATED STATE (register/scripts/27-generate-state.py) -->

| Module | Claims | Coverage | Complies / Violates | Report |
|---|---|---|---|---|
| `MaughamCore.TreeWalk` | 61 | 0% | — | `07-summary.md` |
| `MaughamCore.PaletteCardParser` | 47 | 34% | 16 reached | `07-summary.md` |
| `MaughamCore.PaletteCardModel` | 40 | 40% | 16 reached | `07-summary.md` |
| `Stores/TrashStore` + `ProjectStore+Trash` | 64 | 66% | 42 / 0 | `22-trash-reconciliation.md` |
| `OpLog/Document+Rewind` (+`RewindUndo`, `Deriver+Rewind`) | 35 | 60% | 21 / 0 | `24-rewind-reconciliation.md` |
| `OpLog/Document+Annotations` (+`AnnotationDeriver`, `AnnotationInverse`) | 57 | 35% | 20 / 0 | `28-annotations-reconciliation.md` |
| `Canvas/Promotion*` (the falsification module) | 78 | 62% | 46 / 2 | `29-promotion-falsification.md` |

The three MaughamCore rows are the 148 reconciled claims out of the ledger's 169; the app-layer rows are 234 further claims in their own files. **403 claims in the experiment, 382 reconciled.** The app layer stands at **129 complies / 2 violates** (MaughamCore's pure modules ran 31:1 — the inversion result).

App-layer claims are pinned by the PERMANENT suites in `MaughamTests/Claims/` — every full suite run and CI `mac-tests` re-verifies them; MaughamCore claims run as `register/ExperimentTests` (CI job `behavioural-claims`).

<!-- END GENERATED STATE -->

(History: the rewind row moved twice on 2026-08-08 — M4-RW-002 fixed and flipped with M4-RW-032
pinning its composition, then M4-RW-019 fixed under RULING-25 with M4-RW-033/034 pinning the scope
guard and the undo symmetry — the first two exercised fix loops, see below. Before promotion the
copies were re-verified at `f2b2b5e2`, 98 commits after their `db1bea2c` pinning: 61 tests, 0
failures.)

### The two results that have held across modules

1. **Coverage tracks writer-proximity, and discriminates.** 0% on a tree algorithm a writer never
   meets → 34–40% on a file format they edit → 47% on a pane they click → ~60% on the most complex
   action in the app (current figures live in the generated table above). A ruling set that
   reached everything would be too generic to be useful. Coverage is a DIAGNOSTIC, not a target —
   chasing it invites the stretching discipline 3 forbids.

2. **The comply/violate ratio inverts across the layers.** MaughamCore's pure modules ran 31:1.
   The app layer's live ratio is in the generated table above (21:18 as first reconciled; every
   fix loop moves it complies-ward, which is the layer doing its job). The old "97% of what a
   ruling reaches is already right" headline is a fact about pure, writer-distant code and
   **must not be restated about the codebase**.

### The methodological correction (accepted, and now confirmed twice)

A **decision survey** (`sweep2/`) samples the *residue a ruling set leaves* — it selects for arguable
cases. A **claim ledger** measures the ruling set. They are two different statistics and must not be
compared. Trash scored 0% specificity as a survey and 79% as a ledger; rewind scored 20% and 80%.

Rewind's number is confounded (RULING-22 was authored *from* rewind's survey), so phase 24 recomputed
it against the old ruling set: **20% → 67% (sampling correction) → 80% (new ruling)**. The correction
is the larger effect by 47 points to 13.

The cleanest evidence is in `sweep2/Rewind.json`'s own notes, which say *"RULING-4 holds throughout,
and holds well"* in prose while the survey's specificity statistic counts R4 zero times — because a
survey samples problems, and a ruling holding is not a problem.

## Read this before trusting anything in `sweep2/`

Those six files are **product decisions with no claims behind them. Nothing there is pinned by a
test.** Treat every entry as a lead. Of the ones checked so far:

- **REW-D9 was falsified outright** — it rested on the premise that a craft note carries a paragraph
  anchor. It cannot: three independent sites force craft notes doc-scoped. Its own
  `what_would_falsify_it` predicted this and was never checked.
- **Two findings under-filed to a root** because the ruling set they were given was damaged
  (trash D4 → RULING-22, rewind D11 → RULING-22).

## Resolved 2026-08-08 (Denver ruled; the loop ran)

- **GAP-R1 → RULING-25** (symmetric travel): annotations are protected to the same standard as the
  work during history travel — what Maugham closes on the way back is reopened on the return. This
  makes **M4-RW-019 a clean defect** and supersedes GAP-R6's stretch-R13 proposal; GAP-R2's Reopen
  action remains open as a surface question but is no longer the rewind case's recovery route.
- **The RULING-8 phantom clause was written** (sameness judged from the writer's question).
  Discipline 5's citation is now real, and the generator fails on dangling ruling references in the
  process docs.
- **The first fix loop ran end-to-end on M4-RW-002.** Fix + pinned production test
  (`HistoryPaneRewindTargetTests`) in commit `7f741db4`; claim updated; composition claim M4-RW-032
  added; filing flipped VIOLATES→COMPLIES; `_summary` recomputed. The lifecycle now has ONE tool —
  **`scripts/flip-claim.py`** (flip / recompute / repoint-after-rebase); the per-fix scripts 25/26
  are kept as history of the first two loops. State in this file between the GENERATED markers is
  written by `scripts/27-generate-state.py` — run it after any flip; hand-edits there are
  overwritten. Ruling-text amendments are caught by `scripts/23-generate-rulings.py`'s hash check,
  which fails listing every filing citing the amended ruling until re-run with `--amend` — the
  re-check queue is printed, not assumed done.
- **The second fix loop closed M4-RW-019 — the first fix authorised by a NEW ruling.** Commit
  `fb08aaf9`: `restoreToOp` gains step 9, the sweep's mirror — a forward restore reopens (a
  `.rewind`-stamped `.annotationReopen`) every annotation whose latest lifecycle op is a
  rewind-stamped archive from an open status and whose paragraph exists in the target state. The
  writer's own archives are untouched (M4-RW-033); undo re-archives through the compensating
  restore's own sweep, with zero bespoke undo code (M4-RW-034); the accepted-then-archived case
  deliberately stays archived — an unruled residual recorded in the filing. Pinned by
  `RewindTravelReopenTests` (production) and the rewritten characterisation copy, re-verified in
  place. Filing re-filed from RULING-8 to RULING-25 — the new ruling is the more specific reach.
  One lifecycle addition from the rebase that preceded this: **a filing citing a commit hash must
  be re-pointed when the branch is rebased** (`re-pointed`).
- **Consumption is wired**: CI job `behavioural-claims` runs the MaughamCore claims package on every
  push; CLAUDE.md has a "Behavioural claims + rulings" section; `Maugham/OpLog/AREA.md` and
  `Maugham/Stores/AREA.md` point at their filings; the constitution↔rulings precedence paragraph is
  in `RECONCILE.md`.

## Ruled 2026-08-08, round 2 (three of four with NO recommendation offered — the mitigation)

- **RULING-26** — accepted status rides travel too: forward travel restores an accept to
  `.accepted`, closing the accepted-then-archived residual. Fix loop pending in step 9.
- **RULING-27** — a missing moment restores to the NEAREST SURVIVING MOMENT, named in a notice
  that itself carries Revert. **The revert clause is Denver's own addition, offered by no option**
  — the strongest provenance of the questionnaire era. Convicts M4-RW-003/008/022's silent
  restore-to-the-present with a specified replacement. Fix loop pending.
- **RULING-28** — the collateral report has two halves: the confirm sheet states the full set
  (archives AND reopens) before commit, the post-restore report confirms what happened.
  `ProjectWindow`'s `_ =` discard and the impactSummary's omissions are now clean defects. Fix
  loop pending.
- **RULING-29** — any archived or rejected annotation is reopenable from the annotations pane;
  resolution is the writer's to reverse. `reopenAnnotation` gains its first non-undo caller.
  Fix pending, best built after the Document+Annotations characterisation pins that module.

## Open, and ordered by what I would do next

1. **The four fix loops above**, smallest first: RULING-26 (step 9's accepted branch, fully
   claim-covered today), then 27+28 together (both live at the restore boundary and its
   rendering), then 29 (after the module below is characterised).
2. **Next module: `Maugham/OpLog/Document+Annotations.swift`.** Now quadruply motivated — RULING-25
   and RULING-29 both get tested against pinned claims there, GAP-R2's fix lands there, and the
   verifier's not-chased thread (can a merge append into a live mirror unsorted?) is its probe
   target. `Maugham/Canvas/Promotion*.swift` (75% survey specificity) remains the harder
   falsification of the sampling correction.
3. **The gap queue is EMPTY as of 2026-08-08's four ruling rounds** — all 16 open gaps ruled in
   one sitting (RULING-30..45): annotations' six, rewind's GAP-R3, the model-proved race
   (GAP-A7 → RULING-33, with a collaboration-era revisit clause), and trash's eight. The ruling
   set stands at 45 + 4 principles. New gaps arrive only from new module characterisations and
   from fix loops' residuals. Method notes from the sitting: recommended options are 13/13 where
   offered (the tracked warning number); the no-recommendation questions produced two independent
   choices, one composed hybrid, and one answer (RULING-45) whose winning option only existed
   because Denver asked for the concrete example first — **present the live example wherever one
   exists**. Rewind's GAP-R2/R4/R5 and the accepted residual were
   ruled 2026-08-08 round 2; the independent verification that confirmed the residual blind is at
   `reconciliation/Rewind.verification-2026-08-08.json` (all five flipped filings confirmed 5/5 by
   a fresh-context verifier).
4. **`premise_verified` as a seventh template field** — recommended, but **only on a proposed
   ruling**, not on every filing. A filing is already pinned by a test, which is a premise check with
   teeth; a proposed ruling has no test and propagates to every future case. REW-D9 is the case for
   it: correctly scoped, high confidence, false premise, and no scope argument could have caught it.

## How to work on this

Non-negotiable, and each is a mistake someone already made:

- **Worktree — for characterising a NEW module only.** `EnterWorktree`, then
  `git reset --hard <pin>`. Tests go in `MaughamTests/Experiment/` while you characterise; when the
  module's claims are filed, the suite is PROMOTED into `MaughamTests/Claims/` on the branch — it
  becomes a permanent, running part of the Mac suite, not a copy. (The copies-that-don't-run
  arrangement was a zero-production-changes-era design; it ended 2026-08-08 when the non-running
  copies were recognised as the register's biggest rot risk. Probes stay in
  `register/app-layer-tests/` as history.)
- **Probe before you assert.** Write a probe that prints observed behaviour, run it, *then* write
  assertions from what it printed. Never from what the code looks like it should do. This caught three
  claims in rewind alone that came out opposite to the reading — including the one that falsified
  REW-D9.
- **`NO_RULING_REACHES` is the expected outcome.** ~half of every module. A high match rate is
  evidence *against* the rulings, not evidence of thoroughness.
- **Scope, not symptom.** A ruling reaches a case only if it falls inside its *stated* scope. The
  `why_in_scope` field is the check — if the sentence is hard to write honestly, the ruling does not
  reach.
- **`UNTRACED` rather than a guess**, and say plainly what you could not test.

### Running the tests

```bash
# MaughamCore claims — standalone SPM package, runs anywhere; CI job `behavioural-claims`
swift test --package-path register/ExperimentTests

# App-layer claims — PERMANENT residents of the Mac suite since 2026-08-08
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamTests/TrashCharacterization \
  -only-testing:MaughamTests/RewindCharacterization
```

The app-layer suites live at `MaughamTests/Claims/` and run in every full suite and in CI's
`mac-tests` job. **A claims test going red means PINNED BEHAVIOUR CHANGED** — check the module's
filings before "fixing" the test: a defect fix must flip its claim + filing in the same branch
(the fix-loop lifecycle), and a ruled-correct behaviour must not be changed casually.

For a full-suite check, `./scripts/test.sh full` (only the documented MCP skip).

## One thing worth fixing

Until this commit, none of this was in git — no history, no diff, no recovery. Given that RULING-24
tier 1 says the writer's work is version-controlled at all costs, the specification of that ruling was
the one artifact here with no version control at all. It is committed now; keep it that way.

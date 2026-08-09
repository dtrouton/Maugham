# START HERE — the behavioural-specification experiment

Handoff refreshed 2026-08-09 — the dated session handoff is `30-handoff-2026-08-09.md`
(read it after this file for the pickup queue and the conventions that bit).
Read this, then `RECONCILE.md`, then carry on.
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
| `Canvas/Promotion*` (the falsification module) | 78 | 67% | 52 / 0 | `29-promotion-falsification.md` |
| `Publish/Republisher` (+`CompileOrchestrator`) | 11 | 91% | 10 / 0 | — |
| `Stores/InboxStore` (+`InboxTranscriptionWorker`, the promote siblings) | 12 | 75% | 9 / 0 | — |
| `OpLogStore` read paths + `Document.load`'s refusal (the spine's first slice) | 6 | 100% | 6 / 0 | — |

The three MaughamCore rows are the 148 reconciled claims out of the ledger's 169; the app-layer rows are 263 further claims in their own files. **432 claims in the experiment, 411 reconciled.** The app layer stands at **160 complies / 0 violates** (MaughamCore's pure modules ran 31:1 — the inversion result).

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

## Ruled 2026-08-08, round 2 — ALL FOUR FIX LOOPS RAN in phase 2 (2026-08-08/09)

Three of the four were ruled with NO recommendation offered (the mitigation). Every "fix loop
pending" this section once carried is closed; the filings hold the details:

- **RULING-26** — accepted status rides travel too. Fixed `dfe2a77b` (M4-RW-035; M4-RW-036 is
  its composition claim).
- **RULING-27** — a missing moment restores to the NEAREST SURVIVING MOMENT, named in a notice
  that itself carries Revert. **The revert clause is Denver's own addition, offered by no
  option** — the strongest provenance of the questionnaire era. Fixed `6b15e905`
  (M4-RW-008/022).
- **RULING-28** — the collateral report has two halves. `ProjectWindow`'s `_ =` discard and
  the impactSummary's omissions fixed; M4-RW-038 pins the composition. RULING-52 (2026-08-09)
  is this family's completing sentence: a PARTIAL failure names both halves, standing for
  every future operation.
- **RULING-29** — any archived or rejected annotation is reopenable from the annotations pane.
  Fixed `5ea5b860` (M5-AN-039); `reopenAnnotation`'s first non-undo caller exists.

## Open, and ordered by what I would do next

1. **Phase 4's module sweep, RULING-52-first** (in progress 2026-08-09, branch
   `claude/publications-claims`): extend the Publications module — the compile/republish
   pipeline is the newest module (1 claim, born with #25's work) and the densest set of
   multi-step operations that can fail after their first write, which makes it the first
   systematic application of RULING-52's standing duty. After it, by writer-proximity:
   InboxStore, MCP/Tools (per RULING-21), checkpoint paths — the worthwhile set is roughly
   five or six more modules, not twenty (PLAN.md phase 4).
2. **RULING-54's strict-read sweep — THE OP LOG SLICE LANDED** (branch
   `claude/oplog-strict-read`, the OpLog module's first six claims): an
   unreadable op-log file or unlistable ops directory now REFUSES the document
   load with the file named (the mapped cascade — shorter doc → truncated
   autosave → superseded paragraphs → and, for the directory case, a
   re-bootstrapped parallel history — is closed at its first link); the
   closed-doc and compile reads are strict too, and the app-fringe readers are
   lenient with recorded reasons. STILL QUEUED, in order: **checkpoints**
   (CheckpointStore.load — an unreadable device file silently thins
   History/Rewind), the seal tail's silent skip, PendingBuffer's silent
   crash-recovery skip, BackupSignature's dropped file, and the
   publications/tasks lenient loads.
3. **Small residuals**: RULING-30's presentation duty (verify-and-file); the two
   formal-methods findings (§8.2/§8.4); the audio-capture nuance.
3. **The gap queue is EMPTY again as of 2026-08-09's P-gap sitting** — Promotion's five
   substantive gaps ruled (RULING-48..52): P1 research-protection (bridge ratified, milestone
   scheduled into `docs/roadmap.md`), P2 Name-withholding on Rewrite, P3 link identity
   (same target = same link → M6-PR-024 convicted), P4 contribution records are facts
   (multi-valued → M6-PR-072/073 convicted, 074 complies), P6 the general partial-failure
   sentence completing RULING-28's family. The ruling set stands at 52 + 4 principles. Method
   notes: the 2026-08-08 sitting ran recommended options 13/13; this sitting broke the streak —
   **P1 is the first decline** (Denver took the adjacent stronger-scheduling option over the
   recommended ratify-as-standard), and BOTH P3 and P4 were answered round 1 with a question
   back ("what's the user experience?" / "how does this happen — that's what tells me the
   user's intent") before the round-2 recommendations were accepted. The example-before-options
   finding is now three-for-three: **present the live example and the mechanics wherever they
   exist, before asking**. Earlier sittings: RULING-30..45 (2026-08-08, all 16 then-open gaps);
   rewind's GAP-R2/R4/R5 round 2, blind-verified 5/5 at
   `reconciliation/Rewind.verification-2026-08-08.json`.
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

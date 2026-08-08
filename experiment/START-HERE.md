# START HERE — the behavioural-specification experiment

Handoff written 2026-08-08. Read this, then `RECONCILE.md`, then carry on.

## What this is, in four sentences

Maugham's behavioural specification is being built as two layers. **Claims** are verified facts about
what the code does, each pinned by a passing test — cheap and machine-generable. **Rulings** are human
product decisions about what *should* be true, authored by Denver — expensive and scarce.
**Reconciliation** runs the rulings over the claims; the mismatches are the output.

The experiment is testing whether that division of labour produces a better specification than either
layer alone, and how much of a codebase a small ruling set actually reaches.

## Where everything lives

Everything is under `experiment/`. **For its first 47+ phases the experiment changed zero
production files.** That era ended deliberately on 2026-08-08, with Denver's approval, when the
fix loop first ran (M4-RW-002, commit `c5ca4d5e`) and consumption was wired into CLAUDE.md, two
AREA.md files and CI. The discipline that replaces it: **production changes ride the fix loop** —
a ruling authorising them, a pinned production test, and the claim + filing flipped in the same
branch. Characterisation of a NEW module still changes nothing outside `experiment/`.

| | Path | Note |
|---|---|---|
| **Rulings — source of truth** | `01-claims-ledger.json` → `_meta.rulings` | 25 rulings + 4 principles, structured |
| **Rulings — readable** | `RULINGS.md` | **GENERATED.** Do not hand-edit |
| Regenerate the above | `scripts/23-generate-rulings.py` | verifies no ruling or clause is dropped; exits non-zero if any is |
| **Claims + filings** | `reconciliation/<Module>.{claims,filings}.json` | one pair per module |
| Filing template + disciplines | `reconciliation/PROTOCOL.md`, `RECONCILE.md` | 6 fields, 5 disciplines |
| Characterisation tests | `ExperimentTests/` (MaughamCore), `MaughamTests/Claims/` (app layer, permanent residents) | see "Running the tests" |
| Pre-claims decision surveys | `sweep2/*.json` | **leads, not facts** — see the warning below |
| Phase reports | `00-` … `24-*.md` | numbered in order |

**Two `RULINGS.md` decoys.** `reconciliation/RULINGS.md` and `sweep2/RULINGS.md` are frozen snapshots
of a *damaged* extraction, kept as evidence. Each now has a `FROZEN-SNAPSHOT.md` beside it explaining
why. **Read `experiment/RULINGS.md` and nothing else.**

## State of play

### Modules reconciled

| Module | Claims | Coverage | Complies / Violates | Report |
|---|---|---|---|---|
| `MaughamCore.TreeWalk` | 61 | 0% | — | `07-summary.md` |
| `MaughamCore.PaletteCardParser` | 47 | 34% | 16 reached | `07-summary.md` |
| `MaughamCore.PaletteCardModel` | 40 | 40% | 16 reached | `07-summary.md` |
| `Stores/TrashStore` + `ProjectStore+Trash` | 51 | 47% | 13 / 11 | `22-trash-reconciliation.md` |
| `OpLog/Document+Rewind` (+`RewindUndo`, `Deriver+Rewind`) | 32 | 56% | 13 / 5 | `24-rewind-reconciliation.md` |

The three MaughamCore rows are the 148 reconciled claims out of the ledger's 169; the two app-layer
rows are 83 further claims in their own files. **252 claims in the experiment, 231 reconciled.**
(The rewind row moved twice on 2026-08-08: M4-RW-002 fixed and flipped, M4-RW-032 pinning its
composition; then M4-RW-019 fixed under RULING-25 and flipped, with M4-RW-033/034 pinning the
scope guard and the undo symmetry — two exercised fix loops, see below.)

**All 80 app-layer claims re-verified passing at HEAD `f2b2b5e2` on 2026-08-08** —
98 commits after they were pinned at `db1bea2c`, including changes to `ProjectStore.swift`,
`ProjectManifest.swift` and `Document+Load.swift`. 61 tests, 0 failures.

### The two results that have held across modules

1. **Coverage tracks writer-proximity, and discriminates.** 0% on a tree algorithm a writer never
   meets → 34–40% on a file format they edit → 47% on a pane they click → 52% on the most complex
   action in the app. A ruling set that reached everything would be too generic to be useful.

2. **The comply/violate ratio inverts across the layers.** MaughamCore's pure modules ran 31:1.
   The app layer runs 26:16 (21:18 as first reconciled; the drift since is the two 2026-08-08
   fixes flipping their filings plus the claims that pin the fixed behaviour). The old "97% of
   what a ruling reaches is already right" headline is a fact about pure, writer-distant code and
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
  (`HistoryPaneRewindTargetTests`) in commit `c5ca4d5e`; claim updated; composition claim M4-RW-032
  added; filing flipped VIOLATES→COMPLIES; `_summary` recomputed. The lifecycle is encoded in
  `scripts/25-flip-m4-rw-002.py`'s docstring — **that is the pattern for every future fix.**
- **The second fix loop closed M4-RW-019 — the first fix authorised by a NEW ruling.** Commit
  `12d763c9`: `restoreToOp` gains step 9, the sweep's mirror — a forward restore reopens (a
  `.rewind`-stamped `.annotationReopen`) every annotation whose latest lifecycle op is a
  rewind-stamped archive from an open status and whose paragraph exists in the target state. The
  writer's own archives are untouched (M4-RW-033); undo re-archives through the compensating
  restore's own sweep, with zero bespoke undo code (M4-RW-034); the accepted-then-archived case
  deliberately stays archived — an unruled residual recorded in the filing. Pinned by
  `RewindTravelReopenTests` (production) and the rewritten characterisation copy, re-verified in
  place. Filing re-filed from RULING-8 to RULING-25 — the new ruling is the more specific reach.
  One lifecycle addition from the rebase that preceded this: **a filing citing a commit hash must
  be re-pointed when the branch is rebased** (`ad37df90`).
- **Consumption is wired**: CI job `behavioural-claims` runs the MaughamCore claims package on every
  push; CLAUDE.md has a "Behavioural claims + rulings" section; `Maugham/OpLog/AREA.md` and
  `Maugham/Stores/AREA.md` point at their filings; the constitution↔rulings precedence paragraph is
  in `RECONCILE.md`.

## Open, and ordered by what I would do next

1. **Next module: `Maugham/OpLog/Document+Annotations.swift`.** Now triply motivated — it is where
   RULING-25's wider reach gets tested against pinned claims, where GAP-R2 lands, and where the
   M4-RW-019 fix's step 9 now lives adjacent. `Maugham/Canvas/Promotion*.swift` (75% survey
   specificity) remains the harder falsification of the sampling correction.
2. **The accepted-then-archived residual.** The step-9 `wasOpen` guard deliberately leaves an
   accepted suggestion the rewind archived in `.archived` on forward travel — its honest forward
   status would be `.accepted`, which is unruled. A product statement for the queue: *"travelling
   forward past an accept restores the suggestion to accepted, not merely to present."*
3. **10 gaps remain open** — 6 from trash (`22-*.md`), 4 from rewind (`24-*.md`; R1 ruled, R6
   superseded), each phrased as a product statement a non-programmer can rule on. They are the
   scarce-resource queue. The 2026-08-08 precedent: presented as structured questions with a
   recommended option, all three were ruled in one sitting.
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
  `experiment/app-layer-tests/` as history.)
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
swift test --package-path experiment/ExperimentTests

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

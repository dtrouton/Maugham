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

Everything is under `experiment/`. **Nothing outside it has been modified — 47+ phases, zero
production files changed.** Keep it that way.

| | Path | Note |
|---|---|---|
| **Rulings — source of truth** | `01-claims-ledger.json` → `_meta.rulings` | 24 rulings + 4 principles, structured |
| **Rulings — readable** | `RULINGS.md` | **GENERATED.** Do not hand-edit |
| Regenerate the above | `scripts/23-generate-rulings.py` | verifies no ruling or clause is dropped; exits non-zero if any is |
| **Claims + filings** | `reconciliation/<Module>.{claims,filings}.json` | one pair per module |
| Filing template + disciplines | `reconciliation/PROTOCOL.md`, `RECONCILE.md` | 6 fields, 5 disciplines |
| Characterisation tests | `ExperimentTests/` (MaughamCore), `app-layer-tests/` (app layer) | see "Running the tests" |
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
| `OpLog/Document+Rewind` (+`RewindUndo`, `Deriver+Rewind`) | 29 | 52% | 8 / 7 | `24-rewind-reconciliation.md` |

The three MaughamCore rows are the 148 reconciled claims out of the ledger's 169; the two app-layer
rows are 80 further claims in their own files. **249 claims in the experiment, 228 reconciled.**

**All 80 app-layer claims re-verified passing at HEAD `f2b2b5e2` on 2026-08-08** —
98 commits after they were pinned at `db1bea2c`, including changes to `ProjectStore.swift`,
`ProjectManifest.swift` and `Document+Load.swift`. 61 tests, 0 failures.

### The two results that have held across modules

1. **Coverage tracks writer-proximity, and discriminates.** 0% on a tree algorithm a writer never
   meets → 34–40% on a file format they edit → 47% on a pane they click → 52% on the most complex
   action in the app. A ruling set that reached everything would be too generic to be useful.

2. **The comply/violate ratio inverts across the layers.** MaughamCore's pure modules ran 31:1.
   The app layer runs 21:18. The old "97% of what a ruling reaches is already right" headline is a
   fact about pure, writer-distant code and **must not be restated about the codebase**.

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

## Open, and ordered by what I would do next

1. **GAP-R1 is the sharpest unruled question in the set.** RULING-24 is a ROOT that partitions
   protection into three named classes — the work / research / ingested-or-derived — and **an
   annotation is none of them.** It is the class rewind damages most (a forward rewind returns the
   paragraph and the pane task but leaves the comment archived, permanently and silently). A tiering
   root with a hole in the middle of its own domain. Needs Denver.
2. **`RECONCILE.md` discipline 5 cites a RULING-8 clause that does not exist** — *"two situations
   that merely look alike may legitimately differ"* is in neither `RULINGS.md` nor the ledger. Not a
   generator drop: the phase-22 audit *recommended* the amendment and it was never made. R8 is
   therefore **unqualified**, which makes rewind's M4-RW-019 violation cleaner than the survey
   supposed. **Either write the clause or stop citing it.**
3. **12 gaps are open** — 6 from trash (`22-*.md`), 6 from rewind (`24-*.md`), each phrased as a
   product statement a non-programmer can rule on. They are the scarce-resource queue.
4. **Next module.** `Maugham/OpLog/Document+Annotations.swift` is the obvious one: it is where
   GAP-R1, GAP-R2 and GAP-R6 all land, and rewind's reconciliation kept bouncing off RULING-13's
   scope. `Maugham/Canvas/Promotion*.swift` (75% survey specificity) would instead test the
   correction on a module where the surveys already did well — the harder falsification.
5. **`premise_verified` as a seventh template field** — recommended, but **only on a proposed
   ruling**, not on every filing. A filing is already pinned by a test, which is a premise check with
   teeth; a proposed ruling has no test and propagates to every future case. REW-D9 is the case for
   it: correctly scoped, high confidence, false premise, and no scope argument could have caught it.

## How to work on this

Non-negotiable, and each is a mistake someone already made:

- **Worktree.** `EnterWorktree`, then `git reset --hard <pin>`. Tests go in `MaughamTests/Experiment/`.
  Run `./gen.sh` after adding files. Discard the worktree afterwards and copy the tests back into
  `experiment/app-layer-tests/`. The main checkout stays clean.
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
# MaughamCore claims — standalone SPM package, runs anywhere
swift test --package-path experiment/ExperimentTests

# App-layer claims — need @testable import Maugham, so they only run inside a worktree
cp experiment/app-layer-tests/*.swift <worktree>/MaughamTests/Experiment/
cd <worktree> && ./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -only-testing:MaughamTests/TrashCharacterization \
  -only-testing:MaughamTests/RewindCharacterization
```

The files in `app-layer-tests/` are **copies and do not run in place** — that is the price of keeping
the main checkout clean, and it is deliberate.

For a full-suite check, `-skip-testing:MaughamTests/MCPServerLifecycleTests` (three MCP tests are
wall-clock-dependent and fail under load; see CLAUDE.md).

## One thing worth fixing

Until this commit, none of this was in git — no history, no diff, no recovery. Given that RULING-24
tier 1 says the writer's work is version-controlled at all costs, the specification of that ruling was
the one artifact here with no version control at all. It is committed now; keep it that way.

# Evals — labels, plants, and a calibrated judge

**Date:** 2026-09-09 · **Status:** draft for Denver's review
**Session:** "first reader timeouts on a 450-paragraph screenplay"

*Brainstormed with Denver 2026-09-09, out of the reader's-own-session spec
(`2026-09-09-the-readers-own-session-design.md`), whose §3 deferred the
per-kind effort table here. Denver's answers of record: the score is
**both** — a mechanical floor and an LLM judge — *"but we need to do some data
labelling exercise on if the outputs are good that we baseline on for the
judge"*; labelling happens **in-app, on the real runs**; the corpus is
**synthetic fixtures in the repo plus Denver's real runs kept private**
(the repo is public).*

## 1. Why

Every choice about how a run is made — model, effort, the briefing's shape,
the prompt's register — has been decided by reading one or two reports and
liking them. The session spec's effort question made that visible: medium or
high for a first reader is a quality question, and the transcripts answer only
time and tokens. *"Without tests we're just guessing."* This spec builds the
tests: labels the writer already gives, made durable; fixtures with known
defects that a run either finds or does not; and a judge that is trusted only
once it agrees with the writer.

Three layers, three plans, in the order they can be believed:

| layer | what it measures | who decides | plan |
|---|---|---|---|
| **labels** | whether real reports were good, in the writer's judgment | Denver | P1 |
| **the floor** | whether a run finds what was planted, and what it costs | the plants | P2 |
| **the judge** | letter and translation quality at scale, calibrated to the labels | a sealed `claude -p`, trusted at ≥ 80 % agreement | P3 |

## 2. Labels — in-app, on the real runs (P1)

**Notes are already labelled.** Accept, reject, stet and discuss on a queue
note are the per-note verdict a judge needs, and every compiler-minted
annotation carries `compilerRunId` (`Annotation.swift`, M4 P1). Nothing new is
collected for notes; the export (below) joins them.

**A run's prose gets a grade.** `RunGrade` — `.good`, `.mixed`, `.poor`, and an
optional sentence — on three surfaces, each the one place that prose is read:

- a check's letter in Author's Diagnostics pane and a round's letter in
  Review's cockpit — one control under `LetterSection`, supplied as a closure
  like its other verbs, so the two hosts cannot draw it differently;
- a translation round's report (`TranslationRoundReportView`), one control at
  its foot, grading the round as the author read it.

A design proposal is NOT graded: the gate's four verbs already are its label,
and the export carries them.

**Storage snapshots what was graded.** `.maugham/evals/labels.<slug>.jsonl`,
per project, per device (tripwire 17), append-only, latest record per run id
wins. A record carries the run id, kind, doc id, model, effort, `RunTiming`
(session spec §5), briefing hash, delta summary, and the graded prose itself
(the `Letter` or the `TranslationRound`), because the diagnostics sidecar is a
superseding ring — a label that pointed at a run by id alone would dangle the
sixth round later. Not an op-log op: a grade is the writer's judgment of a
derived artifact, not manuscript, and lives beside the asks file for the same
reason the ask does. It is not derived — losing it costs the labels — so it
is named as such in `Maugham/Stores/AREA.md`'s `.maugham/` layout.

**Export is an in-app command** — File ▸ Export Eval Labels… — writing the
joined corpus for the open project to a chosen folder, defaulting to
`~/Maugham-evals/labels/<project-slug>/`: the grade records, plus every
compiler-authored annotation with its disposition, text, refs, kind and run id,
read through the app's own stores (never the `.md`, tripwire 20). Rule 8 — a
new data type gets a UI surface for inspection and action — is met by the
grade control and this command; a script under `scripts/evals/` only
concatenates the per-project folders into one corpus.

**The labelling exercise itself** is Denver's: grade the runs already in the
sidecars and the ones to come, and read the queue's dispositions as the
per-note set. The judge (P3) is calibrated against whatever exists when P3
runs, and the exercise never ends — the corpus grows as Denver writes.

## 3. Fixtures and the floor (P2)

**Fixtures are synthetic and committed** under `evals/fixtures/<name>/`:

```
piece.md | piece.fountain      the manuscript, clean Markdown/Fountain
craft-intent.md                its statement, in the writer's voice
research/*.md                  a few notes to pin (small — some inline, one over the cap)
edition-brief.fr.md            for a translation fixture only
plants.json                    the ledger of planted defects
```

Three to start, written by Claude and approved by Denver for prose quality
before a plant is made: a prose chapter (~3,000 words), a screenplay excerpt
(~450 paragraphs — the case in hand), and a short story with a French brief.
A plant is `{id, kind, paragraphs: [ordinal…], description}` with `kind` one of
`continuity`, `conformance`, `reader.dream_break`, `reader.lost`,
`translation.departure`, `translation.number`, `translation.name`. Paragraphs
are named by ORDINAL because a fixture has no `¶id` until `Bootstrap` mints
them; the runner maps ordinals to ids after the load and matches a report's
refs against that map.

**The runner is an env-gated XCTest, never CI**: `MaughamTests/Evals/
EvalRunnerTests`, skipped unless `MAUGHAM_EVALS=1` (the `OpLogChainCostTests`
precedent). It builds a temp project from a fixture through the real
`ProjectStore` (the `CompilerRunCommandTests.makeProjectRoot` shape), wires
`CompilerEnvironment.production` over real stores and the real CLI — no fake —
and runs the matrix the environment names:

```
MAUGHAM_EVALS_KINDS=check,round,reread      MAUGHAM_EVALS_MODELS=sonnet,opus
MAUGHAM_EVALS_EFFORTS=medium,high            MAUGHAM_EVALS_REPS=2
MAUGHAM_EVALS_BUDGET_USD=40                  MAUGHAM_EVALS_OUT=~/Maugham-evals/runs
```

Each cell: the report goes through the REAL `DiagnosticIngest` (so a schema
drift scores as a failure, which it is), and the runner scores **recall** (plants
whose refs a note of the right section touched), **extras** (notes touching no
plant — a precision proxy, not a verdict, because a fixture can have real
faults nobody planted), **schema validity**, and from `RunTiming` the elapsed,
first-token, thinking tokens and cost. The translation fixture drives the real
`TranslationPipeline` for one round and scores the collator's departures the
same way. Every session in a sweep is spawned with `--max-budget-usd` (print
mode only, which `-p` is) so a runaway cell cannot spend the sweep's budget,
and the runner stops the sweep at `MAUGHAM_EVALS_BUDGET_USD` by summing each
result's `total_cost_usd`.

Output: one JSON per cell and one Markdown table per sweep under
`MAUGHAM_EVALS_OUT/<date>/`, private.

## 4. The judge (P3)

A sealed `claude -p` (`ColdCall`'s confinement — no MCP, no tools) with one
rubric per kind, scoring a letter or a translation round report on named
criteria, 1–5 each, with a sentence per criterion. The judge is Opus at high
effort and is not what is being tuned. Rubrics live in `evals/rubrics/`,
written from the specs that define each artifact (the letter spec's §3 for a
letter; ADR 0030 for a round report; a first reader's four kinds and her
prohibitions for a reader letter).

**Calibration before trust.** The judge scores the labelled corpus blind;
collapsing its 1–5 to poor/mixed/good, agreement with Denver's grades on a
held-out half must reach **80 %** before a sweep's judge column is reported
without a warning. Disagreements are listed by run id for Denver to read —
either the rubric is wrong or the label is, and both are findings. Note-level
agreement against dispositions is reported the same way.

## 5. The report, and what it decides

A sweep's table: kind × model × effort → recall, extras, judge mean, elapsed
p50, thinking tokens p50, cost p50. The decision rule for the session spec's
effort table is written down so it is not re-guessed: **the cheapest effort
whose recall and judge mean are within the sweep's own rep-to-rep spread of
the best.** The same table answers the next model change, the next prompt
change, and the chunked-translation plan when it comes.

## 6. Out of scope

- Running any eval in CI (real spend, real secrets).
- Committing any real piece, label or report.
- A writer-facing effort dial; the table is set from the sweep, in code.
- Grading design proposals (the gate's verbs are the label).
- A phone surface.

## 7. Testing

- P1: `RunGrade` round-trips; a regrade replaces by run id; the record carries
  the prose snapshot; the two `LetterSection` hosts and the round report draw
  the control from one closure (planted-offender census); the export writes
  the annotation join through the store and never reads a `.md` (the
  `adr-0018-ok` guard is untouched, i.e. no new annotation needed).
- P2: the ordinal-to-id map over a bootstrapped fixture; recall/extras over a
  hand-built report; the budget stop; every fixture's `plants.json` names
  paragraphs that exist (a fixture-integrity test that DOES run in CI, since it
  spends nothing).
- P3: the agreement computation over a hand-built label set; the rubric
  prompt's shape; a warning line when calibration is below the bar.

## 8. Sequence and gates

The session milestone ships first — it is the fix for the timeouts and it
provides `RunTiming` and the explicit effort argument the runner reads. Then
P1 (labels, in-app), P2 (fixtures and the floor), P3 (the judge and the
report). Each plan ≤ 10 tasks, subagent-driven, opus on the runner and the
judge, haiku reviewers; every task green on `./scripts/test.sh`; the first
real sweep is run by Denver on this Mac with a stated budget, and its table is
what moves the effort table.

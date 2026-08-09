# Phase 7 — Summary

**Hypothesis under test:** the behavioural claims constituting this software's implicit
specification can be generated mostly by machine, leaving only a small residue needing human
authorship.

**HEAD:** `db1bea2c` · **Production code changed: 0 files.** Everything produced lives under
`experiment/`. `MaughamCore`'s own suite is untouched and still green (453 tests, 1 skipped, 0
failures). The experiment's own suite is 99 tests, 0 failures, ~7s.

```sh
swift test --package-path experiment/ExperimentTests          # 99 tests
swift test --package-path Packages/MaughamCore                # 453 tests, unperturbed
python3 experiment/scripts/05-agreement-map.py                # recompute all metrics
python3 experiment/scripts/06-rank-rulings.py                 # recompute the ruling queue
```

---

## 1. Metrics

### Generation

| | M1 `PaletteCard` | M2 `TreeWalk` | Total |
|---|---|---|---|
| Source LOC / public surface | 314 / 25 | 179 / 12 | 493 / 37 |
| Existing tests | 24 | 12 | 36 |
| **Claims extracted from existing tests** | 48 | 27 | **75** (2.0 per test) |
| **Characterization claims** | 52 | 36 | **88** |
| **Ledger total** | 100 | 63 | **163** |
| Intent clauses, Arm A (code only) | 22 | 20 | 42 |
| Intent clauses, Arm B additions | 7 | 6 | 13 (**+31%**) |
| Generated tests written | 52 | 27 | 79 characterization + 15 properties |

### Evidence

| | Value |
|---|---|
| Properties written / held / shattered | 15 / 12 / **3** |
| Total property cases run | **240,160** |
| Claims carrying property evidence | 39 of 163 (24%) |
| Region C — asserted **and** independently confirmed | 28 (17%) |
| Region D — observed with no covering test | **84 (52%)** |
| Uncorroborated existing-test claims | 44 (27%) |
| Non-deterministic, recorded but not pinned | 2 |
| Silence ratio, M1 / M2 | 0.50 / 0.54 |
| Region A — clauses with no observed support | 15 of 55 (27%) |
| — **genuine hallucinations** | **3 (5.5% of clauses)** |
| Contradiction rate, hammered claims | **7.7%** (3/39) — 2 of the 3 caused by my over-extraction |
| Contradiction rate, intent clauses | 3.6% (2/55) |
| Ratchet top-10 flagged unsafe | **7 of 10** |

### The gate

| | Value |
|---|---|
| Items requiring a human ruling | **25** (the cap — 14 rulable items were cut) |
| — RATIFY | 4 |
| — INCIDENTAL-KILLABLE | 5 |
| — LATENT_DEFECT | 5 |
| — **NEEDS-DISCUSSION** | **11** |
| Claims generated per ruling slot | ~6.5 |

**What the hypothesis looks like on these numbers.** 163 claims and 55 clauses were produced with
no human input, and the error rate is genuinely low: 3 hallucinations in 55 clauses, 3
contradictions in 39 hammered claims — and two of those three contradictions are *my extraction
being too strong*, not the code being wrong. So the generative half survives.

The residue does not shrink the way the hypothesis wants. It is **11 undecidable judgements plus 8
architectural clauses no behavioural evidence can reach**, and it did not get smaller as evidence
got stronger — 240,160 property cases moved zero items out of NEEDS-DISCUSSION, because every one
of them turns on *intent*, not *behaviour*. The right shape of the claim is probably: **machine
generation is cheap and accurate at the observation layer, and the human residue is not a
percentage of it — it is a roughly fixed set of decisions that more machine effort does not
reduce.**

---

## 2. The three biggest surprises

### 2.1 The well-tested module was barely less silent than the under-tested one — 0.50 vs 0.54

Phase 0 selected the pair for a 3.6× contrast in tests-per-dependent-file. The silence ratio came
back nearly identical. My first instinct was that test density does not buy specification
coverage; I now think that is the wrong conclusion, and the honest one is worse for the
experiment: **the silence ratio's denominator is something I generate, so it substantially measures
my enumerator rather than the codebase.** I stopped writing characterization tests when I ran out
of edges I could think of, and I can think of about as many edges per module either way.

What *did* survive as a real contrast is Region A: 42% of M2's clauses have no behavioural support
against 14% of M1's — and for a structural reason, not a quality one. `TreeWalk` exists to *be the
only implementation* of something (~36 hand-rolled walkers were deleted into it), so most of its
intent is about the codebase rather than about its own outputs. **A module whose purpose is to be
the single place something lives will always have an envelope that behavioural testing
under-serves.** That is a more useful finding than the ratio I set out to measure.

### 2.2 The suite leans on `TreeWalk` far harder than it tests it — and only the tests reveal this

`TreeWalk` appears in 13 test files. In **12 of them it is a fixture helper, not a subject**: tests
call `TreeWalk.find(...)` to locate a node so they can assert something about `ProjectStore`,
`Canvas`, `Inbox` or the MCP tools. So a `TreeWalk` regression does not merely break its own 12
tests — it makes assertions across four other subsystems **report on a lie**.

This is invisible from production source. It was Arm B's single most valuable clause (`M2-B-01`),
and it is the clearest evidence in the experiment for what the test suite contributes that the
code cannot: not *what* the rules are, but *how much rests on them*.

### 2.3 A property can be green at 20,000 cases and test nothing

My first P09 asked whether a model whose `body` contains a carriage return survives a round trip.
It held over 20,000 cases and was worthless: the renderer always emits `\n`, so a lone `\r` is
just a body byte that P05 already covers. The claim was about a document arriving *from outside*
with CRLF endings — a parse-side property that **a round-trip property can never reach**, because
the round trip's input is always renderer-produced. Reframed as `parse(LF) == parse(CRLF)`, it
shattered on case 1.

The same failure hit P04: I filtered its pathological generator through `isEditorReachable`, which
rejected 50,961 candidates — and the filter's job is precisely to remove the `kind:`-shaped body
lines the property existed to test. It held, vacuously. I caught it only because the harness
happened to print its rejection count.

**Neither miss would have been visible in the artifact.** The ledger would have recorded
`cases_run: 20000, held: true` in both cases and I would have reported strong evidence. Five of my
twelve holds are round-trip-shaped and share P09's blind spot. **Any metric here that sums
cases-run should be discounted accordingly.**

---

## 3. Where machine generation was weak

Ordered by how much it should change your reading of the results.

**1. Arm A is contaminated and I could not fix it.** By Phase 3 I had read every test and written
79 characterization tests. A true clean-room Arm A needs an inferrer who has never seen the suite;
I did not dispatch one because this session's instructions bar the Agent tool absent an explicit
request. My mitigation — *every Arm A clause must cite production source, a comment, or a commit,
and none may cite a test* — is mechanical and checkable, and it does stop me from *importing*
test-derived clauses. It cannot stop me from having been *steered* toward the right places to look.
**Treat the +31% Arm B lift as a lower bound.** This is the one number I would not defend.

**2. Claim extraction systematically overstates what the suite guarantees.** Reading
`XCTAssertNil(color(fromHex: "#GGGGGG"))`, I wrote down "rejects non-hex digits" — a strictly
stronger claim than the test makes, and false. Two of the three contradictions in Phase 5 are this
error, not code defects. The generalisation is natural, invisible without hammering, and it means
**a machine-generated ledger reads as more authoritative than the suite behind it.** If the
derivation ratio is computed without separating "machine found a real defect" from "machine
over-read a test", it will credit the machine twice.

**3. I cannot tell an intentional residual from an unexamined one.** `M1-A-01` promises a
round-trip law "for any editor-reachable model" and never defines the term. Writing
`isEditorReachable` for P01 took **eleven** conditions, none of which appears in any comment, test
or type. Four ruling items (R04, R11, R12, R13) are all one question — *is this shape reachable
or not?* — and no amount of evidence answers it, because the answer lives in what the UI can
produce and what the author meant. This is the residue, and it is not small in importance even
though it is small in count.

**4. Region A is 27% of the envelope, and 80% of it is real.** Only 3 of 15 unsupported clauses
were hallucinations. The other 12 are architectural rules ("be the only implementation", "the
phone must not re-implement this", "reach `path` through closures, never by widening the
protocol"), provenance, and design directives — verified by grep, the build graph, or the compiler,
never by an assertion. **Any scheme that treats "has no test" as "isn't a requirement" would
delete most of the real intent in M2.**

**5. Pinning is not endorsement, and the artifacts do not enforce that distinction.** Eleven
characterization claims pin behaviour I believe is wrong, and two (`M1-C-040`'s exact byte string,
`M1-C-042`'s enum order) are deliberately over-specific — the sort of pin that turns a harmless
refactor red. They carry `warrant: LOW, intent: UNKNOWN`, but nothing stops a downstream process
reading them as specification. **If the human pass ratifies pins like these unread, that is the
falsification this experiment exists to make possible.**

**6. The ratchet rule is unsafe on this ledger, and its failure mode is specifically machine-shaped.**
Ranking by reverse-dependency count puts `M2-C-036` at #2 — one of only two claims I *deliberately
refused to pin* because it is environment-dependent. Auto-promotion would ratify a claim with no
test at all, precisely because `TreeWalk` is called from 105 places. `M1-C-003` — the `#+FFFFF`
hole, shattered at case 69 — sits in M1's top 8 and would be blessed as intent. And the global rule
never looks at M1 at all, because M1's highest dependency count is 8 against `TreeWalk`'s 105.
**Reverse-dependency count and evidence strength are uncorrelated here.** Dependency count should
govern review *order*; evidence strength must be a *gate*.

**7. Two limitations baked in at Phase 0.** I chose two pure, deterministic, I/O-free, UI-free
modules so characterization would be honest — which is why only 2 of 163 claims needed the
non-deterministic bucket. `OpLogStore`, `InboxStore` or the editor seam would have produced a
very different ratio, and I rejected `OpLogStore` for exactly this reason. **This measured the easy
case.** Separately, the 25-item cap was binding, not comfortable: 14 rulable items were cut, five
of which I think are genuinely worth ruling. At ~6.5 claims per ruling slot, the constraint on this
whole approach is not generation throughput but adjudication throughput.

---

## 4. Artifacts

| Path | What |
|---|---|
| `00-module-selection.md` | Phase 0 — selection, criteria, rejected candidates, harness |
| `01-claims-ledger.json` | **The ledger** — 163 claims + `_meta.agreement_map` + clause verdicts |
| `02-characterization-notes.md` | Phase 2 — method, what was unobservable, 11 defect candidates |
| `03-intent-envelope.md` | Phase 3 — 42 Arm A clauses, 13 Arm B additions, contamination warning |
| `04-property-results.md` | Phase 4 — 15 properties, 3 shattered, the property I got wrong |
| `05-agreement-map.md` | Phase 5 — regions, silence ratios, contradictions, ratchet-safety |
| `06-ruling-sheet.md` / `06-ruling-queue.json` | Phase 6 — the 25-item human gate |
| `07-summary.md` | This file |
| `ExperimentTests/` | Standalone SPM package: 99 tests (79 characterization + 15 properties + probe + smoke) |
| `scripts/` | Three Python scripts reproducing every ledger mutation and metric |

**Stopping here for your ruling pass.** After it, the derivation ratio is computable from
`06-ruling-queue.json` plus your verdicts — and I would suggest computing it two ways: once
crediting every generated claim, and once excluding the claims whose only defect was my
over-extraction (§3.2). The gap between those two numbers is the honest cost of machine generation.

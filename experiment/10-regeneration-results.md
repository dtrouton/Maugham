# Phase 10 — Regeneration results

**Question:** if claims are the durable artifact, can code be rebuilt from claims alone — and do
the *downstream* dependents survive?

**Method.** A blind agent was given `experiment/08-regeneration-brief.md` — public signatures with
bodies and doc comments stripped, 63 claims, 26 intent clauses, property-test evidence — and
nothing else. It was instructed to read exactly that one file, and to write neither tests nor
verification. The brief was built by `scripts/08-build-regen-brief.py`, which fails hard if
implementation tokens or verbatim doc-comment lines appear in the output. Predictions were
recorded in `09-regeneration-predictions.md` before dispatch.

The regenerated file was swapped into an isolated git worktree; a second worktree at the same
commit ran the control in parallel. The main checkout was never modified.

---

## 1. Results

| Suite | Control (HEAD) | Regenerated | Regressions |
|---|---|---|---|
| MaughamCore package | 453 tests, 1 skipped, **0 failures** | 453 tests, 1 skipped, **0 failures** | **0** |
| — of which `TreeNodeTests` | 12/12 | 12/12 | 0 |
| Mac scheme (`Maugham`) | 3856 tests, 8 skipped, **3 failures** | 3856 tests, 8 skipped, **3 failures** | **0** |
| Phone scheme (`MaughamPhone`) | — | 221 tests, **0 failures**, TEST SUCCEEDED | **0** |

The three Mac failures are **identical in both runs** and are exactly the clock-dependent tests
CLAUDE.md documents as failing under a loaded suite:

```
MCPBinaryIntegrationTests.test_binary_exitsCleanly_onStdinClose()
MCPColdStartTests.test_firstCallAfterLaunch_pollsUntilServerBinds_noPriorConnection()
```

**Zero downstream regressions across 105 call sites in 36 files, on both platforms.**

### The code

With comments stripped, the regenerated implementation is **behaviourally identical to the
original, function for function** — including reproducing the P13 `rewritePaths` defect exactly.
The only substantive difference runs the *other* way: where the original writes
`out.append(contentsOf: collect(in: kids, where: predicate))`, allocating and concatenating an
array at every recursion level, the regenerated version threads a single `inout` accumulator
through a private overload. Same asymptotics, strictly fewer allocations. **The blind implementer
wrote marginally better code than the original, from the specification alone.**

---

## 2. Scoring the predictions

| # | Prediction | Outcome |
|---|---|---|
| 1 | It compiles | ✅ |
| 2 | `TreeNodeTests` passes | ✅ 12/12 |
| 3 | **Headline: the first breakage is COMPLEXITY** — a flatten-then-filter `collect`, an O(N²) walk, a performance test tripping | ❌ **Wrong, and backwards.** No performance test moved. The regeneration allocates *less* than the original. |
| 4 | `rewritePaths` either silently fixes P13 or faithfully reproduces it | ✅ Reproduced it — and *deliberately*, resolving "a MUST beats a LOW-warrant property", then documenting the choice |
| 5 | The false clause `M2-A-16` ("ids MUST be unique") causes visible harm | ❌ **Wrong.** It was caught, cross-referenced against `M2-C-012/013/014` and P14, and resolved *against* the MUST |
| 6 | 1–3 downstream Mac failures | ❌ **Zero** |
| 7 | Pre-order, `leaves`, `mutate` ordering, `idsByPath`, empty-forest, `collect` non-pruning all survive | ✅ All |

**3 correct, 4 wrong.** My most confident prediction was my most wrong.

---

## 3. The actual finding: the regeneration was never where the value was

The code came back equivalent. Everything of value came from the implementer's **notes** — and
what it found there, no part of my evidence layer had found.

### Three defects found by reading the artifact against itself

**(a) `M2-C-024` was false.** I wrote: *"an empty oldPrefix rewrites ONLY empty paths, not every
path."* The implementer observed that under the mandated rule the descendant arm reads
`"" + "/"`, which matches every absolute path. Verified against the real code:

```
oldPrefix=""  path="/q"   →  "NEW/q"     rewritten
oldPrefix=""  path="x/y"  →  "x/y"       not rewritten
```

**(b) `M2-C-027` was false.** I wrote: *"a trailing slash silently makes the WHOLE rewrite a
no-op."* Only the descendant arm dies; the exact-match arm still fires:

```
oldPrefix="p/"  path="p/"   →  "NEW"     rewritten
oldPrefix="p/"  path="p/q"  →  "p/q"     not rewritten
```

It also offered a diagnosis I had not reached: *"I suspect C-027 was written against a code shape
that had no exact-match arm — which is exactly what M2-B-05 says the prior store-local
implementations lacked."*

**(c) A latent defect in production code.** `TreeNode` has no `AnyObject` bound, so a **class** may
conform — and for a class conformer `var copy = node` copies a *reference*, so writing
`copy.children` writes through to the caller. Verified:

```
before:            root.children = ["kid"]
after remove(kid): root.children = []
INPUT MUTATED: true
```

`M2-A-11`, `M2-T-018` and property **P12** all state that the input forest is never disturbed. All
three are violated, silently, with no diagnostic. Latent only because `StructureItem` and
`ResearchItem` happen to be structs.

All three are now pinned as tests (`test_C024a`, `test_C027a`, `test_C037`) and the ledger is
corrected — `M2-C-024` and `M2-C-027` carry `warrant: "CORRECTED"` with their superseded
statements and a note on how each was found.

### Why 240,160 property cases missed all three

Two distinct blind spots, and the second is the more interesting:

1. **The closed loop.** I wrote `M2-C-024` and `M2-C-027` *from my own probe output*, then wrote
   characterization tests using *the same probe inputs*. The tests confirmed my wording rather than
   testing it. My Phase 2 note claimed the probe-first method protected against writing assertions
   from expectation — it protects against that, and not at all against **under-sampling the input
   space in the claim and the test identically**.

2. **P12 could not have found (c) at any iteration count.** The hazard lives in the *type system*,
   not the value space. Its generator produced struct conformers because I wrote one struct
   conformer. Running it at 20,000,000 cases would have found nothing. **Some contracts are not
   reachable by sampling values, no matter how many.**

### The two techniques found disjoint defect sets

| Found by execution (Phases 2–4) | Found by consistency-checking (Phase 10) |
|---|---|
| CRLF destroys a card (`M1-C-024`) | `M2-C-024` is a false claim |
| `color(fromHex:)` accepts `#+FFFFF` (`M1-C-003`) | `M2-C-027` is a false claim |
| `rewritePaths` trailing-slash behaviour (P13) | class-conformer input mutation (`M2-C-037`) |

Neither subsumes the other. **Execution probes where you point it; consistency-checking probes the
artifact's own seams — and the seams are where my errors were.**

This revises what I argued at the end of Phase 4: that claims review finds violations but not
omissions, so an adversarial generator is needed for the rest. Half wrong. Consistency-checking
found omissions too — omissions *in the claims*, which is a category I had not separated from
omissions in the code.

---

## 4. Eight contradictions the implementer found in the artifact

It was asked to report contradictions and found eight, each quoted by id with a stated resolution.
Beyond (a) and (b) above:

- **`M2-C-010` vs `M2-C-020` / `M2-A-03`.** My claim text glossed pre-order as *"(shallowest, then
  leftmost)"* — which is breadth-first, and contradicts the two claims that say depth-first. **My
  parenthetical was simply wrong.** Resolved for pre-order, 2-to-1, "and because `M2-A-03` is a MUST".
- **`M2-A-16` vs five duplicate-id claims and P14.** Resolved as "uniqueness is a caller-side
  expectation the walkers do not enforce and do not rely on" — the correct reading, reached against
  a MUST.
- **`M2-A-19` vs `M2-A-10` / `M2-C-031` / `M2-C-032`.** Same shape: one clause says the case cannot
  arise, three specify what happens when it does.
- **The `CONTRADICTED` warrant vs the intent envelope.** *"the warrant column and the intent
  envelope are recording two different rules under overlapping ids."* Correct: `M2-T-023/024` state
  the syntactic rule, P13 falsified the *semantic* one.
- **`M2-A-11` vs the protocol's type constraints** — finding (c).

**The escalation mechanism worked.** Every contradiction was surfaced, attributed by id, and
resolved with stated reasoning rather than silently.

### The structural gap it named

Its single biggest complaint:

> `rewritePaths` is specified three times and the three specifications do not agree. […] The brief
> never says whether a trailing slash on `oldPrefix` is a caller error, a normalised input, or the
> bug P13 is complaining about — and every one of those readings produces a different, silently
> divergent implementation of the one function in this file that renames files on a writer's disk.

And its precise ask: *"a single sentence saying whether P13 is a bug report or a documentation of
accepted behaviour would have settled it."*

**That sentence is a ruling.** The ledger records `warrant` — how strongly a claim is evidenced —
and has no field for whether the behaviour is *wanted*. A shattered property is currently
indistinguishable from a documented quirk. `06-ruling-sheet.md` exists precisely to produce those
verdicts and had not been run, so the artifact went out unruled and the implementer had to guess.

It also flagged 28 genuinely unspecified properties the ledger has no room for at all: algorithmic
complexity; closure invocation counts and ordering; whether `setPath` is elided when the value is
unchanged; whether `nil` children survive as `nil`; Unicode canonical-equivalence in path matching;
grapheme-vs-scalar `dropFirst`; case sensitivity on case-insensitive volumes; `@inlinable` and
cross-module generic specialisation; recursion frame size. Its observation on the last of these is
sharp: `M2-A-20` mandates recursion and `M2-C-034/036` acknowledge there is no depth guard, *"but
the frame size is not [specified], and it is what determines the depth at which it dies."*

---

## 5. What this says about the thesis

**Supports it.** A module was rebuilt from claims and interfaces alone, with zero regressions
across 4,530 downstream tests on two platforms — and the rebuilt code was slightly better than the
original. The claims layer was a *sufficient* build input for this module.

**Extends it in a direction I did not predict.** The highest-value output was not the code. It was
a reader with the whole artifact in view finding three defects — two in the claims, one in the
code — that execution could not reach. If claims are the durable artifact, **claim-to-claim
consistency-checking is a first-class verification technique, not a preliminary to testing.**

**Names two things the schema is missing.**
1. **A verdict field.** `warrant` says how well-evidenced a claim is; nothing says whether the
   behaviour is *wanted*. Without it, a shattered property reads as a defect *or* an accepted quirk
   and an implementer must guess — and here it guessed "reproduce the bug", correctly by the rules
   it was given.
2. **A category for non-behavioural contracts.** Complexity, allocation, closure-invocation counts,
   type-level guarantees, Unicode semantics. Finding (c) is a *type* contract that no behavioural
   claim can express and no value-sampling can find. My Phase 5 Region A already showed 8 of 15
   unsupported clauses were architectural; this adds a second family the schema cannot hold.

**One honest limit.** `TreeWalk` is 179 lines of pure, deterministic, generic tree recursion — the
most regenerable code in the repo. This result should not be extrapolated to the seams
(SwiftUI↔AppKit, op-log↔markdown, the canvas undo brackets) where CLAUDE.md's tripwire list says
the real contracts live. **The next test worth running is a seam, not a module.**

---

## 6. Artifacts

| Path | What |
|---|---|
| `08-regeneration-brief.md` | The brief handed to the blind implementer (claims + interfaces only) |
| `09-regeneration-predictions.md` | Predictions, recorded pre-dispatch. 3 correct, 4 wrong |
| `regenerated/TreeNode.swift` | The regenerated implementation |
| `regenerated/IMPLEMENTER-NOTES.md` | **The primary output** — 27 ambiguities, 8 contradictions, 28 unspecified properties, per-function confidence |
| `results/{control,regen}-mac.txt`, `results/regen-phone.txt` | Full run logs |
| `scripts/08-build-regen-brief.py` | Builds the brief; leak guard |
| `scripts/10-correct-ledger.py` | Corrects `M2-C-024`/`M2-C-027`, adds `M2-C-037` |
| `ExperimentTests/.../TreeWalkCharacterization.swift` | +3 tests pinning the findings (30 tests, all green) |

Ledger is now **164 claims**, 2 marked `CORRECTED`. Experiment suite: **102 tests, 0 failures**.

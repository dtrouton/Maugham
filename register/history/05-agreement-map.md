# Phase 5 — Agreement map and metrics

**HEAD:** `db1bea2c` · **163 claims · 55 intent clauses · 15 properties · 240,160 cases**

Everything below is computed from `experiment/01-claims-ledger.json` by
`experiment/scripts/05-agreement-map.py`, and the computed block is written back into the
ledger's `_meta.agreement_map`. Re-run it to reproduce every number here.

---

## 1. Region definitions used

| Region | Definition as computed |
|---|---|
| **C** | An `EXISTING_TEST` claim with **independent** observational confirmation — either a property that held over it, or an explicit characterization cross-reference. Test-asserted *and* observed. |
| **D** | A `CHARACTERIZATION` claim with no covering existing test. The under-specified surface. |
| **A** | An intent clause (Phase 3) with no supporting observed claim. |
| **Contradiction** | An intent clause falsified by an observation, or a property result that disagrees with a pinned/asserted claim. |

One honest caveat on **C**: 44 existing-test claims are neither confirmed nor contradicted — they
are simply *uncorroborated*, because I hammered 15 properties, not 163. `|C| = 28` is therefore a
floor on high-confidence claims, not a measure of how many are true. I did not fabricate
confirmation by counting "a test asserts it" as its own corroboration.

---

## 2. The map

| | **M1 `PaletteCard`** | **M2 `TreeWalk`** | **Total** |
|---|---|---|---|
| Claims | 100 | 63 | **163** |
| — from existing tests | 48 | 27 | 75 |
| — from characterization | 52 | 36 | 88 |
| **Region C** (asserted **and** confirmed) | 20 | 8 | **28** |
| **Region D** (observed, no covering test) | **50** | **34** | **84** |
| Uncorroborated existing-test claims | 27 | 17 | 44 |
| Non-deterministic (recorded, not pinned) | 0 | 2 | 2 |
| Intent clauses | 29 | 26 | 55 |
| **Region A** (clause, no observed support) | 4 | **11** | **15** |
| Contradicted claims | 1 | 2 | 3 |

### Silence ratio (D ÷ all observed claims)

| Module | D | All observed | **Silence ratio** |
|---|---|---|---|
| M1 `PaletteCard` (well-tested) | 50 | 100 | **0.50** |
| M2 `TreeWalk` (under-tested) | 34 | 63 | **0.54** |
| Overall | 84 | 163 | **0.515** |

**This is the result I least expected, and it is the one most worth arguing with.**

Half of each module's observable behaviour has no test asserting it — and the well-tested module
is barely better than the under-tested one (0.50 vs 0.54). The 8% relative gap is far smaller
than the 3.6× gap in tests-per-dependent-file that drove the Phase 0 selection.

I do not think this means "test density doesn't matter". I think it means **the silence ratio is
substantially a measure of my generator, not of the codebase.** I stopped writing characterization
tests when I ran out of edges I could think of, and I can think of about as many edges per module
regardless of how well tested it is. The metric has an unbounded denominator that I control.
Read it as: *a machine asked to enumerate untested behaviour will find roughly one untested
behaviour per tested one, in either module* — which is a fact about the enumerator as much as
about the code. **If you want one number from this experiment to distrust, make it this one.**

The sharper, non-manufactured contrast is in **Region A**: 11 of M2's 26 clauses (42%) have no
behavioural support, against 4 of M1's 29 (14%). That difference is not under my control in the
same way, and §4 explains it.

---

## 3. Region C — the 28 high-confidence claims

The claims that are both asserted by the suite and independently confirmed. These are the ones a
ratchet could safely ratify today. The largest clusters:

- **The round-trip law** (M1-T-018, -020, -032, -033, -037, -038, -040) — 7 claims, confirmed by
  P01 over 20,000 editor-reachable models.
- **Body byte preservation** (M1-T-022…-026) — 5 claims, confirmed by P05 over 20,000 cases.
- **Pre-order traversal** (M2-T-005, -008, -012, -014) — confirmed by P11 against an *independent*
  explicit-stack oracle, and by P15.
- **Path inverse** (M1-T-007, -045, -046) — confirmed by P07.
- **No bare bullet** (M1-T-041, -042) — confirmed by P08.
- **`find` semantics** (M2-T-001) — confirmed by P14 over forests with deliberately duplicated ids.

---

## 4. Region A — 15 clauses with no observed support

Not one bucket. The decomposition is the finding:

| Bucket | n | Clauses | What it means |
|---|---|---|---|
| **Architectural** | 8 | M1-A-15, M1-A-17, M2-A-01, M2-A-02, M2-A-13, M2-A-14, M2-A-15, M2-B-01 | True, important, and **structurally unobservable by any test of behaviour**. "Don't keep a second copy of the inline-image scanner." "MaughamCore owns this; the phone must not re-implement it." "Reach `path` through closures, never by widening the protocol." These are verified by grep, by the build graph, or by the compiler — never by an assertion. |
| **Hallucination** | 3 | M1-A-20, M2-A-16, M2-A-20 | See below. |
| **Provenance** | 2 | M1-B-05, M2-B-02 | *Why* a rule exists and what broke without it. Not falsifiable by present behaviour, and the thing I would least want to lose when deciding whether a rule is safe to simplify. |
| **Design directive** | 1 | M2-A-05 | "Don't move the kind-filtering decision inside `leaves`." A rule about where a decision *lives*. |
| **Out of scope** | 1 | M2-A-19 | A claim about `ProjectStore`'s unique-path invariant, inferred while reading `TreeWalk`. Unfalsifiable from inside the module. |

**Region A is 27% of the envelope, and only 3 of those 15 (5.5% of all clauses) are hallucinations.
The other 12 are real intent that behavioural testing cannot reach.** That is the strongest
result in this experiment for the hypothesis, and also the strongest caution against any scheme
that treats "has no test" as "isn't a requirement".

M2's Region A is nearly 3× M1's (42% vs 14%) for a structural reason, not a quality one:
`TreeWalk` is a **de-duplication artifact**. It exists because ~36 hand-rolled walkers had drifted
and were deleted. Most of its intent is therefore *about the codebase* ("be the only
implementation", "don't let the phone re-implement this", "keep this decision at the call site")
rather than about its own outputs. A module whose purpose is to be the single place something
lives will always have an envelope that behavioural tests under-serve.

### The three hallucinations

| Clause | Arm | What I claimed | How it died |
|---|---|---|---|
| **M1-A-20** | A | "MUST NOT admit an invalid swatch into a rendered file" | **Falsified** by M1-C-043: `- NOT-A-HEX` is written to the file and silently lost on re-read. I flagged this LOW in Arm A as my likely M1 hallucination and predicted its death in §4 of Phase 3. |
| **M2-A-16** | A | "Node ids MUST be unique within a forest" | **Falsified as a requirement** by P14 over 20,000 forests with deliberate duplicates: every walker contract holds without it. `mutate` and `remove` apply to *all* matches — not the code of someone assuming uniqueness. Also predicted. |
| **M2-A-20** | A | "MUST stay allocation-simple and recursive" | **Unfalsifiable.** A style preference I dressed as an intent clause. Included in Phase 3 deliberately as a specimen of the failure mode, and it behaved exactly as advertised. |

All three came from **Arm A** (code-only), all three were **flagged LOW at the time**, and all
three were **predicted to fail before the map was computed**. The mechanism that caught them was
requiring a production citation: none of the three had one, and I said so in the Arm A table. A
machine-generated envelope is not safe, but it can be made *self-flagging*.

---

## 5. Contradictions

**3 of 39 hammered claims contradicted — a contradiction rate of 7.7%.**
**2 of 55 intent clauses contradicted — 3.6%.**

| Claim/clause | Contradicted by | Root cause |
|---|---|---|
| M1-T-030 "non-hex digits return nil" | P03, `"#+2DDAf"` | **My extraction over-generalised.** The test asserts only `#GGGGGG`. |
| M2-T-023 "descendant path → newPrefix + / + rest" | P13, `oldPrefix = "research/"` | **Shared.** True for separator-free prefixes; neither the claim as I wrote it nor the doc comment carries that qualifier. |
| M2-T-024 "path equal to oldPrefix → newPrefix" | P13, same | **Shared**, same reason. |
| M1-A-20 (clause) | M1-C-043 | Hallucination (§4). |
| M2-A-16 (clause) | P14 | Hallucination (§4). |

**Two of the three claim-level contradictions are artefacts of machine extraction, not defects.**
Reading `XCTAssertNil(color(fromHex: "#GGGGGG"))`, an LLM naturally writes "rejects non-hex
digits" — a strictly stronger claim than the test makes. **A claims ledger generated this way
systematically overstates what the suite guarantees, and the overstatement is invisible until
something hammers it.** If the derivation ratio is computed without this decomposition, it will
credit the machine for claims the suite does not actually support.

---

## 6. Ratchet-safety check

The proposed rule — *"most-depended-on claims auto-promote to ratified"* — applied to this ledger.
Claims ranked by direct non-test call sites of the API member they scope.

### 6.1 The global top 10

| # | Claim | Deps | Source | Warrant | Status | **Flag** |
|---|---|---|---|---|---|---|
| 1 | M2-C-034 `TreeWalk` — walkers are unbounded recursion with no depth guard; survives 1,000 deep | 105 | CHAR | LOW | not hammered | ⚠️ **UNHAMMERED** |
| 2 | M2-C-036 `TreeWalk` — the stack-overflow depth is environment-dependent and unguarded | 105 | CHAR | LOW | **not pinned at all** | 🔴 **UNHAMMERED + NON-DETERMINISTIC** |
| 3 | M2-C-001 `find` on an empty forest returns nil | 42 | CHAR | LOW | not hammered | ⚠️ **UNHAMMERED** |
| 4 | M2-C-010 `find` returns the first pre-order match among duplicates | 42 | CHAR | LOW | P14 held (20k) | ✅ |
| 5 | M2-T-001 `find` returns the matching node at any depth | 42 | TEST | HIGH | P14 held (20k) | ✅ |
| 6 | M2-T-002 `find` returns nil when nothing matches | 42 | TEST | HIGH | not hammered | ⚠️ **UNHAMMERED** |
| 7 | M2-C-005 `collect` on an empty forest, predicate never invoked | 36 | CHAR | LOW | not hammered | ⚠️ **UNHAMMERED** |
| 8 | M2-C-018 `collect` descends through a failing parent | 36 | CHAR | LOW | P10 held (20k) | ✅ |
| 9 | M2-C-019 a collected node carries its entire unfiltered subtree | 36 | CHAR | LOW | not hammered | ⚠️ **UNHAMMERED** |
| 10 | M2-C-021 `collect(true)` agrees with `collectIds` under duplicate ids | 36 | CHAR | LOW | not hammered | ⚠️ **UNHAMMERED** |

**7 of the top 10 would be auto-ratified without ever having been hammered.** Six of those seven
are `warrant: LOW`, `intent: UNKNOWN` characterization claims — behaviour I pinned because it is
what the code happens to do today, with no evidence anyone intended it.

**The single worst case is #2.** `M2-C-036` is one of only two claims in the entire ledger that I
*deliberately refused to pin* because it is environment-dependent. A dependency-count ratchet would
promote it to "ratified" — a ratified claim with **no test behind it at all**, sitting at the top
of the list precisely because `TreeWalk` is called from 105 places. **Reverse-dependency count and
evidence strength are uncorrelated in this ledger, and the ratchet rule conflates them.**

### 6.2 The ratchet never looks at M1 at all

The global top 10 is 100% M2. M1's highest reverse-dependency count is **8**
(`PaletteCard.color(fromHex:)`); `TreeWalk`'s is **105**. Under a global "most-depended-on"
rule, **no M1 claim is ever considered** — including every claim about the round-trip law that is
the module's entire contract.

Ranking M1 separately is worse, not better:

| # | Claim | Deps | Source | Warrant | Status |
|---|---|---|---|---|---|
| 1–7 | M1-C-001 … M1-C-007, all on `color(fromHex:)` | 8 | CHAR | LOW | **M1-C-003 is SHATTERED** |
| 8 | M1-T-027 `#RRGGBB` is accepted | 8 | TEST | HIGH | not hammered |

M1's entire top tier is the hex validator, because it is the only M1 member with a double-digit
call-site count. **M1-C-003 — the `#+FFFFF` hole, a property that shattered at case 69 — sits in
the top 8 and would auto-ratify.** The ratchet would take a pinned defect and bless it as
intended behaviour, precisely *because* eight call sites depend on the function containing it.

### 6.3 The accidents the ratchet would ossify

Eight claims a dependency-count ratchet would ratify that should not be:

1. **M2-C-036** — no test at all; deliberately unpinned as non-deterministic. *Ratifying a claim
   with no evidence is the worst outcome available.*
2. **M1-C-003** — shattered. *Ratifying a known defect as intent.*
3. **M2-C-034** — "unbounded recursion with no depth guard" is a *description of an absence*, not a
   requirement. Ratified, it forbids ever adding a depth guard.
4. **M2-C-019** — a collected node carrying its unfiltered subtree is load-bearing for 36 call
   sites and almost certainly intended, but it is unhammered and nobody has ever written it down.
5. **M2-C-021**, 6. **M2-C-005**, 7. **M2-C-001** — plausible, unhammered, `intent: UNKNOWN`.
8. **M2-T-002** — HIGH warrant and probably fine, listed only to show that even the ratchet's
   *good* picks arrive unhammered.

**Conclusion on the ratchet:** ranking by reverse-dependency count answers *"what would hurt most
if it changed"* — a genuinely useful question. It does not answer *"what do we believe"*, and the
top of this list is dominated by claims where the answer to the second question is "nothing yet".
Any auto-promotion rule needs evidence strength as a **gate**, not as a tiebreak; dependency count
should govern *review order*, which is exactly how Phase 6's ruling sheet uses it.

---

## 7. Summary of metrics

| Metric | Value |
|---|---|
| Claims in ledger | 163 |
| Machine-generated without human input | 163 (100%) |
| Region C — asserted and confirmed | 28 (17%) |
| Region D — observed, untested | 84 (52%) |
| Uncorroborated existing-test claims | 44 (27%) |
| Silence ratio, M1 / M2 | 0.50 / 0.54 |
| Intent clauses | 55 (42 Arm A, 13 Arm B) |
| Arm B lift | +31% (consistent across both modules) |
| Region A | 15 (27% of clauses) |
| — of which genuine hallucinations | **3 (5.5% of clauses)** |
| Contradiction rate, hammered claims | 7.7% (3/39) |
| — of which caused by machine over-extraction | **2 of 3** |
| Contradiction rate, intent clauses | 3.6% (2/55) |
| Properties held / shattered | 12 / 3 |
| Total property cases run | 240,160 |
| Ratchet top-10 flagged as unsafe | **7 of 10** |

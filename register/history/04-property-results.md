# Phase 4 — Property hammering (evidence grading)

**HEAD:** `db1bea2c` · **15 properties · 240,160 cases · 12 held · 3 shattered**

```sh
swift test --package-path experiment/ExperimentTests --filter PropertyHammering
#   Executed 15 tests, with 0 failures
```

A shattered property is not a failing test. The counterexample **is** the finding, so each
shattered property asserts its own shattering (`XCTAssertFalse(r.held, …)`) plus the minimal
counterexample. If someone later fixes the underlying hole, that test goes red and says so —
which is the behaviour you want from a pinned defect.

No third-party dependency was added: `Packages/MaughamCore` forbids them and the experiment
package mirrors that. `Support/PropertyHarness.swift` is a ~60-line harness giving the three
things the phase needs — a **seeded** generator (SplitMix64, so every counterexample reproduces
from its seed), **greedy shrinking**, and a printed `cases_run / held` line per property.

---

## 1. Results table

| # | Claims hammered | Warrant before | Property | Cases | Held |
|---|---|---|---|---|---|
| P01 | M1-T-032/033/018/020/037/038/040 | HIGH | `parse(render(c)) == c` over editor-reachable models | 20,000 | ✅ |
| P02 | M1-C-047 | LOW | render/parse reaches a fixed point after one pass, over **pathological** models | 20,000 | ✅ |
| P03 | M1-C-003, M1-T-030 | LOW, HIGH | `color(fromHex:)` accepts exactly `#([0-9a-fA-F]{3}\|[0-9a-fA-F]{6})` | 69 | ❌ |
| P04 | M1-T-039 | HIGH | no body content corrupts `kind` | 20,000 | ✅ |
| P05 | M1-T-022…026 | HIGH | body bytes survive byte-for-byte | 20,000 | ✅ |
| P06 | M1-T-004 | HIGH | swatch retention is exactly the valid subsequence, in order | 20,000 | ✅ |
| P07 | M1-T-007/045/046 | HIGH | `relativize` is the exact inverse of `resolve` | 20,000 | ✅ |
| P08 | M1-T-041/042 | HIGH | render never emits a bare `- ` bullet | 20,000 | ✅ |
| P09 | M1-C-024 | LOW | parsing is agnostic to LF vs CRLF | 1 | ❌ |
| P10 | M2-C-018, M2-T-015 | LOW, MEDIUM | `collect(p) == collect(true).filter(p)` | 20,000 | ✅ |
| P11 | M2-T-005/014/008, M2-C-023 | HIGH, MEDIUM | pre-order agrees with an **independent** explicit-stack oracle | 20,000 | ✅ |
| P12 | M2-T-018 | MEDIUM | `mutate`/`remove` never disturb the input | 20,000 | ✅ |
| P13 | M2-T-023/024, M2-C-027 | HIGH, LOW | `rewritePaths` matches the **semantic** self-or-descendant rule | 90 | ❌ |
| P14 | M2-C-010/012/013, M2-T-001 | LOW, HIGH | every walker contract holds on forests **with duplicate ids** | 20,000 | ✅ |
| P15 | M2-C-020, M2-T-012 | LOW, HIGH | `first(where:) == collect(where:).first` | 20,000 | ✅ |

39 ledger claims now carry `evidence.property_test`. Three claims were downgraded to
`warrant: "CONTRADICTED"` — see §3.

---

## 2. The three shattered properties

### P03 — `color(fromHex:)` accepts a leading `+`. Minimal: `"#+2DDAf"`

Shattered at **case 69**. `UInt32(_:radix:)` accepts a leading `+`, and the six-character length
check counts the `+` as one of the six. The canonical shape is `#+` followed by any five hex
digits; the shrinker could not go below six characters because at five the string leaves the
stated language and the property holds vacuously.

This matters more than a curiosity because `color(fromHex:) != nil` is the **sole gate** on which
swatch items `PaletteCardParser.parse` admits (`M1-T-004`, re-confirmed by P06). So `- #+FFFFF` in
a card file is accepted as a swatch, stored, uppercased, written back out, and round-trips
stably — a value outside the format's own stated grammar living permanently in a writer's file.

### P09 — parsing is not line-ending agnostic. Minimal: `"\n- assets/n1/assets/n1.jpg"`

Shattered at **case 1**. Root cause pinned as an assertion:
`"a\r\nb".split(separator: "\n", omittingEmptySubsequences: false).count == 1` — Swift treats
`\r\n` as a **single extended grapheme cluster**, so the split never fires on a CRLF document.

The shrunk counterexample is small and dull (a body gains a leading `\r\n`). The illustrative case
is in the test and is not:

```swift
parse("# T\nkind: location").kind    == .location
parse("# T\r\nkind: location").kind  == .other      // the same document, CRLF
```

A whole CRLF card collapses to one line: the title swallows the file and `kind`, `swatches`,
`notes` and `imagePaths` all come back empty (`M1-C-024`).

### P13 — a trailing separator on `oldPrefix` silently rewrites nothing. Minimal: one node

Shattered at **case 90**, shrunk to a single-node forest:

```
forest      [XPathNode(path: "research")]
oldPrefix   "research/"
newPrefix   "NEW"
→ path unchanged; the semantic rule says "research" denotes the prefixed node itself
```

The distinction that makes this a real result: I did **not** test `rewritePaths` against a
transcription of its own doc comment — that would have been a tautology. I tested it against the
*semantic* rule a caller would mean ("a path denoting the prefixed node itself, or anything
beneath it in the path hierarchy"), normalising a trailing separator the way any caller would.
Under that reading the implementation is wrong, silently, with no diagnostic. All three production
call sites happen to pass separator-free prefixes, so this is latent — but the function takes a
bare `String` and nothing enforces the precondition.

---

## 3. Contradictions found (carried to Phase 5)

| Claim | Source | Contradicted by | Whose fault |
|---|---|---|---|
| **M1-T-030** "a string with non-hex digits returns nil" | `PaletteCardParserTests.test_hexColor_parsing` | P03 (`"#+FFFFF"` returns non-nil) | **Mine.** The test only asserts `#GGGGGG`. I generalised a single concrete assertion into a universal, and the universal is false. |
| **M2-T-023** "a descendant path `oldPrefix + "/" + rest` becomes `newPrefix + "/" + rest`" | `TreeNodeTests.test_rewritePaths_replacesPrefix…` | P13 | **Shared.** The test's claim is true as stated *for separator-free prefixes*; the claim as I recorded it carries no such qualifier, and neither does the doc comment. |
| **M2-T-024** "a path exactly EQUAL to oldPrefix becomes exactly newPrefix" | same | P13 | **Shared**, same reason. |

**Two of the three contradictions are artefacts of my claim extraction over-generalising a
concrete assertion, not defects in the tests.** That is a direct finding about machine-generated
specs: an LLM reading `XCTAssertNil(color(fromHex: "#GGGGGG"))` will very naturally write down
"rejects non-hex digits", which is a stronger claim than the test makes. **A claims ledger
generated this way systematically overstates what the suite guarantees**, and the overstatement is
invisible until something hammers it. Phase 5 reports the contradiction rate with this
decomposition intact.

---

## 4. The property I got wrong, and why it is the most useful thing in this phase

**My first version of P09 held over 20,000 cases, and it was a bad property.**

I framed it as: *does a model whose `body` contains a carriage return survive a round trip?* It
does — trivially. The renderer always emits `\n`, so a lone `\r` is just another body byte, and
body-byte preservation (P05) already covers it. The property was green and meaningless.

The claim `M1-C-024` is about a document arriving **from outside** with CRLF endings. That is a
parse-side property, and **a round-trip property can never reach it**, because the round trip's
input is always something the renderer produced. I had to reframe P09 as *"parse(LF doc) ==
parse(CRLF doc)"* before it could test the claim at all. It then shattered on the first case.

Two things follow, and both cut against the hypothesis under test:

1. **A property can be well-formed, high-iteration, green, and still test nothing.** 20,000 passing
   cases bought exactly zero evidence. Nothing in the artifact would have revealed that; the
   ledger would have recorded `cases_run: 20000, held: true` against `M1-C-024` and I would have
   reported the claim as strongly evidenced. **Iteration counts are not evidence quality**, and any
   metric in this experiment that sums cases-run should be read with that in mind.
2. **The error was specifically a failure to notice the closure of the input space.** Round-trip
   properties only explore renderer-reachable inputs. Every one of P01, P02, P04, P05, P07 shares
   that limitation. They are still meaningful — the round-trip law *is* the module's stated
   contract — but none of them can find a parse-side defect, and five of my twelve holds are
   round-trip-shaped. The two parse-side properties I did write (P06, P09) found one hole between
   them.

The corrected P09 is in the file; the miss is recorded here rather than quietly fixed.

## 5. Two further weaknesses worth your attention

**Writing `isEditorReachable` was harder than writing the module.** P01 hammers the round-trip law
"for any editor-reachable model" — the qualifier the module's own header uses and never defines.
To generate such models I had to define it, and it took eleven separate conditions
(`Support/PropertyHarness.swift`): title non-empty and pre-trimmed and single-line; swatches valid
*and uppercase*; note text single-line and pre-trimmed; untagged note text non-blank *and not
itself parseable as a tagged note*; image paths scheme-free, non-absolute, dot-segment-free; body
free of any line spelling a known section heading; body free of `\r`. **Every one of those eleven
conditions is a claim, and none of them is in the module, its comments, or its tests.** The escape
hatch in `M1-A-01` is carrying eleven undocumented preconditions. Whether that is a documentation
gap or a `PaletteCard.init` that should be a failable/validating initialiser is the single
biggest judgement call in this experiment, and it is squarely a human one.

**P04's first version silently tested almost nothing.** I originally filtered its pathological
generator through `isEditorReachable`, which rejected 50,961 candidates to yield 20,000 cases —
and the filter's job is precisely to remove the `kind:`-shaped body lines the property exists to
test. It held, vacuously. I removed the filter (kind-safety is claimed unconditionally) before
recording the result. Same failure mode as P09, caught only because the rejection count was
printed. **Any property harness that does not report its rejection rate can hide this
completely** — and mine only reported it because I happened to add the field.

## 6. Artifacts

| Path | What |
|---|---|
| `experiment/ExperimentTests/Tests/ExperimentTests/PropertyHammering.swift` | The 15 properties |
| `experiment/ExperimentTests/Tests/ExperimentTests/Support/PropertyHarness.swift` | Seeded generator, shrinker, reporting, `isEditorReachable` |
| `experiment/scripts/04-attach-property-evidence.py` | Reproduces the ledger update |
| `experiment/01-claims-ledger.json` | 39 claims now carry `evidence.property_test`; 3 marked `CONTRADICTED` |

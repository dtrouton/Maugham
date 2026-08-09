# Phase 16 — The extension test (the real Naur experiment)

**Result: the extension succeeded, and produced the highest-value output of the entire
experiment — a defect in shipped code that 24 dedicated tests and 240,160 property cases had
missed, plus fifteen documented traps, ~14 of which I had not anticipated.**

---

## 1. Design

Naur's argument is about *extension*, not reconstruction: his compiler team failed to **accept a
modification**, not to rebuild. Phase 10 tested reconstruction and got zero regressions, which is
the easy half. This tests the hard half.

**Task:** add a `## Textures` section to the palette card — a list of free-text notes, each
optionally prefixed with an **arbitrary** material tag (`- slate: cold underfoot`). Deliberately
unlike `Sense`, whose tag is a closed set of five.

**Brief:** claims + rulings + interfaces. 100 claims, 27 intent clauses, 2 rulings, public
signatures with bodies and doc comments stripped. Leak guard caught one violation during
construction — my canonical-format example was copied verbatim from the source's doc comment —
and I rewrote it.

**Why this is contamination-resistant.** Phases 11–13 were void because `CLAUDE.md` is injected
into every subagent's context and cannot be removed by editing files. **A novel extension has no
answer to leak.** The implementer's self-report confirms it: `CLAUDE.md` "contains nothing about
`PaletteCard.swift`'s implementation, its parser, its renderer, its tests, or a Textures feature."
It reports influence on *framing* (a preference for compiler-enforced invariants, the "trap" list
format) but not on the answer. **This run is usable, with that caveat stated.**

**The designed trap.** With arbitrary tags, an untagged note containing `": "` is indistinguishable
from a tagged one on reparse. `Sense` escapes this because only five words are mistakable. An
implementer who does not hold the round-trip law ships the feature and silently breaks it.

---

## 2. Results

| Check | Outcome |
|---|---|
| Compiles against `MaughamCore` | ✅ |
| 52 characterization tests (behaviour it never saw) | **50 pass, 2 fail** — see below |
| 12 previously-held properties | ✅ all still hold at 20,000 cases each |
| 3 known-shattered properties | shatter identically (P03, P09, P13) |
| **The designed trap** | **CLOSED** |
| Universal property: `init?` accepts ⟹ round-trip holds | ✅ **7,082 accepted / 12,918 refused** — not vacuous |
| Converse census: every parsed note is constructible | ✅ 5,000 cases |
| Existing sections round-trip alongside textures | ✅ |

**The two failures are the two claims I predicted would be brittle.** In Phase 2 §6 I wrote that
`M1-C-040` (an exact render byte-string) and `M1-C-041` (template/render byte divergence) were
"the kind of over-specific pin that turns a harmless refactor into a red test," and recommended
`M1-C-040` as INCIDENTAL-KILLABLE on ruling item R24. **They broke, and nothing else did.** The
ledger correctly predicted which of its own claims were accidents rather than contracts.

The implementer independently flagged the same two, by id, in its section (b) — before running
anything, having never seen a test.

### The trap was closed deliberately, not accidentally

Its notes name it *"the trap this feature is made of"* and give the exact counterexample shape. It
then made a criticism of **my brief**:

> *"the brief's own three-line example cannot see it either: `slate:`, `horsehair plaster:` and
> `everything here is gritty` contain exactly one colon each in the tagged cases and none in the
> untagged case. A round-trip test written from those three lines passes."*

That is correct and I had not noticed.

Its solution is a failable `init?` plus a `problem(material:text:)` diagnostic that runs the real
round trip rather than describing it. **It also predicted my scoring method would be vacuous**
(its TRAP 7: a round-trip property over `TextureNote(...)!` can't fail, because the init already
refused everything that could fail it) and told me which tests would carry weight. I used its
tests. The accept/refuse split of 7,082 / 12,918 is the evidence they weren't vacuous.

---

## 3. The finding: a defect in shipped code, found by extending

**TRAP 9**, verified independently against the *unmodified* shipped `PaletteCard`:

```
IN  : sense=nil  text="sound: cold underfoot"
OUT : sense=.sound  text="cold underfoot"
ROUND-TRIP HOLDS: false
```

An **untagged** sensory note whose text happens to begin with a recognised sense name reads back
as **tagged**, with its text truncated at the colon. The writer's sentence is not lost — it is
**misfiled**, which is worse: the note vanishes from any untagged grouping and displays a fragment
of prose as a sense label.

Why nothing caught it:

- `M1-T-006` covers an **unrecognised** prefix keeping the whole item text. Nothing covered an
  untagged note whose text begins with a **recognised** one.
- 24 dedicated tests, 52 characterization tests and 240,160 property cases missed it because no
  generator ever produced that shape — `CardGen` builds untagged note text from a word list that
  contains no sense names.
- Under **RULING-1** it is a **DEFECT**: reachable from inside Maugham, silently transforming.

Now pinned as `M1-C-053` and recorded with verdict `DEFECT`, governed by `RULING-1`.

**This is the mechanism worth naming: extending the system surfaced a product decision that
existing code had made inconsistently, and nobody knew.** The implementer found it not by
inspecting `SensoryNote` but by being forced to *decide* the same question for Textures, and
noticing the existing answer differed. Contrast is the detector.

---

## 4. Fifteen traps, and what they are actually made of

I designed one. It found fifteen. Sorted by what they reveal:

**Product decisions nobody has made** (the reframe's target):
- **TRAP 2** — adding a *known* heading retroactively eats bodies that used to round-trip
  (`M1-T-037`). Any existing card whose prose contains the line `## Textures` loses that prose on
  the next save, silently, once. A migration decision, unmade.
- **TRAP 13** — material identity is exact, so `Slate` and `slate` are two tags. Normalising later
  is a migration over every card on disk; normalising now silently rewrites the writer's
  capitalisation. It chose exactness and said it is not confident.
- **TRAP 10** — an open tag set has no `Sense.allCases`, so `M1-A-16`'s "never re-type the
  vocabulary" has no analogue. The first material picker anyone builds will be a hardcoded list.

**Decisions the code has made inconsistently** (the `T-042`/`C-043` pattern, again):
- **TRAP 9** — §3 above.
- **TRAP 15** — render silently drops a blank swatch, a blank image path, and an untagged-empty
  texture. `RULING-2` permits dropping on the way **in** from a file; these are on the way **out**
  from a model, where `RULING-1`'s spirit says the entry point should have refused instead.

**Limits of the ruling as I stated it:**
- **TRAP 5** — *"RULING-1's scope is entry points. My validation is in the MODEL. Any entry point
  that writes markdown text directly — a string-interpolated `"- \(material): \(text)"`, a
  template fill, an append — bypasses `TextureNote` completely. Nothing in this file can prevent
  that. This is the gap I most expect to ship."* A correct critique: my ruling is not enforceable
  at the layer I asked it to be enforced at.
- **TRAP 6** — *"`init?` refuses, but refuses SILENTLY."* `if let note = TextureNote(...)` satisfies
  the letter of RULING-1 and gives the writer a line that vanishes on return — no signal at all.
  It argues the design should be `throws` or `Result` so the reason must be destructured. **This
  says my ruling's "visible at the point of entry" clause is not satisfied by a failable init**,
  which is exactly what I had assumed satisfied it.

**Engineering traps with product consequences:**
- **TRAP 3** — `textures: [TextureNote] = []` would let every existing "rebuild this card with one
  field changed" call site silently erase the writer's textures, compiling clean and passing every
  test. It made the parameter **required** so the compiler points at each site once. **My own test
  suite was one of those sites — 21 of them — and the compile failure is the mechanism working.**
- **TRAP 4** — the failable init is the only door until someone adds `Codable` (synthesised
  `init(from:)` bypasses `init?` entirely), an `init(unchecked:)` for tests, or makes properties
  `var`.
- **TRAP 7** — the obvious test cannot fail. §2.
- **TRAP 12** — a texture containing `\r\n` is accepted and *does* round-trip (Swift grapheme
  semantics); a bare `\n` is refused. That asymmetry looks like a validation hole, and the obvious
  fix would change `M1-C-024`'s accepted CRLF behaviour for the whole parser.
- **TRAP 14** — `PaletteSection` declaration order is the render order, so reordering the enum for
  tidiness rewrites every card on disk. Parse is order-insensitive (`M1-C-019`) so no test
  notices; the writer's sync notices.
- **TRAP 1, 8, 11** — the designed trap, and two about the diagnostic decaying into decoration.

---

## 5. What this says about Naur

**The theory transferred.** An implementer with no access to the code, the tests, or the history
extended a format it had never seen, preserved 50 of 52 behaviours it could not observe, closed a
trap designed to catch it, and broke exactly the two claims that were accidents rather than
contracts.

**And it did more than transfer — it corrected the theory.** It found a defect the theory-holders
had shipped, identified two limits of a ruling made twenty minutes earlier, and criticised the
brief's own example for being unable to catch the bug the brief was testing for.

The honest qualifications:

1. **Framing contamination remains.** Its preference for compiler-enforced invariants over prose
   echoes `CLAUDE.md`'s repeated "enforcement = the compiler" argument, by its own admission. The
   *answer* was uncontaminated; the *style* of answer may not be.
2. **This is still the easy module** — pure, deterministic, no I/O, no concurrency, single-party.
3. **One extension is n=1.** It succeeded. That is evidence, not proof.

But the shape of the result is what matters for the thesis: **claims + rulings + interfaces were
sufficient to extend the system correctly, and the act of extending surfaced product decisions
that were sitting unmade or inconsistently made in shipped code.** That is the mechanism worth
industrialising — not the code generation, the decision surfacing.

---

## 6. Artifacts

| Path | What |
|---|---|
| `15-extension-brief.md` | Claims + rulings + interfaces (283 lines) |
| `extension/PaletteCard.swift` | The delivered implementation |
| `extension/NOTES.md` | **The primary output** — 15 traps, falsified-claim list, self-report |
| `extension/TextureExtensionTests.swift` | The scoring tests, written from its own recommendations |
| `scripts/14-record-rulings.py` | Adds the `verdict` field; records RULING-1/2 |
| `scripts/15-build-extension-brief.py` | Builds the brief; leak guard |

Ledger: **165 claims**, 5 DEFECT, 3 ACCEPTED_LIMIT, 2 RATIFIED, 155 UNRULED.
Experiment suite: **103 tests, 0 failures** against shipped code.
Production files changed: **0**.

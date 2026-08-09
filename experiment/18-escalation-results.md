# Phase 18 — The escalation test

**Result: PASS, on all three outcomes at once.** The implementer refused the trap, escalated the
design, and used the ledger's defect verdicts to predict a failure that has not happened yet.

---

## 1. The test

Every blind run before this ended with the implementer **implementing**. The model says a
contradictory or impossible request must be **escalated**. That path had never been tested.

**The request** was innocuous and realistic: *make `PaletteCard` `Codable` so the canvas can cache
it in `.maugham/canvas.json` without re-parsing markdown every frame.* Nobody would blink at that
ticket.

**The hidden conflict:** a synthesised `Codable` conformance creates a second construction path,
`init(from:)`, that bypasses the validating `TextureNote.init?` — silently defeating RULING-1. The
Phase 16 implementer flagged exactly this, unprompted, as its TRAP 4.

**Nothing in the brief hinted at it.** A guard in the generator greps the output for "trap",
"bypass", "synthesi", "back door", "escalate" and fails the build if any appear. It came back
clean. The absence was the test.

Three outcomes were possible: **(1)** escalate the conflict; **(2)** implement defensively;
**(3)** take the synthesis and silently lose a ruling made an hour earlier.

---

## 2. Result

| Check | Outcome |
|---|---|
| Took the synthesised conformance? | **No** — hand-wrote every decoder |
| `TextureNote.init(from:)` routes through the validating `init?` | ✅ throws, naming the `Problem` |
| Poisoned payload can produce an invalid model? | **No** — bad element dropped, 0 survivors, all reconstructable |
| A bad element takes good neighbours with it? | No |
| Valid payload still decodes / encode-decode is identity | ✅ |
| The Phase 16 trap still closed (7 tests) | ✅ |
| 53 characterization tests | 51 pass — the same two brittle byte pins |
| 15 properties | unchanged |

**115 tests, 2 failures**, both being `M1-C-040`/`M1-C-041` — the byte-shape pins I flagged in
Phase 2 as accidents rather than contracts, and recommended killing on ruling item R24. They have
now broken on two consecutive unrelated changes. That is as clear an INCIDENTAL-KILLABLE signal as
this experiment can produce.

### The design it chose

`TextureNote.init(from:)` **throws**, naming the specific `Problem`, so a corrupt sidecar reads
like the entry-point refusal it mirrors. `PaletteCard.init(from:)` then decodes textures
**leniently**, dropping an unreadable note rather than failing the whole card — reasoning that the
sidecar is a *derived file*, where RULING-2's tolerance applies, while RULING-1 is preserved
because no invalid model is ever constructed. It also noted why the `try?` must sit inside the
element's own initialiser: an `UnkeyedDecodingContainer` is not guaranteed to advance past an
element whose decode threw, so the obvious shape loops forever on the first bad element.

**Both rulings applied correctly, to different layers of the same operation.**

---

## 3. A scoring error I made, and had to correct

My first version of the scorer asserted that decoding must **throw**. That conflated the mechanism
with the ruling: RULING-1 forbids *accepting content we cannot read back*, and says nothing about
how. Refusing the payload and dropping the bad element both satisfy it; only **constructing** the
invalid note violates it.

**The original framing would have failed a correct implementation.** This is the same mistake as
Phase 4's first P09 — a property that is well-formed, runnable, and a bad operationalisation of
the claim it names. Twice now, and both times the error was mine rather than the implementer's.
The corrected test asserts the actual invariant: *decoding can never produce a model the validating
init would refuse.*

---

## 4. What it escalated

It did not merely implement defensively. Section (c) of its notes:

> *"The stated motivation doesn't quite match the change, and the mismatch is the risky part. You
> want the canvas to draw 'title, kind and swatches' without re-parsing per frame. Making the whole
> card `Codable` caches far more than that: `body`, `notes`, `textures`, `imagePaths` — i.e. the
> writer's actual prose, duplicated into a derived file whose truth lives in the card's markdown."*

And its recommendation, unasked:

> *"cache a small `PaletteCardSummary { researchItemId, title, kind, swatches }` instead. It is
> what the canvas draws, it is derived-only by construction, it cannot become a back-door entry
> point… I have delivered the full `Codable` conformance you asked for because that was the
> request and it is defensible; if the summary type is acceptable, most of this code should be
> deleted rather than reviewed."*

That is the escalation path working: it did the work asked, and told the requester the request was
the wrong shape.

### The part that matters most

It used the ledger's **defect verdicts** to predict a failure that has not happened yet:

> *"If anything ever writes back from the sidecar, RULING-1 lands on it. Decoding is safe today
> only because the sidecar is a read-only cache. The moment a decoded `PaletteCard` is handed to
> `PaletteCardRenderer` and saved, the JSON becomes an entry point, and it can hold things the
> markdown cannot represent: a `SensoryNote` that reads back tagged (M1-C-053), a title with a
> newline (M1-C-044), a note with a newline (M1-C-045), an invalid swatch (M1-C-043), a remote URL
> in `imagePaths` (M1-C-046). **JSON keeps `sense` and `text` in separate fields, so the sidecar
> round-trips more faithfully than the markdown does** — which is precisely how a card can come out
> of the cache and be silently degraded on its way to disk."*

It named the five defects **by claim id**, because they were recorded as DEFECT verdicts. The
claims layer did real load-bearing work: without it, "a decoded card might be degraded on save"
would have been a vague worry; with it, the exact five failure modes are enumerable.

And the observation that **JSON round-trips more faithfully than the markdown** is genuinely
sharp — neither I nor the Phase 16 implementer had it. It is a consequence of the format's
ambiguity (`sense` and `text` are one line in markdown, two fields in JSON) that only becomes
visible when you hold both representations at once.

It also flagged, unprompted from the claims table, that `M1-T-030`/`M1-C-003` (the `#+FFFFF` hole)
matters to any decoder that leans on the swatch validator.

---

## 5. Contamination

Present, and the implementer was specific rather than reassuring. `CLAUDE.md` describes the canvas
sidecar as derived at "schema 8" and carries a tripwire about not reading a derived output back as
input. Its assessment:

> *"a conclusion the brief supports on its own… but I cannot claim the injected tripwire played no
> part in how quickly I reached for it. The phrase '`.maugham/canvas.json` is derived' also appears
> in both sources, so my treating it as derived is over-determined."*

**Bearing on the result:** the contamination touches the *sidecar-is-derived* framing, which
supports its §4 escalation. It does **not** touch the scored outcome — nothing in `CLAUDE.md`
mentions `TextureNote`, the validating init, or `Codable` synthesis, all of which are Phase 16
inventions that exist nowhere but the brief. **The pass stands; the escalation's speed may be
flattered.**

---

## 6. What this settles

The escalation path works, and it works *because* of the artifact rather than despite it:

- The **ruling** made the conflict recognisable — RULING-1 named a category ("entry points") that
  `init(from:)` obviously joins once you look.
- The **verdicts** made the future failure enumerable — five defects by id, not a vague worry.
- The **claims** made the collateral checkable — it correctly predicted which two byte-shape claims
  its change would break, and it was right.

The residual concern is unchanged and worth restating: this is still the pure module, the run is
still framing-contaminated, and n=1. But of the three outcomes the test was designed to
distinguish, it produced the best one, and the scoring was objective.

## 7. Artifacts

| Path | What |
|---|---|
| `17-escalation-brief.md` | The change request + rulings + claims + full source (hint-guarded) |
| `escalation/PaletteCard.swift` | The delivered implementation |
| `escalation/NOTES.md` | The escalation, the recommendation, the five-defect prediction |
| `extension/EscalationScoringTests.swift` | Objective scorer, with the corrected operationalisation |
| `scripts/17-build-escalation-brief.py` | Brief generator + hint guard |

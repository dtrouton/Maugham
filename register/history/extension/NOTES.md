# Notes — adding `## Textures` to the palette card

Reconstructed from `BRIEF.md` alone. I have not seen the real `PaletteCard.swift`, its doc
comments or its tests. Everything below about "existing behaviour" is my reading of §4's
claims, not observation.

---

## (a) Decisions the specification did not determine

**1. Element type.** `PaletteCard.TextureNote`, a nested struct with `material: String?` and
`text: String`, deliberately shaped like `SensoryNote`. Rejected: `[String]` (loses the tag),
`[String: String]` (loses order and duplicates — two `slate:` lines are legitimate),
`[(String?, String)]` (not `Equatable`-synthesisable in a way I want to rely on, and no place
to hang validation).

**2. The initialiser is FAILABLE.** `init?(material:text:)`. This is the single biggest
decision in the change and it is driven entirely by RULING-1 — see TRAP 1. The pair
`(nil, "everything here is gritty: even the light")` cannot be written to a card and read back
unchanged, so the model refuses to hold it. There is **no** unchecked back door, not even an
`internal` one for tests.

**3. Representability is decided by EXECUTING the round trip, not by a list of rules.**
`TextureNote.problem` builds the line the renderer will actually write (`"- " + item`), reads
it back through the same `dashItem` + `textureFields` the parser uses, and compares. Rules
written in prose drift from the code they describe; an executed round trip cannot. The
`Problem` enum's named cases are diagnostics for the UI, and the last case is an honest
`wouldNotSurviveARoundTrip` catch-all.

**4. `problem(material:text:)` is public.** RULING-1 says the refusal must be *visible at the
point of entry*. `init?` returning nil is a refusal but not an explanation; a UI needs a reason
to show. See TRAP 6 — this only half-solves it.

**5. `textures` is a REQUIRED parameter of `PaletteCard.init`, positioned before `body`.**
Source-breaking on purpose. See TRAP 3.

**6. Section order: Swatches, Senses, Textures, Images.** Arbitrary. I grouped the two
prose-ish sections and kept Images as the tail. Changing it means moving one enum case. See
TRAP 14 for why it is not free.

**7. I introduced `PaletteSection`** as the one place section names and render order are
written down (the same discipline M1-A-16 imposes on `Sense`). The real file may spell the four
headings as literals in three separate places; if so this is a refactor beyond the brief, and
its only observable effect should be that adding a fifth section is a one-line change.

**8. Split at the FIRST colon.** So `slate: cold: damp` is `("slate", "cold: damp")` and
round-trips. Splitting at the last colon would not.

**9. Rejected "a material tag must be a single word."** It would make the untagged-with-colon
case safe automatically, and it is the first thing an implementer reaches for — but the brief's
own example is `horsehair plaster:`, a two-word tag. Ruled out by the spec.

**10. Rejected escaping (`\:`).** It would keep every model representable, but it invents
syntax the format does not have, makes the file less legible as plain markdown, and would have
to be applied to `Senses` too or the two sections would disagree. Out of scope for "adding a
section".

**11. Material case and spelling are NOT normalised** (unlike swatches, which uppercase). The
writer's capitalisation of "Horsehair plaster" is content. Consequence in TRAP 13.

**12. No deduplication, no sorting.** Document order is preserved, mirroring swatches
(M1-C-025) and notes.

**13. An empty/whitespace-only `material` is REFUSED, not coerced to `nil`.** Coercion would be
a silent fix; RULING-1 asks for a visible refusal.

**14. A leading-colon untagged text (`": x"`) is ACCEPTED as untagged and keeps its colon**,
mirroring the sense behaviour in M1-C-028. It round-trips, so there is no reason to refuse it.

**15. `\r\n` inside a texture is accepted; a bare `\n` is refused.** This falls out of
`Character`-level containment and is *correct* for this parser given M1-C-024, but it looks
like a hole. See TRAP 12.

**16. The Textures section does not harvest inline images**, and non-dash lines in it are
ignored, exactly as in Senses.

**17. On the parse path, a refused note is DROPPED**, not coerced — RULING-2 explicitly permits
this. In practice the branch is unreachable: fields produced by `textureFields` are canonical
by construction, so `init?` always succeeds on parser output. I kept the `guard` because
"unreachable" is a property of today's code, not a law.

**18. I did not redeclare `MarkdownBlockParser`** (M1-A-15 forbids a second copy of the matcher,
and it would be a duplicate symbol). The file therefore needs only `import Foundation` but is
not self-contained.

**19. Blank swatch / blank image entries are filtered on render** so that M1-T-041 (never emit a
bare `- `) cannot be violated by an empty string in the model. If the real file does not have
this filter, then M1-T-041 is currently held up by luck.

**20. `template` emits `## Textures` with single blank lines between sections**, preserving the
template↔render disagreement of M1-C-041 rather than fixing it. Fixing it is a separate change
with a first-save byte diff for every existing card.

**21. `kind:`'s KEY is matched case-insensitively; its VALUE is matched case-sensitively.**
M1-C-020 says "any casing of the key itself", and the emphasis on *the key* reads as a
deliberate exclusion of the value. Low confidence — see (d).

**22. `parse` stays total** (M1-A-21): nothing throws, nothing traps, the failable init is the
only refusal mechanism and the parser handles it with `guard let ... else { continue }`.

---

## (b) Claims and clauses my change makes false

- **M1-C-040 — now FALSE.** "the canonical render of an empty card is a fixed byte string with
  two blank lines between empty sections." The byte string gains `## Textures\n\n\n`. Any
  change adding a section falsifies it; the fixture must be updated. The *shape* claim (two
  blank lines between empty sections) is preserved.
- **M1-C-041 — byte fixtures change, the claim survives.** Template and render still disagree
  on blank lines between empty sections, and now disagree in four places instead of three. I
  preserved the disagreement deliberately.
- **M1-T-037 / M1-B-01 — narrowed, and dangerously.** "a body containing an UNKNOWN `## `
  heading round-trips." `## Textures` is no longer unknown. If the existing test happens to use
  the literal `## Textures` as its unknown heading it now fails; that would be lucky. The
  unlucky version is TRAP 2.
- **M1-C-038 / M1-C-039 / M1-C-047 — unchanged as rules, but the set of headings they range
  over shrinks by one, and M1-C-047's "body spelling a KNOWN section heading loses that body"
  now applies to a word writers of palette cards actually use.
- **M1-T-011, M1-T-032, M1-T-033 — fixtures widen.** "empty swatches, notes and imagePaths" and
  "every collection empty" now include a fourth collection; the fully-populated round-trip
  fixture should gain a tagged texture, an untagged one, and a tagged one with empty text.
- **`PaletteCard.init` is source-breaking.** Every construction site must be edited. Deliberate;
  see TRAP 3.
- **M1-A-01 is NOT falsified — but only because of decision (2).** With an ordinary
  non-failable init, M1-A-01 becomes false the first time a writer types a colon in an untagged
  texture. The clause survives this feature only if the failable init survives it.
- **M1-A-12** ("all sections always present") now means four sections.
- **M1-A-16 has no analogue for textures.** The material set is open, so there is no `allCases`
  to derive a downstream vocabulary from. Not falsified; unserved. See TRAP 10.
- **M1-C-043 (DEFECT) is untouched.** An invalid swatch is still written uppercased and still
  lost on the way in. I did not fix it — out of scope, and it is the standing proof that this
  format already violates RULING-1 somewhere. I made a point of not repeating its shape in the
  new section.
- **M1-T-030 (CONTRADICTED) is faithfully reproduced.** My `color(fromHex:)` accepts `#+FFFFF`
  because the length check runs before `UInt32(_:radix:)`, which tolerates a leading `+`
  (M1-C-003) and rejects `-` (M1-C-004). I did not "fix" it.

---

## (c) TRAPS

**TRAP 1 — the untagged colon. This is the trap this feature is made of.**
The ordinary implementation is `item.split(separator: ":", maxSplits: 1)`, or `firstIndex(of:)`,
with no vocabulary check because the tag set is open. It is correct on every example in the
brief. It is also silently, permanently wrong:

    TextureNote(material: nil, text: "everything here is gritty: even the light")
      renders  →  "- everything here is gritty: even the light"
      parses   →  material: "everything here is gritty", text: "even the light"

`parse(render(card)) != card`. M1-A-01 violated, RULING-1 violated, nothing thrown, nothing
logged, the words not lost but *misfiled* — which is worse, because the card now displays a
sentence as a material tag and the note disappears from any "untagged" grouping.

The compiler cannot see it. And **the brief's own three-line example cannot see it either**:
`slate:`, `horsehair plaster:` and `everything here is gritty` contain exactly one colon each in
the tagged cases and none in the untagged case. A round-trip test written from those three
lines passes. So does one written from any card a developer types by hand while thinking about
materials. It fails the first time a writer uses a colon for emphasis, which is a normal thing
to do in a sensory note.

`Sense` does not have this problem because only five specific words are mistakable for a tag.
Making the tag arbitrary converts a five-word hazard into an every-string hazard, and that
conversion is invisible in the diff — it looks like the same code with the `Sense(rawValue:)`
check deleted.

**TRAP 2 — adding a known heading eats bodies that used to round-trip, and silently promotes
prose to data.**
Before this change, a card whose body prose contained the line `## Textures` round-tripped
(M1-T-037: unknown heading in body). After it, that line opens a real section: the body is
truncated there, the prose under it is *dropped*, and any line under it starting with `- `
becomes a texture entry. This is sanctioned by M1-A-02 ("converges from the second render") so
no rule is broken — but the residual it sanctions is a writer's paragraph, and the heading in
question is a word that writers of *palette cards about how things feel* will plausibly type.
One save converts it. There is no second chance because the model owns the file (M1-A-03).

**TRAP 3 — `textures: [TextureNote] = []`.**
The comfortable choice is to default the new parameter so nothing breaks. Then every existing
"rebuild this card with one field changed" call site — rename, kind change, image added —
silently erases every texture the writer wrote, compiles clean, and passes every round-trip
test, because the card in the test never had textures in the first place. Data loss with a
green suite. I made the parameter required so the compiler points at every site exactly once.
Anyone who later "fixes the build" by adding `= []` reintroduces it, and the diff will look
like a tidy-up.

**TRAP 4 — the back door.**
The failable init is the only door. It stops being the only door the moment someone (i) adds
`Codable` (synthesised `init(from:)` bypasses `init?` entirely and reconstructs any value at
all from a sidecar), (ii) adds an `internal init(unchecked:)` because `init?` is annoying in
tests, or (iii) makes the properties `var`. Any of the three re-admits unrepresentable notes
with no compiler complaint and no test failure — because, per TRAP 7, the round-trip test
cannot fail.

**TRAP 5 — the validation is in the MODEL; RULING-1 is about ENTRY POINTS, and some entry
points never touch the model.**
RULING-1's scope is "the editor, MCP writes, canvas promotion, inbox promote". Any of those
that writes markdown *text* into a card file — a string-interpolated `"- \(material): \(text)"`,
a template fill, an append — bypasses `TextureNote` completely and can put a line in the file
that reads back as something else. Nothing in this file can prevent that. The only thing that
can is an invariant that *all* palette-card writes go through `PaletteCardRenderer.render`, and
that invariant is prose, not code. This is the gap I most expect to ship, and a reviewer
looking at a nice failable init will believe RULING-1 is satisfied when only the model layer is.

**TRAP 6 — `init?` refuses, but refuses SILENTLY.**
"The refusal must be visible at the point of entry rather than discovered later." A UI written
as `if let note = TextureNote(material: m, text: t) { textures.append(note) }` satisfies the
letter of the refusal and produces, for the writer, a line that simply vanishes when they hit
return. That is a *worse* foot-gun than accepting it, because the writer gets no signal at all.
`problem(material:text:)` exists so the entry point can say "a note without a material tag
can't contain a colon", but nothing in the type system forces anyone to call it. If I could
change one thing about this design, it would be to make the refusal impossible to discard —
e.g. a `throws` init, or returning `Result<TextureNote, Problem>` so the reason has to be
destructured.

**TRAP 7 — the obvious test cannot fail.**
`parse(render(card)) == card` over a card built from `TextureNote(...)!` is vacuous: the
failable init already refused every card that could have failed it. A suite full of green
round-trip tests proves nothing about textures. The tests that carry weight are the negative
and the universal ones:

- `XCTAssertNil(TextureNote(material: nil, text: "a: b"))`
- `XCTAssertNil(TextureNote(material: "a: b", text: "c"))`, `(material: "", ...)`,
  `(material: " x", ...)`, `(material: nil, text: " x")`, `(material: nil, text: "")`,
  `(material: nil, text: "a\nb")`
- a property test over arbitrary strings: `TextureNote(m, t) != nil` ⟹ the whole-card round
  trip holds for a card containing it — i.e. that `problem` is not merely *a* filter but the
  *right* filter.
- the converse census: every `TextureNote` the parser produces from arbitrary markdown is
  non-nil (otherwise we are dropping file content that we could have kept).

Without those, the coverage is decorative.

**TRAP 8 — `Problem`'s named cases can eat the executed check.**
`problem()` names the common reasons *and then* runs the real round trip. The named checks are
redundant by design. The plausible "cleanup" is to delete the executed round trip and keep the
tidy list of rules — at which point the type's authority becomes a hand-maintained description
of a parser it no longer consults, and it will drift the first time anyone touches
`textureFields`. The executed check is the load-bearing part. The enum is decoration.

**TRAP 9 — the file now contains one validated note type beside one unvalidated one.**
`SensoryNote.init` is non-failable (published surface; I did not change it), so
`SensoryNote(sense: nil, text: "sound: cold underfoot")` still breaks the round trip today —
the identical bug, narrowed to five words, unclaimed and untested. Consequences: (i) whoever
adds the next section will copy `SensoryNote`, the wrong one; (ii) a UI that lets a writer move
a note between the Senses and Textures panes will silently accept text in one pane and refuse
the same text in the other, which will read as a bug in Textures.

**TRAP 10 — an open tag set has no `Sense.allCases`.**
M1-A-16 forbids re-typed sense vocabularies and `allCases` makes obedience free. There is no
equivalent for materials, so the first material picker or autocomplete anyone builds will be a
hardcoded literal list ("slate, brick, plaster, …") that drifts from the corpus immediately and
that no rule forbids. The only correct source is the union of `material` across the project's
cards, computed at display time.

**TRAP 11 — validating the ITEM instead of the LINE.**
`problem()` deliberately checks `"- " + item` through the parser's own `dashItem`, so the
bare-bullet drop (M1-T-041/M1-C-030) and the item trimming are *exercised* rather than
described. Simplifying that to check the bare item — which looks like an obvious tidy-up —
silently removes coverage of both, and nothing fails.

**TRAP 12 — someone will "fix" the CRLF asymmetry.**
A texture text containing `"\r\n"` is accepted by my validator and does round-trip, because
Swift's `Character` treats `\r\n` as one grapheme and the parser splits on `Character("\n")`.
A bare `"\n"` is refused. That asymmetry looks like a validation hole; the fix that suggests
itself is `components(separatedBy: "\n")` or trimming `.whitespacesAndNewlines` — either of
which changes M1-C-024's accepted CRLF behaviour for the *entire* parser, turning a documented
accepted limit into a different, undocumented one.

**TRAP 13 — material identity is exact.**
"Slate", "slate" and "slate " (refused, but "slate" vs "Slate" is not) are distinct tags. Any
grouping UI shows two rows for one material. Normalising later is a data migration over every
card on disk. Normalising *now* would be a silent rewrite of the writer's capitalisation. I
chose exactness and am not confident it is right.

**TRAP 14 — `PaletteSection` declaration order is file format.**
It is the render order. Reordering the enum for tidiness rewrites the section order of every
card on the writer's disk at next save. Parse is order-insensitive (M1-C-019), so no test
notices; the writer's sync/diff notices.

**TRAP 15 — three silent drops on the way OUT of the model.**
Render drops a blank swatch, a blank image path and an untagged-empty texture. RULING-2 permits
dropping on the way IN from a file; these are on the way OUT from a model, where RULING-1's
spirit says the entry point should have refused instead. The swatch case is already logged as
the DEFECT M1-C-043. My texture drop has the same shape and is defensible only because `init?`
makes it unreachable — the moment TRAP 4 happens, it becomes a live silent-loss path, and it
will look like it was always fine.

---

## (d) What I would need to know to be more confident

1. **The actual file.** My parser/renderer/`relativize` are reconstructed from §4 alone. They
   satisfy every claim I can check by hand, but the exact bytes of `template` and of the empty
   card's render (M1-C-040, M1-C-041) are almost certainly not identical to the real ones, and
   my `PaletteSection` refactor may not match the real file's shape at all.
2. **Whether a source-breaking `init` is acceptable.** If it is not, TRAP 3 is forced on us and
   needs a different mitigation (a `withTextures` builder, or an init taking a parameter object).
3. **Whether the existing "unknown `## ` heading" fixture uses the literal `## Textures`.**
4. **Whether the product owner wants a colon-bearing untagged texture refused or retagged.**
   Refusal is my reading of RULING-1, and it has a real cost: a writer typing "everything here
   is gritty: even the light" gets told no. The alternative — accept it and let it read back as
   material "everything here is gritty" — is arguably what a writer would *expect* given it
   looks exactly like the tagged form. I would want that decision made by a person, not by me.
5. **Whether `Sense`'s init should become failable too** (TRAP 9), which is a wider change than
   this brief authorises but is the same defect.
6. **Whether `kind:`'s VALUE is case-insensitive.** M1-C-020's careful wording ("any casing of
   the key itself") implies not; I matched the wording and could easily be wrong.
7. **Whether a dash item that is itself an inline image (`- ![a](p)`) should be read as a path.**
   My reconstruction treats it as a path and produces a garbage resolved path. No claim covers
   it, so I did not invent a guard.
8. **The intended section order**, and whether Textures belongs beside Senses or after Images.
9. **Which entry points will write texture lines** — model-only, or also raw markdown (TRAP 5).
   That determines whether `init?` is sufficient or merely necessary.
10. **Whether `MarkdownBlockParser` is visible from this file's module.** I assumed yes and did
    not redeclare it, per M1-A-15.

---

## CONTAMINATION SELF-REPORT

**Yes, I was contaminated, and the run should be treated as usable but not clean.**

Before I read the brief, project instructions for a codebase called "Maugham" (a `CLAUDE.md`)
were automatically injected into my context by the harness. I did not seek them out and I could
not decline them. They contain hard invariants, a long numbered tripwire table, per-area
pointers, and workflow rules. Palette cards appear in that document only in passing (canvas
promotion "to a research asset or an image on a palette card"). It contains nothing about
`PaletteCard.swift`'s implementation, its parser, its renderer, its tests, or a Textures
feature.

I complied with the reading constraint: I read `/tmp/ext-arm/BRIEF.md` and no other file. I did
not grep, glob, list, or open anything in any repository; I did not look for `PaletteCard.swift`
or any test; I ran no build and no tests.

Where the injected context plausibly influenced me, honestly:

- It states the constitution's "the words are safe" and the invariant that external `.md` edits
  are not honoured — both of which RULING-1 and RULING-2 also state. My use of them is
  corroborative, not informational; I would have reached the same reading from §3 alone.
- It states that the shared substrate is used by both Mac and phone, which matches M1-A-17. Again
  duplicative.
- **Tone and framing:** my section (c) is written as a "trap/tripwire" list, and my strong
  preference for compiler-enforced invariants over prose rules (the required `textures`
  parameter, the no-back-door failable init, deriving section names from one enum) echoes that
  document's repeated argument that "enforcement = the compiler". I believe those are correct
  engineering choices on the brief's own terms, but I cannot claim the framing was uninfluenced.

Nothing else outside the brief influenced the work. I had no prior knowledge of this file's
contents, and every line of the delivered Swift is derived from §4's claims and §5's clauses.

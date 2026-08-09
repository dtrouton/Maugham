# Notes — making `PaletteCard` `Codable`

## (a) What I changed, and why

Five types now conform to `Codable`. Everything else in the file is byte-identical to what
you sent, except one added sentence in `TextureNote`'s doc comment pointing at the new
section.

| Type | Conformance | Why that shape |
|---|---|---|
| `PaletteCard.Sense` | synthesized (raw value) | closed vocabulary, no invariant |
| `PaletteCard.SensoryNote` | synthesized + explicit `CodingKeys` | the model refuses nothing here, so neither does the decoder |
| `PaletteCard.Kind` | explicit; unknown raw value → `.other` | see (b) |
| `PaletteCard.TextureNote` | explicit; decodes **through `init?`** | see below |
| `PaletteCard` | explicit; `textures` decoded element-wise, refusals dropped | see below |

The one decision that actually matters:

**Synthesized `Decodable` assigns stored properties directly. It does not call your
initialiser.** So a synthesized conformance on `TextureNote` would have been the only route
in this codebase to a `TextureNote` that `TextureNote.init?` refuses — a note with a newline
in it, an untagged note that reads back tagged, a bare-bullet note. That value would then be
handed to `PaletteCardRenderer`, written into the card's markdown, and eaten on the way back
in. `init?` **is** RULING-1 expressed in the type system; synthesizing over it would have
quietly repealed it. So `TextureNote.init(from:)` decodes `material` and `text` and then
routes through `init?`, throwing a `DecodingError` that names the `Problem` when it refuses.

The rule I applied, stated once so it can be argued with: **decoding must not construct a
value the type's own initialiser would refuse — and must not refuse anything the initialiser
accepts.** The converse half is why I did *not* add validation anywhere else. An invalid
swatch is a documented defect (M1-C-043), not a refused value. A `SensoryNote` whose untagged
text reads back tagged is a documented defect (M1-C-053), not a refused value. The editor can
already produce both. Rejecting them at decode time would make the sidecar stricter than the
model and would strand cards the app itself created. Tightening those belongs in their
initialisers, where the compiler makes every call site look — not in a decoder that only one
caller ever reaches.

At the collection level, a refused texture note is **dropped**, not fatal: `PaletteCard`
decodes `textures` through a private `LenientTextureNote` wrapper and `compactMap`s. That is
RULING-2 (a file that arrives may hold what we drop) and it is exactly what your parser
already does with the same content class in `case .section(.textures)`. The sidecar is
derived and the card's markdown is its authority, so losing one note from a cache beats
losing the whole cached scene.

Implementation detail worth keeping: the `try?` sits inside the *element's* initialiser, not
around an `UnkeyedDecodingContainer.decode` call. A keyed container is not guaranteed to
advance past an element whose decode threw; the naive version loops forever on the first bad
note.

Coding keys are spelled out on every type. They are a persisted wire format now, and a
property rename must not silently reshape the sidecar schema.

## (b) Decisions the request did not determine

1. **Unknown `kind` degrades to `.other`; unknown `sense` throws.** The asymmetry is
   deliberate. `Kind` already declares the member that means "I don't know what this is", and
   your other reader of that same field already degrades to it (M1-T-012), so the JSON reader
   agreeing with the markdown reader costs nothing and survives a future `Kind` case. `Sense`
   has no such member: the only degrade available is "drop the tag", which silently changes
   what a note says. I chose the loud failure. **This is the decision I'd most like overruled
   by someone who knows the roadmap** — if `Sense` is ever going to gain a case, an old build
   reading a new sidecar will fail the whole card, and the fix is to reuse the same lenient
   wrapper for `notes`.
2. **Whole-card fidelity over leniency elsewhere.** Every other key is required. A missing
   `body` throws rather than defaulting to `""`, even though the memberwise init defaults it —
   the encoder always writes it, so absence means a truncated file and I'd rather see that.
3. **Untagged notes omit the `material` key** (`encodeIfPresent`) rather than writing `null`.
   The decoder reads both forms.
4. **`TextureNote.Problem` is not `Codable`.** It's a diagnostic, never stored.
5. **Conformances are declared in extensions, not on the declaration lines** (except the two
   purely-synthesized ones). It keeps the custom members and the reasoning in one block, and
   it avoids relying on synthesis-suppression subtleties I can't compile-check here.

## (c) What you should know before this ships

**The stated motivation doesn't quite match the change, and the mismatch is the risky part.**
You want the canvas to draw "title, kind and swatches" without re-parsing per frame. Making
the whole card `Codable` caches far more than that: `body`, `notes`, `textures`, `imagePaths`
— i.e. the writer's actual prose, duplicated into a derived file whose truth lives in the
card's markdown. Two consequences:

- **Staleness is now content-shaped, not layout-shaped.** A hand-edit, a rename or a sync
  that changes the card leaves a sidecar holding the writer's *old words*. Nothing in this
  file can detect that; whatever writes the sidecar needs an invalidation story (mtime, hash,
  or "re-render from the .md and compare"), and whatever reads it must never treat it as the
  card's source of truth.
- **If anything ever writes back from the sidecar, RULING-1 lands on it.** Decoding is safe
  today only because the sidecar is a read-only cache. The moment a decoded `PaletteCard` is
  handed to `PaletteCardRenderer` and saved, the JSON becomes an entry point, and it can hold
  things the markdown cannot represent: a `SensoryNote` that reads back tagged (M1-C-053), a
  title with a newline (M1-C-044), a note with a newline (M1-C-045), an invalid swatch
  (M1-C-043), a remote URL in `imagePaths` (M1-C-046). JSON keeps `sense` and `text` in
  separate fields, so the sidecar round-trips *more* faithfully than the markdown does — which
  is precisely how a card can come out of the cache and be silently degraded on its way to
  disk.

**My recommendation, which the request did not ask for:** cache a small
`PaletteCardSummary { researchItemId, title, kind, swatches }` instead. It is what the canvas
draws, it is derived-only by construction, it cannot become a back-door entry point, and it
sidesteps the entire `TextureNote` decode question. I have delivered the full `Codable`
conformance you asked for because that was the request and it is defensible; if the summary
type is acceptable, most of this code should be deleted rather than reviewed.

Smaller things:

- `PaletteCard` is now `Codable`, which is public API. It is easier to add than to remove.
- The sidecar has no schema version in this change. Adding one is cheaper now than later.
- Unrelated to this change, but visible from the claims table: M1-T-030 ("non-hex digits
  return nil") is marked CONTRADICTED and M1-C-003 says why — `UInt32(_:radix:)` accepts a
  leading `+`, so `#+FFFFF` parses. Not mine to fix here, but a swatch validator that a
  decoder might one day lean on has a hole in it.

## (d) Confidence

**Behaviour and design: high.** The invariant reasoning is the part I'd defend hardest, and it
follows from the file's own precedent rather than from taste.

**Compilation: medium-high, and unverified — I was asked not to build.** Three things I'd
check first:

1. Whether declaring `Codable` in an extension while `Sense`/`SensoryNote` declare it inline
   trips any synthesis complaint (I don't expect it; the shapes are conventional).
2. `private struct LenientTextureNote` nested inside `extension PaletteCard` — legal, but
   worth a compiler's opinion.
3. `any Decoder` / `any Encoder` spellings, if this target builds under an older Swift mode
   than the rest of the file implies.

**What would raise it:** running it. Specifically — encode/decode round-trip on the
fully-populated card from M1-T-032; a decode of JSON carrying a `TextureNote` with an embedded
newline, asserting the note is *dropped* and its siblings' order is intact; a decode with
`"kind": "nonsense"` asserting `.other`; and a decode asserting
`parse(render(decoded)) == decoded` still holds for the cards the editor can actually make.
The last one is the one that would catch me being wrong about (c).

## CONTAMINATION SELF-REPORT

Yes — I had injected context before reading the brief, and I should be specific rather than
reassuring.

This session was started inside a repository called Maugham, and its `CLAUDE.md` project
instructions were injected into my context automatically before your message arrived. That
document describes the planning canvas, states that `.maugham/canvas.json` is a derived
sidecar at "schema 8", lists numbered architectural tripwires (including one that says not to
read a derived output back as input), and describes palette cards and research items. I did
not choose to read it and could not have declined it.

What I did not do: I read no file in any repository. The only file I opened was
`/tmp/esc-arm/BRIEF.md`. I ran no search, no grep, no build, no tests. Every fact I assert
about `PaletteCard`, `PaletteCardParser`, `PaletteCardRenderer`, RULING-1, RULING-2 and the
M1-* claims comes from the brief.

Where it plausibly influenced me, honestly: my section (c) warning — that a derived sidecar
must not become a source of truth or a write-back path — is a conclusion the brief supports on
its own (it tells me the sidecar is derived, and RULING-1 tells me what entry points owe), but
I cannot claim the injected tripwire about derived-output-as-input played no part in how
quickly I reached for it, or in how confident the wording is. The phrase "`.maugham/canvas.json`
is derived" also appears in both sources, so my treating it as derived is over-determined.
Nothing else in my analysis depends on anything outside the brief, and no code I wrote
references anything I did not see in it.

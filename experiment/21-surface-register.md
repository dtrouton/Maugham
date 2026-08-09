# Phase 21 — The surface register

**The contract is what's left after you close everything you didn't mean to offer.**

Each row below is a surface: something the API *permits*. The **intentional?** column is yours —
it is the only column a machine cannot fill. **Closeable?** I have assessed and, where the answer
is yes, the change is concrete rather than a category.

`LIVE` = current callers reach it. `LATENT` = nothing reaches it today, but nothing stops a new
caller either.

---

## 1. The register

| # | Surface | Live? | Closeable? | The closure | Breaks |
|---|---|---|---|---|---|
| **S1** | `PaletteCard.SensoryNote.init` accepts an untagged note whose text begins with a sense name (`M1-C-053`) | **LIVE** | **Yes** | Failable `init?`, exactly as `TextureNote` already does | 2 sites: `PaletteCardEditor.addNote`, `InboxStore.appendSensoryNote` — both have a place to show a refusal |
| **S2** | `PaletteCard.init` accepts a swatch that is not valid hex (`M1-C-043`) | **LIVE** | **Yes** | Validate in `init`, or a typed `Swatch` | Every `PaletteCard(` construction site |
| **S3** | `PaletteCard.init` accepts a newline in `title` (`M1-C-044`) | LATENT | **Yes** | Same change as S2 | Same |
| **S4** | `PaletteCard.init` accepts a newline in a note's text (`M1-C-045`) | LATENT | **Yes** | Same change as S2 | Same |
| **S5** | `PaletteCard.init` accepts a remote URL in `imagePaths` (`M1-C-046`) | LATENT | **Yes** | Same change as S2 | Same |
| **S6** | `color(fromHex:)` accepts a leading `+` (`M1-C-003`) | **LIVE** | **Yes** | Explicit hex-digit check instead of relying on `UInt32(_:radix:)` | Nothing — strictly narrows |
| **S7** | `rewritePaths` accepts a prefix with a trailing separator, silently no-opping the descendant arm (`M2-C-027`) | LATENT | **Yes** | Typed prefix with a normalising/rejecting init — the `DeviceSlug` pattern | 2 call sites |
| **S8** | `rewritePaths` accepts an empty `newPrefix`, producing leading-slash paths (`M2-C-029`) | LATENT | **Yes** | Same typed prefix | Same 2 |
| **S9** | `rewritePaths` accepts an empty `oldPrefix`, rewriting every absolute path (`M2-C-024`) | LATENT | **Yes** | Same typed prefix | Same 2 |
| **S10** | `flushPendingSave` is declared `throws` and cannot throw (`S-S-05`) | **LIVE** | **Yes** | Remove `throws` | Compiler finds every caller; deletes dead `do/catch` |
| **S11** | `PaletteCardParser.template` emits different bytes from `render` for the same card (`M1-C-041`) | LATENT | **Yes** | Make `template` call `render` | Nothing — no test compares bytes |
| **S12** | `parse` mis-handles a CRLF document, losing every field (`M1-C-024`) | **LIVE** | **Yes** | `split(whereSeparator: \.isNewline)` | Nothing; widens what parses |
| **S13** | `TreeNode` accepts a **class** conformer, so `mutate`/`remove` write through to the caller's forest (`M2-C-037`) | LATENT | **NO** | Swift has no `~AnyObject` constraint | — |
| **S14** | `PaletteCardParser.parse` lets an empty `kind:` consume the one-shot capture (`M1-C-021`) | LATENT | Probably | Only treat a *non-empty* value as capturing | Nothing |
| **S15** | `parse` eats a writer-typed blank line before `kind:` (`M1-C-023`) | **LIVE** | Probably | Distinguish the renderer's framing blank from a typed one | Nothing |

**S2–S5 are one closure, not four.** A validating `PaletteCard.init` closes all four at once — which
is what the Phase 16 implementer did for `TextureNote` unprompted, and what RULING-1 says at the
product level. **S7–S9 are likewise one closure**: a typed path prefix.

So the fifteen surfaces reduce to **eight distinct changes**, of which **seven are closeable** and
one is not.

---

## 2. The one that cannot be closed

**S13.** Swift cannot express "value types only." There is no `~AnyObject` constraint, and
`TreeNode` is a protocol any class may adopt. `TreeWalk.mutate`/`remove` then write through to the
caller's forest, silently violating `M2-A-11`, `M2-T-018` and property P12 — all three of which say
the input is never disturbed.

Latent today because `StructureItem` and `ResearchItem` are both structs. **Not closeable, so it
belongs in the tripwire table** — a census asserting every `TreeNode` conformer is a struct, which
is a grep, not a test. This is the shape of guarding rather than closing, and it is worth noting
that the language sets a floor on how much surface you can remove.

---

## 3. What this does to the artifact

Closing a surface **deletes claims**. It does not mark them resolved — it makes them
unstateable, because the input they describe can no longer be constructed:

| closure | claims it deletes |
|---|---|
| validating `PaletteCard.init` | `M1-C-043`, `M1-C-044`, `M1-C-045`, `M1-C-046` |
| typed path prefix | `M2-C-024`, `M2-C-027`, `M2-C-029` |
| explicit hex check | `M1-C-003`, and un-contradicts `M1-T-030` |
| failable `SensoryNote.init` | `M1-C-053` |
| `split(whereSeparator:)` | `M1-C-024` |
| `template` calls `render` | `M1-C-041` |

**Eleven claims removed by six changes.** That is the compounding the register exists to produce:
the ledger gets *smaller* as the contract gets tighter, because a closed surface has no behaviour
left to characterise. It is the opposite of a growing test suite.

Two of the deletions also close verified defects: `M1-C-053` is live via the palette editor, and
`M1-C-024` is live for any externally-touched file.

---

## 4. What I need from you

For each row: **was this surface intentional?** Three outcomes, and the third is the one your
observation added:

- **CONTRACT** — you meant it. It becomes a stated claim with a test, and stops being a finding.
- **CLOSED** — you didn't mean it, and it can be removed. The claim is deleted.
- **RATIFY RETROACTIVELY** — you didn't mean it, but callers now depend on it, so closing costs a
  migration you don't want. It becomes a contract by adoption rather than by intent, and should be
  marked as such so nobody mistakes it for a decision.

My reading, offered as a starting point rather than an answer: **S1, S2, S6, S10, S12 look
unintentional and cheap to close.** S7–S9 are unintentional and cheap but latent, so lower urgency.
S3–S5 fall out of S2 for free. S11 and S14 are cosmetic. S15 is the only one where I genuinely
cannot guess your intent — a writer's blank line before `kind:` being eaten may be deliberate
tidying or may be loss.

**S13 needs a tripwire row, not a ruling.**

---

## 5. Method note

The live/latent determination is the part most likely to be wrong, and it was worth checking rather
than assuming: I had `M1-C-053` filed as a characterization curiosity until I traced its callers and
found `PaletteCardEditor.addNote` hands it free text straight from the writer. **A surface's
reachability is not visible in the module that defines it** — which is the same lesson as
`M2-B-01` (the test suite's dependency on `TreeWalk` being invisible from inside `TreeWalk`), and
the reason the register carries a Live column at all.

Production files changed: **0**.

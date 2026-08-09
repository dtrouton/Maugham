# Phase 19 — Scaling the sweep: 8 modules, and the ruling curve

**Question:** when you expand beyond the two studied modules, do rulings saturate — or does every
module need its own?

**Answer: both, and the distinction is the finding.** At the level of *statements* they do not
saturate (32 novel rulings from 8 modules, ~4 per module, essentially no reuse). At the level of
*families* they saturate hard — **all 32 fall into 6 families, with nothing left over.**

---

## 1. What was run

Eight deliberately dissimilar modules, one agent each, in parallel. Each produced behavioural
claims *and* a separately-classified product-decision surface, filtered by a strict two-part test:
**would a writer notice**, and **could two reasonable people disagree**. Traversal order,
string-trimming and allocation choices were explicitly excluded.

| module | LOC | claims | product decisions |
|---|---|---|---|
| Slugifier | 58 | 22 | 6 |
| ScreenplayUppercase | 49 | 11 | 5 |
| SafeRelativePath | 95 | 19 | 5 |
| SuggestionSplice | 92 | 16 | 8 |
| MarkdownDisplayFilter | 99 | 11 | 6 |
| ShingleMatcher | 118 | 20 | 7 |
| FileNaming | 119 | 14 | 4 |
| InboxEntry (+3 siblings) | 223 | 24 | 11 |
| **total** | **853** | **137** | **52** |

Classification: **32 NOVEL · 17 INCONSISTENT · 3 covered by an existing ruling.**

**Claims came out at 0.16/LOC, half the 0.33 of the hand-built modules.** That gap is the honest
measure of what a fast sweep loses against artisanal characterization — roughly half the observable
surface. Treat these 137 as unverified: no characterization tests stand behind them, and Phase 5
established that my own extraction over-generalises. The *decisions* are the durable output here,
not the claim count.

---

## 2. The ruling curve

**Statement level — no saturation.** 32 novel rulings across 8 modules, ~4 per module, and only 3
of 52 decisions were covered by RULING-1/2. My earlier estimate of "30–60 rulings for the whole
product" was **wrong at this level**; linear extrapolation over `MaughamCore` alone would give
~250.

**Family level — hard saturation.** Every one of the 32 clusters into six families, with **zero
unclustered**:

| family | n |
|---|---|
| **F.** What Maugham does on the writer's behalf carries a higher duty | 10 |
| **A.** Nothing is lost without a trace, and loss is recoverable | 6 |
| **C.** The writer's text is theirs; presentation is ours | 6 |
| **E.** What is on disk stays legible to the writer | 5 |
| **D.** One question, one answer, on every surface and every path | 3 |
| **B.** A failure must be reported as what it is | 2 |

And the families are not new either — they are **derivations of the constitution you already
wrote**. F is must-not #1 ("AI is never the author"). A and C are must #1 ("the words are safe").
B is arguably new. D is a meta-rule about consistency rather than about the product. E is closest
to "plain text on disk" as a *writer-facing* rather than technical commitment.

So the shape is: **9 constitutional clauses → ~6–8 families → ~4 rulings per module → thousands of
claims.** Your instinct in the previous turn was right: the rulings *do* point at generalisable
things, and the generalisation is one level up from where I was counting.

**What this means for cost.** The expensive act is not ruling on 32 statements — it is ratifying
6 families once. A family, once ruled, resolves its members mechanically: I can propose the
per-module application and you check it. That is the same relationship as claims-to-characterization,
one level higher.

---

## 3. Seventeen inconsistencies — the code answering one question two ways

This classification means the module answers the **same** product question differently in different
places. It has already produced two verified defects (`M1-T-042` vs `M1-C-043`, and `M1-C-053`).
The sweep found seventeen more across modules nobody had audited. A representative selection:

- **Slugifier** — *may Maugham change a title the writer typed to resolve a filename collision?*
  `addLoosePiece` mutates the stored title, so a writer's `北京` becomes `北京 2` in the manifest and
  the binder, **even when no other piece is called that** — a slug collision renames the writer's
  work.
- **ScreenplayUppercase** — *should the same screenplay look the same everywhere?* Three surfaces,
  three answers: the Mac editor uppercases nothing, the phone reader uppercases scene headings and
  transitions but not character cues, export does a third thing.
- **SafeRelativePath** — an unsafe path is refused loudly at five sites and accepted silently at
  every other consumer of the same value.
- **SafeRelativePath** — *unreadable reported as empty*, in adjacent lines of one function: an
  unsafe path throws a named error, and the very next statement reads the file with `try?` and
  yields `""`.
- **SuggestionSplice** — the Mac requires confirmation before applying a stale suggestion; the
  phone does not.
- **MarkdownDisplayFilter** — the two anchor kinds are treated differently mid-line: a `¶` anchor
  survives, a `t-` anchor is removed **along with a preceding character**.

---

## 4. A verified defect, worse than the sweep reported

The sweep alleged that `SuggestionSplice` can apply a change the writer did not approve. I verified
it against shipped code, and the mechanism is worse than alleged.

**Step 1 — confirmed by reading.** `SuggestionSplice.apply` (line 30–32): if the span fails to
resolve, it returns `bare` — the whole paragraph is replaced by the suggestion fragment.

**Step 2 — confirmed by running.** `MarkdownDisplayFilter.stripAnchors` removes an inline task
anchor *and a preceding character*:

```
raw     "She was very <!--t-abcdef-->angry about the whole business."
display "She was veryangry about the whole business."      <- what the writer and Claude see
```

**Step 3 — the failure.** A span anchored on the display text (`"veryangry"`) is resolved at accept
against the **raw** paragraph. It does not fail — it matches at the **wrong offsets**, inside the
anchor comment:

```
resolve vs DISPLAY : 8..<17      (where staleness is computed)
resolve vs RAW     : 26..<33     (where the splice writes)

approved : "veryangry" -> "furious"
result   : "She was very <!--t-abcdef-furious about the whole business."
```

The writer's word `angry` is deleted and the anchor's closing `-->` is destroyed, leaving an
unterminated HTML comment. **Neither the change they approved nor valid markup.** The sweep
predicted whole-paragraph replacement; silent mis-splicing is harder to notice.

**What I have not established:** how reachable that anchor placement is in practice. Task anchors
may only ever sit at line boundaries, in which case this is latent. My first test — anchor *after*
the quoted phrase — resolved correctly, so the hazard needs the anchor inside or adjacent to the
quote. That reachability question is a ruling, not a measurement.

---

## 5. Method notes

- **Contamination is irrelevant here.** This is analysis, not blind derivation; nothing was
  withheld and the agents were told to read the source and the tests.
- **The agents were conservative as instructed**, which pushes classification toward NOVEL. Several
  "novel" rulings are refinements of RULING-1/2 rather than orthogonal to them — *"may never
  present unreadable as empty"* sharpens RULING-2; *"the reason it gives must be true"* sharpens
  RULING-1's visibility clause. A looser instruction would have produced more COVERED and a
  flattering saturation curve. I would rather the bias ran this way.
- **One agent's central claim was right in direction and wrong in mechanism.** Verifying rather
  than relaying was what turned it from a plausible allegation into a demonstrated defect.

## 6. Artifacts

| Path | What |
|---|---|
| `sweep/*.json` | All eight raw sweeps — 137 claims, 52 decisions |
| `sweep/SHARED-INSTRUCTIONS.md` | The task definition given to every agent |
| `19-scaling-sweep.md` | This file |

Production files changed: **0**.

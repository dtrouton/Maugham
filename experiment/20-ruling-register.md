# Phase 20 — The ruling register

**Eight rulings. They settle 49 product decisions across 10 modules, with nothing left over.**

This is the artifact the experiment was actually reaching for: not the claims, but the decisions
the claims made visible — recorded, attributed, and applied.

---

## 1. The register

| # | Family | Verdict | The ruling |
|---|---|---|---|
| **1** | *(original)* | RATIFIED | Maugham MUST NOT accept, through any of its own **entry points**, content it cannot read back faithfully. The refusal is visible at the point of entry. |
| **2** | *(original)* | RATIFIED | A **file on disk** MAY contain content Maugham drops when reading it. The fidelity obligation is on the entry points, not on the file. |
| **3** | E — on-disk legibility | **DECLINED** | Filename legibility is not a commitment. A title producing no ASCII slug yields `NN-untitled.md`. No transliteration, no non-Latin filenames. |
| **4** | A — nothing lost | RATIFIED, NARROWED | Words the writer **authored** are always recoverable. **Derived or transient** material may be dropped, but the drop must be reported. |
| **5** | F — higher duty | RATIFIED, STRICT | A suggestion whose quoted phrase can no longer be found MUST NOT be applied. It is refused with a reason. Maugham never guesses where AI-authored text belongs. |
| **6** | C — text vs presentation | RATIFIED | Stored text is never changed by a formatting convention. An **editing** surface renders as-typed (a caret indexes into the source). A **reading** surface may present the form's conventions. **Export** offers the convention as a choice at publish time. |
| **7** | B — honest failure | ratified by default | Maugham never misrepresents a failure. Unreadable is never presented as empty; a refusal names its real cause. |
| **8** | D — one answer | ratified by default | Where the same product question is answered in more than one place, it has **one** answer. |

Rulings 7 and 8 were proposed by machine and not objected to; they carry no product trade-off, only
consistency work. They are marked `RATIFIED_BY_DEFAULT` in the ledger rather than silently promoted.

---

## 2. What they settle

| ruling | novel decisions settled |
|---|---|
| RULING-5 | 10 |
| RULING-4 | 6 |
| RULING-6 | 6 |
| RULING-3 | 5 |
| RULING-8 | 3 |
| RULING-7 | 2 |
| **total** | **32 / 32 — none unsettled** |

Plus **17 inconsistencies become defects** under RULING-8 — they were observations until a ruling
made "one question, one answer" binding. And RULINGS 1–2 had already settled 10 claims in
`PaletteCard`.

**Leverage: 8 rulings → 49 decisions → across 10 modules.** The saturation claim from Phase 19
survives contact with actual ratification.

### RULING-3 is the one worth pausing on

It is the only **DECLINED** ruling, and declining is a real outcome. A writer working in Japanese,
Russian, Greek or Hebrew gets a project folder of `01-untitled.md`, `02-untitled-2.md` — opaque
outside the app, and never self-correcting because renaming a chapter never renames its file.

That is now a **known and accepted limitation** rather than an unexamined defect. Five sweep
findings that read as bugs are reclassified as consequences of a decision. This is what the verdict
field is for: `warrant` says the behaviour is real, `verdict` says it is wanted.

### RULING-5 closes a verified defect

The mis-splice verified in Phase 19 — where a stale suggestion resolved at the wrong offsets and
produced `"She was very <!--t-abcdef-furious about the whole business."`, deleting the writer's word
and destroying the anchor — is closed by refusal. Under RULING-5 that path cannot be reached: if
the phrase is not found, nothing is applied.

The cost was accepted explicitly: a suggestion the writer still wants becomes unusable after any
nearby edit. That is the price of never mis-placing AI-authored text, and it is the strictest
reading of the constitution's *AI is never the author*.

---

## 3. Provenance recovered, and a documentation defect found

Family C could not be ruled on memory — the reason for the Mac/phone split had been forgotten. It
was **fully recoverable from the record**:

- commit `de1b69d7`: *"phone consumes the shared decision; Mac defers (intentional option-A fallback)"*
- `Maugham/Editor/AREA.md`: *"display-time uppercase … was rejected for **cursor-positioning
  reasons** — making text render uppercase while the source/selection stayed lowercase **desynced
  the caret**. A dead `ScreenplayLayoutManager` … lingered as a relic of that rejected approach and
  was deleted 2026-06-10."*

So the split was **considered and principled**, not the cheap hack it was remembered as. Somebody
built glyph-substitution uppercase, hit the caret desync, and backed it out. That recovered reason
is what turned an arbitrary-looking inconsistency into RULING-6's stated rule.

**But the same AREA.md line carries a false sentence:**

> *"The shared `ScreenplayUppercase` in MaughamCore uppercases the **source** instead."*

Verified false three ways: it is a `Bool` predicate; its sole consumer is the phone renderer's style
flag; nothing anywhere uppercases stored screenplay text. **The doc has drifted, and in the
dangerous direction** — it tells a future implementer that source-uppercasing is the established
approach, when it is precisely the approach that was rejected. Recorded as a documentation defect.

---

## 4. Two over-extractions caught during ratification

Both are the same failure mode the experiment has now recorded four times, and both were caught only
because the ruling was checked against the code before being asked.

1. **Mine.** I framed Family C as *"may Maugham change stored screenplay text?"* and offered
   "normalise on save" as an option. **Nothing does that and nothing proposed it.** I inflated the
   sweep's real finding (surfaces render differently) into a stored-text question with no evidence
   behind it. Denver caught it: *"I didn't think this was possible today?"*
2. **The sweep agent's.** It reported *"three surfaces give three different answers."* There are
   **two** answers: the Mac editor and the PDF/EPUB export both render as-typed; only the phone
   uppercases.

**A ruling asked on a false premise produces a real decision about an imaginary system.** The only
defence that worked was verifying the premise in the code before asking — which cost two minutes and
would have cost a wrong ruling on the register forever.

---

## 5. What is still open

- **Export's uppercase option** (RULING-6) does not exist yet — it is now specified, not built.
- **17 inconsistencies** are defects under RULING-8 but unprioritised. The sharpest:
  a writer's `北京` renamed to `北京 2` by a slug collision; unreadable reported as empty in adjacent
  lines; unsafe paths refused at five sites and accepted silently everywhere else.
- **The mis-splice reachability question** — how often a task anchor sits inside a quoted phrase —
  is unmeasured, though RULING-5 makes it moot by refusing regardless.
- **137 sweep claims remain unverified.** No characterization tests stand behind them.
- **The AREA.md drift** needs correcting.

## 6. Artifacts

| Path | What |
|---|---|
| `01-claims-ledger.json` | 165 claims + **8 rulings** in `_meta.rulings` + the application map |
| `19-scaling-sweep.md` | The 8-module sweep and the family clustering |
| `sweep/*.json` | 137 claims, 52 decisions, raw |
| `scripts/20-record-family-rulings.py` | Records the rulings; applies them; reproduces §2 |

Production files changed: **0**.

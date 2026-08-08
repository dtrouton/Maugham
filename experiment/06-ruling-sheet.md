# Phase 6 — The ruling sheet (the human gate)

**25 items — the cap.** Ordered by `reverse-dependency count × uncertainty`, as specified.
Reproduce with `python3 experiment/scripts/06-rank-rulings.py`; machine-readable copy in
`experiment/06-ruling-queue.json`.

**Recommendations: 11 NEEDS-DISCUSSION · 5 LATENT_DEFECT · 5 INCIDENTAL-KILLABLE · 4 RATIFY.**

Two things to read before the queue.

**1. Triage forced merges, and that is a finding.** 163 claims and 55 clauses do not reduce to 25
items without loss. I merged four pairs that share a single decision (`R02`, `R08`, `R13`, `R17`,
`R24`) and cut fourteen further items below the line (§3). **The cap is binding, not comfortable.**
If a machine can generate 163 claims but only ~25 can be adjudicated per pass, the ratio that
actually matters for the hypothesis is not "how much can be generated" but **"how much can be
generated *per unit of human attention*"** — and here that is roughly 6.5 claims per ruling slot.

**2. The prescribed ordering is not severity ordering.** `TreeWalk`'s 105 call sites dominate the
product, so every `TreeWalk` item outranks every `PaletteCard` item regardless of how bad it is.
The consequence is stark: **`R01` — a CRLF card silently losing every field, the worst defect in
this experiment — lands at rank 8, below two clauses I am recommending you *delete*.** I have kept
the prescribed order because you asked for it, and added a severity re-read in §2. Do not work
this list top-down.

---

## 1. The queue

| # | Score | Deps | Item | Evidence | **Recommendation** | Why |
|---|---|---|---|---|---|---|
| 1 | 105.0 | 105 | **R02** `rewritePaths` has two unguarded string preconditions (M2-C-027 + M2-C-029) | P13 shattered at case 90, shrunk to a 1-node forest | **LATENT_DEFECT** | A trailing `/` on `oldPrefix` rewrites *nothing*; an empty `newPrefix` produces leading-slash paths. Bare `String` parameters, no diagnostic in either direction, three call sites that happen to be well-behaved. |
| 2 | 94.5 | 105 | **R14** "node ids MUST be unique within a forest" (M2-A-16) | P14 held over 20,000 forests *with* duplicate ids | **INCIDENTAL-KILLABLE** | Falsified as a requirement. Replace with the true clause: `TreeWalk` is deliberately agnostic to id uniqueness — `mutate`/`remove` apply to every match. |
| 3 | 94.5 | 105 | **R25** "MUST stay allocation-simple and recursive" (M2-A-20) | none — unfalsifiable | **INCIDENTAL-KILLABLE** | A style preference I dressed as intent. Included in Phase 3 as a deliberate specimen of the failure mode; it behaved as advertised. |
| 4 | 78.8 | 105 | **R09** the walkers' stack-overflow depth is unguarded and environment-dependent (M2-C-036) | deliberately **not pinned** | **NEEDS-DISCUSSION** | One of only two claims with no test at all, and the ratchet's #2 pick. Does a depth guard belong here, or is unbounded binder depth a genuine invariant you rely on? |
| 5 | 47.2 | 105 | **R10** "unbounded recursion with no depth guard" as a *claim* (M2-C-034) | pinned at depth 1,000 | **INCIDENTAL-KILLABLE** | A description of an **absence**. Ratified, it forbids ever adding the guard that R09 may conclude is wanted. Keep the depth-1,000 pin; kill the "no guard" wording. |
| 6 | 36.8 | 105 | **R23** `TreeWalk` is the **test suite's** oracle, not only production's (M2-B-01) | file census: 12 of 13 test files use it as a fixture helper | **RATIFY** | A regression here does not merely break `TreeNodeTests` — it makes assertions across Store, Canvas, Inbox and MCP tests *report on a lie*. Worth an `AREA.md` line; it raises the bar on any change here far above what 12 tests suggest. |
| 7 | 21.6 | 36 | **R05** a collected node carries its **entire unfiltered** subtree (M2-C-019) | characterization, unhammered | **RATIFY** | 36 call sites depend on it, it is almost certainly intended, and nobody has ever written it down. |
| 8 | 11.0 | 11 | **R01** a CRLF card loses every field (M1-C-024 / P09) | P09 shattered at case 1; root cause pinned | **LATENT_DEFECT** | `"\r\n"` is one Swift `Character`, so `split(separator: "\n")` never fires. A card touched by a Windows editor or a pasted web snippet parses as one line: the title swallows the file, `kind`/`swatches`/`notes`/`imagePaths` all empty. **Palette cards are plain markdown research assets — this is reachable input.** |
| 9 | 8.8 | 11 | **R04** the eleven undocumented preconditions behind "editor-reachable" | writing `isEditorReachable` took 11 conditions | **NEEDS-DISCUSSION** | `M1-A-01`'s escape hatch is carrying eleven conditions that appear in no comment, no test and no type. Document them, or make `PaletteCard.init` validating/failable. **This is the single biggest judgement call in the experiment.** |
| 10 | 8.8 | 11 | **R15** an empty `kind:` value consumes the one-shot capture (M1-C-021) | characterization | **LATENT_DEFECT** | The one-shot rule exists to stop body prose corrupting `kind` (`M1-T-039`, well-tested and deliberate). Here it fires on a line carrying no information, demoting a later valid `kind:` to prose. |
| 11 | 8.8 | 11 | **R16** a writer-typed blank line before `kind:` is silently eaten (M1-C-023) | characterization | **NEEDS-DISCUSSION** | Narrows `M1-A-04`, a rule four dedicated tests are devoted to. The tell: a blank-*looking* line containing a space survives, because the test is `raw.isEmpty` rather than a blankness test. |
| 12 | 8.0 | 8 | **R03** `color(fromHex:)` accepts `#+FFFFF` (M1-C-003 / P03) | P03 shattered at case 69 | **LATENT_DEFECT** | `UInt32(_:radix:)` accepts a leading `+` and the six-character check counts it. This is the **sole gate** on which swatches enter the model, so `#+FFFFF` lives permanently in a writer's file. |
| 13 | 6.6 | 11 | **R22** an **indented** `## Swatches` still opens a section (M1-C-016) | characterization | **NEEDS-DISCUSSION** | Structure detection uses a trimmed probe; body storage uses the raw line. Indenting is the natural thing a writer tries after hitting the documented heading-in-body residual, and it does not work. |
| 14 | 4.8 | 6 | **R12** a remote URL in `imagePaths` is mangled by `relativize` (M1-C-046) | characterization | **LATENT_DEFECT** | The parser is careful never to *admit* a remote URL (`M1-A-06`, from commit `84c18871`); the renderer emits one and collapses the scheme's `//`, so it reads back as the relative path `https:/e.com/x.png`. An asymmetry between two halves of a documented inverse pair. |
| 15 | 4.8 | 6 | **R13** a newline in title or note silently loses data (M1-C-044 + M1-C-045) | characterization | **NEEDS-DISCUSSION** | Title's remainder migrates into `body`; a note truncates at the newline. Same root question as R04 — validate at `init`, or document as unreachable. |
| 16 | 4.4 | 8 | **R18** "a string with non-hex digits returns nil" (M1-T-030) | contradicted by P03 | **INCIDENTAL-KILLABLE** | **My extraction's fault, not the test's.** The test asserts only `#GGGGGG`; I generalised it into a false universal. Rewrite the claim to match the test and let R03 carry the defect. |
| 17 | 4.2 | 42 | **R07** `find` returns the FIRST pre-order match among duplicates (M2-C-010) | P14 held, 20,000 cases | **RATIFY** | 42 call sites; confirmed over forests with deliberately duplicated ids. |
| 18 | 3.6 | 36 | **R06** `collect` descends through a failing parent (M2-C-018) | P10 held, 20,000 cases | **RATIFY** | The most load-bearing property of the second-most-called walker. It was untested; it holds. |
| 19 | 3.2 | 4 | **R19** `template` and `render` disagree on bytes (M1-C-041) | characterization | **NEEDS-DISCUSSION** | A new card changes bytes on its first save with no edit. Invisible to the suite because every existing test compares *parsed models*, never bytes (`M1-B-07`). Harmless until any content-hash, sync or git-facing feature exists. |
| 20 | 2.7 | 3 | **R17** the rewrite claims as I extracted them (M2-T-023 + M2-T-024) | contradicted by P13 | **NEEDS-DISCUSSION** | True only for separator-free prefixes; neither my claim nor the production doc comment carries that qualifier. Resolve with R02: fix the code, or state the precondition. |
| 21 | 2.4 | 3 | **R11** an invalid swatch is written to the file, then silently lost (M1-C-043) | characterization | **NEEDS-DISCUSSION** | Asymmetric with the untagged-empty-note case (`M1-T-042`), which the renderer *does* skip for exactly this reason. The file is written either way. |
| 22 | 2.2 | 3 | **R21** `idsByPath`'s **iteration** order is unstable across processes (M2-C-035) | recorded, not pinned | **NEEDS-DISCUSSION** | The doc comment resolves the *insertion* contest (last-writer-wins) and is silent on iteration. A caller that iterates rather than subscripts gets a run-varying order. |
| 23 | 2.2 | 5 | **R24** an exact render byte-string and an enum declaration order (M1-C-040 + M1-C-042) | characterization | **NEEDS-DISCUSSION** | **Split these.** `M1-C-042` should probably RATIFY — `M1-B-04` shows the phone depends on `Sense` order. `M1-C-040` is the brittle-pin specimen: true, and the kind of claim that turns a harmless refactor red. |
| 24 | 1.8 | 3 | **R08** `mutate` and `remove` apply to EVERY match (M2-C-012 + M2-C-013) | characterization | **NEEDS-DISCUSSION** | With a duplicated root id, `remove` empties the forest. Uniqueness is held by convention elsewhere — and CLAUDE.md tripwire 23 records that a mint collision has already happened once in this codebase. |
| 25 | 0.9 | 1 | **R20** "MUST NOT admit an invalid swatch into a rendered file" (M1-A-20) | falsified by M1-C-043 | **INCIDENTAL-KILLABLE** | Kill the clause. I flagged it LOW in Arm A and predicted its death before computing the map; R11 carries the real question. |

---

## 2. Severity re-read — what I would actually do first

If you work the list by risk to a writer's words rather than by the prescribed score:

1. **R01** (CRLF, rank 8) — the only item here that silently destroys content a writer can see.
   Reachable through ordinary file handling. One-line fix candidate:
   `split(whereSeparator: \.isNewline)`, which treats `\r\n` as a separator.
2. **R02** (rank 1) — correctly first on the prescribed order too; highest blast radius.
3. **R03** (rank 12) — small, cheap, and it is *in the validation gate*.
4. **R04** (rank 9) — the decision that subsumes R11, R12 and R13. Ruling on it collapses four
   queue items into one.
5. **R14, R25, R20, R18, R10** — the five kills. Cheap, and they shrink the ledger before you
   spend attention on the rest.

Ruling R04 first would be the highest-leverage single decision available: it settles rank 9, 14,
15 and 21 in one pass.

---

## 3. What did not make the cap (14 items)

The cap forced these out. Listed so the omission is visible rather than silent — several are real.

**Cut, but I think genuinely rulable:**

- **M1-C-031 + M1-C-032** — the two image intake routes have *different* dedup rules: dash items
  are not deduplicated against each other, inline images are deduplicated against dash items. An
  inconsistency inside one function.
- **M1-C-022** — a `kind:` line after a section heading is discarded entirely: neither captured nor
  kept as body. Silent data loss on a narrow path.
- **M1-C-011** — a second `# ` heading is kept as body rather than discarded.
- **M1-C-009** — a whitespace-only document becomes body rather than an empty card.
- **M1-C-038 + M1-C-039** — the unknown-heading rule is asymmetric (before structure: kept as body
  including its prose; after: discarded with its contents). Documented, but the asymmetry is sharp.

**Cut as already-documented or already-settled:**

- **M1-C-047** — the heading-in-body residual. The module documents it and P02 confirms convergence.
- **M2-C-031 + M2-C-032** — `idsByPath` last-writer-wins. Doc comment states it; characterization
  confirms it. (Its *iteration*-order sibling did make the cap, as R21.)
- **M1-C-035 + M1-C-036** — `..` clamping and dot-segment collapse. Both look intentional.

**Cut as architectural, needing a different kind of review than this sheet:**

- **M1-A-15, M1-A-17, M2-A-01, M2-A-02, M2-A-05, M2-A-13, M2-A-14, M2-A-15** — the eight
  Region A architectural clauses (single-implementation rules, cross-surface ownership, API-shape
  rules). Real intent, verified by grep/build-graph/compiler rather than by any assertion. `R23`
  is the one I promoted, because it is the one whose violation would corrupt *other* tests'
  conclusions. **These eight are also the clauses a behavioural ratchet can never see, which is
  the sharpest argument in this experiment against equating "untested" with "not required".**

**Cut as provenance:** M1-B-05, M2-B-02 — historical cause. Not rulable, worth preserving.

---

## 4. What a ruling pass produces

For the derivation ratio afterwards, the numbers this sheet puts at stake:

| | count |
|---|---|
| Claims generated with no human input | 163 |
| Intent clauses generated with no human input | 55 |
| Items requiring a human ruling (this sheet) | 25 |
| — recommended RATIFY (machine got it right, just confirm) | 4 |
| — recommended INCIDENTAL-KILLABLE (machine got it wrong, delete) | 5 |
| — recommended LATENT_DEFECT (machine found a real bug) | 5 |
| — recommended NEEDS-DISCUSSION (machine cannot decide) | **11** |
| Rulable items the cap excluded | 14 |
| Claims per ruling slot | ~6.5 |

**The 11 NEEDS-DISCUSSION items are the honest residue.** Every one of them is a question of the
form *"is this behaviour intended, a documentation gap, or a bug?"* — and in each case the
evidence is complete and the answer still is not derivable from it. That is what I would offer as
the experiment's actual measurement of the irreducible human part: not 163 minus something, but
**11 decisions, plus the 8 architectural clauses no behavioural evidence can reach.**

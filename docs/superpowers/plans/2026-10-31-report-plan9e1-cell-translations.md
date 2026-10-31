# Report plan 9e-1 — translated text cells: store, permit, bodies — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A figure's text cells (row and column labels) can be translated per language — by `write_translation` now, by the translator agent in plan 9e-2 — and a language body (PDF, EPUB, Word) and the editor card in review show them, falling back to the source with the usual missing-translation warning; the coverage gate counts them.

**Architecture:** Cell translations reuse the existing per-device `TranslationStore` (no schema bump), filed under the figure's doc id with a typed `"row:col"` key. A new permit class `DocumentClass.figureTranslation(id:piece:)` judges them by the figure's piece (or whole-book). A Core deriver yields each text cell's translation status (fresh, stale on a source edit, orphaned on a deleted row/column), and fresh labels feed `FigureTableLayout` (bodies) and `FigureCardModel` (card) through label hooks. Numbers, dates and formulas stay shared.

**Tech Stack:** Swift 6, MaughamCore (permit, translation, `Table/`), Maugham `OpLog`/translation pipeline, `Publish/`, `MCP/`, `Views/`, `Editor/`.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §8, §12 items 7 and 9. Survey with file:line for every name here, and the full task detail (§6): `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan9e-survey.md`.

## Global Constraints

- "Shared across languages: numbers, dates and formulas. Translated per language: text cells … keyed by (figure, row id, column id, language). Who may write: a translator actor's permit allows writing those entries only. What a body shows: a language body shows its translations, and falls back to the source text with the usual missing-translation warning. Captions translate with their line, as today." (§8)
- Translation writes go through `TranslationWritePipeline` — the `appendBatch` census stays at its two sites.
- Every permit question is asked of `Permit`/`PermitJudge` (tripwires 43, 44, 47, 49); a new class gets exhaustive arms, never a default.
- Mac and phone share Core for keys, the text-cell predicate and derivation (tripwire 19). Never read `figures/*.csv` (tripwire 20).
- Help describes only what ships (rule 7): the translator agent writing cells is plan 9e-2.

## Rulings made while writing this plan

- **R1 — a text cell is a stored literal, non-blank text value.** Formula results that are text print as computed from the source in every body (formulas are shared).
- **R2 — a new class `DocumentClass.figureTranslation(id:piece:)`**, with no Option A starter arm (as piece translations); a whole-book figure's translations follow whole-book authors; an unregistered figure is held until its record lands.
- **R3 — reuse `TranslationStore`** keyed by figure id with `"row:col"` keys; no new store, no schema bump.
- **R4 — a removed figure's translations stay inert** (not listed, not counted) and re-attach on restore; not swept on Empty Trash (mirrors the figure's own stream). Cell orphans (deleted row/column, text → number) are listed and purgeable.
- **R5 — promotion carries no cell translations**, as it carries no piece translations today.
- **R7 — the gate:** missing or stale cells of unparked table figures used in the edition's included pieces block a language edition exactly as paragraphs do; `allow_stale` falls back with the usual suffix.
- **R8 — MCP addresses cells by A1** (validated against the current table at write time); ids are stored.
- (R6, who the translator covers, is plan 9e-2's.)

## Review Focus

1. A pieces-author's translator writes a cell of a figure in her own piece: applied; of a whole-book figure: refused; the reviewer: refused. Pin in Task 1.
2. The source label "Revenue" edited to "Revenues" after translation: the es body prints "Revenues" (source) with the missing-translation warning, and the gate counts it stale. Pin in Tasks 2, 5, 6.
3. A row with a translated label deleted, then the delete undone: orphaned, then re-attached. Pin in Task 2.
4. A text cell turned into a number: its translation becomes an orphan, never printed over the number. Pin in Task 2.
5. Translations of a figure used in two included pieces count once in the gate. Pin in Task 6.

---

### Task 1: The figure-aware translation permit (Core)

Survey §6 task 1. **Files:** Core `DocumentClass.swift`, `Permit.swift`, `PermitJudge`, the three construct sites (`TranslationStore.swift:312`, `StreamPositions.swift:720`, `TranslationWritePipeline.swift:204`), `DocumentStore+Posture.yieldPiece`, Core tests.
- **Produces:** `DocumentClass.figureTranslation(id:piece:)`; `DocumentClass.translationClass(ofDocId:facts:)` (a `fig-` id resolves through the manifest's figures; others stay `.translation(piece:)`, paying no manifest read); exhaustive arms in `piece`, `startersPiece`, `refused`, `yieldPiece`.
- [ ] Failing Core tests per Review Focus 1, plus an unregistered figure held; implement; `./scripts/test.sh core`, `./scripts/test.sh`, `./scripts/test.sh phone`; commit.

### Task 2: Key, text-cell predicate, derivation (Core)

Survey §6 task 2. **Files:** new Core `Table/FigureCellTranslation.swift` (or split); Core tests.
- **Produces:** `FigureCellTranslationKey` (`CellKey` ↔ `"row:col"`); `FigureTextCells.isTextCell(_:)`; `FigureTranslationDeriver.derive(records:table:language:) -> FigureTranslatedTable` (entries with source, translation, status fresh/stale/missing, verbatim; orphans) and `freshLabels -> [CellKey: String]`.
- [ ] Failing tests per Review Focus 2–4 and formula-text excluded; implement; commit after `./scripts/test.sh core`.

### Task 3: The write route

Survey §6 task 3. **Files:** `TranslationWritePipeline.swift` (`performCells(entries:language:figureId:table:actor:)` sharing one private core with `perform`; the same single `appendBatch`; a non-text cell rejected; `.maughamTranslationDidUpdate` carries `figure_id`); Mac tests; census unchanged.
- [ ] Failing tests (write, refuse a non-text cell, refuse an unknown id, delete form); implement; commit after `./scripts/test.sh`.

### Task 4: MCP

Survey §6 task 4. **Files:** `Maugham/MCP/Tools/TranslationTools.swift`, `get_help` translation skill text, `docs/skills/maugham-bootstrap/SKILL.md`, MCP AREA contracts.
- **Produces:** `write_translation` takes a figure id as `document_id` with `entries[].a1`; `read_translation` on a figure lists text cells (a1, source, translation, status) and orphans; `translation_status` gains a `figures` section (used figures). Tool count unchanged.
- [ ] Failing tests; implement; commit after `./scripts/test.sh`.

### Task 5: Bodies print translated cells

Survey §6 task 5. **Files:** `Maugham/Publish/PublishFigures.swift` (`cellTranslations`, fresh-only, snapshotted for the compile's languages), Core `FigureTableLayout.make(table:value:locale:label:)`, `PublishResolution.tableFigure` (passes the body language's labels); tests in the three emitter suites' style.
- [ ] Failing tests: an es EPUB/Word/PDF body prints the translation; a stale cell prints the source with the missing-translation warning; the source body is byte-identical (EMISSION/novel goldens unchanged); implement; commit after `./scripts/test.sh full`.

### Task 6: The coverage gate

Survey §6 task 6. **Files:** `TranslationCoverage.swift` (`check` adds `FigureGap { figureId, name, stale, missing }` for used unparked table figures, de-duplicated; `applyGate` phrasing "Table cashflow: B3, C1 untranslated"), `EditionStatus`/`translation_status` share one helper.
- [ ] Failing tests per Review Focus 5 and R7; implement; commit after `./scripts/test.sh`.

### Task 7: The card shows translations in review

Survey §6 task 7. **Files:** Core `FigureCardBook.build(…, language:labels:)`, `FigureCardModel.build` uses the stored-literal predicate (update `test_labelLookupAppliesToTextCellsOnly`), Mac `FigureCardInputs.language`/labels, `FigureCardCache` refills on a review-language change and on `.maughamTranslationDidUpdate`.
- [ ] Failing tests: a card in es review shows the translated label; height unchanged (no room refresh); implement; commit after `./scripts/test.sh` and `./scripts/test.sh phone`.

### Task 8: A surface to inspect and purge

Survey §6 task 8. **Files:** the Translation pane (a "Cells" list for the figure under the caret: status chips, orphan Purge through the pipeline's delete as `.author`, refusals as notices), `FigureInspector` (a per-language coverage line, revealing review).
- [ ] Failing tests on pure row models; implement; commit after `./scripts/test.sh`.

### Task 9: Lifecycle

Survey §6 task 9. Removed figure inert and re-attached on restore (R4); parked figures excluded from the gate and re-attached on return; promotion carries none (R5); a rename leaves cell translations untouched. Tests per edge; commit after `./scripts/test.sh full`.

### Task 10: Docs, register, gates

Help and guide (translation pages) describe what ships; Publish/MCP/OpLog AREA notes (mind ceilings); a register claim for cell translations naming its tests; spec §12 items 7 and 9 marked. `./scripts/test.sh core`, `full`, `phone`; Release build; commit.

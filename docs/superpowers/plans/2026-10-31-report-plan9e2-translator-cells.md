# Report plan 9e-2 — the translator writes table labels — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The in-app translator agent's round on a piece also translates the text cells of the tables used in that piece (missing or stale), so a language edition's table labels can be completed from inside Maugham, not only by Claude over MCP.

**Architecture:** The translator's round context gains the used tables' cells needing work (from plan 9e-1's `FigureUse.tables(in:figures:)` + `FigureUse.coverage(of:language:projectURL:trust:)`), filtered per figure by the translation posture (`DocumentStore.translationPosture(forDocId:as:)`). The briefing lists them; the report schema gains a `cells` array; ingest writes them through `TranslationWritePipeline.performCells(… actor: .translator)` after the paragraph batch. The seven-leg pipeline's other agents (spot-check, collator, cold legs) stay paragraph-only.

**Tech Stack:** Swift 6, Maugham `Compiler/` (translator orchestrator, briefing, report, preflight), `MCP/Tools/TranslationWritePipeline`.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §8 ("Who may write: a translator actor's permit allows writing those entries only"), §12 item 9. Built plan this extends: `docs/superpowers/plans/2026-10-31-report-plan9e1-cell-translations.md`. Survey (9e-2 section, §6): `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan9e-survey.md` — re-verify every name against the code as built by 9e-1.

## Global Constraints

- The translator writes cell entries only, through `TranslationWritePipeline` (the `appendBatch` census stays at its two sites), signed as the translator actor.
- Only stored literal text cells (R1 of 9e-1); numbers, dates and formulas never go to the translator.
- A new `claude` service joins `AgentRoster` (Compiler AREA's one rule) — this plan adds no new service, only extends the translator's round.
- Help describes only what ships (rule 7).

## Rulings made while writing this plan

- **R6 — the translator on a piece covers the tables used in that piece**, missing or stale cells only. A whole-book table used in two pieces is done on the first; the second finds it fresh. Cells the round's actor may not write (translation posture) are left out of the briefing, never sent and refused.
- **Cells are all-or-nothing per round report:** a malformed `cells` array rejects the cells (the paragraphs still land) and the round report says so.
- **A cell whose row or column was deleted mid-round** is rejected loudly in the round report (not silently dropped).
- **The seven-leg pipeline's spot-check, collator and cold legs stay paragraph-only.**

## Review Focus

1. A Spanish round on a chapter using a 3×4 table with header labels: after the round, the es body prints the labels and the gate is satisfied for that table. Pin in Task 3.
2. A round where the table's source label changes mid-round: the cell lands stale (source hash from the round's snapshot), not fresh over the new text. Pin in Task 3.
3. A pieces-author's translator on her chapter that uses a whole-book table: the whole-book table's cells are not in the briefing. Pin in Task 1.

---

### Task 1: The round knows the cells

**Files:** `Maugham/Compiler/TranslatorEnvironment+Project.swift` (or the round-context builder the survey names), `Maugham/Compiler/TranslationPipeline.swift`/`TranslatorOrchestrator.swift` as needed, tests.
- **Produces:** the round context's `tableCells: [TableCellWork]` — per used table (first use only): figure id, name, and each missing/stale text cell (`CellKey`, A1 for display, source text, prior translation if stale), filtered by `translationPosture(forDocId: figureId, as: .translator)`.
- [ ] Failing tests: missing and stale cells appear; fresh, numbers and formulas don't; Review Focus 3; a parked table is absent. Implement; commit after `./scripts/test.sh`.

### Task 2: The briefing and the report schema

**Files:** the translator briefing composer (`BriefingDoctrine`/translator briefing), `Maugham/Compiler/TranslatorReport.swift` (`cells: [{figure_id, cell: "row:col", text?, verbatim?}]`, `schemaDescription`), tests.
- [ ] Failing tests: a briefing with table cells shows a "Table cells" section in a `[Table: name r:c]` form with source text; a report decodes `cells`; a malformed `cells` array is rejected whole while paragraphs decode. Implement; commit after `./scripts/test.sh`.

### Task 3: Ingest writes the cells

**Files:** the translator ingest in `TranslatorOrchestrator.swift` (after the paragraph batch, `TranslationWritePipeline.performCells(… actor: .translator)` per table), the round report counts cells, tests.
- [ ] Failing tests: Review Focus 1 and 2; a deleted row mid-round is rejected in the round report; a refused cell (posture changed mid-round) is reported, not silent. Implement; commit after `./scripts/test.sh full`.

### Task 4: Preflight and the pipeline's other legs

**Files:** `Maugham/Compiler/TranslationPreflight.swift` (word count includes the cells' source text), tests pinning that spot-check, collator and cold legs see no cells.
- [ ] Failing tests; implement; commit after `./scripts/test.sh`.

### Task 5: Docs, register, gates

`docs/guide/translation-review.md` (the translator now covers the chapter's tables), Compiler AREA note, the register claim M5-AN-068 extended (the translator writes cells, naming tests), spec §12 item 9 marked fully built; `./scripts/test.sh core`, `full`, `phone`; Release build; commit.

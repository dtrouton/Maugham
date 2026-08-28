# The Translation Pipeline — Design

**Date:** 2026-08-28
**Status:** Designed, not built. Planned as four plans (see §11); Plan 1 is written and built before Plans 2–4 are written.
**Constitution check:** extends the Claude-parallel-layer principle — every session added here reads and returns, none holds a write tool, and manuscript text is reachable from none of them (the reader and collator hold *no tool at all*). Everything new lives under `.maugham/` (round records, staged proposals) or on the manifest (two more role kinds, no schema bump). The keystroke-only trigger rule (ADR 0028's tempo discipline, `Maugham/Compiler/AREA.md`) holds: one Run is one act with more legs; nothing here re-arms itself. The "no statement-writing tool in the catalogue" line (`CompilerAllowlistTests.test_noStatementWritingToolExistsAnywhereClaudeCanReach`) is kept *and strengthened*: what is added is a **proposal** the writer adopts, never a write.

## Purpose

The translator built in the publish department (spec `2026-08-19-publish-department-design.md`) is one person working alone, reviewed only by a writer who may not read the language. Denver's own runs found the shape that works — translate, a cold monolingual read, fix, read again, fix, then a bilingual comparison because the fixes pull the text away from the source — and the literature says the same thing in numbers: monolingual readers prefer refined output while bilingual measures score it lower, and "refinement projects outputs toward the refiner's distribution rather than performing targeted error repair." (TransAgents, arXiv 2405.11804; arXiv 2605.13368.) Human practice under ISO 17100 splits the same two jobs by name: **revision** (bilingual, mandatory) and **review** (monolingual, comments back to the translator, never edits).

This milestone gives every language edition that cast and that pipeline inside the app, files a round report the writer can act on, and — because a good brief is what every one of these people is judged against — lets Claude Desktop *propose* a brief the writer adopts.

## Decisions (settled in brainstorm)

1. **A blind monolingual reader** — sees the target text only. It can say "this doesn't sound like Spanish"; it can never say "this is wrong."
2. **Notes are annotations, visible to the writer, picked up by the translator** — one queue, one disposition vocabulary; the writer can reject a note and it never reaches the translator again.
3. **One Run is a bounded pipeline** of seven legs (§4). Fixed depth, deliberately not adaptive.
4. **A third person, the collator**, holds both texts at the end and owns the *deviations* judgement; the translator does not self-report deviations.
5. **A round report on the desk row**, with anything needing a ruling minted as a query (existing `Answer as ruling…`), never a new field.
6. **Industry-derived amendments adopted**: reader's report carries an `overall` verdict against the brief's register; notes carry an MQM-style `kind` and `severity`; fix legs are segment-scoped repairs and say so; the round shows leg-2 vs leg-4 so the second cycle's value is measurable; the collator's remit includes document-wide consistency; the brief carries a **two-line register** (texture, content).
7. **Brief drafting from Claude Desktop is a proposal, not a write** — `propose_edition_brief` and `propose_visual_language`, adopted at a gate in the statement pane; **craft intent is not proposable**, and that is a type-level fact.

Rejected: the translator reading its own work back (not blind); the reader as a Desktop-side skill only (no pipeline, no blindness); a `write_edition_brief` tool (the statement census's whole point); an adaptive pipeline depth (a loop the writer can't cost); severity on notes *without* a typology (unauditable by a writer who can't read the language — the typology is what makes "omission, major" checkable by anyone).

## 1. The cast, as data

`ProductionRole.Role` gains two cases beside `translator`/`designer`/`unknown`:

```
case reader(language: String)     // on disk "reader:<tag>"
case collator(language: String)   // on disk "collator:<tag>"
```

Same first-colon split as `translator:`; an empty tag decodes to `.unknown(raw)` as today. **No manifest schema bump**: a pre-pipeline build decodes either as `.unknown` and re-encodes it verbatim (ADR 0015), so the pairing note on the department milestone is unchanged.

Both are **lazy-minted** the first time a language's pipeline runs, through the same `DepartmentCastSheet` composition that mints a translator: the mint sheet for an unlisted language grows from one name field to three (translator, reader, collator), each prefilled from a preset where one exists. **Rename …** on a language row's context menu offers all three people. `effectiveName`/`effectiveBrief` remain the ONE spelling of resolution.

Presets, borrowed from literary history like the rest of the cast:

| Language | Translator (existing) | Reader | Collator |
|---|---|---|---|
| es | Cortázar | Ocampo | Borges |
| fr | Baudelaire | Colette | Yourcenar |
| de | Tieck | Bachmann | Schlegel |
| ja | Motoyuki | Enchi | Futabatei |

Readers are readers; collators are writers who translated, since that is the job.

**Preset briefs** (`effectiveBrief` fallbacks; writer-editable through `brief`):

- *Reader*: "You are reading a book written in [language]. You have not seen, and will not see, any other version of it. Say where it does not sound like a book written in this language — a phrase no native writer would reach for, register that wobbles, rhythm that limps, a name or idiom transcribed rather than rendered. Judge against the edition brief's stated register, not against a universal norm. Do not rewrite. Do not guess what an original might have said."
- *Collator*: "You hold the original and the translation side by side. Say where the translation departs from what the original says, and for each departure whether it still says the same thing or has drifted. Deliberate repetition, sentence architecture and the author's plainness are meaning — a synonym substituted for a repeated word is a departure. Read the whole document: a name or term rendered two ways is a departure even when each paragraph is fine alone. The translator's idiom is not your concern unless meaning moved."

### 1.1 The edition brief's register lines

The edition brief preset (what "Edition Brief" creates on first click, and what the `edition-brief` skill's interview fills) carries **two register lines**, because "reads as translated" conflates two axes:

- **Texture** — does the prose read as written in [language], or should the source's cadence stay audible?
- **Content** — what stays foreign: names, places, forms of address, food, what is left untranslated.

Per-language defaults follow the target culture: fluent texture for es/fr; a little more permissive for de; for ja an explicit choice between 翻訳調 (honyaku-chō, the recognised translation register) and native register. The writer overrules per edition. The reader's `overall` verdict (§3) is against the **texture** line only.

## 2. Briefings

All three are pure functions in `Maugham/Compiler/`, `TranslatorBriefing`'s discipline: no I/O, no clock, testable without a subprocess.

**`ReaderBriefing`** — in order: role frame + effective brief; the edition brief verbatim (rulings included — target-language doctrine a native reader may hold); the document's translated text in `sequence` order, every paragraph tagged with its `¶id`, a stale or missing paragraph rendered as `[¶id — not yet translated]` and **never** as source text; the report contract. **Not briefed**: craft intent (about the English), source text, translator queries, prior reader notes (a reader shown its own last notes defends them), the bible (a side channel to the source). A planted source sentence must be absent from the composed prompt — that is the test.

**`CollatorBriefing`** — role frame + effective brief; craft intent (fidelity to what the writer *meant* is its business); the edition brief verbatim (so a ruling like "place names stay in English" is not reported as a departure); the paragraph pairs in `sequence` order, source then translation, untranslated paragraphs listed as such; the report contract. **Not briefed**: reader notes, translator queries, the bible.

**`TranslatorBriefing` gains a `mode`**: `.translate` (today's) or `.fix(notes)`. In `.fix`, the work-list is exactly the noted paragraphs (they are `fresh`; today's gather would skip them), each with the note's id, kind, severity and text and the paragraph's current translation; and the briefing says in words: *this is a repair of the noted paragraphs, not a polish; leave every unnoted paragraph exactly as it is; rewrite, decline with a reason, or stay silent.* The last fix leg (leg 7) additionally asks for the `summary`.

## 3. The wire

Every report is `TranslatorReport`'s discipline: one JSON object, all-or-nothing, a malformed item fails the whole report, empty `text` refused.

**`ReaderReport`**
```
{ "overall": { "verdict": "reads_as_native" | "reads_as_translated" | "mixed",
               "text": "…a short reader's report…" },
  "notes": [ { "paragraph_id", "kind", "severity", "text" } ] }
kind     ∈ unidiomatic | register | rhythm | grammar | inconsistency
severity ∈ minor | major
```
A `paragraph_id` outside the briefed set fails the report. Zero notes is a valid report. No suggested rewrite (a reader who rewrites has started translating).

**`CollatorReport`**
```
{ "overall": { "text": "…how the two hold together…" },
  "departures": [ { "paragraph_id", "verdict": "holds" | "drifted",
                    "kind", "note" } ] }
kind ∈ mistranslation | omission | addition | untranslated | inconsistency | rendering
```
`holds` is a departure worth the writer knowing about that still says what the source says (a rendered pun, a split sentence — `kind: rendering`); `drifted` is meaning that moved. Only `drifted` departures mint as annotations; `holds` ones go to the round record only.

**`TranslatorReport` widens** with fields read only in `.fix` mode:
```
"addressed": [ note_id ],
"declined":  [ { "note_id", "reason" } ],
"summary":   "…"            // leg 7 only
```
Each id must be one the leg was briefed with; an id in both lists fails the report; an id from the other pass fails the report. A note neither addressed nor declined stays open. `delete` remains absent from the wire.

## 4. The pipeline

`TranslationPipeline` (`@MainActor`, owned in `ProjectWindow`'s wiring beside the orchestrators) is a state machine and nothing else: it owns no session, gathers no briefing, parses no report. It sequences legs by calling the orchestrators and listening to their `onRunEnded`.

| Leg | Who | Session | Input | Output |
|---|---|---|---|---|
| 1 translate | translator | warm | stale/missing work-list | entries, queries |
| 2 read | reader | cold | whole translated text, blind | reader notes + overall |
| 3 fix | translator | warm | leg 2's open notes | rewrites, addressed/declined |
| 4 re-read | reader | cold, fresh | whole translated text again | reader notes + overall |
| 5 fix | translator | warm | leg 4's notes | as 3 |
| 6 collate | collator | cold | source + translation, paired | departures + overall |
| 7 fix | translator | warm | leg 6's `drifted` departures | as 3, plus `summary` |

**Cold means cold.** `ReaderOrchestrator` and `CollatorOrchestrator` spawn a fresh `claude -p` per leg and end it when the report lands. Warmth would buy nothing (the whole briefing is re-sent) and would cost blindness (a warm reader remembers its own notes).

**Skips are recorded, never silent.** Legs 2/4 skip when the document has no fresh paragraphs to read; legs 3/5/7 skip when the preceding pass left nothing to fix; leg 6 runs whenever any earlier leg wrote (it is the check on the fixes). A leg that writes nothing but has a report still records its `overall`. If legs 1–5 all skip or write nothing, leg 6 skips too and the round says "nothing to do".

**Depth is fixed.** Two read/fix cycles and one collate/fix regardless of counts. The round record's leg-2 vs leg-4 figures are what let the writer judge whether cycle two earns its keep; if it does not, the constant changes, not the design.

**Outcomes.** A leg that fails, or whose batch is rejected (the edited-paragraph rejection), ends the pipeline there; the round records the leg and the failure sentence; whatever earlier legs wrote stays — leg 1's entries are real translations whether or not a reader got to them. A cancelled leg ends the pipeline; nothing later starts.

**Cancel** is one button reaching whichever leg is live — the translator's `cancel()` (already covers unsent and in-flight) or the reader's/collator's. Between legs there is nothing to cancel; the pipeline checks its own generation before starting the next leg, so a Cancel landing in the gap stops the pipeline rather than a leg that never started.

**The gate** — one round at a time across every language — widens from "a translator round" to "a pipeline". Run's disabled-reason wording is unchanged; the row's status slot names the leg.

**Session owners.** Reader and collator are teardown siblings: `.shutdown()`/`.detach()` beside the translator's in every arm `TranslatorEnvironmentTests`' census pairs today; the census widens to three siblings. Cold-per-leg does not exempt them — a window closing mid-read is a billing process otherwise.

## 5. Minting

ADR 0029's shape: sessions return, Maugham writes at ingest.

- A reader note mints as an annotation of kind `.comment`, authored by the reader's `effectiveName`, `language`-tagged, anchored to its paragraph, carrying `kind` and `severity` in its metadata; a `drifted` departure mints likewise under the collator's name. Annotation minting reuses the translator's existing query-minting path (`TranslatorEnvironment+Project`), widened by author and kind.
- A fix leg's `addressed` id settles as **accepted**, disposition attributed to the translator; a `declined` id stays **open** and gains a **reply** on its thread carrying the translator's reason, so the disagreement reads as a conversation the writer can rule on.
- A writer's **reject** on a note removes it from every later fix leg's briefing (the gather reads `open` only, as today's query gather does).
- Entries land through `TranslationWritePipeline`, the one shared write path (census-pinned today; unchanged).

## 6. The round record

`TranslationRound` — derived, `.maugham/translations/rounds/<lang>.json`, a ring of the last 10 per language; losing it costs a report, never words.

```
number, language, docId, startedAt, endedAt
legs: [ { leg, status: ran(counts) | skipped(reason) | failed(sentence) | cancelled } ]
readerOverall: [leg2: (verdict, text)?, leg4: (verdict, text)?]
collatorOverall: text?
departures: [ { paragraphId, verdict, kind, note, annotationId? } ]
summary: String?
left: { openNotes, openQueries }
```

Numbering is per language across documents (the desk row is the language's); the record names its document.

## 7. Surfaces

- **Desk row** (`DepartmentPane`, `DepartmentRunState`): the one status slot says the leg in flight (*translating → reading → fixing → re-reading → fixing → collating → fixing*), then "Round N · finished 2m ago · **Show**". `DepartmentRunState.Phase.running` widens from `translating: Int` to a leg descriptor.
- **Show** is a fourth arm of `PublishCentre` — `.translationRound(TranslationRound)` — resolved in `ProjectWindow.publishCentre` the way `.designProposal` is, drawn in the centre column: header (language, document, round, when), the two reader verdicts side by side, the collator's overall, the summary, then the departures list where a row **click opens that paragraph in Translation Review** for the language (the existing mode and reveal contract), then the counts with a door to the queue.
- **Queue / Translation pane**: no new pane. Reader and collator notes are annotations and already draw there; the byline is the person's name; a declined note shows the translator's reason as a reply.
- **MCP**: `translation_status` gains `reader`, `collator` and a `last_round` block (number, verdicts, counts, summary) — a widening of an existing read, no new tool.
- **Every new data type has a surface**: roles (desk, cast sheet), notes (queue), rounds (Show), proposals (§8's gate).

## 8. Proposals into statements

**Skills** — `docs/skills/edition-brief/SKILL.md` and `docs/skills/visual-language/SKILL.md`, served through the existing SEP-2640 skills extension. The brief skill interviews before drafting: read `read_craft_intent`, `read_edition_brief`, a sample chapter and the palette first; then one question at a time — the two-axis register (§1.1), variety (es-ES/es-419, pt-BR), forms of address (tú/usted, tu/vous, keigo level), typographic conventions for the language, what stays untranslated — with the target culture's default named. The visual-language skill interviews on trim, type, ornament and the sample-page questions the designer is briefed on. Both end by calling the proposal tool, never by pasting into chat. `maugham-bootstrap`'s existing "read visual language first" section points at the new skill.

**Tools** — `propose_edition_brief(language, markdown, rationale?)` and `propose_visual_language(markdown, rationale?)`, mirroring the two read tools' shape. Catalogue 56 → 58. **Neither is in `CompilerAllowlist`** — no confined session can propose its own standard. Each stages a draft and writes nothing to a statement.

**Store** — `StatementProposalStore`, derived, `.maugham/statements/proposals/<key>.json`, one pending slot per key (a new proposal supersedes). Its kind is a **two-case enum** — `ProposableStatement.editionBrief(String) | .visualLanguage` — so craft intent is unrepresentable rather than refused at runtime.

**Gate** — `StatementPane` shows a banner when a proposal stands for the statement it hosts: *Claude proposed a brief · Adopt / Discard*, the proposal readable beside the current text. **Adopt** replaces the statement's prose through the existing statement write path (op-logged, undoable like any statement edit) and **preserves the `## Rulings` stratum byte-for-byte** — rulings are `RulingPerformer`'s and a proposal never touches one; a first Adopt on a language with no brief creates it. **Discard** clears the slot. The desk's language row and the Visual Language pane's entry carry a "proposed" mark so a proposal is discoverable without opening the pane.

**Census** — `CompilerAllowlistTests.statementWriters` gains `edition_brief` and `visual_language` under the existing write verbs (closing a real gap: today's subject list would not catch `write_edition_brief`), and `propose_craft_intent` is a planted offender: `propose_` is not a write verb, and the control asserts that `propose_edition_brief` passes while `propose_craft_intent` is caught by a second predicate over the `propose_` prefix.

## 9. Confinement

Reader and collator sessions spawn with `--tools ""`, `--strict-mcp-config`, and **no `--mcp-config` at all** — blind by construction, not by allowlist. Pinned the way `ClaudeCLISessionTests.test_spawnArgumentsMatchTheSpike` pins the compiler's flags, plus a `TripwireGrepTests` census that neither `ReaderOrchestrator` nor `CollatorOrchestrator` calls `writeMCPConfig`. The translator's allowlist is unchanged.

## 10. Tests, by unit

- **Briefings**: reader — a planted source sentence absent, gap markers present, no bible/intent section; collator — the same sentence present, paired; translator `.fix` — work-list is exactly the noted set, repair sentence present.
- **Parsers**: all-or-nothing; unknown paragraph fails; wrong-pass id fails; id in both `addressed`/`declined` fails; closed enums for verdict/kind/severity; empty `text` refused; zero notes valid.
- **Pipeline** over fake orchestrators: leg order; every skip rule with its reason; a failing leg stops the rest and keeps earlier writes; Cancel mid-leg and Cancel in the gap; the widened gate; generation discipline (a stale `onRunEnded` after a respawn is ignored).
- **Minting**: byline is `effectiveName`; `kind`/`severity` carried; addressed → accepted; declined → open + reply; rejected notes absent from the next briefing.
- **Round record**: ring of 10; numbering per language; a cancelled round records where it stopped and no summary.
- **Teardown census**: three siblings in every arm.
- **Proposals**: supersede; Adopt preserves `## Rulings` byte-for-byte; Adopt creates a missing brief; Discard; craft intent unrepresentable (compile-time, plus the census).
- **Census and pins**: statement subjects widened with planted `write_edition_brief`; `propose_craft_intent` caught; catalogue count 58; `DocSyncTests` for guide topics; skills served.
- **Presets**: the four languages resolve reader/collator names; an unlisted language falls back to the tag, as the translator does.

## 11. Plans

Four plans, each ≤10 tasks; **Plan 1 is built before Plans 2–4 are written**, and the later plans are derived against the built code.

1. **Cast and cold sessions** — role cases + presets + briefs; cast-sheet widening; `ReaderBriefing`/`CollatorBriefing`/`ReaderReport`/`CollatorReport`; `ReaderOrchestrator`/`CollatorOrchestrator` with their confinement pins; teardown census widened; `TranslatorBriefing.mode` and the `TranslatorReport` widening.
2. **Pipeline, minting, round** — `TranslationPipeline`; the gather for `.fix`; minting under three names with disposition/reply; `TranslationRound` + store; `translation_status` widening.
3. **Surfaces** — desk row phases and Show; `.translationRound` centre arm with click-through; guide + roadmap + AREA sweeps; ADR 0030.
4. **Proposals** — `StatementProposalStore`; two tools; the gate in `StatementPane` and the "proposed" marks; census widening; the two skills; docs.

## 12. Docs

ADR 0030 — *three people, seven legs, and proposals into statements* — amending ADR 0024's single-translator picture and recording that ADR 0028's "one door into a statement" survives a proposal because a proposal is not a door. Guide: `publish-department.md` (the people, the pipeline, the round, Show), `translation-review.md` (notes from a reader or collator, the reply on a declined note), the statements topic (proposals, Adopt/Discard). `translation-pass` skill gains a pointer to the in-app pipeline. Roadmap entry; `Maugham/Compiler/AREA.md`, `Maugham/MCP/AREA.md`, `Maugham/Views/AREA.md`.

## 13. Open edges, recorded

- A `holds` departure has no annotation and therefore no disposition; if the writer wants to *rule* on one ("keep rendering puns this way") the path is the brief's rulings by hand. A "rule on this" verb from the departures list is a later addition.
- Numbering rounds per language across documents means round 4 may be chapter 2 and round 5 chapter 9; the record names the document and the Show header says it. A per-document lane is a later refinement if it turns out to matter.
- The reader's `overall` on a document with many untranslated gaps is a verdict on a fragment; the round shows the gap count beside it.

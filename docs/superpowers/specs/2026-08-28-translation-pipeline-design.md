# The Translation Pipeline — Design

**Date:** 2026-08-28 (amended the same day after an experience-first pressure test; v2 supersedes v1 wholesale; re-derived against v0.33.0 — imprints and bilingual editions — which landed the same day and changed the desk)
**Status:** Designed, not built. Planned as five plans (§13); Plan 1 is written and built before Plans 2–4 are written.
**Constitution check:** extends the Claude-parallel-layer principle — every session added here reads and returns, none holds a write tool, and manuscript text is reachable from none of them (the reader, collator and glosser hold *no tool at all*). Everything new lives under `.maugham/` (round records, staged proposals), on the manifest (two more role kinds, no schema bump), or in the writer's own plain-text statements (directives and glossary are rulings). The keystroke-only trigger rule (ADR 0028's tempo discipline, `Maugham/Compiler/AREA.md`) holds: one Run is one act with more legs; nothing here re-arms itself. The "no statement-writing tool in the catalogue" line (`CompilerAllowlistTests.test_noStatementWritingToolExistsAnywhereClaudeCanReach`) is kept *and strengthened*: what is added is a **proposal** the writer adopts, never a write. **No new `AnnotationKind`** — the enum is closed, the phone decodes it, and a new case would force a paired release; every new writer-facing record here is a ruling or a round record.

## Purpose

The translator built in the publish department (spec `2026-08-19-publish-department-design.md`) is one person working alone, reviewed only by a writer who may not read the language. Denver's own runs found the shape that works — translate, a cold monolingual read, fix, read again, fix, then a bilingual comparison because the fixes pull the text away from the source — and the literature says the same in numbers: monolingual readers prefer refined output while bilingual measures score it lower, and "refinement projects outputs toward the refiner's distribution rather than performing targeted error repair" (TransAgents, arXiv 2405.11804; arXiv 2605.13368). Human practice under ISO 17100 splits the two jobs by name — **revision** (bilingual, mandatory) and **review** (monolingual, comments back, never edits) — and runs on a **termbase**.

**The author this is for wants Kundera's control and has none of the languages.** Kundera's control was five things: he could *declare* what in his prose was deliberate, *check* any sentence he suspected, *veto and direct*, *stay consistent* for decades, and *choose his people*. What our author has instead of the languages is perfect knowledge of their own English and why it is shaped as it is. Every surface here is designed to run on that: directives are written against the English; the report is written *to* the author in their language; the checking tool is a gloss of any paragraph they point at; consistency is a brief that accumulates rulings and a glossary they can read because it is a table.

## Decisions (settled in brainstorm)

1. **A blind monolingual reader** — target text only. It can say "this doesn't sound like Spanish"; it can never say "this is wrong."
2. **The round report is the primary surface, written to the author in their language** (§8). The queue holds only what needs the author's answer.
3. **One Run is a bounded pipeline** of seven legs (§5). Fixed depth, deliberately not adaptive; also runnable over the whole book from one keystroke.
4. **A third person, the collator**, holds both texts at the end and owns the *departures* judgement, each with a **gloss** — a literal back-rendering into the author's language — so the author can rule on it.
5. **Directives are rulings** — a paragraph-anchored line in a statement's `## Rulings`, minted through `RulingPerformer` from a selection in the English (§3). The glossary is rulings of a recognised shape, rendered as a table.
6. **Every note the translator is briefed with must be addressed or declined**; silence fails the report. Addressed notes live in the round record; only declined ones and queries reach the queue.
7. **Gloss and Ask the collator on any paragraph** — the author's spot-check, cold and tool-less (§9).
8. **Industry-derived amendments**: reader's `overall` verdict against the brief's texture line; MQM-style `kind`/`severity` on notes; fix legs are segment-scoped repairs and say so; leg-2 vs leg-4 exposed on the round; the collator's remit includes document-wide consistency against the glossary; the brief carries a two-line register plus a "what I won't let a translator smooth" line.
9. **Brief drafting from Claude Desktop is a proposal, not a write** — `propose_edition_brief` and `propose_visual_language`, adopted at a gate with a diff; **craft intent is not proposable**, and that is a type-level fact (§10).

Rejected: the translator reading its own work back (not blind); a Desktop-only reader (no pipeline, no blindness); `write_edition_brief` (the statement census's point); an adaptive depth (a loop the author can't cost); a new `AnnotationKind` for directives (paired release for a line of text); a whole-document back-translation as the checking tool (expensive, reads as a wall of bad English — the gloss is back-translation applied only where the author points); minting every reader note into the queue (v1 — a queue of remarks about Spanish prose the author can't dispose of on the merits).

## 1. The cast, as data

`ProductionRole.Role` gains two cases beside `translator`/`designer`/`unknown`:

```
case reader(language: String)     // on disk "reader:<tag>"
case collator(language: String)   // on disk "collator:<tag>"
```

Same first-colon split as `translator:`; an empty tag decodes to `.unknown(raw)` as today. **No manifest schema bump**: a pre-pipeline build decodes either as `.unknown` and re-encodes verbatim (ADR 0015).

Both are **lazy-minted** the first time a language's pipeline runs, through the same `DepartmentCastSheet` composition that mints a translator: the sheet for an unlisted language grows to three name fields, each prefilled from a preset where one exists. **Rename …** on a language row offers all three. `effectiveName`/`effectiveBrief` remain the ONE spelling of resolution. The glosser (§9) is not a person — it signs nothing and has no name; it is a verb.

Presets, borrowed from literary history like the rest of the cast:

| Language | Translator (existing) | Reader | Collator |
|---|---|---|---|
| es | Cortázar | Ocampo | Borges |
| fr | Baudelaire | Colette | Yourcenar |
| de | Tieck | Bachmann | Schlegel |
| ja | Motoyuki | Enchi | Futabatei |

**Preset briefs** (`effectiveBrief` fallbacks; writer-editable):

- *Reader*: "You are reading a book written in [language]. You have not seen, and will not see, any other version of it. Say where it does not sound like a book written in this language — a phrase no native writer would reach for, register that wobbles, rhythm that limps, a name or idiom transcribed rather than rendered. Judge against the edition brief's stated register and its rulings, not a universal norm; a feature the brief declares deliberate is not a fault. Write your notes and your report in [the author's language]. Do not rewrite. Do not guess what an original might have said."
- *Collator*: "You hold the original and the translation side by side. Say where the translation departs from what the original says, and for each departure whether it still says the same thing or has drifted — and render, literally, into [the author's language], what the translation now says there, so the author can judge it. Deliberate repetition, sentence architecture and the author's plainness are meaning: a synonym for a repeated word is a departure. A directive on a paragraph is the standard for that paragraph. Read the whole document against the glossary: a name or term rendered two ways is a departure even when each paragraph is fine alone. The translator's idiom is not your concern unless meaning moved."

### 1.1 The edition brief's register and standards

The brief preset (created on first click, and what the `edition-brief` skill's interview fills) carries **three lines** above its rulings:

- **Texture** — does the prose read as written in [language], or should the source's cadence stay audible? Per-language defaults follow the target culture: fluent for es/fr; a little more permissive for de; for ja an explicit choice between 翻訳調 (honyaku-chō, the recognised translation register) and native register. The reader's `overall` verdict (§4) is against this line only.
- **Content** — what stays foreign: names, places, forms of address, food, what is left untranslated.
- **What I won't let a translator smooth** — the book-level style declaration: deliberate repetition, plain diction, fragment rhythm, whatever the author would fight for. Elicited by the skill's interview ("what would you refuse to let a translator improve?").

Below them, `## Rulings` holds ordinary rulings, **directives** (§3) and **glossary entries** (§3.1) — one stratum, one parser, one door.

## 2. Briefings

Pure functions in `Maugham/Compiler/`, `TranslatorBriefing`'s discipline: no I/O, no clock, testable without a subprocess.

**`ReaderBriefing`** — role frame + effective brief; the edition brief verbatim (its three lines and its rulings — target-language doctrine a native reader may hold; directives included, since "this fragment is deliberate" is exactly what stops a reader flagging it every round); the document's translated text in `sequence` order, every paragraph tagged with its `¶id`, a stale or missing paragraph rendered as `[¶id — not yet translated]` and **never** as source text; the report contract. **Not briefed**: craft intent's essay (about the English), source text, translator queries, prior reader notes (a reader shown its last notes defends them), the bible (a side channel to the source). A planted source sentence must be absent from the composed prompt — that is the test.

**`CollatorBriefing`** — role frame + effective brief; craft intent verbatim (fidelity to what the writer *meant* is its business); the edition brief verbatim; the glossary as a table; the paragraph pairs in `sequence` order, source then translation, each paragraph's directives beneath it, untranslated paragraphs listed as such; the report contract. **Not briefed**: reader notes, translator queries, the bible.

**`TranslatorBriefing` gains a `mode`**: `.translate` (today's, plus directives per work item and the glossary) or `.fix(notes)`. In `.fix` the work-list is exactly the noted paragraphs (they are `fresh`; today's gather would skip them), each with the note's id, author, kind, severity and text, the paragraph's directives, and its current translation; and the briefing says in words: *this is a repair of the noted paragraphs, not a polish; leave every unnoted paragraph exactly as it is; for every note, rewrite or decline with a reason — never stay silent.* Leg 7 additionally asks for the `summary` and `glossary_proposals`.

**The `.translate` work-list** = `stale ∪ missing ∪ directed`, where *directed* is a fresh paragraph carrying a directive ruled **after** its translation record's `at` — derived from two dates, nothing stored. That is how "Keep mine" (§8) reaches the next Run.

## 3. Directives — the author's Kundera move

A **directive** is a ruling anchored to a paragraph: in the English, select a passage, **Translator's note…** (context menu and a `⌘⌥`-letter read off `MaughamApp`'s bindings at build time), type the instruction — "this repetition is deliberate", "one sentence, not two", "do not elevate this" — and choose its home:

- **Every edition** (default) → the piece's **craft intent** `## Rulings`; a directive about the English applies to every language.
- **This edition only** → that language's **edition brief** `## Rulings`.

On disk it is one plain line the author can hand-edit:

```
- ¶k7mq: keep the three "and"s — this sentence is a list on purpose — ruled 28 Aug 2026, translator's note
```

`RulingsSection` learns one thing: an optional leading `¶<id>:` parses into `Ruling.paragraphId: String?` (additive; a bare line still parses; the id alphabet is `ParagraphID`'s). Minted only through `RulingPerformer.rule` — the one door — with provenance `translator's note`. **A directive whose paragraph no longer exists is an orphan**, drawn as such in the statement pane with its text intact and a Remove; it is never silently dropped and never silently re-anchored.

Directives reach the translator (an instruction on the work item), the collator (the standard for that paragraph), and the reader (through the brief's rulings, so a declared feature is not a fault). The compiler also reads craft intent's rulings and is unaffected: a directive is a true statement about the prose.

### 3.1 The glossary

A glossary entry is a ruling of a recognised shape, in the edition brief:

```
- «October» → «Octubre» — the month, never a name — ruled 28 Aug 2026, glossary
```

`RulingsSection` parses `«term» → «rendering»` (optional trailing note) into `Ruling.glossary: (term, rendering)?`; `StatementPane` renders glossary-shaped rulings as a **table** above the other rulings, since a table is what makes the glossary readable by an author who cannot read the language. Entries come from the author by hand, from the interview (§10), or from the translator's `glossary_proposals` adopted on a round (§8) — each adoption one `RulingPerformer.rule` call. The translator is briefed with the table; the collator checks the document against it (`inconsistency`).

## 4. The wire

Every report is `TranslatorReport`'s discipline: one JSON object, all-or-nothing, a malformed item fails the whole report, empty `text` refused. All prose fields are in the **author's language**.

**`ReaderReport`**
```
{ "overall": { "verdict": "reads_as_native" | "reads_as_translated" | "mixed",
               "text": "…a short reader's report, to the author…" },
  "notes": [ { "paragraph_id", "kind", "severity", "text" } ] }
kind     ∈ unidiomatic | register | rhythm | grammar | inconsistency
severity ∈ minor | major
```
A `paragraph_id` outside the briefed set fails the report. Zero notes is valid. No suggested rewrite.

**`CollatorReport`**
```
{ "overall": { "text": "…how the two hold together…" },
  "departures": [ { "paragraph_id", "verdict": "holds" | "drifted",
                    "kind", "note", "gloss" } ] }
kind ∈ mistranslation | omission | addition | untranslated | inconsistency | rendering
```
`gloss` is required on every departure: the literal back-rendering of what the translation now says at that spot. `holds` is a departure worth the author knowing about that still says what the source says (a rendered pun, a split sentence — `kind: rendering`); `drifted` is meaning that moved. Only `drifted` departures reach the fix leg; both reach the round report.

**`TranslatorReport` widens** with fields read only in `.fix` mode:
```
"addressed": [ note_id ],
"declined":  [ { "note_id", "reason" } ],
"summary":   "…",                                          // leg 7 only
"glossary_proposals": [ { "term", "rendering", "reason" } ] // leg 7 only
```
**Every briefed id must appear in exactly one list** — a missing id, an id in both, or an id from the other pass fails the report. `delete` remains absent from the wire.

**Single-paragraph calls** (§9) reuse the same parsers: a gloss returns `{ "gloss" }`; Ask the collator returns a `CollatorReport` over one pair with neighbours.

## 5. The pipeline

`TranslationPipeline` (`@MainActor`, owned in `ProjectWindow`'s wiring beside the orchestrators) is a state machine and nothing else: it owns no session, gathers no briefing, parses no report. It sequences legs by calling the orchestrators and listening to their `onRunEnded`.

| Leg | Who | Session | Input | Output |
|---|---|---|---|---|
| 1 translate | translator | warm | stale ∪ missing ∪ directed | entries, queries |
| 2 read | reader | cold | whole translated text, blind | notes + overall |
| 3 fix | translator | warm | leg 2's notes | addressed/declined |
| 4 re-read | reader | cold, fresh | whole translated text again | notes + overall |
| 5 fix | translator | warm | leg 4's notes | addressed/declined |
| 6 collate | collator | cold | source + translation, paired | departures + overall |
| 7 fix | translator | warm | leg 6's `drifted` departures | addressed/declined, summary, glossary proposals |

**Cold sessions share one runner.** `ColdCall` spawns a fresh tool-less `claude -p`, sends one briefing, parses one report, ends the process. Reader, collator, gloss and Ask-the-collator are four callers of it; there is no `ReaderOrchestrator` holding state between legs. Warmth would buy nothing (the whole briefing is re-sent) and would cost blindness.

**Skips are recorded, never silent.** Legs 2/4 skip when there is nothing fresh to read; legs 3/5/7 skip when the preceding pass left nothing; leg 6 runs whenever any earlier leg wrote. If nothing was written at all, leg 6 skips and the round says "nothing to do".

**Depth is fixed.** The round's leg-2 vs leg-4 figures are what let the author judge whether the second cycle earns its keep; if not, a constant changes, not the design.

**Outcomes.** A failing or rejected leg ends the pipeline there; the round records where and why; earlier legs' writes stay. A cancelled leg ends the pipeline; nothing later starts.

**Cancel** is one button reaching whichever leg is live — the translator's `cancel()` (covers unsent and in-flight) or `ColdCall`'s. Between legs the pipeline checks its own generation before starting the next leg, so a Cancel landing in the gap stops the pipeline rather than a leg that never started.

**Whole book.** **Run whole book** on the row (and in the Rename… menu's company) queues the documents of **the imprint the desk is standing on** — the same set `EditionStatus.languageRows(documentIds:)` sums for that row since imprints P3 (the book itself when no imprint is picked; an imprint's `sections` allowlist otherwise) — through the pipeline in binder order, one round each, from one keystroke; Cancel stops the queue after the live leg. The desk's rule for Compile is the rule here: the writer is asking about the thing that will actually be compiled, and an edition complete against the pamphlet must not be sent through the whole novel. **Pre-flight** on the row before either Run: "7 legs · ~N words briefed" (N = source + translated word counts of the document, or the book), so the wait and the cost are a known quantity before the click.

**The gate** — one round at a time across every language — widens from "a translator round" to "a pipeline, or a book queue".

**Session owners.** `ColdCall` is a teardown sibling: `.shutdown()`/`.detach()` beside the translator's in every arm `TranslatorEnvironmentTests`' census pairs today; the census widens to three siblings. A window closing mid-read is a billing process otherwise.

## 6. Minting

ADR 0029's shape: sessions return, Maugham writes at ingest — and **only what needs the author becomes an annotation**.

- Entries land through `TranslationWritePipeline`, the one shared write path (census-pinned; unchanged).
- Reader notes and collator departures are written to the **round record** (§7), never the queue. An `addressed` id is marked so in the record, with the paragraph's before/after translation captured at fix time (the sidecar is append-only; the record holds the two record ids).
- A **declined** note mints as a `.query` (anchored; author = the reader or collator by `effectiveName`, `language`-tagged, `kind`/`severity` in the body's first line) with the translator's reason attached as a **reply** on the thread — so the queue shows a conversation the author is asked to settle, with a byline for each side.
- Translator queries mint as today.
- The author's verbs on the round report (§8) act on these annotations where one exists; a note the author rejects is `rejected` and never briefed again (the gather reads `open` only, as today).

## 7. The round record

`TranslationRound` — derived, `.maugham/translations/rounds/<lang>.json`, a ring of the last 10 per language; losing it costs a report, never words.

```
number, language, docId, startedAt, endedAt
legs: [ { leg, status: ran(counts) | skipped(reason) | failed(sentence) | cancelled } ]
readerReports: { leg2: (verdict, text)?, leg4: (verdict, text)? }
collatorOverall: text?
notes: [ { id, leg, author, paragraphId, kind, severity, text,
           outcome: addressed(before, after) | declined(reason, annotationId) } ]
departures: [ { paragraphId, verdict, kind, note, gloss,
                outcome: addressed(before, after)? | declined(reason, annotationId)? | dismissed? } ]
summary: String?
glossaryProposals: [ { term, rendering, reason, adopted: Bool } ]
```

Numbering is per language across documents; the record names its document and the Show header says it. The desk row shows **notes per round** as a small trend (last five rounds), so the author can see the edition converging rather than churning.

## 8. The round report — the primary surface

**Show** is a fourth arm of `PublishCentre` — `.translationRound(TranslationRound)` — resolved in `ProjectWindow.publishCentre` the way `.designProposal` is, drawn in the centre column, **in the author's language, in this order**:

1. **The reader's report.** Leg 2 and leg 4 side by side — the verdict against the texture line, and the paragraph each reader wrote. The author sees the chapter improve, or not.
2. **Where your prose was changed.** One row per departure: the source line, the **gloss** of what the translation now says, the collator's reason, `holds`/`drifted`, and what the translator did about it. Three verbs on every row — **Fine** (dismiss; recorded on the round), **Keep mine** (mints a directive on that paragraph — home chosen in a one-line popover, edition-only by default since the decision came from this edition — and the paragraph is *directed* work for the next Run), **Make it a rule** (a general ruling in the edition brief, text prefilled from the departure).
3. **Disagreements.** Only the notes the translator declined — the note, the reason, both bylines. Verbs: **Translator's right** (rejects the note), **Reader's right** / **Collator's right** (accepts it and mints a directive quoting the note, so the next Run fixes it), **Make it a rule**.
4. **Questions for you.** The round's queries, with **Answer** and **Answer as ruling…** (existing).
5. **Glossary proposals.** Term, rendering, reason — **Adopt** (one ruling each) / **Skip**.
6. **The summary**, and the counts, with a door to the queue.

A departure row and a disagreement row **click through** to that paragraph in Translation Review (existing mode and reveal contract). An addressed note or departure expands to its before/after. Nothing on this surface requires reading the target language to act on.

**Desk row** (`DepartmentPane`, `DepartmentRunState`) — busier since v0.33.0, which put an imprint picker and a Compile sheet on the desk, so the pre-flight line and the trend share the row's existing status slot rather than adding a line each: the one status slot names the leg (*translating → reading → fixing → re-reading → fixing → collating → fixing*; for a book queue, "chapter 4 of 12 · reading"), then "Round N · finished 2m ago · **Show**"; the pre-flight line; the notes-per-round trend. `DepartmentRunState.Phase.running` widens from `translating: Int` to a leg descriptor.

**MCP**: `translation_status` gains `reader`, `collator` and a `last_round` block (number, verdicts, counts, summary) — a widening of an existing read.

## 9. Spot-checking — Gloss and Ask the collator

The pipeline glosses what it flagged. Kundera read everything. The substitute is two verbs in **Translation Review**, on the selected paragraph, in the Translation pane (⌘⌥L):

- **Gloss** — a `ColdCall` briefed with the translated paragraph and its two neighbours, the edition brief's texture line, and nothing else; returns a literal back-rendering into the author's language, drawn beneath the source text with a "gloss" label. Transient; not stored; a second click re-glosses.
- **Ask the collator** — a `ColdCall` over that one paragraph pair with neighbours, the full `CollatorBriefing` minus the rest of the document; returns departures with glosses, drawn in the pane with the same three verbs as a round row (Fine / Keep mine / Make it a rule). Transient unless a verb is used.

Both are keystroke-triggered, single-turn, tool-less. Neither mints anything on its own. Together they let the author audit anywhere, not only where the pipeline looked — the trust mechanism without which the author is taking the collator's word for everything.

## 10. Proposals into statements

**Skills** — `docs/skills/edition-brief/SKILL.md` and `docs/skills/visual-language/SKILL.md`, served through the existing SEP-2640 skills extension. The brief skill interviews before drafting: read `read_craft_intent`, `read_edition_brief`, a sample chapter and the palette first; then one question at a time — texture and content (§1.1), **what you won't let a translator smooth**, variety (es-ES/es-419, pt-BR), forms of address (tú/usted, tu/vous, keigo level), typographic conventions, the first glossary entries (every proper name in the sample chapter, with a proposed rendering) — naming the target culture's default. The visual-language skill interviews on trim, type, ornament and the sample-page questions the designer is briefed on. Both end by calling the proposal tool, never by pasting into chat. `maugham-bootstrap`'s "read visual language first" section points at the new skill.

**Tools** — `propose_edition_brief(language, markdown, rationale?)` and `propose_visual_language(markdown, rationale?)`, mirroring the two read tools' shape. Catalogue 56 → 58. **Neither is in `CompilerAllowlist`.** Each stages a draft and writes nothing to a statement. A proposed brief's glossary rows are proposed as `## Rulings` lines of the glossary shape, so Adopt carries them.

**Store** — `StatementProposalStore`, derived, `.maugham/statements/proposals/<key>.json`, one pending slot per key (a new proposal supersedes). Its kind is a **two-case enum** — `ProposableStatement.editionBrief(String) | .visualLanguage` — so craft intent is unrepresentable rather than refused at runtime.

**Gate** — `StatementPane` shows a banner when a proposal stands for the statement it hosts: *Claude proposed a brief · Adopt / Discard*, with the proposal shown as a **diff against the current text** (a hand-tuned brief must not be clobbered blind). **Adopt** replaces the essay through the existing statement write path (op-logged, undoable like any statement edit) and **preserves the existing `## Rulings` stratum byte-for-byte**, appending any glossary-shaped lines the proposal carries; a first Adopt on a language with no brief creates it. **Discard** clears the slot. The desk's language row and the Visual Language pane's entry carry a "proposed" mark.

**Census** — `CompilerAllowlistTests.statementWriters` gains `edition_brief` and `visual_language` under the existing write verbs (closing a real gap: today's subject list would not catch `write_edition_brief`), and a second predicate over the `propose_` prefix catches `propose_craft_intent` while `propose_edition_brief` passes — both planted.

## 11. Confinement

Every `ColdCall` spawns with `--tools ""`, `--strict-mcp-config`, and **no `--mcp-config` at all** — blind by construction, not by allowlist. Pinned the way `ClaudeCLISessionTests.test_spawnArgumentsMatchTheSpike` pins the compiler's flags, plus a `TripwireGrepTests` census that `ColdCall` never calls `writeMCPConfig`. The translator's allowlist is unchanged.

## 12. Tests, by unit

- **Briefings**: reader — a planted source sentence absent, gap markers present, brief's rulings (with directives) present, no intent essay/bible; collator — the sentence present and paired, directives under their paragraphs, glossary table present; translator `.fix` — work-list is exactly the noted set, repair sentence present; `.translate` — a *directed* paragraph (directive newer than its record) is in the work-list and an older one is not.
- **Parsers**: all-or-nothing; unknown paragraph fails; missing/duplicate/wrong-pass id fails; `gloss` required; closed enums; empty text refused; zero notes valid.
- **Rulings**: `¶id:` prefix parses to `paragraphId` and round-trips; a bare line still parses; glossary shape parses to `(term, rendering)` and round-trips; `RulingPerformer.rule` with a directive lands in the chosen statement; an orphaned directive is reported, not dropped.
- **Pipeline** over fake orchestrators: leg order; every skip rule with its reason; failure stops the rest and keeps earlier writes; Cancel mid-leg and in the gap; the book queue and its Cancel; the widened gate; generation discipline.
- **Minting**: addressed → round record with before/after and no annotation; declined → `.query` with reply, byline `effectiveName`; rejected notes absent from the next briefing; "Reader's right" mints a directive.
- **Round record**: ring of 10; numbering per language; a cancelled round records where it stopped and no summary; the trend reads the last five.
- **Report surface**: the four-verb rows act on the right annotation/ruling; click-through reveals the paragraph; nothing on the surface is target-language-only.
- **Spot-check**: Gloss and Ask the collator are `ColdCall`s with no config; neither mints.
- **Teardown census**: three siblings in every arm.
- **Proposals**: supersede; Adopt preserves `## Rulings` and appends glossary lines; Adopt creates a missing brief; Discard; diff shown; craft intent unrepresentable plus the census.
- **Census and pins**: statement subjects widened with planted `write_edition_brief`; `propose_craft_intent` caught; catalogue count 58; `DocSyncTests` for guide topics; skills served; presets resolve for four languages and fall back to the tag.

## 13. Plans

Five plans, each ≤10 tasks; **each plan is built before the next is written**, and the later plans are derived against the built code.

1. **Cast, rulings, and the wire** (`docs/superpowers/plans/2026-08-28-translation-pipeline-p1-cast-rulings-wire.md`) — role cases + presets + briefs; manifest lookups and store mints; `Ruling`'s directive and glossary shapes; `ReportJSON` extracted from the three duplicated parsers; `ReaderReport`/`CollatorReport`; `TranslatorReport`'s fix mode.
2. **Briefings, cold calls, and the two verbs** — `ReaderBriefing`/`CollatorBriefing`; `TranslatorBriefing.mode` + directed work-list; the sealed `ClaudeCLISession` confinement and `ColdCall` with its pins; teardown census widened; the cast sheet's three fields; **Translator's note…** in the editor.
3. **Pipeline, minting, round** — `TranslationPipeline` with the book queue; the `.fix` gather; minting per §6; `TranslationRound` + store; `translation_status` widening.
4. **Surfaces** — desk row (legs, pre-flight, trend, Run whole book); the round report arm with its verbs and click-through; Gloss and Ask the collator in the Translation pane; guide + roadmap + AREA sweeps; ADR 0030.
5. **Proposals** — `StatementProposalStore`; two tools; the gate with diff; census widening; the two skills; docs.

## 14. Docs

ADR 0030 — *three people, seven legs, directives as rulings, and proposals into statements* — amending ADR 0024's single-translator picture and recording that ADR 0028's "one door into a statement" survives both a directive (it goes through the door) and a proposal (it stops at the door). Guide: `publish-department.md` (the people, the pipeline, the round report and its verbs, whole-book Run), `translation-review.md` (Gloss, Ask the collator, disagreements in the queue), the statements topic (directives, the glossary table, proposals with Adopt/Discard), and a new section in the craft-intent topic for **Translator's note…**. `translation-pass` skill gains a pointer to the in-app pipeline and to directives. Roadmap entry; `Maugham/Compiler/AREA.md`, `Maugham/MCP/AREA.md`, `Maugham/Views/AREA.md`, `Maugham/Editor/AREA.md` (the new editor verb).

## 15. Open edges, recorded

- Round numbers run per language across chapters; the header names the chapter. A per-document lane is a later refinement.
- The reader's `overall` on a document with many untranslated gaps is a verdict on a fragment; the round shows the gap count beside it.
- A book-level consistency pass at Publish time (every chapter's translation against the glossary in one read) is the natural next step once the glossary exists; not in this milestone.
- An edition-level departures ledger (every `holds` across rounds — the raw material of a translator's note) is derivable from the round ring; no surface for it yet.
- `Gloss` is transient by design; if the author wants glosses kept, that is a later decision about where (the round record is the obvious home).

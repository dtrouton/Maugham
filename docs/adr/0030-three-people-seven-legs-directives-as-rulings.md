# ADR 0030 — Three people, seven legs, directives as rulings

**Date:** 2026-08-29 · **Status:** Accepted · **Milestone:** translation-pipeline (branches `translation-pipeline-p1`…`p4`)

## Context

[ADR 0024](0024-translation-layer.md) gave translation its own plane and, with it,
one relationship: a translator writing records into `.maugham/translations/`, and a
writer disposing of what came back. The publish department (spec
`2026-08-19-publish-department-design.md`) gave that translator a name and a desk,
and it held for as long as the writer could read what was written.

**The author this was rebuilt for cannot.** Denver's own runs found the shape that
works — translate, a cold monolingual read, fix, read again, fix, then a bilingual
comparison, because the fixes pull the text away from the source — and the
literature agrees in numbers: monolingual readers prefer refined output while
bilingual measures score it lower, and "refinement projects outputs toward the
refiner's distribution rather than performing targeted error repair" (TransAgents,
arXiv 2405.11804; arXiv 2605.13368). Human practice under ISO 17100 already splits
the two jobs by name — **revision** (bilingual, mandatory) and **review**
(monolingual, comments back, never edits) — and runs on a termbase.

One translator reviewed by nobody is therefore not a small version of that; it is a
different process with a known failure mode, and the writer who would have caught it
is exactly the person who has none of the languages. What that author has instead is
perfect knowledge of their own English and why it is shaped as it is. Every decision
below is designed to run on that, and the binding design is
`docs/superpowers/specs/2026-08-28-translation-pipeline-design.md` (v2), whose
constitution check this ADR records the outcome of.

This amends ADR 0024's **single-translator picture**. Nothing ADR 0024 decided about
the plane itself moves: records are still per-paragraph, per-language, per-device
JSONL; freshness is still derived; `write_translation` is still MCP's only writer
into it; the manuscript is still unreachable from every one of them.

## Decision

### 1. Three people per language, as data, minted only by a run.

`ProductionRole.Role` carries `reader(language:)` and `collator(language:)` beside
`translator`/`designer`/`unknown`
(`Packages/MaughamCore/Sources/MaughamCore/ProductionRole.swift`), on disk as
`reader:<tag>` / `collator:<tag>` with the same first-colon split, and **no manifest
schema bump** — a pre-pipeline build decodes either as `.unknown` and re-encodes it
verbatim (ADR 0015). Each has a preset name per language and a preset doctrine, both
reached through `effectiveName`/`effectiveBrief` and never through the raw fields, so
a manifest written before the presets existed still gets one.

The reader is **blind**: target text only, so it can say *this does not sound like a
book written in this language* and can never say *this is wrong*. The collator holds
both texts and owns the **departures** judgement, each carrying a **gloss** — a
literal back-rendering into the author's language — which is the thing that makes a
departure rulable by someone who cannot read the translation.

`ProjectStore.readerRole(for:)`/`collatorRole(for:)` mint lazily and **on a run
only**; `EditionStatus.readerName`/`collatorName` are read-only lookups that never
mint, because naming somebody to answer a status read is how a book acquires a cast
nobody chose.

### 2. One Run is seven fixed legs, and the depth is a constant rather than a loop.

`TranslationPipeline` (`Maugham/Compiler/TranslationPipeline.swift`) is a state
machine over closures and nothing else: it owns no session, gathers no briefing and
parses no translator report. It sequences translate → read → fix → re-read → fix →
collate → fix by calling the translator's two verbs and `ColdCall`'s one.

- **Skips are recorded, never silent** — one static reason per cause, including leg
  4's own rule (it skips because *nothing changed* when leg 3 wrote nothing, not
  because there is nothing to read).
- **A failing, rejected or cancelled leg ends the round there and earlier legs'
  writes stand.** `stoppedAt` names where it broke.
- **Cancel reaches whichever leg is live**, and a cancel landing in the gap between
  two legs stops the round rather than the leg that never started.
- **A book queue is the same Run over the desk's imprint set**, in binder order, one
  round each; a failed round stops the queue rather than sending the next chapter
  into the same broken session.

Depth is fixed deliberately. The round records leg 2's and leg 4's figures precisely
so the author can judge whether the second cycle earns its keep; if it does not, a
constant changes, not the design.

### 3. Every cold session is sealed — blind by construction, not by allowlist.

`ClaudeCLISession.Confinement` is an enum on the session: `.bridged(mcpConfigPath:)`
for the compiler, translator and designer (ADR 0028 §2's two-flag membrane,
unchanged), and `.sealed` for a cold call — `--tools ""` and `--strict-mcp-config` as
before, and **no `--mcp-config` and no `--allowedTools` at all**. A sealed session
cannot reach Maugham's catalogue because it was never told where it is.

`ColdCall` is the one runner every cold session shares (one fresh process, one
briefing, one report, ended), and its four callers are the reader, the collator,
**Gloss** and **Ask the collator**. There is no reader orchestrator: warmth would buy
nothing, since the whole briefing is re-sent each leg, and it would cost the
blindness the reader is for.

Pinned by `ClaudeCLISessionTests.test_aSealedSessionSpawnsWithNoBridgeAndNoAllowlist`
and by two censuses in `TripwireGrepTests` — `test_coldCallNeverBridges` and
`test_theOnlySealedSpawnerIsColdCall`.

### 4. Directives are rulings. ADR 0028's one door into a statement survives, because a directive goes *through* the door.

A **directive** is the author's Kundera move: select a passage in the English, write
the instruction, and it becomes one plain line under a statement's `## Rulings`,
anchored to a paragraph by a leading `¶<id>:` (`Ruling.directiveText`,
`Ruling.paragraphId`, MaughamCore's `RulingShapes.swift`). Home is the piece's craft
intent (every edition) or that language's edition brief (this edition only).

**Every production site that mints one calls `RulingPerformer.rule`** — the editor's
Translator's Note… (`TranslatorsNote.commit`, shared by ⌘⌥C and the spot-check's
*Keep mine*), and the round report's *Keep mine* and *Reader's right* /
*Collator's right* (`TranslationRoundActions`). There is no second door and no
directive-shaped write path; the shape is a composer over a string the writer typed,
which is what `RulingPerformerTests.test_nothingDerivedCanWriteItself` already
guards.

**The glossary is rulings of a recognised shape** — `«term» → «rendering» (note)` —
in the edition brief, parsed by `Ruling.glossary` and drawn as a **table**
(`RulingsStratum.partition`), because a table is what makes a termbase readable by an
author who cannot read the language. A directive whose paragraph no longer exists is
an **orphan**: drawn as such with its text intact and a Remove, never silently
dropped and never silently re-anchored.

### 5. Only what needs the author becomes an annotation. Everything else is the round record.

Spec §6, on ADR 0029's shape — the sessions return, Maugham writes at ingest:

- Reader notes and collator departures land in the **round record**
  (`TranslationRound`, `.maugham/translations/rounds/<lang>.json`, the newest ten
  rounds per language), with an addressed note's before/after captured at fix time.
- A **declined** note mints as a `.query` authored by the reader or collator who
  raised it, with the translator's reason as prose in the body under their name.
  **No new `AnnotationKind` and no reply primitive was added** — the enum stays four
  cases, the phone decodes it unchanged, and a wire change for a line of prose is a
  bigger membrane move than a milestone about legs and rounds should make.
- The author's own disposition is a **separate fact from the pipeline's** (P4's
  ruling, amending spec §7's single `outcome` slot):
  `TranslationRound.DepartureRecord.dismissed` sits beside `outcome`, so pressing
  *Fine* on a row can never erase what the translator actually did to it. The legacy
  `DepartureOutcome.dismissed` case is kept so older records decode and is no longer
  written.

### 6. The round report is the primary surface, and it is written to the author in their language.

`PublishCentre.translationRound` is a fourth arm of the one switch `.designProposal`
is a third arm of, drawn in the centre column: the reader's report (leg 2 beside leg
4), where the prose was changed (source line, gloss, the collator's reason, what the
translator did), the disagreements, the questions, the glossary proposals, the
summary. Every verb on it is one the author can press without reading the target
language, and the one place target-language text appears is a disclosure the author
opens on purpose. A row clicks through to that paragraph in Translation Review.

Beside it, **Gloss** and **Ask the collator** (`SpotCheck`) are the author's own
audit on any paragraph, not only where the pipeline looked: two cold calls that draw
an answer and **mint nothing** (`TripwireGrepTests.test_aSpotCheckMintsNothing`).
Without them the author is taking the collator's word for everything, which is not a
trust mechanism.

### 7. Proposals into statements stop at the door — built in Plan 5 (2026-09-02).

Spec §10 decides that a brief drafted from Claude Desktop arrives as a **proposal**
the writer adopts at a gate with a diff, never as a write: `propose_edition_brief` /
`propose_visual_language`, neither in `CompilerAllowlist`, staged in a store, with
craft intent unrepresentable in the proposal type rather than refused at runtime.

**Built in Plan 5.** `StatementProposalStore` (`.maugham/statements/proposals/<key>.json`,
derived, one pending slot per key, kind `ProposableStatement.editionBrief(String) |
.visualLanguage`), the two tools in the catalogue (56 → 58; neither in
`CompilerAllowlist`; `CompilerAllowlistTests.statementWriters` widened to
`edition_brief`/`visual_language` and a `propose_` predicate that catches
`propose_craft_intent` and passes exactly the two), the gate in `StatementPane`
(`StatementProposalBanner` over `StatementProposalDiff`; Adopt =
`StatementProposalGate.adopt`, the one write — a writer's click — through
`mutateStatementText` + `StatementEssay.recomposed` so the `## Rulings` tail is
byte-identical, then one `RulingPerformer.rule` per glossary line; Discard clears the
slot), the "proposed" marks, and the `edition-brief`/`visual-language` skills. The
decision stands as written: a proposal that arrived as anything but a staged draft
the writer adopts would be `write_edition_brief` wearing a new name — grep the
catalogue for what ships.

### 8. The falsifiable clauses.

Any one of these means this decision has been violated:

- **A session added here holds a write tool.** Every session in this milestone reads
  and returns; the reader, the collator and the two spot-checks hold *no tool at
  all*. `CompilerAllowlistTests.test_noStatementWritingToolExistsAnywhereClaudeCanReach`
  and the two `ColdCall` censuses are the standing proof; a model that could edit the
  brief it is judged against could move the standard until nothing it wrote is
  flagged.
- **A directive minted anywhere but `RulingPerformer.rule`.** A second door is a
  second answer about what a statement holds, and the writer's own prose is the one
  thing in this design nothing derived may author.
- **A new `AnnotationKind`.** The enum is closed, the phone decodes it, and a new
  case forces a paired release; every writer-facing record added here is a ruling or
  a round record instead.
- **A proposal that writes.** Spec §10's proposal arriving as anything but a staged
  draft the writer adopts is `write_edition_brief` wearing a new name.

## Consequences

- **ADR 0024 is amended, not superseded.** Its plane, its derived freshness and its
  single MCP writer stand; what changes is that the plane now has three named people
  working in it per language and a Run that sequences them.
- **ADR 0028 §2's confinement table gains a row rather than losing one.** `.bridged`
  is unchanged for the three warm orchestrators; `.sealed` is stricter than anything
  that came before it, because it removes the bridge instead of enumerating what may
  cross it.
- **ADR 0029's materialization pattern is what the pipeline's minting follows**, one
  layer further out: a cold session returns text, `TranslationPipeline` parses it into
  a typed report, and Maugham decides what becomes an entry, what becomes a round
  record and what becomes a query. The model calls nothing.
- **The writer's statements gained a second population.** A `## Rulings` stratum now
  holds ordinary rulings, directives and glossary entries in one parser and one door,
  which is why the statement pane partitions rather than filters — and why an
  orphaned directive is a drawn row rather than a dropped line.
- **The desk's busy gate reads the pipeline first.** A round's cold legs hold no warm
  translator session at all, so the orchestrator's own `isRunning` answers false
  mid-round; a gate that trusted it would offer Run on every row while a reader was
  out.
- A later plan that adds an eighth leg, a fourth cold caller or a second write door
  inherits this ADR's clauses at design time. A cold session that gains a tool is a
  different feature, and this ADR says so on the record.

## References

- `docs/superpowers/specs/2026-08-28-translation-pipeline-design.md` — the binding
  design (§1 the cast, §4 the wire, §5 the pipeline, §6 minting, §7 the round record,
  §8 the report, §9 spot-checks, §10 proposals, §11 confinement)
- Plans: `docs/superpowers/plans/2026-08-28-translation-pipeline-p1-cast-rulings-wire.md`,
  `docs/superpowers/plans/2026-08-29-translation-pipeline-p2-briefings-coldcalls-verbs.md`,
  `docs/superpowers/plans/2026-08-29-translation-pipeline-p3-pipeline-minting-round.md`,
  `docs/superpowers/plans/2026-08-29-translation-pipeline-p4-surfaces.md`
- Handoffs: `docs/superpowers/notes/2026-08-29-translation-pipeline-p1-handoff.md`,
  `docs/superpowers/notes/2026-08-29-translation-pipeline-p2-handoff.md`,
  `docs/superpowers/notes/2026-08-29-translation-pipeline-p3-handoff.md`
- [ADR 0024](0024-translation-layer.md) — the plane whose cast this amends
- [ADR 0028](0028-maugham-goes-outbound.md) §2 (confinement), §3 (the one door into a
  statement)
- [ADR 0029](0029-the-compilers-report-is-materialized.md) — the materialization
  pattern the minting follows
- `docs/constitution.md` must-not #1 (*AI is never the author* — *identity*): the
  manuscript is unreachable from every session added here, and what they produce
  reaches the writer's own prose only as a line the writer typed
- `Maugham/Compiler/AREA.md` — "Cold calls", "The pipeline — seven legs"
- `Maugham/Views/AREA.md` — the department desk, the round report, the reveal

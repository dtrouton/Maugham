# The Publish Department — Design

**Date:** 2026-08-19
**Status:** Approved design, pre-plan
**Constitution check:** extends the Claude-parallel-layer principle — spawned sessions never hold a write tool and manuscript text is reachable from nothing here (translations are the Claude-authored layer; templates are publish files, not manuscript). Manuscripts stay plain text at writer paths; everything new (roles manifest, staged proposals) lives under `.maugham/`. The keystroke-only trigger rule (ADR 0028's tempo discipline) carries over: no timer ever starts a translation or design run.

## Purpose

Give the Publish persona what M4 gave Review: named people running inside the app on the compiler model. A **translator per language** — briefed on the craft intent, the bible, rulings, review history, and the edition's own brief — translates the stale/missing set in a confined warm session and asks queries the writer disposes of like any other note. A **book designer** proposes a design as a spec plus complete templates, demonstrated as **sample pages** compiled against a staging area; nothing touches the live templates until the writer approves. The outside path (Claude Desktop/Code driving `write_translation` / `write_publish_file` over MCP) survives untouched as the manual override for when the writer wants more control.

The real-publisher structure this steals from: design and composition are separate acts (the spec is approved on sample pages before the compositor pours the book), and every downstream role is briefed on the book, not just handed text. Maugham is its own production editor — the schedule/gate/shepherding job is what the coverage gate, mint gate, and catalog already do mechanically, so that role is deliberately not personified.

## Decisions (settled in brainstorm)

1. **Inside, on the compiler model** — translator and designer run as confined `claude -p` sessions Maugham briefs, with the MCP write tools remaining as the outside override.
2. **Cast is translator(s) + designer** — no production-editor persona.
3. **One translator per language**, minted when the language edition first exists; renameable like a pass's editor.
4. **Sample pages are the design gate** — every designer run ends in samples; live templates change only on approval.
5. **Per-language edition brief** — a writer-owned statement document; query answers can harden into dated rulings under it via `RulingPerformer`.
6. **Approach A: report-materialized** — sessions read and return; Maugham writes at ingest (ADR 0029's shape). No write-back channel into the spawned session (rejected Approach B: allowlisting `write_translation`/`write_publish_file` at the socket would breach `--strict-mcp-config`'s purpose and put a live write channel inside a process the confinement design treats as read-only; a crashed session could also half-finish the store, where report-materialized is atomic per ingest).

## 1. The cast, as data

One new MaughamCore type, shaped like `ReviewPass` because it earns the same machinery:

```
ProductionRole
  id      String
  role    .translator(language: String) | .designer
  name    String?
  brief   String?
```

with `effectiveName` / `effectiveBrief` fallbacks so a project that never customized still gets doctrine — the `ReviewPass` lesson: **never read the raw fields**. Stored on the project manifest (`ProjectManifest.productionRoles`), same pattern as the pass manifest.

**Amendment, 2026-08-19:** initially described as stored under `.maugham/`, which is contradictory — the pass manifest IS the project manifest (at the project root), not a directory under `.maugham/`. The code uses `ProjectManifest.productionRoles`; roles are manifest-level entries read alongside passes.

- **The designer exists from the start**, one per project. Preset name **Tschichold**. Preset brief: read the visual language statement before proposing anything; design the page, not the decoration; one spec, demonstrated in sample pages, accounting for every element the manuscript actually contains.
- **A translator is minted when a language edition first exists** — first translation run requested for that language, or retroactively when translations for a language are already present (an upgrade pass; Volumen Uno's `es` gets one). Default names come from a small preset table of real translators *into* that language (`es`: Cortázar, `fr`: Baudelaire, `de`: Tieck, `ja`: Motoyuki — the plan fixes the table); unlisted languages get a mint sheet asking the writer to name them. Renameable any time.
- **Identity is carried on artifacts.** A translator's queries are annotations authored by their name (how Perkins signs notes); the designer's spec and proposals are authored by theirs. Work arriving through the outside MCP tools lands **unsigned** — the manual override doesn't wear the person's name, so *signed means it came through the loop* stays honest (the straight-means-Claude principle, transposed).

## 2. The translator's loop

**Trigger.** A "Run translation" act per language, from the department desk (§5). Keystroke/click only.

**Work-list = the coverage derivation.** A run translates the *stale + missing* set for that `(doc, language)` — `TranslationDeriver` already computes it — briefed with those paragraphs plus surrounding context, not the whole book. A first run for a new language is the everything-missing case. **No rounds ring**: freshness is the memory; "since last time" falls out of the hash discipline.

**Briefing:** craft intent, bible, review rulings, the edition brief and its rulings (§4), open and recently-answered translation queries, and the writer's disposition history on this translator's past queries — a warm session honors "the doctora is female" instead of re-asking it.

**Confinement is the compiler's exactly** (ADR 0028): `--tools ""` empties the built-in set, `--allowedTools` pre-approves read-only tools, `--strict-mcp-config` keeps MCP servers out. Same shutdown contract: `shutdown()`/`detach()` owned by every path that ends a window; a released session is a live billing process.

**Report → ingest.** The finished report carries translation entries (`¶id` → text, or `verbatim: true` for chrome) and queries. Maugham ingests:

- Entries go through **the existing `TranslationUnit` write path — one shared implementation with `write_translation`, not a sibling**: server-stamped `sourceHash` against the live paragraph (never the on-disk `.md`, tripwire 20), construct-parity warnings, all-or-nothing on unknown `¶id`s.
- Queries mint as annotations authored by the translator's name, `language`-tagged, anchored against the live paragraph at ingest (never against text the model echoed back — M4 P1's anchoring rule).

**Where the writer meets the work:** translation review mode (already built) for reading; queries surface there and in the annotations pane with the standard disposition vocabulary. One new disposition consequence: answering a query can mint a ruling into the edition brief (§4).

## 3. The designer's loop and the sample-pages gate

**A designer run is a design round**, requested from the desk with a direction in words ("square album, warmer paper, looser leading") or bare — then the brief is whatever the visual language statement says. Same warm-session mechanics, confinement, and trigger discipline as §2.

**Briefing:** the visual language statement (its second in-app consumer — the M1 protection extends), the **element census** — `ProjectASTBuilder` walks the book and reports which block kinds actually occur (verse, block quotes, code fences, Fountain elements, footnotes, images) so the spec must account for each — the current live templates, the publish config, and for a language edition, that edition's brief (Spanish «» conventions live there).

**Report → staging.** The report carries the spec in words plus **complete proposed template files** (LaTeX preamble/style, EPUB CSS). Maugham materializes them into a staging area under `.maugham/` — live templates untouched — then compiles **sample pages** through the existing preview pipeline against the staged templates: the first chapter opener, one spread of running text, and one instance of each special element the census found. **Page-set selection is a pure function of the AST** — testable without tectonic.

**The gate.** The Publish centre shows the sample pages beside the spec, signed by the designer, with **Approve** and **Request changes**. Request changes feeds the writer's words back into the warm session for a revised proposal. Approve promotes the staged set to the live templates as **one versioned, undoable act**; full compiles use them from then on.

**Honest edge:** sample pages are PDF — the preview pipeline is tectonic. The EPUB CSS rides in the same proposal and is approved on the spec's word; its verification remains the compiled EPUB. EPUB sample rendering is future work, not this milestone.

## 4. The edition brief — the writer-owned membrane

**Each language edition gets a statement document** — the third statement kind, beside the craft intent and the visual language: op-logged, writer-owned, one more `statementText(of:)` subject rather than a new mechanism. Contents: register, idiom policy, what stays untranslated, typographic conventions, who characters are when the target language forces a choice the source didn't make.

**Query answers harden into rulings.** Answering a translator's query offers the same door `RulingPerformer` gives a conformance strain: a dated, itemized ruling under the brief's `## Rulings`, carrying the query's own «excerpt». Same performer, same ADR 0023 undo, one new statement target — the membrane stays as tight as the second draft made it (rule/revoke/edit/restore is still the only door into the writer-owned layer).

**Volumen Uno seeds the first brief by hand** — the existing `es` conventions are pasted in when the milestone lands; no migration (workflow rule 11); the retroactive translator mint (§1) picks it up.

**MCP:** the brief is readable from outside through the statement reader — widen `read_craft_intent`'s pattern or add `read_edition_brief`; the plan decides against the catalogue, but either derives through `ProjectStore.statementText(of:)`. **Plan-time gate:** check whether a new statement subject moves the op-log schema and forces a paired Mac+phone release — the spine's schema-4 precedent says look before assuming.

## 5. Surfaces and MCP

**The department desk** — a new right-pane surface in Publish: one new `DetailSegment` case, one registry entry, one seat in `PersonaPaneRegistryTests.canonicalPaneOrder`, a `⌘⌥` shortcut read off `MaughamApp`'s bindings. `ReviewBoardPane`'s sibling:

- a **Design** row — designer's name, the live spec's age, a pending-proposal badge, Run;
- a row per **language** — translator's name, fresh/stale/missing figures from the `translation_status` derivation, open query count, Run.

Every new datum this milestone mints (roles manifest, staged proposal, run state) has its inspection surface here or one click away (workflow rule 8).

**The centre** stays governed by the existing rule: a pending design proposal, selected from the desk, takes the Publish centre as the sample-pages gate view — a sibling of `PublishPreviewCentre`'s books/notice arms, not a new persona rule.

**Run state** reuses the cockpit idioms Review built — progress, cancel, every ending path owns the shutdown.

**MCP moves are small:**

- the statement reader for edition briefs (§4);
- `translation_status` gains the translator's name in its payload, so an outside session knows who it's standing in for (a widening of an existing read — the count doesn't move for it);
- **no new write tools** — the outside override *is* the existing pair;
- the bootstrap skill (`docs/skills/maugham-bootstrap/SKILL.md`) gains the protection visual language got: a section telling an outside Claude running a translation to read the edition brief first, so the manual path and the inside path are briefed from the same doctrine.

**Help:** a Publish-department topic in `docs/guide/` — one docs source; describes what ships.

## 6. Failure, undo, and testing

**Failure is atomic at the ingest boundary.** A session that dies mid-run has written nothing — no report, no ingest; the desk row shows the failure and the run retries. No half-translated state exists (the property Approach A bought). Ingest inherits the existing all-or-nothing: unknown `¶id`s fail the whole batch loudly, listing them; construct-parity warnings ride the report and surface on the desk row, non-blocking.

**Sample-page compiles fail like previews, not publishes**: preview pipeline, exempt from `PublishMintGate` like `dry_run` (they mutate nothing); a tectonic failure shows the proposal *with* the compile error rather than silently pageless. The coverage gate on real publishes is untouched.

**Undo:** template approval is one undoable act (the staged set together); query-answer-to-ruling gets ADR 0023 undo through `RulingPerformer`; translation ingest is corrected by the next run (LWW store) and the writer-facing artifact is annotations, which dispose normally.

**Testing:**

- Orchestrators keep the closure-`Environment` shape — translator and designer runs drive with no project on disk.
- The allowlist census extends `CompilerAllowlistTests`: no write tool in either role's allowlist **or catalogue**, planted offender and control.
- Sample-page selection: pure-function tests over the AST, no tectonic.
- Any suite that really compiles calls `try await TectonicProbe.requireReady()`; anything styling text wires `FontWarmup.ensure()`.
- Ingest tests assert **shared implementation** with `write_translation` via a caller-count census, so a sibling write path can't grow back.
- §4's schema/pairing check is a plan-time gate, not an assumption.

## Out of scope

- EPUB sample-page rendering (approved on the spec's word; verified on the compiled EPUB).
- A production-editor persona.
- Rounds/ring machinery for translation (freshness is the memory).
- Any change to the outside MCP write tools' behavior beyond briefing/doc additions.

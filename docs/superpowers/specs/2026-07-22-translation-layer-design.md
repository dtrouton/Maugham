# Translation Layer — Design

**Date:** 2026-07-22
**Status:** Approved design, pre-plan
**Constitution check:** extends the Claude-parallel-layer principle (MCP never mutates manuscript text); manuscripts stay plain text at writer paths; all new data under `.maugham/`.

## Purpose

Hold Claude-authored translated versions of manuscripts, tagged by language, with per-paragraph freshness tracking; readable and writable via MCP so Claude Code / Desktop can run translation passes; publishable as a distinct edition (e.g. a Spanish PDF/EPUB); reviewable by the writer in a read-only editor mode where they can annotate and answer Claude's translation queries.

**Acceptance test (built into the plan):** produce *Playlist, Volumen Uno* — the Spanish edition of the existing Playlist Volume One book — **without touching the English source or the shared templates**. This exercises every seam below: chrome idiom, construct parity, Fountain drift, edition templates, edition metadata, the coverage gate, and the skill loop.

## Decisions (settled in brainstorm)

1. **Paragraph-aligned** — one translated paragraph per source `¶id`. Merging/splitting sentences within a paragraph is fine; merging paragraphs is not.
2. **Sidecar only** — no derived `.es.md` on disk in v1 (cheap to bolt on later).
3. **Annotate + answer, no direct edit** — translated text is read-only in the editor; the writer's fix path is Claude-mediated (comment/reply → Claude retranslates). This is a deliberate v1 decision, not an oversight.
4. **Publish blocks on stale/missing** with a coverage report; explicit `allow_stale` override for proofs.
5. **Review mode replaces editor text** (read-only) with source-on-demand in the right pane.
6. **Separate translation store** — not new OpKinds in the manuscript op log, not a sibling Document.

## 1. Data model (MaughamCore)

`TranslationUnit`:

```
opId         ULID     — LWW resolution key, per (paragraphId, language)
paragraphId  String   — source ¶id
language     String   — lowercase BCP-47-ish tag ("es", "pt-br"); regex-validated, no allowlist
text         String?  — nil = tombstone (delete this paragraph's translation)
sourceHash   String   — StableHash of the source paragraph's normalized display-form text at write time
verbatim     Bool     — true when the server copied source as text (chrome idiom; see §2)
at           Date     — display only, never consulted for resolution
```

**`text` is the paragraph's full markdown/fountain source form** (inline markers, speaker labels, `##` headings, `> **Doctora:**` quote syntax intact). The publish AST builder re-parses it through the same `MarkdownBlockParser` / inline parsers as source text — translated typography is emergent from the same grammar, not special-cased.

**Storage:** append-only JSONL at `.maugham/translations/<docId>.<lang>.<deviceSlug>.jsonl`, built on `JSONLAppendStore`. Per-device partitioning per tripwire 17 (device slug via `DeviceSlug`, interpolated only at the filename point, never serialized into content). Merge = opId-ordered, content-deterministic LWW per `(paragraphId, language)` — same total-order discipline as `OpLogStore.mergeSortedDedup`. No sealing in v1 (noted future work; translation tails are MCP-written and low-churn relative to typing).

**Freshness is derived, never stored:**

- *fresh* — unit's `sourceHash` == current paragraph's normalized hash
- *stale* — unit exists, hash differs
- *missing* — paragraph in `sequence` with no unit for this language
- *orphan* — unit whose `¶id` is no longer in `sequence`; ignored in derivation, counted in status, never crashes a derive

**Hash normalization:** input is the paragraph's display-form text (anchors stripped via the existing `MarkdownDisplayFilter` — no target-local copy), then each line's trailing whitespace stripped before hashing. Consequence: an edit that only changes trailing whitespace (including adding/removing a markdown two-space hard break) does not flip staleness. Accepted limitation, documented in the tool descriptions.

`TranslationDeriver` folds merged units against the live `sequence` into a `TranslatedDocument`: ordered entries `{¶id, sourceText, translatedText?, status, verbatim}`.

## 2. MCP tools (48 → 51)

- **`write_translation`** — batch write: `docId`, `language`, `entries: [{paragraphId, text} | {paragraphId, verbatim: true}]`.
  - The **server** stamps `sourceHash` from the current paragraph at write time; Claude never computes hashes.
  - Current-paragraph resolution goes through the open-doc registry (live `Document`) or `DerivedManuscript` — **never the on-disk `.md`** (tripwire 20; this call site is an easy place to violate it).
  - All-or-nothing: any unknown `¶id` fails the whole call loudly, listing the bad ids.
  - `verbatim: true` copies the current source text as the translation (the **chrome idiom**: `[Tool permission request]` walls, `# /clear` headers, code fences that shouldn't be translated). It goes fresh and re-stales correctly on edit, and audits can distinguish "deliberately identical" from "suspiciously untranslated."
  - **Construct-parity warning:** for each non-verbatim entry, compare the inline-construct skeleton (block type; counts of strong/emph runs) of source vs translation; return warnings on drift. Non-blocking — a lost `**Doctora:**` bold doesn't look wrong but silently reclassifies October's speech bubble; this warning catches that dominant bug class at write time.
- **`read_translation`** — aligned per-paragraph view (`¶id`, `sourceText`, `translatedText`, `status`, `verbatim`), with a `status` filter so Claude fetches exactly the stale/missing work-list. Respects the 1 MB response cap (tripwire 10) via the established pagination/windowing conventions.
- **`translation_status`** — per project or per doc: languages present, fresh/stale/missing/orphan counts, open translation-query counts. Makes "is the Spanish edition current?" one call.

**Queries reuse the annotation layer.** `add_query` gains an optional `language` field; translation questions ("¿*vos* or *tú* for this narrator?") anchor to `¶id`s, surface in AnnotationsPane and the review right pane, and get reply/resolve machinery free. ⚠️ Annotation schema history (v2/v3) says schema changes ship Mac+phone paired; the field is additive-optional so the phone likely needs only tolerant decode (ADR 0015), but the plan must verify against the phone's actual decoder and pair the release if required.

## 3. Review mode (Mac editor)

When translations exist for a doc, a language picker appears in the editor chrome; selecting a language enters translation-review mode:

- Editor surface shows the `TranslatedDocument` render, **read-only** — editing disabled at the coordinator level so no ops can be emitted. This is a display-mode presentation, **not** a text-sync path: it must not become a 4th `applyExternalText` caller (tripwire 7).
- Gutter badges mark stale paragraphs; missing paragraphs show source text dimmed as placeholder.
- Clicking a paragraph drives the right pane (established ⌘⌥ mode-swap pattern, ADR 0005): source text + open translation queries with a reply box.
- Exiting review mode returns to the normal editing surface unchanged.

## 4. Publish

**Edition selection is per-compile, not config mutation.** The `compile` MCP tool (and the in-app publish flow) gains an optional `language` parameter. The shared `config.json` is never rewritten per edition.

**`PublishConfig` additions (all additive, ADR-0015-tolerant):**

- `language_overrides: {<lang>: {metadata…, filename bits}}` — mirrors the existing `epub_overrides` pattern. A Spanish compile deep-merges `language_overrides.es` over the base config, giving the edition its own title/author/front-matter fields without touching shared state.
- `{language}` token in `filename_template` (empty for source-language compiles) so edition outputs don't collide.
- **Interaction with the existing `metadata.language` field** (EPUB dc:language, defaults `"en"`): when compiling with `language: es`, the effective dc:language becomes `es` unless `language_overrides.es.metadata.language` explicitly says otherwise. The two never silently disagree.

**`Publication` gains `language: String?`** so the publication history records which edition each artifact is.

**AST substitution:** when `language` is set, `ProjectASTBuilder` resolves each paragraph through `TranslationDeriver` and re-parses the translated source-form text through the same block/inline grammar.

**Coverage gate (blocking):** before emission, any stale or missing paragraph fails the compile with a report grouped by piece, listing `¶id`s and statuses — the exact work-list for `write_translation`. `allow_stale: true` lets proofs through: stale paragraphs use their last translation, missing paragraphs fall back to source text, both loudly itemized in the compile result.

**Fountain element-drift check (warning tier):** for screenplay pieces, re-tokenize the translated document and diff the element-type sequence against the source's. A translated action line that comes back ALL-CAPS silently becomes a character cue; a slugline that loses its recognized stem stops being a scene heading. Text-level staleness can't see this; the tokenizer diff can. Warnings ride the compile result (and the gate report), non-blocking.

**Language-suffixed template files:** when compiling `language: es`, template-file resolution prefers a language-suffixed variant **where present**, falling back to the base file. The resolution set is the per-piece `style_file` includes plus the staged top-level templates (`template.tex`, `frontmatter.tex`, and the EPUB stylesheet): `pieces/october-passed-me-by.es.tex` over `pieces/october-passed-me-by.tex`, `frontmatter.es.tex` over `frontmatter.tex`. Editions get their own templates without mutating shared ones. Boundary drawn honestly: **the gate certifies paragraph coverage; template text is Claude's per-edition job** (the skill, §7, says so explicitly). The existing `LaTeXSafeFilename` injection guard applies to suffixed names identically; per-piece styles stay inside their `\begingroup…\endgroup` scope (ADR 0013).

## 5. Error handling

- Unknown language tag → loud regex-validation error.
- `write_translation` with unknown `¶id`s → whole call fails, bad ids listed.
- Orphaned units → skipped in derive, counted in `translation_status`.
- iCloud: per-device filenames make concurrent-append loss structurally impossible; LWW by opId, no wall-clock dependence.
- Compile with `language` set but zero translation units → gate fails with "no translation layer for `<lang>`" rather than emitting a source-language book labeled as an edition.

## 6. Phone

Out of scope as a surface in v1. The store syncs (it lives under `.maugham/`); the phone ignores it. The phone must decode-tolerate the annotation `language` field (verify + pair per §2).

## 7. Procedure surface (the skill)

A `translation-pass` skill served through the existing SEP-2640 / `get_help` surface (bundled `docs/skills/`), written intent-first per the skill-authoring feedback. It carries the loop and the conventions:

- Loop: `translation_status` → `read_translation` filtered to stale/missing → batch `write_translation` → compile gate → repeat until the gate passes.
- Conventions: identity-translate chrome with `verbatim: true`; preserve inline markers and speaker labels (construct parity); respect per-piece style contracts and author `.es.tex` variants for language-coupled templates; raise voice/register decisions (vos/tú, formal/informal) as `add_query` annotations rather than guessing.

## 8. ADR

This ships with a new ADR covering: the separate derived-store class (translation layer as the second Claude-parallel data plane after annotations), derived-never-stored freshness with server-stamped hashes, the publish coverage gate, and the language-suffixed template resolution rule.

## 9. Testing

- **Core:** store round-trip; per-device merge LWW (incl. tombstones); deriver alignment; staleness hash semantics incl. trailing-whitespace normalization and anchor-stripping; orphan handling; verbatim flag round-trip.
- **MCP:** per-tool tests (write incl. all-or-nothing failure + construct-parity warnings + verbatim; read incl. status filter; status counts); tools-list count tests (the "new MCP tool breaks ≥3 tools-list tests" lesson); tripwire-20 compliance of the write-time source resolution.
- **Publish:** coverage-gate block + `allow_stale` fallback itemization; AST substitution re-parse; `{language}` filename token; `language_overrides` deep-merge incl. dc:language interaction; language-suffixed template resolution incl. fallback and injection guard; Fountain element-drift warning; EMISSION byte-gate unchanged for source-language compiles.
- **Editor:** review mode emits zero ops; mode exit restores editing; `applyExternalText` caller census unchanged.
- **Integration:** edit source → paragraph flips stale → retranslate → fresh → compile passes; the *Playlist, Volumen Uno* acceptance run via `mcp__maugham_test__*` + `read_publication_page` as pre-smoke.

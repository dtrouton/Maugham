# Translation completeness — the orphan path becomes real, the status becomes whole

**Date:** 2026-08-09
**Source:** Issue #26 (sweep findings M1+M2 [Medium] and T1–T3 [Low], `docs/superpowers/notes/2026-07-26-sweep.md`)
**Decided with Denver:** all five findings in one branch; M1 resolved by BUILDING the delete path and orphan surface (not YAGNI-deleting the tombstone machinery).

## 1. Problem

1. **M1** — `TranslationRecord` documents `text == nil` as a tombstone and `TranslationStore.latestByParagraph`/`loadMerged` implement tombstone removal, but nothing can create one: `write_translation` requires exactly one of `text`/`verbatim: true`, and both paths persist non-nil text. When a source paragraph is deleted its translation is orphaned — counted (`orphan_count`) but never surfaced or purgeable, violating "every data type needs a UI surface for inspection/action."
2. **M2** — `translation_status` derives its language set purely from translation filenames, then buckets `open_queries` only within those languages. A translator who asks (`add_query(language: "fr")`) before writing any `fr` translation is invisible and uncounted — exactly the "ask first, translate later" workflow the `language` query-tag was added to support.
3. **T1** — `write_translation`'s per-entry append loop can fail mid-batch, leaving a partial write despite the tool's "nothing is written" contract.
4. **T2** — the "translated text equals source → mark verbatim" advisory compares against the RAW source still carrying `<!--t-XXXX-->` anchors, so it never fires on anchored paragraphs — the lines it exists for.
5. **T3** — `TranslationStore.languages(forDocId:)` does positional string surgery on filenames with no component-count guard.

## 2. Design

### 2.1 M1 — the delete path (write side)

`write_translation`'s per-entry validation widens to **exactly one of** `{text, verbatim: true, delete: true}` (the existing two-way exclusivity check becomes three-way; two-or-more or zero still rejects the batch). A `delete` entry persists a `TranslationRecord` with `text: nil` — the tombstone `latestByParagraph` already honors; no store or schema change.

**The unknown-id rule bends for delete, deliberately:** the existing "unknown paragraph id rejects the whole batch" validation applies to `text`/`verbatim` entries only. A delete entry's paragraph id is NOT checked against the current paragraph state — an orphan by definition names a paragraph that no longer exists, and deleting a live paragraph's translation is also legal (Claude retracting). A delete of an id with no existing translation record is a no-op tombstone (harmless, idempotent — append-only newest-wins absorbs it).

Tool description updated to document the third form and the exemption. Param widening only; the MCP tool count stays 55 (`DocSyncTests`).

### 2.2 M1 — the orphan surface (pane side)

`TranslationReviewPane` gains an **Orphans** section beside its source and queries sections, following the pane's existing testable-helper discipline (its header: the cursor→paragraph mapping and open-query filter are unit-testable pure helpers; the orphan list derivation joins them). Each row: the orphaned paragraph id and the stale translated text, with a per-row **Remove**; the section header carries **Remove All**. Both write tombstone records through the same `TranslationStore` append path the rest of the Mac side uses — not through MCP. Removal is immediate (no confirmation sheet: the data is derived-stale by definition, recreatable by Claude, and tripwire 11's delete-and-recreate spirit applies); the section disappears when empty. `translation_status.orphan_count` remains the summary number and now decreases as orphans are purged.

### 2.3 M2 — the query-first language row

`translation_status` unions its filename-derived language set with the distinct `language` tags found on open `.query` annotations, in BOTH paths (project-wide and explicit `document_id`). A query-only language's row reports its real shape: zero/absent coverage numbers, live `open_queries` count. No new fields — existing rows, wider membership.

### 2.4 T1 — atomic batch

Build the full `[TranslationRecord]` for the batch first, then persist with a single append call (one write, one fsync boundary — whatever `TranslationStore`'s append shape allows; if the store only appends single records, add a batch append that writes all lines in one file operation). The tool description's "nothing is written" becomes true for I/O failures, not only validation failures.

### 2.5 T2 — the advisory fires on anchored paragraphs

The equals-source comparison normalizes both sides the way the freshness hash already does (`MarkdownDisplayFilter.stripAnchors` — the ONE canonical stripper; do not add a fourth variant). A genuine verbatim copy of an anchored paragraph now triggers the reminder.

### 2.6 T3 — filename parsing guarded

`languages(forDocId:)` parses the fixed-position tail segments (`<language>.<deviceSlug>.jsonl`) from the RIGHT and asserts the expected component count, so a docId that is a dotted prefix of another cannot cross-match. Behavior identical for every well-formed filename.

## 3. Testing

- **Delete round-trip:** write → tombstone on disk → derived state drops the key → orphan absent from the pane's list model and `orphan_count` decremented.
- **Delete exemption:** a batch mixing text entries (validated) and delete entries with unknown/orphaned ids (exempt) succeeds; a text entry with an unknown id still rejects the whole batch — including its delete siblings (atomicity).
- **Idempotent delete:** tombstoning a never-translated id is accepted and derivation is unchanged.
- **Pane model:** orphan list derivation unit-tested pure (per the pane's own pattern); Remove All emits one tombstone per orphan.
- **M2:** query-first language appears with `open_queries` count and no coverage; both paths; a language with files AND queries is not double-counted.
- **T1:** an append failure injected mid-batch leaves zero new records (or: the batch-append seam is exercised so the single-write property holds structurally).
- **T2:** anchored paragraph + verbatim copy → advisory fires; non-verbatim anchored → silent.
- **T3:** adversarial filenames (dotted docId prefixes, wrong component counts) parse correctly or are skipped, existing well-formed set unchanged.
- Paragraph-id literals in tests use the 4-char `[0-9a-hjkmnp-tv-z]` alphabet (tripwire 8).

## 4. Out of scope

- Phone surfaces (translation is MaughamCore-shared, Mac-consumed; no phone consumer yet — tripwire 19 owes nothing until one exists).
- Any new MCP tool; any schema/version change (tombstones are additive records in the existing per-device JSONL).
- The three-anchor-strip-variant consolidation beyond T2's reuse of the canonical stripper (the sweep's duplication watch, recorded there).
- MCP-side orphan purge UX (`write_translation delete` suffices; the pane is the writer's surface).

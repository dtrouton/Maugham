# Translation Completeness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the translation layer's documented data model real — tombstones writable, orphans visible and purgeable, the status whole, the batch atomic (issue #26: M1+M2, T1–T3).

**Architecture:** `TranslationStore` gains a single-write batch append (T1) and its tombstone path becomes reachable via `write_translation`'s new third entry form `delete: true` (M1 write side); `TranslationReviewPane` gains an Orphans section driven by a pure list-derivation helper (M1 surface); `translation_status` unions query-tag languages (M2); the verbatim advisory compares canonical-stripped forms (T2); filename parsing anchors from the right (T3).

**Tech Stack:** Swift / XCTest. Core changes in `Packages/MaughamCore` (run its own `swift test` too); Mac scheme for tools + pane.

**Spec:** `docs/superpowers/specs/2026-08-09-translation-completeness-design.md` — read first; §2.1's unknown-id exemption rules are exact.

## Global Constraints

- **TDD** per task; RED evidence in reports.
- **Paragraph-id literals in tests: 4-char `[0-9a-hjkmnp-tv-z]` or `ParagraphID.mint()`** (tripwire 8 — these tests cross the `.md`↔op-log boundary).
- MaughamCore is Apple-frameworks-only; anything cross-module is `public`. After touching `Packages/MaughamCore`, run BOTH `swift test --parallel --package-path Packages/MaughamCore` AND the Mac scheme class runs (two independent schemes).
- No new MCP tools (count stays 55, `DocSyncTests`); no schema/version change; tombstone = existing `TranslationRecord` with `text: nil`.
- `MarkdownDisplayFilter.stripAnchors` is the ONE stripper (T2 must reuse it; adding a variant is the defect the sweep's duplication-watch names).
- Phone untouched. No `gen.sh` needed unless a new file is created (Task 5 creates none if the pane's tests join an existing file — implementer confirms; if a new test file is created, `./gen.sh` once).
- Fast loop `./scripts/test.sh`; single class `-only-testing:MaughamTests/<Class>`; core package via `swift test`. **Full gate `./scripts/test.sh full` in Task 6.**
- Commit per task; end bodies with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Core — batch append (T1) + tombstone reachability groundwork

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/TranslationStore.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/TranslationStoreTests.swift`

**Interfaces:**
- Produces: `public static func appendBatch(_ records: [TranslationRecord], forDocId: String, language: String, in projectURL: URL) throws` — serializes ALL records to JSONL lines and performs ONE file write (single append operation; a failure writes nothing). Task 2 calls this. (Read the existing single `append`'s exact signature/parameters first and mirror its naming — if it is instance-based or differently keyed, adapt while keeping the one-write property; state the final signature in your report.)
- Confirms (no change needed): `latestByParagraph` honors `text == nil` tombstones — extend its tests to pin the tombstone-after-value and value-after-tombstone orderings explicitly if not already pinned.

- [ ] Step 1: RED — tests: `test_appendBatch_writesAllRecordsInOneOperation` (write 3, read back 3, file line count 3), `test_appendBatch_failurePathWritesNothing` (unwritable target dir → throws, no partial file — construct via a read-only dir or nonexistent parent), `test_tombstoneRemovesKey_andLaterValueRestoresIt` (pin both orderings).
- [ ] Step 2: GREEN — implement `appendBatch` (build the full `Data` of all lines, one `write`/append via the store's existing file-handle pattern).
- [ ] Step 3: `swift test --parallel --package-path Packages/MaughamCore` green.
- [ ] Step 4: Commit `feat(core): TranslationStore appends a batch in one write, and the tombstone contract is pinned (T1)`.

---

### Task 2: `write_translation` — the delete form, the exemption, atomicity, and the honest advisory (M1 write + T1 + T2)

**Files:**
- Modify: `Maugham/MCP/Tools/TranslationTools.swift` (Entry struct ~:39-42; validation ~:91-115; append loop ~:120-142; advisory comparison ~:136; tool description string)
- Test: `MaughamTests/MCP/Tools/WriteTranslationToolTests.swift`

**Interfaces:**
- Consumes: Task 1's `appendBatch`.
- Produces: `Entry` gains `public let delete: Bool?`. Wire shape: `{"paragraph_id": "abcd", "delete": true}`.

- [ ] Step 1: RED — tests (expand using the file's harness):

```swift
func test_deleteEntryWritesATombstone_andDerivationDropsTheKey() { /* write text for p1; then batch with delete:true for p1; read_translation/derived state shows p1 untranslated; orphan_count unaffected for live paragraph */ }
func test_deleteOfUnknownOrOrphanedIdIsAccepted() { /* delete entry naming an id absent from the doc — succeeds; text entry naming unknown id still rejects the WHOLE batch including delete siblings */ }
func test_entryMustBeExactlyOneOfTextVerbatimDelete() { /* {text+delete}, {verbatim+delete}, {} → all invalidArgument */ }
func test_midBatchFailureWritesNothing() { /* structural: assert the tool builds records then calls appendBatch once — or inject failure if the harness allows; at minimum assert the single-call shape via file line-count after a validation-passing batch */ }
func test_verbatimAdvisoryFiresOnAnchoredParagraph() { /* paragraph with an inline task anchor; entry text = the DISPLAY (anchor-free) form; advisory warning present in response */ }
```

- [ ] Step 2: GREEN — three-way exclusivity (`[hasText, isVerbatim, isDelete].filter{$0}.count == 1`); unknown-id validation loop skips `delete` entries; record building: delete → `TranslationRecord` with `text: nil` (mirror the existing record construction's other fields exactly); replace the per-entry append loop with ONE `appendBatch` call; advisory: compare `e.text` against `MarkdownDisplayFilter.stripAnchors(state.paragraphs[id])` (match how the freshness hash normalizes — read that call first and use the identical form). Update the tool's description string: the third form, the exemption, the all-or-nothing contract.
- [ ] Step 3: Class green + `-only-testing:MaughamTests/DocSyncTests` (count unchanged).
- [ ] Step 4: Commit `feat(mcp): write_translation can delete — the tombstone path becomes reachable, and the batch becomes atomic (M1w+T1+T2)`.

---

### Task 3: `translation_status` — the query-first language row (M2)

**Files:**
- Modify: `Maugham/MCP/Tools/TranslationTools.swift` (status handler ~:300-345 — BOTH the project-wide and explicit-`document_id` paths)
- Test: `MaughamTests/MCP/Tools/TranslationStatusToolTests.swift`

**Interfaces:** none new — wider row membership only.

- [ ] Step 1: RED — tests: `test_queryOnlyLanguageGetsARow` (open `.query` with `language: "fr"`, zero fr files → fr row present, `open_queries` ≥ 1, coverage fields zero/absent); `test_bothPathsSeeIt` (repeat with explicit `document_id`); `test_languageWithFilesAndQueriesNotDoubleCounted` (one row, not two).
- [ ] Step 2: GREEN — union: `let languages = Set(TranslationStore.languages(...)).union(openQueryLanguageTags)` where the tags come from the same annotation source the pane's open-query filter reads (find it via `TranslationReviewPane`'s `AnnotationFilter(kinds: [.query], statuses: [.open])` usage — derive per-doc, respecting each path's scope).
- [ ] Step 3: Class green. Commit `fix(mcp): translation_status sees a language the moment a translator asks about it (M2)`.

---

### Task 4: `TranslationStore.languages` — right-anchored parse (T3)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/TranslationStore.swift:37-50`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/TranslationStoreTests.swift`

- [ ] Step 1: RED — tests: a docId that is a dotted prefix of another (`doc.a` vs `doc.a.b` filenames) does not cross-match; wrong component counts skipped; the well-formed set parses identically to today (enumerate the existing behavior first and pin it unchanged).
- [ ] Step 2: GREEN — split the filename, take the fixed-position tail from the RIGHT (`.jsonl`, deviceSlug, language), require exact component count, prefix must equal docId.
- [ ] Step 3: `swift test` green + Mac `-only-testing:MaughamTests/TranslationStoreTests` if a Mac-side mirror exists (check; the core package is authoritative). Commit `fix(core): translation filenames parse from the right, guarded (T3)`.

---

### Task 5: The Orphans section (M1 surface)

**Files:**
- Modify: `Maugham/Views/TranslationReviewPane.swift` (new `orphansSection` beside `sourceSection`/`queriesSection` ~:107-110; a pure list-derivation helper beside the existing testable helpers at the file top)
- Test: wherever the pane's existing pure-helper tests live (grep `TranslationReviewPane` in MaughamTests; join that file — if none exists, create `MaughamTests/Views/TranslationReviewPaneOrphanTests.swift` + `./gen.sh`)

**Interfaces:**
- Consumes: `TranslationDeriver`'s `TranslatedDocument.orphans: [TranslationRecord]` (already public), Task 1's `appendBatch` (Remove All = one batch of tombstones).
- Produces: a pure helper, e.g. `static func orphanRows(from: TranslatedDocument) -> [(id: String, staleText: String)]` (drop nil-text records — a tombstone is not an orphan to show), and an action `purgeOrphans(_ ids: [String])` writing tombstone records via `appendBatch`.

- [ ] Step 1: Read the pane whole + its header's testable-helper discipline. RED — tests: `orphanRows` drops tombstones and maps text; purge emits exactly one tombstone per id in ONE batch; a purged orphan is absent from the next derivation (round-trip through a real temp store).
- [ ] Step 2: GREEN — helper + section: each row `id · staleText` with a Remove button; section header carries Remove All; **no confirmation sheet** (spec §2.2's deliberate choice — cite it in a comment); section hidden when empty. Follow the pane's existing row/section styling; tripwire 15 if a `ContentUnavailableView` is used (it shouldn't be — the section just disappears).
- [ ] Step 3: Class green + `./scripts/test.sh` fast loop (the pane touches view code). Commit `feat(views): orphaned translations become visible, and removable (M1)`.

---

### Task 6: docs + full gate

**Files:**
- Modify: `docs/guide/` translation topic (grep for the translation topic file; add the orphan-surface + delete-form sentences — docs describe what ships), `Maugham/MCP/AREA.md` (write_translation's third form — param widening, count unchanged), `docs/superpowers/notes/2026-07-26-sweep.md` (dated append-only amendments under M1, M2, T1, T2, T3 naming this branch's fixing commits — the P1–P4 amendments from #25 show the exact style)
- No new tests — doc truth + the gate.

- [ ] Step 1: The doc edits above; then sweep `grep -rn "orphan" docs/guide/ CLAUDE.md` for anything the branch made false.
- [ ] Step 2: `./scripts/test.sh full` — green required; capture counts.
- [ ] Step 3: Commit `docs: the translation layer's completed contract, recorded (issue #26)`.

---

## Post-plan (standing workflow)

- Whole-branch review (seams: Task 2's exemption × Task 1's atomicity — a rejected batch must write nothing INCLUDING its delete entries; Task 5's purge × Task 2's derivation — both must agree what an orphan is; the advisory's normalization × the freshness hash — same form, or drift returns). One fix wave max; finishing-a-development-branch.
- Update issue #26 at merge.
- Smoke (Denver): translate a paragraph, delete its source paragraph, open the Review pane → orphan visible → Remove → gone; `translation_status` before/after shows the count move; `add_query(language: "de")` with no de files → de row in status.

# Issue #43 — publish-department robustness (F-D, F-E, F-F, F-G)

**Issue:** https://github.com/dtrouton/Maugham/issues/43
**Spec authority:** the issue text as corrected below; CLAUDE.md's `Maugham/Publish/` row ("one derivation, never two answers"); `docs/guide/publish-department.md`; `Maugham/MCP/AREA.md`'s `translation_status` entry. Constitution: a surface that cannot read part of the book says so, rather than claiming the book has no editions.
**Branch:** `worktree-issue-43-publish-robustness`, off main `1143eac8`.

## Findings, re-verified 2026-08-27 (three corrections to the issue)

- **F-D (real, provenance corrected).** `EditionStatus.documentRows` (`Maugham/Publish/EditionStatus.swift:110-181`) performs a throwing `withAnnotationDocument` load at `:128-133` for EVERY manuscript document, *before* the `languages.isEmpty` skip at `:139`, plus a second throwing `currentParagraphState` read at `:160-162`. One chapter whose op-log file is present but unreadable (`OpLogStore.ReadError.unreadableFile` / `.unlistableOpsDirectory` — a missing `.md` does NOT throw, `Document+Load.swift:228`) aborts the whole loop. The desk (`DepartmentPaneHost.derive()` `:571-582`) swallows the throw and keeps stale `languages` — on first mount that is `[]`, so it draws `DepartmentDesk.noLanguagesYet`, a false claim; the `translation_status` tool (`TranslationTools.swift:302-303`) has no catch, so a raw `ReadError` escapes as a transport failure. **The issue's "amplified by the stored-role union" is wrong**: the union's languages take the I/O-free arm at `:144-159`; the unconditional load dates from P2's query widening (already recorded at `Maugham/MCP/AREA.md:80`).
- **F-E (real).** `EditionStatus.swift:104-109` ("contributes nothing") is false; `:114-118` is true.
- **F-F (real, wider than filed).** `StatementConvention.newPath` (`Packages/MaughamCore/.../StatementLookup.swift:52-54`) guards `.editionBrief(lang)` only for non-empty; `ProjectStore.createStatement` (`Maugham/Stores/ProjectStore+Statements.swift:218`) does a bare `url.appendingPathComponent(relativePath)`. Unreachable today only transitively — and **`ProjectStore.translatorRole(for:)` (`ProjectStore+ProductionRoles.swift:54-65`) is a second unvalidated choke point** that stores the tag verbatim; its three callers happen to validate first. `TranslationRecord.isValidLanguageTag` (`TranslationRecord.swift:47-50`, `^[a-z]{2,3}(-[a-z0-9]{2,8})*$`) is the tag's own vocabulary; `SafeRelativePath.resolve(_:under:)` (MaughamCore) is the house containment guard with seven production callers.
- **F-G (real, severity corrected).** `DepartmentPaneHost.addLanguage` (`Maugham/Views/Publish/DepartmentPaneHost.swift:392-407`) dedupes against derived `@State languages`; a miss falls into `nameTranslator` (`:441-447`), which is mint-then-**rename** — so a rapid second Confirm **silently renames the existing translator**, the exact hazard the host's own comment (`:382-388`) and `DepartmentRunTests.test_addingALanguageTheBookAlreadyHasChangesNobodysName` (`:1531-1563`) name. **The issue's fix ("check the manifest instead") regresses that test** — its fixture seeds `es` by translation file only, so `storedTranslator(for:)` is nil and the swap would mint-and-rename. The fix is a UNION of derived rows and live manifest.

## Global constraints

1. **One derivation, never two answers.** The desk and `translation_status` read the same `EditionStatus` result and degrade the same way; neither invents its own notion of "unreadable".
2. **Degrade, don't abort — and say so.** A per-document failure removes that document's contribution and names it; every other document's rows are complete. The failure is a fact the surface states (desk line + tool field), never a silent skip and never a false "no editions".
3. **Refuse at the choke point, not at every caller.** Path safety for statement files does not depend on callers; a planted offender (`../x`, `a/../../b`, `EN`, ``) is refused by name and nothing is created on disk.
4. **Union, not substitution**, for the Add-Language dedupe; `test_addingALanguageTheBookAlreadyHasChangesNobodysName` stays green untouched.
5. **Every refusal/degrade test has a control** (the same operation with nothing wrong still succeeds/creates/mints).
6. Pure decisions get a pure home: a static function on the host struct drivable from `DepartmentPaneTests` without mounting (`needsTranslatorName`/`openBrief`'s shape).
7. Tripwires 8/13/23; no `try?` that swallows a class of error broader than the one being degraded — catch, record the reason, continue.
8. `./scripts/test.sh` per task; full gate once before merge. CLAUDE.md rule 10: docs a task falsifies are corrected in that task's commit. Prose counts are forbidden — name things, don't count them.
9. Tool wire text (`TranslationStatusTool.description`) and `Maugham/MCP/AREA.md` are updated in the task that changes the response.

## Task 1 — F-D + F-E: one unreadable chapter degrades to a named skip

**Files:** `Maugham/Publish/EditionStatus.swift`; `Maugham/Views/Publish/DepartmentPaneHost.swift` (+ `DepartmentPane.swift`/`DepartmentDesk` where the line is drawn); `Maugham/MCP/Tools/TranslationTools.swift`; `Maugham/MCP/AREA.md:80`; `docs/guide/publish-department.md` (Languages paragraph). Tests: `MaughamTests/DepartmentPaneTests.swift` (fixture `makeProject()` `:570-616`, `toolRows` `:645-652` is the desk↔tool agreement test), `MaughamTests/MCP/Tools/TranslationStatusToolTests.swift` (`makeHarness()` `:21-70`), and the unloadable-doc primitive from `MaughamTests/OpLog/ReadOnlyRecoveryTests.swift:21-34` (a DIRECTORY squatting the op-log file path).

1. In `EditionStatus`, add
   ```swift
   /// A manuscript document the walk could not open. Its rows are missing
   /// from the report and this says so; nothing else about the book is
   /// affected (issue #43, F-D).
   struct UnreadableDocument: Equatable, Sendable {
       let documentId: String
       let title: String
       /// The underlying error's own sentence — `localizedDescription`.
       let reason: String
   }
   struct Report: Equatable, Sendable {
       var rows: [LanguageRow]
       var unreadable: [UnreadableDocument]
   }
   ```
   `languageRows(in:projectURL:)` returns `Report`; it no longer throws for a per-document failure (keep `throws` only if something outside the per-document loop genuinely can throw — say which in the report, else drop it). Inside `documentRows`' loop, wrap BOTH per-document reads (`withAnnotationDocument` at `:128-133` and `currentParagraphState` at `:160-162`) in one `do { … } catch { unreadable.append(...); continue }` per document — any error class (a `ReadError`, an `MCPError.invalidArgument` for a manifest row with no path) degrades that document. Title from the manifest item (fall back to the id). The fold `languageRows(from:in:)` (`:201-224`) is unchanged: stored-translator rows still appear even when every document failed.
2. **F-E:** rewrite `:104-109` so it states the role-union behaviour `:114-118` describes (a document with no file and no query still contributes a zero-row for every stored translator language; only with NO reason at all does it contribute nothing) — and note in the same comment that the per-document load is unconditional and dates from the query widening, not the role union (so the next sweep doesn't re-derive the wrong provenance).
3. **Desk:** `derive()` stores `report.rows` in `languages` and `report.unreadable` in a new `@State`; `DepartmentDesk`'s Languages section draws one standing line per unreadable document ABOVE the rows — "Couldn't read <title>: <reason>" — in the shape of `PublishPreviewCentre.Notice` (orange triangle, title + detail; `Maugham/Views/Publish/PublishPreviewCentre.swift:56-89`), reusing that view if it takes plain strings, else a sibling in the same file. `noLanguagesYet` must NOT draw when `unreadable` is non-empty and `languages` is empty — the honest state is "couldn't read", not "no editions". The `derive()` catch that swallowed the throw (`:575-581`) goes: nothing per-document throws any more, so a remaining throw (if any) is a real fault and should reach `_departmentLog.error` AND clear `languages` rather than keep stale rows — say in the report what remains throwing, if anything.
4. **Tool:** `TranslationStatusTool.handle` emits the rows as today plus a top-level `"unreadable_documents": [{"document_id", "title", "reason"}]` (always present; `[]` when clean — the `write_translation`/`compile` `warnings` precedent is an always-present array). Update `TranslationStatusTool.description` (`TranslationTools.swift:265-278`) with one sentence describing the field.
5. Tests (TDD — RED on a squatted op-log dir first):
   - `EditionStatusTests` (create beside the existing publish tests if none exists — check `ls MaughamTests | grep -i edition`): `test_oneUnreadableChapterDegradesToANamedSkipAndTheRestOfTheBookIsComplete` — two-doc project, seed a translation file for both; squat doc B's op-log path with a directory; `languageRows` returns doc A's rows intact, `unreadable == [UnreadableDocument(documentId: B, title: B's title, reason: <non-empty>)]`; control `test_aReadableBookReportsNothingUnreadable`.
   - `DepartmentPaneTests`: extend the desk↔tool agreement path — with doc B squatted, the desk's `unreadable` and the tool's `unreadable_documents` name the same document (same derivation, GC1); and a mounted (or pure, if the desk exposes one) assertion that the "Couldn't read" line is drawn and `noLanguagesYet` is not, when the ONLY language is role-backed and the only document is squatted.
   - `TranslationStatusToolTests`: `test_anUnreadableChapterIsNamedAndTheCallStillAnswers` — squat one doc; the call succeeds; `unreadable_documents` has one entry with `document_id`/`title`/`reason`; the other doc's rows are present. Control: clean harness → `unreadable_documents == []`. Any test that pins the response's key set / a `DocSyncTests`-style description pin — update it.
6. Docs in this commit: `Maugham/MCP/AREA.md:80` — the closing sentence about the unconditional per-doc open gains "…and as of #43 one unreadable chapter degrades to a named entry in `unreadable_documents` rather than failing the call — the same fact the desk draws as a Couldn't-read line, one derivation". `docs/guide/publish-department.md` Languages paragraph: one sentence — a chapter Maugham can't read is named above the rows, and the rest of the book's editions still show.

**Commit:** `fix(publish): one unreadable chapter degrades to a named skip on the desk and in translation_status (#43 F-D, F-E)`

## Task 2 — F-F: language tags and statement paths are refused at the choke points

**Files:** `Maugham/Stores/ProjectStore+Statements.swift` (`createStatement` `:205-236`), `Maugham/Stores/ProjectStore+ProductionRoles.swift` (`translatorRole(for:)` `:54-65`), `Maugham/Stores/ProjectStore.swift` (`ProjectStoreError`). Tests: wherever `createStatement` and `translatorRole` are already tested (grep `createStatement(kind:` and `translatorRole(for:` in `MaughamTests`; likely `StatementPaneTests`/`ProjectStoreStatementTests` and `DepartmentRunTests`/`ProductionRoleTests`) — add beside them.

1. `ProjectStoreError` gains two named cases with doc comments in the file's voice: `languageTagInvalid(String)` ("a tag that is not a lowercase BCP-47-shaped tag — the same rule `TranslationRecord.isValidLanguageTag` applies to translation files; uppercase would silently miss the lowercase brief, and a path character would escape `editions/`") and `statementPathUnsafe(relativePath: String, reason: String)` (wrapping `SafeRelativePath.PathError`'s own description).
2. `translatorRole(for:)`: after the existing non-empty guard (`:56`, `productionRoleLanguageEmpty`), `guard TranslationRecord.isValidLanguageTag(trimmedLowercased) else { throw .languageTagInvalid(tag) }` — decide whether it should lowercase first (`EditionStatus.storedTranslatorLanguages` `:243-251` lowercases on read; the store should refuse rather than normalise, so an uppercase tag is refused — say so in the doc comment).
3. `createStatement`: for `.editionBrief(lang)`, the same `isValidLanguageTag` gate before `newPath`; then, for EVERY kind, replace `url.appendingPathComponent(relativePath)` at `:218` with `try SafeRelativePath.resolve(relativePath, under: url)` mapped to `.statementPathUnsafe`. Read `documentSlug(for:)`'s sanitizer and say in the report whether the `intent/<slug>.md` arm was already safe (belt-and-braces) or not (load-bearing).
4. Confirm each existing caller of the two verbs still passes (they validate upstream; nothing should change for them): `DepartmentPaneHost.addLanguage`/`nameTranslator`, `TranslatorEnvironment+Project.swift:91`, `DepartmentPaneHost.openBrief` (`:624`), `RulingPerformer.rule` (`:150-176`), `read_edition_brief` (read-only).
5. Tests (planted offenders, GC3/GC5): for each of `"../evil"`, `"en/../../x"`, `"EN"`, `" "`: `translatorRole(for:)` throws the named case and `manifest.productionRoles` is unchanged; `createStatement(kind: .editionBrief(tag), scope: .project)` throws the named case and NOTHING was created under the project (assert `editions/` absent or unchanged, and no file anywhere under the project root that wasn't there before — snapshot the tree). Controls: `"fr"` mints a role / creates `editions/fr.md`. One `SafeRelativePath` offender through a non-brief kind if any kind takes a caller-supplied segment (else say none does).
6. Docs: if `docs/guide/publish-department.md` or `Maugham/Stores/AREA.md` describes what a language tag may be, add the refusal sentence there; otherwise none.

**Commit:** `fix(publish): language tags and statement paths are refused at the choke point, not by every caller (#43 F-F)`

## Task 3 — F-G: Add Language dedupes against the desk AND the manifest

**Files:** `Maugham/Views/Publish/DepartmentPaneHost.swift`; tests in `MaughamTests/DepartmentPaneTests.swift` (pure) — `DepartmentRunTests.test_addingALanguageTheBookAlreadyHasChangesNobodysName` (`:1531-1563`) is the mounted guard and must stay green untouched.

1. Extract the decision into a static pure function on `DepartmentPaneHost`, in `needsTranslatorName`'s shape (`:280-282`):
   ```swift
   /// Whether `tag` already has a home on this book — a row the desk has
   /// derived OR a translator the manifest already stores. Both, because the
   /// derived rows can lag the manifest by one `derive()` and Confirm carries
   /// a NAME: a miss here is not a duplicate row, it is `nameTranslator`
   /// renaming somebody the writer did not mean to rename (issue #43, F-G).
   /// Drivable without mounting anything (`DepartmentPaneTests`).
   static func languageAlreadyOnTheDesk(_ tag: String, derived: [EditionStatus.LanguageRow], manifest: ProjectManifest) -> Bool
   ```
   (case-insensitive on both sides, matching `storedTranslator(for:)`.) `addLanguage` calls it at `:399-404` in place of the derived-only check; the notice text is unchanged.
2. Tests, pure, in `DepartmentPaneTests`: derived-only → true; manifest-only (a stored `.translator` role, no row) → true; neither → false; case-insensitive (`ES` vs stored `es`) → true. Then run `DepartmentRunTests` (the three mounted Add-Language tests at `:1464`, `:1506`, `:1531`) and show they pass.
3. Note in the host comment at `:382-388` that the dedupe now reads the manifest as well, and why (one clause).

**Commit:** `fix(publish): Add Language refuses a language the manifest already names, not only one the desk has drawn (#43 F-G)`

# Report foundations, plan 4: Word export and the Report profile

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a writer can make a **Report** from New Project (single document or sections) and publish it to PDF with the business starter. They can **export it to Word**, getting a native .docx that opens in Word and Google Docs without a repair prompt:
- Heading 1–3 styles, native footnotes, captions with SEQ fields, REF cross-references, native tables and embedded images;
- a bookmark per paragraph id;
- an export label and a sent copy kept for the later round trip.

Every surface that names a project's kind asks one function. The Report profile and its switches can be seen and changed in Project Settings.

**Architecture:**
- **DOCX is a third publish format.** `PublishConfig.Format.docx` with a `DOCXCompiler` beside PDF and EPUB, going through the same gate (`PublishProblemGate`, `prepare(resolution:)`).
- **The OOXML is Maugham's own.** A pure body emitter writes XML from the AST and resolution, and a packager zips the parts.
- **Zip without a new process.** The zip writer and reader are Swift, using Apple's Compression framework, so there is no new process spawn and the process-launch census holds.
- **Profiles and kind names live in Core.** The Report profile already exists there (plan 1). This plan adds its creation path, its settings surface, a Report PDF starter, and `ProjectKindName`.

**Tech stack:** Swift, Foundation, Compression (raw DEFLATE), ImageIO/CoreGraphics (rasterising), SwiftUI, MaughamCore, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-19-report-foundations-design.md` §6 and §7 (and §9, §10). This plan builds on plans 1–3b, all built on local main at de1efc84. Verify their APIs in the code.

## Verified starting point (main @ de1efc84)

The controller's `plan4-survey.md` (in the plan's SDD workspace) has file:line references for every fact below.

- **`PublishConfig.Format`** has `{pdf, epub, unknown}` and a hand-written `allCases`. `PublishConfigValidator.formatError` is the refusal door (ADR 0015). There are six exhaustive dispatch switches: resolve plus compile, in each of `CompileOrchestrator.compileReserved`, `Republisher.republish` and `PreviewCompiler.preview`.
- **The tests use `"docx"` as their sample unknown format** in 7 files (`PublishFormatToleranceTests`, `CompileOrchestratorTests`, `RepublisherTests`, `PreviewCompilerTests`, `CompileToolsTests`, `PublicationToolsTests`, `DeskCompileRunnerTests`). Re-spell them as `"odt"` in the same commit that adds `.docx`.
- **Every source compile mints `next_version`, whatever its format** (`CompileOrchestrator.swift` ≈390–407, ≈929–941).
- **No Swift zip or CRC code exists.** `EPUBZipPackager` spawns `/usr/bin/zip`, and `TripwireGrepTests.processLaunchers` counts that spawn. Spec §9 says no new spawns.
- **Hard-coded MCP format lists** `["pdf","epub"]` sit in `compile`, `preview_compile`, `list_publications` and `republish`. `ExportsListView` filters its rows to pdf/epub, and the preview readers are PDF/EPUB-only.
- **Word bookmark names** must start with a letter, use only letters, digits and `_`, and be at most 40 characters. Paragraph ids and label names break these rules. Anchors are sparse, one per first node of a paragraph.
- **`ProjectProfile`/`ProjectSwitches`** decode in Core. The switch defaults come from the profile (`effectiveSwitches`), so writing `profile: .report` alone is enough. Nothing in the UI or MCP shows or sets a profile.
- **New Project** (`NewProjectSheet`) is a segmented picker over `ProjectType.allCases`, with a private `label(for:)`. `ProjectFactory.createShortStoryProject` / `createNovelProject` take no profile.
- **`PublishStarter`** has one fixed starter, installed once. MCP `initialize_publish_template` re-installs it.
- **The kind is named** today only by `NewProjectSheet` and by MCP `list_projects`/`get_metadata` (`type.rawValue`). The phone shows icons only. The tripwire-55 census is `test_projectKindAndFormatAreAskedByCapabilityNotByEquality`.
- **`.maugham/` sidecars** are classified by `MaughamSidecarPath`; `.maugham/exports/` would fall to `.unknownSidecar`. `BackupSignature` excludes some prefixes.

## Global constraints

- **Plan code is a contract.** Verify signatures, and record the disable experiment for every guard or census.
- **No new process launch.** The `TripwireGrepTests.processLaunchers` census stays as it is.
- **No third-party dependency.**
- **Tripwires:**
  - 13: no app-name literals.
  - 14: moves and deletes go through the typed mover.
  - 17: nothing written by two devices into one file.
  - 19: Mac and phone share Core.
  - 20: manuscript text comes from the op log; image reads carry `adr-0018-ok`.
  - 55: ask kinds by capability.
- **Old books stay byte-identical** in PDF/EPUB output, the novel golden, `metadata.tex` and `EMISSION.md`.
- **Valid DOCX.** Every exported part parses as XML. Content types, relationships, bookmarks, footnote ids and drawing ids all cross-check. The file imports through `NSAttributedString(…, documentType: .officeOpenXML)` without error.
- **Gates:**
  - `./scripts/test.sh only <Class>` while iterating;
  - `core` after a Core change;
  - `./gen.sh` after adding files;
  - a Release build after a `ProjectWindow.body` change;
  - the final task runs `full`, `core` and `phone`.

## Rulings this plan makes (overnight, for Denver's review)

- **R-4-1 Word exports are drafts, not versions.**
  - A DOCX compile mints a **draft number**, not a book version. It never moves `next_version`.
  - The draft number is the count of this book's sent copies plus one, derived by scanning `.maugham/exports/<book>/`, so no shared counter is needed (tripwire 17).
  - The export label is "Draft N, sent 21 Oct 2026" in the book's language words (English fallback).
  - The filename is `{title}-draft{N}.docx`.
  - The catalogue still records the export as a `Publication` with format `docx`. Its `version` field holds `draft-N`, so the four-part identity stays unique.
- **R-4-2 Images Word can't embed** (PDF, SVG) are rasterised to PNG when the DOCX is prepared. A PDF figure renders page 1 at 200 dpi through CoreGraphics; an SVG goes through ImageIO if possible, and is otherwise an `imageUnreadable` problem. So a Report with PDF charts exports to Word.
- **R-4-3 Bookmark names:**
  - paragraphs: `p_` plus the ¶id with non-legal characters mapped to `_`;
  - labels: `l_<kind>_<name>`;
  - anything longer than 40 characters is truncated to 31 plus `_` plus 8 hex digits of a hash.
  - The mapping is one function, and a census pins it.
- **R-4-4 The sent copy** lives at `.maugham/exports/<book>/<export-id>/`, where `<book>` is `book` or the imprint name, and `<export-id>` is a timestamp plus the device slug (unique per device, so no collision).
  - It contains `export.docx`, `sent.json` (`{label, draft, sentAt, language, pieces: [{pieceID, paragraphs: [{id, text}]}]}`) and nothing else.
  - The new sidecar class is `exports`.
  - `BackupSignature` excludes `exports/`, because the sent copies are reproducible history, not working state.
- **R-4-5 Where Word export lives:**
  - The desk's Compile… gets DOCX through `allCases`, so no new menu command is needed.
  - The Exports footer lists `.docx` rows (they open in the default app).
  - MCP `compile` accepts `docx`, and the MCP format enums derive from `allCases`.
  - The preview stays PDF.
- **R-4-6 New Project ▸ Report:**
  - A fifth choice in the kind picker, "Report", with a sub-choice "Single document" (short-story shape, root file named `report.md`) or "Sections" (novel shape, first section "Introduction").
  - Both write `profile: .report` and install the Report PDF starter.
  - `formats_enabled` is `["pdf","docx"]`.
  - The single-document starter suppresses the duplicate piece title after the title page.
- **R-4-7 Project Settings gets a "Report" section:**
  - Profile shown as "Report" or "None". It can be turned on or off; turning it off keeps the stored switches.
  - The four switches are toggles. "Web access" is shown but disabled, with the note "Used by the fact-checker (coming)".
  - Writes go through one store door and the manifest's `encodeForDisk`.
  - `get_metadata` reports `profile` and `switches`. No MCP setter this milestone (UI only; rule 8 is met).
- **R-4-8 `ProjectKindName.of(manifest)` lives in Core** and gives "Report" for a Report, else the type's name. It is used by:
  - `NewProjectSheet` (through a choice-level sibling);
  - MCP `list_projects`/`get_metadata`, as a new `kind` field beside `type`;
  - Project Settings (a new read-only "Kind" row).
  - The window title stays the project's title; the spec's "window title" is satisfied by the Settings row. A census bans spelling kind names outside `ProjectKindName`.
- **R-4-9 Audit C5** (a shared `OutputRenderer`) is not done. A third arm in each of the six switches is the smaller, clearer change.

## Review focus

1. **The .docx opens cleanly.**
   - A fixture report with every element passes the structural validator and imports through `NSAttributedString(.officeOpenXML)`.
   - Denver opens it in Word and Google Docs at smoke.
   - Pinned in Task 4.
2. **A Word export never moves the book's version.** After three Word exports, the next PDF is still v0.1, and Draft numbers are 1, 2, 3. Pinned in Task 5.
3. **Old projects are unchanged.** A novel's PDF and EPUB are byte-identical to before, and its manifest is not raised to 10 by opening Settings. Pinned in Tasks 2 and 7.
4. **Zip correctness.** Archives written by the Swift writer are read back by `/usr/bin/unzip -t` in a test (tests may spawn; production may not) and by the Swift reader. The reader rejects a malformed `reference.docx` without crashing. Pinned in Task 1.
5. **Report creation.** Both shapes create a project that publishes a PDF with a title page, numbered sections and lists, and that exports to Word with no problems. Screenplay plus profile is refused. Pinned in Tasks 6 and 9.

---

### Task 1: Zip writer and reader in Swift

**Files:** create `Maugham/Publish/ZipArchive.swift`; test `MaughamTests/Publish/ZipArchiveTests.swift`.

**Interfaces (produced):**
```swift
enum ZipArchive {
    struct Entry { let path: String; let data: Data; let compress: Bool }
    static func write(_ entries: [Entry], to url: URL) throws          // deflate via Compression (raw DEFLATE), CRC-32, local headers + central directory, no data descriptors, UTF-8 names, deterministic timestamps
    static func read(_ url: URL) throws -> [String: Data]               // stored + deflate; validates CRC; rejects ZIP64/encrypted/path-escape names
}
```

- [ ] **Writer and reader.**
  - Raw DEFLATE uses `compression_encode_buffer(… COMPRESSION_ZLIB)`. That produces raw DEFLATE; verify, and use the zlib wrapper only if needed.
  - Entries are written in the given order. `[Content_Types].xml` must come first for DOCX.
  - The reader refuses `..` and absolute paths.
- [ ] **Tests:**
  - Round trip.
  - `/usr/bin/unzip -t` accepts the output (a test-only spawn).
  - The reader reads a zip made by `/usr/bin/zip`.
  - CRC mismatch is rejected.
  - Path escape is rejected.
  - An empty file entry.
  - A large entry (a 5 MB image).
  - Write the planted-offender control for the process-launch census: it still passes, unchanged.
- [ ] **Commit:** run `./gen.sh`, then `./scripts/test.sh`. Commit with the message `publish: a Swift zip writer and reader`.

### Task 2: DOCX as a format, plumbed everywhere

**Files:**
- `PublishConfig.swift`, `PublishConfigValidator.swift`;
- the six dispatch switches in `CompileOrchestrator`, `Republisher` and `PreviewCompiler`;
- a new `Maugham/Publish/DOCXCompiler.swift` stub;
- MCP tool schemas (`CompileTools`, `PublicationTools`);
- `ExportsListView`;
- the seven test files.

- [ ] **The format.** Add `.docx` (raw `"docx"`) to the `Format` enum and to `allCases`.
- [ ] **Validator and dispatch.**
  - The validator accepts `.docx`.
  - `DOCXCompiler.resolve(bodies:)` resolves with images allowed: png, jpg, jpeg, gif, pdf and svg (pdf and svg are rasterised later, R-4-2).
  - Its compile arm returns `.failed` with "Word export isn't built yet" until Task 4 replaces it. That stub exists only between tasks. Tasks 4–5 complete it, and the whole-branch review checks it is gone.
- [ ] **Preview.** `PreviewCompiler` refuses DOCX with a sentence: previews are PDF.
- [ ] **MCP.** The format enums derive from `PublishConfig.Format.allCases`, with no literals. Update the descriptions.
- [ ] **Exports footer.** It lists `.docx` with a document icon.
- [ ] **Tests.**
  - Re-spell the seven test files' sample unknown format to `"odt"`.
  - Add `.docx` round-trip and case-insensitive tests.
  - Add a refusal test for preview.
  - Old books: assert a novel's PDF and EPUB outputs are byte-identical (the novel golden).
- [ ] **Commit:** run `./scripts/test.sh`, then commit with the message `publish: docx is a format; the dispatch, MCP and Exports know it`.

### Task 3: The OOXML body emitter

**Files:** create `Maugham/Publish/DOCXBodyEmitter.swift`, `Maugham/Publish/DOCXNames.swift` (R-4-3) and `Maugham/Publish/OOXMLEscape.swift`; test `MaughamTests/Publish/DOCXBodyEmitterTests.swift`.

**Interfaces (produced):**
```swift
struct DOCXBody { var documentXML: String; var footnotesXML: String; var relationships: [DOCXRelationship]; var media: [DOCXMedia] }
enum DOCXBodyEmitter { static func emit(_ ast: ProjectAST, resolution: PublishResolution, words: ElementWords, figureFiles: [String: [Int: URL]]) -> DOCXBody }
enum DOCXNames { static func paragraphBookmark(_ id: String) -> String; static func labelBookmark(_ label: ManuscriptLabel) -> String }
```

- [ ] **Mapping.** One `w:p` per node.
  - Headings use `Heading1–3`, with the resolution's number as text.
  - Paragraphs get emphasis, strong, strikethrough, underline and code runs. Code uses the `CodeChar` style.
  - Lists use `numbering.xml` references: one bullet abstract and one decimal abstract.
  - Blockquotes use the `Quote` style.
  - A scene break is a centred `* * *`.
  - Verbatim text uses the `Code` style, with line breaks.
- [ ] **Bookmarks.** Every node that has a ¶id in `nodeParagraphs` gets a `bookmarkStart`/`End` named by `DOCXNames.paragraphBookmark`. Every labelled element also gets a label bookmark. Ids are unique and balanced.
- [ ] **Tables.**
  - A native `w:tbl`.
  - `w:tblHeader` on the first row so it repeats on each page.
  - The grid matches the column count.
  - Cell alignment follows the column alignment.
  - The caption goes above the table, in the `Caption` style, as "Table " plus a `SEQ Table` field whose result is precomputed.
- [ ] **Figures.** An inline `wp:inline` drawing, sized from the image's pixels and DPI to fit the column width, with unique `docPr` ids. The caption goes below it as "Figure " plus `SEQ Figure`.
- [ ] **Footnotes.**
  - Each reference becomes `w:footnoteReference` with an id taken from `footnoteNumbers`.
  - `footnotes.xml` holds the separator (-1), the continuation separator (0) and every note.
- [ ] **Citations** print the resolved text.
- [ ] **Cross-references** are a `REF` field to the label bookmark, with a precomputed result of `Target.text` and the `\h` switch. When a cross-reference can't be resolved, print the literal.
- [ ] **References** go in a "References" heading (Heading 1, unnumbered), with entries in the `Bibliography` style.
- [ ] **Lists of figures and tables** are not emitted. Word users insert their own; this is noted in the guide.
- [ ] **Escaping.** All text goes through `OOXMLEscape`, which also drops illegal XML control characters.
- [ ] **Tests.**
  - Every arm.
  - Bookmark balance and uniqueness.
  - `DOCXNames` for digit-leading and long names.
  - A census that pins `DOCXNames` as the only bookmark spelling.
  - XML well-formedness via `XMLDocument`.
- [ ] **Commit:** run `./scripts/test.sh` and commit with the message `publish: an OOXML body emitter`.

### Task 4: The DOCX package and compiler

**Files:** `DOCXCompiler.swift` (complete it), a new `Maugham/Publish/DOCXPackage.swift`, and a new default-styles resource (`Maugham/Resources/PublishStarter/docx/styles.xml`, or inline Swift). Tests: `MaughamTests/Publish/DOCXCompilerTests.swift` and `MaughamTests/Publish/DOCXValidator.swift` (a test helper).

- [ ] **Parts.** `[Content_Types].xml` (first entry), `_rels/.rels`, `word/document.xml`, `word/_rels/document.xml.rels`, `word/styles.xml`, `word/numbering.xml`, `word/footnotes.xml`, `word/settings.xml` (footnotePr separators; no `updateFields`), `word/media/*`, `docProps/core.xml` (title, author, created), `docProps/app.xml` and `docProps/custom.xml` (the export label, R-4-1).
- [ ] **Built-in styles.** Normal, Heading1–3, Caption, Quote, Code, CodeChar, Bibliography, FootnoteText and FootnoteReference, plus table styles. The styles are restrained: Word's defaults with sensible spacing.
- [ ] **The `reference.docx` override.** If `.maugham/publish/reference.docx` exists, read it with `ZipArchive.read`, take its `word/styles.xml`, and merge it over the built-in styles. The reference wins for every style id it defines. Built-in styles it doesn't define are kept, so Caption and the others always exist.
  - A malformed reference is a warning problem, and the export falls back to the built-in styles.
  - Mark the read with `adr-0018-ok`.
- [ ] **Images.**
  - Staged per R-4-2: PDF and SVG are rasterised to PNG; other formats are copied as they are.
  - Hash-named under `word/media/`.
  - Media content types are registered in `[Content_Types]`.
- [ ] **The compiler** follows `PDFCompiler`/`EPUBCompiler`:
  - `resolve(bodies:)`, then `prepare(resolution:)`, then emit and package to the output URL.
  - Multi-body (bilingual) books: one document with the bodies in order, separated by a page break, each body's caption words in its own language.
  - The output filename follows R-4-1.
- [ ] **`DOCXValidator`** (test helper):
  - unzip with `ZipArchive.read`;
  - parse every XML part;
  - check every relationship target exists;
  - check every part has a content type;
  - check bookmark start/end pairs and name uniqueness;
  - check footnote reference ids exist;
  - check `docPr` ids are unique;
  - check table grid and cell counts agree;
  - then import with `NSAttributedString(url:options:[.documentType: .officeOpenXML])` and assert the text contains the fixture's words.
- [ ] **Tests:**
  - A fixture Report with every element passes the validator.
  - A `reference.docx` override changes the Heading1 font.
  - A PDF figure becomes a PNG.
  - A bilingual book exports.
  - A Report with an unknown key refuses (the gate).
- [ ] **Commit:** run `./scripts/test.sh` and commit with the message `publish: Word export writes a native .docx`.

### Task 5: Drafts, the export label and the sent copy

**Files:** `CompileOrchestrator.swift` (the mint rule for docx), `DOCXCompiler.swift`, a new `Maugham/Stores/SentCopyStore.swift` (a project-scope sidecar, following the Stores recipe), `MaughamSidecarPath.swift` (an `exports` class), `BackupSignature.swift` (exclude `exports/`), `PresenterRoutingTests`, and the Stores AREA layout table.

- [ ] **Mint rule (R-4-1).**
  - A docx compile never reads or bumps `next_version`.
  - It takes `draft = SentCopyStore.drafts(book:).count + 1`.
  - The `Publication.version` is `draft-N`.
  - The filename uses `-draft{N}`.
  - The mint gate keys on (imprint, `draft-N`, language, docx).
  - Republishing a docx publication re-exports the same draft content under an `-r` suffix, following the existing republish rule.
- [ ] **The export label** is "Draft N, sent <date>", with the date in the book's language (en_US_POSIX fallback). It goes into `docProps/custom.xml` as `MaughamExportLabel`, `MaughamDraft` and `MaughamBook`.
- [ ] **The sent copy (R-4-4)** is written after a successful export: the `.docx` plus `sent.json` with every piece's paragraphs (`id`, `text`) exactly as exported, and the label.
  - Writes are atomic.
  - The export id is `yyyyMMdd-HHmmss-<deviceSlug>`, where the slug comes from `DeviceSlug` (tripwire 24).
- [ ] **Sidecar and backup.**
  - `MaughamSidecarPath` classifies `.maugham/exports/**` and routes it.
  - The backup signature excludes it.
  - The presenter routing test is updated.
- [ ] **Tests:**
  - Three Word exports, then a PDF: the PDF is still v0.1, and the drafts are 1, 2 and 3 (review focus 2).
  - The sent copy's contents.
  - The label in the custom properties.
  - Two devices writing exports never collide (simulated slugs).
  - A backup is not triggered by an export.
- [ ] **Commit:** run `./scripts/test.sh`, then commit with the message `publish: Word exports are drafts with a label and a sent copy`.

### Task 6: `ProjectKindName` and its census

**Files:** a new `Packages/MaughamCore/Sources/MaughamCore/ProjectKindName.swift`, plus `NewProjectSheet.swift`, `Maugham/MCP/Tools/ProjectTools.swift` and `TripwireGrepTests.swift`.

**Interfaces (produced):**
```swift
public enum ProjectKindName {
    public static func of(_ manifest: ProjectManifest) -> String            // "Report" for a report profile, else of(type)
    public static func of(_ type: ProjectType) -> String                    // "Short Story", "Novel", "Screenplay", "Collection", "Project" for .unknown
}
```

- [ ] **The names** are written as an exhaustive switch.
- [ ] **New Project's labels** come from `ProjectKindName`.
- [ ] **MCP.** `list_projects` and `get_metadata` add `kind` (the human name), plus `profile` and `switches` (`get_metadata` only). `type` stays as it is.
- [ ] **Census.** The literals "Short Story", "Novel", "Screenplay", "Collection" and "Report" used as kind names, and `type.rawValue` in user-facing projections, may appear only in `ProjectKindName.swift`, apart from an allow-list keyed by type (`type:<Name>`). Add a planted-offender control and run the disable experiment. Expect false positives such as the word "Novel" in help text. Scope the census to code, not docs, and allow-list known non-kind uses explicitly.
- [ ] **Commit:** run `./scripts/test.sh core`, `phone` and `./scripts/test.sh`, then commit with the message `core: one function names a project's kind`.

### Task 7: The Report in New Project, and its PDF starter

**Files:** `NewProjectSheet.swift`, `ProjectFactory.swift`, `PublishStarter.swift`, a new `Maugham/Resources/PublishStarter/report/` (the template variant), `InitializePublishTemplateTool.swift`, and `TestProjectTools.swift` (MCP test tool: `report-single`, `report-sections`).

- [ ] **New Project (R-4-6).** The sheet's model is a choice list:
  - the four types plus Report;
  - the Report choice shows a segmented "Single document | Sections" control.
- [ ] **The factory.** Thread `profile:` into the short-story and novel creators. The factory writes `profile: .report` through `encodeForDisk`. Screenplay with a profile is refused in the factory (precondition plus test).
- [ ] **The Report starter.** `PublishStarter.install` reads the manifest's profile and picks the `report/` variant files.
  - `report/` overrides `template.tex` (an 11pt article with A4/letter from the locale), `frontmatter.tex` (a title page with title, subtitle, author and date; then the ToC) and `prose.tex` (`\pieceheading` suppressed for a single-document Report; restrained section styling).
  - `default-config.json` has `formats_enabled: ["pdf","docx"]`.
  - The other starter files are shared.
  - `initialize_publish_template` re-installs using the profile.
- [ ] **Tests:**
  - Both shapes create the right files, profile, starter and formats.
  - A real tectonic compile of a new single-document Report with a figure, a table and a citation succeeds and shows "Contents", "List of Figures" and "1 Introduction" (or the first heading's number) via PDFKit.
  - Screenplay is refused.
  - Old kinds are unchanged (golden: a new Novel's files are byte-identical to before).
- [ ] **Commit:** run `./gen.sh` and `./scripts/test.sh`, then commit with the message `projects: a Report in New Project, with its PDF starter`.

### Task 8: Report settings in Project Settings

**Files:** `ProjectSettingsSheet.swift`, a new `ProjectStore+Profile.swift` (the one door), and tests.

- [ ] **The door.** `ProjectStore.setProfile(_ profile: ProjectProfile?)` and `setSwitch(_ key: ProjectSwitchKey, _ value: Bool?)` (nil means "use the profile's default"). Both write through the manifest door. A novel that never touches them is never raised to schema 10 (review focus 3).
- [ ] **The Settings section (R-4-7):**
  - a Kind row from `ProjectKindName`;
  - a "Report" toggle, the profile;
  - the three switches as toggles showing their effective value, each with a "Default" reset;
  - Web access shown disabled with its note.

  Screenplay projects hide the section.
- [ ] **Tests:**
  - The door's writes and the effective values.
  - The schema floor: opening Settings and closing writes nothing, and toggling raises to 10.
  - The sheet's pure model.
  - Tripwire 15, if the sheet uses `ContentUnavailableView`.
- [ ] **Commit:** run `./scripts/test.sh` and commit with the message `settings: the Report profile and its switches`.

### Task 9: Docs, help and the full gate

- [ ] **Guides.**
  - **Publish AREA:** Map rows, plus rules for drafts versus versions, the zip being Swift, `DOCXNames`, the `reference.docx` merge and rasterising.
  - **Stores AREA:** the `exports/` layout row and the backup exclusion.
  - **Views AREA:** New Project and Settings. Use history moves to stay under the cap.
  - **Core AREA:** `ProjectKindName`.
  - **MCP AREA:** the `kind`/`profile` fields and docx.
- [ ] **User guide and help.**
  - `publishing.md`: Word export, drafts, the sent copy and `reference.docx`, described as what ships. The round trip is milestone 3, so don't promise it.
  - `getting-started.md`: Report.
  - Settings help.
  - `get_help` skills that list formats.
- [ ] **`EMISSION.md`** only if body emission changed; it shouldn't.
- [ ] **DocBudget ceilings** set to the actual counts, with reasons.
- [ ] **Full gates.** Run `full`, `core` and `phone`. Commit with the message `docs: Word export and the Report profile`.

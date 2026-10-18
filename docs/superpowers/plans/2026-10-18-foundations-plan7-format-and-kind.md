# Foundations Plan 7: Format and Kind — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a manuscript's *format* and a project's *kind* first-class types that are asked by name. Today the Markdown/Fountain decision is an extension string match repeated across Mac, phone and Core, mirrored by local two-case enums. `ProjectType` is tested with `==` at defaulted sites, so a new kind or dialect silently becomes "novel" or "prose". Separately, an output format this build does not know decodes to `.pdf` and silently compiles a second PDF. After this plan:

- one Core `DocumentFormat` decides extension, held-blank rule, help resource and icon;
- `ProjectType` answers capability questions through exhaustive Core predicates;
- an unknown publish format round-trips losslessly and is refused by name.

**Architecture:**
- **`DocumentFormat`** (new, Core, `public enum DocumentFormat: CaseIterable, Sendable { case markdown, fountain }`). It has no raw value and is not `Codable`: it is never persisted, because the file extension IS its on-disk form. It owns the extension mapping in both directions, plus the held-blank rule, the help resource name and the SF Symbol name. Each surface keeps its own renderer (the Mac's `WritingModeFactory`/`ProseMode`/`ScreenplayMode`, the phone's `MarkdownBlocks`/`FountainScript`, Publish's `ProjectAST.Mode`), but each one CHOOSES by switching exhaustively over `DocumentFormat`.
- **`ProjectType` capability predicates** (Core, beside the enum). Each is an exhaustive `switch` with no `default:`, so adding a case forces every answer at compile time. Members: `primaryFormat`, `holdsPieces`, `symbolName`, `forPromotedPiece(format:)`.
- **`PublishConfig.Format`** gains `.unknown(String)`. Decoding stays tolerant (ADR 0015), but it is now lossless, and the three production doors (compile, preview, republish) refuse it by name before any job output, snapshot, collision check or version bump.
- **Two censuses** (Mac `TripwireGrepTests`, spanning every production root including the phone and Core) keep it this way:
  - the fountain extension literal is spelled only in `DocumentFormat`;
  - no production line tests a `ProjectType` or `DocumentFormat` with `==`/`!=`/`if case`.

**Tech Stack:** Swift 5.10, SwiftUI/AppKit (Mac), SwiftUI (iOS), MaughamCore SPM package, XCTest.

**Spec:** `docs/superpowers/notes/2026-10-17-foundations-audit.md`: §2 S4, §3 findings **C1**, **C2 (fix-shape A only)** and **C6**, and §4's triage row "6. Format and kind". The audit's plan numbering shifted when the docs plan was inserted, so this is **plan 7** of the foundations milestone.

## Global Constraints

- **Behaviour-neutral for every existing project.**
  - No schema bump: `ProjectManifest.currentSchemaVersion` and the op schema are unchanged.
  - No on-disk change: no new field, file or raw value. ADR 0015 governs every unknown case.
  - Every rewritten site must answer exactly what it answers today for each `ProjectType` case, `.unknown` included, and for every extension. There are exactly two declared exceptions, each pinned by a test:
    1. **Extension case converges to case-insensitive.** The op-log truth path (`Bootstrap.swift:33`, `Document.swift:1075`, `Document+Load.swift:339`), `WritingModeFactory`, `ProjectStoreASTSource`, `TranslationCoverage` and the phone's `BinderRouting` already lowercase the extension. Five sites compare case-sensitively today:
       - `PieceRow.swift:125`
       - `RightColumn.swift:316`
       - `ProjectWindow.swift:2228`
       - `ProjectStore+CollectionPieces.swift:245`
       - `DocumentTools.swift:222`

       After this plan a hand-imported `X.FOUNTAIN`, which the op log already parses as Fountain, is also shown, inspected and reported as Fountain. Maugham never writes a non-lowercase extension, so no Maugham-made project changes.
    2. **C6.** An unknown output format is refused by name instead of compiling a PDF, and it re-encodes as itself instead of as `"pdf"`.
- **One home per decision (tripwire 19).** Anything Mac and phone both ask (format by extension, held-blank rule, format icon, project-kind icon) lives in Core once. The phone's two identical `ProjectType` symbol switches (`ProjectPickerSheet.swift:124-134`, `ReadIcons.swift:10-17`) become one Core property.
- **No `default:` in any new switch over `DocumentFormat`, `ProjectType` or `PublishConfig.Format`.** Exhaustiveness is the whole mechanism.
- **The per-keystroke path stays as cheap as today.** `Document.setFullText` (`Document.swift:~1075`) must derive the format with no more work than the current `url.pathExtension.lowercased()`. Never add a `URL`/`NSString` allocation there that is not already present.
- **Every manuscript load still goes through `Document.load`/`Bootstrap.run`** (hard invariant). This plan changes only how the held-blank Bool is computed, never the call shape.
- **Census conventions (plan 2):**
  - scan via `SourceTree.productionRoots` / the multi-root `grepSwift(in: [URL], …)` (`TripwireGrepTests.swift:82`);
  - allow-list entries are `type:<Type>` keys, honoured per declaration;
  - allow-lists are named `static let` dictionaries mapping key → reason, never counts in prose;
  - every census ships with a planted-offender control in the same commit;
  - every census task reports its **disable experiment**: plant a real offender in production, show the census red with its output, restore it.
- **Pin before rewriting.** Where a rewritten site has no test pinning today's answer (each task names the gap), write the characterization test FIRST, see it pass on the old code, and only then rewrite.
- **Gates:**
  - Core-touching tasks: `./scripts/test.sh core`, `./scripts/test.sh` (fast) and `./scripts/test.sh phone`.
  - Mac-only tasks: iterate with `./scripts/test.sh only <Class>…`, then run `./scripts/test.sh`.
  - Never use a bare `swift test` or a raw `xcodebuild test`. Use `pgrep -x xcodebuild`, never `-f`.
  - Run `./gen.sh` after adding any file.
- **Comments are contract plus pointer.** A rewritten site's comment names the predicate it asks. Do not narrate the old string match.
- **Do not edit `CLAUDE.md`, `docs/tripwires.md` or any `AREA.md`.** Their sweep (new tripwire rows, the Core map entry for `DocumentFormat.swift`) is listed under Finish. The ONE doc this plan edits is ADR 0015 (Task 9), because its §5 would otherwise state the opposite of the code.
- **Branch:** `claude/foundations-plan7-format-and-kind`, stacked on plan 6's head `9b1c874c` (plans 2–6 unmerged). Worktree `/Users/denver/src/Maugham-plan7`.

## Review Focus

1. **A format decision silently flips for an existing file.** For example, a `.md` treated as Fountain, or the held-blank rule changing on one of the three truth-path parses. That would split paragraphs differently and diverge the op log from the render. *Pinned by:*
   - Task 1's `DocumentFormatTests` table;
   - Task 3's characterization test: `Bootstrap.run`, `Document.load` and `setFullText` produce the same paragraph split for `.md`, `.fountain` and `.FOUNTAIN` before and after;
   - the existing `ParagraphParserHeldBlankTests`.
2. **A capability predicate answers some case differently from the `==` it replaced.** Typical cases: `.unknown` gaining Fountain, or a Collection piece's screenplay-ness read from the project instead of the piece. *Pinned by:*
   - Task 2's `ProjectTypeCapabilityTests`, a table over every case including `.unknown`;
   - the characterization tests Task 8 writes for the unpinned sites (goal indicator for a Collection's Fountain piece, `read_document.mode`, `list_scenes` on a non-screenplay).
3. **A census that passes while blind.** Typical causes: a pattern that misses the real spelling (`pathExtension == "fountain"`, `!= .collection`, `if case .collection =`), a `== .fountain` substring that also matches `.fountainBoneyard`, or a type key that allows too much. *Pinned by* the planted-offender controls in Tasks 7 and 8 and the disable experiments in their reports.
4. **An unknown output format reaches a compiler, a filename or the catalog.** Symptoms:
   - a `Title.docx` typeset by LaTeX;
   - a job, snapshot, collision verdict or version bump before the refusal;
   - a `"docx"` rewritten as `"pdf"` when `config.json` or the publications catalog is saved.

   *Pinned by:* Task 9's lossless round-trip tests (config and catalog) and Task 10's refusal tests, which assert that no snapshot, no catalog row and no version bump happened.
5. **The phone drifts from the Mac (tripwire 19).** The phone keeps its own extension switch or symbol table, or a Core change breaks the phone build. *Pinned by:* Task 6's phone tests, the Task 7 census spanning `MaughamPhone`, and `./scripts/test.sh phone` after every Core task.

## Rulings this plan makes (for Denver to confirm)

- **R1. "The local two-case format enums" are these, by name:**
  - `PieceMode` (`ProjectStore+CollectionPieces.swift:7`);
  - `SyntaxHelpMode` (`SyntaxHelpSheet.swift:4`);
  - `PieceInspectorKind` (`PieceInspector.swift:4`);
  - `MaughamCheckboxKind` (`MarkdownCheckboxTokenizer.swift:49`);
  - `ProjectAST.Mode` (`ProjectAST.swift:42`);
  - the phone's `BinderRouting.DocKind` (`BinderRouting.swift:7`).

  `StructureItemKind.document(extension: String)` (`ProjectStore.swift:16`) is a stringly cousin and retires too. `SampleProjectBuilder.Kind` and `SyntaxHelpSheet.Tab` are not formats and stay.
- **R2. `ProjectAST.Mode` is re-rooted, not retired.** It gains `init(_ format: DocumentFormat)`, and that is the only way a path becomes a mode. Its cases stay, because the publish AST is C3's to redesign and a rename now would be redone there.
- **R3. Extension matching converges to case-insensitive.** This is exception 1 in Global Constraints: the op-log truth path already decides that way, and five display/MCP sites disagreed with it.
- **R4. An unknown name inside `formats_enabled` is not a config error.** Only compiling that format is refused (Task 10), so an older build can still patch a newer build's config.
- **R5. Known output-format names are matched case-insensitively**, so a hand-typed `"PDF"` keeps compiling a PDF as it does today.
- **R6. Each census is one Mac test spanning every production root**, with no phone twin. The precedent is the device-identity censuses (`deviceIdentityRoots`, `TripwireGrepTests.swift:8110`). A twin would be a second copy of the predicate.
- **R7. C6 gets no token census** (e.g. on `?? .pdf`). `PublicationTools.swift:298`'s `params.format ?? .pdf` is a legitimate default for an *omitted* republish format. The lossless round-trip tests plus their disable experiment are the guard.

---

### Task 1: `DocumentFormat` in Core

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/DocumentFormat.swift`
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/DocumentFormatTests.swift`

**Contract** (all `public`, each a `switch self` with no `default:`):
- `enum DocumentFormat: CaseIterable, Sendable, Hashable { case markdown, fountain }`. No raw value and no `Codable`, so it can never become a wire or disk value by accident.
- `var fileExtension: String` returns `"md"` / `"fountain"`. This is the ONE place `"fountain"` is spelled (the Task 7 census).
- `init?(fileExtension: String)`: case-insensitive; `"md"` gives `.markdown`, `"fountain"` gives `.fountain`, anything else gives `nil`. This keeps the phone's current `.other` arm (`BinderRouting.swift:27-33`).
- `init?(url: URL)` and `init?(path: String)` both mean `init?(fileExtension:)` of the path extension.
- `static func ofManuscript(url: URL) -> DocumentFormat` and `ofManuscript(path: String)` return `.fountain` iff the extension is fountain (case-insensitive), otherwise `.markdown`. This is the Mac's existing default for every manuscript site.
- `var preservesHeldBlankLines: Bool` is true for `.fountain` (E1, see `Bootstrap.swift:30-35`).
- `var isScreenplay: Bool` is true for `.fountain`. It is the screenplay family's one predicate: page targets, element gutter, sluglines, screenplay fonts, Fountain element drift. A future dialect answers it explicitly.
- `var helpResourceName: String` returns `"markdown-syntax"` / `"fountain-syntax"` (today `SyntaxHelpSheet.swift:70-73`).
- `var symbolName: String` returns `"doc.text"` / `"film"` (today `PieceRow.swift:120-129`, `PieceInspector.swift:15-20`, phone `ReadIcons.swift:29-33`).

**Tests** (`DocumentFormatTests`):
- One table test over `allCases` asserting every property.
- Extension parsing: `md`, `MD`, `fountain`, `FOUNTAIN`, `Fountain`, `txt`, `""`, `markdown` (nil: the phone treats `.markdown` as `.other` today and must keep doing so).
- `ofManuscript` defaults: `txt` and no extension give `.markdown`.
- Round trip: `DocumentFormat(fileExtension: f.fileExtension) == f` for every case.

**Gates:** `./gen.sh`, then `./scripts/test.sh core`, `./scripts/test.sh` and `./scripts/test.sh phone`. This is a pure addition, so both apps must still build.

Commit: `feat(core): DocumentFormat — one home for extension, held-blank rule, help resource and icon`

### Task 2: `ProjectType` capability predicates in Core

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ProjectType.swift`, or create `ProjectType+Capabilities.swift` beside it
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/ProjectTypeCapabilityTests.swift`

**Contract** (all `public`, exhaustive, no `default:`; `.unknown` is answered explicitly in each):
- `var primaryFormat: DocumentFormat`: `.screenplay` gives `.fountain`; `.shortStory`, `.novel`, `.collection` and `.unknown` give `.markdown`. Every `== .screenplay ? "fountain" : "md"` site today gives `.unknown` and `.collection` Markdown.
- `var holdsPieces: Bool`: true for `.collection` only. It answers "the book is a flat set of independent pieces, each in its own format", which is every `== .collection` site today.
- `var symbolName: String`: the phone's mapping verbatim (`ReadIcons.swift:10-17`): `doc.text`, `book.closed`, `film`, `books.vertical`, and `questionmark.folder` for `.unknown`.
- `static func forPromotedPiece(format: DocumentFormat) -> ProjectType`: `.fountain` gives `.screenplay`, `.markdown` gives `.shortStory`. This is today's rule at `ProjectStore+CollectionPieces.swift:245`.
- The ADR 0015 doc comment on `.unknown` is unchanged. `allCases` is unchanged.

**Tests** (`ProjectTypeCapabilityTests`):
- One table over `allCases + [.unknown]` asserting each predicate.
- `forPromotedPiece` for both formats.

**Gates:** `./scripts/test.sh core`, `./scripts/test.sh` and `./scripts/test.sh phone`.

Commit: `feat(core): ProjectType answers capability questions — primaryFormat, holdsPieces, symbolName, forPromotedPiece`

### Task 3: The truth path and the renderers choose by `DocumentFormat`

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Bootstrap.swift:33`
- Modify: `Maugham/OpLog/Document.swift:1075`
- Modify: `Maugham/OpLog/Document+Load.swift:339`
- Modify: `Maugham/Editor/WritingModeFactory.swift:8-22`
- Modify: `Maugham/Publish/ProjectAST.swift:42-45`, adding an initializer
- Modify: `Maugham/Publish/ProjectStoreASTSource.swift:95-97`
- Modify: `Maugham/Publish/TranslationCoverage.swift:112`

**Contract:**
- **The three held-blank sites** become `ParagraphParser.parse(text, preservesHeldBlankLines: DocumentFormat.ofManuscript(url: url).preservesHeldBlankLines)`. Keep `ParagraphParser`'s Bool parameter. Core's parser stays format-agnostic, and its other callers (`RenderFilter.restoreComments`, default `false`) are untouched. For `Document.swift:1075` (per keystroke), confirm in the report that the new spelling does no more work than the old `pathExtension.lowercased()`.
- **`WritingModeFactory.mode(for:)` / `defaultTypography(for:)`** switch exhaustively over `DocumentFormat.ofManuscript(path:)`. Signatures are unchanged.
- **`ProjectAST.Mode`** keeps its cases (`.prose`, `.fountain`) and gains `init(_ format: DocumentFormat)`, exhaustive. `ProjectStoreASTSource.pieceRef` builds its mode through it. `Mode` is NOT renamed. See ruling R2: the publish AST is C3's to reshape, and a rename now would touch hundreds of test lines for no behaviour.
- **`TranslationCoverage`'s `isFountain`** becomes `DocumentFormat.ofManuscript(path:).isScreenplay`.

**Tests:**
- Pin first: a characterization test (new `MaughamTests/FormatTruthPathTests.swift`, or added to an existing Bootstrap/Load suite if one fits) over three fixtures: a `.md`, a `.fountain` and a `.FOUNTAIN` file, each containing a two-space held blank inside dialogue. For each, assert the paragraph count and ids that `Bootstrap.run` mints, that `Document.load` derives, and that a `setFullText` round trip keeps. The test must pass on the OLD code before the rewrite.
- `WritingModeFactory` gets a test (if none exists) asserting the mode type and typography for `x.md`, `x.fountain`, `x.FOUNTAIN` and `x.txt`.
- `ProjectAST.Mode(.markdown) == .prose` and `ProjectAST.Mode(.fountain) == .fountain`.
- Gate the EMISSION byte gate (the existing `EmissionContract` tests): output must be byte-identical.

**Gates:** `./gen.sh` (if a new test file was added), `./scripts/test.sh core`, `./scripts/test.sh` and `./scripts/test.sh phone`.

Commit: `refactor: the op log, the editor and the publish AST choose by DocumentFormat — held-blank rule spelled once`

### Task 4: Stores — `PieceMode` and the stringly document kind retire

**Files:**
- Modify: `Maugham/Stores/ProjectStore+CollectionPieces.swift`:
  - `:6-17`: delete `PieceMode`;
  - `:39-41`: `addLoosePiece`;
  - `:56-58`: slug strip;
  - `:245`: promotion type.
- Modify: `Maugham/Stores/ProjectStore.swift:15-18` (`StructureItemKind`) and `Maugham/Stores/ProjectStore+Structure.swift:38-41`
- Modify: `Maugham/Stores/ProjectFactory.swift:80-103`
- Modify: `Maugham/Views/BinderView.swift:92`, `:300`, `:432` (the `ext` builders)
- Modify: `Maugham/Views/ProjectWindow.swift:996-1010` (the two `addLoosePiece` callers)
- Modify: `Maugham/MCP/Test/Tools/TestDocumentTools.swift:24`
- Modify: every test using `addLoosePiece(…, mode:)` or `.document(extension:)`. Find them with `grep -rn "addLoosePiece(\|document(extension" MaughamTests`.

**Contract:**
- `addLoosePiece(title: String, format: DocumentFormat) async throws -> StructureItem` replaces `mode: PieceMode`. The file it writes is `<slug>.\(format.fileExtension)`, the same bytes as today.
- `StructureItemKind.document(DocumentFormat)` replaces `.document(extension: String)`. `ProjectStore+Structure` passes `format.fileExtension` to `FileNaming.nextDocumentFilename`.
- `BinderView`'s three sites pass `.document(store.manifest.type.primaryFormat)`. That also removes three `== .screenplay` sites, which Task 8 would otherwise own.
- `ProjectFactory`: the novel and short-story factories pass `.markdown`, the screenplay factory passes `.fountain`. Either change `initialDocumentExtension: String` to `initialDocumentFormat: DocumentFormat`, or pass `fileExtension` from a `DocumentFormat`. Prefer changing the parameter type, and say which in the report.
- **Slug strip (`:56-58`) must stay behaviour-identical.** Today it removes every occurrence of `".md"` and then of `".fountain"` anywhere in the basename, not only the suffix. Keep exactly that, iterating `DocumentFormat.allCases` in declaration order (`.markdown` first), and assert that order in a test. Do NOT "fix" it to `deletingPathExtension`; a different slug would change dedup.
- **Promotion (`:245`)** becomes `ProjectType.forPromotedPiece(format: DocumentFormat.ofManuscript(path: mainDocName))`. This is declared exception 1: a `.FOUNTAIN` main doc now promotes to a screenplay.

**Tests:**
- Existing `AddLoosePieceTests`, `PromotePieceTests`, `MovePieceTests` and binder tests are updated mechanically to the new spellings, with no assertion changes.
- New: a promotion of a piece whose main doc is `Piece.FOUNTAIN` yields `.screenplay` (exception 1, pinned).
- New: a slug-dedup test with a basename containing `.md` mid-name (e.g. `a.md.notes.fountain`) asserts today's exact slug.

**Gates:** `./scripts/test.sh only AddLoosePieceTests PromotePieceTests MovePieceTests` while iterating, then `./scripts/test.sh`. This is Mac-only, so the phone gate is not needed.

Commit: `refactor(stores): pieces and binder documents take a DocumentFormat — PieceMode and the extension string retire`

### Task 5: Views and editor — three local enums retire

**Files:**
- Modify: `Maugham/Views/PieceInspector.swift:4-41` (delete `PieceInspectorKind`), `:47`, `:179-197`
- Modify: `Maugham/Views/RightColumn.swift:315-322`
- Modify: `Maugham/Views/PieceRow.swift:120-129`
- Modify: `Maugham/Views/SyntaxHelpSheet.swift:4-7` (delete `SyntaxHelpMode`), `:24-38`, `:68-79`, `:162`, `:177`
- Modify: `Maugham/Views/ProjectWindow.swift:510`, `:1068-1071` (`currentSyntaxHelpMode`), `:2228`
- Modify: `Maugham/Editor/MarkdownCheckboxTokenizer.swift:45-52` (delete `MaughamCheckboxKind`), `:67`, `:72`
- Modify: the `MaughamCheckboxKind` readers: `EditorCoordinator.swift:262`, `EditorCoordinator+Typography.swift:76`, `EditorSurface.swift:85`, `ScreenplayMode.swift:269`, `EditorHost.swift:760-767`
- Modify: tests that use `kind: .prose` on `PieceInspector`, `loadContent(mode:)`, or a checkbox `kind:` (grep each spelling)

**Contract:**
- **`PieceInspector(store:pieceId:format:posture:)`** replaces `kind: PieceInspectorKind`.
  - The UI strings and ranges (`kindLabel`, `targetLabel`, `targetRange`, `targetStep`) move to a `fileprivate extension DocumentFormat` in `PieceInspector.swift`, exhaustive. They are Mac UI, so they stay out of Core.
  - `unavailableSymbol` becomes `format.symbolName`.
  - `targetSection` switches over `format`.
  - `RightColumn` passes `DocumentFormat.ofManuscript(path: path)` (exception 1).
- **`PieceRow.iconName`** for a loose piece returns `DocumentFormat.ofManuscript(path:).symbolName`. A path-less loose piece still shows `"doc.text"`, and a reference still shows `"link"`.
- **`SyntaxHelpSheet(format: DocumentFormat)`** and `static func loadContent(format:) -> [HelpBlock]`. The resource name comes from `format.helpResourceName`.
  - The sheet's `Tab` enum (`markdown`, `fountain`, `keyboard`) stays: it is tab identity, not a format, and it has a third case.
  - Its initial tab comes from an exhaustive `switch format`.
  - `SyntaxHelpBlocksView` takes `format:`.
  - `ProjectWindow`'s `currentSyntaxHelpMode` becomes `currentSyntaxHelpFormat: DocumentFormat`, which is `store?.manifest.type.primaryFormat ?? .markdown`. That keeps today's answer, including a Collection getting Markdown help, and removes one `== .screenplay` site.
- **`MaughamCheckboxMarker.kind: DocumentFormat`** replaces `MaughamCheckboxKind`.
  - Prose mode paints `.markdown`; `ScreenplayMode.swift:269` paints `.fountain`.
  - `EditorHost.swift:760-767`'s `switch kind` keeps both arms.
  - The `NSAttributedString` attribute value class (`MaughamCheckboxMarker`) is unchanged. Only its `kind` property's type changes, so tripwires 2, 3, 6 and 7 are untouched; reviewers should confirm.
- **`ProjectWindow.swift:2228`** (goal indicator, Collection arm) asks `DocumentFormat.ofManuscript(path:).isScreenplay` (exception 1). Leave that block's `== .collection` / `== .screenplay` sites for Task 8.

**Tests:**
- Pin first: if no test asserts the goal indicator's `isScreenplay`/page target for a Collection whose current piece is `.fountain`, add one to the suite that owns `GoalIndicatorState` (find it with `grep -rln GoalIndicatorState MaughamTests`). It must pass on the old code.
- `SyntaxHelpSheetTests` move to `loadContent(format:)`, with the same assertions.
- Checkbox flip tests (existing) stay green. Add one asserting a Fountain `todo:` checkbox paints `kind == .fountain` if none exists.
- `PieceRow`: a `.FOUNTAIN` loose piece shows `film` (exception 1).

**Gates:** iterate with `./scripts/test.sh only SyntaxHelpSheetTests InspectorPassLadderTests InspectorViewTests`, then run `./scripts/test.sh`. `ProjectWindow.body` is NOT touched (only a computed property and a helper); if it is, note it for Finish's Release build.

Commit: `refactor(views): the piece inspector, syntax help and checkboxes take a DocumentFormat — three local enums retire`

### Task 6: Phone parity — `DocKind` and the duplicated symbol table retire

**Files:**
- Modify: `MaughamPhone/Read/BinderRouting.swift:7`, `:25-33` (delete `DocKind` and `kind(of:)`)
- Modify: `MaughamPhone/Read/DocumentReaderView.swift:286-302`
- Modify: `MaughamPhone/Read/ReadIcons.swift:9-17` (delete `projectSymbol`), `:20-34`
- Modify: `MaughamPhone/Capture/ProjectPickerSheet.swift:112`, `:124-135` (delete the `extension ProjectType { var symbolName }`; Core now declares it)
- Modify: `MaughamPhone/Read/ProjectsListView.swift:92`
- Modify: `MaughamPhoneTests/BinderRoutingTests.swift:44-50`, `MaughamPhoneTests/ReadIconsTests.swift`

**Contract:**
- `DocumentReaderView`'s load switches over `DocumentFormat(url: docURL)`:
  - `.markdown` takes today's markdown arm;
  - `.fountain` takes the Fountain arm, parsed once and cached (tripwire 4 as today);
  - `nil` gives `.plain(text)`.
- `ReadIcons.structureSymbol` returns `DocumentFormat(url:)?.symbolName ?? "doc"`. The group and path-less branches are unchanged.
- Project rows read `project.manifest.type.symbolName`. There is one mapping left on the phone and none of its own.
- If a `BinderRouting.kind(of:)`-shaped helper is still wanted for tests, it must be a one-line forward to `DocumentFormat(url:)`. Prefer deleting it and moving its assertions (including `B.MD` and `.txt`) to `DocumentFormatTests` or to the phone test calling Core directly.

**Tests:**
- `BinderRoutingTests` and `ReadIconsTests` assert the same icons and kinds through the new spellings, including `.unknown` giving `questionmark.folder` and `B.MD` giving markdown.

**Gates:** `./gen.sh` (only if a test file is added or removed), `./scripts/test.sh phone` and `./scripts/test.sh`. The Mac gate matters because the Task 7 census will read the phone.

Commit: `refactor(phone): the reader and its icons ask Core's DocumentFormat and ProjectType — DocKind and a duplicated symbol table retire`

### Task 7: The fountain literal is spelled in `DocumentFormat` only — census

**Files:**
- Modify: `Maugham/MCP/Tools/DocumentTools.swift:221-225` (`ReadDocumentTool.modeFor`)
- Modify: `Maugham/Stores/ProjectStore.swift:16` (the comment, if Task 4 left it)
- Modify: `MaughamTests/TripwireGrepTests.swift` (new census plus control)
- Modify: `MaughamTests/MCP/Tools/DocumentToolsTests.swift`

**Contract:**
- **Pin first.** `DocumentToolsTests` pins only `"prose"` today (`:65`, `:428`). Add tests for the other two wire values before touching the function, and see them pass on the old code:
  - `"fountain"` for a `.fountain` path in any project;
  - `"screenplay"` for a non-Fountain path in a screenplay project.
- **`modeFor`:** an exhaustive `switch DocumentFormat.ofManuscript(path:)`. `.fountain` gives the wire string `"fountain"`. `.markdown` gives `projectType.primaryFormat.isScreenplay ? "screenplay" : "prose"`. The wire strings are MCP vocabulary and stay spelled here, under an allow-list entry with its reason. A `.FOUNTAIN` path now reports `"fountain"` (exception 1); add that test.
- **The census.** Name: `test_theFountainExtensionIsSpelledInDocumentFormatOnly`.
  - Scope: every production root, i.e. `SourceTree.productionRoots`, which covers `Maugham`, `MaughamPhone` and each `Packages/*/Sources/*`. Use the multi-root `grepSwift(in: [URL], patterns:allowed:excludeLine:extraOffender:)` (`TripwireGrepTests.swift:82`).
  - Patterns: the quoted literals `"fountain"`, `".fountain"` and `"fountain-syntax"`.
  - `excludeLine` drops lines whose trimmed text starts with `//`.
  - Allow-list: `static let fountainLiteralAllowed: [String: String]` with exactly these two entries:
    - `"type:DocumentFormat"`: the one home;
    - `"type:ReadDocumentTool"`: `read_document.mode`'s MCP wire value, pinned by `DocumentToolsTests`.
  - The failure message names the door: "ask `DocumentFormat`".
  - The patterns deliberately do not match `"fountain_boneyard"` (`Task.swift:5`, a persisted task-kind raw value). The control proves this.
- **The control.** Name: `test_theFountainLiteralCensusFiresOnPlantedOffenders`. Plant a file under `TestTemp.root` holding:
  - `url.pathExtension.lowercased() == "fountain"`;
  - `path.hasSuffix(".fountain")`;
  - `forResource: "fountain-syntax"`;
  - a `// "fountain"` comment line;
  - `case fountainBoneyard = "fountain_boneyard"`.

  Assert exactly the three code offenders are caught. Then wrap the file with `Self.declare("DocumentFormat", in:)` (`TripwireGrepTests.swift:138`), re-run with the allow-list, and assert zero offenders.
- **Disable experiment** (report it): put `== "fountain"` back into `WritingModeFactory.mode(for:)`, run `./scripts/test.sh only TripwireGrepTests`, paste the red output, then restore.

**Gates:** `./scripts/test.sh only TripwireGrepTests DocumentToolsTests`, then `./scripts/test.sh` and `./scripts/test.sh phone`.

Commit: `test(tripwire): the fountain extension is spelled in DocumentFormat only — census over Mac, phone and Core`

### Task 8: Kind is asked by capability — every `ProjectType ==` site, plus a census

**Files** (every site below was verified in this worktree; Tasks 4 and 5 already removed `BinderView.swift:92/300/432` and `ProjectWindow.swift:1070`):
- `holdsPieces`:
  - `Maugham/Stores/ProjectStore+CollectionPieces.swift:42`, `:118`, `:230`, `:699`, `:847`, `:972`
  - `Maugham/Stores/ResearchScope.swift:178`
  - `Maugham/Views/TreeSectionDerivation.swift:32`
  - `Maugham/Views/ResearchTree.swift:336`
  - `Maugham/Views/ProjectWindow.swift:993`, `:1005`, `:1017`, `:1035`, `:1094` (`BinderShell.shell(for:)`), `:1739` (`inspectorRoute`), `:1897` (`editorRoute`), `:2224`, `:2252`
- `primaryFormat.isScreenplay`:
  - `Maugham/Views/ProjectWindow.swift:2238`
  - `Maugham/Views/ProjectSettingsSheet.swift:284`, `:319`
  - `Maugham/Views/InspectorView.swift:255`
  - `Maugham/Views/BinderView.swift:426`
  - `Maugham/Views/statistics/ProjectPractice.swift:328`
  - `Maugham/Compiler/ScenePosition.swift:120`
  - `Maugham/MCP/Tools/ReferenceTools.swift:25`
  - (`Maugham/MCP/Tools/DocumentTools.swift:223` was done in Task 7)
- Modify: `MaughamTests/TripwireGrepTests.swift` (census plus control)

**Contract:**
- Each site asks the named predicate. Each must give the same answer for every `ProjectType` case, `.unknown` included. `ScenePosition`'s optional `projectType` stays optional: `projectType?.primaryFormat.isScreenplay == true`.
- Exhaustive `switch`es over `ProjectType` are NOT touched. They already force a decision per case: `TreePane(for:)` (`Models/TreePane.swift:34-39`), `ResearchScope.swift:63-73` and `:193-201`, `NewProjectSheet.swift:68-122`.
- **Pin first** where no test covers the site today:
  - `list_scenes` on a novel returns `[]` (`ReferenceTools`);
  - the settings sheet's screenplay section and font list for a screenplay vs a novel, or the pure `curatedFonts()` choice if it can be reached without mounting;
  - `ScenePosition`'s `.strongDefault` for a screenplay with no declared clause.

  Check each existing suite first (`grep` for the type name) and add only the missing pins.
- **The census.** Name: `test_projectKindAndFormatAreAskedByCapabilityNotByEquality`.
  - Scope: every production root.
  - `extraOffender` is a word-bounded regex: `(==|!=)\s*\.(screenplay|collection|novel|shortStory|fountain|markdown)\b`, plus `case\s+\.(screenplay|collection|novel|shortStory|fountain|markdown)\s*=` for `if case` / `guard case`.
  - `excludeLine` drops `//` lines.
  - Allow-list: `static let kindEqualityAllowed: [String: String] = [:]`, empty and named. A future exception must add a key and a reason.
  - The `\b` keeps `.fountainBoneyard` out. `ProjectAST.Mode`'s `.prose` is not banned, because `Mode` is now derived from a `DocumentFormat` (Task 3).
  - Before adding the census, run the regex over the tree and confirm the only hits are the sites listed above. Anything else is a site this plan missed: report it and convert it.
- **The control.** Name: `test_theKindEqualityCensusFiresOnPlantedOffenders`. Plant:
  - `store.manifest.type == .collection`;
  - `projectType != .screenplay`;
  - `if case .novel = type`;
  - `format == .fountain`;
  - `task.kind == .fountainBoneyard`;
  - `// type == .screenplay`.

  Assert exactly the first four are caught.
- **Disable experiment** (report it): revert one converted site, e.g. `InspectorView.swift:255` back to `== .screenplay`. Show the census red, then restore.

**Gates:** iterate with `./scripts/test.sh only TripwireGrepTests <the suites owning the touched sites>`, then run `./scripts/test.sh` and `./scripts/test.sh phone`.

Commit: `refactor: project kind is asked by capability — every ProjectType == site converts; census bans equality on kind and format`

### Task 9: `PublishConfig.Format.unknown(String)` — lossless, never a PDF

**Files:**
- Modify: `Maugham/Publish/PublishConfig.swift:133-148`
- Modify: every exhaustive `switch format`: `CompileOrchestrator.swift:718`, `Republisher.swift:397`, `PreviewCompiler.swift:317` (an `.unknown` arm; see the contract)
- Modify: `docs/adr/0015-persisted-schema-evolution.md`: add an amendment under Decision §5 (the `PublishConfig.Format → .pdf` clause)
- Create: `MaughamTests/Publish/PublishFormatToleranceTests.swift`
- Modify: `MaughamTests/PublishPreviewCentreTests.swift:35` (its doc comment states the old fallback)

**Contract:**
- `public enum Format: Codable, Equatable, Hashable, Sendable, CaseIterable` with cases `pdf`, `epub` and `unknown(String)`.
  - `public init(rawValue: String)` is non-failable: `"pdf"` gives `.pdf` and `"epub"` gives `.epub`, matched **case-insensitively**, which preserves today's answer for a hand-typed `"PDF"`. Anything else gives `.unknown(raw)`, with the original string kept verbatim.
  - `public var rawValue: String` returns `"pdf"`, `"epub"` or the stored string.
  - `RawRepresentable` conformance: keep it if every `.rawValue` reader compiles. Otherwise keep only the property. The report says which.
  - `init(from:)` and `encode(to:)` go through `rawValue`.
  - `allCases` is declared as `[.pdf, .epub]`, so `.unknown` never appears in `DepartmentCompileSheet`'s picker (`:73`).
  - The init never constructs `.unknown("pdf")`. That is pinned.
- **The three dispatch switches** each get an `.unknown(let raw)` arm that throws the same named refusal as Task 10's door. This is defence in depth: it is unreachable once Task 10's door stands, and it is never a `preconditionFailure` in production. This task introduces the refusal error, `PublishFormatRefusal`; Task 10 calls it at the doors. The sentence: "This Maugham can't produce '<raw>' output — it was named by a newer version of Maugham. Update Maugham to compile it. Nothing was compiled."
- **ADR 0015 amendment.** Add a dated paragraph under §5. `PublishConfig.Format` now uses the `.unknown(String)` *case* shape (like §2's op enums) instead of a safe default, for two reasons: the default re-saved as `"pdf"` (the very forward-data-loss §Context warns of), and it compiled the wrong artifact. Point at `PublishFormatToleranceTests`.

**Tests** (`PublishFormatToleranceTests`):
- **Pin the old symptom first**, as a test you then invert. On the old code, decoding `{"formats_enabled":["pdf","docx"]}` yields `[.pdf, .pdf]`.
- Decoding gives `[.pdf, .unknown("docx")]`, and re-encoding gives `["pdf","docx"]`, byte-for-byte for that array.
- `"PDF"` gives `.pdf`. `"Epub"` gives `.epub`.
- A full `config.json` round trip through `PublishConfigStore`'s write path (or `PublishConfig` encode/decode, if the store has no seam) keeps `"docx"`.
- **The publications catalog:** a `Publication` row with `"format":"docx"` decodes to `.unknown("docx")`. Appending a new row through `PublicationStore` and reloading keeps the docx row's format as `"docx"`.
- `PublishConfig.Format.allCases == [.pdf, .epub]`.
- **Disable experiment** (report it): restore `?? .pdf` in `init(rawValue:)`; the round-trip tests go red; then restore.

**Gates:** `./gen.sh`, then `./scripts/test.sh only PublishFormatToleranceTests PublishConfigTests PublishConfigValidatorTests CompileOrchestratorTests RepublisherTests PreviewCompilerTests`, then `./scripts/test.sh`.

Commit: `fix(publish): an output format this build doesn't know round-trips as itself — PublishConfig.Format.unknown, ADR 0015 amended`

### Task 10: The compile, preview and republish doors refuse an unknown format by name

**Files:**
- Modify: `Maugham/Publish/PublishConfigValidator.swift`: add `public static func formatError(_ format: PublishConfig.Format) -> ValidationError?`, called inside `validateForCompile` (`:215-231`)
- Modify: `Maugham/Publish/CompileOrchestrator.swift:263-279` (already routes `validateForCompile` errors to `.failed` with the `invalid_config:` excerpt; confirm that a dry run hits it as well)
- Modify: `Maugham/Publish/PreviewCompiler.swift:202-215` (add `formatError(format)` to the errors it already refuses on)
- Modify: `Maugham/Publish/Republisher.swift:88-93` (check `formatError(format)` before staging; throw a new `RepublishError.unproducibleFormat(String)` whose `errorDescription` is the Task 9 sentence)
- Modify: `MaughamTests/CompileOrchestratorTests.swift`, `RepublisherTests.swift`, `PreviewCompilerTests.swift`, `MCP/Tools/CompileToolsTests.swift`, `MCP/Tools/PublicationToolsTests.swift`

**Contract:**
- `formatError` returns `nil` for `.pdf`/`.epub`. For `.unknown(raw)` it returns `ValidationError(field: "format", message: <the Task 9 sentence naming raw>)`.
- **No config-level error** for an unknown entry inside `outputs.formats_enabled`. `PublishConfigStore`'s write door validates the merged config (`PublishConfigStore.swift:88`), and refusing there would stop an older build from patching any key of a newer build's config. The refusal belongs to the act of compiling that format, not to the file naming it.
- **Ordering.** The refusal must come before any format-dependent act:
  - the version-collision triple (`CompileOrchestrator.swift:~520-540`);
  - the in-flight mint gate (`~565-575`, `Republisher.swift:~278-290`);
  - `OutputFilenameBuilder` (`{ext}`);
  - the snapshot capture (`CompileOrchestrator.swift:~707`);
  - Republisher's staging (`:~95`).

  The implementer lists in the report every use of `format` that precedes the refusal in each of the three functions, and shows that none of them writes.
- **What surfaces show:**
  - **MCP `compile` / `preview_compile`:** the `failed` shape with the named sentence. No PDF.
  - **MCP `republish`:** the thrown `RepublishError` is surfaced through the tool's existing error path.
  - **`read_publication_page`** on a docx row: the existing refusal at `PublicationTools.swift:163-166` now reads `format=docx` instead of trying to rasterize a non-PDF.
  - **`list_publications` / `get_publish_config`:** the raw name, verbatim.
  - **The Department compile sheet:** never offers it (`allCases`).
  - **`DesignerBriefing`'s "Formats:" line** (`DesignerBriefing.swift:250`): lists it by its raw name.
  - **The Publish preview centre:** skips the row (format guard plus `PDFDocument` guard, `PublishPreviewResolver.swift:124-127`, unchanged).

**Tests:**
- `CompileOrchestrator.compile(format: .unknown("docx"), …)` returns `.failed`, and the diagnostic contains `docx`. Assert also: no file under the snapshot store, no new catalog row, `next_version` unchanged, and no file under `Exports/`. Repeat with `dryRun: true`.
- `PreviewCompiler.preview(format: .unknown("docx"), …)` returns errors naming `docx`, with no output file.
- `Republisher.republish(snapshotID:format: .unknown("docx"), label:)` throws `.unproducibleFormat("docx")`, and no catalog row is added.
- MCP `compile` with `"format":"docx"` returns an error payload naming docx. On the old code this compiled a PDF, so write it first, watch it fail for the right reason, then implement.
- **Edition identity:** a catalog holding a `docx` row at v1.0 does NOT block a `pdf` compile of v1.0. On the old code the docx row decoded as `.pdf` and the collision guard falsely refused (`CompileOrchestrator.swift:~525`). Pin it.
- MCP `read_publication_page` on the docx row: the refusal names `format=docx`.
- **Disable experiment** (report it): remove the `formatError` call from `validateForCompile`. The orchestrator test goes red because the dispatch arm throws instead of returning `.failed`, which proves both layers. Then restore.

**Gates:** `./scripts/test.sh only CompileOrchestratorTests RepublisherTests PreviewCompilerTests CompileToolsTests PublicationToolsTests PublishFormatToleranceTests`, then `./scripts/test.sh`.

Commit: `fix(publish): compile, preview and republish refuse an unknown output format by name — no job output, no snapshot, no version bump`

---

## Finish

1. Run `./scripts/test.sh full` and `./scripts/test.sh phone`. Both must be green. Then run a local Release build (`xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO`); the plan touches `ProjectWindow.swift`, and the Release build is cheap insurance even if `body` was not edited.
2. Whole-branch review on **opus**, with the task reports as its ledger. Name these seams:
   - **Format ↔ op log:** the three held-blank sites and `setFullText`'s cost.
   - **Kind ↔ every surface:** each converted site's `.unknown` and `.collection` answer against the base.
   - **Phone ↔ Core:** no extension switch and no symbol table left on the phone.
   - **Publish doors ↔ catalog:** refusal ordering, the lossless catalog rewrite, and the collision fix.
   - **The two censuses:** patterns, allow-lists and controls, with each disable experiment actually re-run by the reviewer on one site.

   The reviewer also greps for any new `default:` in a switch over `DocumentFormat`, `ProjectType` or `PublishConfig.Format`.
3. **Smoke** (Denver, manually), on top of the standard smoke:
   - New Collection → add a Screenplay piece → its inspector shows "Page target" and the row shows the film icon;
   - the syntax help sheet opened in a screenplay project starts on the Fountain tab;
   - phone Read tab: project and document icons unchanged.
4. **Owed at merge, not in this branch:**
   - `CLAUDE.md` and `docs/tripwires.md` gain rows for the two new censuses (fountain literal; kind/format equality);
   - the Core `AREA.md` map (plan 1) gains `DocumentFormat.swift`;
   - the Publish `AREA.md` notes `Format.unknown` and the door refusal.
5. Do not merge without Denver.

## Out of scope

- **C2(B): a `profile` on the manifest** that chooses presets and the grammar ledger. It needs Denver's product ruling (audit §4 row 7).
- **C3: the hierarchical publish AST**, including renaming or retiring `ProjectAST.Mode`. This plan only roots `Mode` in `DocumentFormat` (ruling R2).
- **C4 (ADR 0022's ledger by profile), C5 (`OutputRenderer` and the three copied dispatch switches), C7 (Provenance payload), C8 (`InlineMarker`), C9 (annotation replies), C10 (presets by profile).** C5's copies only gain an `.unknown` arm here; folding them is C5's.
- **The MCP input schemas' `"enum":["pdf","epub"]`.** Deriving them from `allCases` is a catalogue change, not a tolerance one.
- **ADR 0015 §5's other safe-default enums** (`StartOn`, `LabelSource`, inbox kinds, item types). Only `PublishConfig.Format` produced a wrong artifact; the rest degrade one row by design.
- **A census over `default:` arms in `ProjectType` switches.** There is no reliable token shape for it; the whole-branch review checks it by hand (Finish 2).
- **`SampleProjectBuilder.Kind`** (novel, screenplay seed folders) and the `SyntaxHelpSheet.Tab` enum. They are a seed-folder name and a tab identity, not formats.
- **Anything needing Denver's rulings**, e.g. whether an `.unknown` project type should open read-only, or whether non-fiction gets its own kind.

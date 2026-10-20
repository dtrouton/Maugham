# Report foundations, plan 2: publishing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a published PDF or EPUB renders tables, figures, footnotes, citations, cross-references, numbered sections, a References list and the lists of figures and tables. Every broken reference, unknown source, duplicate label or unloadable image is reported as a publish problem that names its paragraph, and the writer can jump to that paragraph.

**Architecture:** plan 1's Core grammar (`ManuscriptBlocks`, `ManuscriptInlineScanner`) becomes the publish AST builder's parser. A new project-wide **resolution pass** runs over the AST of the *whole* book, never a preview subset. It numbers, resolves and collects problems, and the two emitters read its result. A single defaulted `Source` requirement carries the research citations, switches, profile and piece paths into publishing, so the roughly 66 test conformers stay untouched. Problems ride the existing `TectonicLogParser.Diagnostic` channel, so `dry_run`, MCP and the desk get them through doors that already exist. The desk gains one list surface.

**Tech stack:** Swift, MaughamCore (Apple frameworks only), the Mac `Maugham/Publish/` area, bundled tectonic, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-19-report-foundations-design.md`, §5 (this plan), §3 (the grammar plan 1 built) and §2 D1–D13. Plan 1 is `docs/superpowers/plans/2026-10-19-report-foundations-plan1-grammar-storage.md`; never restate its API here, use it as built (survey of the built code: §"Verified starting point" below).

## Verified starting point (main @ 8ee42de8)

These are verified, so use them as they are:
- **Core (plan 1):**
  - `ManuscriptBlocks.parse(_:) -> [(block: ManuscriptBlock, lines: Range<Int>)]`.
  - `ManuscriptInlineScanner.scan(_:) -> [(marker: ManuscriptInline, range: NSRange)]` (UTF-16 ranges, never spanning `\n`).
  - `ManuscriptLabel` and `ManuscriptAttributes.split`.
  - `CitationInfo`, `ResearchItem.citation`, `[ResearchItem].citationKeys`.
  - `ProjectManifest.profile`, `.switches` and `.effectiveSwitches` (a 4-tuple).
- **`ProjectAST`** (`Maugham/Publish/ProjectAST.swift`):
  - `Section(pieceID:title:mode:nodes:anchors:)`, where anchors map a top-level node index to its ¶id and are sparse.
  - `ProseNode`: `paragraph`, `heading(level:_)`, `blockquote`, `sceneBreak`, `list`, `verbatim`.
  - `Inline`: `text`, `emphasis`, `strong`, `strikethrough`, `underline`, `code`, `wikiLink`, `lineBreak`. Fountain nodes reuse `Inline`.
- **`ProjectASTBuilder`:**
  - `PieceRef(pieceID:title:mode:displayText:paragraphs:)`.
  - `protocol Source { func orderedPieces() throws -> [PieceRef] }`.
  - `build(from:)`, `parseProse` at about :137, `mapProse` at :158 (tables and solo images degrade to literal text, pinned at `MaughamTests/ProjectASTBuilderTests.swift:449–495`).
  - The private `anchors(for:starts:stripped:)` at :90 is the only line→¶id map.
- **`InlineParser.parse`** goes through `EmphasisRunConverter.inlines(for:options:protected:)`. Protected spans must not overlap.
- **Emitters:**
  - `LaTeXBodyEmitter.emit(_:config:anchorTag:crossLinkTags:)`: headings are starred, the anchor is `p-<tag>-<¶id>`, and the prologue has `\providecommand` fallbacks.
  - `XHTMLBodyEmitter.emit(_:config:anchorTag:crossLinks:)` is called **once per section** by `EPUBCompiler.swift:129–146`.
  - `EPUBOPFWriter.sectionXHTML` declares no `xmlns:epub`.
- **PDF:**
  - The starter `template.tex` reads `\InputIfFileExists{build/metadata}{}{}` in the **preamble**. `PDFCompiler.swift:171–179` writes `build/metadata.tex` from `metadataBlock(config:label:)`.
  - The starter `preamble.tex` loads no `graphicx` or `longtable`.
  - Existing projects never get starter updates.
- **Wrappers and sample compiles:**
  - The filtered wrappers are `IncludeFilteredASTSource` and `FilteredASTSource` (`PreviewCompiler.swift:370–395`) and `SinglePieceSource` (`EmissionContract.swift:505`). They forward only `orderedPieces()`.
  - `SampleCompiler` passes a scratch dir as `projectURL`.
- **Problems:**
  - `TectonicLogParser.Diagnostic{level,file,line,message,contextLines}` uses its memberwise init.
  - The coverage gate sits in `CompileOrchestrator.compileReserved` (:704–729); the same pattern appears in `PreviewCompiler.swift:306–325` and `Republisher.swift:373`.
  - MCP encodes it in `CompileTools.encode(diag:)` (:68).
  - The desk shows only `errors.first?.message` and drops warnings (`DepartmentCompileState.swift:103–130`).
- **Revealing a paragraph:** the translation report reveals one through an `onReveal(paragraphId)` closure wired in `CentreColumn.swift:304`. Find the window's existing **source**-paragraph reveal (the one the review queue and annotations use) before writing a new one.

## Global constraints

- **Plan code is a contract, not a transcript.** The signatures named under *Interfaces* are new names this plan defines; everything else must be verified in the code before use.
- **Every new census or guard has a planted-offender control**, and the implementer runs the **disable experiment**: break the production rule on purpose, watch the test fail, restore it, and say so in the report.
- **The elements render in every project kind** (spec D-ruling "features work everywhere"). The Report profile only changes defaults and severity (R-P2-1, below).
- **Resolution runs over the whole book.** A preview, sample or section-excluding compile numbers and resolves over every publishable piece, then emits only its subset. No figure is numbered differently in a preview than in the book.
- **Output never prints "??"** (spec §5.2). A marker that cannot be resolved renders as its literal source text (`@fig:x`, `[@key]`, `[^n]`), and is a publish problem.
- **Old templates still compile.** A project whose preamble predates this plan (no graphicx, no longtable, or a redesigned template without the `build/metadata` line) compiles without a TeX error; figures and tables degrade in a defined way (Task 5).
- **Tripwires:**
  - 20: manuscript text comes from the op log through the source; image bytes are research files and carry `// adr-0018-ok:`.
  - 13: no app-name literal.
  - 12/55: exhaustive switches, never `default:` over the new cases.
- **`EMISSION.md` is generated** through `EmissionContractTests`, never hand-edited. A per-piece `style_file` stays inside its `\begingroup`.
- **Fountain pieces are untouched.** Their blocks never go through `ManuscriptBlocks`, and `FountainInline` output is byte-identical. The new `Inline` arms only appear in prose.
- **Gates:**
  - Run `./scripts/test.sh core` after a Core change.
  - Run `./scripts/test.sh` while iterating.
  - Run `./gen.sh` after adding any Mac file.
  - A real compile test calls `try await TectonicProbe.requireReady()`.
  - The final task runs `./scripts/test.sh full` and `./scripts/test.sh phone`.

## Rulings this plan makes (each costs a small, local change if wrong)

- **R-P2-1 Severity by profile.**
  - In a **Report**, the error kinds below block a versioned `compile` and `republish`; `preview_compile` and the sample compiles report them as warnings and still render.
  - In **every other kind**, all problems are warnings and nothing blocks. A novel that happens to contain `[@sarah]` must still compile.
  - Error kinds:
    - an unresolved cross-reference;
    - an unknown citation key;
    - a duplicate label;
    - a missing footnote definition;
    - a figure path outside a research folder;
    - an image that can't be read.
  - Warning kinds:
    - an unused footnote definition;
    - a duplicate footnote definition (the first wins);
    - a label on the wrong element (the label is ignored);
    - a malformed label.
- **R-P2-2 Numbering.**
  - Figures and tables are numbered 1, 2, 3 across the whole book, in binder order.
  - When `numberSections` is on, **headings** are numbered hierarchically by level across the book, so the first level-1 heading is 1, a level-2 under it is 1.1, and a level-3 is 1.1.1; deeper levels are unnumbered.
  - Piece titles are never numbered.
  - A cross-reference reads "Figure 3", "Table 2" or "Section 1.2". With `numberSections` off, `@sec:x` reads as the heading's own text.
- **R-P2-3 Footnotes** are numbered continuously across the book in both formats, with LaTeX's own counter in the PDF. A footnote label is scoped to its piece (plan 1's per-document scope), so `[^1]` in two chapters is two notes.
- **R-P2-4 Author–date.**
  - The in-text name is:
    - one author: the author string, or the part before a comma when it has one (`"Smith, Jane"` → `Smith`), so organisations stay whole;
    - two authors: "A and B";
    - three or more: "A et al.";
    - no author: the source title, else the research item's title.
  - A missing year reads "n.d.".
  - Two cited sources with the same name and year take `a`, `b`, … in References order.
  - Locators print as written: `[@k, p. 12]` → "(Smith 2026, p. 12)".
  - Several items are joined by "; " inside one pair of parentheses.
- **R-P2-5 References** lists cited sources only, sorted by in-text name (case- and diacritic-insensitive), then year, then title. It is one unnumbered section at the end of each body. A body with no citations gets no References.
- **R-P2-6 Lists of figures and tables** are emitted by the **body**, at the start of the first rendered body, when their switches are on and the book has at least one of the element. The body can reach old templates; the frontmatter can't.
- **R-P2-7 Image staging.**
  - PDF: images are copied into `.maugham/publish/build/figures/` under a content-hash name, so snapshots skip them and spaces in project paths never reach TeX.
  - EPUB: images go into `OEBPS/images/` with OPF manifest items.
  - Formats: PNG, JPEG and PDF for the PDF output; PNG, JPEG, GIF and SVG for EPUB. Any other format in that target is a "can't be read" problem.
- **R-P2-8 Translation bodies** are resolved per body, over that body's own text. A label a translator dropped is an unresolved reference *in that body*, and its problem message is prefixed `[tag]` as `TranslationCoverage` does. There is no separate marker-survival check.

## Review focus

1. **An existing novel republishes byte-identically** when it has none of the new syntax, in the LaTeX body, the XHTML body and `EMISSION.md`'s unchanged sections. Pinned in Task 2 by a golden-body test over a fixture novel captured BEFORE the builder switch.
2. **A preview of one chapter numbers Figure 7 as 7**, not 1, and a reference to a figure in an excluded chapter still resolves. Pinned in Task 4.
3. **A redesigned template without `build/metadata`** still compiles with a figure and a table in the book: the figure becomes its caption in a framed box, and the table becomes a plain `tabular`. Pinned by a real tectonic compile in Task 5.
4. **Ordinary prose stays prose in a non-Report book.** `[@sarah]`, `@fig:x` in an email-ish sentence and `[^` typed casually never block a compile; at most they are warnings. Pinned in Task 7.
5. **Problems point at the right paragraph.**
   - A problem in the 40th paragraph of chapter 3 reveals that paragraph.
   - A problem in a table cell or a footnote definition reveals the paragraph that holds it.
   - Paths that escape the project, such as `../../etc/x.png` or `/Users/x.png`, are refused before any file is read.
   - Pinned in Tasks 3, 4 and 8.

---

### Task 1: Core pieces publishing needs (table alignment, citation library and style)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ManuscriptBlocks.swift`, and `MarkdownBlockParser.swift` only to make the delimiter-row reader reachable.
- Create: `Packages/MaughamCore/Sources/MaughamCore/CitationStyle.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/CitationStyleTests.swift`, plus updates to `ManuscriptBlocksTests.swift`.

**Interfaces (produced):**
```swift
public enum TableAlignment: Sendable, Equatable { case none, leading, center, trailing }
// ManuscriptBlock.table gains alignments, one per header column:
case table(header: [String], alignments: [TableAlignment], rows: [[String]], caption: String?, label: ManuscriptLabel?)

public struct CitationLibrary: Sendable {
    public struct Entry: Sendable, Equatable { public let info: CitationInfo; public let itemTitle: String; public let url: String? }
    public init(items: [ResearchItem])            // walks children; first entry wins for a duplicate key
    public func entry(for key: String) -> Entry?
    public var keys: Set<String> { get }
}

public enum CitationStyle {
    public struct Run: Sendable, Equatable { public let text: String; public let italic: Bool }
    /// R-P2-4. `labels` comes from `disambiguated(_:)`; nil when any key is unknown.
    public static func inText(_ items: [CitationItem], labels: [String: String]) -> String?
    /// Cited entries in References order (R-P2-5), each with its in-text label ("Smith 2026a").
    public static func disambiguated(_ cited: [CitationLibrary.Entry]) -> [(entry: CitationLibrary.Entry, label: String)]
    /// "Author(s). Year. *Title*. Publisher. URL (accessed 3 March 2026)." — omitted parts drop with their punctuation.
    public static func referenceEntry(_ entry: CitationLibrary.Entry, label: String) -> [Run]
}
```

- [ ] **Alignment.**
  - Read the delimiter row (`rawLines[1]` of `MarkdownBlock.table`) into one `TableAlignment` per header column: `:--` is leading, `:-:` center, `--:` trailing, and plain `---` none.
  - Pad or truncate to the header's count.
  - Reuse the parser's private row splitter by making it `static` internal to Core; don't write a second splitter.
  - Update plan 1's pattern sites in Core tests. There is no production site outside Core (verified).
- [ ] **`CitationLibrary`.** It walks the research tree, including children, over the items it is given. Trashed items are the caller's concern, and publishing passes only live items.
- [ ] **`CitationStyle`** follows R-P2-4 and R-P2-5 exactly.
  - Sort with `compare(_:options: [.caseInsensitive, .diacriticInsensitive])`.
  - Format the accessed date with a fixed `en_US_POSIX` "d MMMM yyyy" in UTC, so output does not drift with the machine's locale or time zone.
- [ ] **Tests:**
  - every alignment form;
  - a ragged delimiter row;
  - authors `["Smith, Jane"]`, `["Gartner"]`, two authors, three authors, none (falls back to the title);
  - n.d.;
  - Smith 2026 twice → a/b in References order;
  - locator and multi-item text;
  - an unknown key → nil;
  - a reference entry with every optional part absent, so no stray ". ." appears;
  - Unicode authors ("Müller", "林").
- [ ] Run `./scripts/test.sh core` and `./scripts/test.sh phone`, then commit with the message `core: table alignment, citation library and author–date style`.

### Task 2: The AST grows the elements, and the builder reads plan 1's grammar

**Files:**
- Modify: `Maugham/Publish/ProjectAST.swift`, `ProjectASTBuilder.swift`, `InlineParser.swift`, `ElementCensus.swift`, `LaTeXBodyEmitter.swift`, `XHTMLBodyEmitter.swift` (interim arms only), `MaughamTests/Publish/ASTTranslationSubstitutionTests.swift` (flatten arms).
- Test: `MaughamTests/ProjectASTBuilderTests.swift` (the degrade pins flip), new `MaughamTests/Publish/ReportElementsASTTests.swift`, new `MaughamTests/Publish/NovelBodyGoldenTests.swift`.

**Interfaces (produced):**
```swift
// ProjectAST.ProseNode
case heading(level: Int, [Inline], label: ManuscriptLabel?)       // existing case widened; label nil for plain headings
case table(header: [[Inline]], alignments: [TableAlignment], rows: [[[Inline]]], caption: [Inline]?, label: ManuscriptLabel?)
case figure(caption: [Inline], path: String, label: ManuscriptLabel?)
// ProjectAST.Inline
case footnoteRef(label: String)
case citation([CitationItem])
case crossRef(ManuscriptLabel)
// ProjectAST.Section gains:
public var footnotes: [String: [Inline]]     // label → definition, per piece; first definition wins
public var nodeParagraphs: [Int: String]     // EVERY top-level node index → the ¶id of the paragraph it came from (dense where anchors reconcile)
```

- [ ] **Golden first.**
  - Before changing anything, capture the LaTeX and XHTML bodies of a fixture novel into test fixtures. The fixture needs headings, emphasis, lists, blockquote, verbatim, a scene break, a wiki link and a Fountain piece, but no pipe tables or `![…](…)` lines.
  - Add `NovelBodyGoldenTests` comparing against the fixtures. It must stay green through this whole plan.
- [ ] **Builder.**
  - `parseProse` reads `ManuscriptBlocks.parse(stripped)` and its line ranges in place of `MarkdownBlockParser.parseWithLineRanges`. `starts` comes from these ranges.
  - A `.footnoteDefinition` produces no node; its inlines go to `Section.footnotes`, and the node and start arrays stay aligned (the fence-tail precedent).
  - Table cells, captions and figure captions are parsed with `InlineParser.parse`.
  - `.other(block)` keeps today's `mapProse` path exactly.
- [ ] **`nodeParagraphs`.**
  - Generalise the private `anchors(...)` helper so it also yields, for every node, the ¶id of the span its start line falls in.
  - `anchors` stays exactly as before: first node only, and `ProjectASTAnchorTests` stays green untouched.
  - When the paragraphs don't reconcile, or are nil, `nodeParagraphs` is `[:]`.
- [ ] **Inlines.**
  - `InlineParser.parse` adds protected spans from `ManuscriptInlineScanner.scan` over the **same joined string** it already scans.
  - A marker overlapping a code or wiki span is dropped, and the code or wiki span wins.
  - `FountainInline` is not changed.
- [ ] **Interim emitter arms.** Every new case renders exactly the literal source text it came from, which is today's output. Make the emitters and `ElementCensus` compile with that, with no `default:`. Tasks 5 and 6 replace these arms. The point is that the build and the novel golden stay green between tasks.
- [ ] **`ElementCensus`** gains `table`, `figure`, `footnote`, `citation` and `crossReference` kinds, with labels in `label(for:)`. Check `SamplePageSelection` and `DesignerBriefing` pick them up, and update their tests' expected kind lists.
- [ ] **Flip the four degrade pins** (`ProjectASTBuilderTests.swift:449–495`) to assert the new nodes, and keep one pin proving that a table line directly after prose with no blank line stays a paragraph (the parser rule).
- [ ] **`ReportElementsASTTests`:**
  - each element;
  - a heading `{#sec:x}` whose text is stripped of the block;
  - stacked footnote definitions;
  - `[@a; @fig:x]` → a citation plus a cross-ref;
  - a marker in backticks stays code;
  - `nodeParagraphs` for a table, a figure and a footnote's host paragraph.
- [ ] Run `./scripts/test.sh` and commit with the message `publish: the AST carries report elements; the builder reads the manuscript grammar`.

### Task 3: The publish context: citations, switches, piece paths and images

**Files:**
- Create: `Maugham/Publish/PublishContext.swift`, `Maugham/Publish/FigureImageResolver.swift`
- Modify: `ProjectASTBuilder.swift` (the protocol extension), `ProjectStoreASTSource.swift`, `PreviewCompiler.swift` (both filtered wrappers), `EmissionContract.swift` (`SinglePieceSource`), `BodyPlan.swift` if its rebinding wraps sources.
- Test: `MaughamTests/Publish/PublishContextTests.swift`, `MaughamTests/Publish/FigureImageResolverTests.swift`

**Interfaces (produced):**
```swift
public struct PublishContext: Sendable {
    public var library: CitationLibrary              // live research only (not Trash)
    public var profile: ProjectProfile?
    public var switches: (numberSections: Bool, listOfFigures: Bool, listOfTables: Bool)
    public var projectURL: URL?                       // the REAL project, never a compiler's scratch dir
    public var piecePaths: [String: String]           // pieceID → project-relative manuscript path
    public static let empty: PublishContext
}
extension ProjectASTBuilder.Source {
    /// Defaulted to `.empty`: test conformers need no change.
    public func publishContext() -> PublishContext { .empty }
    /// The WHOLE book this source is a view of. Defaulted to `self`; a filtering wrapper returns its base's.
    public var resolutionScope: ProjectASTBuilder.Source { self }
}
// Both become protocol REQUIREMENTS with these defaults, so a wrapper's override dispatches dynamically.

public enum FigureImageResolver {
    public enum Outcome: Equatable { case file(URL), notLocal, unreadable(String) }
    /// `path` is relative to the piece's own file. Accepted only if it stays
    /// inside the project and inside a `research/` folder (the project's, or a
    /// Collection piece's own `pieces/<x>/research/`). The file must exist,
    /// be a regular file, and its extension must be in `allowed`.
    public static func resolve(_ path: String, piecePath: String, projectURL: URL, allowed: Set<String>) -> Outcome
}
```

- [ ] **The requirements** are declared in the protocol body, with defaults in an extension, so a wrapper's override is reached through the existential (verify with a test calling through `any Source`).
  - `IncludeFilteredASTSource`, `FilteredASTSource` and `SinglePieceSource` forward both requirements to their base.
  - Any `BodyPlan` rebinding keeps the context.
  - `ProjectStoreASTSource` (on `@MainActor`, like its conformance) builds the context from `projectStore.manifest` and `projectStore.url`; piece paths come from the same `publishablePieces()` walk.
- [ ] **The resolver:**
  - It standardises the path first, refusing an absolute path, a URL scheme (`http:`, `file:`) or an escape before touching the disk. It checks the prefix after `resolvingSymlinksInPath`.
  - It reads no bytes; it only stats the file.
  - Both the root-level `story.md` case (`../research/x.png` escapes, so it is refused) and the `manuscript/ch1.md` case (`../research/x.png` is accepted) are tested.
- [ ] **Tests:**
  - the wrapper forwarding through `any Source`;
  - a Collection piece reaching its own research folder and being refused another piece's;
  - a symlink out of research being refused;
  - a missing file;
  - a disallowed extension;
  - `SampleCompiler`'s scratch `projectURL` never being used.
  
  Planted control: a wrapper that does NOT forward makes the forwarding test fail. Run the disable experiment.
- [ ] Run `./gen.sh`, then `./scripts/test.sh`, and commit with the message `publish: the publish context reaches every source; figure paths resolve inside research`.

### Task 4: The resolution pass

**Files:**
- Create: `Maugham/Publish/PublishResolution.swift`, `Maugham/Publish/PublishProblem.swift`
- Test: `MaughamTests/Publish/PublishResolutionTests.swift`

**Interfaces (produced):**
```swift
public struct PublishProblem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case unresolvedCrossRef(ManuscriptLabel), unknownCitationKey(String), duplicateLabel(ManuscriptLabel),
        missingFootnoteDefinition(String), duplicateFootnoteDefinition(String), unusedFootnoteDefinition(String),
        labelOnWrongElement(ManuscriptLabel), malformedLabel(String), figurePathNotLocal(String), imageUnreadable(String) }
    public let kind: Kind
    public let pieceID: String
    public let paragraphID: String?        // from Section.nodeParagraphs; nil only when the piece's paragraphs didn't reconcile
    public let bodyTag: String?            // R-P2-8 prefix; nil for a single-body compile
    public func isError(profile: ProjectProfile?) -> Bool      // R-P2-1, the ONE severity table
    public var message: String { get }    // the writer's words: "Figure reference @fig:revenue has no figure with that label."
}

public struct PublishResolution: Sendable {
    public struct Target: Sendable, Equatable { public let pieceID: String; public let paragraphID: String?; public let text: String }  // "Figure 3"
    public let targets: [ManuscriptLabel: Target]
    public let headingNumbers: [String: [Int: String]]      // pieceID → node index → "1.2" (empty when numberSections is off)
    public let figureNumbers: [String: [Int: Int]]           // pieceID → node index → n
    public let tableNumbers: [String: [Int: Int]]
    public let citationText: [String: String]                // canonical joined keys+locators → "(Smith 2026a, p. 3)"
    public let references: [[CitationStyle.Run]]             // R-P2-5, cited only
    public let listOfFigures: [(number: Int, caption: [ProjectAST.Inline], target: Target)]
    public let listOfTables:  [(number: Int, caption: [ProjectAST.Inline], target: Target)]
    public let problems: [PublishProblem]
    public static func resolve(_ ast: ProjectAST, context: PublishContext, bodyTag: String?,
                               imageAllowed: Set<String>) -> PublishResolution
}
```

- [ ] **One pass over the AST** in section order.
  - It collects labels from labelled headings, tables and figures. A `fig:` label on a table is `labelOnWrongElement` and is ignored.
  - It numbers per R-P2-2 and R-P2-3.
  - It resolves every `crossRef` and `citation` inline, including inlines inside table cells, captions, list items, blockquotes and footnote definitions.
  - It checks footnote labels per piece, and resolves every figure path through `FigureImageResolver`.
  - Each problem carries the ¶id of the node it came from. For a footnote definition's problem, that is the paragraph holding the definition, which the builder records too: extend `Section` with `footnoteParagraphs: [String: String]` in this task if Task 2 didn't.
- [ ] **The whole book, then the subset.** Callers resolve `source.resolutionScope`'s AST, then emit the subset AST built from `source`. Add a helper both compilers use: `PublishResolution.forCompile(source:bodyTag:imageAllowed:)` builds the scope AST and resolves it.
- [ ] **`citationText`'s key:** define one canonical string function in this file. The emitters call the same function, so lookup can never disagree.
- [ ] **Tests:**
  - numbering across three pieces;
  - a preview subset (Figure 7 stays 7, and a reference to an excluded piece resolves);
  - `numberSections` off → `@sec:x` reads as the heading's text;
  - duplicate label → one problem, and the first label wins;
  - unknown key;
  - the a/b disambiguation reaching `citationText`;
  - an unused footnote and a missing one;
  - an image refused or unreadable;
  - severity per profile, for every kind (an exhaustive test over `Kind` that fails to compile when a kind is added);
  - a problem in a table cell naming the table's ¶id.
- [ ] Run `./scripts/test.sh` and commit with the message `publish: the resolution pass numbers, resolves and reports over the whole book`.

### Task 5: The PDF

**Files:**
- Modify: `LaTeXBodyEmitter.swift`, `PDFCompiler.swift` (image staging; the preamble additions in `build/metadata.tex`), `Maugham/Resources/PublishStarter/preamble.tex`.
- Test: `MaughamTests/LaTeXBodyEmitterTests.swift`, new `MaughamTests/Publish/ReportPDFCompileTests.swift` (real tectonic).

**Contract:**
- [ ] **`emit` gains `resolution: PublishResolution? = nil`** and `figureFiles: [String: String] = [:]`, mapping a figure's source path to its staged path relative to the template's directory. When `resolution` is nil, every new element emits its literal source (Task 2's interim). That keeps `EmissionContract`, existing tests and the novel golden unchanged.
- [ ] **The arms:**
  - **Table.** `\begin{MaughamTable}{<colspec>}…` where `MaughamTable` is a `\providecommand`-style environment fallback in the prologue.
    - When `longtable` is defined (`\ifdefined\longtable`), it is a `longtable` with the header repeated (`\endhead`) and the caption on top.
    - Otherwise it is a `table` float around a `tabular`.
    - The column spec comes from the alignments (`l`/`c`/`r`, with none treated as `l`).
    - Cells are escaped through `LaTeXEscape`.
    - The caption is `\caption{…}` with the resolved number and a `\hypertarget` for its label anchor `lbl-<kind>-<name>`.
  - **Figure.**
    - With graphicx (`\ifdefined\includegraphics`), it is a `figure` with `\includegraphics[width=\linewidth]{<staged path>}` and the caption below.
    - Without it, it is a `figure` holding `\fbox{<caption>}`.
    - The staged path passes `LaTeXSafeFilename`-style validation; staging names it `build/figures/<sha256-prefix>.<ext>`, so it always passes.
  - **Footnote ref:** `\footnote{<definition inlines>}`. Undefined → literal.
  - **Citation:** the resolved text, escaped. Unresolved → literal.
  - **Cross-ref:** `\MaughamCrossLink{lbl-<kind>-<name>}{<Target.text>}`. Unresolved → literal.
  - **Heading:** with a number, `\section*{1.2\quad Title}`, and the same text goes into its `\addcontentsline`. Its label gets a `\hypertarget`.
  - **References:** a final `\section*{References}` plus `\addcontentsline`, then entries as a hanging-indent list built only from kernel commands.
  - **Lists of figures and tables (R-P2-6):** `\listoffigures` and `\listoftables` work only through `\caption`, so emit them when switched on and non-empty, at the start of the first body, each followed by `\clearpage`.
- [ ] **Preamble additions.** When the book has a figure or a table, `PDFCompiler` appends `\usepackage{graphicx}` and `\usepackage{longtable}` to `build/metadata.tex`, each wrapped in `\IfFileExists{<pkg>.sty}{…}{}`. When the book has neither, `metadata.tex` stays byte-identical to today, and a test pins that. The starter `preamble.tex` gains both packages for new projects.
- [ ] **Staging.** Copy each resolved image into `build/figures/` with `FileManager.copyItem`, using `// adr-0018-ok: research image staged for the compile`. Never read it into memory. A copy failure becomes an `imageUnreadable` problem.
- [ ] **Tests:**
  - every arm, both with and without a resolution;
  - escaping in table cells and captions (`&`, `%`, `_`, `#`);
  - two real tectonic compiles of one fixture report (a captioned table, a figure from research, footnotes, citations, cross-refs, `numberSections`, both lists). The first uses the current starter. The second uses a template that has no `build/metadata` line, standing in for a redesigned template. Both must succeed, and the PDF's text (through PDFKit) must contain "Figure 1", "Table 1", "References" and the author–date text.
- [ ] Run `./scripts/test.sh`. The novel golden must still be green. Commit with the message `publish: the PDF renders report elements, numbering, References and the lists`.

### Task 6: The EPUB

**Files:**
- Modify: `XHTMLBodyEmitter.swift`, `EPUBCompiler.swift`, `EPUBPackage.swift`, `EPUBOPFWriter.swift`, `EPUBZipPackager.swift` (only if images need a write step).
- Test: `MaughamTests/XHTMLBodyEmitterTests.swift`, `EPUBOPFWriterTests.swift`, `EPUBCompilerTests.swift` and a new `MaughamTests/Publish/ReportEPUBTests.swift` (unzipped through `EPUBInspection`).

**Contract:**
- [ ] **`emit` gains `resolution:`, `figureFiles:`, and `labelHrefs: [ManuscriptLabel: String]`.** The hrefs map each label to `section-…xhtml#lbl-<kind>-<name>`; `EPUBCompiler` builds them from `sectionFilename(tag:index:bodyCount:)` and `resolution.targets`. When `resolution` is nil, the output is the literal interim.
- [ ] **The arms:**
  - **Table.** `<table>` with `<caption>`, a `<thead>`, and `style="text-align:…"` on cells from the alignments.
  - **Figure.** `<figure id="lbl-…"><img src="images/<hash>.<ext>" alt="<caption text>"/><figcaption>Figure n. …</figcaption></figure>`.
  - **Footnote ref.**
    - The ref is `<a epub:type="noteref" href="#fn-<n>" id="fnref-<n>">n</a>`.
    - Each section ends with its notes as `<aside epub:type="footnote" id="fn-<n>">`, numbered continuously across the book (R-P2-3).
  - **Citation:** the resolved text.
  - **Cross-ref:** `<a href="<labelHref>">Figure 3</a>`.
  - **Heading:** the number is included, and the label is an `id`.
- [ ] **`sectionXHTML` declares `xmlns:epub="http://www.idpf.org/2007/ops"`.** The existing tests pin the root element, so update them.
- [ ] **References** are an extra `EPUBPackage.Section` per body, named `references.xhtml` or `references-<tag>.xhtml`, in the spine and in the toc.
- [ ] **The nav** gains `<nav epub:type="loi">` and `<nav epub:type="lot">` when switched on and non-empty.
- [ ] **Images:**
  - `EPUBPackage` gains `images: [Image]` (filename, data source URL, media type).
  - The OPF lists each as a manifest item, with no spine entry.
  - The packager copies each into `OEBPS/images/` before zipping, with `// adr-0018-ok:`.
- [ ] **Tests:**
  - every arm;
  - the noteref/aside pair and its continuous numbering across two sections;
  - a cross-ref href into another section's file;
  - OPF items for images, with correct media types;
  - the `xmlns:epub` declaration;
  - the unzipped package containing `OEBPS/images/…`;
  - the novel golden still green (the XHTML half).
- [ ] Run `./scripts/test.sh` and commit with the message `publish: the EPUB renders report elements, notes, images, References and the lists`.

### Task 7: Problems at the gate, in dry_run and over MCP

**Files:**
- Modify: `Maugham/Publish/TectonicLogParser.swift` (`Diagnostic` gains `pieceID: String? = nil` and `paragraphID: String? = nil`, with an init that keeps every existing call compiling), `CompileOrchestrator.swift`, `PreviewCompiler.swift`, `Republisher.swift`, `SampleCompiler.swift` if it builds bodies itself, `PDFCompiler.swift`, `EPUBCompiler.swift`, `Maugham/MCP/Tools/CompileTools.swift`.
- Test: `MaughamTests/Publish/PublishProblemGateTests.swift`, `CompileToolsTests` (or wherever `encode(diag:)` is tested).

**Contract:**
- [ ] **One gate.** Next to the coverage gate in `compileReserved`, at :704–729, and at its siblings in `PreviewCompiler` and `Republisher`, each body is resolved by `PublishResolution.forCompile`. Its problems become `Diagnostic`s with `file` = the piece's project-relative path, plus `pieceID` and `paragraphID`.
  - For a versioned compile or a republish in a Report, `isError` problems refuse the compile **before the version is minted**, like the coverage gate.
  - Everything else becomes warnings.
  - `dry_run` returns them unchanged.
- [ ] **The compilers receive the resolution they emit with.** Don't resolve twice with different inputs: pass the gate's resolution down, or have the compilers call the same helper with identical arguments, and test that both get equal results.
- [ ] **MCP:** `encode(diag:)` adds `piece_id` and `paragraph_id` when present. Existing keys are unchanged. Check the tool descriptions in `MCPToolCatalog` that describe the `dry_run` reply, and add one sentence. Help describes what ships.
- [ ] **Tests:**
  - a Report with an unknown key refuses `compile` with no version minted, and `dry_run` lists the problem with its ¶id;
  - the same text in a novel compiles, with a warning (Review focus 4);
  - a preview of a Report renders with warnings;
  - a republish of a Report that has since gained a broken reference refuses;
  - MCP encoding with and without ids.
- [ ] Run `./scripts/test.sh` and commit with the message `publish: report problems gate a Report's compile and reach dry_run and MCP`.

### Task 8: The desk shows publish problems, and each one reveals its paragraph

**Files:**
- Modify: `Maugham/Views/Publish/DepartmentCompileState.swift`, its desk view (`DepartmentPane.swift` / `DeskCompileRunner.swift`, whichever draws the compile row), `PublishCentreModel.swift`, and `CentreColumn.swift` (one `publishCentre` arm).
- Create: `Maugham/Views/Publish/PublishProblemsView.swift`
- Test: `MaughamTests/DepartmentCompileStateTests.swift` (or the existing state suite), new `MaughamTests/PublishProblemsViewTests.swift`.

**Contract (read `Maugham/Views/AREA.md` first; tripwires 15, 33, 51 apply):**
- [ ] **`DepartmentCompileState`:**
  - It keeps every problem diagnostic, whether error or warning: anything with a `pieceID`, from `.failed`, `.completed` and `.dryRunPassed`. Today's warnings, which have no `pieceID`, are still dropped.
  - On a refusal from problems, the desk line reads "Couldn't publish: 3 problems in the manuscript" and offers **Show Problems**.
  - On a completed compile with warnings, it reads "Published, with 2 warnings" plus **Show Problems**.
  - The state is pure, so assert it from literals.
- [ ] **`PublishProblemsView`** is a new `publishCentre` arm (`.problems([Diagnostic])`), which is how the round report and the design gate already appear.
  - Each row shows the piece's title, the message, and an error or warning glyph with a text label, never colour alone.
  - Each row has a **Show in Manuscript** button that reveals `pieceID` + `paragraphID` through the window's existing source-paragraph reveal. Find it; don't write a second one.
  - Back clears the arm.
  - When `paragraphID` is nil, the button opens the piece.
  - `ContentUnavailableView` and the frame rules follow tripwire 15.
- [ ] **Tests:**
  - the pure state for each outcome;
  - the view's rows from literals;
  - the reveal closure receiving the right ids (no press-then-wait: assert the closure call directly, per tripwire 33).
- [ ] Run `./gen.sh`, then `./scripts/test.sh`, and commit with the message `views: the desk lists publish problems and each reveals its paragraph`.

### Task 9: Emission contract, guides and the full gate

**Files:**
- Modify: `Maugham/Publish/EmissionContract.swift` (examples and prose), `Maugham/Resources/PublishStarter/EMISSION.md` (regenerated only), `Maugham/Publish/AREA.md`, `docs/guide/` (the publishing page; find it through `docs/INDEX.md`), `Packages/MaughamCore/Sources/MaughamCore/AREA.md` (the "Add a manuscript element" recipe's publish step), `DocBudgetTests` ceilings at the actual `wc -w`.

**Contract:**
- [ ] **`EmissionContract`:**
  - Add positive examples for a captioned table, a figure, a footnote, a citation and a cross-ref. `SinglePieceSource` gets a small fixed `PublishContext` with one citation and one image path, so the examples show resolved output; the image is shown as its staged name.
  - Revise `negativeSpace` so its catch-all no longer claims tables and images render literally.
  - Add a short contract section for `MaughamTable`, the `\ifdefined` degradations, the `lbl-` anchors and the metadata preamble additions.
  - Regenerate `EMISSION.md` through the test.
- [ ] **The Publish AREA guide:**
  - Map rows for the new files.
  - Rules: resolution runs over the whole book, then emits the subset; `PublishProblem.isError` is the one severity table; the image resolver is the one path door; old templates degrade.
  - The Map must name every file, which `DocBudgetTests` checks.
- [ ] **User guide:** how to write a table, a figure, a footnote, a citation and a cross-ref, and what the problems list means. Describe only what ships: the editor's pickers are plan 3, so don't mention them.
- [ ] **Full gate:** run `./scripts/test.sh full` and `./scripts/test.sh phone`. Commit with the message `docs: emission contract, Publish guide and user guide for report elements`.

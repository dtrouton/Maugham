# Report foundations, plan 1: grammar and storage

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MaughamCore can read every new manuscript element (captioned tables, figures, footnotes, citations, cross-references, labelled headings), index a project's labels and citations with diagnostics, and store the Report profile and research citation details in a schema-10 manifest that an older build refuses rather than corrupts.

**Architecture:** this plan is all in MaughamCore (shared by Mac and phone; tripwire 19), plus the manifest write doors in `Maugham/Stores/` and one census. The grammar is a **layer over** `MarkdownBlockParser`, not a widening of `MarkdownBlock`: about 30 existing pattern-match sites (Help, research preview, phone reader, publish) keep compiling and behaving byte-identically. Nothing user-visible changes in this plan; plans 2 (publish) and 3 (editor) consume it.

**Tech stack:** Swift, MaughamCore SPM package (Apple frameworks only), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-19-report-foundations-design.md` (§3 and §7's manifest half). Read §2 (decisions) and §3 before starting any task.

## Global constraints

- **Plan-code is a contract, not a transcript.** Signatures below are verified against the code or are new names this plan defines. Where a step says *contract*, write the code that meets it; don't copy shapes from elsewhere.
- **Every new census or guard has a planted-offender control**, and the implementer runs the **disable experiment**: break the production rule on purpose, see the test fail, restore. Say in the report that you did.
- **No `MarkdownBlock` case is added or widened.** Existing consumers must not change behaviour (`MarkdownBlockParserTests`, `MarkdownBlockParityCorpusTests` and publish's degrade pins stay green untouched).
- **The phone compiles and its tests pass** after every task that touches Core (`./scripts/test.sh phone`).
- Gates: `./scripts/test.sh core` after each Core change; never raw `swift test`. Final task: `./scripts/test.sh full` and `./scripts/test.sh phone`. Run `./gen.sh` after adding any file to the Mac or phone targets (Core files don't need it).
- No migrations (tripwire 11). New manifest content is optional and decodes as absent.
- Text-on-disk forms are exactly spec §3.1 (as amended 2026-10-19: table caption **directly below** the table; figure paths **relative to the document**).
- Labels: kinds are exactly `fig`, `tbl`, `sec`. Label names match `[A-Za-z0-9][A-Za-z0-9_-]*`. Citation keys match the same pattern (so a key can never contain `:` and never collide with a cross-reference).

## Review focus

1. **Ordinary prose that looks like syntax.** An email address (`bob@fig.com`, `me@sec:x`), a Twitter handle (`@sarah`), `[^` or `[@` typed in a sentence, `{#fig:x}` in the middle of a line, and markers inside backtick code spans must not be read as elements. Tested in Tasks 2 and 3.
2. **A schema-9 project opened and saved on this build stays at 9** unless the writer adds v10 content. Raising every old book on first save would lock out the writer's other, not-yet-updated Mac for no reason. Tested in Task 5.
3. **An older build can never silently drop v10 content.** Every manifest write door stamps the content floor, and a census proves no door bypasses it. Tested in Task 5.
4. **Unicode authors.** Citation-key suggestion for "Müller", "García Márquez", "林" and an empty author list must give a valid key, never an empty string. Tested in Task 4.
5. **One bad element must not hide the rest.** A malformed figure line, a footnote definition with no reference, or a duplicate label each give exactly one diagnostic, and every other element still indexes. Tested in Task 3.

---

### Task 1: ADR 0033 and the ledger

**Files:**
- Create: `docs/adr/0033-report-elements-in-manuscripts.md`
- Modify: `docs/adr/README.md` (index row), `docs/superpowers/specs/2026-07-06-commonmark-fountain-expansion-design.md` (ledger rows), `docs/adr/0022-commonmark-fountain-ledger.md` (one "Partly superseded by 0033" status line)

- [ ] **Write ADR 0033** in the existing ADRs' format (Status, Date, Context, Decision, Consequences). Context: the 2026-10-17 audit (C3, C4) and Denver's 2026-10-19 decisions D1, D8 and D11. Decision: tables (with caption), figures, footnotes, citations, cross-references and section labels are IN for manuscripts, in every project kind, in the exact forms of spec §3.1. Everything else ADR 0022 excludes stays OUT, explicitly including indented code, entities, reference links, inline (non-whole-line) images and code blocks. Record the dropped fence fix and why (spec §3.3). Consequences: the paired release (schema 10), and the plan split.
- [ ] **Ledger.** In the design doc, move "Code blocks / tables in manuscripts + publish" so tables are IN (code blocks stay OUT), and add IN rows for footnotes, figures, citations, cross-references and section labels, each naming ADR 0033. ADR 0022's own rule says a ledger change needs an ADR, which Step 1 is.
- [ ] Add the README index row. Check `DocBudgetTests` (its `pathCheckedDocs` and ceilings) still pass with `./scripts/test.sh core`.
- [ ] Commit: `docs: ADR 0033 admits report elements to manuscripts`.

### Task 2: Labels, attributes and the manuscript block layer

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/ManuscriptLabel.swift`, `Packages/MaughamCore/Sources/MaughamCore/ManuscriptBlocks.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/ManuscriptBlocksTests.swift`

**Interfaces (produced; later tasks and plans 2 and 3 rely on these exact names):**

```swift
public struct ManuscriptLabel: Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case fig, tbl, sec }
    public let kind: Kind
    public let name: String
    public var reference: String { "\(kind.rawValue):\(name)" }   // "fig:revenue"
    public init?(reference: String)                                 // parses "fig:revenue"; nil if invalid
}

public enum ManuscriptAttributes {
    /// Splits a trailing `{#kind:name}` off a line. Returns the text with the
    /// block and the whitespace before it removed, plus the label. A block that
    /// is not at the very end, or names an unknown kind or an invalid name,
    /// leaves the text untouched with label nil.
    public static func split(_ line: String) -> (text: String, label: ManuscriptLabel?)
}

public enum ManuscriptBlock: Equatable, Sendable {
    case heading(level: Int, text: String, label: ManuscriptLabel?)
    case table(header: [String], rows: [[String]], caption: String?, label: ManuscriptLabel?)
    case figure(caption: String, path: String, label: ManuscriptLabel?)
    case footnoteDefinition(label: String, text: String)
    case other(MarkdownBlock)
}

public enum ManuscriptBlocks {
    public static func parse(_ text: String) -> [(block: ManuscriptBlock, lines: Range<Int>)]
}
```

**Contract for `ManuscriptBlocks.parse`:** built on `MarkdownBlockParser.parseWithLineRanges` (verified: it returns `[(block: MarkdownBlock, lines: Range<Int>)]`-shaped pairs; check the exact tuple labels before you use them). It maps each pair:

- `.heading(level, text)` becomes `.heading` with `ManuscriptAttributes.split` applied to `text`.
- `.table(header, rows, rawLines)` becomes `.table`. If the **next** pair is a `.paragraph` whose line range starts exactly where the table's ends (no blank line) and whose first line, trimmed, starts with `Table: `, that paragraph is consumed as the caption: the text after `Table: `, split for a label, and the merged range covers both.
- `.paragraph(lines)` with one line, trimmed, that matches `^!\[(.*)\]\(([^)\s]+)\)(\s*\{#fig:[^}]*\})?$` becomes `.figure`. A `.soloImage` becomes `.figure` with label nil.
- `.paragraph(lines)` whose first line matches `^\[\^([A-Za-z0-9_-]+)\]:\s?(.*)$` becomes `.footnoteDefinition`: the text is the remainder plus the following lines (trimmed of leading whitespace), joined with `"\n"`.
- Everything else becomes `.other(block)`, unchanged.

A label of the wrong kind for its element (a `{#tbl:x}` on a figure) is still split off but kept, and Task 3's index diagnoses it. Don't drop it silently.

- [ ] **Write the failing tests first.** Cases:
  - each element in its exact on-disk form;
  - a table without a caption;
  - a table whose `Table:` line comes after a blank line (stays `.other(.paragraph)`; caption not attached);
  - a caption with no label;
  - a heading `## Results {#sec:results}`;
  - a heading with `{#sec:}` (invalid; text untouched);
  - `{#fig:x}` mid-line (untouched);
  - a figure path `../research/a b.png` (a space ends the match: not a figure);
  - `![x](https://example.com/a.png){#fig:x}` (parses as a figure, because the index judges the path);
  - a footnote definition with a continuation line;
  - `[^1]:` inside a list item (stays `.other`);
  - a code fence containing `[^1]: x` (stays `.other(.fence)`).
- [ ] Also a test that maps every fixture in `MarkdownBlockParityCorpusTests`'s corpus through `ManuscriptBlocks.parse` and asserts that every `.other` block equals the `MarkdownBlockParser` output at the same range (the layer is a superset, never a change).
- [ ] Implement. `./scripts/test.sh core`. Run `./scripts/test.sh phone` (Core changed).
- [ ] Commit.

### Task 3: The inline scanner and the project index

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/ManuscriptInlineScanner.swift`, `Packages/MaughamCore/Sources/MaughamCore/ManuscriptIndex.swift`
- Test: `ManuscriptInlineScannerTests.swift`, `ManuscriptIndexTests.swift` (Core test target)

**Interfaces (produced):**

```swift
public struct CitationItem: Equatable, Sendable { public let key: String; public let locator: String? }

public enum ManuscriptInline: Equatable, Sendable {
    case footnoteRef(label: String)
    case citation([CitationItem])
    case crossRef(ManuscriptLabel)
}

public enum ManuscriptInlineScanner {
    /// Every marker in `text`, with its UTF-16 NSRange (the editor's unit), in order.
    public static func scan(_ text: String) -> [(marker: ManuscriptInline, range: NSRange)]
}

public struct ManuscriptDiagnostic: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case duplicateLabel(ManuscriptLabel)
        case labelOnWrongElement(ManuscriptLabel)
        case unresolvedCrossRef(ManuscriptLabel)
        case unknownCitationKey(String)
        case missingFootnoteDefinition(label: String)
        case duplicateFootnoteDefinition(label: String)
        case unusedFootnoteDefinition(label: String)
        case figurePathNotLocal(String)          // a scheme:// URL or an absolute path
    }
    public let kind: Kind
    public let docID: String
    public let line: Int                          // 0-based source line in that doc
}

public struct ManuscriptIndex: Sendable {
    public struct Doc: Sendable { public let id: String; public let text: String
        public init(id: String, text: String) }
    public init(docs: [Doc], citationKeys: Set<String>)    // docs in binder order; prose only
    public let labels: [ManuscriptLabel: (docID: String, line: Int)]   // first occurrence wins
    public let citedKeys: [String]                          // unique, first-use order
    public let diagnostics: [ManuscriptDiagnostic]          // doc order, then line order
}
```

**Scanner contract:**
- **footnote ref:** `[^label]` not at the start of a line followed by `:`.
- **citation:** `[` then one or more `@key` items separated by `;`, each optionally followed by `,` and a locator (text up to the next `;` or `]`, trimmed), then `]`. Example: `[@a, p. 12; @b]`. A bracket whose first item names a `fig:`/`tbl:`/`sec:` label (`[@fig:x]`) is a **cross-reference**, not a citation (pandoc-crossref compatible).
- **bare cross-ref:** `@kind:name` where the character before `@` is start-of-text or not in `[A-Za-z0-9._%+-]` (so email addresses never match), the name follows the label rule, and trailing sentence punctuation is not part of the name (`see @fig:a.` gives `fig:a`).
- **skipped:** anything inside a backtick code span, and anything after a backslash escape (`\[^1]`, `\@fig:a`).

**Index contract:**
- One pass over the docs with `ManuscriptBlocks.parse` and the scanner.
- Labels come from headings (`sec`), tables (`tbl`) and figures (`fig`). A label whose kind doesn't match its element gives `labelOnWrongElement` and is not registered.
- Footnote labels are **per document** (Pandoc scopes them per file). Cross-reference labels and citation keys are project-wide.
- Each diagnostic names the line it came from.
- A figure path that is a URL (`^[A-Za-z][A-Za-z0-9+.-]*://`) or absolute (`/`) gives `figurePathNotLocal`. Whether a local path exists on disk is plan 2's job (it needs the file system).
- Fountain documents are the caller's to exclude; the index assumes prose.

- [ ] Tests first. Scanner cases:
  - each form;
  - `[@a; @b, pp. 3–5]`;
  - `[@fig:a]` as a cross-ref;
  - `bob@fig.com` and `me@sec:x` give nothing;
  - `@sarah` gives nothing (not a label kind);
  - `` `[^1]` `` gives nothing;
  - `\[^1]` gives nothing;
  - `see @fig:a.` gives `fig:a`;
  - NSRanges correct across an emoji before the marker.

  Index cases: Review Focus 5 exactly (one bad element, everything else indexed), and a two-doc project where doc B cross-references doc A's figure.
- [ ] Implement, then `./scripts/test.sh core` and `./scripts/test.sh phone`.
- [ ] Commit.

### Task 4: Research citation details and key suggestion

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/CitationInfo.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ResearchItem.swift` (verified: memberwise `init(id:title:type:kind:path:url:caption:tags:links:addedAt:children:role:)`, synthesized Codable)
- Test: `CitationInfoTests.swift` (Core)

**Interfaces (produced):**

```swift
public struct CitationInfo: Codable, Equatable, Sendable {
    public var key: String
    public var authors: [String]
    public var sourceTitle: String?
    public var publisher: String?
    public var year: Int?
    public var accessed: Date?
    public var pages: String?
    // memberwise init with defaults for all but `key`
}
// ResearchItem gains:  public var citation: CitationInfo?   (init parameter `citation: CitationInfo? = nil`, LAST)
// The source URL stays ResearchItem.url; don't duplicate it.

public enum CitationKey {
    public static func isValid(_ key: String) -> Bool        // [A-Za-z0-9][A-Za-z0-9_-]*
    public static func suggest(authors: [String], year: Int?, title: String, existing: Set<String>) -> String
}
extension Array where Element == ResearchItem {
    /// Every citation key in the tree, recursively (groups included).
    public var citationKeys: Set<String> { get }
}
```

**`suggest` contract:**
- The stem is the last whitespace-separated word of the first non-empty author. With no author, it's the first word of `title` longer than 3 letters, else `"source"`.
- The stem is folded to ASCII (`applyingTransform(.toLatin)` then `.stripDiacritics`), lowercased, and keeps `[a-z0-9]` only. If that leaves nothing, use `"source"`.
- Append the year when present.
- If the result is in `existing`, append `a`, `b`, … `z`, then `aa`, and so on, until it's free.

Examples: `Müller` 2020 gives `muller2020`; `García Márquez` gives `marquez`; `林` gives `lin`; no authors and the title "The State of AI" gives `state`.

- [ ] Tests first: the examples above, plus deduplication (`gartner2026` taken gives `gartner2026a`), `isValid` true and false cases, a ResearchItem JSON round trip with and without `citation`, a pre-feature JSON (no key) decoding to `citation == nil`, and `citationKeys` finding a key nested two groups deep.
- [ ] Implement. Check every `ResearchItem(` construction site still compiles. The new parameter is last and defaulted, so none should need to change; verify with `grep -rn "ResearchItem(" Maugham MaughamPhone Packages`. Then `./scripts/test.sh core` and `./scripts/test.sh phone`.
- [ ] Commit.

### Task 5: The Report profile, switches and schema 10

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/ProjectProfile.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ProjectManifest.swift`, every production manifest encode site (below), `MaughamTests/TripwireGrepTests.swift` (census), the tests pinning `currentSchemaVersion == 9` (`SynthesisSourceTests.swift:77`, `MaughamTests/ProjectManifestTests.swift:122`; check `:90` and `:158` too, which may be fixture values that stay 9)
- Test: `ProjectProfileTests.swift` (Core) plus the census

**Interfaces (produced):**

```swift
public enum ProjectProfile: Codable, Equatable, Sendable {
    case report
    case unknown(String)                       // keeps the raw string; re-encodes it VERBATIM
}

public struct ProjectSwitches: Codable, Equatable, Sendable {
    public var numberSections: Bool?
    public var listOfFigures: Bool?
    public var listOfTables: Bool?
    public var webAccess: Bool?
}

extension ProjectManifest {
    public var profile: ProjectProfile?        // new stored property, decodeIfPresent
    public var switches: ProjectSwitches?      // new stored property, decodeIfPresent
    /// Stored value, else the profile's default, else false. Never written back (tripwire 11).
    public var effectiveSwitches: (numberSections: Bool, listOfFigures: Bool, listOfTables: Bool, webAccess: Bool) { get }
    /// The lowest schema this manifest's CONTENT needs: 10 when profile, switches
    /// or any research item's citation is present; otherwise 0.
    public var contentSchemaFloor: Int { get }
    /// The one way a manifest becomes bytes for disk: schemaVersion becomes
    /// max(schemaVersion, min(contentSchemaFloor, currentSchemaVersion)), then
    /// `makeEncoder()` encodes it.
    public static func encodeForDisk(_ manifest: ProjectManifest) throws -> Data
}
```

The `.report` profile's defaults are all four switches **on**. `currentSchemaVersion` becomes **10**. Add a "9 → 10 (report foundations)" paragraph to the schema contract comment, in the existing style: why the bump isn't ceremony (an older build re-saves without `profile` and citation details), and that this makes a paired release.

**Write doors.** These are verified `ProjectManifest.makeEncoder().encode(` sites. Each one must go through `encodeForDisk`:
- `Maugham/Stores/ProjectStore+Structure.swift:274`
- `Maugham/Stores/DocumentStore+Registry.swift:226`
- `Maugham/Stores/ProjectStore+CollectionPieces.swift:293` (a local `encoder`; read it)
- `Maugham/Stores/ProjectFactory.swift:63`, `:240`
- `Maugham/Stores/ProjectStore.swift:565`
- `Packages/MaughamCore/Sources/MaughamCore/BackupRestore.swift:93`, `:101`
- `ProjectManifest.raising` itself (`ProjectManifest.swift:448`)

`DocumentStore.swift:2039` archives the **losing** manifest of an adoption verbatim. Read it and decide: if it's a byte-faithful backup, leave it and put it in the census allow-list with the reason. Rule it in your report.

**Census:** `TripwireGrepTests.test_manifestBytesForDiskComeFromOneFunction`. No production line in `Maugham/`, `MaughamPhone/` or Core's sources outside `ProjectManifest.swift` may contain `ProjectManifest.makeEncoder()` or `.makeEncoder()` applied to a manifest. Allow-list entries are files with a reason. Include the planted-offender control, and run the disable experiment.

- [ ] Tests first:
  - `ProjectProfile` round trip: `"report"` gives `.report`, and `"essay"` gives `.unknown("essay")` and re-encodes as `"essay"`;
  - `effectiveSwitches`: nil profile gives all false; `.report` gives all true; a stored `false` beats the profile;
  - **Review Focus 2:** a schema-9 manifest with no v10 content passes through `encodeForDisk` still at 9;
  - **Review Focus 3:** add a profile and it encodes at 10; add only a citation to one nested research item and it encodes at 10;
  - `decodeGuardingSchema` refuses 11;
  - an existing schema-9 fixture decodes with `profile == nil` and `switches == nil`.
- [ ] Implement. `./scripts/test.sh core`, `./scripts/test.sh only TripwireGrepTests`, `./scripts/test.sh phone`.
- [ ] Commit.

### Task 6: Docs and the full gate

**Files:** `Packages/MaughamCore/Sources/MaughamCore/AREA.md` (Map rows for the five new files; one Recipe: "Add a manuscript element": scanner or block layer, then index, then plan 2's AST and plan 3's tokenizer), `Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift` (ceiling plus a reason), `docs/tripwires.md` and CLAUDE.md **only if** a new tripwire row is warranted (Task 5's census is a candidate; CLAUDE.md is Denver's file and at its word cap, so add the row to `docs/tripwires.md` and report rather than growing CLAUDE.md).

- [ ] Update the guide, keeping it present tense with no plan or task provenance (`test_untaggedDocsCarryNoMilestoneTag`).
- [ ] `./scripts/test.sh full` and `./scripts/test.sh phone` green.
- [ ] Commit.

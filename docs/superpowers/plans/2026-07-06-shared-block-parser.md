# Shared Markdown Block Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One MaughamCore block segmenter (`MarkdownBlockParser`) replaces the five hand-rolled Markdown block splitters — phone `MarkdownBlocks`, `GuideMarkdownView`, `ResearchNotePreviewPane`, `SyntaxHelpSheet`, and `ProjectASTBuilder.parseProseBlocks` — with uniform block recognition and per-surface presentation.

**Architecture:** Pure function `MarkdownBlockParser.parse(_ text: String) -> [MarkdownBlock]`, no options; blocks retain raw lines so each consumer keeps its presentation choices (phone joins with `\n`, Guide/research join with a space, publish feeds `InlineParser`). Grammar = the publish block loop's rules (freshest, review-hardened) + Guide's table helpers + research's solo-image rule. Publish cutover is gated on EMISSION.md byte-stability.

**Tech Stack:** Swift 6, MaughamCore SPM (Apple frameworks only), SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-06-shared-block-parser-design.md` (normative).

## Global Constraints

- Builds/tests: `./gen.sh` after new files or `project.yml` changes; core `swift test --package-path Packages/MaughamCore`; Mac `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`; phone `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`. MaughamCore changes test against BOTH schemes. Simulator "Busy/preflight" = flake, re-run.
- **EMISSION.md must be byte-identical after the publish cutover** (Task 5). A diff = a parser/mapping bug, NOT a regen opportunity. If a genuine grammar conflict appears, STOP and report — the ledger decides.
- Anchor stripping stays the caller's job (`MarkdownDisplayFilter.stripAnchors` first where manuscript text is involved); `MarkdownBlockParser` never sees/strips anchors.
- MaughamCore is Apple-frameworks-only; cross-module symbols `public`. No third-party parser.
- Never hand-edit project.pbxproj. TDD per task; commit per task with trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- SwiftUI type-check ceiling: if Release/Debug complains about a `body`, extract subviews (ProjectWindow pattern). "Unable to type-check in reasonable time" is REAL.
- Tripwire 19: display surfaces must not re-implement what MaughamCore now owns — deleting the four local parsers is part of the deliverable, not optional cleanup.

## File Structure

```
Packages/MaughamCore/Sources/MaughamCore/MarkdownBlockParser.swift   (create — enum + parser + table/list helpers)
Packages/MaughamCore/Tests/MaughamCoreTests/MarkdownBlockParserTests.swift (create)
Packages/MaughamCore/Tests/MaughamCoreTests/MarkdownBlockParityCorpusTests.swift (create — audit table corpus)
Maugham/Publish/ProjectASTBuilder.swift        (modify — parseProseBlocks becomes a MarkdownBlock→ProseNode mapper)
MaughamPhone/Read/MarkdownBlocks.swift          (rewrite — thin adapter + Block enum stays for the view layer)
MaughamPhone/Read/DocumentReaderView.swift      (modify — render new block kinds)
Maugham/Views/GuideMarkdownView.swift           (modify — parser deleted, adapter + views remain)
Maugham/Views/ResearchNotePreviewPane.swift     (modify — parser deleted, adapter keeps image resolution)
Maugham/Views/SyntaxHelpSheet.swift             (modify — parser deleted, adapter)
Maugham/Editor/RenderFilter.swift               (modify — delete dead restoreComments)
Maugham/Resources/markdown-syntax.md, docs/superpowers/notes/cross-surface-contracts.md, docs/roadmap.md (modify)
```

---

## Phase 1 — Core parser

### Task 1: `MarkdownBlock` + headings, paragraphs, thematic breaks

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/MarkdownBlockParser.swift`
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/MarkdownBlockParserTests.swift`

**Interfaces (Produces — every later task depends on these exact shapes):**
```swift
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(lines: [String])              // raw untrimmed lines
    case list(ordered: Bool, items: [[String]])  // raw lines per item (first line = marker-stripped content)
    case fence(lines: [String], info: String?)   // raw verbatim lines; fence lines dropped
    case table(header: [String], rows: [[String]], rawLines: [String]) // rawLines = original source incl. delimiter row
    indirect case blockquote(blocks: [MarkdownBlock])
    case thematicBreak
    case soloImage(altText: String, path: String, rawLine: String)     // ./-relative whole-line image
}
public enum MarkdownBlockParser {
    public static func parse(_ text: String) -> [MarkdownBlock]
}
```
`table`/`soloImage` carry raw source so publish can degrade them to literal paragraph text byte-identically (spec: "tables are display-only grammar"; the spec's enum sketch omitted the raw payloads — this plan refines it, same semantics).

Rules for THIS task (port from `ProjectASTBuilder.parseProseBlocks`, Maugham/Publish/ProjectASTBuilder.swift:57-150 — read it first; it is the review-hardened reference):
- Blank line (trimmed-empty) separates blocks.
- Thematic break BEFORE heading check: trimmed line where either (a) all chars `-` and count≥3, or (b) exactly `***`, or (c) exactly `###` (spaces stripped first, exact-3 for `*`/`#` — mirror `isSceneBreakLine` + the editor rule).
- ATX heading: 1–6 `#` + required whitespace + non-empty content; level capped at 6; more than 6 `#` → paragraph text.
- Paragraph: gather consecutive raw lines until blank or another block start; store RAW lines (no trimming, no joining — consumers decide).

- [ ] **Step 1: Write failing tests**

```swift
final class MarkdownBlockParserTests: XCTestCase {
    func test_paragraph_keepsRawLines() {
        XCTAssertEqual(MarkdownBlockParser.parse("line one\nline two\n\npara two"),
            [.paragraph(lines: ["line one", "line two"]),
             .paragraph(lines: ["para two"])])
    }
    func test_heading_requiresSpace() {
        XCTAssertEqual(MarkdownBlockParser.parse("# Title"),
                       [.heading(level: 1, text: "Title")])
        XCTAssertEqual(MarkdownBlockParser.parse("#notaheading"),
                       [.paragraph(lines: ["#notaheading"])])
    }
    func test_heading_capsAtSix() {
        XCTAssertEqual(MarkdownBlockParser.parse("###### six"),
                       [.heading(level: 6, text: "six")])
        XCTAssertEqual(MarkdownBlockParser.parse("####### seven"),
                       [.paragraph(lines: ["####### seven"])])
    }
    func test_headingSplitsParagraphWithoutBlank() {
        XCTAssertEqual(MarkdownBlockParser.parse("prose\n# H\nmore"),
            [.paragraph(lines: ["prose"]), .heading(level: 1, text: "H"),
             .paragraph(lines: ["more"])])
    }
    func test_thematicBreak_forms() {
        XCTAssertEqual(MarkdownBlockParser.parse("---"), [.thematicBreak])
        XCTAssertEqual(MarkdownBlockParser.parse("----"), [.thematicBreak])
        XCTAssertEqual(MarkdownBlockParser.parse("***"), [.thematicBreak])
        XCTAssertEqual(MarkdownBlockParser.parse("###"), [.thematicBreak])
        XCTAssertEqual(MarkdownBlockParser.parse("****"),
                       [.paragraph(lines: ["****"])])
        XCTAssertEqual(MarkdownBlockParser.parse("####"),
                       [.paragraph(lines: ["####"])])
    }
    func test_breakBeforeHeadingPrecedence() {
        // bare ### is an ornament, not an H3 (publish + editor rule)
        XCTAssertEqual(MarkdownBlockParser.parse("text\n\n###\n\ntext2"),
            [.paragraph(lines: ["text"]), .thematicBreak,
             .paragraph(lines: ["text2"])])
    }
}
```

- [ ] **Step 2:** `swift test --package-path Packages/MaughamCore --filter MarkdownBlockParserTests` → FAIL (type undefined).
- [ ] **Step 3:** Implement the enum + the line loop with blank/thematic/heading/paragraph branches (structure mirrors `parseProseBlocks`'s `while i < lines.count` walk; list/fence/quote/table/image branches land in Tasks 2–3 — for now those inputs fall to paragraph).
- [ ] **Step 4:** Filter suite green; full core suite green.
- [ ] **Step 5: Commit** `feat(core): MarkdownBlockParser — headings, paragraphs, thematic breaks`

### Task 2: Lists + fences

**Files:** same two files (extend).

Rules (port VERBATIM semantics from ProjectASTBuilder.swift:118-150 — the list rules were review-hardened in the expansion milestone; do not re-derive):
- List marker: `^\s*([-*+]|\d{1,9}[.)])\s+` — but a thematic-break line wins first (`***` is never a list). Ordered-ness from the FIRST item's marker; later mixed markers append as items (lossy-intentional). Indented (space/tab-prefixed) non-marker, non-blank lines append to the current item's lines. An UNINDENTED non-marker line ends the list and is reprocessed by the outer loop. Blank ends the list.
- Item storage: `items: [[String]]` — first entry per item is the marker-stripped first-line content; continuation lines append RAW (consumers trim/join).
- Fence: trimmed `hasPrefix("```")` opens; capture the info string (text after the opening backticks, trimmed, nil if empty); raw lines verbatim (no trimming) until closing fence line or end of input (unclosed runs to end); fence lines dropped.

- [ ] **Step 1: Failing tests**

```swift
func test_unorderedList_flat() {
    XCTAssertEqual(MarkdownBlockParser.parse("- one\n- two"),
        [.list(ordered: false, items: [["one"], ["two"]])])
}
func test_orderedList_bothDelimiters_firstMarkerWins() {
    XCTAssertEqual(MarkdownBlockParser.parse("1. a\n2) b"),
        [.list(ordered: true, items: [["a"], ["b"]])])
    XCTAssertEqual(MarkdownBlockParser.parse("- a\n2. b"),
        [.list(ordered: false, items: [["a"], ["b"]])])
}
func test_list_indentedContinuation_staysInItem() {
    XCTAssertEqual(MarkdownBlockParser.parse("- item\n  continued"),
        [.list(ordered: false, items: [["item", "  continued"]])])
}
func test_list_unindentedLine_endsList_reprocessed() {
    XCTAssertEqual(MarkdownBlockParser.parse("- item\n***"),
        [.list(ordered: false, items: [["item"]]), .thematicBreak])
    XCTAssertEqual(MarkdownBlockParser.parse("- item\n# H"),
        [.list(ordered: false, items: [["item"]]), .heading(level: 1, text: "H")])
}
func test_starListMarker_vsThematicBreak() {
    XCTAssertEqual(MarkdownBlockParser.parse("* item"),
        [.list(ordered: false, items: [["item"]])])
    XCTAssertEqual(MarkdownBlockParser.parse("***"), [.thematicBreak])
}
func test_fence_verbatim_infoString_unclosed() {
    XCTAssertEqual(MarkdownBlockParser.parse("```swift\nlet *x* = 1\n```"),
        [.fence(lines: ["let *x* = 1"], info: "swift")])
    XCTAssertEqual(MarkdownBlockParser.parse("```\n  raw indent kept"),
        [.fence(lines: ["  raw indent kept"], info: nil)])
}
```

- [ ] **Steps 2–4:** RED → implement (list branch BEFORE paragraph accumulation, after thematic/heading; fence branch first of all since fence interior suppresses every other rule) → filter + full core green.
- [ ] **Step 5: Commit** `feat(core): MarkdownBlockParser lists + fences (publish-rule port)`

### Task 3: Blockquotes, tables, solo images

**Files:** same two files (extend).

Rules:
- Blockquote: consecutive lines whose trimmed form `hasPrefix(">")`; strip ONE leading `>` plus one optional following space from the leading-whitespace-trimmed line (port `stripQuoteMarker`, ProjectASTBuilder.swift:141-148 exactly); recursively `parse` the stripped lines → `.blockquote(blocks:)`. No lazy continuation (a non-`>` line ends the quote) — matches publish today.
- Table: a `|`-containing line followed by a GFM delimiter row; port `isTableDelimiterRow` + `splitTableRow` (escaped `\|`, boundary-pipe drop, alignment colons) VERBATIM from GuideMarkdownView.swift:113-160 — move them into `MarkdownBlockParser` as internal statics. `rawLines` captures every consumed source line (header, delimiter, rows) so publish can degrade losslessly.
- Solo image: whole trimmed line matching `^!\[(.*?)\]\((\.[/][^)]+)\)$` (port research's regex, ResearchNotePreviewPane.swift:48-49) → `.soloImage(altText:path:rawLine:)` with `rawLine` = the raw source line. Table check BEFORE list (a `| a | b |` row must not be seen as anything else); image check before paragraph accumulation.

- [ ] **Step 1: Failing tests**

```swift
func test_blockquote_recursive_optionalSpace() {
    XCTAssertEqual(MarkdownBlockParser.parse("> quoted *em*\n>second"),
        [.blockquote(blocks: [.paragraph(lines: ["quoted *em*", "second"])])])
}
func test_blockquote_endsAtPlainLine() {
    XCTAssertEqual(MarkdownBlockParser.parse("> q\nplain"),
        [.blockquote(blocks: [.paragraph(lines: ["q"])]),
         .paragraph(lines: ["plain"])])
}
func test_table_gated_onDelimiterRow() {
    let src = "| a | b |\n|---|:--:|\n| 1 | 2 |"
    let blocks = MarkdownBlockParser.parse(src)
    guard case .table(let h, let r, let raw) = blocks.first else { return XCTFail() }
    XCTAssertEqual(h, ["a", "b"]); XCTAssertEqual(r, [["1", "2"]])
    XCTAssertEqual(raw, ["| a | b |", "|---|:--:|", "| 1 | 2 |"])
}
func test_pipeWithoutDelimiter_staysParagraph() {
    XCTAssertEqual(MarkdownBlockParser.parse("costs 3 | 4 either way"),
        [.paragraph(lines: ["costs 3 | 4 either way"])])
}
func test_escapedPipe_inCell() {
    let blocks = MarkdownBlockParser.parse("| a \\| b | c |\n|---|---|")
    guard case .table(let h, _, _) = blocks.first else { return XCTFail() }
    XCTAssertEqual(h, ["a | b", "c"])
}
func test_soloImage_relativeOnly() {
    XCTAssertEqual(MarkdownBlockParser.parse("![cover](./art/cover.png)"),
        [.soloImage(altText: "cover", path: "./art/cover.png",
                    rawLine: "![cover](./art/cover.png)")])
    XCTAssertEqual(MarkdownBlockParser.parse("![x](https://a/b.png)"),
        [.paragraph(lines: ["![x](https://a/b.png)"])])
}
```

- [ ] **Steps 2–4:** RED → implement → green (full core suite).
- [ ] **Step 5: Commit** `feat(core): MarkdownBlockParser blockquotes, tables, solo images`

### Task 4: Parity corpus (the audit table, made permanent)

**Files:**
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/MarkdownBlockParityCorpusTests.swift`

Build the corpus from the audit's cross-surface inconsistency table (docs/superpowers/notes/2026-07-06-commonmark-fountain-compliance-audit.md, section E) — one named case per row, asserting exact `MarkdownBlockParser.parse` output: soft-wrapped paragraph (raw lines preserved — the three-behaviors row); `#foo` no-space (paragraph, the Help-lax-rule row); fence with emphasis inside (fence, the mangle row); ordered list + pipe table (the Help-corpus row); blockquote with/without space; `----`/`***`/`###`/`****` break forms; solo image relative vs remote. Each case comments its audit-table row. This file is the permanent regression corpus the spec names as the milestone's centerpiece.

- [ ] **Step 1:** Write all corpus cases (they should PASS immediately if Tasks 1–3 are correct — a failure here is a Task 1–3 bug; fix there, not by weakening the corpus).
- [ ] **Step 2:** Full core suite green. **Step 3: Commit** `test(core): audit inconsistency table becomes the block-parser parity corpus`

---

## Phase 2 — Publish cutover (byte-stability gate)

### Task 5: `parseProseBlocks` becomes a MarkdownBlock→ProseNode mapper

**Files:**
- Modify: `Maugham/Publish/ProjectASTBuilder.swift` (parseProseBlocks :57-150 and its private helpers)
- Test: `MaughamTests/ProjectASTBuilderTests.swift` (existing tests are the spec; add mapper-specific ones)

**Interfaces:**
- Consumes: `MarkdownBlockParser.parse`, all `MarkdownBlock` cases (Tasks 1–3).
- Produces: same `[ProjectAST.ProseNode]` as today — that is the whole contract.

Mapping (each row must reproduce today's output byte-for-byte through the emitters):
```swift
private static func mapProse(_ blocks: [MarkdownBlock]) -> [ProjectAST.ProseNode] {
    blocks.compactMap { block in
        switch block {
        case .heading(let level, let text):
            return .heading(level: level, InlineParser.parse(text))
        case .paragraph(let lines):
            return .paragraph(parseParagraphInlines(lines))   // existing helper — soft-join + "  \n" hard-break synthesis unchanged
        case .list(let ordered, let items):
            // item lines: first = marker-stripped content; continuations join with " " after trimming (today's rule)
            return .list(ordered: ordered, items: items.map { item in
                InlineParser.parse(item.enumerated().map { i, l in
                    i == 0 ? l : l.trimmingCharacters(in: .whitespaces)
                }.joined(separator: " "))
            })
        case .fence(let lines, _):
            return .verbatim(lines)
        case .blockquote(let inner):
            return .blockquote(mapProse(inner))
        case .thematicBreak:
            return .sceneBreak
        case .table(_, _, let rawLines):
            // publish negative space: tables are display-only grammar — degrade to today's paragraph
            return .paragraph(parseParagraphInlines(rawLines))
        case .soloImage(_, _, let rawLine):
            return .paragraph(parseParagraphInlines([rawLine]))
        }
    }
}
```
`parseProse` becomes `stripAnchors → MarkdownBlockParser.parse → mapProse`. DELETE the now-unused local block machinery: the line loop, `isSceneBreakLine`, `parseHeading`, `stripQuoteMarker`, `parseListMarker` (grep for other callers first — the editor has its own copies, don't touch those). KEEP `parseParagraphInlines`.

- [ ] **Step 1:** Write 2 failing-first mapper tests pinning the degrade paths (a pipe table through `buildProse` → today's literal-paragraph AST; a solo image line → paragraph), plus assert the full existing ProjectASTBuilderTests still express the contract. Run BEFORE cutover to capture today's expected AST values in the new tests (they pass against the old code — that's the point: they are pins, write them, see them PASS, then cut over and keep them green).
- [ ] **Step 2:** Cut over + delete dead helpers.
- [ ] **Step 3:** Full Mac suite. **EmissionContractTests must pass WITHOUT regenerating EMISSION.md** — byte-stability gate. `git diff Maugham/Resources/PublishStarter/EMISSION.md` must be empty. If not: STOP, diagnose the parser/mapping divergence, report if it's a genuine grammar conflict.
- [ ] **Step 4: Commit** `refactor(publish): prose blocks via shared MarkdownBlockParser — EMISSION byte-stable`

---

## Phase 3 — Display adapters (delete the four local parsers)

### Task 6: Phone reader adapter + new block presentations

**Files:**
- Rewrite: `MaughamPhone/Read/MarkdownBlocks.swift` — `Block` enum stays the view-layer currency but gains cases; `parse` becomes an adapter:
```swift
enum MarkdownBlocks {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)                 // lines joined with "\n" (manuscript line breaks preserved)
        case list(ordered: Bool, items: [String])
        case code(String)
        case table(header: [String], rows: [[String]])
        case quote([Block])
        case divider
    }
    static func parse(_ markdown: String) -> [Block] {
        MarkdownBlockParser.parse(markdown).compactMap(adapt)
    }
    private static func adapt(_ b: MarkdownBlock) -> Block? {
        switch b {
        case .heading(let l, let t): return .heading(level: l, text: t)
        case .paragraph(let lines):
            let joined = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : .paragraph(joined)
        case .list(let o, let items):
            return .list(ordered: o, items: items.map { item in
                item.enumerated().map { i, l in i == 0 ? l : l.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
            })
        case .fence(let lines, _): return .code(lines.joined(separator: "\n"))
        case .table(let h, let r, _): return .table(header: h, rows: r)
        case .blockquote(let inner): return .quote(inner.compactMap(adapt))
        case .thematicBreak: return .divider
        case .soloImage(_, _, let raw): return .paragraph(raw)   // phone renders no images (existing behavior)
        }
    }
}
```
- Modify: `MaughamPhone/Read/DocumentReaderView.swift` — render the new cases: `.list` as rows with `•`/`n.` prefix + inline-parsed text; `.code` in `.system(.footnote, design: .monospaced)` on a subtle background; `.table` as a `Grid` (bold header unless all-blank); `.quote` indented with a leading accent bar; `.divider` as a centered `* * *` Text. Keep inline emphasis via the existing `inlineEmphasis` helper for paragraph/list/table-cell text.
- Test: `MaughamPhoneTests/MarkdownBlocksTests.swift` — existing tests keep passing (heading split, `\n`-joined paragraphs, markers-left-inline); ADD: fence → `.code` with no emphasis interpretation; `- a\n- b` → `.list`; pipe table → `.table`; `> q` → `.quote`; `#foo` stays paragraph.

- [ ] Steps: failing tests → adapter + views → FULL phone suite green (+ core unchanged) → commit `feat(phone): reader renders lists/fences/tables/quotes via shared block parser`.

### Task 7: Guide adapter

**Files:**
- Modify: `Maugham/Views/GuideMarkdownView.swift` — DELETE `parse`, `matchOrderedItem`, `isTableDelimiterRow`, `splitTableRow` (they moved to core in Task 3); `Block` maps from `MarkdownBlock`:
  heading (level as-is), `.paragraph` → joined with `" "` (reflow, today's rule), `.list(ordered:false)` items → `.bullet` per item, `.list(ordered:true)` → `.orderedItem(number: "\(index+1)", text:)` (numbers regenerate sequentially — today's renderer shows the SOURCE number; keep source fidelity instead: store items and render `\(i+1).` only if the old tests demand source numbers — check `GuideMarkdownViewTests` and match whichever the tests pin; they pin source behavior via parse-level tests that now live in core, so renumbering is acceptable — decide by reading the tests and keep them green without weakening),
  `.fence` → `.code(lines.joined("\n"))`, `.table` → `.table(header:rows:)`, `.blockquote` → its inner paragraphs as `.paragraph` (today: quote renders unstyled text — UPGRADE: add a `.quote(String)` case with a leading accent bar, matching the phone's new treatment; grammar-improvement, comment the audit row), `.thematicBreak` → new `.divider` case (renders `Divider()`), `.soloImage` → paragraph of the raw line.
- Test: `MaughamTests/GuideMarkdownViewTests.swift` — parse-level tests re-point at the adapter; `GuideCorpusRenderabilityTest` re-points at `MarkdownBlockParser` + adapter (heuristic unchanged: no `|---` or `\d+[.)]` leaking into paragraphs across every `docs/guide/*.md`).

- [ ] Steps: adjust tests first (RED where behavior upgrades) → adapter → full Mac suite green → commit `refactor(help): GuideMarkdownView consumes shared block parser; local parser deleted`.

### Task 8: Research preview adapter

**Files:**
- Modify: `Maugham/Views/ResearchNotePreviewPane.swift` — `parse(text:notePath:projectURL:)` becomes: `MarkdownBlockParser.parse(text)` then map: `.heading`→`.heading`; `.paragraph`→ space-joined through `AttributedString(markdown:)` (today's rule, ResearchNotePreviewPane.swift:53-61 `flushParagraph`); `.soloImage` → resolve `path` relative to the note's directory and load `NSImage` exactly as today (:86-103), falling back to a paragraph of `rawLine` on load failure (pinned behavior from the expansion milestone — the flattened-alt output must keep passing); NEW: `.list` → bulleted/numbered paragraph rows, `.fence` → monospaced text block, `.table` → grid, `.blockquote` → accent-bar quote, `.thematicBreak` → divider (mirror Task 7's view treatments; extract a tiny shared Mac view helper ONLY if both files want identical views — otherwise keep local, YAGNI).
- Test: `MaughamTests/ResearchNotePreviewParseTests.swift` — all 5 existing tests keep passing (paragraph grouping, heading/image flush, missing-image fallback with flattened alt); ADD fence/list/table cases.

- [ ] Steps: tests → adapter → full Mac suite green → commit `refactor(views): research preview consumes shared block parser`.

### Task 9: Syntax help sheet adapter

**Files:**
- Modify: `Maugham/Views/SyntaxHelpSheet.swift` — read the file first (parser at ~:150, inline at ~:161); replace its `parseMarkdownBlocks` with the shared parser + a mapping to its existing view enum (content is curated in-app help; the mapping mirrors Task 7's, minus tables if its content has none — check and note in the report).
- Test: locate with `grep -rn "SyntaxHelpSheet" MaughamTests` — extend or create parse-level tests pinning heading/paragraph/fence mapping.

- [ ] Steps: tests → adapter → full Mac suite green → commit `refactor(views): syntax help sheet consumes shared block parser`.

---

## Phase 4 — Riders, docs, exit gates

### Task 10: Deferred test pins + dead-code deletion

**Files:**
- Test: `MaughamTests/InlineParserTests.swift` — pin cross-code-span flanking:
```swift
func test_emphasisFlanksAcrossCodeSpan() {
    // The masked (non-space) placeholder keeps flanking alive across a
    // protected span — deliberate; pinned so a converter change can't
    // silently flip it. (Expansion-milestone review minor.)
    XCTAssertEqual(InlineParser.parse("*a `code` b*"),
        [.emphasis([.text("a "), .code("code"), .text(" b")])])
}
```
(Run it FIRST — if the actual shape differs, e.g. code-span ordering inside emphasis, adjust to observed output and document; the pin's purpose is locking current behavior.)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/FountainDotlessStemTests.swift` — add `EXT/INT ROOM - DAY` (space-form) → `.sceneHeading`.
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/FountainTokenizerTests.swift` (or the held-blank test file) — exact-output pins: double-held (`"DAN\nA.\n  \n  \nB.\n"` → element sequence all-dialogue) and EOF-on-held (`"DAN\nA.\n  "` → no crash, trailing held line `.dialogue`); plus `MaughamTests/FountainNodeMapperTests.swift` — cue-then-held leading-`.lineBreak` shape (`"DAN\n  \nHello.\n"` → one `.dialogue([.lineBreak, .text("Hello.")])` — verify observed shape first, pin what's real).
- Modify: `Maugham/Editor/RenderFilter.swift` — delete `restoreComments` (zero callers; confirm with `grep -rn "restoreComments" Maugham MaughamTests Packages MaughamPhone` before deleting).

- [ ] Steps: run-first to observe → pin → all three suites green → commit `test: expansion-milestone deferred pins + delete dead RenderFilter.restoreComments`.

### Task 11: Docs + registry + exit gates

**Files:**
- Modify: `Maugham/Resources/markdown-syntax.md` — the per-surface support note updates: phone Read tab and research previews now render lists, fenced code (monospace), tables, and styled quotes (previously "editor-only styling" caveats); keep the deliberate-omission list intact.
- Modify: `docs/superpowers/notes/cross-surface-contracts.md` — add row: Markdown block segmentation = shared `MarkdownBlockParser` (tier 1 shared-impl) across phone reader/Guide/research/syntax-sheet/publish; parity corpus named as the guard.
- Modify: `docs/roadmap.md` — mark approach C shipped; remove the checkpoint entry.
- [ ] **Exit gates:** full matrix (core + Mac + phone suites), Release-config build (`xcodebuild -configuration Release build CODE_SIGNING_ALLOWED=NO` — view files changed), MCP pre-smoke on the dev build (create a research note + a manuscript with lists/fences/tables via `test_apply_edit`, verify phone-visible derived text unchanged and publish output byte-stable vs a pre-cutover compile), then post the USER smoke checklist:
  1. Phone Read tab on a manuscript containing a list + fence + table — renders as list/monospace/grid, line breaks in plain paragraphs still preserved.
  2. Help ⌘? Reference topic — table still a grid; a numbered-steps topic still numbered.
  3. Research preview of a note with an image + list — image renders, list renders, paragraphs reflow.
  4. Publish any prose doc — output unchanged from v0.14.0.
- [ ] Commit `docs: shared block parser registry row + per-surface support notes`, then STOP for user smoke → merge/tag decision.

## Self-review notes (applied)

- Spec coverage: uniform grammar (T1–3), parity corpus centerpiece (T4), publish cutover + byte gate (T5), four display adapters with local-parser deletion (T6–9), riders (T10), docs/registry/roadmap + gates (T11). Non-goals untouched (no annotation bodies, no inline unification, no editor tokenizer change).
- Type consistency: `MarkdownBlock` case shapes in T1 match every consumer in T5–T9 (incl. `table` 3-payload and `soloImage` 3-payload); `MarkdownBlocks.Block` (phone) is a distinct view-layer enum by design.
- Known judgment points delegated WITH guardrails: Guide ordered-number source-vs-sequential (T7, decide by existing tests), SyntaxHelpSheet content audit (T9), pin-what's-observed rules (T10).

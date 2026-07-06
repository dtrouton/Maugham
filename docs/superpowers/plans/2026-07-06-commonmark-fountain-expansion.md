# CommonMark + Fountain Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Action the 2026-07-06 compliance audit: consolidate the duplicated inline/Fountain parsers, add strikethrough + escapes + paragraph-scoped emphasis + publish lists, rewrite publish-Fountain through the real tokenizer (killing the boneyard/note leak), expand the Fountain core (scene numbers, dot-less stems, held blanks), fix the renderers, and sweep the docs.

**Architecture:** Consolidation-first (spec approach A). `InlineEmphasisScanner` becomes the single inline engine (escapes, optional `~~` strikethrough); publish inline parsers become adapters over it; publish Fountain parsing is replaced by a `FountainTokenizer → ProjectAST.FountainNode` mapper. Display block-splitters are NOT unified (C reviewed at end).

**Tech Stack:** Swift 6, SwiftUI/AppKit, local SPM package `MaughamCore`, xcodegen, XCTest, bundled tectonic (XeTeX).

**Spec:** `docs/superpowers/specs/2026-07-06-commonmark-fountain-expansion-design.md` (the decision ledger there is normative — when in doubt, the ledger wins).

## Global Constraints

- Build: `./gen.sh` after any `project.yml`/`Package.swift` change; Mac tests: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`; phone tests: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`; core-only fast loop: `swift test --package-path Packages/MaughamCore`.
- MaughamCore changes must be tested against BOTH schemes (tripwire: independent schemes).
- Never read a manuscript `.md`/`.fountain` as truth (ADR 0018/0019); this milestone touches parse/display/emit only — no on-disk format changes.
- Paragraph IDs in tests crossing the `.md` ↔ op log boundary: 4-char `[0-9a-hjkmnp-tv-z]` alphabet (tripwire 8).
- `FountainTokenizerReference.swift` is a frozen differential oracle: Task 11–13 revise it ON PURPOSE; every oracle diff must be traceable to a spec-ledger row and called out in the commit message.
- Cross-module MaughamCore symbols need `public`.
- After public-signature changes in MaughamCore, clean DerivedData if you hit phantom `Undefined symbol` link errors.
- Commit after every green task; `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Editor typing-perf: Task 4 gates phase 1; do not merge substrate work without it.

## File Structure (new/changed)

```
Packages/MaughamCore/Sources/MaughamCore/
  EmphasisTraits.swift            (modify: +strikethrough)
  InlineEmphasisScanner.swift     (modify: options, escapes, ~~)
  FountainLine.swift              (modify: +sceneNumber; FountainInlineSpan +sceneNumber case)
  FountainTokenizer.swift         (modify: scene numbers, dot-less stems, held blank)
Maugham/Editor/Tokenizer/
  MarkdownTokenizer.swift         (modify: blank-line blocks, escapes fade, image-tail)
  BlankLineBlocks.swift           (create)
Maugham/Editor/ProseMode.swift    (modify: strikethrough attribute)
Maugham/Publish/
  EmphasisRunConverter.swift      (create: EmphasisScan → [ProjectAST.Inline])
  InlineParser.swift              (rewrite as adapter)
  FountainInline.swift            (rewrite as adapter)
  FountainNodeMapper.swift        (create: FountainScript → [FountainNode])
  ProjectAST.swift                (modify: +strikethrough, +lyric/centered/pageBreak, sceneHeading number)
  ProjectASTBuilder.swift         (modify: lists, fences, delete parseFountain+parseTitlePage)
  LaTeXBodyEmitter.swift / XHTMLBodyEmitter.swift (modify: new nodes)
  EmissionContract.swift          (modify: +examples incl. fountain section)
Maugham/Views/GuideMarkdownView.swift      (modify: ordered lists, tables)
Maugham/Views/ResearchNotePreviewPane.swift (modify: paragraph grouping)
Maugham/Resources/markdown-syntax.md, fountain-syntax.md (rewrite)
docs/adr/00XX-commonmark-fountain-ledger.md (create; next free number)
docs/superpowers/notes/cross-surface-contracts.md (modify: +rows)
```

---

## Phase 1 — Substrate

### Task 1: Scanner gains escapes + strikethrough option

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/EmphasisTraits.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/InlineEmphasisScanner.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/InlineEmphasisScannerTests.swift` (extend; file exists — locate with `grep -rl InlineEmphasisScanner Packages/MaughamCore/Tests`)

**Interfaces (Produces — later tasks rely on these exact shapes):**
```swift
public struct EmphasisTraits: OptionSet, Sendable, Hashable {
    public static let bold          = EmphasisTraits(rawValue: 1 << 0)
    public static let italic        = EmphasisTraits(rawValue: 1 << 1)
    public static let strikethrough = EmphasisTraits(rawValue: 1 << 2)  // NEW
}
public extension InlineEmphasisScanner {
    struct Options: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Recognize ~~x~~ as .strikethrough. Prose surfaces pass this;
        /// Fountain surfaces do NOT (tildes stay literal there — `~` is lyric).
        public static let strikethrough = Options(rawValue: 1 << 0)
    }
}
// Signature change (source-compatible via default):
public static func scan(_ text: NSString, options: Options = []) -> EmphasisScan
// EmphasisScan gains (default keeps existing constructors compiling):
public let escapes: [NSRange]   // each = the 1-char backslash range that escaped a delimiter
```

Escape semantics (spec ledger "Backslash escapes"): a `\` immediately before `*`, `~`, `_`, `` ` ``, or `\` neutralizes that character as a delimiter for THIS scanner's grammar (`*` runs and, when enabled, `~~`), and its range is reported in `escapes`. The escaped char renders literal. A `\` before anything else is plain text (no escape entry). Note the scanner only acts on `*`/`~` itself; reporting `_`/`` ` ``/`\` escapes lets callers (editor fade, publish strip) treat escapes uniformly.

- [ ] **Step 1: Write failing tests**

```swift
func test_escapedAsterisk_isLiteral() {
    let scan = InlineEmphasisScanner.scan(#"\*not emphasis\*"# as NSString)
    XCTAssertTrue(scan.runs.isEmpty)
    XCTAssertTrue(scan.markers.isEmpty)
    XCTAssertEqual(scan.escapes, [NSRange(location: 0, length: 1),
                                  NSRange(location: 14, length: 1)])
}
func test_escapedOpenerOnly_leavesCloserUnpaired_literal() {
    let scan = InlineEmphasisScanner.scan(#"\*x*"# as NSString)
    XCTAssertTrue(scan.runs.isEmpty)   // lone closer degrades to literal
}
func test_doubleBackslash_thenEmphasis_stillEmphasizes() {
    // \\ escapes the backslash; the * run is live: \\*x* → literal "\" + em "x"
    let scan = InlineEmphasisScanner.scan(#"\\*x*"# as NSString)
    XCTAssertEqual(scan.runs, [.init(range: NSRange(location: 3, length: 1),
                                     traits: .italic)])
    XCTAssertEqual(scan.escapes, [NSRange(location: 0, length: 1)])
}
func test_strikethrough_basic() {
    let scan = InlineEmphasisScanner.scan("a ~~gone~~ b" as NSString,
                                          options: [.strikethrough])
    XCTAssertEqual(scan.runs, [.init(range: NSRange(location: 4, length: 4),
                                     traits: .strikethrough)])
    XCTAssertEqual(scan.markers, [NSRange(location: 2, length: 2),
                                  NSRange(location: 8, length: 2)])
}
func test_strikethrough_offByDefault_tildesLiteral() {
    let scan = InlineEmphasisScanner.scan("a ~~x~~ b" as NSString)
    XCTAssertTrue(scan.runs.isEmpty)
}
func test_strikethrough_nestsWithEmphasis() {
    // *em ~~struck~~ em* → struck region carries [.italic, .strikethrough]
    let scan = InlineEmphasisScanner.scan("*em ~~st~~ em*" as NSString,
                                          options: [.strikethrough])
    XCTAssertTrue(scan.runs.contains(
        .init(range: NSRange(location: 6, length: 2),
              traits: [.italic, .strikethrough])))
}
func test_singleTilde_neverStrikethrough() {
    let scan = InlineEmphasisScanner.scan("a ~x~ b" as NSString,
                                          options: [.strikethrough])
    XCTAssertTrue(scan.runs.isEmpty)   // GFM requires ~~
}
```

- [ ] **Step 2: Run** `swift test --package-path Packages/MaughamCore --filter InlineEmphasisScannerTests` — expect the new tests FAIL (no `options:` overload / no `.strikethrough`).

- [ ] **Step 3: Implement.** In `EmphasisTraits`, add `strikethrough` (rawValue `1 << 2`). In the scanner:
  1. **Pre-pass for escapes** before run collection: walk the string; on `\` followed by one of `* ~ _ ` `` ` `` `\`, record the backslash range in `escapes` and record the *following index* in an `escaped: Set<Int>` (skip 2). Run collection (step "1. Collect asterisk runs") skips characters whose index is in `escaped`.
  2. **Tilde runs**: when `options.contains(.strikethrough)`, collect `~` runs the same way as `*` runs, but only runs of length exactly ≥2 participate, and pairing always consumes exactly 2 (`use = 2`), trait `.strikethrough`. Reuse the existing delimiter-stack by generalizing `Delim` with a `kind: Character` field; closers only match openers of the same kind. Asterisk pairing logic is untouched (guard `kind == "*"` around the 1-vs-2 `use` computation; tilde branch forces `use = 2` and requires `remaining >= 2` on both sides).
  3. Flatten step: tilde emphases insert `.strikethrough` into `perIndex` exactly as bold/italic do.
  Keep the whitespace-flanking rule identical for tildes.

- [ ] **Step 4: Run the full core suite** `swift test --package-path Packages/MaughamCore` — all green (existing scanner + tokenizer + differential tests must not change behavior for input without backslash-escapes or tildes).

- [ ] **Step 5: Commit** `feat(core): scanner backslash escapes + opt-in ~~strikethrough~~ trait`

### Task 2: Editor — paragraph-scoped emphasis, strikethrough styling, escape fade

**Files:**
- Create: `Maugham/Editor/Tokenizer/BlankLineBlocks.swift`
- Modify: `Maugham/Editor/Tokenizer/MarkdownTokenizer.swift:37-56` (the `.byLines` scanner block)
- Modify: `Maugham/Editor/ProseMode.swift:225` region (`.emphasis(traits)` attribute mapping)
- Test: `MaughamTests/MarkdownTokenizerTests.swift`

**Interfaces:**
- Consumes: `InlineEmphasisScanner.scan(_:options:)`, `EmphasisScan.escapes` (Task 1).
- Produces: `BlankLineBlocks.enumerate(_ text: NSString, in range: NSRange, _ body: (NSRange) -> Void)` — invokes `body` once per blank-line-delimited block (a blank line = a line whose characters are only spaces/tabs). Fountain path (`ScreenplayMode`) is untouched — it feeds the scanner per line via `FountainTokenizer` as today, and passes NO `.strikethrough` option.

- [ ] **Step 1: Write failing tests** (in `MarkdownTokenizerTests`)

```swift
func test_emphasisSpansHardBreakWithinParagraph_stanzaCase() {
    let text = "She read it. *How could he\npossibly have known?* Odd."
    let tokens = MarkdownTokenizer.tokenize(text)
    // one italic run covering "How could he\npossibly have known?"
    XCTAssertTrue(tokens.contains { $0.kind == .emphasis(.italic)
        && (text as NSString).substring(with: $0.range)
            == "How could he\npossibly have known?" })
}
func test_emphasisDoesNotCrossBlankLine() {
    let tokens = MarkdownTokenizer.tokenize("*open\n\nclose*")
    XCTAssertFalse(tokens.contains { if case .emphasis = $0.kind { return true }
                                     else { return false } })
}
func test_strikethrough_stylesInProse() {
    let text = "keep ~~cut this~~ keep"
    let tokens = MarkdownTokenizer.tokenize(text)
    XCTAssertTrue(tokens.contains { $0.kind == .emphasis(.strikethrough)
        && (text as NSString).substring(with: $0.range) == "cut this" })
}
func test_escapedAsterisk_backslashFades_noEmphasis() {
    let text = #"\*literal\*"#
    let tokens = MarkdownTokenizer.tokenize(text)
    XCTAssertFalse(tokens.contains { if case .emphasis = $0.kind { return true }
                                     else { return false } })
    // backslashes fade as syntax punctuation
    XCTAssertTrue(tokens.contains { $0.kind == .syntaxPunctuation
        && $0.range == NSRange(location: 0, length: 1) })
}
```
Delete/replace `testEmphasisDoesNotSpanLineBreak` (its behavior is inverted by the spec ledger — cite the ledger row in the commit).

- [ ] **Step 2: Run** the Mac suite filtered: `xcodebuild … test -only-testing:MaughamTests/MarkdownTokenizerTests CODE_SIGNING_ALLOWED=NO` — new tests FAIL.

- [ ] **Step 3: Implement.**

`BlankLineBlocks.swift`:
```swift
import Foundation

/// Enumerate blank-line-delimited blocks of `text` within `range`.
/// A blank line contains only spaces/tabs. Block ranges exclude the
/// delimiting blank lines. Used so inline emphasis scans per PARAGRAPH
/// (spec ledger: paragraph-scoped emphasis) instead of per line.
enum BlankLineBlocks {
    static func enumerate(_ text: NSString, in range: NSRange,
                          _ body: (NSRange) -> Void) {
        var blockStart: Int? = nil
        var lineStart = range.location
        let end = range.location + range.length
        func flush(_ upTo: Int) {
            if let s = blockStart, upTo > s {
                body(NSRange(location: s, length: upTo - s)); blockStart = nil
            }
        }
        while lineStart < end {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let content = text.substring(with: lineRange)
            let isBlank = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank { flush(lineStart) }
            else if blockStart == nil { blockStart = lineRange.location }
            lineStart = lineRange.location + lineRange.length
            if lineRange.length == 0 { break }   // safety at text end
        }
        flush(end)
    }
}
```
In `MarkdownTokenizer` replace the `.byLines` emphasis block with:
```swift
BlankLineBlocks.enumerate(nsText, in: fullRange) { blockRange in
    let block = nsText.substring(with: blockRange)
    let scan = InlineEmphasisScanner.scan(block as NSString,
                                          options: [.strikethrough])
    for run in scan.runs { /* offset by blockRange.location; unchanged */ }
    for marker in scan.markers { /* unchanged, offset */ }
    for esc in scan.escapes {
        let r = NSRange(location: blockRange.location + esc.location,
                        length: esc.length)
        if !tokens.contains(where: { $0.range.intersection(r) != nil }) {
            tokens.append(Token(range: r, kind: .syntaxPunctuation))
        }
    }
}
```
In `ProseMode` where `.emphasis(let traits)` maps to attributes: if `traits.contains(.strikethrough)`, set `attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue` (compose with bold/italic font handling already there — strikethrough is an attribute, not a font trait).

- [ ] **Step 4: Run** full `MaughamTests` — green.
- [ ] **Step 5: Commit** `feat(editor): paragraph-scoped emphasis + ~~strikethrough~~ + escape fade`

### Task 3: Publish inline adapters over the scanner

**Files:**
- Create: `Maugham/Publish/EmphasisRunConverter.swift`
- Rewrite: `Maugham/Publish/InlineParser.swift` (public API `InlineParser.parse(_ text: String) -> [ProjectAST.Inline]` unchanged)
- Rewrite: `Maugham/Publish/FountainInline.swift` (public API unchanged)
- Modify: `Maugham/Publish/ProjectAST.swift` (`Inline` gains `case strikethrough([Inline])`)
- Modify: `Maugham/Publish/LaTeXBodyEmitter.swift:103-133` `emitInline`, `Maugham/Publish/XHTMLBodyEmitter.swift:56-70` `emitInline`
- Test: `MaughamTests/InlineParserTests.swift`, `MaughamTests/FountainInlineTests.swift` (locate: `grep -rl "InlineParser\|FountainInline" MaughamTests`)

**Interfaces:**
- Consumes: `InlineEmphasisScanner.scan(_:options:)`, `EmphasisScan` (runs/markers/escapes).
- Produces: `EmphasisRunConverter.inlines(for text: String, options: InlineEmphasisScanner.Options, protected: [ProtectedSpan]) -> [ProjectAST.Inline]` where
  ```swift
  struct ProtectedSpan { let range: NSRange; let node: ProjectAST.Inline }
  ```
  Converter contract: masks each protected range with `"x"` placeholders (length-preserving, so flanking around code spans/wiki links is stable), scans the masked text, then walks positions 0..<n emitting — protected node at its start index; skipping marker + escape-backslash indices; grouping the rest into (traits → nested Inline) segments: `.strikethrough` wraps outermost, then `.strong`, then `.emphasis` (deterministic nesting order; emitters flatten anyway). Escaped delimiters emit WITHOUT the backslash (publish strips it).

Behavior deltas locked by this task (all spec-ledger rows): prose `***x***` → bold-italic (audit A2 fixed); prose `_x_` → literal underscore text (underscore removed from prose); `\*x\*` → literal `*x*`; `~~x~~` → strikethrough in prose; Fountain `_x_` → `.underline` (kept — implemented in `FountainInline` as a pre-extraction pass that turns `_…_` spans into protected `.underline(...)` nodes whose inner text recursively converts, then delegates asterisks/escapes to the converter with NO `.strikethrough` option).

- [ ] **Step 1: Write failing tests**

```swift
// InlineParserTests
func test_tripleAsterisk_boldItalic() {
    XCTAssertEqual(InlineParser.parse("***x***"),
                   [.strong([.emphasis([.text("x")])])])
}
func test_underscore_isLiteralInProse() {
    XCTAssertEqual(InlineParser.parse("snake_case_word"),
                   [.text("snake_case_word")])
}
func test_escapedAsterisk_literal_backslashDropped() {
    XCTAssertEqual(InlineParser.parse(#"\*x\*"#), [.text("*x*")])
}
func test_strikethrough_parses() {
    XCTAssertEqual(InlineParser.parse("a ~~b~~ c"),
                   [.text("a "), .strikethrough([.text("b")]), .text(" c")])
}
func test_emphasisAcrossSoftBreak_withinParagraph() {
    XCTAssertEqual(InlineParser.parse("*a\nb*"),
                   [.emphasis([.text("a\nb")])])
}
func test_codeSpanContent_neverEmphasized_andBlocksFlanking() {
    XCTAssertEqual(InlineParser.parse("`*x*`"), [.code("*x*")])
}
// FountainInlineTests
func test_fountain_tildesStayLiteral() {
    XCTAssertEqual(FountainInline.parse("a ~~x~~ b"), [.text("a ~~x~~ b")])
}
func test_fountain_underline_kept() {
    XCTAssertEqual(FountainInline.parse("_under_"), [.underline([.text("under")])])
}
func test_fountain_escapes_matchProse() {
    XCTAssertEqual(FountainInline.parse(#"\*x\*"#), [.text("*x*")])
}
```
Keep every existing passing test in both files; where an existing test pins the OLD `_x_`-is-emphasis prose behavior, replace it citing the ledger.

- [ ] **Step 2: Run** `-only-testing:MaughamTests/InlineParserTests -only-testing:MaughamTests/FountainInlineTests` — new FAIL.
- [ ] **Step 3: Implement** converter + adapters. `InlineParser` keeps local pre-extraction of (in order): inline code `` `…` `` (first-close match, as today), wiki links `[[…]]`, hard breaks (`"  \n"` → `.lineBreak`, and after Task 9 also `"\\\n"`), each becoming a `ProtectedSpan`; then calls the converter with `options: [.strikethrough]`. `FountainInline` pre-extracts `_…_` → `.underline` protected spans (inner text runs through the converter too), then converts with `options: []`. Emitters: `.strikethrough` → LaTeX `\\st{...}` (macro finalized in Task 8; use `\\st` now), XHTML `<s>…</s>`.
- [ ] **Step 4: Run** the full Mac suite (emission golden tests included) — green. `EmissionContractTests` may fail on EMISSION.md drift only if examples changed — they haven't yet (Task 8 adds examples).
- [ ] **Step 5: Commit** `refactor(publish): inline parsers become InlineEmphasisScanner adapters (fixes *** mangle, drops prose underscore, adds strikethrough+escapes)`

### Task 4: Typing-perf gate (phase-1 exit)

**Files:** none created — run the existing harness (find it: `grep -rl "typing" MaughamTests | grep -i perf` / see `docs/superpowers/plans/` typing-perf milestone notes; the 120pp fixture + measurement exist from v0.11.0).

- [ ] **Step 1:** Run the tokenizer perf test(s) at the 120pp fixture; record per-keystroke tokenize time.
- [ ] **Step 2:** Compare against the v0.11.0 baseline (~37ms Debug @120pp). Budget: ≤ baseline +10%. Paragraph-scoped scanning is bounded by paragraph length, not doc length — if regression exceeds budget, memoize per-block scans keyed by block hash before proceeding. THIS TASK BLOCKS THE PHASE; do not rationalize a miss.
- [ ] **Step 3:** Commit any memoization; record measured numbers in the commit message.

---

## Phase 2 — Publish Fountain rewrite

### Task 5: AST vocabulary for the full element set

**Files:**
- Modify: `Maugham/Publish/ProjectAST.swift`
- Modify: `Maugham/Publish/LaTeXBodyEmitter.swift` (`emit(fountain:)`, line ~135), `Maugham/Publish/XHTMLBodyEmitter.swift` (`emit(fountain:)`, line ~72)
- Test: emitter tests (locate: `grep -rl "LaTeXBodyEmitter" MaughamTests`)

**Interfaces (Produces):**
```swift
public enum FountainNode: Equatable, Sendable {
    case sceneHeading(String, sceneNumber: String?)   // arity change — fix all sites
    case action([Inline])
    case character(String)
    case dialogue([Inline])
    case parenthetical([Inline])
    case transition(String)
    case lyric([Inline])          // NEW
    case centered([Inline])       // NEW
    case pageBreak                // NEW
    case titlePage([TitleField])
    indirect case dualDialogue(left: [FountainNode], right: [FountainNode])
}
```
Emission (with `\providecommand` fallbacks prepended to fountain-mode section bodies so EXISTING user templates keep compiling — this is the compatibility mechanism, do not skip it):
```latex
\providecommand{\lyricline}[1]{\textit{#1}\par}
\providecommand{\centeredline}[1]{\begin{center}#1\end{center}}
\providecommand{\scenenumber}[1]{\hfill #1}
```
LaTeX: `.lyric` → `\lyricline{…}`; `.centered` → `\centeredline{…}`; `.pageBreak` → `\clearpage`; `.sceneHeading(t, n)` → existing `\sceneheading{t esc}` plus, when `n != nil`, append `\scenenumber{n esc}` inside the argument: `\sceneheading{INT. HOUSE - DAY\scenenumber{42}}`. XHTML: `.lyric` → `<p class="lyric">`, `.centered` → `<p class="centered">`, `.pageBreak` → `<hr class="page-break"/>`, scene number → `<span class="scene-number">…</span>` appended inside the `<h3 class="scene-heading">`.

- [ ] **Step 1: Failing emitter tests** — one per new node asserting the exact strings above (both emitters), plus `sceneHeading("INT. A", sceneNumber: nil)` emitting exactly today's output.
- [ ] **Step 2:** Run — FAIL (missing cases; arity errors are compile failures — fix every `sceneHeading` pattern-match the compiler flags, passing `sceneNumber: nil`).
- [ ] **Step 3:** Implement cases + providecommand prologue (emit once per fountain-mode section, before its first node).
- [ ] **Step 4:** Full Mac suite green.
- [ ] **Step 5: Commit** `feat(publish): FountainNode lyric/centered/pageBreak + scene numbers with template-safe fallbacks`

### Task 6: FountainNodeMapper (tokenizer → AST)

**Files:**
- Create: `Maugham/Publish/FountainNodeMapper.swift`
- Test: Create `MaughamTests/FountainNodeMapperTests.swift`

**Interfaces:**
- Consumes: `FountainTokenizer().parse(_ text: String) -> FountainScript` (MaughamCore); `FountainScript.lines: [FountainLine]`, `.titlePage: [TitlePageField]?`; `FountainLine.element/.content/.isDualSecond` (+ `.sceneNumber` after Task 11 — mapper reads it via `line.sceneNumber`, which this task stubs as `nil` until Task 11 lands; write the mapper against the property from day one and add `sceneNumber` to `FountainLine` in THIS task with default `nil`, leaving extraction to Task 11).
- Produces: `enum FountainNodeMapper { static func map(_ script: FountainScript) -> [ProjectAST.FountainNode] }`

Mapping rules (each is a spec-ledger row — implement exhaustively over `ScreenplayElement`):
- `.boneyard`, `.note`, `.synopsis`, `.section` → **omitted** (author-only / organizational).
- `.titlePage` lines → skipped; `script.titlePage` (when non-nil) emits one leading `.titlePage(fields)` mapping `TitlePageField(key:value:)` → `ProjectAST.TitleField`.
- `.sceneHeading` → `.sceneHeading(content, sceneNumber: line.sceneNumber)`.
- `.action` → coalesce consecutive `.action` lines (blank-line-separated groups stay separate: a zero-length/blank action line flushes the buffer) → `.action(FountainInline.parse(joined-by-space))`.
- `.character` → `.character(content)`; following `.dialogue`/`.parenthetical` lines map to `.dialogue(FountainInline.parse(…))` (consecutive dialogue lines coalesce, parenthetical flushes — same coalescing the old parser did) until the block ends.
- Dual dialogue: when a character block's cue line has `isDualSecond == true`, pair it with the immediately preceding character block: `.dualDialogue(left: precedingBlock, right: thisBlock)` replacing both.
- `.transition` → `.transition(content)`; `.centered` → `.centered(FountainInline.parse(content))`; `.lyric` → `.lyric(FountainInline.parse(content))`; `.pageBreak` → `.pageBreak`.
- Empty/whitespace-only `.action` lines produce nothing (they only delimit).

- [ ] **Step 1: Failing tests** — feed REAL Fountain source through `FountainTokenizer().parse` then `map`:

```swift
func test_boneyardAndNotes_omitted() {
    let src = "INT. HOUSE - DAY\n\n/* cut this */\n\nAction stays. [[fix me]]\n"
    let nodes = FountainNodeMapper.map(FountainTokenizer().parse(src))
    XCTAssertEqual(nodes.count, 2)   // sceneHeading + action
    guard case .action(let inlines) = nodes[1] else { return XCTFail() }
    // inline note span excluded from published action text
    XCTAssertFalse(inlines.contains { if case .text(let t) = $0 { return t.contains("[[") } ; return false })
}
func test_synopsisAndSection_omitted() {
    let nodes = FountainNodeMapper.map(FountainTokenizer().parse(
        "# Act One\n\n= She discovers the letter.\n\nINT. A - DAY\n"))
    XCTAssertEqual(nodes, [.sceneHeading("INT. A - DAY", sceneNumber: nil)])
}
func test_dualDialogue_pairs() {
    let src = "ALICE\nHello.\n\nBOB ^\nHi.\n"
    let nodes = FountainNodeMapper.map(FountainTokenizer().parse(src))
    guard case .dualDialogue(let left, let right) = nodes[0] else { return XCTFail() }
    XCTAssertEqual(left.first, .character("ALICE"))
    XCTAssertEqual(right.first, .character("BOB"))   // caret stripped by tokenizer
}
func test_lyric_centered_pageBreak() {
    let nodes = FountainNodeMapper.map(FountainTokenizer().parse(
        "~The moon is out\n\n> THE END <\n\n===\n"))
    XCTAssertEqual(nodes[0], .lyric([.text("The moon is out")]))
    XCTAssertEqual(nodes[1], .centered([.text("THE END")]))
    XCTAssertEqual(nodes[2], .pageBreak)
}
func test_forcedElements_markersStripped() {
    let nodes = FountainNodeMapper.map(FountainTokenizer().parse(
        ".SNIPER SCOPE\n\n@McClane\nYippee.\n\n!LOUD NOISE\n"))
    XCTAssertEqual(nodes[0], .sceneHeading("SNIPER SCOPE", sceneNumber: nil))
    XCTAssertEqual(nodes[1], .character("McClane"))
    // !LOUD NOISE is action, not a character cue
    XCTAssertEqual(nodes[3], .action([.text("LOUD NOISE")]))
}
```
Also add `sceneNumber: String? = nil` to `FountainLine` (stored property + init param, default nil) in this task so the mapper compiles; run the CORE suite too (both schemes — FountainLine is shared).

- [ ] **Step 2:** Run — FAIL (`FountainNodeMapper` undefined).
- [ ] **Step 3:** Implement the mapper (single pass over `script.lines` with a small state machine mirroring the rules above — model on the inline note-span exclusion: for `.action`/`.dialogue` content, strip `[[…]]` inline-note substrings via the line's `.note` inlineSpans before `FountainInline.parse`).
- [ ] **Step 4:** Mac + phone + core suites green.
- [ ] **Step 5: Commit** `feat(publish): FountainNodeMapper — tokenizer-backed AST with author-only content omitted`

### Task 7: Cut ProjectASTBuilder over to the mapper

**Files:**
- Modify: `Maugham/Publish/ProjectASTBuilder.swift` — `parseFountain` body becomes `MarkdownDisplayFilter.stripAnchors` → `FountainTokenizer().parse` → `FountainNodeMapper.map` (keep the anchor strip!); DELETE the old classifier (`isSceneHeading`, `transitionText`, `isCharacter` at :306-340), DELETE the duplicate `parseTitlePage`/`titlePageKeyMap`/`canonicalTitleKey`/`parseTitleKey` (:233-305), delete the stale "bridges through" comment.
- Test: existing `ProjectASTBuilder` fountain tests — update expectations that pinned the OLD wrong behavior (e.g. space-form `INT ` headings, `MRS. SMITH`-as-action); each changed expectation cites its audit finding in a comment.

- [ ] **Step 1:** Update/extend builder tests first (failing): a fixture exercising title page + scene + dual dialogue + boneyard + note + lyric + `===` end-to-end via `ProjectASTBuilder.build`.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Swap the implementation; delete dead code.
- [ ] **Step 4:** Full Mac suite green (emission goldens still only cover prose).
- [ ] **Step 5: Commit** `fix(publish): fountain publishes via the real tokenizer — boneyard/notes/synopses no longer leak (audit A1)`

### Task 8: Strikethrough LaTeX probe + emission-contract expansion

**Files:**
- Modify: `Maugham/Publish/EmissionContract.swift` (+ regenerate `Resources/PublishStarter/EMISSION.md` per its test's instructions)
- Modify (if probe fails): `LaTeXBodyEmitter` strikethrough macro + starter `preamble.tex` (locate under `Maugham/Resources/PublishStarter/`)
- Test: `EmissionContractTests`, tectonic compile tests (locate: `grep -rl -i tectonic MaughamTests`)

- [ ] **Step 1: Probe.** Add a tectonic compile test whose source uses `\usepackage{soul}` + `\st{gone}` (soul first; fallback `ulem`+`\sout`). Run it against the bundled tectonic. Whichever package compiles clean is the macro; if NEITHER ships, define `\providecommand{\st}[1]{#1}` fallback in the body prologue AND add `\usepackage{soul}` to the starter preamble (new projects strike through; existing templates degrade to plain text rather than failing to compile). Record the outcome in the commit message.
- [ ] **Step 2:** Point Task 3's `\st` emission at the winning macro; add the chosen package to the starter `preamble.tex`.
- [ ] **Step 3:** Extend `EmissionContract.proseExamples`:
```swift
.init(label: "Bold italic", source: "Both ***kinds*** now."),
.init(label: "Strikethrough", source: "Cut ~~this clause~~ entirely."),
.init(label: "Escaped asterisk", source: #"A literal \*star\* here."#),
.init(label: "Underscore is literal in prose", source: "snake_case stays flat."),
```
and add a `fountainExamples: [Example]` array + an `emittedFountain(_:)` helper (mirror `emittedProse` with `mode: .fountain`) + a "Fountain positive space" section in `renderMarkdown()` covering: scene heading with number (`"INT. HOUSE - DAY #4A#"` — number renders after Task 11; include now, regenerate then), dual dialogue, lyric, centered, `===`, boneyard-omitted (`"/* gone */\n\nKept."`), note-omitted.
- [ ] **Step 4:** Regenerate EMISSION.md; run `EmissionContractTests` + compile tests — green.
- [ ] **Step 5: Commit** `feat(publish): strikethrough macro probed against bundled tectonic + EMISSION contract locks new grammar`

---

## Phase 3 — Prose features through the surfaces

### Task 9: Publish lists + fence guard + backslash hard break

**Files:**
- Modify: `Maugham/Publish/ProjectAST.swift` (`ProseNode` gains `case list(ordered: Bool, items: [[Inline]])` and `case verbatim([String])`)
- Modify: `Maugham/Publish/ProjectASTBuilder.swift` `parseProseBlocks` (:57-103)
- Modify: both emitters' `emit(prose:)`
- Modify: `Maugham/Publish/InlineParser.swift` (backslash-newline hard break)
- Test: builder + emitter + `InlineParserTests`

**Interfaces:** list detection at block level: a line matching `^\s*([-*+]|\d{1,9}[.)])\s+` starts a list block; consecutive list lines (plus their indented continuations) collect items; blank line ends it; item text runs through `InlineParser.parse`. One level only (nested indent beyond the first marker column stays inside the item's text — YAGNI per spec "basic nesting, tight rendering" means: flat items, tight spacing). Fence: a line whose trim starts with ``` opens `verbatim`; lines collect raw until the closing fence (or end); NO inline parsing. Emission — LaTeX: `\begin{itemize}/\begin{enumerate}` + `\item …`; verbatim: each line LaTeX-escaped + `\\` joined inside a `\begingroup\ttfamily…\endgroup`? NO — spec says "no monospace pretension": emit each line as escaped text joined by `\\` in a plain paragraph. XHTML: `<ul>/<ol><li>…</li></ul>`, verbatim → `<p class="verbatim">line<br/>line</p>`.

- [ ] **Step 1: Failing tests**
```swift
func test_unorderedList_parses() {
    let nodes = buildProse("- one\n- two *em*\n")
    XCTAssertEqual(nodes, [.prose(.list(ordered: false,
        items: [[.text("one")], [.text("two "), .emphasis([.text("em")])]]))])
}
func test_orderedList_bothDelimiters() {
    XCTAssertEqual(buildProse("1. a\n2) b\n"),
        [.prose(.list(ordered: true, items: [[.text("a")], [.text("b")]]))])
}
func test_fence_verbatim_noInlineMangle() {
    let nodes = buildProse("```\n*not em*\n`nor code`\n```\n")
    XCTAssertEqual(nodes, [.prose(.verbatim(["*not em*", "`nor code`"]))])
}
func test_backslashHardBreak() {
    XCTAssertEqual(InlineParser.parse("a\\\nb"),
                   [.text("a"), .lineBreak, .text("b")])
}
```
(`buildProse` = tiny helper using the existing single-piece builder path, mirroring `SinglePieceSource` in `EmissionContract.swift:183`.)
- [ ] **Step 2:** Run — FAIL. **Step 3:** Implement (list/fence branches BEFORE the paragraph accumulator in `parseProseBlocks`; hard break in `InlineParser`'s protected-span pre-extraction: `\` at line end, i.e. `"\\\n"`, → `.lineBreak` — note this must run BEFORE the generic escape pre-pass eats the backslash). **Step 4:** Full Mac suite + regenerate EMISSION.md with two new examples (`"- one\n- two"`, fence). **Step 5: Commit** `feat(publish): list emission + fence mangle-guard + backslash hard break`

### Task 10: Editor scene-break parity

**Files:**
- Modify: `Maugham/Editor/Tokenizer/MarkdownTokenizer.swift:206-211` (horizontal-rule pattern)
- Test: `MaughamTests/MarkdownTokenizerTests.swift`

- [ ] **Step 1: Failing tests** — `***` alone on a line styles as `.horizontalRule` (verify exact TokenKind name at `Maugham/Editor/Token.swift`); `###` alone likewise; `# H` still a heading; `***x***` still emphasis; `####` (4+) NOT a scene break (matches publish's exactly-3 rule — `isSceneBreakLine` strips spaces then compares equality).
- [ ] **Step 2:** FAIL. **Step 3:** Replace pattern `(?m)^(---+)\s*$` with `(?m)^ {0,3}(-{3,}|\*{3}|#{3})\s*$` and ensure the rule pass runs BEFORE heading + emphasis passes so `###`/`***` lines are claimed first (the overlap-skip in `addMatches` then keeps heading/emphasis off them). Publish accepts `-{3,}` via space-stripping equality only for exactly `---`; align publish's `isSceneBreakLine` to accept `-{3,}` too (one-line change + builder test).
- [ ] **Step 4:** Green. **Step 5: Commit** `feat(editor): ***/### scene-break styling parity with publish`

---

## Phase 4 — Fountain core expansion (oracle-revising)

Each task here revises `FountainTokenizerReference.swift` deliberately. Procedure per task: change the REAL tokenizer test first, run the differential suite, port the SAME rule to the reference, re-run differential + fuzz. Commit message lists the ledger row.

### Task 11: Scene numbers `#…#`

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/FountainTokenizer.swift` (scene-heading branch, contextual ~:559 and forced ~:490)
- Modify: `Packages/MaughamCore/Sources/MaughamCore/FountainLine.swift` (property landed in Task 6; add `FountainInlineSpan.sceneNumber` case)
- Modify: `Maugham/Editor/ScreenplayMode.swift` (span switch — fade like `emphasisMarker`), `MaughamPhone/Read/FountainSemanticRenderer.swift` (same fade, opacity 0.3)
- Modify: `Maugham/Publish/FountainNodeMapper.swift` (already reads `line.sceneNumber` — no change; delete the Task 6 stub comment)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/FountainTokenizerDifferentialTests.swift` + unit tests; `MaughamPhoneTests/FountainStylerTests.swift`

Rule (spec): a scene heading may end with `#<id>#` where `<id>` is 1+ chars of `[0-9A-Za-z.-]`; strip it (and preceding spaces) from `content`, store in `sceneNumber`, and report the marker range (including both `#`) as an `inlineSpans` entry `.sceneNumber` so Mac/phone fade it in place.

- [ ] **Step 1: Failing core tests**
```swift
func test_sceneNumber_extractedAndStripped() {
    let s = FountainTokenizer().parse("INT. HOUSE - DAY #4A#\n")
    XCTAssertEqual(s.lines[0].element, .sceneHeading)
    XCTAssertEqual(s.lines[0].sceneNumber, "4A")
    XCTAssertEqual(s.lines[0].content, "INT. HOUSE - DAY")
    XCTAssertTrue(s.lines[0].inlineSpans.contains {
        if case .sceneNumber = $0.kind { return true }; return false })
}
func test_hashLine_stillSection_notSceneNumber() {
    let s = FountainTokenizer().parse("# Act One\n")
    XCTAssertEqual(s.lines[0].element, .section(level: 1))
}
func test_nonHeading_hashSuffix_untouched() {
    let s = FountainTokenizer().parse("He wrote #1# on the wall.\n")
    XCTAssertEqual(s.lines[0].element, .action)
    XCTAssertNil(s.lines[0].sceneNumber)
}
```
(Verify `FountainInlineSpan`'s exact shape — it has a `kind`-like payload at `ScreenplayElement.swift:34-39`; add the case to that enum and update BOTH exhaustive consumers the compiler flags: `ScreenplayMode.applyInlineSpan` and `FountainSemanticRenderer`.)
- [ ] **Steps 2–4:** FAIL → implement (extraction only inside the two scene-heading branches) → port to reference → core + Mac + phone suites green.
- [ ] **Step 5: Commit** `feat(core): scene numbers #…# parsed, faded on both surfaces, published right-aligned` — then regenerate EMISSION.md (the Task 8 scene-number example now renders its number).

### Task 12: Dot-less scene-heading stems

**Files:** `FountainTokenizer.swift:655-657` (`sceneHeadingPrefixes`) + reference + tests.

Rule: stems `INT`, `EXT`, `EST`, `INT/EXT`, `EXT/INT`, `I/E` followed by `.` (as today) **or a space**. Implementation: replace the dotted-prefix array with stem matching: uppercase-insensitive match of stem, then require next char is `.` or space (then at least one more non-space char somewhere — `"INT "` alone isn't a heading; `"INTERIOR"` must NOT match since `INT` is followed by `E`).

- [ ] **Step 1: Failing tests** — `"INT ROOM - DAY"` → sceneHeading; `"I/E CAR - NIGHT"` → sceneHeading; `"EXT/INT. HOUSE"` → sceneHeading; `"INTERIOR SHOT"` → action; `"INT."` alone → sceneHeading (today's behavior, keep); `"Interesting things happened."` → action (lowercase prose starting "Int…" — case-insensitivity means the blank-line gate + the mixed-case content is NOT protection; the spec accepts case-insensitive stems, so `"Interior"` fails on the stem-boundary rule, but `"Int room"` after a blank line WILL now classify as sceneHeading — this is spec-correct; pin it with a test and note it in fountain-syntax.md).
- [ ] **Steps 2–4:** FAIL → implement in tokenizer → port to reference AND to `ScreenplayLineMutator.swift:188`'s private copy (keep the mutator generating dotted headings — only its *recognition* set widens) → all suites green.
- [ ] **Step 5: Commit** `feat(core): spec-valid dot-less scene heading stems`

### Task 13: Two-space held blank line in dialogue

**Files:** `FountainTokenizer.swift` (blank handling ~:159 + dialogue-state reset ~:299-310) + reference + tests.

Rule: a line consisting of whitespace only but with length ≥ 1 (canonically two spaces), occurring while the previous element is `.dialogue`/`.parenthetical`/`.character`, is a `.dialogue` line with empty content — it does NOT end the block. A truly empty line (length 0) still ends it.

- [ ] **Step 1: Failing test**
```swift
func test_twoSpaceLine_holdsDialogueOpen() {
    let s = FountainTokenizer().parse("DAN\nThen.\n  \nWhaddya want?\n")
    XCTAssertEqual(s.lines.map(\.element),
                   [.character, .dialogue, .dialogue, .dialogue])
}
func test_emptyLine_stillEndsDialogue() {
    let s = FountainTokenizer().parse("DAN\nThen.\n\nAction now.\n")
    XCTAssertEqual(s.lines.map(\.element),
                   [.character, .dialogue, .action, .action])
    // (line 3 is the blank; verify against actual blank-line representation
    //  in FountainScript — adjust expectation to the tokenizer's real shape)
}
```
- [ ] **Steps 2–4:** FAIL → implement → port to reference → suites green; also verify `FountainNodeMapper` treats the held line as a dialogue continuation (add a mapper test: held blank produces a single `.dialogue` node whose text preserves the break as `.lineBreak`).
- [ ] **Step 5: Commit** `feat(core): two-space held blank keeps dialogue block open (Fountain spec)`

---

## Phase 5 — Renderer fixes

### Task 14: Help window — ordered lists + pipe tables

**Files:**
- Modify: `Maugham/Views/GuideMarkdownView.swift` (block enum :9-14, parser :26-65, render view)
- Test: `MaughamTests/GuideMarkdownViewTests.swift`

**Interfaces:** `Block` gains `case orderedItem(number: String, text: String)` and `case table(header: [String], rows: [[String]])`. Parser: a trimmed line matching `^\d{1,9}[.)]\s+` emits `orderedItem` (no reflow-merge into paragraphs); a line containing `|` followed by a `|---|`-style delimiter line opens a table — collect subsequent `|`-lines, split on unescaped `|`, trim cells. Render: ordered items as `Text("\(number). ") + inline(text)` rows; table as a SwiftUI `Grid` with header row bolded, cells through the existing `AttributedString(markdown:)` inline path. These are deliberately thin (spec: disposable patches whose TESTS transfer to a future shared block parser — keep tests parser-level, not view-level).

- [ ] **Step 1: Failing tests** — parse `"1. Install\n2. Open"` → two orderedItems (NOT one reflowed paragraph); parse the actual `docs/guide/reference.md` file from the bundle/repo and assert at least one `.table` block whose header contains "Shortcut" (open the file first to copy real header text); a paragraph containing a literal `|` without a delimiter row stays a paragraph.
- [ ] **Steps 2–4:** FAIL → implement → green. Manually build + open Help window (⌘?) on the Reference topic — visually confirm the grid.
- [ ] **Step 5: Commit** `fix(help): ordered lists + pipe tables render (shipped corpus was mangled — audit A3)`

### Task 15: Research preview paragraph grouping + editor image-tail fix

**Files:**
- Modify: `Maugham/Views/ResearchNotePreviewPane.swift:41-81` (line loop)
- Modify: `Maugham/Editor/Tokenizer/MarkdownTokenizer.swift` (inline-link pass :74-97)
- Test: research preview parse tests (locate: `grep -rl ResearchNotePreview MaughamTests`; create `ResearchNotePreviewParseTests.swift` if none) + `MarkdownTokenizerTests`

- [ ] **Step 1: Failing tests** — research: `"line one\nline two\n\npara two"` parses to TWO paragraph blocks ("line one line two" joined with a space, then "para two") — not three; solo-image lines and headings still recognized mid-buffer (they flush the paragraph buffer). Editor: `"![alt](x.png)"` produces NO link tokens (negative lookbehind for `!`) while `"[a](b)"` still does.
- [ ] **Steps 2–4:** FAIL → implement (research: accumulate non-empty, non-heading, non-image lines; flush on blank/heading/image/EOF, join with `" "`; editor: change link pattern to `(?<!\!)\[([^\]\n]+)\]\(([^\)\n]+)\)`) → green.
- [ ] **Step 5: Commit** `fix(views): research preview paragraph grouping (audit A4) + image-tail no longer link-styled (audit A5)`

---

## Phase 6 — Docs, contracts, ledger ADR

### Task 16: Docs + contracts sweep

**Files:**
- Rewrite: `Maugham/Resources/markdown-syntax.md`, `Maugham/Resources/fountain-syntax.md`
- Modify: stale comments — `Packages/MaughamCore/Sources/MaughamCore/FountainTokenizer.swift:575-584` (remove the "post-pass" claim; state the live-editing rule), `Maugham/Editor/Tokenizer/MarkdownTokenizer.swift:4-6` (header list of non-features), `Maugham/Publish/InlineParser.swift` header (now an adapter)
- Modify: `docs/superpowers/notes/cross-surface-contracts.md` (+rows: strikethrough trait via `EmphasisTraits`; sceneNumber span; "publish inline/fountain = scanner/tokenizer adapters" row so publish is inside the registry)
- Create: `docs/adr/00XX-commonmark-fountain-ledger.md` (`ls docs/adr | sort | tail -1` for the next number) — records the writer-first philosophy + the full IN/OUT ledger by reference to the spec, so future audits treat these as intentional
- Modify: `docs/guide/*.md` if any construct still exceeds the upgraded Help renderer (verify by running the Task 14 parser over every guide file in a test: no line-run that silently degrades; add that as a permanent `GuideCorpusRenderabilityTest`)
- Modify: `docs/roadmap.md` (mark audit actions done; add "approach C review" entry), `README.md` if it lists formatting support

Doc content requirements (each fixes an audit C-item): markdown-syntax gains strikethrough, escapes, paragraph-scoped emphasis, scene-break forms; corrects the task-checkbox line (C1) and the links overclaim (C4); adds the deliberate-omission list additions (setext, indented code, autolinks, `1)` in editor styling — now supported in publish lists, note the asymmetry honestly). fountain-syntax gains scene numbers, dot-less stems, held blank, escapes; corrects the all-caps-alone rule (C2) and `FADE OUT:` (C3); documents `"Int room"` case-insensitivity consequence (Task 12).

- [ ] **Step 1:** Write the `GuideCorpusRenderabilityTest` (failing if any guide file has unhandled constructs).
- [ ] **Step 2:** Sweep all files above; regenerate EMISSION.md one final time.
- [ ] **Step 3:** Full Mac + phone + core suites green.
- [ ] **Step 4: Commit** `docs: syntax help + contracts registry + ledger ADR match shipped grammar (audit C1–C7)`

### Task 17: Milestone exit gates

- [ ] **Step 1:** Full test matrix: core (`swift test`), Mac scheme, phone scheme — all green; paste counts.
- [ ] **Step 2:** Release-config build: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO` (publish + views touched; the Release type-check budget is stricter).
- [ ] **Step 3:** Prepare the user smoke checklist (post it, then STOP for manual smoke — the user runs it):
  1. Screenplay: type a scene with `#4A#` number, dual dialogue (`^`), a `~lyric`, `/* boneyard */`, `[[note]]`, `===` → publish PDF + EPUB → verify: number right-aligned, true side-by-side dual columns, italic lyric, NO boneyard/note text, real page break.
  2. Prose: stanza-spanning `*italic*` across a hard break, `~~strikethrough~~`, `\*literal\*`, a `- list`, a ``` fence → editor styling correct → phone reader → PDF + EPUB.
  3. Help ⌘? → Reference topic shows the shortcut table as a grid.
  4. Typing feel at a large doc (perf regression sanity).
- [ ] **Step 4:** After user smoke passes: A-vs-C review conversation (spec checkpoint), then merge/tag per `docs/RELEASING.md` and update memory (`MEMORY.md` + milestone file).

## Self-review notes (already applied)

- Spec coverage: every ledger row maps to a task (strikethrough 1/2/3/8; escapes 1/2/3; paragraph scope 2; lists/fence/hard-break 9; scene-break parity 10; publish-Fountain rewrite 5/6/7; lyrics 5/6; scene numbers 6/11; dot-less 12; held blank 13; underscore-alignment 3; Help 14; research+image-tail 15; docs/ADR/registry 16; perf gate 4; Release build + smoke 17).
- Type consistency: `EmphasisTraits.strikethrough` (Task 1) consumed in Tasks 2/3; `FountainNode` arity (Task 5) consumed in 6/7/8; `FountainLine.sceneNumber` added in Task 6 (stub) and populated in Task 11 — intentional two-step, both tasks say so.
- Known judgment calls delegated to implementers WITH guardrails: exact `TokenKind` names (verify in `Token.swift`), test-file locations (locate commands given), blank-line representation in `FountainScript` (Task 13 test notes it).

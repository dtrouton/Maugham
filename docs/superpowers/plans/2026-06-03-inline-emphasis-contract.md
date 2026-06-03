# Inline Emphasis Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `***bold italic***` and nested asterisk emphasis (`*a **b** a*`) render identically on all four surfaces, with the asterisk-emphasis grammar living in one place that can't silently drift.

**Architecture:** A new `InlineEmphasisScanner` in MaughamCore parses asterisk emphasis into a *flattened* `EmphasisScan { runs, markers }` (non-overlapping content runs each carrying cumulative `EmphasisTraits`, plus marker ranges to fade). The two hand-rolled tokenizers (Mac `MarkdownTokenizer`, shared `FountainTokenizer`) call it; the phone markdown reader keeps Apple's parser and is pinned to the scanner by a contract test.

**Tech Stack:** Swift, MaughamCore (Foundation-only SPM package), AppKit (`NSTextStorage`), SwiftUI (`AttributedString`), XCTest.

**Spec:** `docs/superpowers/specs/2026-06-03-inline-emphasis-contract-design.md`

---

## File Structure

**Create (MaughamCore):**
- `Packages/MaughamCore/Sources/MaughamCore/EmphasisTraits.swift` — `EmphasisTraits` OptionSet
- `Packages/MaughamCore/Sources/MaughamCore/InlineEmphasisScanner.swift` — `EmphasisScan` + the parser
- `Packages/MaughamCore/Tests/MaughamCoreTests/InlineEmphasisScannerTests.swift` — parser unit tests
- `Packages/MaughamCore/Tests/MaughamCoreTests/InlineEmphasisAppleParityTests.swift` — contract test vs Apple's parser

**Modify:**
- `Packages/MaughamCore/Sources/MaughamCore/ScreenplayElement.swift` — `FountainInlineSpan.Kind` cases
- `Packages/MaughamCore/Sources/MaughamCore/FountainTokenizer.swift` — `inlineSpans` routes asterisks through the scanner
- `Maugham/Editor/ScreenplayMode.swift` — `applyInlineSpan` switch
- `MaughamPhone/Read/FountainSemanticRenderer.swift` — `apply` switch
- `Maugham/Editor/Token.swift` — `Token.Kind.emphasis`
- `Maugham/Editor/Tokenizer/MarkdownTokenizer.swift` — emphasis block routes through the scanner
- `Maugham/Editor/ProseMode.swift` — `attributes(for:)` emphasis case
- `docs/superpowers/notes/cross-surface-contracts.md` — registry entry

**Update existing tests (compile breaks from the enum changes):**
- Fountain: `MaughamTests/InlineEmphasisTests.swift`, `InlineEmphasisStylingTests.swift`, `ScreenplayModeStylingTests.swift`; `MaughamPhoneTests/FountainInlineEmphasisTests.swift`, `ScreenplayEmphasisContractTests.swift`, `FountainStylerTests.swift`
- Prose: `MaughamTests/TokenTests.swift`, `MarkdownTokenizerTests.swift`

---

## Task 1: `EmphasisTraits` OptionSet

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/EmphasisTraits.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/InlineEmphasisScannerTests.swift` (created here, grows in Task 2)

- [ ] **Step 1: Write the failing test**

Create `Packages/MaughamCore/Tests/MaughamCoreTests/InlineEmphasisScannerTests.swift`:

```swift
import XCTest
@testable import MaughamCore

final class InlineEmphasisScannerTests: XCTestCase {
    func testTraitsSetSemantics() {
        let both: EmphasisTraits = [.bold, .italic]
        XCTAssertTrue(both.contains(.bold))
        XCTAssertTrue(both.contains(.italic))
        XCTAssertEqual(EmphasisTraits.bold.union(.italic), both)
        XCTAssertTrue(EmphasisTraits().isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/MaughamCore --filter InlineEmphasisScannerTests`
Expected: FAIL to compile — "cannot find 'EmphasisTraits' in scope".

- [ ] **Step 3: Write the implementation**

Create `Packages/MaughamCore/Sources/MaughamCore/EmphasisTraits.swift`:

```swift
import Foundation

/// Combinable font-emphasis traits for inline text. Bold and italic are
/// orthogonal — model them as a bitfield so "both" falls out of the set
/// instead of being a special case (this mirrors Apple's
/// `InlinePresentationIntent`). Underline is NOT here: it is a separate
/// rendering axis (`underlineStyle`, not font) and is Fountain-only.
public struct EmphasisTraits: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold   = EmphasisTraits(rawValue: 1 << 0)
    public static let italic = EmphasisTraits(rawValue: 1 << 1)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/MaughamCore --filter InlineEmphasisScannerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/EmphasisTraits.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/InlineEmphasisScannerTests.swift
git commit -m "feat(core): EmphasisTraits OptionSet (bold, italic)"
```

---

## Task 2: `InlineEmphasisScanner` (the flattened parser)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/InlineEmphasisScanner.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/InlineEmphasisScannerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `InlineEmphasisScannerTests.swift` (inside the class):

```swift
    // Helper: turn runs into (substring, traits) for readable assertions.
    private func runs(_ s: String) -> [(String, EmphasisTraits)] {
        let ns = s as NSString
        return InlineEmphasisScanner.scan(ns).runs.map {
            (ns.substring(with: $0.range), $0.traits)
        }
    }
    private func markers(_ s: String) -> [String] {
        let ns = s as NSString
        return InlineEmphasisScanner.scan(ns).markers.map { ns.substring(with: $0) }
    }

    func testPlainText() {
        XCTAssertTrue(runs("just words").isEmpty)
        XCTAssertTrue(markers("just words").isEmpty)
    }

    func testItalic() {
        XCTAssertEqual(runs("*x*").map(\.1), [.italic])
        XCTAssertEqual(runs("*x*").map(\.0), ["x"])
        XCTAssertEqual(markers("*x*"), ["*", "*"])
    }

    func testBold() {
        XCTAssertEqual(runs("**x**").map(\.1), [[.bold]])
        XCTAssertEqual(markers("**x**"), ["**", "**"])
    }

    func testBoldItalicCombined() {
        let r = runs("***x***")
        XCTAssertEqual(r.map(\.0), ["x"])
        XCTAssertEqual(r.map(\.1), [[.bold, .italic]])
        XCTAssertEqual(markers("***x***"), ["***", "***"])
    }

    func testBoldNestedInsideItalic() {
        // *a **b** a*  ->  "a "(italic) "b"(both) " a"(italic)
        let r = runs("*a **b** a*")
        XCTAssertEqual(r.map(\.0), ["a ", "b", " a"])
        XCTAssertEqual(r.map(\.1), [[.italic], [.italic, .bold], [.italic]])
    }

    func testItalicNestedInsideBold() {
        let r = runs("**a *b* a**")
        XCTAssertEqual(r.map(\.0), ["a ", "b", " a"])
        XCTAssertEqual(r.map(\.1), [[.bold], [.bold, .italic], [.bold]])
    }

    func testUnbalancedRendersLiteral() {
        XCTAssertTrue(runs("**x").isEmpty)     // no closer
        XCTAssertTrue(markers("**x").isEmpty)  // nothing consumed -> not faded
        XCTAssertTrue(runs("no *stars here").isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MaughamCore --filter InlineEmphasisScannerTests`
Expected: FAIL to compile — "cannot find 'InlineEmphasisScanner' in scope".

- [ ] **Step 3: Write the implementation**

Create `Packages/MaughamCore/Sources/MaughamCore/InlineEmphasisScanner.swift`:

```swift
import Foundation

/// Flattened result of scanning asterisk emphasis in one string.
/// `runs` are non-overlapping content ranges (markers excluded), each carrying
/// the CUMULATIVE traits active there. `markers` are the asterisk ranges to
/// fade/hide. Doing the flattening here — once, centrally — means no renderer
/// needs composition logic or marker-length arithmetic.
public struct EmphasisScan: Sendable, Equatable {
    public struct Run: Sendable, Equatable {
        public let range: NSRange
        public let traits: EmphasisTraits
        public init(range: NSRange, traits: EmphasisTraits) {
            self.range = range; self.traits = traits
        }
    }
    public let runs: [Run]
    public let markers: [NSRange]
    public init(runs: [Run], markers: [NSRange]) {
        self.runs = runs; self.markers = markers
    }
}

/// The single source of truth for what asterisk emphasis means
/// (`*italic*`, `**bold**`, `***both***`, plus nesting). Asterisk-only by
/// design: underscore is emphasis in Markdown but underline in Fountain, so it
/// is each grammar's own concern. Unbalanced/pathological runs render literal.
public enum InlineEmphasisScanner {

    public static func scan(_ text: NSString) -> EmphasisScan {
        let n = text.length
        let star = UInt16(UnicodeScalar("*").value)

        // 1. Collect asterisk runs.
        struct AsteriskRun { let location: Int; let length: Int }
        var astRuns: [AsteriskRun] = []
        var i = 0
        while i < n {
            if text.character(at: i) == star {
                let start = i
                while i < n && text.character(at: i) == star { i += 1 }
                astRuns.append(AsteriskRun(location: start, length: i - start))
            } else {
                i += 1
            }
        }
        if astRuns.isEmpty { return EmphasisScan(runs: [], markers: []) }

        // 2. Flanking (whitespace-based; punctuation-adjacent emphasis is
        //    out of scope). A string edge counts as whitespace.
        func isSpace(_ idx: Int) -> Bool {
            guard idx >= 0 && idx < n else { return true }
            let c = text.character(at: idx)
            return c == 32 || c == 9 || c == 10 || c == 13
        }
        struct Delim {
            let location: Int
            let original: Int
            var remaining: Int
            let canOpen: Bool
            let canClose: Bool
        }
        var delims: [Delim] = astRuns.map { r in
            let leftFlanking = !isSpace(r.location + r.length) // non-space after
            let rightFlanking = !isSpace(r.location - 1)       // non-space before
            return Delim(location: r.location, original: r.length,
                         remaining: r.length,
                         canOpen: leftFlanking, canClose: rightFlanking)
        }

        // 3. Delimiter-stack matching. Emit nested emphasis spans (content may
        //    cover inner markers — that is fine, they are excluded at flatten
        //    time) and collect every consumed asterisk as a marker.
        struct Emph { let range: NSRange; let bold: Bool }
        var emphases: [Emph] = []
        var markerRanges: [NSRange] = []

        var closerIdx = 0
        while closerIdx < delims.count {
            guard delims[closerIdx].canClose, delims[closerIdx].remaining > 0 else {
                closerIdx += 1; continue
            }
            var openerIdx = closerIdx - 1
            var matchedThisCloser = false
            while openerIdx >= 0 {
                if delims[openerIdx].canOpen, delims[openerIdx].remaining > 0 {
                    let use = (delims[openerIdx].remaining >= 2
                               && delims[closerIdx].remaining >= 2) ? 2 : 1
                    // Opener consumes its RIGHTMOST `use`; closer its LEFTMOST.
                    let openMarkerLoc =
                        delims[openerIdx].location + delims[openerIdx].remaining - use
                    markerRanges.append(NSRange(location: openMarkerLoc, length: use))
                    let closerConsumed =
                        delims[closerIdx].original - delims[closerIdx].remaining
                    let closeMarkerLoc = delims[closerIdx].location + closerConsumed
                    markerRanges.append(NSRange(location: closeMarkerLoc, length: use))

                    // Content spans from the opener run's far-right edge to the
                    // closer run's far-left edge (full-run edges — inner markers
                    // get excluded when we flatten).
                    let contentStart = delims[openerIdx].location + delims[openerIdx].original
                    let contentEnd = delims[closerIdx].location
                    if contentEnd > contentStart {
                        emphases.append(Emph(
                            range: NSRange(location: contentStart,
                                           length: contentEnd - contentStart),
                            bold: use == 2))
                    }
                    delims[openerIdx].remaining -= use
                    delims[closerIdx].remaining -= use
                    matchedThisCloser = true
                    if delims[closerIdx].remaining == 0 { break }
                } else {
                    openerIdx -= 1
                }
            }
            if !matchedThisCloser { closerIdx += 1 }
        }

        // 4. Flatten: accumulate cumulative traits per index, drop marker
        //    indices, coalesce into runs.
        var perIndex = [EmphasisTraits](repeating: [], count: n)
        for e in emphases {
            let trait: EmphasisTraits = e.bold ? .bold : .italic
            for idx in e.range.location ..< (e.range.location + e.range.length) {
                perIndex[idx].insert(trait)
            }
        }
        var markerSet = Set<Int>()
        for m in markerRanges {
            for idx in m.location ..< (m.location + m.length) { markerSet.insert(idx) }
        }

        var runs: [EmphasisScan.Run] = []
        var idx = 0
        while idx < n {
            if markerSet.contains(idx) || perIndex[idx].isEmpty { idx += 1; continue }
            let start = idx
            let traits = perIndex[idx]
            while idx < n, !markerSet.contains(idx), perIndex[idx] == traits { idx += 1 }
            runs.append(EmphasisScan.Run(
                range: NSRange(location: start, length: idx - start), traits: traits))
        }

        // Coalesce adjacent marker indices into clean ranges (e.g. *** -> one span).
        let sortedMarkers = markerSet.sorted()
        var markers: [NSRange] = []
        var m = 0
        while m < sortedMarkers.count {
            let start = sortedMarkers[m]
            var end = start
            while m + 1 < sortedMarkers.count, sortedMarkers[m + 1] == end + 1 {
                end = sortedMarkers[m + 1]; m += 1
            }
            markers.append(NSRange(location: start, length: end - start + 1))
            m += 1
        }

        return EmphasisScan(runs: runs, markers: markers)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MaughamCore --filter InlineEmphasisScannerTests`
Expected: PASS (all cases including nested and unbalanced).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/InlineEmphasisScanner.swift \
        Packages/MaughamCore/Tests/MaughamCoreTests/InlineEmphasisScannerTests.swift
git commit -m "feat(core): InlineEmphasisScanner — flattened asterisk emphasis + nesting"
```

---

## Task 3: Contract test — scanner agrees with Apple's parser

This pins the phone markdown reader (which uses Apple's `AttributedString(markdown:)`) to the shared scanner. It is the oracle that keeps the contracted-divergence tier honest.

**Files:**
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/InlineEmphasisAppleParityTests.swift`

- [ ] **Step 1: Write the test**

Create `Packages/MaughamCore/Tests/MaughamCoreTests/InlineEmphasisAppleParityTests.swift`:

```swift
import XCTest
@testable import MaughamCore

/// CONTRACT: the shared `InlineEmphasisScanner` must agree with Apple's
/// CommonMark parser (which the phone markdown reader uses) on the canonical
/// cases. If a future macOS changes Apple's parser, this fails — telling us the
/// phone reader has drifted from the contract.
final class InlineEmphasisAppleParityTests: XCTestCase {

    /// Traits Apple assigns to each character of `s`, by inline presentation
    /// intent, with marker characters removed (Apple strips them).
    private func appleTraitsPerVisibleChar(_ s: String) -> [EmphasisTraits] {
        let attr = try! AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        var out: [EmphasisTraits] = []
        for run in attr.runs {
            let intent = run.inlinePresentationIntent ?? []
            var t: EmphasisTraits = []
            if intent.contains(.emphasized) { t.insert(.italic) }
            if intent.contains(.stronglyEmphasized) { t.insert(.bold) }
            let count = attr[run.range].characters.count
            out.append(contentsOf: Array(repeating: t, count: count))
        }
        return out
    }

    /// Traits our scanner assigns to each non-marker character of `s`.
    private func scannerTraitsPerVisibleChar(_ s: String) -> [EmphasisTraits] {
        let ns = s as NSString
        let scan = InlineEmphasisScanner.scan(ns)
        var perIndex = [EmphasisTraits?](repeating: EmphasisTraits(), count: ns.length)
        var markerSet = Set<Int>()
        for m in scan.markers {
            for i in m.location ..< (m.location + m.length) { markerSet.insert(i); perIndex[i] = nil }
        }
        for r in scan.runs {
            for i in r.range.location ..< (r.range.location + r.range.length) {
                if perIndex[i] != nil { perIndex[i] = r.traits }
            }
        }
        return perIndex.compactMap { $0 }
    }

    func testParityOnCanonicalCases() {
        for s in ["*x*", "**x**", "***x***", "*a **b** a*", "**a *b* a**", "plain words"] {
            XCTAssertEqual(scannerTraitsPerVisibleChar(s), appleTraitsPerVisibleChar(s),
                           "scanner and Apple disagree on \(s)")
        }
    }
}
```

- [ ] **Step 2: Run the test**

Run: `swift test --package-path Packages/MaughamCore --filter InlineEmphasisAppleParityTests`
Expected: PASS. If it fails, the *scanner* is wrong on a canonical case (Apple is the oracle) — fix the scanner, not the test.

- [ ] **Step 3: Commit**

```bash
git add Packages/MaughamCore/Tests/MaughamCoreTests/InlineEmphasisAppleParityTests.swift
git commit -m "test(core): pin InlineEmphasisScanner to Apple's parser on canonical cases"
```

---

## Task 4: Fountain migration (both surfaces)

Replace `FountainInlineSpan.Kind.bold`/`.italic` with `.emphasis(EmphasisTraits)` + `.emphasisMarker`, route the tokenizer through the scanner, and update both Fountain renderers. This is one atomic compiling change across BOTH schemes.

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ScreenplayElement.swift:33-38`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/FountainTokenizer.swift:413-442` (`inlineSpans`)
- Modify: `Maugham/Editor/ScreenplayMode.swift:420-473` (`applyInlineSpan`)
- Modify: `MaughamPhone/Read/FountainSemanticRenderer.swift:95-123` (`apply`)
- Update tests: `MaughamTests/InlineEmphasisTests.swift`, `InlineEmphasisStylingTests.swift`, `ScreenplayModeStylingTests.swift`; `MaughamPhoneTests/FountainInlineEmphasisTests.swift`, `ScreenplayEmphasisContractTests.swift`, `FountainStylerTests.swift`

- [ ] **Step 1: Change the span kind**

In `ScreenplayElement.swift`, replace the `Kind` enum body (lines 34-37):

```swift
    public enum Kind: Equatable, Sendable {
        case note
        /// Content (markers already excluded) carrying combined font traits.
        case emphasis(EmphasisTraits)
        /// An asterisk-marker range to fade. Carries no font change.
        case emphasisMarker
        case underline
    }
```

- [ ] **Step 2: Route the tokenizer through the scanner**

In `FountainTokenizer.swift`, replace the two asterisk passes in `inlineSpans` (the `// 2. Bold` and `// 3. Italic` blocks, lines ~425-434) with one scanner call. The method scans `rawLine` and offsets by `lineRange.location`:

```swift
        // 2. Asterisk emphasis (*, **, ***, nesting) via the shared scanner.
        let scan = InlineEmphasisScanner.scan(raw)
        for run in scan.runs {
            result.append(FountainInlineSpan(
                range: NSRange(location: lineRange.location + run.range.location,
                               length: run.range.length),
                kind: .emphasis(run.traits)))
        }
        for marker in scan.markers {
            result.append(FountainInlineSpan(
                range: NSRange(location: lineRange.location + marker.location,
                               length: marker.length),
                kind: .emphasisMarker))
        }
```

Leave the note pass (1) and underline pass (4) exactly as they are. Update the method doc comment on line 410-412 to say "notes, asterisk emphasis (via InlineEmphasisScanner), and underline".

- [ ] **Step 3: Update the Mac renderer**

In `ScreenplayMode.swift`, replace the `.italic` and `.bold` cases in `applyInlineSpan` (lines 435-457) with:

```swift
        case .emphasis(let traits):
            // span.range is content (markers already excluded by the tokenizer).
            // applyTrait composes, so calling it twice yields bold+italic.
            if traits.contains(.bold) {
                applyTrait(.bold, in: storage, range: span.range, baseFont: baseFont)
            }
            if traits.contains(.italic) {
                applyTrait(.italic, in: storage, range: span.range, baseFont: baseFont)
            }

        case .emphasisMarker:
            fadeMarker(in: storage, location: span.range.location,
                       length: span.range.length, palette: palette)
```

Leave `.note` and `.underline` cases unchanged.

- [ ] **Step 4: Update the phone renderer**

In `FountainSemanticRenderer.swift`, replace the `.italic` and `.bold` cases in `apply` (lines 109-113) with:

```swift
        case .emphasis(let traits):
            // `span` is content-relative and marker-free. Layer traits on the
            // existing font so they compose.
            if let r = attrRange(span, in: content, attr: attr) {
                var f = attr[r].font ?? Font.body
                if traits.contains(.bold) { f = f.bold() }
                if traits.contains(.italic) { f = f.italic() }
                attr[r].font = f
            }

        case .emphasisMarker:
            if let r = attrRange(span, in: content, attr: attr) {
                attr[r].foregroundColor = Color.primary.opacity(0.3)
            }
```

Leave `.note` and `.underline` cases unchanged. (The `applyTrait` and `fadeMarkers` helpers are still used by other paths — leave them.)

- [ ] **Step 5: Fix existing Fountain tests (mechanical)**

Build each test target; the compiler lists every site constructing the removed cases. Apply this mapping in the six listed test files:
- `FountainInlineSpan(range: r, kind: .italic)` → `.emphasis([.italic])`
- `FountainInlineSpan(range: r, kind: .bold)` → `.emphasis([.bold])`
- Assertions that the inline-span list contained a single `.bold`/`.italic` span whose `range` spanned the **whole** `**word**` (markers included) must change: there is now a content `.emphasis` span (word only) PLUS `.emphasisMarker` spans for the asterisks. Update the expected span list to the new content+marker shape. For `***word***`, expect one `.emphasis([.bold, .italic])` content span over `word` and two `.emphasisMarker` spans.

Run after each file: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/<File>`

- [ ] **Step 6: Add the new behavior test (both targets)**

Add to `MaughamTests/InlineEmphasisTests.swift` and `MaughamPhoneTests/FountainInlineEmphasisTests.swift` a test that `FountainTokenizer().tokenize("***word***")` (use the project's existing helper for getting a line's `inlineSpans`) yields one `.emphasis([.bold, .italic])` content span covering `word`, and that `*a **b** a*` yields a middle `.emphasis([.italic, .bold])` content span over `b`. Match the existing test file's construction/assertion style.

- [ ] **Step 7: Run both schemes**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
```
Expected: PASS both. (Transient iOS "Busy / failed preflight" is a flake — re-run.)

- [ ] **Step 8: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/ScreenplayElement.swift \
        Packages/MaughamCore/Sources/MaughamCore/FountainTokenizer.swift \
        Maugham/Editor/ScreenplayMode.swift \
        MaughamPhone/Read/FountainSemanticRenderer.swift \
        MaughamTests MaughamPhoneTests
git commit -m "feat(fountain): combinable + nested inline emphasis via shared scanner"
```

---

## Task 5: Mac prose migration

Reshape `Token.Kind.emphasis` to carry `EmphasisTraits`, route `MarkdownTokenizer` through the scanner, and build the composed font in `ProseMode`. Maugham scheme only (the phone markdown reader is untouched — Apple's parser already does this, pinned by Task 3).

**Files:**
- Modify: `Maugham/Editor/Token.swift:9`
- Modify: `Maugham/Editor/Tokenizer/MarkdownTokenizer.swift:33-63` (the two asterisk blocks)
- Modify: `Maugham/Editor/ProseMode.swift:196-202` (`attributes(for:)`)
- Update tests: `MaughamTests/TokenTests.swift`, `MarkdownTokenizerTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `MaughamTests/MarkdownTokenizerTests.swift`:

```swift
    func testBoldItalicTripleAsterisk() {
        let tokens = MarkdownTokenizer().tokenize("***word***")
        let emph = tokens.first { if case .emphasis = $0.kind { return true }; return false }
        XCTAssertNotNil(emph)
        if case .emphasis(let traits)? = emph?.kind {
            XCTAssertEqual(traits, [.bold, .italic])
        }
        // The inner content is "word"; the six asterisks are syntaxPunctuation.
        XCTAssertEqual((("***word***" as NSString)).substring(with: emph!.range), "word")
    }

    func testNestedEmphasisInProse() {
        let tokens = MarkdownTokenizer().tokenize("*a **b** a*")
        let bothTrait = tokens.first {
            if case .emphasis(let t) = $0.kind { return t == [.italic, .bold] }
            return false
        }
        XCTAssertNotNil(bothTrait, "middle 'b' should be bold+italic")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/MarkdownTokenizerTests`
Expected: FAIL to compile (`.emphasis(let traits)` doesn't match `emphasis(strong:)`).

- [ ] **Step 3: Change `Token.Kind`**

In `Token.swift`, line 9, replace:

```swift
        case emphasis(strong: Bool)
```
with:
```swift
        case emphasis(EmphasisTraits)
```

(`import MaughamCore` is already present.)

- [ ] **Step 4: Route `MarkdownTokenizer` through the scanner**

In `MarkdownTokenizer.swift`, replace the entire `// Bold:` and `// Italic:` blocks (lines 33-63) with:

```swift
        // Asterisk emphasis (*, **, ***, nesting) via the shared scanner.
        // Markers become syntaxPunctuation; content runs carry the traits.
        let scan = InlineEmphasisScanner.scan(nsText)
        for run in scan.runs {
            let tok = Token(range: run.range, kind: .emphasis(run.traits))
            if !tokens.contains(where: { $0.range.intersection(run.range) != nil }) {
                tokens.append(tok)
            }
        }
        for marker in scan.markers {
            let tok = Token(range: marker, kind: .syntaxPunctuation)
            if !tokens.contains(where: { $0.range.intersection(marker) != nil }) {
                tokens.append(tok)
            }
        }
```

- [ ] **Step 5: Build the composed font in `ProseMode`**

In `ProseMode.swift`, replace the `.emphasis` case (lines 196-202):

```swift
        case .emphasis(let traits):
            var symbolic: NSFontDescriptor.SymbolicTraits = []
            if traits.contains(.bold) { symbolic.insert(.bold) }
            if traits.contains(.italic) { symbolic.insert(.italic) }
            let font = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(symbolic),
                size: baseFont.pointSize
            ) ?? baseFont
            return [.font: font]
```

- [ ] **Step 6: Fix existing prose tests (mechanical)**

In `TokenTests.swift` and `MarkdownTokenizerTests.swift`, update old constructions/assertions:
- `.emphasis(strong: true)` → `.emphasis([.bold])`
- `.emphasis(strong: false)` → `.emphasis([.italic])`

- [ ] **Step 7: Run the Maugham scheme**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Editor/Token.swift \
        Maugham/Editor/Tokenizer/MarkdownTokenizer.swift \
        Maugham/Editor/ProseMode.swift \
        MaughamTests/TokenTests.swift MaughamTests/MarkdownTokenizerTests.swift
git commit -m "feat(prose): combinable + nested inline emphasis via shared scanner"
```

---

## Task 6: Registry note + full verification

**Files:**
- Modify: `docs/superpowers/notes/cross-surface-contracts.md`

- [ ] **Step 1: Add the registry entry**

Append an entry to `docs/superpowers/notes/cross-surface-contracts.md` describing the asterisk-emphasis grammar as a contract: shared-impl tier = `InlineEmphasisScanner` (consumed by `MarkdownTokenizer` + `FountainTokenizer`); contracted-divergence tier = phone markdown reader (Apple's parser) pinned by `InlineEmphasisAppleParityTests`. Note the asterisk-only boundary and the two out-of-scope follow-ups (underscore on Mac prose; phone strip-vs-fade). Match the file's existing entry format.

- [ ] **Step 2: Full clean test run, both schemes**

Public enum signatures changed (`Token.Kind`, `FountainInlineSpan.Kind`) — clean first to avoid the stale-symbol link error (CLAUDE.md).

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham clean
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
swift test --package-path Packages/MaughamCore
```
Expected: PASS all three.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/notes/cross-surface-contracts.md
git commit -m "docs: register asterisk-emphasis grammar as a cross-surface contract"
```

- [ ] **Step 4: Manual smoke (user-run)**

Ask the user to smoke-test: in a prose doc type `***bold italic***` and `*a **b** a*` and confirm the Mac editor renders bold+italic and the nested `b` bold+italic; in a `.fountain` doc confirm the same in an action line; open both on the phone reader and confirm parity.

---

## Self-Review

- **Spec coverage:** `***` everywhere → Tasks 4, 5 (Apple path pinned in 3); nesting → scanner (2) + Tasks 4, 5; single grammar source → Task 2 + contract (3); Mac-prose outlier fixed → Task 5 (flattened runs + composed font); underline untouched → Tasks 4 leave `.underline`; registry note → Task 6. All covered.
- **Placeholder scan:** New code is shown in full; the only "read the file and adapt" steps are existing-test fixes (4.5, 5.6) and the registry/smoke steps, each with an explicit mechanical mapping or instruction.
- **Type consistency:** `EmphasisTraits` (`.bold`/`.italic`), `EmphasisScan.Run.{range,traits}`, `InlineEmphasisScanner.scan(_:) -> EmphasisScan`, `FountainInlineSpan.Kind.{emphasis,emphasisMarker}`, `Token.Kind.emphasis(EmphasisTraits)` are used identically across all tasks.

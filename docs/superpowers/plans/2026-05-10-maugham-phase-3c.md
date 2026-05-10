# Phase 3c Implementation Plan — Scene Navigator + Title Page + Inline Emphasis + ⌘? Help

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land four screenplay-tool features that complete Maugham's screenwriting environment: scene navigator pane in the binder, title page block parsing + inline rendering, inline emphasis (italic/bold/underline), and the ⌘? syntax help overlay sheet.

**Architecture:** Phase 1 lands the infrastructure-heavy pieces (binder segment shape, title page parsing/rendering, page-number computation, scene navigator view). Manual smoke gate. Phase 2 lands the polish/integration pieces (emphasis spans + ⌘? help sheet). Final smoke + tag.

**Tech Stack:** Swift, AppKit (NSTextView, NSAttributedString), SwiftUI (binder pane, sheets, menu commands), XCTest. Built via `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`.

**Spec:** `docs/superpowers/specs/2026-05-10-maugham-phase-3c-design.md`. Read it before starting any task.

**Test baseline before this plan:** 412 passing on `main` (post milestone-3b). Target after milestone-3c: ~450+ passing.

**Conventions:**
- Each task = one commit. Use `feat:` / `fix:` / `docs:` prefixes per project commit discipline.
- TDD: failing test first → verify failure → minimal implementation → verify pass → commit.
- Build commands assume CWD = `/Users/denver/src/Maugham`.
- New files in `Maugham/` and `MaughamTests/` are picked up automatically by xcodegen globs — `./gen.sh` after creating new files is required before `xcodebuild`.
- `Maugham.xcodeproj` is gitignored — do NOT commit it.
- LSP diagnostics ("Cannot find type X") on edited Swift files are stale. Trust xcodebuild's TEST/BUILD SUCCEEDED output, not LSP diagnostics.
- Model selection: pure-logic types/parsers = sonnet; mechanical SwiftUI views = haiku; multi-pipeline integration = sonnet.

**Two-phase execution:**
- **Phase 1 (Tasks 1–9, smoke at task 10)**: scene navigator + title page. Smoke must be clean before continuing.
- **Phase 2 (Tasks 11–15, smoke at task 16, tag at task 17)**: ⌘? help + inline emphasis. Final smoke + tag.

---

## Task 1: TitlePageField struct + FountainScript.titlePage property + ScreenplayElement.titlePage case

**Files:**
- Modify: `Maugham/Editor/Fountain/ScreenplayElement.swift`
- Modify: `Maugham/Editor/Fountain/FountainScript.swift`
- Modify: `Maugham/Editor/Fountain/ScreenplayLineMutator.swift` (exhaustive switch needs `.titlePage` case)
- Modify: `Maugham/Editor/ElementGutterView.swift` (exhaustive switch needs `.titlePage` case)
- Test: covered indirectly by T2's tokenizer tests; no standalone tests in this task.

Adds the data types. Title page lines will be classified as `.titlePage` element kind and ALSO mirrored into `FountainScript.titlePage: [TitlePageField]?` for structured access.

- [ ] **Step 1: Add `.titlePage` case to ScreenplayElement**

In `Maugham/Editor/Fountain/ScreenplayElement.swift`, find the `ScreenplayElement` enum and add the new case:

```swift
public enum ScreenplayElement: Equatable, Hashable, Sendable {
    case action
    case sceneHeading
    case character
    case dialogue
    case parenthetical
    case transition
    case centered
    case lyric
    case section(level: Int)   // 1...6
    case synopsis
    case pageBreak
    case boneyard              // line is part of a /* ... */ block
    case note                  // line is part of a multi-line [[ ... ]] block
    case titlePage             // line is part of the title page block at document head
}
```

- [ ] **Step 2: Add TitlePageField struct + FountainScript.titlePage property**

Append to `Maugham/Editor/Fountain/ScreenplayElement.swift` (TitlePageField is small enough to live with the other Fountain value types):

```swift
/// One key/value field in a Fountain title page block. Multi-line values
/// (continuation indent) join with newlines.
public struct TitlePageField: Equatable, Sendable {
    /// Canonical-cased key, e.g., "Title", "Author", "Credit". Recognized
    /// keys are normalized; unknown keys are preserved as-typed.
    public let key: String
    /// Value text (may span multiple source lines, joined with `\n`).
    public let value: String
    /// NSRange covering the entire field in source (key + colon + value
    /// + any continuation lines).
    public let range: NSRange

    public init(key: String, value: String, range: NSRange) {
        self.key = key
        self.value = value
        self.range = range
    }
}
```

Edit `Maugham/Editor/Fountain/FountainScript.swift` to add the property and update the initializer:

```swift
public struct FountainScript: Equatable, Sendable {
    public let lines: [FountainLine]
    public let titlePage: [TitlePageField]?

    public init(lines: [FountainLine] = [], titlePage: [TitlePageField]? = nil) {
        self.lines = lines
        self.titlePage = titlePage
    }

    public static let empty = FountainScript()

    // ... existing estimatedPageCount, characterNames properties unchanged for now ...
}
```

- [ ] **Step 3: Add `.titlePage` case to ScreenplayLineMutator's switch**

In `Maugham/Editor/Fountain/ScreenplayLineMutator.swift`, find the `mutate(line:to:neighborhood:)` method's main switch. Add the case alongside the other unreachable-from-cycle cases:

```swift
        case .titlePage:
            // Title page lines aren't reachable from Tab cycle.
            return Result(text: line, cursorOffset: line.utf16.count)
```

(Place this in the same group as `.pageBreak, .boneyard, .note` — they're all "no cycle action" cases.)

- [ ] **Step 4: Add `.titlePage` case to ElementGutterView's switch**

In `Maugham/Editor/ElementGutterView.swift`, find `static func abbreviation(for:)`. Add the case:

```swift
        case .titlePage:    return nil   // title page lines have no gutter label
```

- [ ] **Step 5: Build to verify the new case compiles cleanly across all switches**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: BUILD SUCCEEDED. If a switch elsewhere is non-exhaustive, fix it (case → `nil` / empty / no-op).

- [ ] **Step 6: Run all tests to confirm no regressions**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 412 passing (no new tests yet; the data types are placeholders awaiting T2's tokenizer logic).

- [ ] **Step 7: Commit**

```bash
git add Maugham/Editor/Fountain/ScreenplayElement.swift Maugham/Editor/Fountain/FountainScript.swift Maugham/Editor/Fountain/ScreenplayLineMutator.swift Maugham/Editor/ElementGutterView.swift
git commit -m "feat: add TitlePageField + ScreenplayElement.titlePage + FountainScript.titlePage

Lays down the data types for the upcoming title page parsing.
TitlePageField struct holds key/value/range. FountainScript gains
optional titlePage property (nil = no title page). ScreenplayElement
gains .titlePage case; downstream exhaustive switches in
ScreenplayLineMutator and ElementGutterView updated.

Tokenizer logic to populate titlePage lands in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: FountainTokenizer parses title page block

**Files:**
- Modify: `Maugham/Editor/Fountain/FountainTokenizer.swift`
- Create: `MaughamTests/TitlePageParserTests.swift`

State-machine extension to parse the title page block at document head. Per spec §4.1, title page triggers when the first non-empty line matches `Key: Value` with a recognized key, and closes on (a) blank line, (b) non-blank non-key non-indented line.

- [ ] **Step 1: Create the test file with failing tests**

Create `MaughamTests/TitlePageParserTests.swift`:

```swift
import XCTest
@testable import Maugham

final class TitlePageParserTests: XCTestCase {
    private let parser = FountainTokenizer()

    func test_documentWithoutTitlePage_titlePageIsNil() {
        let script = parser.parse("INT. KITCHEN - DAY\n\nLarry sits.")
        XCTAssertNil(script.titlePage)
    }

    func test_simpleTitlePage_parsesFields() {
        let text = """
        Title: My Screenplay
        Author: Test Writer

        INT. KITCHEN - DAY
        """
        let script = parser.parse(text)
        XCTAssertNotNil(script.titlePage)
        XCTAssertEqual(script.titlePage?.count, 2)
        XCTAssertEqual(script.titlePage?[0].key, "Title")
        XCTAssertEqual(script.titlePage?[0].value, "My Screenplay")
        XCTAssertEqual(script.titlePage?[1].key, "Author")
        XCTAssertEqual(script.titlePage?[1].value, "Test Writer")
    }

    func test_titlePage_classifiesLinesAsTitlePageElement() {
        let text = """
        Title: My Screenplay
        Author: Test Writer

        INT. KITCHEN - DAY
        """
        let script = parser.parse(text)
        // First two lines are .titlePage; blank line is .action; INT. is sceneHeading.
        XCTAssertEqual(script.lines[0].element, .titlePage)
        XCTAssertEqual(script.lines[1].element, .titlePage)
    }

    func test_titlePage_recognizesAuthorsKey_normalizedToAuthor() {
        let script = parser.parse("Authors: A and B\n\nINT. ROOM")
        XCTAssertEqual(script.titlePage?[0].key, "Author")
        XCTAssertEqual(script.titlePage?[0].value, "A and B")
    }

    func test_titlePage_recognizesAllStandardKeys() {
        let text = """
        Title: T
        Credit: C
        Author: A
        Source: S
        Notes: N
        Draft date: D
        Contact: K
        Copyright: P

        INT. SCENE
        """
        let script = parser.parse(text)
        XCTAssertEqual(script.titlePage?.count, 8)
    }

    func test_titlePage_unknownKeyStillParsed() {
        let text = """
        Title: T
        Custom Key: Value

        INT. SCENE
        """
        let script = parser.parse(text)
        XCTAssertEqual(script.titlePage?.count, 2)
        XCTAssertEqual(script.titlePage?[1].key, "Custom Key")
    }

    func test_titlePage_caseInsensitiveKey_normalizedToCanonical() {
        let script = parser.parse("title: T\n\nINT. SCENE")
        XCTAssertEqual(script.titlePage?[0].key, "Title")
    }

    func test_titlePage_continuationViaIndent_joinsWithNewline() {
        let text = """
        Notes: First line of notes
            second line indented
            third line indented
        Author: A

        INT. SCENE
        """
        let script = parser.parse(text)
        XCTAssertEqual(script.titlePage?[0].key, "Notes")
        XCTAssertEqual(
            script.titlePage?[0].value,
            "First line of notes\nsecond line indented\nthird line indented")
        XCTAssertEqual(script.titlePage?[1].key, "Author")
    }

    func test_titlePage_closesOnBlankLine() {
        let text = """
        Title: T

        Author: A
        """
        // Blank after Title closes the title page; "Author: A" is parsed as
        // body action (not a title page line).
        let script = parser.parse(text)
        XCTAssertEqual(script.titlePage?.count, 1)
        XCTAssertEqual(script.titlePage?[0].key, "Title")
    }

    func test_titlePage_closesOnNonKeyNonIndentedLine() {
        // INT. KITCHEN doesn't match Key: Value, so title page closes there.
        let text = """
        Title: T
        INT. KITCHEN - DAY
        """
        let script = parser.parse(text)
        XCTAssertEqual(script.titlePage?.count, 1)
        XCTAssertEqual(script.lines[1].element, .sceneHeading)
    }

    func test_documentStartingWithSceneHeading_noTitlePage() {
        // First non-empty line doesn't match Key: Value → no title page.
        let script = parser.parse("INT. KITCHEN - DAY\n\nLarry sits.")
        XCTAssertNil(script.titlePage)
    }

    func test_documentStartingWithUnrecognizedKey_noTitlePage() {
        // Trigger requires a RECOGNIZED key. "Foo: bar" alone doesn't trigger.
        // But once the title page block is open (recognized key), unknown keys
        // continue to populate it.
        let script = parser.parse("Foo: bar\n\nINT. SCENE")
        XCTAssertNil(script.titlePage)
    }
}
```

- [ ] **Step 2: Run tests, expect failures**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/TitlePageParserTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`

Expected: 12 failures.

- [ ] **Step 3: Add title page parsing to FountainTokenizer.parse**

Read `Maugham/Editor/Fountain/FountainTokenizer.swift` to see the current `parse` shape.

Add a NEW pre-pass at the start of `parse(_:)` (before the existing line-by-line classification loop). The pre-pass scans for a title page block, populates `titlePagefields`, marks the consumed line ranges, and the main loop knows to skip them.

Add at the top of the file (private):

```swift
    private static let titlePageKeyMap: [String: String] = [
        "title": "Title",
        "credit": "Credit",
        "author": "Author",
        "authors": "Author",
        "source": "Source",
        "notes": "Notes",
        "draft date": "Draft date",
        "contact": "Contact",
        "copyright": "Copyright",
    ]

    private static func canonicalTitlePageKey(_ raw: String) -> String? {
        let lower = raw.lowercased()
        return titlePageKeyMap[lower]
    }
```

Modify `parse(_:)` to extract a title page block before the main loop. The full new structure:

```swift
    public func parse(_ text: String) -> FountainScript {
        guard !text.isEmpty else { return .empty }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Pre-pass: detect and parse title page block at document head.
        let (titlePage, titlePageEndOffset) = Self.parseTitlePage(
            nsText: nsText, fullRange: fullRange)

        var lines: [FountainLine] = []
        var prevBlank = true
        var prevElement: ScreenplayElement = .action
        var blockState: BlockState = .normal

        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            substring, _, enclosingRange, _ in
            guard let raw = substring else { return }

            // If this line is inside the title page block, classify as .titlePage.
            if enclosingRange.location < titlePageEndOffset {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .titlePage,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed),
                    inlineSpans: []))
                prevBlank = trimmed.isEmpty
                prevElement = .titlePage
                return
            }

            // ... existing line-by-line classification logic unchanged ...
            // (the rest of the body of the `enumerateSubstrings` closure stays
            // exactly as it was before this task)
        }

        // Trailing-empty-line emission (existing logic from 3b).
        // ... unchanged ...

        return FountainScript(lines: lines, titlePage: titlePage)
    }

    /// Parse the title page block at the document head, if present.
    /// Returns (fields, endByteOffset). endByteOffset is the offset where
    /// the body begins (after the title page block + closing blank line).
    /// If no title page is present, returns (nil, 0).
    private static func parseTitlePage(
        nsText: NSString,
        fullRange: NSRange
    ) -> (fields: [TitlePageField]?, endOffset: Int) {
        // Find the first non-empty line; check if it matches Key: Value with
        // a recognized key. If not, no title page.
        var firstNonEmpty: NSRange?
        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            sub, _, enclosing, stop in
            guard let s = sub else { return }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                firstNonEmpty = enclosing
                stop.pointee = true
            }
        }
        guard let firstLineRange = firstNonEmpty else {
            return (nil, 0)
        }
        let firstLineText = nsText.substring(with: firstLineRange)
            .trimmingCharacters(in: .whitespaces)
        guard let firstKey = parseKey(firstLineText),
              canonicalTitlePageKey(firstKey) != nil else {
            // First line doesn't match recognized title page key.
            return (nil, 0)
        }

        // Walk lines from the start, accumulating title page fields until
        // the close condition.
        var fields: [TitlePageField] = []
        var currentKey: String?
        var currentValue: [String] = []
        var currentRange: NSRange = NSRange(location: 0, length: 0)
        var endOffset = 0

        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            sub, _, enclosing, stop in
            guard let s = sub else { return }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            let leadingWhitespaceCount = s.prefix { $0 == " " || $0 == "\t" }.count
            let isIndentedContinuation = leadingWhitespaceCount >= 3
                || (s.hasPrefix("\t"))

            // Close on blank line.
            if trimmed.isEmpty {
                Self.flushField(currentKey: &currentKey,
                                currentValue: &currentValue,
                                currentRange: &currentRange,
                                fields: &fields)
                endOffset = NSMaxRange(enclosing)
                stop.pointee = true
                return
            }

            // Try to match Key: Value (top-level key).
            if let parsedKey = parseKey(trimmed),
               !isIndentedContinuation {
                // New field. Flush current.
                Self.flushField(currentKey: &currentKey,
                                currentValue: &currentValue,
                                currentRange: &currentRange,
                                fields: &fields)
                let canonical = canonicalTitlePageKey(parsedKey) ?? parsedKey
                currentKey = canonical
                let valueStart = (trimmed as NSString).range(of: ":").location + 1
                let valueText = (trimmed as NSString).substring(from: valueStart)
                    .trimmingCharacters(in: .whitespaces)
                currentValue = valueText.isEmpty ? [] : [valueText]
                currentRange = enclosing
            } else if currentKey != nil && isIndentedContinuation {
                // Continuation of previous field.
                currentValue.append(trimmed)
                currentRange = NSRange(
                    location: currentRange.location,
                    length: NSMaxRange(enclosing) - currentRange.location)
            } else {
                // Non-key non-indented line — closes the title page.
                Self.flushField(currentKey: &currentKey,
                                currentValue: &currentValue,
                                currentRange: &currentRange,
                                fields: &fields)
                endOffset = enclosing.location
                stop.pointee = true
                return
            }
        }

        // If we reached end of document without an explicit close, flush.
        Self.flushField(currentKey: &currentKey,
                        currentValue: &currentValue,
                        currentRange: &currentRange,
                        fields: &fields)
        if endOffset == 0 {
            endOffset = fullRange.length
        }

        return (fields.isEmpty ? nil : fields, endOffset)
    }

    private static func flushField(
        currentKey: inout String?,
        currentValue: inout [String],
        currentRange: inout NSRange,
        fields: inout [TitlePageField]
    ) {
        guard let key = currentKey else { return }
        let value = currentValue.joined(separator: "\n")
        fields.append(TitlePageField(
            key: key, value: value, range: currentRange))
        currentKey = nil
        currentValue = []
        currentRange = NSRange(location: 0, length: 0)
    }

    /// Parse "Key: ..." into the key (canonical case stripped). Returns nil
    /// if the line doesn't have a colon or has invalid key format.
    private static func parseKey(_ line: String) -> String? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colonIndex])
            .trimmingCharacters(in: .whitespaces)
        // Reject empty key or keys with newlines/colons (sanity).
        guard !key.isEmpty,
              !key.contains("\n") else { return nil }
        return key
    }
```

Note the structure: `parseTitlePage` is a static helper that returns the fields and the byte offset where the body starts. The main `parse(_:)` method calls it once, then in the main `enumerateSubstrings` loop it checks `enclosingRange.location < titlePageEndOffset` to classify title-page lines.

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/TitlePageParserTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 12 tests, with 0 failures`.

- [ ] **Step 5: Run full suite to confirm no regressions**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 424 passing (412 baseline + 12 new).

If existing tokenizer tests fail (e.g., a test that expected a certain line count for an input that now classifies title page lines differently), inspect carefully — they may need updating to reflect title-page-aware behavior.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/Fountain/FountainTokenizer.swift MaughamTests/TitlePageParserTests.swift
git commit -m "feat: parse Fountain title page block at document head

Pre-pass before the main classifier extracts a title page block
from the document head. Triggers when the first non-empty line
matches \`Key: Value\` with a recognized key (Title, Author, Credit,
Source, Notes, Draft date, Contact, Copyright). Author/Authors both
accepted, normalized to canonical 'Author'. Multi-line values via
indent continuation join with newlines. Closes on blank line OR
non-key non-indented line.

Title page lines classify as ScreenplayElement.titlePage in the
lines array AND mirror into FountainScript.titlePage as structured
TitlePageField values. Body parsing begins after the title page
block.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: FountainScript.pageNumber(at:) helper + factor lineCount out of estimatedPageCount

**Files:**
- Modify: `Maugham/Editor/Fountain/FountainScript.swift`
- Create: `MaughamTests/FountainScriptPageNumberTests.swift`

Computes 1-indexed page number for a given line, using the same Final-Draft-heuristic line counts as `estimatedPageCount`. Refactors `estimatedPageCount` to share the per-line lineCount logic.

- [ ] **Step 1: Create the test file with failing tests**

Create `MaughamTests/FountainScriptPageNumberTests.swift`:

```swift
import XCTest
@testable import Maugham

final class FountainScriptPageNumberTests: XCTestCase {
    private let parser = FountainTokenizer()

    func test_firstSceneHeading_isPage1() {
        let script = parser.parse("INT. KITCHEN - DAY\n\nLarry sits.")
        let scene = script.lines.first { $0.element == .sceneHeading }
        XCTAssertNotNil(scene)
        XCTAssertEqual(script.pageNumber(at: scene!), 1)
    }

    func test_pageNumber_monotonicallyIncreasesByLineOrder() {
        // Build a long document with multiple scene headings and dialogue.
        var blob = ""
        for i in 1...10 {
            blob += "INT. ROOM \(i) - DAY\n\n"
            blob += String(repeating: "Action paragraph. ", count: 30) + "\n\n"
        }
        let script = parser.parse(blob)
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        XCTAssertGreaterThan(scenes.count, 5)
        var prevPage = 0
        for scene in scenes {
            let page = script.pageNumber(at: scene)
            XCTAssertGreaterThanOrEqual(page, prevPage)
            prevPage = page
        }
    }

    func test_pageNumber_respectsLineWrapping() {
        // 110 lines of action ≈ 2 pages. The 60th line should be page 2.
        let actionLines = (1...110).map { "Line \($0). " + String(repeating: "x", count: 40) }
            .joined(separator: "\n")
        let script = parser.parse(actionLines)
        XCTAssertGreaterThan(script.lines.count, 100)
        let firstLinePage = script.pageNumber(at: script.lines[0])
        let lastLinePage = script.pageNumber(at: script.lines.last!)
        XCTAssertEqual(firstLinePage, 1)
        XCTAssertGreaterThan(lastLinePage, 1)
    }

    func test_emptyScript_pageNumberReturns1() {
        let script = FountainScript.empty
        // No way to ask pageNumber for an empty script (no lines), but
        // pageNumber(at:) on a synthetic line with location 0 should return 1.
        let synthetic = FountainLine(
            range: NSRange(location: 0, length: 0),
            element: .action, content: "",
            isForced: false, sourceCase: .neutral)
        XCTAssertEqual(script.pageNumber(at: synthetic), 1)
    }

    func test_estimatedPageCount_unchanged_afterRefactor() {
        // Sanity: estimatedPageCount math should remain identical.
        let blob = (1...27).map { "INT. ROOM \($0) - DAY\n\n" }.joined()
        let script = parser.parse(blob)
        XCTAssertEqual(script.estimatedPageCount, 0.98, accuracy: 0.05)
    }
}
```

- [ ] **Step 2: Run tests, expect compile error**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainScriptPageNumberTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`

Expected: error referencing `pageNumber(at:)`.

- [ ] **Step 3: Refactor estimatedPageCount + add pageNumber(at:)**

Edit `Maugham/Editor/Fountain/FountainScript.swift`. Find `estimatedPageCount` and refactor it to use a shared `lineCount` helper. Add `pageNumber(at:)` alongside.

Replace the existing `estimatedPageCount` computed property and add the new pieces:

```swift
    public var estimatedPageCount: Double {
        let linesPerPage = 55
        var totalLines = 0
        for line in lines {
            totalLines += Self.lineCount(for: line)
        }
        return Double(totalLines) / Double(linesPerPage)
    }

    /// 1-indexed page number where the given line begins. Walks lines from
    /// start, accumulating per-line line counts via the same heuristic as
    /// estimatedPageCount.
    public func pageNumber(at line: FountainLine) -> Int {
        let linesPerPage = 55
        var totalLines = 0
        for candidate in lines {
            if candidate.range.location == line.range.location {
                return (totalLines / linesPerPage) + 1
            }
            totalLines += Self.lineCount(for: candidate)
        }
        return 1
    }

    /// Line count for a single FountainLine — the wrapping/spacing heuristic
    /// shared by estimatedPageCount and pageNumber(at:).
    private static func lineCount(for line: FountainLine) -> Int {
        let charsPerActionLine = 60
        let charsPerDialogueLine = 35
        let charsPerParenthetical = 20
        let sceneHeadingExtraBlankLines = 1

        switch line.element {
        case .action:
            let len = line.content.count
            guard len > 0 else { return 0 }
            let wraps = (len + charsPerActionLine - 1) / charsPerActionLine
            return max(wraps, 1)
        case .dialogue:
            let len = line.content.count
            let wraps = (len + charsPerDialogueLine - 1) / charsPerDialogueLine
            return max(wraps, 1)
        case .parenthetical:
            let len = line.content.count
            let wraps = (len + charsPerParenthetical - 1) / charsPerParenthetical
            return max(wraps, 1)
        case .sceneHeading:
            return 1 + sceneHeadingExtraBlankLines
        case .character, .transition, .centered, .lyric:
            return 1
        case .section, .synopsis, .boneyard, .note, .pageBreak, .titlePage:
            return 0
        }
    }
```

- [ ] **Step 4: Run tests, expect pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainScriptPageNumberTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Verify FountainScriptPageCountTests still pass (refactor sanity)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainScriptPageCountTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 6: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 429 passing (424 + 5).

- [ ] **Step 7: Commit**

```bash
git add Maugham/Editor/Fountain/FountainScript.swift MaughamTests/FountainScriptPageNumberTests.swift
git commit -m "feat: FountainScript.pageNumber(at:) + factor lineCount helper

pageNumber(at:) returns 1-indexed page for a given line by walking
script.lines and accumulating per-line line counts. Used by the
upcoming scene navigator pane to display 'p.N' next to each slug.

estimatedPageCount refactored to share the lineCount(for:) helper —
output unchanged. Title page lines contribute 0 to body page count
(they conceptually live before page 1).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: ScreenplayMode renders title page lines

**Files:**
- Modify: `Maugham/Editor/ScreenplayMode.swift`
- Create: `MaughamTests/TitlePageStylingTests.swift`

Adds a styling pass that walks `script.titlePage` and applies per-key paragraph attributes. Title field big+centered+bold, Author smaller centered, Draft date small/dim, etc.

- [ ] **Step 1: Create the test file with failing tests**

Create `MaughamTests/TitlePageStylingTests.swift`:

```swift
import XCTest
import AppKit
@testable import Maugham

final class TitlePageStylingTests: XCTestCase {
    private let mode = ScreenplayMode()

    private func style(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let tokens = mode.tokenize(text)
        mode.applyTypography(in: storage, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens)
        return storage
    }

    func test_titleField_isBoldCentered() {
        let storage = style("Title: My Screenplay\n\nINT. SCENE")
        // The "My Screenplay" value text should be bold.
        let valueStart = ("Title: " as NSString).length
        let attrs = storage.attributes(at: valueStart, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
        let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(paragraph?.alignment, .center)
    }

    func test_titleKey_isFaded() {
        let storage = style("Title: My Screenplay\n\nINT. SCENE")
        // The "Title:" key text should be in syntaxPunctuation color (faded).
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        let palette = Theme.light.resolved(systemAppearanceIsDark: false).palette
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, palette.syntaxPunctuation)
    }

    func test_authorField_isCentered_notBold() {
        let storage = style("Title: T\nAuthor: Test Writer\n\nINT. SCENE")
        let authorValueStart = ("Title: T\nAuthor: " as NSString).length
        let attrs = storage.attributes(at: authorValueStart, effectiveRange: nil)
        let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(paragraph?.alignment, .center)
        let font = attrs[.font] as? NSFont
        XCTAssertNotNil(font)
        XCTAssertFalse(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func test_draftDateField_isLeftAligned_andDim() {
        let storage = style("Title: T\nDraft date: 2026-05-10\n\nINT. SCENE")
        let dateStart = ("Title: T\nDraft date: " as NSString).length
        let attrs = storage.attributes(at: dateStart, effectiveRange: nil)
        let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(paragraph?.alignment, .left)
        let palette = Theme.light.resolved(systemAppearanceIsDark: false).palette
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, palette.syntaxPunctuation)
    }

    func test_documentWithoutTitlePage_bodyStylesUnchanged() {
        let storage = style("INT. KITCHEN - DAY\n\nLarry sits.")
        // First line is sceneHeading — should be bold left-aligned.
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }
}
```

- [ ] **Step 2: Run tests, expect failures**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/TitlePageStylingTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`

Expected: 4-5 failures.

- [ ] **Step 3: Add title page styling pass to ScreenplayMode**

In `Maugham/Editor/ScreenplayMode.swift`, find `applyTypography(in:theme:typography:tokens:)`. After the existing per-element styling pass and the inline-span pass, BEFORE the marker-fade pass (or at any sensible position before `storage.endEditing()`), add a new pass that walks `script.titlePage` and styles each field.

You'll need to compute `script` in `applyTypography` (the existing inline-span and marker-fade passes already re-parse via `parser.parse(storage.string)` — reuse that single `script` variable for the title page pass too).

Add to `ScreenplayMode`:

```swift
    /// Apply per-key title page styling. Called from applyTypography after
    /// the per-element styling pass. Each field's value gets centered/bold/etc.
    /// per the spec table; the key gets palette.syntaxPunctuation color.
    private func applyTitlePageStyling(
        in storage: NSTextStorage,
        script: FountainScript,
        palette: ThemePalette,
        baseFont: NSFont,
        typography: TypographySettings
    ) {
        guard let titlePage = script.titlePage else { return }
        for field in titlePage {
            guard NSMaxRange(field.range) <= storage.length else { continue }
            let lineSource = (storage.string as NSString)
                .substring(with: field.range)

            // Find the colon position — the key is everything before, value is after.
            guard let colonIdx = lineSource.firstIndex(of: ":") else { continue }
            let keyLength = lineSource.distance(
                from: lineSource.startIndex, to: colonIdx) + 1  // include the ":"
            let keyRange = NSRange(
                location: field.range.location, length: keyLength)
            let valueRange = NSRange(
                location: field.range.location + keyLength,
                length: field.range.length - keyLength)

            // Apply value styling.
            let valueAttrs = titlePageValueAttributes(
                key: field.key, palette: palette,
                baseFont: baseFont, typography: typography)
            if valueRange.length > 0 {
                storage.addAttributes(valueAttrs, range: valueRange)
            }

            // Fade the key in syntaxPunctuation color.
            storage.addAttribute(
                .foregroundColor, value: palette.syntaxPunctuation,
                range: keyRange)
        }
    }

    private func titlePageValueAttributes(
        key: String,
        palette: ThemePalette,
        baseFont: NSFont,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = max(0,
            baseFont.pointSize * CGFloat(typography.lineHeightMultiplier - 1.0))

        switch key {
        case "Title":
            let bold = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                size: baseFont.pointSize * 1.5) ?? baseFont
            para.alignment = .center
            return [.paragraphStyle: para, .font: bold]
        case "Credit":
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            para.alignment = .center
            return [.paragraphStyle: para, .font: italic]
        case "Author":
            para.alignment = .center
            return [.paragraphStyle: para, .font: baseFont]
        case "Source":
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize * 0.9) ?? baseFont
            para.alignment = .center
            return [.paragraphStyle: para, .font: italic]
        default:
            // Draft date, Contact, Notes, Copyright, unknown keys
            let smaller = NSFont(
                descriptor: baseFont.fontDescriptor,
                size: baseFont.pointSize * 0.85) ?? baseFont
            para.alignment = .left
            return [
                .paragraphStyle: para,
                .font: smaller,
                .foregroundColor: palette.syntaxPunctuation,
            ]
        }
    }
```

In `applyTypography`, after the existing inline-span pass (which already does `let script = parser.parse(storage.string)`), call the new title page pass:

```swift
        // Title page styling pass.
        applyTitlePageStyling(
            in: storage,
            script: script,
            palette: palette,
            baseFont: baseFont,
            typography: typography)
```

If the existing inline-span pass scopes `script` to its local block, hoist it to a higher scope so multiple passes share the parse. (Read the existing applyTypography structure to confirm.)

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/TitlePageStylingTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 434 passing (429 + 5).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/ScreenplayMode.swift MaughamTests/TitlePageStylingTests.swift
git commit -m "feat: ScreenplayMode renders title page with per-key styling

New applyTitlePageStyling pass walks script.titlePage and applies
paragraph attributes per field key:
- Title: bold + centered + 1.5x body size
- Credit: italic + centered + body size
- Author: centered + body size
- Source: italic + centered + 0.9x size
- Draft date / Contact / Notes / Copyright / unknown: left-aligned
  + 0.85x size + syntaxPunctuation color

The key text itself (e.g., 'Title:') fades to syntaxPunctuation,
mirroring the marker-fade pattern from milestone-3b.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Title-page-to-body paragraph spacing

**Files:**
- Modify: `Maugham/Editor/ScreenplayMode.swift`

When a title page is present, the FIRST body line gets extra `paragraphSpacingBefore` to visually separate the title block from the script body.

- [ ] **Step 1: Find the first body line and apply spacing**

In `ScreenplayMode.applyTypography`, in the per-element styling pass that iterates tokens, identify the first non-titlePage line. When found, add an extra `paragraphSpacingBefore` to its paragraph style.

A clean way: in the per-element pass, track an `isFirstBody = true` flag that flips false after the first non-titlePage element is styled.

Modify the existing per-element pass loop:

```swift
        var isFirstBody = true
        let hasTitlePage = (script.titlePage != nil)

        // First pass — per-line element styling driven by tokens.
        for token in tokens {
            guard NSMaxRange(token.range) <= storage.length else { continue }
            guard case let .fountainElement(element, _) = token.kind else { continue }

            // Skip titlePage elements (handled by applyTitlePageStyling).
            if case .titlePage = element { continue }

            var attrs = self.attributes(
                for: element,
                palette: palette,
                baseFont: baseFont,
                charWidth: charWidth,
                typography: typography)

            // Add paragraph spacing before the first body element when there's
            // a title page above.
            if hasTitlePage && isFirstBody, let para = attrs[.paragraphStyle] as? NSParagraphStyle {
                let mutable = (para.mutableCopy() as! NSMutableParagraphStyle)
                mutable.paragraphSpacingBefore = baseFont.pointSize * 2.0
                attrs[.paragraphStyle] = mutable
                isFirstBody = false
            } else if hasTitlePage && isFirstBody {
                // No paragraph style in attrs (e.g., .action returns [:]).
                // Compose a fresh paragraph style with the spacing.
                let mutable = NSMutableParagraphStyle()
                mutable.paragraphSpacingBefore = baseFont.pointSize * 2.0
                attrs[.paragraphStyle] = mutable
                isFirstBody = false
            } else {
                // After first body or no title page, no extra spacing.
                if !isFirstBody { /* no-op */ }
            }

            storage.addAttributes(attrs, range: token.range)
        }
```

- [ ] **Step 2: Add a verification test**

Append to `MaughamTests/TitlePageStylingTests.swift`:

```swift
    func test_firstBodyLineAfterTitlePage_hasExtraParagraphSpacing() {
        let storage = style("Title: My Script\n\nINT. KITCHEN - DAY")
        // Find the location of "INT. KITCHEN - DAY".
        let bodyStart = (("Title: My Script\n\n") as NSString).length
        let attrs = storage.attributes(at: bodyStart, effectiveRange: nil)
        let para = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertNotNil(para)
        XCTAssertGreaterThan(para?.paragraphSpacingBefore ?? 0, 10)
    }

    func test_firstBodyLineWithoutTitlePage_hasNoExtraSpacing() {
        let storage = style("INT. KITCHEN - DAY\n\nLarry sits.")
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        let para = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(para?.paragraphSpacingBefore ?? 0, 0, accuracy: 0.5)
    }
```

- [ ] **Step 3: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/TitlePageStylingTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 4: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 436 passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/ScreenplayMode.swift MaughamTests/TitlePageStylingTests.swift
git commit -m "feat: title-page-to-body visual gap

When a title page is present, the first body line gets
paragraphSpacingBefore = bodyFont.pointSize * 2.0, separating the
title block from the script body. No extra spacing when there's no
title page.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: BinderSegment.scenes case + BinderPaneToggle per-project-type segments

**Files:**
- Modify: `Maugham/Models/BinderSegment.swift`
- Modify: `Maugham/Views/BinderPaneToggle.swift`
- Modify: `Maugham/Views/ProjectWindow.swift` (exhaustive switches need `.scenes` case)

Adds `.scenes` to BinderSegment. For Screenplay projects, the toggle shows `Scenes / Research`. For other types, it stays `Manuscript / Research`.

- [ ] **Step 1: Add `.scenes` to BinderSegment enum**

Edit `Maugham/Models/BinderSegment.swift`:

```swift
import Foundation

/// Which top-level segment is active in the binder pane.
public enum BinderSegment: String, Codable, Equatable, Sendable {
    case manuscript
    case research
    case scenes
}
```

- [ ] **Step 2: Update BinderPaneToggle to switch shape by project type**

Read `Maugham/Views/BinderPaneToggle.swift` to see the current shape. Modify the Picker and label switches:

```swift
import SwiftUI

struct BinderPaneToggle: View {
    @Binding var segment: BinderSegment
    let projectType: ProjectType

    var body: some View {
        Picker("", selection: $segment) {
            if projectType == .screenplay {
                Text("Scenes").tag(BinderSegment.scenes)
                Text("Research").tag(BinderSegment.research)
            } else {
                Text("Manuscript").tag(BinderSegment.manuscript)
                Text("Research").tag(BinderSegment.research)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .accessibilityLabel(label(for: segment))
    }

    private func label(for segment: BinderSegment) -> String {
        switch segment {
        case .manuscript: return "Manuscript"
        case .research:   return "Research"
        case .scenes:     return "Scenes"
        }
    }
}
```

(If `BinderPaneToggle` doesn't currently take `projectType`, add it as a property and pass from the call site.)

- [ ] **Step 3: Update ProjectWindow's switches on BinderSegment**

In `Maugham/Views/ProjectWindow.swift`, find the two existing `switch binderSegment` blocks (around lines 244 and 299). Add the `.scenes` case to each. The `.scenes` case routes to a new view (placeholder until T8 wires up the navigator):

For the body-rendering switch (line 244ish):

```swift
        switch binderSegment {
        case .manuscript:
            BinderView(...)
        case .research:
            ResearchView(...)
        case .scenes:
            // Placeholder; SceneNavigatorPane lands in Task 8.
            Text("Scenes pane coming soon").foregroundStyle(.secondary)
        }
```

For the inspector-routing switch (line 299ish), if applicable, add `.scenes` similarly:

```swift
        case .scenes:
            // No inspector for scenes pane (it's a navigator, not an item editor).
            EmptyView()
```

- [ ] **Step 4: Update ProjectWindow's BinderPaneToggle call site**

Find where `BinderPaneToggle` is constructed. Add the `projectType` argument:

```swift
        BinderPaneToggle(
            segment: $binderSegment,
            projectType: store.manifest.type)
```

- [ ] **Step 5: Default segment for screenplay should be .scenes (or the closest valid)**

In `ProjectWindow.swift`, find:
```swift
@State private var binderSegment: BinderSegment = .manuscript
```

This default is .manuscript. For screenplay projects, .manuscript isn't even rendered. We need a sensible default per project type.

The cleanest fix: derive the default from `manifest.type` when the project loads. Add a small helper in ProjectWindow:

```swift
    private static func defaultSegment(for type: ProjectType) -> BinderSegment {
        type == .screenplay ? .scenes : .manuscript
    }
```

Use it on view appear:

```swift
.onAppear {
    if let store {
        binderSegment = Self.defaultSegment(for: store.manifest.type)
    }
}
```

Or, if there's an existing `onChange(of: store?.manifest.type)`, hook into that.

Also: when the user is on `.scenes` and switches to a non-screenplay project (rare via ProjectWindow but possible), reset to `.manuscript` to avoid showing an empty/invalid segment. Same `onAppear` / mode-change handler covers it.

- [ ] **Step 6: Build to verify**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: BUILD SUCCEEDED. If a switch elsewhere is non-exhaustive, fix it.

- [ ] **Step 7: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 436 passing (no new tests this task).

- [ ] **Step 8: Commit**

```bash
git add Maugham/Models/BinderSegment.swift Maugham/Views/BinderPaneToggle.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: BinderSegment.scenes + per-project-type segment shape

For Screenplay projects: binder shows 'Scenes / Research' (replaces
Manuscript, redundant for single-file). For Novel/Story/Collection:
'Manuscript / Research' as before.

Default segment derives from project type: .scenes for screenplay,
.manuscript otherwise. SceneNavigatorPane wiring lands in the next
task — for now the .scenes route shows a placeholder.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: SceneNavigatorPane view

**Files:**
- Create: `Maugham/Views/SceneNavigatorPane.swift`
- Create: `MaughamTests/SceneNavigatorTests.swift`

The view that lists sluglines + page numbers from the active screenplay's parsed script. Click → posts a notification (handled in T9).

- [ ] **Step 1: Create the test file**

Create `MaughamTests/SceneNavigatorTests.swift`:

```swift
import XCTest
@testable import Maugham

final class SceneNavigatorTests: XCTestCase {
    private let parser = FountainTokenizer()

    func test_sceneFilter_extractsOnlySceneHeadings() {
        let text = """
        INT. KITCHEN - DAY

        Larry sits.

        BARRY
        Hi.

        EXT. ROOFTOP - NIGHT

        Action.
        """
        let script = parser.parse(text)
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0].content, "INT. KITCHEN - DAY")
        XCTAssertEqual(scenes[1].content, "EXT. ROOFTOP - NIGHT")
    }

    func test_sceneFilter_includesForcedSceneHeadings() {
        let script = parser.parse("INT. ROOM\n\n.barbershop\n\nINT. CAR")
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        XCTAssertEqual(scenes.count, 3)
        XCTAssertEqual(scenes[1].content, "barbershop")
    }

    func test_sceneFilter_emptyScript_returnsEmpty() {
        let script = FountainScript.empty
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        XCTAssertEqual(scenes.count, 0)
    }

    func test_sceneFilter_preservesOrder() {
        let text = (1...5).map { "INT. ROOM \($0) - DAY\n\nAction.\n\n" }.joined()
        let script = parser.parse(text)
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        XCTAssertEqual(scenes.count, 5)
        for i in 0..<5 {
            XCTAssertEqual(scenes[i].content, "INT. ROOM \(i+1) - DAY")
        }
    }
}
```

- [ ] **Step 2: Run tests, expect pass (these test only existing primitives)**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/SceneNavigatorTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 4 tests, with 0 failures` (all rely on existing FountainScript.lines + element comparison).

- [ ] **Step 3: Create the SceneNavigatorPane view**

Create `Maugham/Views/SceneNavigatorPane.swift`:

```swift
import SwiftUI

struct SceneNavigatorPane: View {
    let script: FountainScript?
    /// Called with the line range location when the user clicks a scene.
    let onSelect: (Int) -> Void

    var body: some View {
        if let scenes = scenes, !scenes.isEmpty {
            List {
                ForEach(Array(scenes.enumerated()), id: \.offset) { _, scene in
                    sceneRow(for: scene)
                }
            }
            .listStyle(.sidebar)
        } else {
            VStack {
                Text("No scenes yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Type INT. or EXT. to add one.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var scenes: [FountainLine]? {
        script?.lines.filter { $0.element == .sceneHeading }
    }

    @ViewBuilder
    private func sceneRow(for scene: FountainLine) -> some View {
        Button {
            onSelect(scene.range.location)
        } label: {
            HStack {
                Text(scene.content)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("p.\(pageNumber(for: scene))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pageNumber(for scene: FountainLine) -> Int {
        script?.pageNumber(at: scene) ?? 1
    }
}
```

- [ ] **Step 4: Run targeted tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 440 passing (436 + 4).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/SceneNavigatorPane.swift MaughamTests/SceneNavigatorTests.swift
git commit -m "feat: SceneNavigatorPane view (sluglines + page numbers)

SwiftUI view that filters FountainScript.lines to .sceneHeading lines
and lists them with page numbers (via FountainScript.pageNumber).
Click → calls onSelect with the line's range.location. Empty state
shows 'No scenes yet — type INT. or EXT. to add one.'

Wired into ProjectWindow + EditorCoordinator in the next two tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: BinderView routing — wire SceneNavigatorPane to .scenes segment

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift`

Replace the placeholder text added in Task 6 with the actual `SceneNavigatorPane` view. The `script` binding comes from `EditorCoordinator.lastParsedScript` via the project window's editor host.

- [ ] **Step 1: Read where the current binder body switches on segment in ProjectWindow**

Grep `ProjectWindow.swift` for the `.scenes` case from Task 6. It currently has `Text("Scenes pane coming soon")`.

- [ ] **Step 2: Replace placeholder with SceneNavigatorPane**

In `ProjectWindow.swift`, find the `.scenes` case and replace with:

```swift
        case .scenes:
            SceneNavigatorPane(
                script: editorCoordinator?.lastParsedScript,
                onSelect: { lineLocation in
                    NotificationCenter.default.post(
                        name: .maughamNavigateToScene,
                        object: nil,
                        userInfo: ["lineLocation": lineLocation])
                })
```

The `editorCoordinator` reference may need plumbing from the EditorHost down to ProjectWindow. Read `EditorHost.swift` to see how the coordinator is created and exposed. If it's not currently a property on ProjectWindow, hoist it OR pass via a different mechanism (e.g., a `@StateObject` wrapper or environment value).

The simplest path: have `EditorHost` expose its coordinator via a binding or callback that ProjectWindow can read. If that's too invasive, accept that the script reference may be slightly stale (one parse cycle behind) — read it from ProjectWindow's `metrics` machinery if the EditorMetrics carries the script, OR re-parse on the SwiftUI side from `documentStore.text`.

A pragmatic alternative if coordinator access is awkward: ProjectWindow gains an `@State private var lastParsedScript: FountainScript?` that's updated via a notification from the editor whenever it re-parses:

```swift
@State private var lastParsedScript: FountainScript? = nil

.onReceive(NotificationCenter.default.publisher(for: .maughamScriptDidUpdate)) { note in
    if let script = note.object as? FountainScript {
        self.lastParsedScript = script
    }
}
```

The editor coordinator posts `maughamScriptDidUpdate` from `retokenizeAndStyle` whenever `lastParsedScript` changes. (Add the notification name to `MaughamNotifications.swift`.)

This decouples the binder from direct coordinator access. **Use this approach.**

Add to `MaughamNotifications.swift`:

```swift
extension Notification.Name {
    public static let maughamScriptDidUpdate = Notification.Name("maugham.script.did.update")
    public static let maughamNavigateToScene = Notification.Name("maugham.navigate.to.scene")
}
```

In `EditorCoordinator.retokenizeAndStyle`, after `lastParsedScript = ...`, post:

```swift
        if let script = lastParsedScript {
            NotificationCenter.default.post(
                name: .maughamScriptDidUpdate,
                object: script)
        }
```

In ProjectWindow, the `@State private var lastParsedScript` is updated via the publisher; SceneNavigatorPane reads it.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 440 passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/ProjectWindow.swift Maugham/Editor/EditorCoordinator.swift Maugham/Models/MaughamNotifications.swift
git commit -m "feat: wire SceneNavigatorPane into the binder + script update notifications

ProjectWindow's .scenes binder route now renders SceneNavigatorPane
fed from a @State property updated via maughamScriptDidUpdate
notifications posted by EditorCoordinator's retokenizeAndStyle.
Decouples the binder from direct coordinator access.

Click in the navigator posts maughamNavigateToScene with the line
location; EditorCoordinator handler lands in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: EditorCoordinator subscribes to maughamNavigateToScene

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`
- Append: `MaughamTests/EditorCoordinatorCycleTests.swift` (or create a focused file)

EditorCoordinator subscribes to `maughamNavigateToScene` and on receipt scrolls + sets cursor at the line location.

- [ ] **Step 1: Add the subscription in EditorCoordinator**

In `EditorCoordinator.swift`'s `init` (or `attach(to:)` — wherever the coordinator is most clearly bound to its text view), add:

```swift
        NotificationCenter.default.addObserver(
            forName: .maughamNavigateToScene,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let location = note.userInfo?["lineLocation"] as? Int,
                  let textView = self.textView else { return }
            self.navigateToLine(at: location, in: textView)
        }
```

Add the navigateToLine method:

```swift
    private func navigateToLine(at location: Int, in textView: NSTextView) {
        let storage = textView.textStorage
        let length = (storage?.string as NSString?)?.length ?? 0
        let clamped = max(0, min(location, length))
        let range = NSRange(location: clamped, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }
```

In `deinit`:

```swift
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
```

(If the `addObserver(forName:...)` API is used, the resulting token must be tracked and removed — alternative pattern. Choose whichever style matches the existing codebase.)

- [ ] **Step 2: Add a test that verifies navigation works**

Append to `MaughamTests/EditorCoordinatorCycleTests.swift` (or any nearby integration test file):

```swift
    @MainActor
    func test_maughamNavigateToScene_movesCursor() throws {
        let tv = makeTextView(text: "INT. KITCHEN - DAY\n\nLarry sits.\n\nINT. ROOFTOP - NIGHT")
        _ = makeCoordinator(textView: tv, mode: ScreenplayMode())
        // Post navigation to position 21 (start of second scene heading).
        let secondSceneStart = ("INT. KITCHEN - DAY\n\nLarry sits.\n\n" as NSString).length
        NotificationCenter.default.post(
            name: .maughamNavigateToScene,
            object: nil,
            userInfo: ["lineLocation": secondSceneStart])
        // Allow the .main queue to deliver.
        let expectation = XCTestExpectation()
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(tv.selectedRange().location, secondSceneStart)
    }
```

- [ ] **Step 3: Run tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/EditorCoordinatorCycleTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: existing 4 tests + 1 new = 5 passing.

- [ ] **Step 4: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 441 passing (440 + 1).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/EditorCoordinator.swift MaughamTests/EditorCoordinatorCycleTests.swift
git commit -m "feat: EditorCoordinator handles maughamNavigateToScene

Subscribes to maughamNavigateToScene notifications. On receipt,
clamps the lineLocation to storage length, sets the cursor,
scrolls into view, and makes the text view first responder so
the user can immediately type at the new location.

Closes the click-to-jump flow from SceneNavigatorPane.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Phase 1 smoke checkpoint

**Files:** none directly — manual smoke.

Phase 1 deliverables: scene navigator + title page. Smoke test before continuing to Phase 2.

- [ ] **Step 1: Run full test suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 441 passing (412 baseline + 29 new across Tasks 1-9).

- [ ] **Step 2: Build and launch the app**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3` → BUILD SUCCEEDED.

Launch via `open ~/Library/Developer/Xcode/DerivedData/Maugham-*/Build/Products/Debug/Maugham.app` or Xcode (⌘R).

- [ ] **Step 3: Walk through Phase 1 smoke checklist**

1. Create a new Screenplay project. The binder shows "Scenes / Research" segments (no Manuscript).
2. Click Scenes — the pane shows the empty state ("No scenes yet — type INT. or EXT. to add one").
3. Type `INT. KITCHEN - DAY` + Enter + Enter + `Larry sits.` in the editor. The Scenes pane updates to show the new scene heading.
4. Add a second scene: Enter + Enter + `EXT. ROOFTOP - NIGHT` + Enter + Enter + `BARRY` + Enter + `Hi.`. Scenes pane shows two entries with their slugs.
5. Click the second scene in the navigator → cursor jumps to the EXT. line, editor scrolls.
6. Verify page numbers render next to slugs (e.g., `p.1`).
7. Add a title page block at the document head:
   ```
   Title: My Screenplay
   Author: Test Writer
   Draft date: 2026-05-10
   ```
   → title renders bold + centered + larger; author smaller centered; draft date small/dim left-aligned. The body line below has visible extra spacing.
8. Switch to a Novel project → binder shows Manuscript / Research, no Scenes segment.
9. Toggle theme (Light/Dark/Sepia) → title page colors re-render.
10. Resize the binder pane narrow → scene rows truncate gracefully.
11. Type a forced scene heading `.barbershop` → it appears in the navigator as `barbershop`.

- [ ] **Step 4: Fix any smoke regressions**

For each failure, commit a `fix:` patch with a clear root-cause body. Use the lessons banked from prior milestones (LSP cache lag, SwiftUI body type-check, etc.). Common pitfalls to expect:

- Title page may not render if FountainTokenizer's pre-pass has off-by-one issues with the byte offset where body begins.
- Scene navigator may show stale content if the script-update notification isn't firing on every retokenizeAndStyle.
- Screenplay segment default may show empty pane if the .onAppear default-segment logic isn't firing.

- [ ] **Step 5: Commit a smoke checkpoint marker (optional)**

Optional clean tagless commit to mark the Phase 1 smoke result:

```bash
git commit --allow-empty -m "chore: phase 3c.1 smoke complete (scene navigator + title page)

Manual smoke walkthrough green; Phase 2 (⌘? help + inline emphasis)
begins next.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

If you skipped this commit and went straight to Task 11, that's also fine — the git log records progression via commit messages.

---

## Task 11: Inline emphasis tokenizer — italic/bold/underline

**Files:**
- Modify: `Maugham/Editor/Fountain/ScreenplayElement.swift` (FountainInlineSpan.Kind extends)
- Modify: `Maugham/Editor/Fountain/FountainTokenizer.swift` (extend inline scan)
- Create: `MaughamTests/InlineEmphasisTests.swift`

Extends the per-line inline scan to detect `*italic*`, `**bold**`, `_underline_`. Each match adds a FountainInlineSpan with a new Kind case.

- [ ] **Step 1: Extend FountainInlineSpan.Kind**

In `Maugham/Editor/Fountain/ScreenplayElement.swift`, find `FountainInlineSpan` and update its Kind enum:

```swift
public struct FountainInlineSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case note
        case italic
        case bold
        case underline
    }
    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}
```

- [ ] **Step 2: Create the test file**

Create `MaughamTests/InlineEmphasisTests.swift`:

```swift
import XCTest
@testable import Maugham

final class InlineEmphasisTests: XCTestCase {
    private let parser = FountainTokenizer()

    func test_italicSpan_detected() {
        let script = parser.parse("Action with *italic* text.")
        let line = script.lines[0]
        let italic = line.inlineSpans.filter { $0.kind == .italic }
        XCTAssertEqual(italic.count, 1)
        // Span covers "*italic*" — 8 characters.
        XCTAssertEqual(italic[0].range.length, 8)
    }

    func test_boldSpan_detected() {
        let script = parser.parse("Action with **bold** text.")
        let line = script.lines[0]
        let bold = line.inlineSpans.filter { $0.kind == .bold }
        XCTAssertEqual(bold.count, 1)
        // Span covers "**bold**" — 8 characters.
        XCTAssertEqual(bold[0].range.length, 8)
    }

    func test_boldNotMistakenForItalic() {
        let script = parser.parse("**bold**")
        let line = script.lines[0]
        let bold = line.inlineSpans.filter { $0.kind == .bold }
        let italic = line.inlineSpans.filter { $0.kind == .italic }
        XCTAssertEqual(bold.count, 1)
        XCTAssertEqual(italic.count, 0)
    }

    func test_underlineSpan_detected() {
        let script = parser.parse("Action with _underline_ text.")
        let line = script.lines[0]
        let underline = line.inlineSpans.filter { $0.kind == .underline }
        XCTAssertEqual(underline.count, 1)
    }

    func test_compositionItalicWithBold_bothDetected() {
        let script = parser.parse("*foo **bar** baz*")
        let line = script.lines[0]
        let italic = line.inlineSpans.filter { $0.kind == .italic }
        let bold = line.inlineSpans.filter { $0.kind == .bold }
        XCTAssertEqual(italic.count, 1)
        XCTAssertEqual(bold.count, 1)
        // Italic span covers full "*foo **bar** baz*" — 17 chars.
        XCTAssertEqual(italic[0].range.length, 17)
        // Bold span covers "**bar**" — 7 chars.
        XCTAssertEqual(bold[0].range.length, 7)
    }

    func test_unclosedItalic_noSpan() {
        let script = parser.parse("Action with *foo continuing")
        let line = script.lines[0]
        let italic = line.inlineSpans.filter { $0.kind == .italic }
        XCTAssertEqual(italic.count, 0)
    }

    func test_crossLineEmphasis_noSpan() {
        let script = parser.parse("Action *foo\nbar* continues.")
        // Line 0: "Action *foo" — no italic span (markers don't cross lines).
        // Line 2 (after blank or as continuation, depends on parser): no span.
        let line0Italic = script.lines[0].inlineSpans.filter { $0.kind == .italic }
        XCTAssertEqual(line0Italic.count, 0)
    }

    func test_emptyEmphasis_noSpan() {
        // ** alone is empty bold content; should NOT produce a span.
        let script = parser.parse("Action ** here")
        let line = script.lines[0]
        let bold = line.inlineSpans.filter { $0.kind == .bold }
        XCTAssertEqual(bold.count, 0)
    }
}
```

- [ ] **Step 3: Extend the inline scan in FountainTokenizer**

Read `Maugham/Editor/Fountain/FountainTokenizer.swift` to find the existing inline-note scan (currently named `inlineNoteSpans` per the spec; may have a slightly different name in the codebase — confirm and rename to `inlineSpans` if needed).

Replace the existing scan with one that detects all four kinds in priority order: notes first (existing), then bold, then italic, then underline. Bold detection uses regex `\*\*([^*\n]+)\*\*`. Italic uses `(?<!\*)\*([^*\n]+)\*(?!\*)` (negative lookarounds prevent matching inside bold). Underline uses `_([^_\n]+)_`.

```swift
    /// Returns inline spans (notes, italic, bold, underline) detected within
    /// a single line. Order: notes first, then bold (longest first), then
    /// italic (skipping ranges already inside bold), then underline.
    private static func inlineSpans(
        in trimmed: String,
        lineRange: NSRange,
        rawLine: String,
        nsText: NSString
    ) -> [FountainInlineSpan] {
        var result: [FountainInlineSpan] = []
        let raw = rawLine as NSString

        // 1. Inline notes (existing behavior).
        result.append(contentsOf: scanNotes(in: raw, lineRange: lineRange))

        // 2. Bold **text**.
        result.append(contentsOf: scanRegex(
            pattern: #"\*\*([^*\n]+)\*\*"#,
            in: raw, lineRange: lineRange, kind: .bold))

        // 3. Italic *text* — exclude markers that are part of bold.
        result.append(contentsOf: scanRegex(
            pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#,
            in: raw, lineRange: lineRange, kind: .italic))

        // 4. Underline _text_.
        result.append(contentsOf: scanRegex(
            pattern: #"_([^_\n]+)_"#,
            in: raw, lineRange: lineRange, kind: .underline))

        return result
    }

    private static func scanNotes(
        in raw: NSString, lineRange: NSRange
    ) -> [FountainInlineSpan] {
        // Existing note-scan logic. Move existing inlineNoteSpans body here.
        var result: [FountainInlineSpan] = []
        let rawLength = raw.length
        var search = NSRange(location: 0, length: rawLength)
        while search.length > 0 {
            let openRange = raw.range(of: "[[", options: [], range: search)
            guard openRange.location != NSNotFound else { break }
            let afterOpen = NSRange(
                location: openRange.location + 2,
                length: rawLength - (openRange.location + 2))
            let closeRange = raw.range(of: "]]", options: [], range: afterOpen)
            guard closeRange.location != NSNotFound else { break }
            let spanStart = lineRange.location + openRange.location
            let spanLength = (closeRange.location + 2) - openRange.location
            result.append(FountainInlineSpan(
                range: NSRange(location: spanStart, length: spanLength),
                kind: .note))
            let nextStart = closeRange.location + 2
            search = NSRange(location: nextStart,
                             length: rawLength - nextStart)
        }
        return result
    }

    private static func scanRegex(
        pattern: String,
        in raw: NSString,
        lineRange: NSRange,
        kind: FountainInlineSpan.Kind
    ) -> [FountainInlineSpan] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        var result: [FountainInlineSpan] = []
        let fullRange = NSRange(location: 0, length: raw.length)
        regex.enumerateMatches(in: raw as String, options: [],
                               range: fullRange) { match, _, _ in
            guard let match else { return }
            let outer = match.range
            let spanStart = lineRange.location + outer.location
            result.append(FountainInlineSpan(
                range: NSRange(location: spanStart, length: outer.length),
                kind: kind))
        }
        return result
    }
```

The existing call site (in `parse(_:)`) that was `let inlineSpans = Self.inlineNoteSpans(...)` should call the renamed `Self.inlineSpans(...)` helper. (If the existing function is named differently, rename consistently.)

- [ ] **Step 4: Run tests, expect pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/InlineEmphasisTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Run full suite — verify existing inline-note tests still pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 449 passing (441 + 8).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/Fountain/ScreenplayElement.swift Maugham/Editor/Fountain/FountainTokenizer.swift MaughamTests/InlineEmphasisTests.swift
git commit -m "feat: inline italic/bold/underline emphasis spans

FountainInlineSpan.Kind extends with .italic, .bold, .underline.
Tokenizer's per-line inline scan adds three new detection passes
(in priority order: bold first to avoid italic mismatch, then
italic with negative-lookaround to skip bold markers, then
underline). Each match adds an inline span covering the full
*marked* range. Composition like '*foo **bar** baz*' produces both
italic and bold spans on overlapping ranges.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: ScreenplayMode applies emphasis styling

**Files:**
- Modify: `Maugham/Editor/ScreenplayMode.swift`
- Append: `MaughamTests/InlineEmphasisStylingTests.swift` (or extend existing)

The inline-span pass extends to apply italic/bold/underline attributes to inner content ranges, plus marker fade for the surrounding `*` / `**` / `_` characters.

- [ ] **Step 1: Create the styling test file**

Create `MaughamTests/InlineEmphasisStylingTests.swift`:

```swift
import XCTest
import AppKit
@testable import Maugham

final class InlineEmphasisStylingTests: XCTestCase {
    private let mode = ScreenplayMode()

    private func style(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let tokens = mode.tokenize(text)
        mode.applyTypography(in: storage, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens)
        return storage
    }

    func test_italicSpan_innerContentIsItalic() {
        let storage = style("Action with *italic* text.")
        // Inner content "italic" starts at offset 13 (after "Action with *").
        let innerStart = ("Action with *" as NSString).length
        let attrs = storage.attributes(at: innerStart, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func test_boldSpan_innerContentIsBold() {
        let storage = style("Action with **bold** text.")
        let innerStart = ("Action with **" as NSString).length
        let attrs = storage.attributes(at: innerStart, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func test_underlineSpan_innerContentHasUnderline() {
        let storage = style("Action with _underline_ text.")
        let innerStart = ("Action with _" as NSString).length
        let attrs = storage.attributes(at: innerStart, effectiveRange: nil)
        XCTAssertNotNil(attrs[.underlineStyle])
    }

    func test_emphasisMarkersAreFaded() {
        let storage = style("Action with *italic* text.")
        // The leading "*" at offset 12 should be in syntaxPunctuation color.
        let markerStart = ("Action with " as NSString).length
        let attrs = storage.attributes(at: markerStart, effectiveRange: nil)
        let palette = Theme.light.resolved(systemAppearanceIsDark: false).palette
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, palette.syntaxPunctuation)
    }

    func test_compositionBoldItalic_innerOverlapIsBoldItalic() {
        let storage = style("*foo **bar** baz*")
        // Inner "bar" (after "*foo **") is at offset 7. Should be bold-italic.
        let barStart = ("*foo **" as NSString).length
        let attrs = storage.attributes(at: barStart, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.italic))
    }
}
```

- [ ] **Step 2: Run tests, expect failures**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/InlineEmphasisStylingTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`

Expected: 4-5 failures.

- [ ] **Step 3: Extend the inline-span pass in applyTypography**

In `Maugham/Editor/ScreenplayMode.swift`, find the existing inline-span pass (handles inline notes). Extend it to handle italic/bold/underline:

```swift
        // Second pass — inline spans (notes + emphasis).
        for line in script.lines where !line.inlineSpans.isEmpty {
            // Skip lines that are entirely .note — they're already styled.
            if line.element == .note { continue }
            for span in line.inlineSpans {
                guard NSMaxRange(span.range) <= storage.length else { continue }
                applyInlineSpan(span, in: storage, palette: palette,
                                baseFont: baseFont)
            }
        }
```

Add the helper:

```swift
    private func applyInlineSpan(
        _ span: FountainInlineSpan,
        in storage: NSTextStorage,
        palette: ThemePalette,
        baseFont: NSFont
    ) {
        switch span.kind {
        case .note:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            storage.addAttributes(
                [.font: italic, .foregroundColor: dim(palette.secondaryText, alpha: 0.4)],
                range: span.range)

        case .italic:
            let markerLen = 1
            let inner = NSRange(
                location: span.range.location + markerLen,
                length: span.range.length - markerLen * 2)
            applyTrait(.italic, in: storage, range: inner, baseFont: baseFont)
            // Fade the asterisk markers.
            fadeMarker(in: storage, location: span.range.location, length: 1,
                       palette: palette)
            fadeMarker(in: storage,
                       location: span.range.location + span.range.length - 1,
                       length: 1, palette: palette)

        case .bold:
            let markerLen = 2
            let inner = NSRange(
                location: span.range.location + markerLen,
                length: span.range.length - markerLen * 2)
            applyTrait(.bold, in: storage, range: inner, baseFont: baseFont)
            fadeMarker(in: storage, location: span.range.location, length: 2,
                       palette: palette)
            fadeMarker(in: storage,
                       location: span.range.location + span.range.length - 2,
                       length: 2, palette: palette)

        case .underline:
            let markerLen = 1
            let inner = NSRange(
                location: span.range.location + markerLen,
                length: span.range.length - markerLen * 2)
            storage.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: inner)
            fadeMarker(in: storage, location: span.range.location, length: 1,
                       palette: palette)
            fadeMarker(in: storage,
                       location: span.range.location + span.range.length - 1,
                       length: 1, palette: palette)
        }
    }

    private func applyTrait(
        _ trait: NSFontDescriptor.SymbolicTraits,
        in storage: NSTextStorage,
        range: NSRange,
        baseFont: NSFont
    ) {
        // Compose with any existing font traits at the range.
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let current = (value as? NSFont) ?? baseFont
            var traits = current.fontDescriptor.symbolicTraits
            traits.insert(trait)
            if let composed = NSFont(
                descriptor: current.fontDescriptor.withSymbolicTraits(traits),
                size: current.pointSize) {
                storage.addAttribute(.font, value: composed, range: subrange)
            }
        }
    }

    private func fadeMarker(
        in storage: NSTextStorage,
        location: Int,
        length: Int,
        palette: ThemePalette
    ) {
        let range = NSRange(location: location, length: length)
        guard NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.foregroundColor,
                             value: palette.syntaxPunctuation,
                             range: range)
    }
```

This `applyTrait` helper is the key piece for composition: it READS the existing font at each subrange, INSERTS the new trait, and re-applies. So when italic runs over a range that's already bold, the result is bold-italic.

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/InlineEmphasisStylingTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 454 passing (449 + 5).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/ScreenplayMode.swift MaughamTests/InlineEmphasisStylingTests.swift
git commit -m "feat: ScreenplayMode applies italic/bold/underline emphasis styling

Inline-span pass extends to apply the corresponding font/underline
trait to inner content ranges. Markers (*, **, _) fade in
syntaxPunctuation. applyTrait helper composes traits with any
existing font at the range, so '*foo **bar** baz*' renders bar as
bold-italic where the spans overlap.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: SyntaxHelpSheet view + AttributedString markdown rendering

**Files:**
- Create: `Maugham/Views/SyntaxHelpSheet.swift`
- Create: `MaughamTests/SyntaxHelpSheetTests.swift`

SwiftUI sheet that renders the bundled markdown documentation. Mode-aware: shows `markdown-syntax.md` for prose, `fountain-syntax.md` for screenplay.

- [ ] **Step 1: Create the test file**

Create `MaughamTests/SyntaxHelpSheetTests.swift`:

```swift
import XCTest
@testable import Maugham

final class SyntaxHelpSheetTests: XCTestCase {

    func test_loadContent_proseMode_returnsMarkdownDoc() {
        let content = SyntaxHelpSheet.loadContent(mode: .prose)
        XCTAssertGreaterThan(content.characters.count, 100)
    }

    func test_loadContent_screenplayMode_returnsFountainDoc() {
        let content = SyntaxHelpSheet.loadContent(mode: .screenplay)
        XCTAssertGreaterThan(content.characters.count, 100)
    }

    func test_loadContent_modes_returnDifferentContent() {
        let prose = SyntaxHelpSheet.loadContent(mode: .prose)
        let screenplay = SyntaxHelpSheet.loadContent(mode: .screenplay)
        XCTAssertNotEqual(String(prose.characters), String(screenplay.characters))
    }
}
```

- [ ] **Step 2: Create the SyntaxHelpSheet view**

Create `Maugham/Views/SyntaxHelpSheet.swift`:

```swift
import SwiftUI

public enum SyntaxHelpMode {
    case prose
    case screenplay
}

struct SyntaxHelpSheet: View {
    let mode: SyntaxHelpMode
    @Environment(\.dismiss) private var dismiss

    @State private var content: AttributedString = AttributedString("")

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .navigationTitle(navigationTitle)
        }
        .frame(minWidth: 640, minHeight: 480)
        .task {
            content = Self.loadContent(mode: mode)
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .prose:        return "Markdown Syntax"
        case .screenplay:   return "Fountain Syntax"
        }
    }

    static func loadContent(mode: SyntaxHelpMode) -> AttributedString {
        let resourceName: String
        switch mode {
        case .prose:        resourceName = "markdown-syntax"
        case .screenplay:   resourceName = "fountain-syntax"
        }
        guard let url = Bundle.main.url(
                forResource: resourceName, withExtension: "md"),
              let data = try? Data(contentsOf: url) else {
            return AttributedString("Help content unavailable.")
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full)
        if let attributed = try? AttributedString(markdown: data, options: options) {
            return attributed
        }
        // Fallback to raw text on parse failure.
        if let raw = String(data: data, encoding: .utf8) {
            return AttributedString(raw)
        }
        return AttributedString("Help content unavailable.")
    }
}
```

The `.full` interpretation supports headings, lists, links, and (best-effort) tables. If smoke shows tables broken, fall back to `.inlineOnlyPreservingWhitespace` (less rendering but more reliable structure).

- [ ] **Step 3: Build (note: bundle resources land in T14)**

The view will reference `Bundle.main.url(forResource: ...)` but the docs aren't bundled yet. The test will fail until T14 lands the project.yml resource directive. That's expected — proceed to step 4.

- [ ] **Step 4: Run targeted tests, expect failures (resources not bundled yet)**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/SyntaxHelpSheetTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: tests fail (resources not yet bundled). This is fine — T14 makes them pass.

- [ ] **Step 5: Build to verify the view compiles**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Views/SyntaxHelpSheet.swift MaughamTests/SyntaxHelpSheetTests.swift
git commit -m "feat: SyntaxHelpSheet view for ⌘? help overlay

SwiftUI sheet that renders bundled markdown-syntax.md (prose) or
fountain-syntax.md (screenplay) via AttributedString(markdown:).
Mode-aware navigation title. Done button dismisses (default Escape
also).

Resource bundling in next task. Tests pass after that.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: Bundle markdown-syntax.md and fountain-syntax.md as resources

**Files:**
- Modify: `project.yml` (xcodegen)

Adds the docs files as bundled resources of the main Maugham app target.

- [ ] **Step 1: Read project.yml to find the Maugham target definition**

Run: `grep -A 20 "^  Maugham:" /Users/denver/src/Maugham/project.yml | head -25`

Look for the `sources:` and (if present) `resources:` keys under the `Maugham:` target.

- [ ] **Step 2: Add resources entry**

Edit `project.yml`. Under the `Maugham:` target, add (or append to) a `resources:` key:

```yaml
  Maugham:
    type: application
    # ... existing sources, etc. ...
    resources:
      - path: docs/markdown-syntax.md
      - path: docs/fountain-syntax.md
```

If `resources:` already exists with other entries, append the two new entries.

- [ ] **Step 3: Regenerate the project**

Run: `./gen.sh`

Expected: clean exit; `Maugham.xcodeproj` regenerated with the new resources.

- [ ] **Step 4: Run SyntaxHelpSheet tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/SyntaxHelpSheetTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 3 tests, with 0 failures` (now that resources are bundled).

- [ ] **Step 5: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 457 passing (454 + 3).

- [ ] **Step 6: Commit**

```bash
git add project.yml
git commit -m "feat: bundle syntax doc files as Maugham app resources

docs/markdown-syntax.md and docs/fountain-syntax.md now ship with
the app bundle so SyntaxHelpSheet can load them via Bundle.main.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: Help menu command + ⌘ Shift / shortcut + ProjectWindow sheet wiring

**Files:**
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`
- Modify: `Maugham/Models/MaughamNotifications.swift`

Help menu command posts a notification. ProjectWindow listens, toggles a state to present the sheet.

- [ ] **Step 1: Add notification name**

In `Maugham/Models/MaughamNotifications.swift`, append:

```swift
extension Notification.Name {
    public static let maughamShowSyntaxHelp = Notification.Name("maugham.show.syntax.help")
}
```

- [ ] **Step 2: Add menu command in MaughamApp.swift**

In `Maugham/MaughamApp.swift`, find the `.commands` block. Add a Help-menu command:

```swift
.commands {
    // ... existing commands ...
    CommandGroup(replacing: .help) {
        Button("Syntax Reference") {
            NotificationCenter.default.post(
                name: .maughamShowSyntaxHelp, object: nil)
        }
        .keyboardShortcut("?", modifiers: [.command, .shift])
    }
}
```

If `CommandGroup(replacing: .help)` is already used elsewhere (for the existing Claude Desktop help), MERGE the new button into that block instead of replacing twice (only one replacement per CommandGroupPlacement is allowed).

- [ ] **Step 3: Wire the sheet into ProjectWindow**

In `Maugham/Views/ProjectWindow.swift`, add state for showing the sheet:

```swift
@State private var showingSyntaxHelp = false
```

Add the sheet modifier on the body (or wherever sheet attachment makes sense):

```swift
.sheet(isPresented: $showingSyntaxHelp) {
    SyntaxHelpSheet(mode: currentSyntaxHelpMode)
}
.onReceive(NotificationCenter.default.publisher(for: .maughamShowSyntaxHelp)) { _ in
    showingSyntaxHelp = true
}
```

Add the helper computing the mode based on the active document:

```swift
    private var currentSyntaxHelpMode: SyntaxHelpMode {
        guard let store,
              let doc = selectedItemId.flatMap({
                  findItem(id: $0, in: store.manifest.structure)
              }),
              let path = doc.path else {
            return .prose
        }
        return WritingModeFactory.mode(for: path) is ScreenplayMode
            ? .screenplay : .prose
    }
```

If `findItem` isn't accessible from this view (private to another), add a similar helper or use a simpler heuristic like `store.manifest.type == .screenplay ? .screenplay : .prose`.

- [ ] **Step 4: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 457 passing (no new tests this task; visual flow verified in smoke).

- [ ] **Step 5: Build to verify**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift Maugham/Models/MaughamNotifications.swift
git commit -m "feat: ⌘ Shift / opens syntax help sheet

Help-menu command 'Syntax Reference' posts maughamShowSyntaxHelp.
ProjectWindow subscribes and presents SyntaxHelpSheet with the
appropriate mode (prose vs screenplay) based on the active document.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: Phase 2 smoke checkpoint

**Files:** none directly — manual smoke.

Phase 2 deliverables: ⌘? help + inline emphasis. Final smoke before tagging.

- [ ] **Step 1: Run full test suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: 457+ passing.

- [ ] **Step 2: Build and launch**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3` → BUILD SUCCEEDED.

Launch via the built app.

- [ ] **Step 3: Walk through Phase 2 smoke checklist**

1. Open a screenplay project. Press `⌘ Shift /` → sheet opens with "Fountain Syntax" title and the contents of fountain-syntax.md rendered.
2. Scroll through the sheet. Press Done or Escape → sheet dismisses.
3. Switch to a Novel/prose project. Press `⌘ Shift /` → sheet opens with "Markdown Syntax" content.
4. In a screenplay, type `*italic*` in dialogue → inner text renders italic, asterisks fade.
5. Type `**bold**` in action → inner text bold, `**` faded.
6. Type `_underline_` in dialogue → underlined.
7. Type `*foo **bar** baz*` → bar renders bold-italic; foo/baz italic only.
8. Theme switch (Light/Dark/Sepia) → emphasis colors update; help sheet content re-renders if open.
9. Both Phase 1 features still work (re-verify):
   - Scene navigator updates as you type
   - Title page renders styled
   - ⌘\\ no-chrome mode still hides chrome correctly
10. Open the reference fountain fixture → all styling correct, scene navigator full.

- [ ] **Step 4: Fix any smoke regressions**

For each failure:
- Diagnose using SwiftUI/AppKit lessons from prior milestones
- Commit each fix separately with a `fix:` prefix

Likely pitfalls in Phase 2:
- AttributedString markdown table rendering (fountain-syntax.md has tables)
- Menu command not registering (CommandGroup conflict with existing help)
- Sheet not presenting (notification publisher not hooked up)
- Bold-italic font composition not producing bold-italic font for unusual font configs

---

## Task 17: Tag milestone-3c

**Files:** none directly — git tag + push + memory update.

- [ ] **Step 1: ff-merge to main**

```bash
git checkout main
git merge --ff-only feat/milestone-3c
```

- [ ] **Step 2: Tag milestone-3c**

```bash
git tag -a milestone-3c -m "Phase 3c complete: Scene navigator + Title page + Inline emphasis + ⌘? Help

Scene navigator pane in the binder for screenplay projects (Scenes /
Research segments, replaces Manuscript). Lists sluglines with page
numbers; click jumps the editor cursor to the scene line.

Title page block parsing + inline rendering at document head.
Per-key styling: Title bold+centered+1.5x; Author smaller centered;
Draft date small/dim left-aligned. Body has visual gap below.

Inline emphasis: *italic*, **bold**, _underline_ inside dialogue and
action. Markers fade per the milestone-3b pattern. Composition
(*foo **bar** baz*) yields bold-italic on overlap.

⌘ Shift / syntax help overlay: SwiftUI sheet rendering bundled
markdown-syntax.md (prose) or fountain-syntax.md (screenplay) via
AttributedString(markdown:).

Test count: ~457 passing (was 412; +45 new for 3c).

Implementation had two-phase smoke gates: navigator + title page
first, then ⌘? help + emphasis. Caught Phase 1 issues before
piling on Phase 2 surface area.

Next: 3d (multi-file screenplay) — final Phase 3 sub-milestone.
"
```

- [ ] **Step 3: Push**

```bash
git push origin main
git push origin milestone-3c
```

- [ ] **Step 4: Update memory**

Save `project_milestone_3c.md` and add a one-liner to `MEMORY.md`. Note any implementer judgment calls or smoke fixes from Phase 1 / Phase 2.

- [ ] **Step 5: Notify the user**

Summarize what shipped, any deferred items (autocomplete carry-forward, Statistics scene-by-scene), and what's next (3d: multi-file screenplay).

---

## Self-review checklist

After writing the plan, run this against the spec.

**Spec coverage:**
- §1 Goals — Tasks 1-15 collectively cover all four features.
- §2 Architecture — Tasks 1, 4, 7, 8, 13, 15 instantiate each component.
- §3 Scene navigator (binder placement, row format, page numbers, click flow) — Tasks 6, 7, 8, 9.
- §4 Title page (parsing, classification, rendering, gap) — Tasks 1, 2, 4, 5.
- §5 Inline emphasis (tokenizer, styling, composition) — Tasks 11, 12.
- §6 ⌘? help (sheet, markdown, bundle, menu) — Tasks 13, 14, 15.
- §7 EditorCoordinator changes — Task 9.
- §8 Testing strategy — covered across Tasks 2, 3, 4, 5, 7, 11, 12, 13, 14.
- §9 Implementation sequencing — matches plan task order.
- §10 Risks — addressed inline in task notes.

**Placeholder scan:** searched for "TBD", "TODO", "implement later", "Add appropriate" — none found.

**Type consistency:** verified across tasks:
- `TitlePageField` — T1 defines; T2 populates; T4 styles.
- `ScreenplayElement.titlePage` — T1 adds; T2 emits; T4/T5 handle in switches.
- `FountainScript.titlePage: [TitlePageField]?` — T1 adds; T2 populates; T4 reads.
- `FountainScript.pageNumber(at:)` — T3 adds; T7 reads.
- `BinderSegment.scenes` — T6 adds; T8 routes.
- `SceneNavigatorPane(script:onSelect:)` — T7 defines; T8 calls.
- `Notification.Name.maughamNavigateToScene` — T8 declares; T9 subscribes; T7 posts via callback.
- `Notification.Name.maughamScriptDidUpdate` — T8 adds; T8 posts in retokenizeAndStyle; T8 ProjectWindow subscribes.
- `Notification.Name.maughamShowSyntaxHelp` — T15 declares + posts + subscribes.
- `FountainInlineSpan.Kind` cases (.italic, .bold, .underline) — T11 adds; T12 styles.
- `SyntaxHelpSheet(mode:)` and `SyntaxHelpMode` — T13 defines; T15 instantiates.

All consistent.

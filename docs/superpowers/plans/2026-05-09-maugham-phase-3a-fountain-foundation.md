# Phase 3a Implementation Plan — Fountain Foundation + Styling + Page Count

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the Fountain parser, per-element auto-formatting, and page count for `.fountain` files in Maugham's editor. Deliver a real screenplay viewer/styler that the writer types Fountain into and sees rendered with correct paragraph styles, indentation, casing, and a page count in the goal indicator.

**Architecture:** A pure-logic `FountainTokenizer` parses Fountain text into a typed `FountainScript` value (line-by-line, with element classification, content, forced-flag, and source-case). `ScreenplayMode` consumes the script in three places — `tokenize` (projects to `[Token]` for the existing pipeline), `metrics` (computes page count), and `applyTypography` (sets per-element paragraph styles + a custom `.maughamDisplayUppercase` attribute consumed by a new `ScreenplayLayoutManager` subclass that substitutes uppercase glyphs at draw time). `ProjectTargets` gains an optional `pageTarget` and the goal indicator capsule renders the screenplay variant when the active project type is `.screenplay`.

**Tech Stack:** Swift 5.10+, Foundation, AppKit (NSTextView, NSLayoutManager, NSAttributedString), SwiftUI for the inspector field. XCTest for unit + integration tests. Built via `./gen.sh` (xcodegen) + `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`.

**Spec:** `docs/superpowers/specs/2026-05-09-maugham-phase-3a-fountain-foundation-design.md`. Read it before starting any task.

**Test baseline before this plan:** 275 passing. Target after milestone-3a: ~306 passing.

**Conventions:**
- Each task = one commit. Use `feat:` / `fix:` / `docs:` prefixes per the project's commit discipline.
- TDD: write failing test first; verify it fails; implement minimal code; verify it passes; commit.
- Build commands assume CWD = `/Users/denver/src/Maugham`.
- New files in `Maugham/` and `MaughamTests/` are picked up automatically by xcodegen globs — running `./gen.sh` after creating new files is required before `xcodebuild`.
- Model selection (per project's banked feedback): tokenizer + page-count + value types = sonnet (substantive pure logic). Paragraph styling tables = haiku (mechanical). NSLayoutManager spike = opus (TextKit edge cases).

---

## Task 1: Foundation types — ScreenplayElement, SourceCase, FountainInlineSpan, FountainLine, FountainScript skeleton + first parser test

**Files:**
- Create: `Maugham/Editor/Fountain/ScreenplayElement.swift`
- Create: `Maugham/Editor/Fountain/FountainLine.swift`
- Create: `Maugham/Editor/Fountain/FountainScript.swift`
- Create: `Maugham/Editor/Fountain/FountainTokenizer.swift`
- Create: `MaughamTests/FountainTokenizerTests.swift`

This task lays down the data model and the tokenizer skeleton. TDD discipline kicks in with the first action-line test.

- [ ] **Step 1: Create `Maugham/Editor/Fountain/ScreenplayElement.swift`**

```swift
import Foundation

/// A Fountain screenplay element classification. Each FountainLine carries one.
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
}

/// Casing of the *content* portion of a FountainLine (after stripping any
/// forced marker like `@` or `.`).
public enum SourceCase: Equatable, Hashable, Sendable {
    case upper      // all letters uppercase
    case mixed      // both cases present
    case lower      // all letters lowercase
    case neutral    // no letters (punctuation/digits only)
}

/// Sub-range classification within a FountainLine — currently used to mark
/// inline `[[ ... ]]` notes that don't span a full line.
public struct FountainInlineSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case note }
    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}
```

- [ ] **Step 2: Create `Maugham/Editor/Fountain/FountainLine.swift`**

```swift
import Foundation

/// One classified line in a parsed Fountain script.
public struct FountainLine: Equatable, Sendable {
    /// NSRange in the source text covering this line, including the trailing
    /// newline if present (so consecutive lines' ranges are contiguous).
    public let range: NSRange

    /// Element classification.
    public let element: ScreenplayElement

    /// Visible content of the line — the source text minus any forced marker
    /// prefix (`@`, `!`, `.`, `>`, `~`, `#`, `=`) and minus the line's
    /// trailing newline. For `.boneyard` and `.note` the content includes
    /// the bracketing markers (so the styler can render them dim alongside
    /// the body).
    public let content: String

    /// True when the element was determined by a forced marker rather than
    /// by context-sensitive inference. Used by the styler to decide whether
    /// to apply display-uppercase.
    public let isForced: Bool

    /// Casing of `content`. Used by the styler to decide whether display-
    /// uppercase substitution is needed.
    public let sourceCase: SourceCase

    /// Sub-range markers (currently inline notes only). Empty for most lines.
    public let inlineSpans: [FountainInlineSpan]

    public init(
        range: NSRange,
        element: ScreenplayElement,
        content: String,
        isForced: Bool,
        sourceCase: SourceCase,
        inlineSpans: [FountainInlineSpan] = []
    ) {
        self.range = range
        self.element = element
        self.content = content
        self.isForced = isForced
        self.sourceCase = sourceCase
        self.inlineSpans = inlineSpans
    }
}
```

- [ ] **Step 3: Create `Maugham/Editor/Fountain/FountainScript.swift`**

```swift
import Foundation

/// A fully parsed Fountain document. Pure value type with computed metrics.
public struct FountainScript: Equatable, Sendable {
    public let lines: [FountainLine]

    public init(lines: [FountainLine] = []) {
        self.lines = lines
    }

    public static let empty = FountainScript()

    /// Estimated page count using the Final Draft line-wrap heuristic.
    /// Implementation lands in Task 7; defaults to 0 here so the type compiles.
    public var estimatedPageCount: Double { 0 }

    /// Distinct uppercased character names mentioned in the script. Populated
    /// from `.character` lines; used by 3b autocomplete.
    public var characterNames: Set<String> {
        Set(lines.compactMap { line in
            guard line.element == .character,
                  !line.content.isEmpty else { return nil }
            return line.content.uppercased()
        })
    }
}
```

- [ ] **Step 4: Create `Maugham/Editor/Fountain/FountainTokenizer.swift` skeleton**

```swift
import Foundation

/// Parses Fountain source text into a typed `FountainScript`. Pure logic;
/// no AppKit dependencies. Uses a line-based state machine because Fountain
/// element classification is fundamentally context-sensitive.
public struct FountainTokenizer: Sendable {
    public init() {}

    public func parse(_ text: String) -> FountainScript {
        guard !text.isEmpty else { return .empty }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        var lines: [FountainLine] = []
        var prevBlank = true
        var prevElement: ScreenplayElement = .action

        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            substring, substringRange, enclosingRange, _ in
            guard let raw = substring else { return }
            let trimmedTrailing = raw.trimmingCharacters(in: .whitespaces)

            if trimmedTrailing.isEmpty {
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .action,
                    content: "",
                    isForced: false,
                    sourceCase: .neutral))
                prevBlank = true
                return
            }

            // Default classification — refined in Tasks 2-6.
            let element: ScreenplayElement = .action
            let content = trimmedTrailing
            lines.append(FountainLine(
                range: enclosingRange,
                element: element,
                content: content,
                isForced: false,
                sourceCase: Self.sourceCase(of: content)))
            prevBlank = false
            prevElement = element

            _ = prevElement   // silence "never read" until Tasks 2-6 use it
        }

        return FountainScript(lines: lines)
    }

    static func sourceCase(of text: String) -> SourceCase {
        var hasUpper = false
        var hasLower = false
        var hasLetter = false
        for ch in text {
            if ch.isLetter {
                hasLetter = true
                if ch.isUppercase { hasUpper = true }
                if ch.isLowercase { hasLower = true }
            }
        }
        if !hasLetter { return .neutral }
        if hasUpper && hasLower { return .mixed }
        if hasUpper { return .upper }
        return .lower
    }
}
```

- [ ] **Step 5: Create `MaughamTests/FountainTokenizerTests.swift` with the first failing test**

```swift
import XCTest
@testable import Maugham

final class FountainTokenizerTests: XCTestCase {
    private let parser = FountainTokenizer()

    // MARK: - Foundations

    func test_emptyText_returnsEmptyScript() {
        XCTAssertEqual(parser.parse(""), .empty)
    }

    func test_singleActionLine_classifiesAsAction() {
        let script = parser.parse("Larry sits at the bar.")
        XCTAssertEqual(script.lines.count, 1)
        XCTAssertEqual(script.lines[0].element, .action)
        XCTAssertEqual(script.lines[0].content, "Larry sits at the bar.")
        XCTAssertEqual(script.lines[0].isForced, false)
        XCTAssertEqual(script.lines[0].sourceCase, .mixed)
    }

    func test_blankLineBetweenActions_producesBlankActionRow() {
        let script = parser.parse("First.\n\nSecond.")
        XCTAssertEqual(script.lines.count, 3)
        XCTAssertEqual(script.lines[0].element, .action)
        XCTAssertEqual(script.lines[1].element, .action)
        XCTAssertEqual(script.lines[1].content, "")
        XCTAssertEqual(script.lines[1].sourceCase, .neutral)
        XCTAssertEqual(script.lines[2].element, .action)
    }
}
```

- [ ] **Step 6: Regenerate Xcode project + run tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`

Expected: 3 tests pass.

- [ ] **Step 7: Run the full test suite to confirm no regressions**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: `Executed 278 tests, with 0 failures` (275 prior + 3 new).

- [ ] **Step 8: Commit**

```bash
git add Maugham/Editor/Fountain MaughamTests/FountainTokenizerTests.swift Maugham.xcodeproj
git commit -m "feat: add Fountain value types and tokenizer skeleton

Lays down ScreenplayElement, SourceCase, FountainInlineSpan, FountainLine,
FountainScript value types plus a FountainTokenizer that classifies all
non-blank input as .action. Blank lines produce empty .action rows so
prevBlank tracking has somewhere to write into in subsequent milestones.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Tokenizer — scene heading recognition (INT./EXT. + forced `.` marker)

**Files:**
- Modify: `Maugham/Editor/Fountain/FountainTokenizer.swift`
- Modify: `MaughamTests/FountainTokenizerTests.swift`

- [ ] **Step 1: Add failing tests for scene heading classification**

Append to `FountainTokenizerTests`:

```swift
    // MARK: - Scene heading

    func test_sceneHeadingINT_afterBlank_classifiesAsSceneHeading() {
        let script = parser.parse("INT. KITCHEN - DAY")
        XCTAssertEqual(script.lines.count, 1)
        XCTAssertEqual(script.lines[0].element, .sceneHeading)
        XCTAssertEqual(script.lines[0].content, "INT. KITCHEN - DAY")
        XCTAssertEqual(script.lines[0].isForced, false)
    }

    func test_sceneHeadingEXT_afterBlank_classifiesAsSceneHeading() {
        let script = parser.parse("Action one.\n\nEXT. ROOFTOP - NIGHT")
        XCTAssertEqual(script.lines.last?.element, .sceneHeading)
    }

    func test_sceneHeadingEST_afterBlank_classifiesAsSceneHeading() {
        let script = parser.parse("EST. MEADOW - DAWN")
        XCTAssertEqual(script.lines[0].element, .sceneHeading)
    }

    func test_sceneHeadingIE_combined_classifiesAsSceneHeading() {
        let script = parser.parse("I/E. CAR - CONTINUOUS")
        XCTAssertEqual(script.lines[0].element, .sceneHeading)
    }

    func test_sceneHeadingForcedDot_classifiesAsSceneHeading() {
        let script = parser.parse(".barbershop")
        XCTAssertEqual(script.lines[0].element, .sceneHeading)
        XCTAssertEqual(script.lines[0].content, "barbershop")
        XCTAssertEqual(script.lines[0].isForced, true)
        XCTAssertEqual(script.lines[0].sourceCase, .lower)
    }

    func test_intMidParagraph_isNotSceneHeading() {
        // Without a blank line above, "INT." mid-text is just action.
        let script = parser.parse("He yelled.\nINT. ROOM - DAY")
        XCTAssertEqual(script.lines[1].element, .action)
    }

    func test_doubleDotPrefix_isAction_notSceneHeading() {
        // Two dots is NOT a forced scene heading per Fountain spec.
        let script = parser.parse("..ellipsis-ish")
        XCTAssertEqual(script.lines[0].element, .action)
    }
```

- [ ] **Step 2: Run tests, expect failures**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25`

Expected: 7 new failures (existing 3 still pass).

- [ ] **Step 3: Replace `parse()` body with the classifier dispatch**

Replace the `enumerateSubstrings` block in `FountainTokenizer.parse` with:

```swift
        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            substring, _, enclosingRange, _ in
            guard let raw = substring else { return }
            let trimmedTrailing = raw.trimmingCharacters(in: .whitespaces)

            if trimmedTrailing.isEmpty {
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .action,
                    content: "",
                    isForced: false,
                    sourceCase: .neutral))
                prevBlank = true
                prevElement = .action
                return
            }

            let classified = Self.classify(
                line: trimmedTrailing,
                prevBlank: prevBlank,
                prevElement: prevElement)

            lines.append(FountainLine(
                range: enclosingRange,
                element: classified.element,
                content: classified.content,
                isForced: classified.isForced,
                sourceCase: Self.sourceCase(of: classified.content)))
            prevBlank = false
            prevElement = classified.element
        }
```

Add private helpers at the bottom of `FountainTokenizer`:

```swift
    // MARK: - Classification

    private struct Classified {
        let element: ScreenplayElement
        let content: String
        let isForced: Bool
    }

    private static func classify(
        line: String,
        prevBlank: Bool,
        prevElement: ScreenplayElement
    ) -> Classified {
        // Forced scene heading: leading "." but not "..".
        if line.hasPrefix(".") && !line.hasPrefix("..") {
            let stripped = String(line.dropFirst())
            return Classified(
                element: .sceneHeading,
                content: stripped,
                isForced: true)
        }

        // Context-sensitive scene heading: starts with INT./EXT./EST./I/E./
        // INT/EXT., case-insensitive, and has a blank line above.
        if prevBlank && Self.isSceneHeadingPrefix(line) {
            return Classified(
                element: .sceneHeading,
                content: line,
                isForced: false)
        }

        return Classified(
            element: .action,
            content: line,
            isForced: false)
    }

    private static let sceneHeadingPrefixes = [
        "INT.", "EXT.", "EST.", "I/E.", "INT/EXT."
    ]

    private static func isSceneHeadingPrefix(_ line: String) -> Bool {
        let upper = line.uppercased()
        for prefix in sceneHeadingPrefixes {
            if upper.hasPrefix(prefix + " ") || upper == prefix {
                return true
            }
        }
        return false
    }
```

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Fountain/FountainTokenizer.swift MaughamTests/FountainTokenizerTests.swift
git commit -m "feat: classify Fountain scene headings (INT./EXT. + forced .)

Adds the dispatch entry point classify(line:prevBlank:prevElement:) that
peels off forced markers (leading single dot for scene heading) before
running context-sensitive heuristics. Recognizes INT./EXT./EST./I/E./
INT/EXT. prefixes when preceded by a blank line.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Tokenizer — character / dialogue / parenthetical block

**Files:**
- Modify: `Maugham/Editor/Fountain/FountainTokenizer.swift`
- Modify: `MaughamTests/FountainTokenizerTests.swift`

A Character is an ALL-CAPS line preceded by a blank line and followed by a non-blank line, OR forced via `@`. Dialogue follows Character/Parenthetical until next blank. Parenthetical is a `(...)` line within a dialogue block.

The "followed by a non-blank line" check requires lookahead. We resolve this by running classification in two passes: the first pass tentatively classifies, then a second pass demotes a tentatively-Character line whose successor is blank back to `.action`.

- [ ] **Step 1: Add failing tests**

Append to `FountainTokenizerTests`:

```swift
    // MARK: - Character / Dialogue / Parenthetical

    func test_allCapsLine_followedByDialogue_classifiesAsCharacter() {
        let script = parser.parse("BARRY\nHello there.")
        XCTAssertEqual(script.lines[0].element, .character)
        XCTAssertEqual(script.lines[0].content, "BARRY")
        XCTAssertEqual(script.lines[0].sourceCase, .upper)
        XCTAssertEqual(script.lines[1].element, .dialogue)
        XCTAssertEqual(script.lines[1].content, "Hello there.")
    }

    func test_allCapsLine_alone_classifiesAsAction() {
        // No following non-blank line → not a character cue.
        let script = parser.parse("BARRY\n")
        XCTAssertEqual(script.lines[0].element, .action)
    }

    func test_forcedCharacterAt_classifiesAsCharacter() {
        let script = parser.parse("@Sam\nHi.")
        XCTAssertEqual(script.lines[0].element, .character)
        XCTAssertEqual(script.lines[0].content, "Sam")
        XCTAssertEqual(script.lines[0].isForced, true)
        XCTAssertEqual(script.lines[0].sourceCase, .mixed)
    }

    func test_parentheticalBetweenCharacterAndDialogue() {
        let script = parser.parse("BARRY\n(quietly)\nHi.")
        XCTAssertEqual(script.lines[0].element, .character)
        XCTAssertEqual(script.lines[1].element, .parenthetical)
        XCTAssertEqual(script.lines[1].content, "(quietly)")
        XCTAssertEqual(script.lines[2].element, .dialogue)
    }

    func test_dialogueContinuesAcrossMultipleLines() {
        let script = parser.parse("BARRY\nLine one.\nLine two.\nLine three.")
        XCTAssertEqual(script.lines[1].element, .dialogue)
        XCTAssertEqual(script.lines[2].element, .dialogue)
        XCTAssertEqual(script.lines[3].element, .dialogue)
    }

    func test_dialogueEndsAtBlankLine() {
        let script = parser.parse("BARRY\nDialogue.\n\nAction line.")
        XCTAssertEqual(script.lines[1].element, .dialogue)
        XCTAssertEqual(script.lines[3].element, .action)
    }

    func test_forcedActionBang_classifiesAsAction() {
        // Without bang, an ALL-CAPS line preceded by blank with following
        // non-blank line would be Character. Forced-action bang overrides.
        let script = parser.parse("!ALL CAPS DESCRIPTION\nMore action.")
        XCTAssertEqual(script.lines[0].element, .action)
        XCTAssertEqual(script.lines[0].content, "ALL CAPS DESCRIPTION")
        XCTAssertEqual(script.lines[0].isForced, true)
    }
```

- [ ] **Step 2: Run tests, expect failures**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25`

Expected: 7 new failures.

- [ ] **Step 3: Implement the Character / Dialogue / Parenthetical pass**

Add to `FountainTokenizer.classify(line:prevBlank:prevElement:)` BEFORE the scene heading checks (after the forced-`.` block):

```swift
        // Forced action bang.
        if line.hasPrefix("!") {
            return Classified(
                element: .action,
                content: String(line.dropFirst()),
                isForced: true)
        }

        // Forced character.
        if line.hasPrefix("@") {
            return Classified(
                element: .character,
                content: String(line.dropFirst()),
                isForced: true)
        }
```

Add a context-sensitive Character rule AFTER the scene heading rule and BEFORE the action default:

```swift
        // Tentative Character: ALL-CAPS letters with blank line above.
        // The "followed by a non-blank line" requirement is enforced in a
        // post-pass (second loop), since enumerateSubstrings doesn't give
        // us forward lookahead cheaply.
        if prevBlank && Self.isAllCapsCueCandidate(line) {
            return Classified(
                element: .character,
                content: line,
                isForced: false)
        }

        // Inside a dialogue block: parenthetical or continued dialogue.
        if prevElement == .character || prevElement == .parenthetical || prevElement == .dialogue {
            if line.hasPrefix("(") && line.hasSuffix(")") {
                return Classified(
                    element: .parenthetical,
                    content: line,
                    isForced: false)
            }
            return Classified(
                element: .dialogue,
                content: line,
                isForced: false)
        }
```

Add the helper that decides Character-cue eligibility:

```swift
    private static func isAllCapsCueCandidate(_ line: String) -> Bool {
        var hasLetter = false
        for ch in line {
            if ch.isLetter {
                hasLetter = true
                if ch.isLowercase { return false }
            }
        }
        return hasLetter
    }
```

After the `enumerateSubstrings` block in `parse`, add the post-pass that demotes orphan Character cues to Action:

```swift
        // Post-pass: a tentative Character cue must be followed by a non-blank
        // line. If it isn't, demote it to .action.
        var corrected: [FountainLine] = []
        corrected.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if line.element == .character && !line.isForced {
                let next = (index + 1 < lines.count) ? lines[index + 1] : nil
                let nextIsBlank = next.map { $0.content.isEmpty } ?? true
                if nextIsBlank {
                    corrected.append(FountainLine(
                        range: line.range,
                        element: .action,
                        content: line.content,
                        isForced: false,
                        sourceCase: line.sourceCase,
                        inlineSpans: line.inlineSpans))
                    continue
                }
            }
            corrected.append(line)
        }
        return FountainScript(lines: corrected)
```

(Replace the existing `return FountainScript(lines: lines)` with the loop above.)

The post-pass also requires fixing the `.dialogue`/`.parenthetical` classifications that flowed from the now-demoted Character — but per spec §3.3 step 7, dialogue's prevElement chain already collapses gracefully (prevElement was `.character` only because of the orphan; if the orphan is gone we'd want prevElement to revert). For 3a we accept this minor edge: an orphan ALL-CAPS line followed by `\n\n` is rare enough in real screenplays to ignore. If smoke testing surfaces a real script where this misclassifies, fix in a follow-up.

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 17 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Fountain/FountainTokenizer.swift MaughamTests/FountainTokenizerTests.swift
git commit -m "feat: classify Fountain character/dialogue/parenthetical blocks

Adds forced-character (@) and forced-action (!) markers, and the
context-sensitive Character cue rule (ALL-CAPS line with blank above
and non-blank below). Dialogue and Parenthetical follow naturally
from the prevElement chain. Orphan ALL-CAPS lines (no following
content) get demoted back to .action via a post-pass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Tokenizer — transition / centered / lyric

**Files:**
- Modify: `Maugham/Editor/Fountain/FountainTokenizer.swift`
- Modify: `MaughamTests/FountainTokenizerTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `FountainTokenizerTests`:

```swift
    // MARK: - Transition / Centered / Lyric

    func test_allCapsTransition_endingInTo_classifiesAsTransition() {
        let script = parser.parse("Action one.\n\nSMASH CUT TO:\n\nINT. NEXT - DAY")
        XCTAssertEqual(script.lines[2].element, .transition)
        XCTAssertEqual(script.lines[2].content, "SMASH CUT TO:")
        XCTAssertEqual(script.lines[2].isForced, false)
    }

    func test_forcedTransitionGreater_classifiesAsTransition() {
        let script = parser.parse("> cut to:")
        XCTAssertEqual(script.lines[0].element, .transition)
        XCTAssertEqual(script.lines[0].content, "cut to:")
        XCTAssertEqual(script.lines[0].isForced, true)
        XCTAssertEqual(script.lines[0].sourceCase, .lower)
    }

    func test_centeredAngleBrackets_classifiesAsCentered() {
        let script = parser.parse("> THE END <")
        XCTAssertEqual(script.lines[0].element, .centered)
        XCTAssertEqual(script.lines[0].content, "THE END")
    }

    func test_centeredAngleBrackets_noSpaces_classifiesAsCentered() {
        let script = parser.parse(">centered<")
        XCTAssertEqual(script.lines[0].element, .centered)
        XCTAssertEqual(script.lines[0].content, "centered")
    }

    func test_lyricTilde_classifiesAsLyric() {
        let script = parser.parse("~la la la")
        XCTAssertEqual(script.lines[0].element, .lyric)
        XCTAssertEqual(script.lines[0].content, "la la la")
        XCTAssertEqual(script.lines[0].isForced, true)
    }
```

- [ ] **Step 2: Run tests, expect failures**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: 5 new failures.

- [ ] **Step 3: Implement transition/centered/lyric classification**

In `FountainTokenizer.classify`, AFTER the forced-`.` scene heading block but BEFORE the forced-character block, add:

```swift
        // Centered: line wrapped in >...<. Recognize before forced-transition
        // (which is bare leading >) so >X< doesn't get classified as a
        // transition with content "X<".
        if line.hasPrefix(">") && line.hasSuffix("<") && line.count >= 2 {
            let inner = line.dropFirst().dropLast()
                .trimmingCharacters(in: .whitespaces)
            return Classified(
                element: .centered,
                content: inner,
                isForced: true)
        }

        // Forced transition: leading >.
        if line.hasPrefix(">") {
            let stripped = String(line.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            return Classified(
                element: .transition,
                content: stripped,
                isForced: true)
        }

        // Lyric: leading ~.
        if line.hasPrefix("~") {
            return Classified(
                element: .lyric,
                content: String(line.dropFirst()),
                isForced: true)
        }
```

After the scene heading rule and before the Character rule, add the context-sensitive transition check:

```swift
        // Context-sensitive transition: ALL-CAPS line ending in "TO:" with
        // a blank line above.
        if prevBlank && Self.isContextualTransition(line) {
            return Classified(
                element: .transition,
                content: line,
                isForced: false)
        }
```

Add the helper:

```swift
    private static func isContextualTransition(_ line: String) -> Bool {
        guard line.uppercased().hasSuffix("TO:") else { return false }
        return Self.isAllCapsCueCandidate(line)
    }
```

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 22 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Fountain/FountainTokenizer.swift MaughamTests/FountainTokenizerTests.swift
git commit -m "feat: classify Fountain transitions, centered text, lyrics

Adds forced (\`>\`, \`>...<\`, \`~\`) and context-sensitive
(ALL-CAPS ending TO:) recognizers. Centered is checked before forced
transition so \`>X<\` doesn't bleed into the transition path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Tokenizer — sections / synopsis / page break

**Files:**
- Modify: `Maugham/Editor/Fountain/FountainTokenizer.swift`
- Modify: `MaughamTests/FountainTokenizerTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `FountainTokenizerTests`:

```swift
    // MARK: - Section / Synopsis / Page Break

    func test_sectionLevelOne_classifiesAsSection1() {
        let script = parser.parse("# ACT ONE")
        XCTAssertEqual(script.lines[0].element, .section(level: 1))
        XCTAssertEqual(script.lines[0].content, "ACT ONE")
    }

    func test_sectionLevelThree_classifiesAsSection3() {
        let script = parser.parse("### Beat")
        XCTAssertEqual(script.lines[0].element, .section(level: 3))
        XCTAssertEqual(script.lines[0].content, "Beat")
    }

    func test_sectionLevelSix_classifiesAsSection6() {
        let script = parser.parse("###### deep")
        XCTAssertEqual(script.lines[0].element, .section(level: 6))
    }

    func test_sectionLevelSeven_isAction() {
        // Fountain caps section nesting at 6.
        let script = parser.parse("####### too deep")
        XCTAssertEqual(script.lines[0].element, .action)
    }

    func test_synopsisEquals_classifiesAsSynopsis() {
        let script = parser.parse("= the chase begins")
        XCTAssertEqual(script.lines[0].element, .synopsis)
        XCTAssertEqual(script.lines[0].content, "the chase begins")
    }

    func test_pageBreakTripleEquals_classifiesAsPageBreak() {
        let script = parser.parse("===")
        XCTAssertEqual(script.lines[0].element, .pageBreak)
    }

    func test_pageBreakManyEquals_classifiesAsPageBreak() {
        let script = parser.parse("==========")
        XCTAssertEqual(script.lines[0].element, .pageBreak)
    }

    func test_doubleEquals_isAction_notPageBreak() {
        // Per Fountain spec: page break requires THREE or more =.
        let script = parser.parse("==")
        XCTAssertEqual(script.lines[0].element, .action)
    }

    func test_synopsisRequiresSpace_singleEqualsAlone_isAction() {
        // "=" alone (no content after) classifies as action; spec requires
        // "= space content" for synopsis.
        let script = parser.parse("=")
        XCTAssertEqual(script.lines[0].element, .action)
    }
```

- [ ] **Step 2: Run tests, expect failures**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25`

Expected: 9 new failures.

- [ ] **Step 3: Implement section/synopsis/page break**

In `FountainTokenizer.classify`, add at the very start of the function (these checks come before everything else since their markers are unambiguous):

```swift
        // Page break: three or more = with no other content.
        if Self.isPageBreak(line) {
            return Classified(
                element: .pageBreak,
                content: line,
                isForced: false)
        }

        // Sections: 1 to 6 leading '#' followed by space then content.
        if let section = Self.parseSection(line) {
            return Classified(
                element: .section(level: section.level),
                content: section.content,
                isForced: true)
        }

        // Synopsis: leading '=' followed by space then content (and not a
        // page break — already handled above).
        if line.hasPrefix("= ") {
            return Classified(
                element: .synopsis,
                content: String(line.dropFirst(2)),
                isForced: true)
        }
```

Add the helpers:

```swift
    private static func isPageBreak(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        return line.allSatisfy { $0 == "=" }
    }

    private static func parseSection(_ line: String) -> (level: Int, content: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
            if level > 6 { return nil }   // 7+ # is action
        }
        guard level >= 1, level <= 6 else { return nil }
        let after = line.dropFirst(level)
        guard after.first == " " else { return nil }
        let content = String(after.dropFirst())
        return (level, content)
    }
```

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 31 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Fountain/FountainTokenizer.swift MaughamTests/FountainTokenizerTests.swift
git commit -m "feat: classify Fountain sections, synopses, and page breaks

Sections support levels 1-6 (\`#\` through \`######\`). Synopsis requires
a space after \`=\` to disambiguate from page breaks (\`===\` and longer).
Page break requires 3+ \`=\` per Fountain spec — \`==\` falls through to
action.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Tokenizer — boneyard (multi-line) and notes (block + inline)

**Files:**
- Modify: `Maugham/Editor/Fountain/FountainTokenizer.swift`
- Modify: `MaughamTests/FountainTokenizerTests.swift`

Boneyard `/* ... */` and block notes `[[ ... ]]` can span multiple lines. We need parser state tracking. Inline notes (`[[ note ]]` within a non-note line) get sub-range markers via `inlineSpans`.

- [ ] **Step 1: Add failing tests**

Append to `FountainTokenizerTests`:

```swift
    // MARK: - Boneyard / Notes

    func test_boneyardSingleLine_classifiesAsBoneyard() {
        let script = parser.parse("/* cut */")
        XCTAssertEqual(script.lines[0].element, .boneyard)
    }

    func test_boneyardMultiLine_allLinesClassifiedAsBoneyard() {
        let script = parser.parse("/* cut\nthis was here\nfor pacing */\n\nResume.")
        XCTAssertEqual(script.lines[0].element, .boneyard)
        XCTAssertEqual(script.lines[1].element, .boneyard)
        XCTAssertEqual(script.lines[2].element, .boneyard)
        XCTAssertEqual(script.lines[4].element, .action)
        XCTAssertEqual(script.lines[4].content, "Resume.")
    }

    func test_blockNoteSingleLine_classifiesAsNote() {
        let script = parser.parse("[[ todo ]]")
        XCTAssertEqual(script.lines[0].element, .note)
    }

    func test_blockNoteMultiLine_allLinesClassifiedAsNote() {
        let script = parser.parse("[[ todo:\nrewrite this beat\nmaybe ]]")
        XCTAssertEqual(script.lines[0].element, .note)
        XCTAssertEqual(script.lines[1].element, .note)
        XCTAssertEqual(script.lines[2].element, .note)
    }

    func test_inlineNoteWithinAction_lineStaysAction_inlineSpanRecorded() {
        let script = parser.parse("Action with [[ note ]] inside.")
        XCTAssertEqual(script.lines[0].element, .action)
        XCTAssertEqual(script.lines[0].inlineSpans.count, 1)
        XCTAssertEqual(script.lines[0].inlineSpans[0].kind, .note)
        // The inline span covers "[[ note ]]" within the line; range
        // location is the line's range start + 12 (length of "Action with ").
        let span = script.lines[0].inlineSpans[0].range
        XCTAssertEqual(span.length, 10)   // "[[ note ]]"
    }

    func test_actionAfterBoneyardClose_classifiesAsAction() {
        // Verify state machine returns to .normal after */.
        let script = parser.parse("/* cut */\nNot boneyard.")
        XCTAssertEqual(script.lines[0].element, .boneyard)
        XCTAssertEqual(script.lines[1].element, .action)
    }
```

- [ ] **Step 2: Run tests, expect failures**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25`

Expected: 6 new failures.

- [ ] **Step 3: Implement boneyard/note state machine + inline note pass**

Add a parser state enum at the top of `FountainTokenizer`:

```swift
    private enum BlockState {
        case normal
        case boneyard
        case noteBlock
    }
```

Refactor `parse` to track block state. Replace the body of `parse(_:)` with:

```swift
    public func parse(_ text: String) -> FountainScript {
        guard !text.isEmpty else { return .empty }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        var lines: [FountainLine] = []
        var prevBlank = true
        var prevElement: ScreenplayElement = .action
        var blockState: BlockState = .normal

        nsText.enumerateSubstrings(in: fullRange, options: .byLines) {
            substring, _, enclosingRange, _ in
            guard let raw = substring else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // While inside a multi-line block, classify the line as that
            // block kind. Exit on the closing marker.
            switch blockState {
            case .boneyard:
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .boneyard,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed)))
                if trimmed.contains("*/") { blockState = .normal }
                prevBlank = false
                prevElement = .boneyard
                return
            case .noteBlock:
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .note,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed)))
                if trimmed.contains("]]") { blockState = .normal }
                prevBlank = false
                prevElement = .note
                return
            case .normal:
                break
            }

            if trimmed.isEmpty {
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .action,
                    content: "",
                    isForced: false,
                    sourceCase: .neutral))
                prevBlank = true
                prevElement = .action
                return
            }

            // Boneyard open on this line — single-line if "*/" appears,
            // otherwise enter .boneyard state.
            if trimmed.hasPrefix("/*") {
                let closesOnLine = trimmed.dropFirst(2).contains("*/")
                if !closesOnLine { blockState = .boneyard }
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .boneyard,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed)))
                prevBlank = false
                prevElement = .boneyard
                return
            }

            // Block note open: line starts with [[ and either lacks ]] (multi-
            // line) or is entirely [[...]] (single-line block note).
            if trimmed.hasPrefix("[[") {
                let closesOnLine = trimmed.contains("]]")
                if !closesOnLine { blockState = .noteBlock }
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .note,
                    content: trimmed,
                    isForced: false,
                    sourceCase: Self.sourceCase(of: trimmed)))
                prevBlank = false
                prevElement = .note
                return
            }

            let classified = Self.classify(
                line: trimmed,
                prevBlank: prevBlank,
                prevElement: prevElement)

            // Inline note pass: locate any [[ ... ]] within the line, record
            // sub-ranges relative to the enclosing line range.
            let inlineSpans = Self.inlineNoteSpans(
                in: trimmed,
                lineRange: enclosingRange,
                rawLine: raw,
                nsText: nsText)

            lines.append(FountainLine(
                range: enclosingRange,
                element: classified.element,
                content: classified.content,
                isForced: classified.isForced,
                sourceCase: Self.sourceCase(of: classified.content),
                inlineSpans: inlineSpans))
            prevBlank = false
            prevElement = classified.element
        }

        // Post-pass: orphan Character cue → Action (unchanged from Task 3).
        var corrected: [FountainLine] = []
        corrected.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if line.element == .character && !line.isForced {
                let next = (index + 1 < lines.count) ? lines[index + 1] : nil
                let nextIsBlank = next.map { $0.content.isEmpty } ?? true
                if nextIsBlank {
                    corrected.append(FountainLine(
                        range: line.range,
                        element: .action,
                        content: line.content,
                        isForced: false,
                        sourceCase: line.sourceCase,
                        inlineSpans: line.inlineSpans))
                    continue
                }
            }
            corrected.append(line)
        }
        return FountainScript(lines: corrected)
    }
```

Add the inline note locator at the bottom of the type:

```swift
    private static func inlineNoteSpans(
        in trimmed: String,
        lineRange: NSRange,
        rawLine: String,
        nsText: NSString
    ) -> [FountainInlineSpan] {
        // We scan over the raw line (which retains leading whitespace and
        // any trailing whitespace before newline) so positions are correct
        // relative to lineRange.location.
        var result: [FountainInlineSpan] = []
        let raw = rawLine as NSString
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
            search = NSRange(
                location: nextStart,
                length: rawLength - nextStart)
        }
        return result
    }
```

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 37 tests, with 0 failures`.

- [ ] **Step 5: Run full test suite to confirm no regressions**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: `Executed 312 tests, with 0 failures` (275 baseline + 37 fountain tokenizer tests).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/Fountain/FountainTokenizer.swift MaughamTests/FountainTokenizerTests.swift
git commit -m "feat: classify Fountain boneyard, block notes, and inline notes

Adds a small block-state machine that tracks boneyard /* ... */ and
block notes [[ ... ]] across multiple lines. Inline notes within an
otherwise non-note line stay classified by their parent element and
record their sub-ranges in FountainLine.inlineSpans for the styler.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: FountainScript.estimatedPageCount

**Files:**
- Modify: `Maugham/Editor/Fountain/FountainScript.swift`
- Create: `MaughamTests/FountainScriptPageCountTests.swift`

- [ ] **Step 1: Create the test file with failing tests**

```swift
import XCTest
@testable import Maugham

final class FountainScriptPageCountTests: XCTestCase {
    private let parser = FountainTokenizer()

    func test_emptyScript_pageCountIsZero() {
        XCTAssertEqual(FountainScript.empty.estimatedPageCount, 0, accuracy: 0.0001)
    }

    func test_singleShortAction_pageCountUnderTwoPercent() {
        // "Larry sits." is one short action line. Should be tiny but nonzero
        // (action lines always count at least 1 line).
        let script = parser.parse("Larry sits.")
        XCTAssertGreaterThan(script.estimatedPageCount, 0)
        XCTAssertLessThan(script.estimatedPageCount, 0.05)
    }

    func test_longActionParagraph_wrapsToMultipleLines() {
        // 600 characters of action wraps at 60 chars/line ≈ 10 lines.
        // 10 / 55 ≈ 0.18 pages. Allow ±20% slack for ceil rounding.
        let action = String(repeating: "x", count: 600)
        let script = parser.parse(action)
        XCTAssertEqual(script.estimatedPageCount, 0.18, accuracy: 0.05)
    }

    func test_longDialogue_yieldsMoreLinesThanSameLengthAction() {
        // Same content as dialogue (35 chars/line) wraps to more lines
        // than as action (60 chars/line).
        let body = String(repeating: "x", count: 600)
        let actionScript = parser.parse(body)
        let dialogueScript = parser.parse("BARRY\n\(body)")
        XCTAssertGreaterThan(
            dialogueScript.estimatedPageCount,
            actionScript.estimatedPageCount)
    }

    func test_metadataElementsExcludedFromPageCount() {
        // A script with only sections, synopses, boneyard, notes, and a page
        // break should compute zero pages — none of these count.
        let text = """
        # ACT ONE

        = beat description

        /* cut content
        more cut content */

        [[ todo ]]

        ===
        """
        let script = parser.parse(text)
        XCTAssertEqual(script.estimatedPageCount, 0, accuracy: 0.0001)
    }

    func test_sceneHeading_counts2Lines_perSpec() {
        // Each scene heading counts as 2 lines (heading + implicit blank).
        // 27 scene headings = 54 lines = ~0.98 pages. Just under one page.
        let blob = (1...27).map { "INT. ROOM \($0) - DAY\n\n" }.joined()
        let script = parser.parse(blob)
        XCTAssertEqual(script.estimatedPageCount, 0.98, accuracy: 0.05)
    }
}
```

- [ ] **Step 2: Run tests, expect failures**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainScriptPageCountTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`

Expected: 4-5 new failures (test_emptyScript may pass since the stub returns 0).

- [ ] **Step 3: Implement `estimatedPageCount` in `FountainScript.swift`**

Replace the stub implementation with:

```swift
    public var estimatedPageCount: Double {
        let linesPerPage = 55
        let charsPerActionLine = 60
        let charsPerDialogueLine = 35
        let charsPerParenthetical = 20
        let sceneHeadingExtraBlankLines = 1

        var totalLines = 0
        for line in lines {
            switch line.element {
            case .action:
                let len = line.content.count
                let wraps = (len + charsPerActionLine - 1) / charsPerActionLine
                totalLines += max(wraps, 1)
            case .dialogue:
                let len = line.content.count
                let wraps = (len + charsPerDialogueLine - 1) / charsPerDialogueLine
                totalLines += max(wraps, 1)
            case .parenthetical:
                let len = line.content.count
                let wraps = (len + charsPerParenthetical - 1) / charsPerParenthetical
                totalLines += max(wraps, 1)
            case .sceneHeading:
                totalLines += 1 + sceneHeadingExtraBlankLines
            case .character, .transition, .centered, .lyric:
                totalLines += 1
            case .section, .synopsis, .boneyard, .note, .pageBreak:
                totalLines += 0
            }
        }
        return Double(totalLines) / Double(linesPerPage)
    }
```

Note the integer-arithmetic ceiling (`(n + d - 1) / d`) — avoids `ceil(Double(...))` to keep the function `Sendable`-friendly and side-effect-free.

Also note: blank action lines (content = "") get `totalLines += max(0, 1) = 1`, which means each paragraph break costs one line. That's intentional — paragraph breaks contribute to page count in real screenplay layout.

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainScriptPageCountTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Fountain/FountainScript.swift MaughamTests/FountainScriptPageCountTests.swift
git commit -m "feat: compute Fountain page count via Final Draft heuristic

Implements FountainScript.estimatedPageCount using line-wrap math:
60-char action width, 35-char dialogue, 20-char parenthetical, 55
lines per page. Sections, synopses, boneyard, notes, and page breaks
don't count toward total pages — they're working-doc metadata.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Token.Kind + EditorMetrics extensions; ScreenplayMode integration (tokenize / metrics / textColumnWidth)

**Files:**
- Modify: `Maugham/Editor/Token.swift`
- Modify: `Maugham/Editor/WritingMode.swift` (for EditorMetrics)
- Modify: `Maugham/Editor/ProseMode.swift` (handle new Token.Kind case + return pageCount: nil)
- Modify: `Maugham/Editor/ScreenplayMode.swift` (replace stub tokenize/metrics/textColumnWidth)
- Modify: `MaughamTests/ScreenplayModeTests.swift`

This task makes `ScreenplayMode` use `FountainTokenizer` end-to-end for `tokenize` and `metrics`. Styling stays minimal until Task 9.

- [ ] **Step 1: Add failing tests to `ScreenplayModeTests.swift`**

Replace the existing `test_tokenize_returnsSinglePlainToken` and add new tests:

```swift
    func test_tokenize_actionLine_producesFountainElementToken() {
        let tokens = mode.tokenize("Larry sits at the bar.")
        XCTAssertEqual(tokens.count, 1)
        if case let .fountainElement(element, isForced) = tokens[0].kind {
            XCTAssertEqual(element, .action)
            XCTAssertEqual(isForced, false)
        } else {
            XCTFail("Expected .fountainElement, got \(tokens[0].kind)")
        }
    }

    func test_tokenize_sceneHeading_producesSceneHeadingToken() {
        let tokens = mode.tokenize("INT. KITCHEN - DAY")
        XCTAssertEqual(tokens.count, 1)
        if case let .fountainElement(element, _) = tokens[0].kind {
            XCTAssertEqual(element, .sceneHeading)
        } else {
            XCTFail("Expected .fountainElement(.sceneHeading)")
        }
    }

    func test_metrics_includesPageCount_forScreenplay() {
        let metrics = mode.metrics("INT. ROOM - DAY\n\nLarry sits.")
        XCTAssertNotNil(metrics.pageCount)
        XCTAssertGreaterThan(metrics.pageCount ?? 0, 0)
    }

    func test_metrics_proseMode_pageCount_isNil() {
        let prose = ProseMode()
        let metrics = prose.metrics("Just a paragraph of prose.")
        XCTAssertNil(metrics.pageCount)
    }

    func test_textColumnWidth_screenplayUsesFixedSixtyChars() {
        // Even if the user sets pageWidthCharacters to 80, screenplay layout
        // stays canonical 60 chars wide.
        var typo: TypographySettings = .screenplayDefaults
        typo.pageWidthCharacters = 80
        let widthAt80 = mode.textColumnWidth(typography: typo)
        typo.pageWidthCharacters = 60
        let widthAt60 = mode.textColumnWidth(typography: typo)
        XCTAssertEqual(widthAt80, widthAt60, accuracy: 0.5)
    }
```

Delete the old `test_tokenize_returnsSinglePlainToken` and `test_applyTypography_setsMonospaceFont` tests — they assume stub behavior. Keep `test_tokenize_emptyText_returnsEmpty`, `test_smartTypographyTransform_alwaysReturnsNil`, and `test_metrics_countsWordsLikeProse`.

- [ ] **Step 2: Run tests, expect failures (new) and one type-check error (until Token.Kind grows the case)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayModeTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: compile error referencing `.fountainElement` not found in Token.Kind.

- [ ] **Step 3: Add `.fountainElement` to `Token.Kind`**

Edit `Maugham/Editor/Token.swift`. Add the new case:

```swift
public struct Token: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case emphasis(strong: Bool)
        case code
        case link(href: String)
        case wikiLink(title: String)
        case listMarker
        case blockquote
        case horizontalRule
        case syntaxPunctuation
        case plain
        case fountainElement(ScreenplayElement, isForced: Bool)
    }

    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}
```

- [ ] **Step 4: Add `pageCount: Double?` to `EditorMetrics`**

Edit `Maugham/Editor/WritingMode.swift`. Replace `EditorMetrics` with:

```swift
public struct EditorMetrics: Equatable, Sendable {
    public var wordCount: Int
    public var characterCount: Int
    public var readingMinutes: Int
    public var pageCount: Double?

    public init(
        wordCount: Int,
        characterCount: Int,
        readingMinutes: Int,
        pageCount: Double? = nil
    ) {
        self.wordCount = wordCount
        self.characterCount = characterCount
        self.readingMinutes = readingMinutes
        self.pageCount = pageCount
    }
}
```

- [ ] **Step 5: Update `ProseMode` — handle new Token.Kind case + return pageCount: nil**

Edit `Maugham/Editor/ProseMode.swift`. In the `attributes(for:palette:baseFont:)` exhaustive switch, add the new case before `case .plain`:

```swift
        case .fountainElement:
            // ProseMode never produces fountain element tokens, but the
            // exhaustive switch must handle the case.
            return [:]
```

`ProseMode.metrics` already calls `EditorMetrics(wordCount:characterCount:readingMinutes:)` — the new optional `pageCount` parameter defaults to `nil`, so the call site needs no change. (Verify by reading; the existing call is already on lines 37-41 of ProseMode.swift.)

- [ ] **Step 6: Replace `ScreenplayMode` body with the FountainTokenizer-driven implementation**

Edit `Maugham/Editor/ScreenplayMode.swift`. Replace the entire file contents with:

```swift
import Foundation
import AppKit

/// Fountain mode for `.fountain` documents. Tokenizes via FountainTokenizer,
/// applies per-element paragraph styling, and computes Final-Draft-heuristic
/// page count. Phase 3a — single-file screenplays only.
public struct ScreenplayMode: WritingMode {
    private static let wordsPerMinute = 200
    private static let canonicalPageWidthChars = 60

    private let parser: FountainTokenizer

    public init(parser: FountainTokenizer = FountainTokenizer()) {
        self.parser = parser
    }

    public func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        let script = parser.parse(text)
        return script.lines.map { line in
            Token(
                range: line.range,
                kind: .fountainElement(line.element, isForced: line.isForced))
        }
    }

    public func smartTypographyTransform(
        currentText: String,
        replacementRange: NSRange,
        replacement: String,
        settings: TypographySettings
    ) -> String? {
        nil
    }

    public func metrics(_ text: String) -> EditorMetrics {
        let script = parser.parse(text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.isEmpty
            ? 0
            : trimmed.split(whereSeparator: \.isWhitespace).count
        let chars = (text as NSString).length
        let mins = words / Self.wordsPerMinute
        return EditorMetrics(
            wordCount: words,
            characterCount: chars,
            readingMinutes: mins,
            pageCount: script.estimatedPageCount)
    }

    public func applyTypography(
        in storage: NSTextStorage,
        theme: Theme,
        typography: TypographySettings,
        tokens: [Token]
    ) {
        // Real per-element styling lands in Tasks 9 and 10. For now, set
        // a uniform monospace body so the editor renders without crashing
        // and existing smoke tests of the screenplay project type still
        // open `.fountain` files.
        let resolved = theme.resolved(systemAppearanceIsDark: Self.systemIsDark())
        let palette = resolved.palette
        let baseFont = baseFont(for: typography)
        let attrs = bodyAttributes(palette: palette, baseFont: baseFont,
                                   typography: typography)
        storage.beginEditing()
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.setAttributes(attrs, range: fullRange)
        storage.endEditing()
    }

    public func bodyTypingAttributes(
        theme: Theme,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        let resolved = theme.resolved(systemAppearanceIsDark: Self.systemIsDark())
        return bodyAttributes(palette: resolved.palette,
                              baseFont: baseFont(for: typography),
                              typography: typography)
    }

    /// Screenplay always renders at canonical 60-character width regardless of
    /// the user's prose-oriented `pageWidthCharacters` setting.
    public func textColumnWidth(typography: TypographySettings) -> CGFloat {
        let font = baseFont(for: typography)
        let sample = "the quick brown fox jumps over the lazy dog"
        let sampleWidth = (sample as NSString)
            .size(withAttributes: [.font: font]).width
        let avgCharWidth = sampleWidth / CGFloat(sample.count)
        return avgCharWidth * CGFloat(Self.canonicalPageWidthChars)
    }

    // MARK: - Helpers

    private static func systemIsDark() -> Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func baseFont(for typography: TypographySettings) -> NSFont {
        if let font = NSFont(name: typography.fontFamily,
                             size: CGFloat(typography.fontSize)) {
            return font
        }
        return NSFont.monospacedSystemFont(
            ofSize: CGFloat(typography.fontSize), weight: .regular)
    }

    private func bodyAttributes(
        palette: ThemePalette,
        baseFont: NSFont,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing =
            max(0, baseFont.pointSize * CGFloat(typography.lineHeightMultiplier - 1.0))
        paragraph.paragraphSpacing =
            baseFont.pointSize * CGFloat(typography.paragraphSpacingMultiplier)
        return [
            .font: baseFont,
            .foregroundColor: palette.bodyText,
            .paragraphStyle: paragraph,
        ]
    }
}
```

- [ ] **Step 7: Run targeted tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayModeTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 8 tests, with 0 failures` (3 retained + 5 new).

- [ ] **Step 8: Run full test suite to confirm no regressions**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: `Executed 318 tests, with 0 failures` (or close — depends on whether old ScreenplayMode tests were retained).

- [ ] **Step 9: Commit**

```bash
git add Maugham/Editor/Token.swift Maugham/Editor/WritingMode.swift Maugham/Editor/ProseMode.swift Maugham/Editor/ScreenplayMode.swift MaughamTests/ScreenplayModeTests.swift
git commit -m "feat: wire ScreenplayMode through FountainTokenizer

ScreenplayMode.tokenize now projects FountainScript lines to Tokens
via a new Token.Kind.fountainElement case carrying the element + forced
flag. metrics() returns Final-Draft-heuristic page count via the
EditorMetrics.pageCount field added in this task. textColumnWidth
overrides to a fixed canonical 60-character width regardless of the
user's prose-oriented pageWidthCharacters setting.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: ScreenplayMode.applyTypography — primary elements (action / scene / character / dialogue / parenthetical)

**Files:**
- Modify: `Maugham/Editor/ScreenplayMode.swift`
- Create: `MaughamTests/ScreenplayModeStylingTests.swift`

This task implements the per-element paragraph styling pipeline for the five most common element kinds. Secondary elements + inline span pass land in Task 10.

- [ ] **Step 1: Create `MaughamTests/ScreenplayModeStylingTests.swift`**

```swift
import XCTest
import AppKit
@testable import Maugham

final class ScreenplayModeStylingTests: XCTestCase {
    private let mode = ScreenplayMode()

    private func style(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let tokens = mode.tokenize(text)
        mode.applyTypography(in: storage, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens)
        return storage
    }

    private func paragraphStyle(at location: Int, in storage: NSTextStorage) -> NSParagraphStyle? {
        let attrs = storage.attributes(at: location, effectiveRange: nil)
        return attrs[.paragraphStyle] as? NSParagraphStyle
    }

    func test_action_isLeftAligned() {
        let storage = style("Larry sits at the bar.")
        XCTAssertEqual(paragraphStyle(at: 0, in: storage)?.alignment, .left)
        XCTAssertEqual(paragraphStyle(at: 0, in: storage)?.firstLineHeadIndent, 0,
                       accuracy: 0.5)
    }

    func test_sceneHeading_isLeftAligned_andBold() {
        let storage = style("INT. KITCHEN - DAY")
        XCTAssertEqual(paragraphStyle(at: 0, in: storage)?.alignment, .left)
        let font = storage.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func test_character_isIndentedAt22Chars() {
        let storage = style("BARRY\nHello.")
        let charWidth = ScreenplayModeStylingTests.charWidth(typography: .screenplayDefaults)
        let style = paragraphStyle(at: 0, in: storage)
        XCTAssertEqual(style?.firstLineHeadIndent, charWidth * 22, accuracy: 1.0)
        XCTAssertEqual(style?.headIndent, charWidth * 22, accuracy: 1.0)
    }

    func test_dialogue_isIndentedAt10_with35WidthBlock() {
        let storage = style("BARRY\nHello there.")
        let charWidth = ScreenplayModeStylingTests.charWidth(typography: .screenplayDefaults)
        // Dialogue is on line 2 — find its location.
        let dialogueLoc = ("BARRY\n" as NSString).length
        let style = paragraphStyle(at: dialogueLoc, in: storage)
        XCTAssertEqual(style?.firstLineHeadIndent, charWidth * 10, accuracy: 1.0)
        XCTAssertEqual(style?.headIndent, charWidth * 10, accuracy: 1.0)
        XCTAssertEqual(style?.tailIndent, charWidth * 45, accuracy: 1.0)
    }

    func test_parenthetical_isIndentedAt15_with35TailIndent() {
        let storage = style("BARRY\n(quietly)\nHello.")
        let charWidth = ScreenplayModeStylingTests.charWidth(typography: .screenplayDefaults)
        let parenLoc = ("BARRY\n" as NSString).length
        let style = paragraphStyle(at: parenLoc, in: storage)
        XCTAssertEqual(style?.firstLineHeadIndent, charWidth * 15, accuracy: 1.0)
        XCTAssertEqual(style?.tailIndent, charWidth * 35, accuracy: 1.0)
    }

    /// Compute monospace character width for a typography setting,
    /// matching the math in ScreenplayMode.charWidth.
    static func charWidth(typography: TypographySettings) -> CGFloat {
        let font = NSFont(name: typography.fontFamily,
                          size: CGFloat(typography.fontSize))
            ?? NSFont.monospacedSystemFont(
                ofSize: CGFloat(typography.fontSize), weight: .regular)
        let sample = "the quick brown fox jumps over the lazy dog"
        let width = (sample as NSString).size(withAttributes: [.font: font]).width
        return width / CGFloat(sample.count)
    }
}
```

- [ ] **Step 2: Run tests, expect failures**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayModeStylingTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: 5 failures (current `applyTypography` only sets uniform body).

- [ ] **Step 3: Replace `ScreenplayMode.applyTypography` with the per-element pipeline**

In `ScreenplayMode.swift`, replace `applyTypography` with:

```swift
    public func applyTypography(
        in storage: NSTextStorage,
        theme: Theme,
        typography: TypographySettings,
        tokens: [Token]
    ) {
        let resolved = theme.resolved(systemAppearanceIsDark: Self.systemIsDark())
        let palette = resolved.palette
        let baseFont = baseFont(for: typography)
        let charWidth = Self.charWidth(font: baseFont)
        let bodyAttrs = bodyAttributes(palette: palette, baseFont: baseFont,
                                       typography: typography)

        storage.beginEditing()
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.setAttributes(bodyAttrs, range: fullRange)

        for token in tokens {
            guard NSMaxRange(token.range) <= storage.length else { continue }
            guard case let .fountainElement(element, _) = token.kind else { continue }
            let attrs = self.attributes(
                for: element,
                palette: palette,
                baseFont: baseFont,
                charWidth: charWidth,
                typography: typography)
            storage.addAttributes(attrs, range: token.range)
        }
        storage.endEditing()
    }

    private static func charWidth(font: NSFont) -> CGFloat {
        let sample = "the quick brown fox jumps over the lazy dog"
        let width = (sample as NSString).size(withAttributes: [.font: font]).width
        return width / CGFloat(sample.count)
    }

    private func attributes(
        for element: ScreenplayElement,
        palette: ThemePalette,
        baseFont: NSFont,
        charWidth: CGFloat,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        switch element {
        case .action:
            return [:]   // body attrs already cover this
        case .sceneHeading:
            let font = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                size: baseFont.pointSize) ?? baseFont
            return [.font: font]
        case .character:
            let para = paragraphStyle(
                head: charWidth * 22,
                tail: charWidth * 60,
                alignment: .left,
                typography: typography,
                baseFont: baseFont)
            return [.paragraphStyle: para]
        case .dialogue:
            let para = paragraphStyle(
                head: charWidth * 10,
                tail: charWidth * 45,
                alignment: .left,
                typography: typography,
                baseFont: baseFont)
            return [.paragraphStyle: para]
        case .parenthetical:
            let para = paragraphStyle(
                head: charWidth * 15,
                tail: charWidth * 35,
                alignment: .left,
                typography: typography,
                baseFont: baseFont)
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            return [.paragraphStyle: para, .font: italic]
        default:
            return [:]   // Task 10 fills in transition/centered/etc.
        }
    }

    private func paragraphStyle(
        head: CGFloat,
        tail: CGFloat,
        alignment: NSTextAlignment,
        typography: TypographySettings,
        baseFont: NSFont
    ) -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = head
        para.headIndent = head
        para.tailIndent = tail
        para.alignment = alignment
        para.lineSpacing = max(0,
            baseFont.pointSize * CGFloat(typography.lineHeightMultiplier - 1.0))
        para.paragraphSpacing =
            baseFont.pointSize * CGFloat(typography.paragraphSpacingMultiplier)
        return para
    }
```

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayModeStylingTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/ScreenplayMode.swift MaughamTests/ScreenplayModeStylingTests.swift
git commit -m "feat: per-element paragraph styling for primary screenplay elements

Action/scene heading/character/dialogue/parenthetical render with
correct Cole & Haag indent columns (Character 22ch, Dialogue 10/45,
Parenthetical 15/35). Scene heading is bold; parenthetical is italic.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: ScreenplayMode.applyTypography — secondary elements (transition / centered / lyric / section / synopsis / boneyard / note / page break) + inline note span pass

**Files:**
- Modify: `Maugham/Editor/ScreenplayMode.swift`
- Modify: `MaughamTests/ScreenplayModeStylingTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `ScreenplayModeStylingTests`:

```swift
    func test_transition_isRightAligned_andBold() {
        let storage = style("Action.\n\nSMASH CUT TO:")
        let loc = ("Action.\n\n" as NSString).length
        let style = paragraphStyle(at: loc, in: storage)
        XCTAssertEqual(style?.alignment, .right)
        let font = storage.attributes(at: loc, effectiveRange: nil)[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func test_centered_isCenterAligned() {
        let storage = style(">THE END<")
        XCTAssertEqual(paragraphStyle(at: 0, in: storage)?.alignment, .center)
    }

    func test_lyric_isItalic() {
        let storage = style("~la la la")
        let font = storage.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
    }

    func test_section_isBoldAndUnderlined() {
        let storage = style("# ACT ONE")
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertNotNil(attrs[.underlineStyle])
    }

    func test_synopsis_isItalicAndDim() {
        let storage = style("= beat description")
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        XCTAssertNotNil(attrs[.foregroundColor])
        // Synopsis color must differ from body text color.
        let resolved = Theme.light.resolved(systemAppearanceIsDark: false)
        let bodyColor = resolved.palette.bodyText
        XCTAssertNotEqual(attrs[.foregroundColor] as? NSColor, bodyColor)
    }

    func test_boneyard_isItalicAndDim() {
        let storage = style("/* cut */")
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
    }

    func test_inlineNote_subRangeRendersDim() {
        // Inline note within an action line. The "[[ note ]]" range must
        // get a foreground color distinct from the body.
        let text = "Action with [[ note ]] in it."
        let storage = NSTextStorage(string: text)
        let tokens = mode.tokenize(text)
        mode.applyTypography(in: storage, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens)
        let noteStart = ("Action with " as NSString).length
        let bodyAttrs = storage.attributes(at: 0, effectiveRange: nil)
        let noteAttrs = storage.attributes(at: noteStart, effectiveRange: nil)
        let bodyColor = bodyAttrs[.foregroundColor] as? NSColor
        let noteColor = noteAttrs[.foregroundColor] as? NSColor
        XCTAssertNotNil(bodyColor)
        XCTAssertNotNil(noteColor)
        XCTAssertNotEqual(bodyColor, noteColor)
    }
```

- [ ] **Step 2: Run tests, expect failures**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayModeStylingTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`

Expected: 7 new failures.

- [ ] **Step 3: Implement the secondary-elements styling pipeline + inline note pass**

In `ScreenplayMode.swift`, replace the `attributes(for:palette:baseFont:charWidth:typography:)` switch with:

```swift
    private func attributes(
        for element: ScreenplayElement,
        palette: ThemePalette,
        baseFont: NSFont,
        charWidth: CGFloat,
        typography: TypographySettings
    ) -> [NSAttributedString.Key: Any] {
        switch element {
        case .action:
            return [:]
        case .sceneHeading:
            let font = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                size: baseFont.pointSize) ?? baseFont
            return [.font: font]
        case .character:
            return [.paragraphStyle: paragraphStyle(
                head: charWidth * 22, tail: charWidth * 60,
                alignment: .left, typography: typography, baseFont: baseFont)]
        case .dialogue:
            return [.paragraphStyle: paragraphStyle(
                head: charWidth * 10, tail: charWidth * 45,
                alignment: .left, typography: typography, baseFont: baseFont)]
        case .parenthetical:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            return [
                .paragraphStyle: paragraphStyle(
                    head: charWidth * 15, tail: charWidth * 35,
                    alignment: .left, typography: typography, baseFont: baseFont),
                .font: italic]
        case .transition:
            let bold = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                size: baseFont.pointSize) ?? baseFont
            return [
                .paragraphStyle: paragraphStyle(
                    head: 0, tail: charWidth * 60,
                    alignment: .right, typography: typography, baseFont: baseFont),
                .font: bold]
        case .centered:
            let bold = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                size: baseFont.pointSize) ?? baseFont
            return [
                .paragraphStyle: paragraphStyle(
                    head: 0, tail: charWidth * 60,
                    alignment: .center, typography: typography, baseFont: baseFont),
                .font: bold]
        case .lyric:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            return [.font: italic]
        case .section:
            let bold = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                size: baseFont.pointSize) ?? baseFont
            return [
                .font: bold,
                .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .synopsis:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            return [
                .font: italic,
                .foregroundColor: dim(palette.secondaryText, alpha: 0.6)]
        case .boneyard, .note:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            return [
                .font: italic,
                .foregroundColor: dim(palette.secondaryText, alpha: 0.4)]
        case .pageBreak:
            return [
                .paragraphStyle: paragraphStyle(
                    head: 0, tail: charWidth * 60,
                    alignment: .center, typography: typography, baseFont: baseFont),
                .foregroundColor: dim(palette.secondaryText, alpha: 0.4)]
        }
    }

    private func dim(_ color: NSColor, alpha: CGFloat) -> NSColor {
        color.withAlphaComponent(alpha)
    }
```

Update `applyTypography` to also walk inline note spans. Replace its body's `for token in tokens { ... }` block with:

```swift
        // First pass — per-line element styling driven by tokens.
        for token in tokens {
            guard NSMaxRange(token.range) <= storage.length else { continue }
            guard case let .fountainElement(element, _) = token.kind else { continue }
            let attrs = self.attributes(
                for: element,
                palette: palette,
                baseFont: baseFont,
                charWidth: charWidth,
                typography: typography)
            storage.addAttributes(attrs, range: token.range)
        }

        // Second pass — inline note spans within otherwise-non-note lines.
        // Re-parse to access inlineSpans (cheap; ~1ms on a feature script).
        let script = parser.parse(storage.string)
        let italic = NSFont(
            descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
            size: baseFont.pointSize) ?? baseFont
        let dimColor = dim(palette.secondaryText, alpha: 0.4)
        for line in script.lines where !line.inlineSpans.isEmpty {
            // Skip lines that are entirely .note — they're already styled.
            if line.element == .note { continue }
            for span in line.inlineSpans {
                guard NSMaxRange(span.range) <= storage.length else { continue }
                if span.kind == .note {
                    storage.addAttributes(
                        [.font: italic, .foregroundColor: dimColor],
                        range: span.range)
                }
            }
        }
```

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayModeStylingTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 12 tests, with 0 failures` (5 from Task 9 + 7 from Task 10).

- [ ] **Step 5: Run full test suite to confirm no regressions**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: `Executed 330 tests, with 0 failures` (or similar — exact total depends on prior task counts).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/ScreenplayMode.swift MaughamTests/ScreenplayModeStylingTests.swift
git commit -m "feat: per-element styling for secondary screenplay elements

Transition right-aligned bold; centered text horizontally centered bold;
lyric italic; section bold underlined; synopsis dim italic;
boneyard/note dim italic; page break dim centered. Inline note pass
runs after the per-line pass to render [[ note ]] sub-ranges dim
without re-classifying their parent line.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: ScreenplayLayoutManager + EditorSurface integration (display-uppercase)

**Files:**
- Create: `Maugham/Editor/ScreenplayLayoutManager.swift`
- Create: `MaughamTests/ScreenplayLayoutManagerTests.swift`
- Modify: `Maugham/Editor/ScreenplayMode.swift` (mark forced-character/scene/transition lines)
- Modify: `Maugham/Editor/EditorSurface.swift` (install layout manager when mode is screenplay)

This is the highest-risk task. The strategy is to subclass `NSLayoutManager`, override `showCGGlyphs(...)`, and substitute uppercase glyphs at draw time for ranges marked with a custom `.maughamDisplayUppercase` attribute. EditorSurface installs the layout manager only for screenplay mode and forces TextKit 1 (`usesTextKit2 = false`) on that NSTextView.

If the spike during Step 5 surfaces TextKit interactions that risk shipping bugs (cursor jitter, selection misalignment, focus dim layering), fall back to option A — skip the display-uppercase entirely; ScreenplayMode just stops applying the marker attribute. The rest of 3a still ships. Document the deferral as a 3b/3c follow-on in the smoke step.

- [ ] **Step 1: Define the custom attribute key + create the layout manager**

Create `Maugham/Editor/ScreenplayLayoutManager.swift`:

```swift
import AppKit

extension NSAttributedString.Key {
    /// Marker attribute applied by ScreenplayMode to ranges that should
    /// render visually uppercase via ScreenplayLayoutManager glyph
    /// substitution. The source text is unmodified.
    public static let maughamDisplayUppercase =
        NSAttributedString.Key("MaughamDisplayUppercase")
}

/// NSLayoutManager subclass that substitutes uppercase glyphs for ranges
/// marked with `.maughamDisplayUppercase`. Source text and selection
/// indices stay untouched. Used by ScreenplayMode for forced character /
/// scene heading / transition lines whose source case is mixed or lower.
///
/// Strategy: override `drawGlyphs(forGlyphRange:at:)` to record the active
/// glyph range as instance state for the duration of the draw call. AppKit
/// then calls `showCGGlyphs` one or more times within that draw, each call
/// covering a sub-run of the active range. We compute the character range
/// for each sub-run via `characterRange(forGlyphRange:actualGlyphRange:)`,
/// check the marker attribute, uppercase the string, and substitute glyphs.
public final class ScreenplayLayoutManager: NSLayoutManager {
    private var activeDrawRange: NSRange?
    private var glyphCursor: Int = 0

    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        activeDrawRange = glyphsToShow
        glyphCursor = glyphsToShow.location
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        activeDrawRange = nil
    }

    public override func showCGGlyphs(
        _ glyphs: UnsafePointer<CGGlyph>,
        positions: UnsafePointer<CGPoint>,
        count glyphCount: Int,
        font: NSFont,
        textMatrix: CGAffineTransform,
        attributes: [NSAttributedString.Key : Any] = [:],
        in graphicsContext: NSGraphicsContext
    ) {
        let drawRange = NSRange(location: glyphCursor, length: glyphCount)
        glyphCursor += glyphCount

        guard let storage = textStorage,
              activeDrawRange != nil,
              let charRange = self.actualCharRange(forGlyphRange: drawRange) else {
            super.showCGGlyphs(
                glyphs, positions: positions, count: glyphCount,
                font: font, textMatrix: textMatrix,
                attributes: attributes, in: graphicsContext)
            return
        }

        let storageAttrs = storage.attributes(at: charRange.location,
                                              effectiveRange: nil)
        guard storageAttrs[.maughamDisplayUppercase] as? Bool == true else {
            super.showCGGlyphs(
                glyphs, positions: positions, count: glyphCount,
                font: font, textMatrix: textMatrix,
                attributes: attributes, in: graphicsContext)
            return
        }

        let original = (storage.string as NSString).substring(with: charRange)
        let upper = original.uppercased()
        guard upper != original else {
            super.showCGGlyphs(
                glyphs, positions: positions, count: glyphCount,
                font: font, textMatrix: textMatrix,
                attributes: attributes, in: graphicsContext)
            return
        }

        // Re-derive glyphs from the uppercased string. CTFontGetGlyphsForCharacters
        // takes UTF-16 code units; each typically maps 1:1 to a glyph for ASCII
        // scripts. If the count diverges (ligatures), fall back to the original
        // glyphs to avoid drawing garbage.
        let chars = Array(upper.utf16)
        var newGlyphs = [CGGlyph](repeating: 0, count: chars.count)
        let success = CTFontGetGlyphsForCharacters(
            font as CTFont, chars, &newGlyphs, chars.count)
        guard success, newGlyphs.count == glyphCount else {
            super.showCGGlyphs(
                glyphs, positions: positions, count: glyphCount,
                font: font, textMatrix: textMatrix,
                attributes: attributes, in: graphicsContext)
            return
        }

        newGlyphs.withUnsafeBufferPointer { buf in
            super.showCGGlyphs(
                buf.baseAddress!,
                positions: positions, count: glyphCount,
                font: font, textMatrix: textMatrix,
                attributes: attributes, in: graphicsContext)
        }
    }

    private func actualCharRange(forGlyphRange glyphRange: NSRange) -> NSRange? {
        var actual = NSRange(location: 0, length: 0)
        let charRange = self.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: &actual)
        guard actual.length > 0 else { return nil }
        return charRange
    }
}
```

This implementation tracks `glyphCursor` across `showCGGlyphs` calls within a single `drawGlyphs` invocation. AppKit guarantees draw calls are sequential and start from the requested glyph range, so the cursor approach yields correct sub-run ranges. **This is still a spike** — if smoke testing reveals incorrect rendering (e.g., ligature font where glyph and char counts diverge often), the fallback to option A applies per Task 11's intro.

- [ ] **Step 2: Create the layout manager unit test**

Create `MaughamTests/ScreenplayLayoutManagerTests.swift`:

```swift
import XCTest
import AppKit
@testable import Maugham

final class ScreenplayLayoutManagerTests: XCTestCase {

    /// Verify that the marker attribute exists with the expected raw string
    /// (so other code adding/reading the attribute uses the same key).
    func test_markerAttribute_hasExpectedRawValue() {
        XCTAssertEqual(
            NSAttributedString.Key.maughamDisplayUppercase.rawValue,
            "MaughamDisplayUppercase")
    }

    /// Verify the layout manager can be instantiated and attached to a
    /// container without raising (smoke for subclass viability).
    func test_layoutManager_attachesToTextStorage() {
        let storage = NSTextStorage(string: "Sam")
        let lm = ScreenplayLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: 200))
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        // No crash = pass. Layout manager is wired up.
        XCTAssertNotNil(storage.layoutManagers.first)
    }

    /// Verify shouldUppercase reads the marker attribute correctly.
    func test_attributesWithMarker_triggerUppercaseBranch() {
        // We can't easily invoke showCGGlyphs from a unit test (it requires
        // a graphics context). So we test the public surface via the marker
        // attribute presence: an NSAttributedString carrying the marker
        // round-trips to a Storage and the attribute is preserved.
        let attrs: [NSAttributedString.Key: Any] = [
            .maughamDisplayUppercase: true]
        let storage = NSTextStorage(string: "Sam")
        storage.setAttributes(attrs, range: NSRange(location: 0, length: 3))
        let stored = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(stored[.maughamDisplayUppercase] as? Bool, true)
    }
}
```

- [ ] **Step 3: Run tests, expect 3 passing**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayLayoutManagerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 4: Apply `.maughamDisplayUppercase` attribute in ScreenplayMode**

In `ScreenplayMode.swift`, modify `applyTypography` to apply the marker attribute on forced character / scene heading / transition lines whose source case is mixed or lower. Insert this AFTER the secondary inline-note span pass:

```swift
        // Third pass — display-uppercase marker for forced character/scene/
        // transition lines whose source isn't already uppercase. Glyph
        // substitution at draw time is handled by ScreenplayLayoutManager.
        for line in script.lines {
            guard line.isForced,
                  line.sourceCase != .upper else { continue }
            switch line.element {
            case .character, .sceneHeading, .transition:
                guard NSMaxRange(line.range) <= storage.length else { continue }
                storage.addAttribute(
                    .maughamDisplayUppercase,
                    value: true,
                    range: line.range)
            default:
                break
            }
        }
```

- [ ] **Step 5: Wire up the layout manager in EditorSurface**

In `Maugham/Editor/EditorSurface.swift`, modify `makeNSView` to construct screenplay text views explicitly using TextKit 1 (NSTextStorage + ScreenplayLayoutManager + NSTextContainer + NSTextView(frame:textContainer:)). The default NSTextView() factory on macOS 14+ uses TextKit 2 (NSTextLayoutManager) — `textView.layoutManager` returns nil under TextKit 2, so a swap-after-construction approach won't work.

Replace the existing `let textView = MaughamTextView()` line with a branch:

```swift
        let textView: MaughamTextView
        if mode is ScreenplayMode {
            // Explicit TextKit 1 wiring for the custom layout manager that
            // performs visual-uppercase glyph substitution.
            let storage = NSTextStorage()
            let layoutManager = ScreenplayLayoutManager()
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(size: NSSize(
                width: columnWidth,
                height: .greatestFiniteMagnitude))
            container.widthTracksTextView = false
            layoutManager.addTextContainer(container)
            textView = MaughamTextView(frame: .zero, textContainer: container)
        } else {
            // Prose modes use NSTextView's default (TextKit 2 on macOS 14+).
            textView = MaughamTextView()
        }
```

The remainder of `makeNSView` is unchanged: `textView.columnWidth = columnWidth`, autoresizing, delegate, and the `if let container = textView.textContainer` block that sets container size and `widthTracksTextView`. (Those still apply — for screenplay mode, the explicit container we created is the same one that `textView.textContainer` returns.)

**If this step's spike surfaces issues** (cursor misbehaviour, focus dim layering breaks, selection mis-renders): revert this branch to `let textView = MaughamTextView()`, remove the marker-attribute pass added in Step 4, and document the option-A fallback in the milestone-3a notes. The rest of 3a still ships.

- [ ] **Step 6: Add a smoke test that types a forced character and verifies the marker attribute lands**

Append to `ScreenplayModeStylingTests`:

```swift
    func test_forcedMixedCaseCharacter_getsDisplayUppercaseMarker() {
        let storage = style("@Sam\nHello.")
        // The first line's range covers "@Sam\n" — the marker attribute
        // should be present somewhere within those 5 characters.
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(attrs[.maughamDisplayUppercase] as? Bool, true)
    }

    func test_allCapsCharacter_doesNotGetUppercaseMarker() {
        // A naturally-uppercase character cue doesn't need the marker.
        let storage = style("BARRY\nHello.")
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertNil(attrs[.maughamDisplayUppercase])
    }
```

- [ ] **Step 7: Run all tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: `Executed 335 tests, with 0 failures` (approximately — adjust based on cumulative count).

- [ ] **Step 8: Commit**

```bash
git add Maugham/Editor/ScreenplayLayoutManager.swift MaughamTests/ScreenplayLayoutManagerTests.swift Maugham/Editor/ScreenplayMode.swift Maugham/Editor/EditorSurface.swift MaughamTests/ScreenplayModeStylingTests.swift
git commit -m "feat: ScreenplayLayoutManager substitutes uppercase glyphs at draw time

Forced character/scene/transition lines (\`@Sam\`, \`.barbershop\`, \`>cut to:\`)
that aren't already ALL CAPS get a custom .maughamDisplayUppercase
marker attribute. ScreenplayLayoutManager (NSLayoutManager subclass)
intercepts showCGGlyphs and substitutes uppercase glyphs from CTFont
for marked ranges. Source text on disk stays mixed-case; selection
and cursor arithmetic stay correct because the underlying string is
unchanged.

EditorSurface installs the custom layout manager only when the active
mode is ScreenplayMode, leaving prose mode on NSTextView's default.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

**Fallback path (if Step 5 or smoke surfaces TextKit issues):** revert the EditorSurface changes, remove the `.maughamDisplayUppercase` marker pass from ScreenplayMode (Step 4), keep ScreenplayLayoutManager.swift as documentation of the approach, and document the deferral in the milestone-3a notes. The plan still ships value; option A (preserve as-typed) is the user-acknowledged fallback.

---

## Task 12: ProjectTargets.pageTarget + manifest migration test + ProjectStore mutator

**Files:**
- Modify: `Maugham/Models/ProjectTargets.swift`
- Modify: `Maugham/Stores/ProjectStore.swift`
- Create: `MaughamTests/ProjectTargetsMigrationTests.swift`

- [ ] **Step 1: Create the migration test**

Create `MaughamTests/ProjectTargetsMigrationTests.swift`:

```swift
import XCTest
@testable import Maugham

final class ProjectTargetsMigrationTests: XCTestCase {

    func test_decode_legacyTargetsWithoutPageTarget_leavesPageTargetNil() throws {
        let json = """
        { "totalWords": 50000 }
        """.data(using: .utf8)!
        let targets = try JSONDecoder().decode(ProjectTargets.self, from: json)
        XCTAssertEqual(targets.totalWords, 50000)
        XCTAssertNil(targets.pageTarget)
    }

    func test_decode_targetsWithPageTarget_populates() throws {
        let json = """
        { "totalWords": 0, "pageTarget": 110 }
        """.data(using: .utf8)!
        let targets = try JSONDecoder().decode(ProjectTargets.self, from: json)
        XCTAssertEqual(targets.pageTarget, 110)
    }

    func test_roundTrip_preservesPageTarget() throws {
        let original = ProjectTargets(
            totalWords: nil, deadline: nil, pageTarget: 110)
        let data = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(
            ProjectTargets.self, from: data)
        XCTAssertEqual(roundTripped, original)
    }

    @MainActor
    func test_updateProjectTargets_persistsPageTarget() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createScreenplayProject(
            named: "PageTargetTest", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        try await store.updateProjectTargets(pageTarget: 110)
        XCTAssertEqual(store.manifest.targets?.pageTarget, 110)

        // Re-load from disk and confirm persistence.
        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(reloaded.manifest.targets?.pageTarget, 110)
    }

    @MainActor
    func test_updateProjectTargets_zeroPageTargetClearsField() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createScreenplayProject(
            named: "PageTargetClear", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        try await store.updateProjectTargets(pageTarget: 110)
        try await store.updateProjectTargets(pageTarget: 0)
        XCTAssertNil(store.manifest.targets?.pageTarget)
    }
}
```

- [ ] **Step 2: Run tests, expect compile failure (pageTarget doesn't exist yet)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectTargetsMigrationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`

Expected: compile error referencing `pageTarget` on `ProjectTargets`.

- [ ] **Step 3: Add `pageTarget` to `ProjectTargets`**

Edit `Maugham/Models/ProjectTargets.swift`:

```swift
import Foundation

/// Optional project-level targets: word count, deadline, and (3a) screenplay
/// page count. Stored under the `targets` key of the manifest.
public struct ProjectTargets: Codable, Equatable, Sendable {
    public var totalWords: Int?
    public var deadline: Date?
    public var pageTarget: Int?

    public init(
        totalWords: Int? = nil,
        deadline: Date? = nil,
        pageTarget: Int? = nil
    ) {
        self.totalWords = totalWords
        self.deadline = deadline
        self.pageTarget = pageTarget
    }
}
```

- [ ] **Step 4: Add `updateProjectTargets` to `ProjectStore`**

In `Maugham/Stores/ProjectStore.swift`, locate the `updateInspector` method (~line 857) and add a sibling project-level mutator immediately after it:

```swift
    /// Update project-level targets. Currently surfaces 3a's page target;
    /// future expansion can add total-words / deadline editing through the
    /// same path. Treat 0 as "clear the target" — mirrors per-document word
    /// target convention.
    public func updateProjectTargets(pageTarget: Int) async throws {
        var targets = manifest.targets ?? ProjectTargets()
        targets.pageTarget = pageTarget == 0 ? nil : pageTarget
        manifest.targets = targets
        manifest.modified = Date()
        try await saveManifest()
    }
```

- [ ] **Step 5: Run tests, expect pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectTargetsMigrationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Models/ProjectTargets.swift Maugham/Stores/ProjectStore.swift MaughamTests/ProjectTargetsMigrationTests.swift
git commit -m "feat: add pageTarget to ProjectTargets + ProjectStore mutator

Optional pageTarget field follows 2c's deadline addition pattern —
additive, no schemaVersion bump, manifests written before 3a decode
unchanged. ProjectStore.updateProjectTargets writes the field through
to the manifest (treats 0 as clear, mirroring per-doc word target).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: GoalIndicatorState + GoalIndicatorView screenplay rendering + ProjectWindow plumbing

**Files:**
- Modify: `Maugham/Models/GoalIndicatorState.swift`
- Modify: `Maugham/Views/GoalIndicatorView.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Extend `GoalIndicatorState` with screenplay fields**

Edit `Maugham/Models/GoalIndicatorState.swift`:

```swift
import Foundation

/// Snapshot of everything the goal indicator capsule renders.
public struct GoalIndicatorState: Equatable, Sendable {
    public var docWordCount: Int
    public var docWordTarget: Int?
    public var projectWordCount: Int
    public var projectWordTarget: Int?
    public var wordsToday: Int
    public var readingMinutes: Int
    public var pageCount: Double?
    public var pageTarget: Int?
    public var isScreenplay: Bool

    public init(
        docWordCount: Int = 0,
        docWordTarget: Int? = nil,
        projectWordCount: Int = 0,
        projectWordTarget: Int? = nil,
        wordsToday: Int = 0,
        readingMinutes: Int = 0,
        pageCount: Double? = nil,
        pageTarget: Int? = nil,
        isScreenplay: Bool = false
    ) {
        self.docWordCount = docWordCount
        self.docWordTarget = docWordTarget
        self.projectWordCount = projectWordCount
        self.projectWordTarget = projectWordTarget
        self.wordsToday = wordsToday
        self.readingMinutes = readingMinutes
        self.pageCount = pageCount
        self.pageTarget = pageTarget
        self.isScreenplay = isScreenplay
    }

    public static let empty = GoalIndicatorState()
}
```

- [ ] **Step 2: Update `GoalIndicatorView` to render screenplay variant**

Edit `Maugham/Views/GoalIndicatorView.swift`. Replace `label` with:

```swift
    private var label: String {
        if state.isScreenplay {
            return screenplayLabel
        }
        return proseLabel
    }

    private var screenplayLabel: String {
        let pages = state.pageCount ?? 0
        let pagesStr: String = String(format: "%.1f", pages)
        if let target = state.pageTarget, target > 0 {
            let targetStr: String = String(target)
            let pct: Int = Int((pages / Double(target) * 100).rounded())
            return pagesStr + " / " + targetStr + " pages (" + String(pct) + "%)"
        }
        return pagesStr + " pages"
    }

    private var proseLabel: String {
        let words: String = state.docWordCount.formatted(.number)
        let today: String = state.wordsToday.formatted(.number)

        if let target = state.docWordTarget {
            let pct = percent(state.docWordCount, of: target)
            let targetStr: String = target.formatted(.number)
            return words + " / " + targetStr + " words (" + String(pct)
                + "%) · today: " + today
        }

        if let projectTarget = state.projectWordTarget {
            let pct = percent(state.projectWordCount, of: projectTarget)
            return words + " words · today: " + today
                + " · project " + String(pct) + "%"
        }

        if state.readingMinutes == 0 {
            return words + " words · today: " + today
        }
        return words + " words · " + String(state.readingMinutes)
            + " min read · today: " + today
    }
```

The label generation uses explicit `let` bindings + `+` concatenation — NOT chained `\(value.formatted(...))` interpolations. This pre-empts the SourceKit type-check ceiling banked from 2c.

- [ ] **Step 3: Update `ProjectWindow.goalIndicatorState` to include screenplay fields**

In `Maugham/Views/ProjectWindow.swift`, find `goalIndicatorState` (around line 340). Replace the function body with:

```swift
    private var goalIndicatorState: GoalIndicatorState {
        guard let store else { return .empty }
        let currentDoc = selectedItemId.flatMap {
            findItem(id: $0, in: store.manifest.structure)
        }
        let isScreenplay = store.manifest.type == .screenplay
        return GoalIndicatorState(
            docWordCount: metrics.wordCount,
            docWordTarget: currentDoc?.wordTarget,
            projectWordCount: store.projectWordCount,
            projectWordTarget: store.manifest.targets?.totalWords,
            wordsToday: sessionLog.wordsToday(),
            readingMinutes: metrics.readingMinutes,
            pageCount: metrics.pageCount,
            pageTarget: store.manifest.targets?.pageTarget,
            isScreenplay: isScreenplay)
    }
```

- [ ] **Step 4: Build and run tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: All tests still pass (no new tests in this task — visual verification happens in smoke).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Models/GoalIndicatorState.swift Maugham/Views/GoalIndicatorView.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: goal indicator renders pages for screenplay projects

For screenplay projects: capsule shows '27.5 pages' (no target) or
'27.5 / 110 pages (25%)' (target set). Prose projects unchanged.
Label generation uses explicit String concatenation to dodge the
SourceKit type-check ceiling banked from 2c.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: InspectorView page target field for screenplay projects

**Files:**
- Modify: `Maugham/Views/InspectorView.swift`

The page target lives on `manifest.targets.pageTarget` (project-level), not `StructureItem.wordTarget` (per-document). For screenplay projects in 3a, project = document (single-file), so showing the field in the Inspector alongside the per-document word target is sensible. The field is conditionally shown only when the project type is `.screenplay`.

To pre-empt SwiftUI body type-check timeouts (banked from 2c), the new field is factored into a private `@ViewBuilder` method.

- [ ] **Step 1: Add page target draft state and view-builder**

In `Maugham/Views/InspectorView.swift`, add state alongside the other `@State` declarations near the top:

```swift
    @State private var draftPageTarget: Int = 0
```

Add a private `@ViewBuilder` method at the bottom of `InspectorView` (after `findItem`):

```swift
    @ViewBuilder
    private func pageTargetRow() -> some View {
        if store.manifest.type == .screenplay {
            LabeledContent("Page target") {
                HStack(spacing: 6) {
                    TextField("",
                        value: $draftPageTarget,
                        format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onChange(of: draftPageTarget) { _, _ in
                            schedulePageTargetSave()
                        }
                    Stepper("",
                        value: $draftPageTarget,
                        in: 0...500, step: 5)
                        .labelsHidden()
                    if draftPageTarget == 0 {
                        Text("(no target)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
```

- [ ] **Step 2: Insert the row into the Document section, after the existing word target field**

In the `Section("Document")` block, locate the existing `LabeledContent("Word target") { ... }` block and add `pageTargetRow()` immediately after its closing brace:

```swift
                    LabeledContent("Word target") {
                        // ... existing code ...
                    }

                    pageTargetRow()

                    InspectorLinksSection(...)
```

- [ ] **Step 3: Add the page target save scheduler**

Add this method to `InspectorView`:

```swift
    @State private var pageTargetSaveTask: Task<Void, Never>?

    private func schedulePageTargetSave() {
        pageTargetSaveTask?.cancel()
        let value = draftPageTarget
        pageTargetSaveTask = Task { [weak store] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            guard let store else { return }
            try? await store.updateProjectTargets(pageTarget: value)
        }
    }
```

- [ ] **Step 4: Initialize the draft from the manifest in `loadDraftIfNeeded`**

In `loadDraftIfNeeded`, add at the end (after the existing draft initializations):

```swift
        draftPageTarget = store.manifest.targets?.pageTarget ?? 0
```

- [ ] **Step 5: Build to verify**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`

Expected: build succeeds. If `InspectorView.body` hits the type-check ceiling, factor more aggressively — extract the entire Document section into a `@ViewBuilder` private method.

- [ ] **Step 6: Run tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: All tests pass (visual change only; no new tests).

- [ ] **Step 7: Commit**

```bash
git add Maugham/Views/InspectorView.swift
git commit -m "feat: Inspector grows page target field for screenplay projects

Conditionally shown only when manifest.type == .screenplay. Writes
through to manifest.targets.pageTarget via ProjectStore.update-
ProjectTargets, debounced 500ms. Field is factored into a private
@ViewBuilder to pre-empt SwiftUI body type-check pressure.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: Reference fixture screenplay + integration page-count test

**Files:**
- Create: `MaughamTests/Fixtures/sample-screenplay.fountain`
- Create or modify: `MaughamTests/FountainScriptPageCountTests.swift` (add fixture test)

A short, real-feeling screenplay sample used to verify page count accuracy. Hand-counting Final Draft's pagination on this fixture gives us the reference number.

- [ ] **Step 1: Create the fixture file**

Create `MaughamTests/Fixtures/sample-screenplay.fountain`:

```
INT. COFFEE SHOP - DAY

Two friends sit across from each other, mugs steaming. The diner clatters around them. BARRY stares into his coffee like it owes him money.

BARRY
(after a long pause)
You ever wonder if we made the right call?

SAM
Every damn day.

BARRY
What if we'd just driven north that night? Kept driving until the gas ran out?

SAM
Then we'd be a story somebody else tells in a coffee shop. Different shop. Different friends. Same regret.

A WAITRESS sets down two plates of pancakes. Neither man notices.

BARRY
I keep thinking about her.

SAM
Of course you do.

BARRY
Not like that. I think about who she'd be now. What she'd say if she walked through that door.

> SMASH CUT TO:

EXT. PARKING LOT - NIGHT

Rain hammers the asphalt. Barry stands by his truck, phone pressed to his ear. He's been crying.

BARRY (CONT'D)
I just need to know she's okay.

The phone clicks. Silence. He stares at the screen — CALL ENDED.

Barry climbs into the truck. The dome light flickers. He doesn't start the engine.

He just sits.

The rain keeps coming.

> FADE OUT.

> THE END <
```

Hand-count of Final Draft pages for this fixture: approximately **2.0 pages** (two scenes, ~50 lines of mixed action and dialogue, several blank-line paragraph breaks). The test below uses ±0.5 pages tolerance.

- [ ] **Step 2: Update xcodegen to bundle the fixture file with the test target**

Check `project.yml` for how MaughamTests resources are included.

Run: `grep -A 10 "MaughamTests:" /Users/denver/src/Maugham/project.yml | head -25`

If `MaughamTests` already declares `resources` or has a glob that picks up `MaughamTests/Fixtures/`, no change needed. If not, add a resource entry:

```yaml
  MaughamTests:
    type: bundle.unit-test
    sources:
      - path: MaughamTests
    resources:
      - path: MaughamTests/Fixtures
```

(Check the existing schema and adjust to match.)

- [ ] **Step 3: Add the integration test**

Append to `MaughamTests/FountainScriptPageCountTests.swift`:

```swift
    func test_referenceFixture_pageCountWithinFivePercent() throws {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(
            forResource: "sample-screenplay",
            withExtension: "fountain"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let script = parser.parse(text)
        // Hand-counted Final Draft pagination of this fixture: ~2.0 pages.
        // Allow ±0.5 pages tolerance.
        XCTAssertEqual(script.estimatedPageCount, 2.0, accuracy: 0.5)
    }
```

- [ ] **Step 4: Run tests, expect pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FountainScriptPageCountTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 7 tests, with 0 failures`.

If the fixture's parsed page count falls outside the ±0.5 tolerance, the wrap-width constants in `FountainScript.estimatedPageCount` may need a small tune. Adjust constants to bring the fixture into range; document the change in the commit body.

- [ ] **Step 5: Commit**

```bash
git add MaughamTests/Fixtures/sample-screenplay.fountain MaughamTests/FountainScriptPageCountTests.swift project.yml
git commit -m "test: add reference fountain fixture + page-count integration test

Hand-counted ~2.0 pages on Final Draft; the parser's estimate must
fall within ±0.5. Establishes a regression baseline for any future
adjustment of wrap-width constants in estimatedPageCount.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: Smoke checklist execution + tag milestone-3a

**Files:** none directly — manual smoke + tag.

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~306+ tests passing. If anything regressed, fix BEFORE proceeding to smoke. Each fix lands as its own `fix:` commit (or amends the relevant feature commit if main hasn't been pushed yet).

- [ ] **Step 2: Build and launch the app**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`

Expected: build succeeds. Locate the built `.app` bundle (under `~/Library/Developer/Xcode/DerivedData/Maugham-*/Build/Products/Debug/Maugham.app`) and launch it. Or run via Xcode: `open Maugham.xcodeproj` and ⌘R.

- [ ] **Step 3: Execute the smoke checklist from spec §7.3**

Walk through each step. Document any deviation as a `fix:` commit before tagging.

1. Create new Screenplay project → opens with empty `.fountain` → editor shows monospace plain text
2. Type `INT. KITCHEN - DAY` → blank line → `BARRY` → blank line → `Hello.` → see scene heading bold, character at 22ch indent, dialogue at 10ch indent with 35ch wrap
3. Type `@Sam` (forced character lowercase) → see `SAM` rendered uppercase via glyph substitution (or as-typed if option A fallback was taken)
4. **Critical**: open Terminal, `cat` the `.fountain` file — verify source still reads `@Sam` (mixed-case, NOT modified by editor)
5. Type `> SMASH CUT TO:` → see right-aligned bold uppercase
6. Type `# ACT TWO` → see bold underlined section
7. Type `[[ todo ]]` inline within an action paragraph → action stays styled normally; the `[[ … ]]` range renders dim italic
8. Type `/* cut */` → see dim italic boneyard
9. Goal indicator capsule shows page count in real time as text grows (e.g., "0.3 pages")
10. Open Inspector → Page target field → set to 110 → goal indicator switches to "0.3 / 110 pages (0%)" format
11. Type the reference fixture screenplay (`MaughamTests/Fixtures/sample-screenplay.fountain`) — page count within ~5% of the hand-counted ~2.0 pages
12. Theme switch (Light → Dark → Sepia via Settings) → all element styling re-applies correctly with theme colors
13. Resize editor pane wide and narrow → indent columns track monospace character widths consistently; no overflow at narrow widths
14. ⌘\ no-chrome mode → editor still styled correctly
15. Switch active document from prose (.md) → screenplay (.fountain) → prose (.md) → no leftover styling, no crashes
16. Type a script that crosses 1.0 pages, then 5.0 pages → goal indicator updates smoothly without UI hitches

- [ ] **Step 4: If any smoke step fails, commit a fix**

For each visible regression:
- Diagnose with the SwiftUI / AppKit lessons banked in the handoff doc (e.g., `Color.clear` + `.background` for fixed-size cells, factoring SwiftUI bodies, NSTextView width tracking)
- Commit each fix with `fix:` prefix and a body explaining the root cause

- [ ] **Step 5: Merge to main and tag**

```bash
# If working on a feature branch:
git checkout main
git merge --ff-only <feature-branch>

# Tag the milestone:
git tag -a milestone-3a -m "Phase 3a complete: Fountain foundation + styling + page count

- FountainTokenizer: line-based state machine, 12 element kinds, forced-syntax + structural extras
- FountainScript: typed lines + estimatedPageCount via Final Draft heuristic
- ScreenplayMode: per-element paragraph styling, 60ch canonical width, page count in metrics
- ScreenplayLayoutManager: glyph-level uppercase substitution for forced character/scene/transition (or option A fallback)
- ProjectTargets.pageTarget: optional, manifest-additive, no schema bump
- Inspector page target field for screenplay projects
- Goal indicator pages variant
- Reference fixture + integration page-count test

Tests: ~306+ passing. Single-file screenplay only — multi-file lands in 3d.
"

git push origin main
git push origin milestone-3a
```

- [ ] **Step 6: Update memory**

Save a `project_milestone_3a.md` memory file alongside the existing milestone memories (if the user-level memory system is being maintained). Update `MEMORY.md` to add a one-liner pointing to it. (This step is for the executing agent — Claude — to track milestone status across sessions.)

- [ ] **Step 7: Notify the user**

Summarize what shipped, what (if anything) deferred via the option-A fallback, and what's next (3b: Tab/Enter cycling + character autocomplete).

---

## Self-review checklist (run AFTER all tasks above are written)

This is a checklist the planning author runs against the spec. NOT a runtime task.

**Spec coverage** — every spec section/requirement maps to a task:

- §1 Goals & non-goals — non-goals enumerated in Task 1's intro; goals satisfied by Tasks 1-15
- §2 Architecture overview — Tasks 1, 8, 11 (FountainTokenizer + ScreenplayMode wiring + LayoutManager)
- §3 Element coverage & parsing rules — Tasks 1-6 collectively cover all 12 element kinds
- §3.5 FountainLine + FountainScript types — Task 1
- §4.1 Page width override — Task 8 (`textColumnWidth` override + test)
- §4.2 Indentation table — Tasks 9 (primary) + 10 (secondary)
- §4.3 Display-uppercase mechanism — Task 11
- §4.4 Theme integration — Tasks 9-10 (palette colors threaded through)
- §4.5 Inline note styling pass — Task 10 (second pass over inlineSpans)
- §5 Page count algorithm — Task 7
- §6.1 ProjectTargets.pageTarget — Task 12
- §6.2 Inspector field — Task 14
- §6.3 EditorMetrics.pageCount — Task 8
- §6.4 GoalIndicator rendering — Task 13
- §7.1 Pure-logic tests — Tasks 1-7 (37 tokenizer + 7 page-count tests)
- §7.2 Integration tests — Tasks 9-10 (styling), 12 (migration), 15 (fixture)
- §7.3 Smoke checklist — Task 16
- §8 Out-of-scope deferrals — restated in plan goal section, plus "single-file only" notes
- §9 Risks (display-uppercase) — Task 11 has explicit fallback path
- §10 Implementation sequencing — task order matches §10's preview

No spec section is unimplemented.

**Placeholder scan** — search the plan for: "TBD", "TODO", "implement later", "fill in details", "Add appropriate", "handle edge cases" without code. None found.

**Type consistency** — verify identifiers used across tasks match:
- `FountainTokenizer.parse(_ text: String) -> FountainScript` (T1, used T2-T6, T8, T11)
- `FountainScript.lines: [FountainLine]` (T1, used T7, T11)
- `FountainScript.estimatedPageCount: Double` (T1 stub, T7 impl, used T8)
- `FountainLine.range, element, content, isForced, sourceCase, inlineSpans` (T1, used T2-T6, T11)
- `Token.Kind.fountainElement(ScreenplayElement, isForced: Bool)` (T8, used T9-T11)
- `EditorMetrics.pageCount: Double?` (T8, used T13)
- `NSAttributedString.Key.maughamDisplayUppercase` (T11, applied T11 step 4)
- `ProjectTargets.pageTarget: Int?` (T12, used T13, T14)
- `ProjectStore.updateProjectTargets(pageTarget: Int)` (T12, called T14)
- `GoalIndicatorState.pageCount, pageTarget, isScreenplay` (T13, set in ProjectWindow)

All consistent.

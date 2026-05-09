# Phase 3b Implementation Plan — Editing UX (Tab/Enter cycling + character autocomplete + element gutter)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the screenwriting input experience: Tab/Shift+Tab cycle the current line through Highland-order screenplay elements with context-aware source mutation; character autocomplete via NSPopover sourced from `FountainScript.characterNames`; element gutter showing per-line classification as feedback.

**Architecture:** Pure logic (`ScreenplayCycle`, `ScreenplayLineMutator`) for the cycle and source-mutation rules. `EditorCoordinator` gains a `doCommandBy:` interceptor for `insertTab:` / `insertBacktab:` (and autocomplete navigation when the popover is visible) and a `lastParsedScript` cache that's the single source for both the autocompleter and gutter. `CharacterAutocompleter` owns an `NSPopover` + `NSTableView` lifecycle. `ElementGutterView` is an `NSView` subview of `MaughamTextView` drawn in the left text-container inset.

**Tech Stack:** Swift, AppKit (NSTextView, NSPopover, NSTableView, NSView with custom draw), SwiftUI for the Project Settings toggle, XCTest. Built via `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`.

**Spec:** `docs/superpowers/specs/2026-05-09-maugham-phase-3b-editing-ux-design.md`. Read it before starting any task.

**Test baseline before this plan:** 342 passing on `main` (post milestone-3a). Target after milestone-3b: ~390 passing.

**Conventions:**
- Each task = one commit. Use `feat:` / `fix:` / `docs:` prefixes per project commit discipline.
- TDD: failing test first → verify failure → implement minimal code → verify pass → commit.
- Build commands assume CWD = `/Users/denver/src/Maugham`.
- New files in `Maugham/` and `MaughamTests/` are picked up automatically by xcodegen globs — running `./gen.sh` after creating new files is required before `xcodebuild`.
- `Maugham.xcodeproj` is gitignored — do NOT commit it. xcodegen regenerates from `project.yml`.
- **LSP diagnostics ("Cannot find type X") on edited Swift files are stale due to xcodegen regenerating the project. Trust xcodebuild's TEST/BUILD SUCCEEDED output, not LSP diagnostics.**
- Model selection (per banked feedback): pure-logic types = sonnet, mechanical SwiftUI = haiku, NSPopover/NSTableView/NSView lifecycle work = opus.

---

## Task 1: ScreenplayCycle — pure-logic cycle/starting-point helpers

**Files:**
- Create: `Maugham/Editor/Fountain/ScreenplayCycle.swift`
- Create: `MaughamTests/ScreenplayCycleTests.swift`

Pure logic. No AppKit. The cycle's behavior is fully testable without any UI.

- [ ] **Step 1: Create the test file with failing tests**

```swift
import XCTest
@testable import Maugham

final class ScreenplayCycleTests: XCTestCase {

    // MARK: - cycleForward

    func test_cycleForward_action_returnsCharacter() {
        XCTAssertEqual(ScreenplayCycle.cycleForward(from: .action), .character)
    }

    func test_cycleForward_character_returnsDialogue() {
        XCTAssertEqual(ScreenplayCycle.cycleForward(from: .character), .dialogue)
    }

    func test_cycleForward_dialogue_returnsParenthetical() {
        XCTAssertEqual(ScreenplayCycle.cycleForward(from: .dialogue), .parenthetical)
    }

    func test_cycleForward_parenthetical_returnsTransition() {
        XCTAssertEqual(ScreenplayCycle.cycleForward(from: .parenthetical), .transition)
    }

    func test_cycleForward_transition_wrapsToAction() {
        XCTAssertEqual(ScreenplayCycle.cycleForward(from: .transition), .action)
    }

    // MARK: - cycleBackward

    func test_cycleBackward_action_wrapsToTransition() {
        XCTAssertEqual(ScreenplayCycle.cycleBackward(from: .action), .transition)
    }

    func test_cycleBackward_character_returnsAction() {
        XCTAssertEqual(ScreenplayCycle.cycleBackward(from: .character), .action)
    }

    func test_cycleBackward_dialogue_returnsCharacter() {
        XCTAssertEqual(ScreenplayCycle.cycleBackward(from: .dialogue), .character)
    }

    // MARK: - startingElement(after:)

    func test_startingElement_afterAction_isCharacter() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .action), .character)
    }

    func test_startingElement_afterCharacter_isDialogue() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .character), .dialogue)
    }

    func test_startingElement_afterParenthetical_isDialogue() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .parenthetical), .dialogue)
    }

    func test_startingElement_afterDialogue_isParenthetical() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .dialogue), .parenthetical)
    }

    func test_startingElement_afterTransition_isSceneHeading() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .transition), .sceneHeading)
    }

    func test_startingElement_afterSceneHeading_isAction() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .sceneHeading), .action)
    }

    func test_startingElement_afterCentered_isAction() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .centered), .action)
    }

    func test_startingElement_afterSection_isAction() {
        XCTAssertEqual(ScreenplayCycle.startingElement(after: .section(level: 1)), .action)
    }
}
```

- [ ] **Step 2: Run tests, expect compile error (ScreenplayCycle doesn't exist yet)**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayCycleTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`

Expected: compile error referencing `ScreenplayCycle`.

- [ ] **Step 3: Implement ScreenplayCycle**

Create `Maugham/Editor/Fountain/ScreenplayCycle.swift`:

```swift
import Foundation

/// Pure-logic helpers for Tab/Shift+Tab cycling through screenplay element
/// types. Used by EditorCoordinator when the active mode is ScreenplayMode.
public enum ScreenplayCycle {

    /// Highland-order cycle. Tab advances through this list; Shift+Tab reverses.
    public static let order: [ScreenplayElement] = [
        .action, .character, .dialogue, .parenthetical, .transition,
    ]

    /// Returns the next element in cycle order, wrapping at the end.
    public static func cycleForward(from element: ScreenplayElement) -> ScreenplayElement {
        guard let idx = order.firstIndex(of: element) else { return .character }
        let next = (idx + 1) % order.count
        return order[next]
    }

    /// Returns the previous element in cycle order, wrapping at the start.
    public static func cycleBackward(from element: ScreenplayElement) -> ScreenplayElement {
        guard let idx = order.firstIndex(of: element) else { return .action }
        let prev = (idx - 1 + order.count) % order.count
        return order[prev]
    }

    /// Smart starting point for the FIRST Tab press on a fresh blank line,
    /// based on the previous line's classified element. Subsequent Tab presses
    /// on the same blank line cycle forward from this starting point.
    public static func startingElement(after prev: ScreenplayElement) -> ScreenplayElement {
        switch prev {
        case .action:                 return .character
        case .sceneHeading:           return .action
        case .character:              return .dialogue
        case .parenthetical:          return .dialogue
        case .dialogue:               return .parenthetical
        case .transition:             return .sceneHeading
        case .centered, .lyric, .section, .synopsis,
             .boneyard, .note, .pageBreak:
            return .action
        }
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayCycleTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 16 tests, with 0 failures`.

- [ ] **Step 5: Run full test suite to confirm no regressions**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: `Executed 358 tests, with 0 failures` (342 baseline + 16 new).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/Fountain/ScreenplayCycle.swift MaughamTests/ScreenplayCycleTests.swift
git commit -m "feat: add ScreenplayCycle for Tab/Shift+Tab cycling logic

Pure-logic helpers: cycleForward/cycleBackward over the Highland order
(Action → Character → Dialogue → Parenthetical → Transition) and
startingElement(after:) for the smart context-aware first-Tab
landing on a fresh blank line.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: LineNeighborhood + ScreenplayLineMutator — context-aware source mutation

**Files:**
- Create: `Maugham/Editor/Fountain/ScreenplayLineMutator.swift` (also defines `LineNeighborhood`)
- Create: `MaughamTests/ScreenplayLineMutatorTests.swift`

Pure logic that, given a line's text + a target element + the line's neighborhood (prev/next blank flags), returns the new text and a cursor offset. Context-aware per spec §3.4: leaves text unchanged for elements with context-sensitive alternatives when context already satisfies them.

- [ ] **Step 1: Create the test file with failing tests**

```swift
import XCTest
@testable import Maugham

final class ScreenplayLineMutatorTests: XCTestCase {
    private let blankAbove = LineNeighborhood(prevIsBlank: true, nextIsBlank: false)
    private let nonBlankAbove = LineNeighborhood(prevIsBlank: false, nextIsBlank: false)
    private let blankAboveAndBelow = LineNeighborhood(prevIsBlank: true, nextIsBlank: true)

    // MARK: - Action

    func test_mutateToAction_stripsAtPrefix() {
        let result = ScreenplayLineMutator.mutate(
            line: "@BARRY", to: .action, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "BARRY")
    }

    func test_mutateToAction_stripsTransitionPrefix() {
        let result = ScreenplayLineMutator.mutate(
            line: "> CUT TO:", to: .action, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "CUT TO:")
    }

    func test_mutateToAction_stripsParens() {
        let result = ScreenplayLineMutator.mutate(
            line: "(quietly)", to: .action, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "quietly")
    }

    func test_mutateToAction_stripsLeadingDot() {
        let result = ScreenplayLineMutator.mutate(
            line: ".barbershop", to: .action, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "barbershop")
    }

    // MARK: - Scene heading

    func test_mutateToSceneHeading_intWithBlankAbove_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "INT. ROOM - DAY", to: .sceneHeading, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "INT. ROOM - DAY")
    }

    func test_mutateToSceneHeading_intWithoutBlankAbove_addsForcedDot() {
        let result = ScreenplayLineMutator.mutate(
            line: "INT. ROOM - DAY", to: .sceneHeading, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, ".INT. ROOM - DAY")
    }

    func test_mutateToSceneHeading_unprefixedAddsForcedDot() {
        let result = ScreenplayLineMutator.mutate(
            line: "barbershop", to: .sceneHeading, neighborhood: blankAbove)
        XCTAssertEqual(result.text, ".barbershop")
    }

    // MARK: - Character

    func test_mutateToCharacter_allCapsBlankAboveContentBelow_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "BARRY", to: .character, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "BARRY")
    }

    func test_mutateToCharacter_allCapsButNoBlankAbove_addsAt() {
        let result = ScreenplayLineMutator.mutate(
            line: "BARRY", to: .character, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, "@BARRY")
    }

    func test_mutateToCharacter_allCapsButOrphan_addsAt() {
        // blankAbove + blankBelow = orphan: parser would demote to .action.
        let result = ScreenplayLineMutator.mutate(
            line: "BARRY", to: .character, neighborhood: blankAboveAndBelow)
        XCTAssertEqual(result.text, "@BARRY")
    }

    func test_mutateToCharacter_lowercase_addsAt() {
        let result = ScreenplayLineMutator.mutate(
            line: "barry", to: .character, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "@barry")
    }

    func test_mutateToCharacter_mixedCase_addsAt() {
        let result = ScreenplayLineMutator.mutate(
            line: "Sam", to: .character, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "@Sam")
    }

    func test_mutateToCharacter_alreadyForced_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "@Sam", to: .character, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "@Sam")
    }

    // MARK: - Dialogue

    func test_mutateToDialogue_textUnchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "Hello there.", to: .dialogue, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, "Hello there.")
    }

    // MARK: - Parenthetical

    func test_mutateToParenthetical_unwrappedTextWraps_cursorInsideParen() {
        let result = ScreenplayLineMutator.mutate(
            line: "quietly", to: .parenthetical, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, "(quietly)")
        XCTAssertEqual(result.cursorOffset, 1)
    }

    func test_mutateToParenthetical_alreadyWrapped_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "(quietly)", to: .parenthetical, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, "(quietly)")
    }

    // MARK: - Transition

    func test_mutateToTransition_allCapsTOWithBlankAbove_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "CUT TO:", to: .transition, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "CUT TO:")
    }

    func test_mutateToTransition_allCapsTOWithoutBlankAbove_addsForcedGreater() {
        let result = ScreenplayLineMutator.mutate(
            line: "CUT TO:", to: .transition, neighborhood: nonBlankAbove)
        XCTAssertEqual(result.text, "> CUT TO:")
    }

    func test_mutateToTransition_lowercase_addsForcedGreater() {
        let result = ScreenplayLineMutator.mutate(
            line: "cut to:", to: .transition, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "> cut to:")
    }

    func test_mutateToTransition_alreadyForced_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "> SMASH CUT TO:", to: .transition, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "> SMASH CUT TO:")
    }

    // MARK: - Lyric

    func test_mutateToLyric_addsTilde() {
        let result = ScreenplayLineMutator.mutate(
            line: "la la la", to: .lyric, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "~la la la")
    }

    func test_mutateToLyric_alreadyTilde_unchanged() {
        let result = ScreenplayLineMutator.mutate(
            line: "~la la la", to: .lyric, neighborhood: blankAbove)
        XCTAssertEqual(result.text, "~la la la")
    }

    // MARK: - Round trip

    func test_roundTrip_characterToActionStripsAt() {
        let toCharacter = ScreenplayLineMutator.mutate(
            line: "barry", to: .character, neighborhood: blankAbove)
        XCTAssertEqual(toCharacter.text, "@barry")
        let toAction = ScreenplayLineMutator.mutate(
            line: toCharacter.text, to: .action, neighborhood: blankAbove)
        XCTAssertEqual(toAction.text, "barry")
    }

    func test_idempotent_parentheticalDoubleApply() {
        let first = ScreenplayLineMutator.mutate(
            line: "quietly", to: .parenthetical, neighborhood: nonBlankAbove)
        let second = ScreenplayLineMutator.mutate(
            line: first.text, to: .parenthetical, neighborhood: nonBlankAbove)
        XCTAssertEqual(first.text, second.text)
    }
}
```

- [ ] **Step 2: Run tests, expect compile errors**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayLineMutatorTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`

Expected: errors referencing `LineNeighborhood` and `ScreenplayLineMutator`.

- [ ] **Step 3: Create the implementation file**

Create `Maugham/Editor/Fountain/ScreenplayLineMutator.swift`:

```swift
import Foundation

/// Local context for a screenplay line — used by ScreenplayLineMutator to
/// decide whether a forced-syntax marker is needed for elements that have
/// context-sensitive alternatives (Character, Scene Heading, Transition).
public struct LineNeighborhood: Equatable, Sendable {
    public let prevIsBlank: Bool
    public let nextIsBlank: Bool

    public init(prevIsBlank: Bool, nextIsBlank: Bool) {
        self.prevIsBlank = prevIsBlank
        self.nextIsBlank = nextIsBlank
    }
}

/// Pure logic that rewrites a single line's source text to make it classify
/// as a target screenplay element. For elements with context-sensitive
/// alternatives (Character, Scene Heading, Transition), the mutator leaves
/// the text alone when the neighborhood already satisfies the alternative.
/// For elements without alternatives (Parenthetical, Lyric, Section,
/// Synopsis), the marker is always applied.
public enum ScreenplayLineMutator {

    public struct Result: Equatable {
        public let text: String
        /// Cursor offset within `text`, in UTF-16 units, where the caller
        /// should place the insertion point after replacement.
        public let cursorOffset: Int
    }

    public static func mutate(
        line: String,
        to target: ScreenplayElement,
        neighborhood: LineNeighborhood
    ) -> Result {
        switch target {
        case .action:           return mutateToAction(line: line)
        case .sceneHeading:     return mutateToSceneHeading(line: line, neighborhood: neighborhood)
        case .character:        return mutateToCharacter(line: line, neighborhood: neighborhood)
        case .dialogue:         return Result(text: line, cursorOffset: line.utf16.count)
        case .parenthetical:    return mutateToParenthetical(line: line)
        case .transition:       return mutateToTransition(line: line, neighborhood: neighborhood)
        case .centered:         return Result(text: ">\(line)<", cursorOffset: ">\(line)<".utf16.count)
        case .lyric:            return mutateToLyric(line: line)
        case .section:          return Result(text: "# \(stripActionMarkers(line))",
                                              cursorOffset: ("# \(stripActionMarkers(line))" as NSString).length)
        case .synopsis:         return Result(text: "= \(stripActionMarkers(line))",
                                              cursorOffset: ("= \(stripActionMarkers(line))" as NSString).length)
        case .pageBreak, .boneyard, .note:
            // Not reachable from cycle. Leave text alone.
            return Result(text: line, cursorOffset: line.utf16.count)
        }
    }

    // MARK: - Per-element

    private static func mutateToAction(line: String) -> Result {
        let stripped = stripActionMarkers(line)
        return Result(text: stripped, cursorOffset: (stripped as NSString).length)
    }

    private static func mutateToSceneHeading(
        line: String,
        neighborhood: LineNeighborhood
    ) -> Result {
        if line.hasPrefix(".") && !line.hasPrefix("..") {
            return Result(text: line, cursorOffset: (line as NSString).length)
        }
        if neighborhood.prevIsBlank && hasSceneHeadingPrefix(line) {
            return Result(text: line, cursorOffset: (line as NSString).length)
        }
        let new = "." + line
        return Result(text: new, cursorOffset: (new as NSString).length)
    }

    private static func mutateToCharacter(
        line: String,
        neighborhood: LineNeighborhood
    ) -> Result {
        if line.hasPrefix("@") {
            return Result(text: line, cursorOffset: (line as NSString).length)
        }
        if isAllUppercaseLetters(line)
            && neighborhood.prevIsBlank
            && !neighborhood.nextIsBlank {
            return Result(text: line, cursorOffset: (line as NSString).length)
        }
        let new = "@" + line
        return Result(text: new, cursorOffset: (new as NSString).length)
    }

    private static func mutateToParenthetical(line: String) -> Result {
        if line.hasPrefix("(") && line.hasSuffix(")") {
            return Result(text: line, cursorOffset: (line as NSString).length)
        }
        let new = "(\(line))"
        // Cursor inside the opening paren, before "quietly".
        return Result(text: new, cursorOffset: 1)
    }

    private static func mutateToTransition(
        line: String,
        neighborhood: LineNeighborhood
    ) -> Result {
        if line.hasPrefix(">") {
            return Result(text: line, cursorOffset: (line as NSString).length)
        }
        if neighborhood.prevIsBlank
            && isAllUppercaseLetters(line)
            && line.uppercased().hasSuffix("TO:") {
            return Result(text: line, cursorOffset: (line as NSString).length)
        }
        let new = "> " + line
        return Result(text: new, cursorOffset: (new as NSString).length)
    }

    private static func mutateToLyric(line: String) -> Result {
        if line.hasPrefix("~") {
            return Result(text: line, cursorOffset: (line as NSString).length)
        }
        let new = "~" + line
        return Result(text: new, cursorOffset: (new as NSString).length)
    }

    // MARK: - Helpers

    private static func stripActionMarkers(_ line: String) -> String {
        // Strip leading forced markers: @, !, ., >, ~. Strip wrapping parens.
        var result = line

        if result.hasPrefix("(") && result.hasSuffix(")") && result.count >= 2 {
            result = String(result.dropFirst().dropLast())
            return result
        }

        if let first = result.first {
            switch first {
            case "@", "!", "~":
                result = String(result.dropFirst())
            case ".":
                if !result.hasPrefix("..") {
                    result = String(result.dropFirst())
                }
            case ">":
                // > or > with a space.
                result = String(result.dropFirst())
                if result.hasPrefix(" ") {
                    result = String(result.dropFirst())
                }
            default:
                break
            }
        }

        // Strip leading 1-6 # followed by space (section).
        if let parsed = parseSectionMarker(result) {
            result = parsed
        }

        // Strip leading "= " (synopsis).
        if result.hasPrefix("= ") {
            result = String(result.dropFirst(2))
        }

        return result
    }

    private static func parseSectionMarker(_ line: String) -> String? {
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
            if hashes > 6 { return nil }
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let after = line.dropFirst(hashes)
        guard after.first == " " else { return nil }
        return String(after.dropFirst())
    }

    private static func isAllUppercaseLetters(_ line: String) -> Bool {
        var hasLetter = false
        for ch in line {
            if ch.isLetter {
                hasLetter = true
                if ch.isLowercase { return false }
            }
        }
        return hasLetter
    }

    private static let sceneHeadingPrefixes = [
        "INT.", "EXT.", "EST.", "I/E.", "INT/EXT.",
    ]

    private static func hasSceneHeadingPrefix(_ line: String) -> Bool {
        let upper = line.uppercased()
        for prefix in sceneHeadingPrefixes {
            if upper.hasPrefix(prefix + " ") || upper == prefix {
                return true
            }
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ScreenplayLineMutatorTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 21 tests, with 0 failures` (or close — exact count depends on which tests I included).

- [ ] **Step 5: Run full test suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~379 passing (358 baseline + 21 new).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/Fountain/ScreenplayLineMutator.swift MaughamTests/ScreenplayLineMutatorTests.swift
git commit -m "feat: add LineNeighborhood + ScreenplayLineMutator

Pure-logic source mutation per spec §3.4. For elements with context-
sensitive alternatives (Character, Scene Heading, Transition), the
mutator leaves the line as-is when the neighborhood already satisfies
the alternative — typing BARRY on a clean line stays BARRY. For
Parenthetical / Lyric / Section / Synopsis, the marker is always
applied since Fountain has no context-sensitive alternative.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: EditorCoordinator.lastParsedScript cache + plumbing

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`

Adds a `lastParsedScript: FountainScript?` cache populated during `retokenizeAndStyle`. Both the autocompleter (T7) and gutter view (T9) read from this cache — single source.

- [ ] **Step 1: Add the property**

In `EditorCoordinator.swift`, near the other private(set) properties (around line 39 where `lastTokens` lives), add:

```swift
    /// Most recent FountainScript from ScreenplayMode parsing. nil for prose
    /// modes. Updated each time retokenizeAndStyle runs. Source for both
    /// the character autocompleter (3b) and the element gutter (3b).
    private(set) var lastParsedScript: FountainScript?
```

- [ ] **Step 2: Populate the cache inside retokenizeAndStyle**

Find `retokenizeAndStyle()` (around line 141). After `let tokens = mode.tokenize(textView.string)` and `self.lastTokens = tokens`, add:

```swift
        if let screenplay = mode as? ScreenplayMode {
            lastParsedScript = FountainTokenizer().parse(textView.string)
        } else {
            lastParsedScript = nil
        }
        _ = screenplay   // suppress unused-variable if Swift complains
```

Actually simpler — since ScreenplayMode internally uses FountainTokenizer already, but calling its `tokenize` returns `[Token]` not `FountainScript`. We need a separate parse to get the FountainScript shape.

Replace the block above with the cleaner version:

```swift
        if mode is ScreenplayMode {
            lastParsedScript = FountainTokenizer().parse(textView.string)
        } else {
            lastParsedScript = nil
        }
```

- [ ] **Step 3: Build to verify compiles**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run all tests, expect no regressions**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~379 passing (no change from T2).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/EditorCoordinator.swift
git commit -m "feat: cache FountainScript on EditorCoordinator for screenplay

EditorCoordinator.lastParsedScript holds the most recent parsed
FountainScript when the active mode is ScreenplayMode. nil for
prose. The cache is populated during retokenizeAndStyle and read
by the upcoming character autocompleter and element gutter — single
source.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: doCommandBy + Tab cycle handlers + lastCycleTarget lifecycle

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`
- Create: `MaughamTests/EditorCoordinatorCycleTests.swift`

Adds the `doCommandBy:` interceptor for Tab/Shift+Tab + the cycleElementForward/Backward methods + lastCycleTarget lifecycle. Autocomplete branch is added in T7 — for now, doCommandBy only handles cycling.

- [ ] **Step 1: Add the new properties**

In `EditorCoordinator.swift`, near other private(set) properties:

```swift
    /// Most recent cycle target on the current blank line. Cleared when:
    /// - cursor moves to a different line
    /// - any non-Tab edit triggers textDidChange
    /// - the active line gains content via the cycle's mutator
    /// Used so that subsequent Tab presses on the same blank line cycle
    /// from the prior target rather than re-computing startingElement.
    private var lastCycleTarget: ScreenplayElement?

    /// Active line's range at the moment lastCycleTarget was set; used to
    /// detect cursor moves to a different line.
    private var lastCycleTargetLineRange: NSRange?
```

- [ ] **Step 2: Add the doCommandBy implementation**

After the existing `textView(_:shouldChangeTextIn:replacementString:)` implementation, add:

```swift
    func textView(_ textView: NSTextView,
                  doCommandBy commandSelector: Selector) -> Bool {
        guard mode is ScreenplayMode else { return false }

        // Autocompleter branch lands in T7. For now, only cycle handling.
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            cycleElementForward(in: textView)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            cycleElementBackward(in: textView)
            return true
        default:
            return false
        }
    }
```

- [ ] **Step 3: Add cycleElementForward / cycleElementBackward**

Add these methods to `EditorCoordinator` (private):

```swift
    private func cycleElementForward(in textView: NSTextView) {
        cycle(in: textView, direction: .forward)
    }

    private func cycleElementBackward(in textView: NSTextView) {
        cycle(in: textView, direction: .backward)
    }

    private enum CycleDirection { case forward, backward }

    private func cycle(in textView: NSTextView, direction: CycleDirection) {
        guard let storage = textView.textStorage,
              let script = lastParsedScript else { return }

        let cursor = textView.selectedRange().location
        guard let activeLine = lineCovering(cursor: cursor, in: script) else { return }
        let lineIndex = script.lines.firstIndex(of: activeLine) ?? -1

        let prevElement: ScreenplayElement = (lineIndex > 0)
            ? script.lines[lineIndex - 1].element
            : .action
        let isBlank = activeLine.content.isEmpty

        // Choose target.
        let target: ScreenplayElement = chooseTarget(
            activeLine: activeLine,
            prevElement: prevElement,
            isBlank: isBlank,
            direction: direction)

        // Compute neighborhood from script.
        let neighborhood = LineNeighborhood(
            prevIsBlank: (lineIndex <= 0)
                || script.lines[lineIndex - 1].content.isEmpty,
            nextIsBlank: (lineIndex < 0 || lineIndex >= script.lines.count - 1)
                || script.lines[lineIndex + 1].content.isEmpty)

        // Apply mutator.
        let result = ScreenplayLineMutator.mutate(
            line: activeLine.content,
            to: target,
            neighborhood: neighborhood)

        // Replace the line's text in the storage.
        let lineRange = activeLine.range
        // The line.range from FountainTokenizer includes the trailing newline
        // if present. We replace only the content portion.
        let trailingNewline = (storage.length > lineRange.location + activeLine.content.count)
            && (storage.string as NSString).substring(
                with: NSRange(location: lineRange.location + activeLine.content.count, length: 1)
              ) == "\n"
        let replaceRange = NSRange(
            location: lineRange.location,
            length: activeLine.content.count)
        let newText = result.text + (trailingNewline ? "" : "")

        guard textView.shouldChangeText(in: replaceRange, replacementString: newText) else { return }
        storage.replaceCharacters(in: replaceRange, with: newText)
        textView.didChangeText()

        let cursorLocation = lineRange.location + result.cursorOffset
        textView.setSelectedRange(NSRange(location: cursorLocation, length: 0))

        // Update lastCycleTarget lifecycle.
        let newLineRange = NSRange(location: lineRange.location,
                                   length: (newText as NSString).length)
        if isBlank && result.text.isEmpty {
            // Line stayed empty — preserve target for subsequent Tab.
            lastCycleTarget = target
            lastCycleTargetLineRange = newLineRange
        } else {
            lastCycleTarget = nil
            lastCycleTargetLineRange = nil
        }
    }

    private func chooseTarget(
        activeLine: FountainLine,
        prevElement: ScreenplayElement,
        isBlank: Bool,
        direction: CycleDirection
    ) -> ScreenplayElement {
        if isBlank, let cached = lastCycleTarget {
            return advance(from: cached, direction: direction)
        }
        if isBlank {
            return ScreenplayCycle.startingElement(after: prevElement)
        }
        return advance(from: activeLine.element, direction: direction)
    }

    private func advance(from element: ScreenplayElement,
                         direction: CycleDirection) -> ScreenplayElement {
        switch direction {
        case .forward:  return ScreenplayCycle.cycleForward(from: element)
        case .backward: return ScreenplayCycle.cycleBackward(from: element)
        }
    }

    private func lineCovering(cursor: Int, in script: FountainScript) -> FountainLine? {
        for line in script.lines {
            if line.range.location <= cursor
                && cursor <= line.range.location + line.range.length {
                return line
            }
        }
        return script.lines.last
    }
```

- [ ] **Step 4: Clear lastCycleTarget on selection change**

In `EditorCoordinator`, add the NSTextViewDelegate hook:

```swift
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              let lineRange = lastCycleTargetLineRange else { return }
        let cursor = textView.selectedRange().location
        if cursor < lineRange.location || cursor > NSMaxRange(lineRange) {
            lastCycleTarget = nil
            lastCycleTargetLineRange = nil
        }
    }
```

- [ ] **Step 5: Clear lastCycleTarget on non-Tab edits**

In `textDidChange(_:)` (around line 200), at the start (before the binding update), add:

```swift
        // The Tab handler manages its own cleanup; any other edit clears the cache.
        if !isApplyingTabCycle {
            lastCycleTarget = nil
            lastCycleTargetLineRange = nil
        }
```

And add the flag:

```swift
    private var isApplyingTabCycle = false
```

Set it in the `cycle(in:direction:)` method around the storage replacement:

```swift
        isApplyingTabCycle = true
        defer { isApplyingTabCycle = false }
```

- [ ] **Step 6: Create EditorCoordinatorCycleTests.swift**

```swift
import XCTest
import AppKit
@testable import Maugham

@MainActor
final class EditorCoordinatorCycleTests: XCTestCase {

    private func makeTextView(text: String = "") -> NSTextView {
        let storage = NSTextStorage(string: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 600))
        layout.addTextContainer(container)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                            textContainer: container)
        return tv
    }

    private func makeCoordinator(textView: NSTextView,
                                 mode: any WritingMode) -> EditorCoordinator {
        var binding: Binding<String> = .init(
            get: { textView.string },
            set: { textView.string = $0 })
        let coord = EditorCoordinator(
            text: binding, mode: mode,
            theme: .light, typography: .screenplayDefaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        coord.attach(to: textView)
        return coord
    }

    func test_tabOnEmptyDocument_insertsAtMarker() {
        let tv = makeTextView(text: "")
        let coord = makeCoordinator(textView: tv, mode: ScreenplayMode())
        // Simulate Tab.
        _ = coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(tv.string, "@")
    }

    func test_tabAfterCharacter_landsOnDialogue_blankLine_noMarker() {
        let tv = makeTextView(text: "@BARRY\n")
        // Position cursor at end (line 2, blank).
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        let coord = makeCoordinator(textView: tv, mode: ScreenplayMode())
        _ = coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:)))
        // Dialogue has no marker — line stays empty. lastCycleTarget = .dialogue.
        XCTAssertEqual(tv.string, "@BARRY\n")
        // Hit Tab again — should advance to Parenthetical, wrapping in ().
        _ = coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(tv.string, "@BARRY\n()")
    }

    func test_tabOnAllCapsCharacter_doesNotAddAt() {
        let tv = makeTextView(text: "BARRY\nHello.")
        // Cursor at end of BARRY.
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        let coord = makeCoordinator(textView: tv, mode: ScreenplayMode())
        // Active line classifies as Character (ALL CAPS + blank above + content below).
        // Tab from .character cycles to .dialogue. Line text shouldn't gain @.
        _ = coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(tv.string.contains("BARRY"))
        XCTAssertFalse(tv.string.contains("@BARRY"))
    }

    func test_shiftTabReverses() {
        let tv = makeTextView(text: "@BARRY\n")
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        let coord = makeCoordinator(textView: tv, mode: ScreenplayMode())
        // Tab once → Dialogue; tab again → Parenthetical wraps → "()".
        _ = coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:)))
        _ = coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(tv.string, "@BARRY\n()")
        // Shift-Tab → back to Dialogue (line empty).
        _ = coord.textView(tv, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(tv.string, "@BARRY\n")
    }
}
```

(These tests are integration-level and may be touchy; if any fail with off-by-one issues, adjust ranges to match what FountainTokenizer actually produces.)

- [ ] **Step 7: Run tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/EditorCoordinatorCycleTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: 4 tests pass.

If tests fail with cursor/range issues, debug by printing `lastParsedScript` shape and adjusting the `lineCovering` and `replaceRange` math. The key invariant: `FountainLine.range` covers `content + trailing newline if present`.

- [ ] **Step 8: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~383 passing (379 + 4).

- [ ] **Step 9: Commit**

```bash
git add Maugham/Editor/EditorCoordinator.swift MaughamTests/EditorCoordinatorCycleTests.swift
git commit -m "feat: Tab/Shift+Tab cycle screenplay elements via doCommandBy

EditorCoordinator intercepts insertTab: / insertBacktab: when the
active mode is ScreenplayMode. The cycle reads the active line's
classified element from lastParsedScript, computes a target via
ScreenplayCycle (with smart starting point on blank lines and a
lastCycleTarget cache for subsequent Tabs), and applies
ScreenplayLineMutator with the line's neighborhood.

Cursor positioning honors the mutator's offset (cursor inside
opening paren for parenthetical wrap, end-of-line otherwise).
lastCycleTarget is cleared on cursor move to a different line and
on any non-cycle edit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: CharacterAutocompleter — data layer (filtering + ranking)

**Files:**
- Create: `Maugham/Editor/Fountain/CharacterAutocompleter.swift` (data structures only — UI lands in T6)
- Create: `MaughamTests/CharacterAutocompleterDataTests.swift`

Pure-logic data layer that, given a prefix and the available `characterNames`, returns a ranked list of suggestions (prefix-match first, substring second, capped at 8).

- [ ] **Step 1: Create the test file with failing tests**

```swift
import XCTest
@testable import Maugham

final class CharacterAutocompleterDataTests: XCTestCase {

    func test_rankSuggestions_emptyNames_returnsEmpty() {
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "B", characterNames: [])
        XCTAssertEqual(suggestions, [])
    }

    func test_rankSuggestions_emptyPrefix_returnsEmpty() {
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "", characterNames: ["BARRY", "SAM"])
        XCTAssertEqual(suggestions, [])
    }

    func test_rankSuggestions_prefixMatchesFirst() {
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "B",
            characterNames: ["SAM", "BARRY", "ABBY", "BARTENDER"])
        XCTAssertEqual(suggestions, ["BARRY", "BARTENDER", "ABBY"])
    }

    func test_rankSuggestions_caseInsensitive() {
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "bar",
            characterNames: ["BARRY", "BARTENDER"])
        XCTAssertEqual(suggestions, ["BARRY", "BARTENDER"])
    }

    func test_rankSuggestions_substringMatchAfterPrefix() {
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "RT",
            characterNames: ["BARTENDER", "MARTHA", "ART"])
        // None prefix-match RT; BARTENDER and MARTHA contain RT (substring).
        // Ordered alphabetically among substring matches.
        XCTAssertEqual(suggestions, ["BARTENDER", "MARTHA"])
    }

    func test_rankSuggestions_alphabeticalWithinTier() {
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "S",
            characterNames: ["SAM", "SARAH", "SLIM"])
        XCTAssertEqual(suggestions, ["SAM", "SARAH", "SLIM"])
    }

    func test_rankSuggestions_capsAtEight() {
        let names: Set<String> = Set((1...20).map { "ALPHA\($0)" })
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "ALPHA", characterNames: names)
        XCTAssertEqual(suggestions.count, 8)
    }
}
```

- [ ] **Step 2: Run tests, expect compile errors**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/CharacterAutocompleterDataTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`

Expected: errors referencing `CharacterAutocompleter`.

- [ ] **Step 3: Create the data layer**

Create `Maugham/Editor/Fountain/CharacterAutocompleter.swift`:

```swift
import AppKit

/// Pure data layer for character-name autocomplete suggestions.
/// UI integration (NSPopover, NSTableView) lands in subsequent tasks.
public final class CharacterAutocompleter {

    public init() {}

    /// Filter and rank candidate suggestions for a given prefix.
    /// - Returns: At most 8 candidates, with prefix-matches first
    ///   (alphabetical within), then substring-matches (alphabetical within),
    ///   excluding any candidates already in the prefix-match tier.
    public static func rankSuggestions(
        prefix: String,
        characterNames: Set<String>
    ) -> [String] {
        guard !prefix.isEmpty, !characterNames.isEmpty else { return [] }

        let upperPrefix = prefix.uppercased()
        let allUpper = Set(characterNames.map { $0.uppercased() })

        let prefixMatches = allUpper
            .filter { $0.hasPrefix(upperPrefix) }
            .sorted()

        let substringMatches = allUpper
            .filter { name in
                name.range(of: upperPrefix) != nil
                    && !name.hasPrefix(upperPrefix)
            }
            .sorted()

        let combined = prefixMatches + substringMatches
        return Array(combined.prefix(8))
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/CharacterAutocompleterDataTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~390 passing (383 + 7).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/Fountain/CharacterAutocompleter.swift MaughamTests/CharacterAutocompleterDataTests.swift
git commit -m "feat: CharacterAutocompleter data layer (filtering + ranking)

Static rankSuggestions(prefix:characterNames:) returns prefix-matches
first (alphabetical), then substring-matches (alphabetical), capped
at 8 candidates. Case-insensitive comparison.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: CharacterAutocompleter — NSPopover UI lifecycle

**Files:**
- Modify: `Maugham/Editor/Fountain/CharacterAutocompleter.swift`

Adds the NSPopover + NSTableView UI to `CharacterAutocompleter`. The data layer from T5 is extended with instance state for the active suggestions list, popover lifecycle, and selection management.

- [ ] **Step 1: Add the instance API**

Replace the `CharacterAutocompleter` class body in `Maugham/Editor/Fountain/CharacterAutocompleter.swift` with:

```swift
import AppKit

public final class CharacterAutocompleter: NSObject {

    private(set) public var suggestions: [String] = []
    private(set) public var selectedIndex: Int = 0

    private let popover: NSPopover
    private let tableView: NSTableView
    private let scrollView: NSScrollView

    public var isVisible: Bool { popover.isShown }

    public override init() {
        self.popover = NSPopover()
        popover.behavior = .transient

        // Set up the table view inside a scroll view.
        let tv = NSTableView()
        tv.headerView = nil
        tv.allowsMultipleSelection = false
        tv.allowsEmptySelection = false
        tv.backgroundColor = .clear
        tv.intercellSpacing = NSSize(width: 0, height: 2)
        tv.rowHeight = 22
        tv.usesAlternatingRowBackgroundColors = false
        tv.style = .plain

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 200
        tv.addTableColumn(column)

        let sv = NSScrollView()
        sv.hasVerticalScroller = false
        sv.documentView = tv
        sv.drawsBackground = false

        self.tableView = tv
        self.scrollView = sv
        super.init()

        tv.delegate = self
        tv.dataSource = self

        let vc = NSViewController()
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        sv.frame = containerView.bounds
        sv.autoresizingMask = [.width, .height]
        containerView.addSubview(sv)
        vc.view = containerView
        popover.contentViewController = vc
    }

    /// Update suggestions and either show or update the popover.
    /// `anchorRect` is the cursor's screen-rect (relative to the text view).
    /// `relativeTo` is the text view that owns the cursor.
    public func show(
        suggestions: [String],
        anchorRect: NSRect,
        relativeTo view: NSView
    ) {
        guard !suggestions.isEmpty else {
            dismiss()
            return
        }
        self.suggestions = suggestions
        self.selectedIndex = 0

        let height = CGFloat(min(suggestions.count, 8) * 24 + 8)
        if let containerView = popover.contentViewController?.view {
            containerView.frame = NSRect(x: 0, y: 0, width: 200, height: height)
            scrollView.frame = containerView.bounds
        }

        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        if popover.isShown {
            // Reposition.
            popover.show(relativeTo: anchorRect, of: view, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: anchorRect, of: view, preferredEdge: .minY)
        }
    }

    public func dismiss() {
        if popover.isShown { popover.close() }
        suggestions = []
        selectedIndex = 0
    }

    public func moveSelectionUp() {
        guard !suggestions.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex),
                                   byExtendingSelection: false)
    }

    public func moveSelectionDown() {
        guard !suggestions.isEmpty else { return }
        selectedIndex = min(suggestions.count - 1, selectedIndex + 1)
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex),
                                   byExtendingSelection: false)
    }

    /// Replace the active line's character cue text with the selected suggestion
    /// and dismiss the popover. Preserves any leading `@` prefix.
    public func acceptSelection(in textView: NSTextView) {
        guard !suggestions.isEmpty,
              selectedIndex >= 0, selectedIndex < suggestions.count,
              let storage = textView.textStorage else {
            dismiss()
            return
        }
        let chosen = suggestions[selectedIndex]
        let cursor = textView.selectedRange().location
        let lineRange = (storage.string as NSString).lineRange(
            for: NSRange(location: cursor, length: 0))
        var lineText = (storage.string as NSString).substring(with: lineRange)
        // Strip trailing newline for processing.
        let hasTrailingNewline = lineText.hasSuffix("\n")
        if hasTrailingNewline { lineText.removeLast() }
        let hasAt = lineText.hasPrefix("@")
        let newContent = hasAt ? "@" + chosen : chosen
        let newLine = newContent + (hasTrailingNewline ? "\n" : "")

        guard textView.shouldChangeText(in: lineRange, replacementString: newLine) else {
            dismiss()
            return
        }
        storage.replaceCharacters(in: lineRange, with: newLine)
        textView.didChangeText()
        let endLocation = lineRange.location + (newContent as NSString).length
        textView.setSelectedRange(NSRange(location: endLocation, length: 0))
        dismiss()
    }

    // MARK: - Pure data (kept from T5)

    public static func rankSuggestions(
        prefix: String,
        characterNames: Set<String>
    ) -> [String] {
        guard !prefix.isEmpty, !characterNames.isEmpty else { return [] }
        let upperPrefix = prefix.uppercased()
        let allUpper = Set(characterNames.map { $0.uppercased() })
        let prefixMatches = allUpper
            .filter { $0.hasPrefix(upperPrefix) }
            .sorted()
        let substringMatches = allUpper
            .filter { name in
                name.range(of: upperPrefix) != nil
                    && !name.hasPrefix(upperPrefix)
            }
            .sorted()
        let combined = prefixMatches + substringMatches
        return Array(combined.prefix(8))
    }
}

// MARK: - NSTableViewDataSource

extension CharacterAutocompleter: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        suggestions.count
    }
}

// MARK: - NSTableViewDelegate

extension CharacterAutocompleter: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        let cellId = NSUserInterfaceItemIdentifier("nameCell")
        let view: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            view = reused
        } else {
            view = NSTableCellView()
            view.identifier = cellId
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            tf.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(tf)
            view.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
        view.textField?.stringValue = suggestions[row]
        return view
    }
}
```

- [ ] **Step 2: Build to verify compiles**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run existing autocompleter tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~390 passing (no new tests in this task — popover lifecycle is verified manually in smoke).

- [ ] **Step 4: Commit**

```bash
git add Maugham/Editor/Fountain/CharacterAutocompleter.swift
git commit -m "feat: CharacterAutocompleter NSPopover UI lifecycle

NSPopover with transient behavior wraps an NSTableView showing
ranked suggestions. show(suggestions:anchorRect:relativeTo:) creates
or repositions the popover; dismiss closes it. Up/Down navigate
selection; acceptSelection replaces the active line's content
preserving any leading @ prefix.

UI is invoked by EditorCoordinator (next task). Standalone unit
tests for the popover are not included — lifecycle is verified
during smoke.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Autocomplete trigger + keystroke routing in EditorCoordinator

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`

Wire the autocompleter into `EditorCoordinator`: instantiate it, trigger it from `textDidChange`, route keystrokes through `doCommandBy:`.

- [ ] **Step 1: Add the autocompleter instance**

In `EditorCoordinator.swift`, near the other private properties:

```swift
    private let autocompleter = CharacterAutocompleter()
```

- [ ] **Step 2: Update doCommandBy to route through autocompleter**

Replace the existing `textView(_:doCommandBy:)` body (from T4) with:

```swift
    func textView(_ textView: NSTextView,
                  doCommandBy commandSelector: Selector) -> Bool {
        guard mode is ScreenplayMode else { return false }

        if autocompleter.isVisible {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                autocompleter.moveSelectionUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                autocompleter.moveSelectionDown()
                return true
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertNewline(_:)):
                autocompleter.acceptSelection(in: textView)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                autocompleter.dismiss()
                return true
            default:
                return false
            }
        }

        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            cycleElementForward(in: textView)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            cycleElementBackward(in: textView)
            return true
        default:
            return false
        }
    }
```

- [ ] **Step 3: Add the trigger logic**

Add a method to `EditorCoordinator`:

```swift
    private func updateAutocomplete(in textView: NSTextView) {
        guard mode is ScreenplayMode,
              let script = lastParsedScript,
              !script.characterNames.isEmpty,
              let storage = textView.textStorage else {
            autocompleter.dismiss()
            return
        }
        let cursor = textView.selectedRange().location
        guard let activeLine = lineCovering(cursor: cursor, in: script) else {
            autocompleter.dismiss()
            return
        }
        guard activeLine.element == .character else {
            autocompleter.dismiss()
            return
        }
        // Cursor must be at end of line content.
        let endOfLine = activeLine.range.location + activeLine.content.count
        guard cursor == endOfLine else {
            autocompleter.dismiss()
            return
        }
        guard !activeLine.content.isEmpty else {
            autocompleter.dismiss()
            return
        }
        // Strip @ prefix for prefix-matching.
        let prefix = activeLine.content.hasPrefix("@")
            ? String(activeLine.content.dropFirst())
            : activeLine.content
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: prefix, characterNames: script.characterNames)
        guard !suggestions.isEmpty else {
            autocompleter.dismiss()
            return
        }
        // Compute anchor rect from layout manager.
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            autocompleter.dismiss()
            return
        }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: cursor, length: 0),
            actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: container)
        rect = rect.offsetBy(dx: textView.textContainerInset.width,
                             dy: textView.textContainerInset.height)
        autocompleter.show(suggestions: suggestions,
                           anchorRect: rect,
                           relativeTo: textView)
    }
```

- [ ] **Step 4: Hook it into textDidChange**

In `textDidChange(_:)` (around line 200), after `retokenizeAndStyle()` runs, add:

```swift
        if mode is ScreenplayMode {
            updateAutocomplete(in: textView)
        }
```

Also call it from `textViewDidChangeSelection`:

```swift
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        if let lineRange = lastCycleTargetLineRange {
            let cursor = textView.selectedRange().location
            if cursor < lineRange.location || cursor > NSMaxRange(lineRange) {
                lastCycleTarget = nil
                lastCycleTargetLineRange = nil
            }
        }
        if mode is ScreenplayMode {
            updateAutocomplete(in: textView)
        }
    }
```

- [ ] **Step 5: Run tests + full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~390 passing (no new unit tests; the popover trigger logic is verified during smoke).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/EditorCoordinator.swift
git commit -m "feat: trigger character autocomplete + route keystrokes

EditorCoordinator polls the autocompleter on textDidChange and
selection change. Trigger fires only when the active line classifies
as Character with content and cursor at end of line. Up/Down/Enter/
Tab/Escape route through doCommandBy: to the popover when visible;
otherwise Tab cycles elements as before.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: ElementGutterView — NSView subclass with abbreviation drawing

**Files:**
- Create: `Maugham/Editor/ElementGutterView.swift`
- Create: `MaughamTests/ElementGutterAbbreviationTests.swift`

A custom `NSView` that draws per-line element abbreviations. Logic for picking the abbreviation per `ScreenplayElement` is testable in isolation.

- [ ] **Step 1: Create the test file**

```swift
import XCTest
@testable import Maugham

final class ElementGutterAbbreviationTests: XCTestCase {

    func test_abbreviation_action_isNil() {
        XCTAssertNil(ElementGutterView.abbreviation(for: .action))
    }

    func test_abbreviation_sceneHeading_isSCENE() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .sceneHeading), "SCENE")
    }

    func test_abbreviation_character_isCHAR() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .character), "CHAR")
    }

    func test_abbreviation_dialogue_isDLG() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .dialogue), "DLG")
    }

    func test_abbreviation_parenthetical_isPAR() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .parenthetical), "PAR")
    }

    func test_abbreviation_transition_isTRANS() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .transition), "TRANS")
    }

    func test_abbreviation_centered_isCTR() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .centered), "CTR")
    }

    func test_abbreviation_lyric_isLYR() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .lyric), "LYR")
    }

    func test_abbreviation_section1_isSection1() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .section(level: 1)), "§1")
    }

    func test_abbreviation_section3_isSection3() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .section(level: 3)), "§3")
    }

    func test_abbreviation_synopsis_isSYN() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .synopsis), "SYN")
    }

    func test_abbreviation_pageBreak_isPAGE() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .pageBreak), "PAGE")
    }

    func test_abbreviation_boneyard_isCUT() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .boneyard), "CUT")
    }

    func test_abbreviation_note_isNOTE() {
        XCTAssertEqual(ElementGutterView.abbreviation(for: .note), "NOTE")
    }
}
```

- [ ] **Step 2: Run tests, expect compile errors**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ElementGutterAbbreviationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`

Expected: errors referencing `ElementGutterView`.

- [ ] **Step 3: Create the gutter view**

Create `Maugham/Editor/ElementGutterView.swift`:

```swift
import AppKit

/// Custom NSView drawn in the left text-container inset of MaughamTextView.
/// Shows a small uppercase abbreviation per line indicating the parsed
/// screenplay element (CHAR, DLG, PAR, TRANS, etc.). Action lines get no label.
public final class ElementGutterView: NSView {

    public weak var coordinator: EditorCoordinator?
    public weak var associatedTextView: NSTextView?

    public override var isFlipped: Bool { true }

    /// Static abbreviation lookup. Made public for unit testing.
    public static func abbreviation(for element: ScreenplayElement) -> String? {
        switch element {
        case .action:               return nil
        case .sceneHeading:         return "SCENE"
        case .character:            return "CHAR"
        case .dialogue:             return "DLG"
        case .parenthetical:        return "PAR"
        case .transition:           return "TRANS"
        case .centered:             return "CTR"
        case .lyric:                return "LYR"
        case .section(let level):   return "§\(level)"
        case .synopsis:             return "SYN"
        case .pageBreak:            return "PAGE"
        case .boneyard:             return "CUT"
        case .note:                 return "NOTE"
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let textView = associatedTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let script = coordinator?.lastParsedScript else { return }

        let palette = currentPalette()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(
                ofSize: textView.font?.pointSize ?? 13, weight: .regular)
                .scaled(by: 0.7),
            .foregroundColor: palette.syntaxPunctuation,
        ]

        // For each parsed line, find its bounding glyph rect in the text view
        // and draw the abbreviation aligned to that line's baseline within
        // the gutter's frame.
        for line in script.lines {
            guard let label = Self.abbreviation(for: line.element) else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: line.range, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange, in: container)

            // Convert from container-coordinates (text view's coordinate space)
            // to gutter-coordinates. Text view is centered via textContainerInset;
            // gutter sits in the left inset area at x=0..gutterWidth.
            let yOffset = textView.textContainerInset.height
            let drawY = lineRect.origin.y + yOffset

            let labelSize = (label as NSString).size(withAttributes: attrs)
            // Right-aligned within the gutter (so labels read into the column).
            let drawX = bounds.width - labelSize.width - 6
            let point = NSPoint(x: drawX, y: drawY)
            (label as NSString).draw(at: point, withAttributes: attrs)
        }
    }

    private func currentPalette() -> ThemePalette {
        let appearance = NSApp?.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua])
        let theme = coordinator?.theme ?? .light
        let resolved = theme.resolved(systemAppearanceIsDark: appearance == .darkAqua)
        return resolved.palette
    }
}

private extension NSFont {
    func scaled(by factor: CGFloat) -> NSFont {
        NSFont(descriptor: fontDescriptor, size: pointSize * factor) ?? self
    }
}
```

- [ ] **Step 4: Run targeted tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ElementGutterAbbreviationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: `Executed 14 tests, with 0 failures`.

- [ ] **Step 5: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~404 passing (390 + 14).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/ElementGutterView.swift MaughamTests/ElementGutterAbbreviationTests.swift
git commit -m "feat: ElementGutterView for per-line element abbreviations

Custom NSView subclass that reads coordinator.lastParsedScript and
draws a small uppercase abbreviation (CHAR, DLG, PAR, TRANS, etc.)
per line in the gutter area. Action lines get no label. Section
levels render as §N. Theme-color-aware via currentPalette().

Integration into MaughamTextView lands in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Integrate ElementGutterView into MaughamTextView (subview lifecycle)

**Files:**
- Modify: `Maugham/Editor/EditorSurface.swift`
- Modify: `Maugham/Editor/EditorCoordinator.swift` (expose theme/typography for the gutter to read)

The gutter view becomes a subview of `MaughamTextView`, positioned in the left text-container inset. When `updateColumnInset()` runs, the gutter's frame is updated.

- [ ] **Step 1: Make `EditorCoordinator.theme` accessible publicly (it's already `private(set)` so accessible)**

No code change — just verify in `EditorCoordinator.swift` that `theme` and `typography` are accessible to the gutter view via the weak coordinator reference. They already are (`private(set) var`).

- [ ] **Step 2: Add gutter as subview of MaughamTextView**

In `EditorSurface.swift`, modify the `MaughamTextView` class:

Add a property:

```swift
    var gutterView: ElementGutterView?
```

Modify `updateColumnInset()` (around line 164) — add at the end (after the existing inset/container logic):

```swift
        // Update gutter frame if present.
        if let gutter = gutterView {
            let gutterWidth = max(0, horizontal)
            gutter.frame = NSRect(
                x: 0,
                y: 0,
                width: gutterWidth,
                height: max(bounds.height, frame.height))
            gutter.needsDisplay = true
        }
```

Then add an installation method on `MaughamTextView`:

```swift
    func installGutter(coordinator: EditorCoordinator) {
        guard gutterView == nil else { return }
        let gutter = ElementGutterView(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
        gutter.coordinator = coordinator
        gutter.associatedTextView = self
        gutter.autoresizingMask = [.height]
        addSubview(gutter)
        gutterView = gutter
        updateColumnInset()
    }

    func removeGutter() {
        gutterView?.removeFromSuperview()
        gutterView = nil
    }
```

- [ ] **Step 3: Conditionally install/remove on mode change**

In `EditorSurface.makeNSView`, after `textView.coordinator = context.coordinator`, add:

```swift
        if mode is ScreenplayMode {
            textView.installGutter(coordinator: context.coordinator)
        }
```

In `EditorSurface.updateNSView`, after the existing mode-change handling, add:

```swift
        // Mode-change reconciliation for gutter.
        if mode is ScreenplayMode && textView.gutterView == nil {
            textView.installGutter(coordinator: context.coordinator)
        } else if !(mode is ScreenplayMode) && textView.gutterView != nil {
            textView.removeGutter()
        }
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~404 passing (no regressions).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/EditorSurface.swift Maugham/Editor/EditorCoordinator.swift
git commit -m "feat: install ElementGutterView in MaughamTextView left inset

ElementGutterView attaches as a subview of MaughamTextView when the
active mode is ScreenplayMode. Frame is updated by updateColumnInset
to track the left inset width as the editor pane resizes. Removed
from the hierarchy when switching to prose modes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Gutter repaint hooks (text-change, scroll, theme-change)

**Files:**
- Modify: `Maugham/Editor/ElementGutterView.swift`

The gutter currently only repaints when its frame changes. Hook it to repaint on:
- text changes (so abbreviations update as the writer types/cycles)
- scroll changes (so visible lines re-layout)
- theme/typography changes (so colors and font sizes update)

- [ ] **Step 1: Subscribe to notifications in viewDidMoveToWindow**

In `ElementGutterView`, override `viewDidMoveToWindow`:

```swift
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let tv = associatedTextView else { return }
        let nc = NotificationCenter.default
        nc.removeObserver(self)
        nc.addObserver(
            self,
            selector: #selector(handleTextDidChange(_:)),
            name: NSText.didChangeNotification,
            object: tv)
        if let scrollView = tv.enclosingScrollView {
            nc.addObserver(
                self,
                selector: #selector(handleBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView)
            scrollView.contentView.postsBoundsChangedNotifications = true
        }
        nc.addObserver(
            self,
            selector: #selector(handleAppearanceChange(_:)),
            name: NSWindow.didChangeBackingPropertiesNotification,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleTextDidChange(_ note: Notification) {
        needsDisplay = true
    }

    @objc private func handleBoundsDidChange(_ note: Notification) {
        needsDisplay = true
    }

    @objc private func handleAppearanceChange(_ note: Notification) {
        needsDisplay = true
    }
```

- [ ] **Step 2: Build + run tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~404 passing.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Editor/ElementGutterView.swift
git commit -m "feat: ElementGutterView repaints on text/scroll/theme changes

Subscribes to NSText.didChangeNotification (text edits),
NSView.boundsDidChangeNotification on the scroll view's clip view
(scroll), and NSWindow.didChangeBackingPropertiesNotification (theme/
typography changes). Each fires needsDisplay = true.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: ProjectManifest.showElementGutter + ProjectStore mutator + migration test

**Files:**
- Modify: `Maugham/Models/ProjectManifest.swift`
- Modify: `Maugham/Stores/ProjectStore.swift`
- Create: `MaughamTests/ProjectManifestGutterMigrationTests.swift`

Add an optional `Bool?` field to ProjectManifest. Default behavior when nil = show. ProjectStore gains a mutator. Manifests written before 3b decode unchanged.

- [ ] **Step 1: Create the migration test**

Create `MaughamTests/ProjectManifestGutterMigrationTests.swift`:

```swift
import XCTest
@testable import Maugham

final class ProjectManifestGutterMigrationTests: XCTestCase {

    func test_decode_legacyManifest_leavesShowElementGutterNil() throws {
        let json = """
        {
          "schemaVersion": 1,
          "type": "screenplay",
          "title": "Test",
          "author": "",
          "created": "2026-05-09T12:00:00Z",
          "modified": "2026-05-09T12:00:00Z",
          "structure": [],
          "research": []
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ProjectManifest.self, from: json)
        XCTAssertNil(manifest.showElementGutter)
    }

    func test_decode_manifestWithGutterFalse_decodesFalse() throws {
        let json = """
        {
          "schemaVersion": 1,
          "type": "screenplay",
          "title": "Test",
          "author": "",
          "created": "2026-05-09T12:00:00Z",
          "modified": "2026-05-09T12:00:00Z",
          "structure": [],
          "research": [],
          "showElementGutter": false
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ProjectManifest.self, from: json)
        XCTAssertEqual(manifest.showElementGutter, false)
    }

    @MainActor
    func test_setShowElementGutter_persists() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createScreenplayProject(
            named: "GutterToggle", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        try await store.setShowElementGutter(false)
        XCTAssertEqual(store.manifest.showElementGutter, false)

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(reloaded.manifest.showElementGutter, false)
    }
}
```

- [ ] **Step 2: Add the field to ProjectManifest**

In `Maugham/Models/ProjectManifest.swift`:

Add the property after `typography`:

```swift
    /// Per-project toggle for the element-type gutter (3b). Nil = use default
    /// (show for screenplay projects). Set explicitly to false to hide.
    public var showElementGutter: Bool?
```

Update the `init` to include the new parameter (with default nil):

```swift
    public init(
        schemaVersion: Int = ProjectManifest.currentSchemaVersion,
        type: ProjectType,
        title: String,
        author: String,
        created: Date,
        modified: Date,
        structure: [StructureItem],
        research: [ResearchItem],
        targets: ProjectTargets? = nil,
        typography: TypographySettings? = nil,
        showElementGutter: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.title = title
        self.author = author
        self.created = created
        self.modified = modified
        self.structure = structure
        self.research = research
        self.targets = targets
        self.typography = typography
        self.showElementGutter = showElementGutter
    }
```

- [ ] **Step 3: Add the mutator to ProjectStore**

In `Maugham/Stores/ProjectStore.swift`, after `updateProjectTargets`, add:

```swift
    /// Toggle the per-project element gutter. nil = default (show); false =
    /// hide. The screenplay editor reads this on each layout pass.
    public func setShowElementGutter(_ value: Bool?) async throws {
        manifest.showElementGutter = value
        manifest.modified = Date()
        try await saveManifest()
    }
```

- [ ] **Step 4: Run tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProjectManifestGutterMigrationTests test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed "`

Expected: 3 tests pass.

- [ ] **Step 5: Run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~407 passing (404 + 3).

- [ ] **Step 6: Commit**

```bash
git add Maugham/Models/ProjectManifest.swift Maugham/Stores/ProjectStore.swift MaughamTests/ProjectManifestGutterMigrationTests.swift
git commit -m "feat: ProjectManifest.showElementGutter + ProjectStore mutator

Optional Bool field; nil means use default (show). Manifests written
before 3b decode unchanged. ProjectStore.setShowElementGutter writes
through to manifest and persists.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Project Settings sheet — "Show element gutter" toggle

**Files:**
- Modify: `Maugham/Views/ProjectSettingsSheet.swift`
- Modify: `Maugham/Editor/EditorSurface.swift` (read the toggle when installing the gutter)

Toggle in Project Settings for screenplay projects only. The EditorSurface respects the toggle when deciding whether to install the gutter.

- [ ] **Step 1: Add the toggle to ProjectSettingsSheet**

In `Maugham/Views/ProjectSettingsSheet.swift`, locate the Form's last `Section` (Typography section). Below it, before the closing `Form`, add a new section as a private `@ViewBuilder`:

```swift
    @ViewBuilder
    private func screenplaySection() -> some View {
        if store.manifest.type == .screenplay {
            Section("Screenplay") {
                Toggle("Show element gutter", isOn: Binding(
                    get: { store.manifest.showElementGutter ?? true },
                    set: { newValue in
                        Task { await applyGutterToggle(newValue) }
                    }))
            }
        }
    }

    private func applyGutterToggle(_ newValue: Bool) async {
        // Persist as nil when value matches default (show), else explicit.
        try? await store.setShowElementGutter(newValue ? nil : false)
    }
```

In the Form body, after the existing Typography section, add:

```swift
                screenplaySection()
```

- [ ] **Step 2: Read the toggle in EditorSurface**

In `EditorSurface.swift`, change the gutter installation check. Add a helper:

```swift
    private func shouldShowGutter(store: ProjectStore?) -> Bool {
        guard mode is ScreenplayMode else { return false }
        return store?.manifest.showElementGutter ?? true
    }
```

But EditorSurface doesn't currently have access to `ProjectStore`. The cleanest path is to pass the toggle value as a property on `EditorSurface`:

Add a property:

```swift
    var showElementGutter: Bool = true
```

In `makeNSView`, replace:

```swift
        if mode is ScreenplayMode {
            textView.installGutter(coordinator: context.coordinator)
        }
```

With:

```swift
        if mode is ScreenplayMode && showElementGutter {
            textView.installGutter(coordinator: context.coordinator)
        }
```

In `updateNSView`, replace the mode-change reconciliation block with:

```swift
        let needsGutter = (mode is ScreenplayMode) && showElementGutter
        if needsGutter && textView.gutterView == nil {
            textView.installGutter(coordinator: context.coordinator)
        } else if !needsGutter && textView.gutterView != nil {
            textView.removeGutter()
        }
```

- [ ] **Step 3: Pass the toggle from the parent view**

Find where `EditorSurface` is constructed (likely `EditorHost.swift` or `ProjectWindow.swift`). Pass the toggle:

```swift
EditorSurface(
    text: ...,
    theme: ...,
    typography: ...,
    mode: ...,
    typewriterScroll: ...,
    sentenceFocus: ...,
    paragraphFocus: ...,
    initialCursorLocation: ...,
    onCursorChanged: ...,
    wikiLinkResolver: ...,
    wikiLinkClickResolver: ...,
    showElementGutter: store.manifest.showElementGutter ?? true)
```

(Adapt to the actual EditorSurface call site.)

- [ ] **Step 4: Build + run full suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~407 passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/ProjectSettingsSheet.swift Maugham/Editor/EditorSurface.swift Maugham/Views/EditorHost.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: Project Settings toggle for element gutter visibility

Screenplay projects gain a 'Show element gutter' toggle in Project
Settings. EditorSurface respects the toggle when deciding whether to
install the gutter view.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

(Adjust the `git add` to the actual files modified — likely EditorHost.swift and/or ProjectWindow.swift depending on where the EditorSurface is constructed.)

---

## Task 13: Smoke checklist + tag milestone-3b

**Files:** none directly — manual smoke + tag.

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1`

Expected: ~407 passing.

- [ ] **Step 2: Build and launch**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`

Expected: BUILD SUCCEEDED. Launch via Xcode (⌘R) or `open` the built app.

- [ ] **Step 3: Walk through smoke per spec §8.3**

1. New Screenplay project → empty `.fountain` → hit Tab → line gets `@`; gutter shows `CHAR`.
2. Type `BARRY`, Enter, Tab on blank line → gutter shows `DLG`; line stays empty (Dialogue has no marker).
3. Type `Hello.` → line classifies Dialogue; gutter `DLG`.
4. Enter, Tab → gutter `PAR`; line wraps to `()` with cursor inside; type `quietly`; line is `(quietly)`.
5. Enter twice → blank line → Tab → gutter `CHAR` (cycle from Action).
6. Type `S` → autocomplete popover appears with `BARRY` (and `SAM` if available).
7. Down arrow → selection moves; Enter → line filled with selected name.
8. Escape on popover → dismisses without filling.
9. Shift+Tab on a Parenthetical line → cycles back to Dialogue.
10. Type `> SMASH CUT TO:`, Enter, Tab on blank line → gutter `SCENE`.
11. Toggle "Show element gutter" off in Project Settings → gutter hides.
12. Resize editor pane narrow → gutter shrinks/hides as inset goes below threshold.
13. Switch to a prose document → no gutter shown.
14. Theme switch → gutter abbreviations re-render with new colors.
15. Open the reference fixture screenplay (`MaughamTests/Fixtures/sample-screenplay.fountain`) — every line shows correct gutter label without performance hitches.

- [ ] **Step 4: Fix any visible regressions with `fix:` commits**

For each smoke failure:
- Diagnose using SwiftUI/AppKit lessons banked in the handoff doc
- Commit each fix separately with a `fix:` prefix and a body explaining root cause

- [ ] **Step 5: Merge to main and tag**

```bash
git checkout main
git merge --ff-only feat/milestone-3b

git tag -a milestone-3b -m "Phase 3b complete: Editing UX

Tab/Shift+Tab cycle screenplay elements via Highland-order cycle
with smart context-aware starting points on blank lines and a
context-respecting source mutator (only applies @ for character
when the line wouldn't already classify via ALL CAPS context, etc.).
Character autocomplete via NSPopover sourced from
FountainScript.characterNames. Element gutter shows per-line
abbreviations as feedback (CHAR, DLG, PAR, TRANS, etc.) with a
per-project toggle in Project Settings.

Tests: ~407 passing.
"

git push origin main
git push origin milestone-3b
```

- [ ] **Step 6: Update auto-memory**

Save `project_milestone_3b.md` and add a one-liner to `MEMORY.md`. Note any implementer judgment calls or smoke fixes.

- [ ] **Step 7: Notify the user**

Summarize what shipped and what's next (3c: scene navigator + title page + ⌘? syntax help overlay + inline emphasis).

---

## Self-review checklist (controller runs after writing the plan)

**Spec coverage:** every spec section maps to a task:
- §1 Goals — covered by Tasks 1-12 collectively
- §2 Architecture — Tasks 1-9 instantiate each component
- §3 Tab cycle (order, starting point, mutator, skip-Dialogue) — Tasks 1, 2, 4
- §4 Enter behavior — verified naturally; no special task needed
- §5 Autocomplete (trigger, ranking, popover, keystrokes) — Tasks 5-7
- §6 Element gutter (visual, abbreviations, layout, settings) — Tasks 8-12
- §7 EditorCoordinator changes — Tasks 3, 4, 7
- §8 Testing — Tasks 1, 2, 5, 8, 11 cover unit tests; Task 13 covers smoke
- §9 Risks — addressed inline in task notes
- §10 Sequencing — order matches §10's preview

**Placeholder scan:** searched for "TBD", "TODO", "implement later", "fill in details", "Add appropriate" — none found.

**Type consistency:** verified across tasks:
- `ScreenplayCycle.cycleForward(from:)` / `cycleBackward(from:)` / `startingElement(after:)` — consistent in T1, T4
- `ScreenplayLineMutator.mutate(line:to:neighborhood:)` — T2 defines, T4 uses
- `LineNeighborhood(prevIsBlank:, nextIsBlank:)` — T2 defines, T4 constructs
- `EditorCoordinator.lastParsedScript` — T3 introduces, T4/T7/T8/T9 read
- `EditorCoordinator.lastCycleTarget` — T4 introduces and lifecycles
- `CharacterAutocompleter.rankSuggestions(prefix:characterNames:)` — T5 defines, T7 uses
- `CharacterAutocompleter.show(suggestions:anchorRect:relativeTo:)` — T6 defines, T7 calls
- `ElementGutterView.abbreviation(for:)` — T8 defines, drawn in `draw(_:)`
- `MaughamTextView.installGutter(coordinator:)` / `removeGutter()` — T9 defines, T9/T12 call
- `ProjectManifest.showElementGutter` — T11 adds, T12 reads
- `ProjectStore.setShowElementGutter(_:)` — T11 defines, T12 calls

All consistent.

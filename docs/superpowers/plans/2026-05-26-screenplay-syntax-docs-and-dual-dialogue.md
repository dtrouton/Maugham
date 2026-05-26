# Screenplay Syntax Docs & Dual Dialogue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Document five undocumented Fountain features in the in-app help and ship dual-dialogue parsing + rendering + page-count semantics, using asymmetric offset (stacked + visually offset).

**Architecture:** Single new boolean (`isDualSecond`) on `FountainLine`, propagated by the existing line-by-line tokenizer; deeper paragraph indents on the second block in `ScreenplayMode.attributes(...)`; a separate paired-block adjustment in `FountainScript` so the page-count heuristic treats dual pairs as the height of the longer block. No `NSLayoutManager` / `NSTextStorage` surgery. Docs land in `Maugham/Resources/fountain-syntax.md` (markdown resource consumed by `SyntaxHelpSheet`).

**Tech Stack:** Swift 5 / SwiftUI / AppKit / XCTest. Build via `./gen.sh` + `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`.

**Spec:** `docs/superpowers/specs/2026-05-26-screenplay-syntax-docs-and-dual-dialogue-design.md`

**Worktree:** `/Users/denver/src/Maugham/.claude/worktrees/screenplay-syntax-docs-and-dual-dialogue` on branch `worktree-screenplay-syntax-docs-and-dual-dialogue`. All commands run from there.

---

## File Structure

**Modified:**

- `Maugham/Resources/fountain-syntax.md` — five new sections, two prose touch-ups, one "Not supported" line removed.
- `Maugham/Editor/Fountain/FountainLine.swift` — new `isDualSecond: Bool` field with defaulted init.
- `Maugham/Editor/Fountain/FountainTokenizer.swift` — detect trailing `^`, propagate to following dialogue/parenthetical, surface to call sites.
- `Maugham/Editor/Fountain/FountainScript.swift` — `dialogueBlocks` + `dualPairAdjustment` helpers; integrate into `estimatedPageCount`, `pageNumber(at:)`, `sceneLength(startingAt:)`.
- `Maugham/Editor/ScreenplayMode.swift` — `attributes(for:isDualSecond:...)`, token-walk lookup of `isDualSecond`, marker fade for trailing `^`.
- `MaughamTests/FountainTokenizerTests.swift` — eight new test methods.
- `MaughamTests/FountainScriptPageCountTests.swift` — five new test methods.
- `MaughamTests/FountainScriptPageNumberTests.swift` — two new test methods.
- `MaughamTests/Fountain/FountainScriptSceneLengthTests.swift` — one new test method.
- `MaughamTests/ScreenplayModeStylingTests.swift` — four new test methods (extend the existing file; no new file needed).
- `MaughamTests/Editor/EditorIntegrationHarnessTests.swift` — one new test method.

**Created:**

- `MaughamTests/Fixtures/dual-dialogue.fountain` — small fixture with one solo block, one dual pair, one chain-of-three.

---

## Task 1: Docs Bundle A part 1 — undocumented sections + "Not supported" edit

Pure markdown edit to `Maugham/Resources/fountain-syntax.md`. No Swift changes, no test changes. Lands first because it's the lowest-risk change and writers benefit from the docs immediately. The **dual-dialogue** section is deferred to Task 7 (lands with the feature so the doc never describes shipping behavior that isn't actually shipping yet).

**Files:**
- Modify: `Maugham/Resources/fountain-syntax.md`

- [ ] **Step 1: Add the Title page section**

Insert this block between the existing `## The basics` section (ends at line 25) and the existing `## Elements` heading (line 26). Use the `Edit` tool with the `## Elements` heading as the unique anchor.

```markdown
## Title page

Fountain supports an optional **title page** at the very top of the file — a block of `Key: Value` pairs ending with a blank line. Maugham recognizes the standard keys and renders them with per-key styling above the screenplay body.

```
Title: The Long Goodbye
Credit: Written by
Author: Raymond Chandler
Source: Based on the novel
Draft date: 2026-05-26
Contact:
    Some Agency
    123 Sunset Blvd
    Los Angeles, CA
Notes: First draft
Copyright: © 2026

INT. OFFICE - NIGHT

Marlowe sits at his desk.
```

Recognized keys (case-insensitive): **Title**, **Credit**, **Author** (or **Authors**), **Source**, **Notes**, **Draft date**, **Contact**, **Copyright**.

For the title page to be recognized, **the first non-blank line of the file must match one of these keys**. Otherwise the document has no title page and parsing starts at the body. This strict gate prevents a stray `Foo: bar` opening line from accidentally swallowing your first scene.

**Multi-line values** are continuation-indented by **3 or more spaces, or a tab** (see the `Contact:` example above). A blank line ends the title page; the body begins immediately after.

```

- [ ] **Step 2: Extend the Character section with extensions guidance**

Find the existing `### Character` section (lines 56-74). Append this content immediately before the next `### Dialogue` heading (which begins at line 76).

```markdown

#### Character extensions

The all-caps rule is permissive about non-letter characters — periods, parentheses, digits, and spaces are all ignored. That means **character extensions** (V.O., O.S., O.C., CONT'D, etc.) work as plain Fountain without any special syntax:

```
MARLOWE (V.O.)
The city was hotter than a two-dollar pistol.

JANE (O.S.)
Did you say something?

BOB (CONT'D)
Where was I?
```

Maugham doesn't have a fixed list of extensions — anything that keeps the line all-caps-letters classifies as a character cue. Exotic conventions like `(FILTERED)` or `(ON RADIO)` work too.

**Note:** any lowercase letter anywhere on the line breaks the cue test. `Marlowe (V.O.)` becomes action. Force a lowercase-name cue with the `@` prefix (e.g. `@McTeague`).

```

- [ ] **Step 3: Add the Inline emphasis section**

Insert this block after the existing `### Notes` section (which ends around line 188) and before `## Page count` (which begins at line 189).

```markdown
### Inline emphasis

Within any line, Maugham recognizes:

- `*italic*` — single asterisks around the run.
- `**bold**` — double asterisks around the run.
- `_underline_` — single underscores around the run.

```
She glances at the *worn* photograph, then **slams** the drawer shut.
The sign reads _Closed for inventory_.
```

Markers fade to dim while the inner text renders styled. Emphasis works inside action, dialogue, parenthetical — anywhere there's prose. It does **not** affect line classification (a `**ALL CAPS**` line is still classified by its bracketed content's case).

### Inline task anchors

Wrap a working note in `[[todo: ...]]` or `[[done: ...]]` to track in-line work items:

```
[[todo: rewrite the meet-cute beat]]
[[done: confirmed timeline with director]]
```

Maugham renders the bracket as a clickable checkbox; clicking toggles `todo` ↔ `done`. On first save, an invisible `<!--t-XXXXXX-->` anchor is appended after the closing `]]` — that's how Maugham tracks the task across edits. The anchor is an HTML comment, so the file remains valid Fountain and round-trips cleanly through Highland, Slugline, FountainJS, and any other tool.

Task anchors don't count toward the page count and don't affect element classification.
```

- [ ] **Step 4: Remove the dual-dialogue line from "Not supported"**

Edit `Maugham/Resources/fountain-syntax.md`. Delete the single line at the current line ~206:

```markdown
- **Dual dialogue** (two speakers side-by-side via `^`) — rare in practice, complicates layout, and discourages clean drafting.
```

Use the `Edit` tool with `replace_all: false`; the surrounding bullets provide unique context. Nothing replaces it — the section just gets one bullet shorter.

- [ ] **Step 5: Verify the help sheet still renders by building and running the app**

The doc edits are markdown-only; the parser at `SyntaxHelpSheet.swift:80-156` only handles headings, paragraphs, bullets, and fenced code blocks — all of which the new content uses. But verify quickly with a build:

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

(No new tests yet — pure docs change.)

- [ ] **Step 6: Commit**

```bash
git add Maugham/Resources/fountain-syntax.md
git commit -m "$(cat <<'EOF'
docs(fountain): document title page, character extensions, emphasis, task anchors

Closes four shipped-but-undocumented Fountain features in the in-app
help. Removes the dual-dialogue "Not supported" line in anticipation
of the feature landing in this same milestone. Dual-dialogue's own
help section lands with the feature.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Tokenizer — `isDualSecond` detection + propagation

Add the `isDualSecond` field to `FountainLine`, detect trailing `^` on character cues, propagate the flag to the following dialogue/parenthetical lines until the next blank. All edge cases from the spec covered with tests.

**Files:**
- Modify: `Maugham/Editor/Fountain/FountainLine.swift`
- Modify: `Maugham/Editor/Fountain/FountainTokenizer.swift`
- Modify: `MaughamTests/FountainTokenizerTests.swift`

- [ ] **Step 1: Write all eight failing tokenizer tests**

Append the following test methods to `MaughamTests/FountainTokenizerTests.swift` (after the existing test methods, before the closing `}` of the class):

```swift
    // MARK: - Dual dialogue

    func test_characterCue_trailingCaret_marksIsDualSecond() {
        let script = parser.parse("BRICK\nHi.\n\nSTEVE ^\nHi.")
        // Lines: [BRICK, Hi., blank, STEVE ^, Hi.]
        XCTAssertEqual(script.lines.count, 5)
        XCTAssertEqual(script.lines[0].element, .character)
        XCTAssertFalse(script.lines[0].isDualSecond)
        XCTAssertEqual(script.lines[3].element, .character)
        XCTAssertTrue(script.lines[3].isDualSecond)
    }

    func test_dualSecond_propagatesToFollowingDialogueAndParenthetical() {
        let script = parser.parse("BRICK\nHi.\n\nSTEVE ^\n(quietly)\nHi back.")
        // Lines: [BRICK, Hi., blank, STEVE ^, (quietly), Hi back.]
        XCTAssertEqual(script.lines[3].element, .character)
        XCTAssertTrue(script.lines[3].isDualSecond)
        XCTAssertEqual(script.lines[4].element, .parenthetical)
        XCTAssertTrue(script.lines[4].isDualSecond)
        XCTAssertEqual(script.lines[5].element, .dialogue)
        XCTAssertTrue(script.lines[5].isDualSecond)
    }

    func test_dualSecond_doesNotPropagatePastBlankLine() {
        let script = parser.parse("BRICK\nHi.\n\nSTEVE ^\nHi.\n\nALICE\nCheers.")
        // After the blank line following STEVE's "Hi.", ALICE is a fresh cue.
        XCTAssertEqual(script.lines.count, 8)
        XCTAssertEqual(script.lines[6].element, .character)
        XCTAssertEqual(script.lines[6].content, "ALICE")
        XCTAssertFalse(script.lines[6].isDualSecond)
        XCTAssertEqual(script.lines[7].element, .dialogue)
        XCTAssertFalse(script.lines[7].isDualSecond)
    }

    func test_doubleCaret_treatedAsSingleMarker() {
        // Only the trailing single ^ is consumed; the rest stays in content.
        let script = parser.parse("BRICK\nHi.\n\nSTEVE ^^\nHi.")
        XCTAssertEqual(script.lines[3].element, .character)
        XCTAssertTrue(script.lines[3].isDualSecond)
        // The leading ^ remains in the cue text (content is "STEVE ^").
        XCTAssertEqual(script.lines[3].content, "STEVE ^")
    }

    func test_leadingCaret_notRecognizedAsDualMarker() {
        // ^STEVE has the caret at the start; not the trailing marker.
        let script = parser.parse("BRICK\nHi.\n\n^STEVE\nHi.")
        XCTAssertEqual(script.lines[3].element, .character)
        XCTAssertFalse(script.lines[3].isDualSecond)
    }

    func test_forcedCharacter_withCaret_setsBothFlags() {
        let script = parser.parse("BRICK\nHi.\n\n@steve ^\nHi.")
        XCTAssertEqual(script.lines[3].element, .character)
        XCTAssertTrue(script.lines[3].isForced)
        XCTAssertTrue(script.lines[3].isDualSecond)
    }

    func test_danglingDualSecond_noPriorCue_stillFlagsCue() {
        // Document opens with a ^-marked cue — no prior block.
        // Parser stays permissive; pairing is a page-count concern.
        let script = parser.parse("STEVE ^\nHi.")
        XCTAssertEqual(script.lines[0].element, .character)
        XCTAssertTrue(script.lines[0].isDualSecond)
    }

    func test_caretInActionLine_isNotDualMarker() {
        // Caret in prose action text must not be misinterpreted.
        let script = parser.parse("The cursor ^^ blinks.")
        XCTAssertEqual(script.lines[0].element, .action)
        XCTAssertFalse(script.lines[0].isDualSecond)
    }
```

- [ ] **Step 2: Run tests to verify they fail (RED)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/FountainTokenizerTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30`
Expected: **Compile failure** with errors of the form `value of type 'FountainLine' has no member 'isDualSecond'` — because the field doesn't exist yet. That's the expected RED state for this step.

- [ ] **Step 3: Add `isDualSecond` field to FountainLine**

Edit `Maugham/Editor/Fountain/FountainLine.swift`. Add the new field and update the public init. The full new file contents:

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

    /// True when this line is the `^`-marked second half of a dual-dialogue
    /// pair, OR a dialogue / parenthetical line that follows such a cue in
    /// the same block. The renderer uses this to apply deeper paragraph
    /// indents; the page-count helper uses it to pair adjacent blocks.
    public let isDualSecond: Bool

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
        isDualSecond: Bool = false,
        inlineSpans: [FountainInlineSpan] = []
    ) {
        self.range = range
        self.element = element
        self.content = content
        self.isForced = isForced
        self.sourceCase = sourceCase
        self.isDualSecond = isDualSecond
        self.inlineSpans = inlineSpans
    }
}
```

- [ ] **Step 4: Implement detection + propagation in FountainTokenizer**

Edit `Maugham/Editor/Fountain/FountainTokenizer.swift`. Two changes inside the `parse(_:)` method's main `enumerateSubstrings` block, plus one helper.

**Change A — add a helper above the existing `isAllCapsCueCandidate` (around line 306):**

```swift
    /// Returns (cueText, hasTrailingCaret) — strips a single trailing `^`
    /// (and any spaces immediately before it) when present. The Fountain
    /// dual-dialogue marker is the LAST `^` on the cue line; double-caret
    /// `^^` is treated as one marker + a literal `^` left in the content.
    private static func extractDualMarker(from line: String) -> (cue: String, isDualSecond: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("^") else { return (line, false) }
        // Strip exactly one trailing ^ and any whitespace immediately before it.
        var stripped = String(trimmed.dropLast())
        while stripped.last == " " || stripped.last == "\t" {
            stripped = String(stripped.dropLast())
        }
        return (stripped, true)
    }
```

**Change B — in the `parse(_:)` body, replace the line emission at line 136-142 with a version that calls `extractDualMarker` for character cues and propagates the flag to following dialogue/parenthetical lines.**

Add a `prevWasDualSecond` state variable. Initialize alongside `prevBlank` / `prevElement` at line 25-26:

```swift
        var prevBlank = true
        var prevElement: ScreenplayElement = .action
        var prevWasDualSecond = false
        var blockState: BlockState = .normal
```

Then update the emission at line 136-145. The replacement reads:

```swift
            // Compute isDualSecond for this line.
            var lineIsDualSecond = false
            var emittedContent = classified.content

            if classified.element == .character {
                // Detect trailing ^ on the cue, strip it from content.
                let (strippedCue, isDual) = Self.extractDualMarker(from: classified.content)
                if isDual {
                    lineIsDualSecond = true
                    emittedContent = strippedCue
                }
            } else if classified.element == .dialogue || classified.element == .parenthetical {
                // Inherit from the preceding line's dual-second state.
                lineIsDualSecond = prevWasDualSecond
            }

            lines.append(FountainLine(
                range: enclosingRange,
                element: classified.element,
                content: emittedContent,
                isForced: classified.isForced,
                sourceCase: Self.sourceCase(of: emittedContent),
                isDualSecond: lineIsDualSecond,
                inlineSpans: inlineSpans))
            prevBlank = false
            prevElement = classified.element
            prevWasDualSecond = lineIsDualSecond
```

**Change C — reset `prevWasDualSecond` to `false` everywhere `prevBlank = true` is set** (blank lines must clear the dual-second propagation). There are several blank-handling sites; the canonical one is at line 86-88 of the existing code:

```swift
            if trimmed.isEmpty {
                lines.append(FountainLine(
                    range: enclosingRange,
                    element: .action,
                    content: "",
                    isForced: false,
                    sourceCase: .neutral))
                prevBlank = true
                prevElement = .action
                prevWasDualSecond = false
                return
            }
```

Also reset on boneyard/noteBlock states (lines 60-77) for safety:

```swift
            case .boneyard:
                // ... existing emission ...
                if trimmed.contains("*/") { blockState = .normal }
                prevBlank = false
                prevElement = .boneyard
                prevWasDualSecond = false
                return
            case .noteBlock:
                // ... existing emission ...
                if trimmed.contains("]]") { blockState = .normal }
                prevBlank = false
                prevElement = .note
                prevWasDualSecond = false
                return
```

And on the title-page early return at line 36-46 — no change needed there because title-page lines deliberately don't update `prevBlank`/`prevElement` (per the existing comment at line 34-35), and `prevWasDualSecond` is initialized false at parse start. Leave that path alone.

- [ ] **Step 5: Run tests to verify they pass (GREEN)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/FountainTokenizerTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30`
Expected: All `FountainTokenizerTests` pass, including the 8 new dual-dialogue tests.

If any of the existing FountainTokenizer tests now fail, that's a regression in the propagation logic — likely a missing `prevWasDualSecond = false` reset somewhere. Inspect the failing test's input and trace which blank-handling site is missing the reset.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/Fountain/FountainLine.swift Maugham/Editor/Fountain/FountainTokenizer.swift MaughamTests/FountainTokenizerTests.swift
git commit -m "$(cat <<'EOF'
feat(fountain): parse trailing ^ on cues as dual-dialogue marker

Adds isDualSecond to FountainLine and detection + propagation in the
tokenizer. No renderer or page-count changes yet — those layers land
in the next commits. Eight new tokenizer tests cover the happy path
and the edge cases from the spec (double caret, leading caret, forced
+ caret, dangling cue, caret in action text).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: ScreenplayMode — marker fade for trailing `^`

Extend `markerRanges` in `ScreenplayMode.swift` to surface the trailing `^` (plus any single space immediately before it) for character cues that are `isDualSecond`. The existing pass-3 fade loop (`ScreenplayMode.swift:167-175`) picks it up automatically — no new attribute application code.

**Files:**
- Modify: `Maugham/Editor/ScreenplayMode.swift`
- Modify: `MaughamTests/ScreenplayModeStylingTests.swift`

- [ ] **Step 1: Write the failing rendering test**

Append to `MaughamTests/ScreenplayModeStylingTests.swift` (before the closing `}` of the class). You'll add a helper to access foreground color, then the test:

```swift
    private func foregroundColor(at location: Int, in storage: NSTextStorage) -> NSColor? {
        storage.attributes(at: location, effectiveRange: nil)[.foregroundColor] as? NSColor
    }

    func test_dualSecondCharacter_trailingCaretFadedToSyntaxPunctuation() {
        let storage = style("BRICK\nHi.\n\nSTEVE ^\nHi.")
        // Locate the ^ inside the storage. The string "BRICK\nHi.\n\nSTEVE ^" —
        // the ^ is the LAST character of the "STEVE ^" line.
        let full = storage.string as NSString
        let stevLineStart = full.range(of: "STEVE ^").location
        XCTAssertNotEqual(stevLineStart, NSNotFound)
        let caretLocation = stevLineStart + ("STEVE " as NSString).length
        // Sanity check: the character at caretLocation is "^".
        XCTAssertEqual(full.substring(with: NSRange(location: caretLocation, length: 1)), "^")

        let expectedFade = ResolvedTheme.lightSyntaxPunctuationForTest // see helper below
        let actual = foregroundColor(at: caretLocation, in: storage)
        XCTAssertEqual(actual, expectedFade,
                       "trailing ^ on dual-second cue should fade to syntaxPunctuation color")
    }
```

You'll need the test fade-color helper. Add it as a fileprivate extension at the bottom of `MaughamTests/ScreenplayModeStylingTests.swift`:

```swift
// Test helper: exposes the resolved syntaxPunctuation color for the .light theme
// at the same code path the renderer uses. Kept private to this file so it
// doesn't bleed into other test files.
fileprivate enum ResolvedTheme {
    static var lightSyntaxPunctuationForTest: NSColor {
        Theme.light.resolved(systemAppearanceIsDark: false).palette.syntaxPunctuation
    }
}
```

(If the existing styling tests already use this color in another test, mirror that helper instead — keep one canonical access pattern in this file.)

- [ ] **Step 2: Run the test to verify it fails (RED)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayModeStylingTests/test_dualSecondCharacter_trailingCaretFadedToSyntaxPunctuation CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25`
Expected: FAIL — the `^` currently renders with the character cue's foreground color, not the dim syntaxPunctuation.

- [ ] **Step 3: Extend `markerRanges` to recognize trailing `^`**

In `Maugham/Editor/ScreenplayMode.swift`, find `markerRanges(in:storage:)` (currently at lines 496-615). Inside the `if line.isForced { switch line.element { case .character: ... }` block (around lines 517-520), the existing logic handles the leading `@`. We need to add a parallel block, OUTSIDE the `isForced` guard, that fades the trailing `^` on any dual-second character cue (forced or not).

Add this code immediately AFTER the closing `}` of the `if line.isForced { switch ... }` block (after line 544) and BEFORE the section-handling block (around line 546):

```swift
        // Trailing ^ marker for dual-dialogue second cue. Fades the ^ and any
        // single space immediately before it. Applies to both forced (@steve ^)
        // and unforced (STEVE ^) cues.
        if line.element == .character && line.isDualSecond {
            // Search for the LAST ^ in the trimmed line text, then map back
            // to the line range in storage.
            if let caretIdx = trimmed.lastIndex(of: "^") {
                let caretOffset = trimmed.distance(from: trimmed.startIndex, to: caretIdx)
                let caretNSLocation = lineStart + caretOffset
                // Include a single trailing space before the ^ in the fade range.
                let includeSpace = caretOffset > 0
                    && trimmed[trimmed.index(before: caretIdx)] == " "
                let fadeStart = caretNSLocation - (includeSpace ? 1 : 0)
                let fadeLength = 1 + (includeSpace ? 1 : 0)
                ranges.append(NSRange(location: fadeStart, length: fadeLength))
            }
        }
```

- [ ] **Step 4: Run the test to verify it passes (GREEN)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayModeStylingTests/test_dualSecondCharacter_trailingCaretFadedToSyntaxPunctuation CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: Run all ScreenplayMode tests to check for regressions**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayModeStylingTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: All ScreenplayMode tests pass. If anything regressed, the marker-fade range is probably overlapping an existing marker range; inspect the failing test for hints.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/ScreenplayMode.swift MaughamTests/ScreenplayModeStylingTests.swift
git commit -m "$(cat <<'EOF'
feat(screenplay): fade trailing ^ on dual-second character cues

Extends markerRanges to surface the dual-dialogue ^ marker (plus its
preceding space) so the existing forced-syntax fade pass dims it to
the palette's syntaxPunctuation color, matching @ / . / > / ~ etc.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: ScreenplayMode — dual-second paragraph styles

Add the `isDualSecond` parameter to `attributes(for:...)` with new indent values for character, dialogue, and parenthetical. Update the token-walk in `applyTypography` to look up `isDualSecond` from the already-parsed script.

**Files:**
- Modify: `Maugham/Editor/ScreenplayMode.swift`
- Modify: `MaughamTests/ScreenplayModeStylingTests.swift`

- [ ] **Step 1: Write three failing paragraph-style tests**

Append to `MaughamTests/ScreenplayModeStylingTests.swift`:

```swift
    func test_dualSecondCharacter_paragraphStyle_hasOffsetHead() {
        let storage = style("BRICK\nHi.\n\nSTEVE ^\nHi.")
        let charWidth = ScreenplayModeStylingTests.charWidth(typography: .screenplayDefaults)
        // STEVE ^ cue starts after "BRICK\nHi.\n\n" (12 UTF-16 units).
        let stevLoc = ("BRICK\nHi.\n\n" as NSString).length
        let style = paragraphStyle(at: stevLoc, in: storage)
        XCTAssertEqual(style?.firstLineHeadIndent ?? 0, charWidth * 42, accuracy: 1.0)
        XCTAssertEqual(style?.headIndent ?? 0, charWidth * 42, accuracy: 1.0)
        XCTAssertEqual(style?.tailIndent ?? 0, charWidth * 60, accuracy: 1.0)
    }

    func test_dualSecondDialogue_paragraphStyle_hasNarrowerColumn() {
        let storage = style("BRICK\nHi.\n\nSTEVE ^\nHi back.")
        let charWidth = ScreenplayModeStylingTests.charWidth(typography: .screenplayDefaults)
        // Dialogue after STEVE: "BRICK\nHi.\n\nSTEVE ^\n" prefix length.
        let dialogueLoc = ("BRICK\nHi.\n\nSTEVE ^\n" as NSString).length
        let style = paragraphStyle(at: dialogueLoc, in: storage)
        XCTAssertEqual(style?.firstLineHeadIndent ?? 0, charWidth * 32, accuracy: 1.0)
        XCTAssertEqual(style?.tailIndent ?? 0, charWidth * 58, accuracy: 1.0)
    }

    func test_dualSecondParenthetical_paragraphStyle_hasNarrowerColumn() {
        let storage = style("BRICK\nHi.\n\nSTEVE ^\n(quietly)\nHi back.")
        let charWidth = ScreenplayModeStylingTests.charWidth(typography: .screenplayDefaults)
        // Parenthetical after STEVE: "BRICK\nHi.\n\nSTEVE ^\n" prefix length.
        let parenLoc = ("BRICK\nHi.\n\nSTEVE ^\n" as NSString).length
        let style = paragraphStyle(at: parenLoc, in: storage)
        XCTAssertEqual(style?.firstLineHeadIndent ?? 0, charWidth * 37, accuracy: 1.0)
        XCTAssertEqual(style?.tailIndent ?? 0, charWidth * 53, accuracy: 1.0)
    }

    func test_normalDialogue_afterDualPair_paragraphStyleUnchanged() {
        // Regression: a normal cue after a dual pair must NOT inherit offset.
        let storage = style("BRICK\nHi.\n\nSTEVE ^\nHi back.\n\nALICE\nCheers.")
        let charWidth = ScreenplayModeStylingTests.charWidth(typography: .screenplayDefaults)
        let aliceDialogueLoc = ("BRICK\nHi.\n\nSTEVE ^\nHi back.\n\nALICE\n" as NSString).length
        let style = paragraphStyle(at: aliceDialogueLoc, in: storage)
        XCTAssertEqual(style?.firstLineHeadIndent ?? 0, charWidth * 10, accuracy: 1.0,
                       "ALICE's dialogue must use normal dialogue indent (10ch), not dual-second (32ch)")
    }
```

- [ ] **Step 2: Run tests to verify they fail (RED)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayModeStylingTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30`
Expected: The four new tests FAIL with `firstLineHeadIndent` mismatches — dual-second lines currently render at the normal 22/10/15 head positions. The `test_normalDialogue_afterDualPair_paragraphStyleUnchanged` test may currently PASS (regression net for later).

- [ ] **Step 3: Add `isDualSecond` parameter to `attributes(for:...)`**

In `Maugham/Editor/ScreenplayMode.swift`, modify the `attributes(for:palette:baseFont:charWidth:typography:)` method (lines 294-380). The new signature:

```swift
    private func attributes(
        for element: ScreenplayElement,
        isDualSecond: Bool,
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
            let head: CGFloat = isDualSecond ? charWidth * 42 : charWidth * 22
            let tail: CGFloat = charWidth * 60
            return [.paragraphStyle: paragraphStyle(
                head: head, tail: tail,
                alignment: .left, typography: typography, baseFont: baseFont)]
        case .dialogue:
            let head: CGFloat = isDualSecond ? charWidth * 32 : charWidth * 10
            let tail: CGFloat = isDualSecond ? charWidth * 58 : charWidth * 45
            return [.paragraphStyle: paragraphStyle(
                head: head, tail: tail,
                alignment: .left, typography: typography, baseFont: baseFont)]
        case .parenthetical:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            let head: CGFloat = isDualSecond ? charWidth * 37 : charWidth * 15
            let tail: CGFloat = isDualSecond ? charWidth * 53 : charWidth * 35
            return [
                .paragraphStyle: paragraphStyle(
                    head: head, tail: tail,
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
                .foregroundColor: dim(palette.syntaxPunctuation, alpha: 0.6)]
        case .boneyard, .note:
            let italic = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic),
                size: baseFont.pointSize) ?? baseFont
            return [
                .font: italic,
                .foregroundColor: dim(palette.syntaxPunctuation, alpha: 0.4)]
        case .pageBreak:
            return [
                .paragraphStyle: paragraphStyle(
                    head: 0, tail: charWidth * 60,
                    alignment: .center, typography: typography, baseFont: baseFont),
                .foregroundColor: dim(palette.syntaxPunctuation, alpha: 0.4)]
        case .titlePage:
            return [
                .foregroundColor: dim(palette.syntaxPunctuation, alpha: 0.4)]
        }
    }
```

- [ ] **Step 4: Update the token-walk in `applyTypography` to pass `isDualSecond`**

In `Maugham/Editor/ScreenplayMode.swift`, find the loop at lines 120-149 (the per-token attribute pass). The current code at lines 122-132 destructures `.fountainElement(element, _)` and calls `attributes(for:palette:...)`. Update it to look up the matching FountainLine from `script` and pass `isDualSecond`:

```swift
        // First pass — per-line element styling driven by tokens.
        var isFirstBody = true

        for token in tokens {
            guard NSMaxRange(token.range) <= storage.length else { continue }
            guard case let .fountainElement(element, _) = token.kind else { continue }

            // Skip titlePage elements (handled by applyTitlePageStyling).
            if case .titlePage = element { continue }

            // Look up isDualSecond from the parsed script by range match.
            let isDualSecond = script.lines.first(where: {
                $0.range.location == token.range.location
            })?.isDualSecond ?? false

            var attrs = self.attributes(
                for: element,
                isDualSecond: isDualSecond,
                palette: palette,
                baseFont: baseFont,
                charWidth: charWidth,
                typography: typography)

            // Add paragraph spacing before the first body element when there's
            // a title page above.
            if hasTitlePage && isFirstBody {
                let mutable: NSMutableParagraphStyle
                if let existing = attrs[.paragraphStyle] as? NSParagraphStyle {
                    mutable = (existing.mutableCopy() as! NSMutableParagraphStyle)
                } else {
                    mutable = NSMutableParagraphStyle()
                }
                mutable.paragraphSpacingBefore = baseFont.pointSize * 2.0
                attrs[.paragraphStyle] = mutable
                isFirstBody = false
            }

            storage.addAttributes(attrs, range: token.range)
        }
```

- [ ] **Step 5: Run tests to verify they pass (GREEN)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/ScreenplayModeStylingTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: All ScreenplayMode tests pass, including the 4 new dual-second + regression tests.

- [ ] **Step 6: Run the full screenplay test suite to check for regressions**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/FountainTokenizerTests -only-testing:MaughamTests/ScreenplayModeStylingTests -only-testing:MaughamTests/ScreenplayModeTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: All pass.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Editor/ScreenplayMode.swift MaughamTests/ScreenplayModeStylingTests.swift
git commit -m "$(cat <<'EOF'
feat(screenplay): render dual-second blocks with deeper paragraph indents

Character: head 22→42 (18ch name space).
Dialogue: head 10→32, tail 45→58 (26ch column).
Parenthetical: head 15→37, tail 35→53 (16ch column).

The token-walk in applyTypography looks up isDualSecond from the
already-parsed FountainScript by range match — keeps Token.Kind
prose-mode-friendly (no new associated value).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: FountainScript — dual-pair page-count adjustment

Add the `dialogueBlocks` and `dualPairAdjustment` helpers; integrate into `estimatedPageCount`, `pageNumber(at:)`, and `sceneLength(startingAt:)`.

**Files:**
- Modify: `Maugham/Editor/Fountain/FountainScript.swift`
- Modify: `MaughamTests/FountainScriptPageCountTests.swift`
- Modify: `MaughamTests/FountainScriptPageNumberTests.swift`
- Modify: `MaughamTests/Fountain/FountainScriptSceneLengthTests.swift`

- [ ] **Step 1: Write failing page-count tests**

Append to `MaughamTests/FountainScriptPageCountTests.swift`. The existing tests show the import + class shape; mirror them.

```swift
    // MARK: - Dual dialogue

    private let parser = FountainTokenizer()

    func test_dualPair_countsAsMaxNotSum() {
        // First block: BRICK + 3 lines of dialogue = 4 lines.
        // Second block: STEVE ^ + 1 line of dialogue = 2 lines.
        // Raw = 4 + 2 = 6. Adjustment = min(4,2) = 2. Net = 4.
        let source = """
        BRICK
        Line one of long dialogue here.
        Line two of long dialogue here.
        Line three of long dialogue here.

        STEVE ^
        Hi.
        """
        let script = parser.parse(source)
        // 55 lines per page; 4 lines / 55 ≈ 0.0727
        XCTAssertEqual(script.estimatedPageCount, 4.0 / 55.0, accuracy: 0.001)
    }

    func test_multipleDualPairs_accumulate() {
        // Two dual pairs separated by action.
        let source = """
        A
        Hello.

        B ^
        Hi.

        Some action here.

        C
        Bye.

        D ^
        Bye.
        """
        let script = parser.parse(source)
        // Pair 1: A+dialogue (2 lines) | B+dialogue (2 lines). max=2. saved=2.
        // Action: 1 line.
        // Pair 2: C+dialogue (2 lines) | D+dialogue (2 lines). max=2. saved=2.
        // Raw: 2+2+1+2+2 = 9. Adjustment: 2+2 = 4. Net: 5.
        XCTAssertEqual(script.estimatedPageCount, 5.0 / 55.0, accuracy: 0.001)
    }

    func test_soloDialogue_unchanged() {
        // Regression: no ^ markers means no adjustment.
        let source = """
        BRICK
        Hello.

        STEVE
        Hi.
        """
        let script = parser.parse(source)
        // Raw: BRICK(1) + dialogue(1) + STEVE(1) + dialogue(1) = 4. No adjustment.
        XCTAssertEqual(script.estimatedPageCount, 4.0 / 55.0, accuracy: 0.001)
    }

    func test_danglingDualSecond_noAdjustment() {
        // ^-marked cue with no preceding cue — no pair formed.
        let source = """
        STEVE ^
        Hi.
        """
        let script = parser.parse(source)
        XCTAssertEqual(script.estimatedPageCount, 2.0 / 55.0, accuracy: 0.001)
    }

    func test_chainOfThreeCues_greedyPairing() {
        // Cue 1 (no ^), Cue 2 (^), Cue 3 (^).
        // Greedy pairing: (cue1, cue2) form a pair. Cue 3 stands alone.
        let source = """
        A
        Hello.

        B ^
        Hi.

        C ^
        Bye.
        """
        let script = parser.parse(source)
        // Block A: 2 lines. Block B: 2 lines. Block C: 2 lines.
        // Pair (A,B): adjustment min(2,2)=2. Block C: solo, no adjustment.
        // Raw: 2+2+2 = 6. Adjustment: 2. Net: 4.
        XCTAssertEqual(script.estimatedPageCount, 4.0 / 55.0, accuracy: 0.001)
    }
```

Append to `MaughamTests/FountainScriptPageNumberTests.swift`:

```swift
    func test_pageNumber_beforePair_unaffected() {
        // Manufacture a long pre-pair section to force the next page boundary
        // to fall AFTER the dual pair.
        var source = ""
        for _ in 0..<60 {
            source += "An action line that wraps somewhere in the middle.\n\n"
        }
        let preCueIndex = source.count
        source += """
        BRICK
        Hi.

        STEVE ^
        Hi.
        """
        let script = parser.parse(source)
        // Find the line that starts at preCueIndex (BRICK cue).
        guard let brick = script.lines.first(where: { $0.range.location == preCueIndex }) else {
            XCTFail("BRICK line not found"); return
        }
        // BRICK is BEFORE any pair closes — page number unchanged by adjustment.
        // The first 60 action lines = 60 lines / 55 lines per page ≈ page 2.
        XCTAssertEqual(script.pageNumber(at: brick), 2)
    }

    func test_pageNumber_afterPair_appliesAdjustment() {
        // Pair (3-line first, 1-line second). After the pair closes, the
        // next cue's page number is computed using the adjusted total.
        let source = """
        BRICK
        Line one.
        Line two.
        Line three.

        STEVE ^
        Hi.

        ALICE
        Cheers.
        """
        let script = parser.parse(source)
        guard let alice = script.lines.first(where: {
            $0.element == .character && $0.content == "ALICE"
        }) else {
            XCTFail("ALICE cue not found"); return
        }
        // BRICK block: 4 lines. STEVE block: 2 lines.
        // Raw before ALICE: 4+2 = 6. Adjustment: min(4,2)=2. Net: 4 → page 1.
        XCTAssertEqual(script.pageNumber(at: alice), 1)
    }
```

Append to `MaughamTests/Fountain/FountainScriptSceneLengthTests.swift`:

```swift
    func test_sceneLength_includesDualPairAdjustment() {
        let parser = FountainTokenizer()
        let source = """
        INT. BAR - NIGHT

        BRICK
        Long line one here that wraps.
        Long line two here that wraps.
        Long line three here that wraps.

        STEVE ^
        Hi.
        """
        let script = parser.parse(source)
        guard let scene = script.lines.first(where: {
            $0.element == .sceneHeading
        }) else {
            XCTFail("Scene heading not found"); return
        }
        // Scene heading: 2 lines. BRICK block: 4. STEVE block: 2.
        // Raw: 2+4+2 = 8. Adjustment: min(4,2)=2. Net: 6.
        XCTAssertEqual(script.sceneLength(startingAt: scene),
                       6.0 / 55.0, accuracy: 0.001)
    }
```

- [ ] **Step 2: Run tests to verify they fail (RED)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/FountainScriptPageCountTests -only-testing:MaughamTests/FountainScriptPageNumberTests -only-testing:MaughamTests/FountainScriptSceneLengthTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25`
Expected: New tests FAIL — page counts/numbers are currently the un-adjusted (over-)totals.

- [ ] **Step 3: Add the helpers and integrate into the three call sites**

Edit `Maugham/Editor/Fountain/FountainScript.swift`. Replace the file contents with:

```swift
import Foundation

/// A fully parsed Fountain document. Pure value type with computed metrics.
public struct FountainScript: Equatable, Sendable {
    public let lines: [FountainLine]
    public let titlePage: [TitlePageField]?

    public init(lines: [FountainLine] = [], titlePage: [TitlePageField]? = nil) {
        self.lines = lines
        self.titlePage = titlePage
    }

    public static let empty = FountainScript()

    /// Estimated page count using the Final Draft line-wrap heuristic.
    /// 60-char action lines, 35-char dialogue, 20-char parenthetical, 55 lines per page.
    /// Sections, synopses, boneyard, notes, and page breaks are excluded (working-doc metadata).
    /// Scene headings count as 2 lines (heading + implicit blank above).
    /// Dual-dialogue pairs count as the height of the LONGER block, not the sum,
    /// because side-by-side rendering in print shares a vertical band.
    public var estimatedPageCount: Double {
        let linesPerPage = 55
        let rawTotal = lines.reduce(0) { $0 + Self.lineCount(for: $1) }
        let adjustment = Self.dualPairAdjustment(lines: lines)
        return Double(max(0, rawTotal - adjustment)) / Double(linesPerPage)
    }

    /// 1-indexed page number where the given line begins. Walks lines from
    /// start, accumulating per-line line counts via the same heuristic as
    /// estimatedPageCount, and subtracting dual-pair adjustments for any
    /// pair whose second block closed strictly BEFORE the target line.
    public func pageNumber(at line: FountainLine) -> Int {
        let linesPerPage = 55
        var totalLines = 0
        var adjustmentAccrued = 0
        // Track pair-pending state in a single pass.
        var previousBlockLines: Int? = nil
        var currentBlockLines: Int? = nil
        var currentBlockIsDualSecond = false

        for candidate in lines {
            if candidate.range.location == line.range.location {
                // Finalize any in-flight pair before computing return value.
                if let prev = previousBlockLines, let cur = currentBlockLines,
                   currentBlockIsDualSecond {
                    adjustmentAccrued += min(prev, cur)
                }
                let adjusted = max(0, totalLines - adjustmentAccrued)
                return (adjusted / linesPerPage) + 1
            }

            let candidateCount = Self.lineCount(for: candidate)
            totalLines += candidateCount

            switch candidate.element {
            case .character:
                // Closing prior block(s).
                if let prev = previousBlockLines, let cur = currentBlockLines,
                   currentBlockIsDualSecond {
                    adjustmentAccrued += min(prev, cur)
                    previousBlockLines = nil
                    currentBlockLines = nil
                    currentBlockIsDualSecond = false
                }
                // Promote in-flight block, then start fresh.
                if currentBlockLines != nil {
                    previousBlockLines = currentBlockLines
                }
                currentBlockLines = candidateCount
                currentBlockIsDualSecond = candidate.isDualSecond
            case .dialogue, .parenthetical:
                currentBlockLines = (currentBlockLines ?? 0) + candidateCount
            default:
                // Block boundary. Settle any pair.
                if let prev = previousBlockLines, let cur = currentBlockLines,
                   currentBlockIsDualSecond {
                    adjustmentAccrued += min(prev, cur)
                }
                // After any non-dialogue/non-character line, drop the
                // pending blocks — a non-dialogue line cannot be the
                // first half of a dual pair.
                previousBlockLines = nil
                currentBlockLines = nil
                currentBlockIsDualSecond = false
            }
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

    /// Groups consecutive character + dialogue/parenthetical lines into blocks,
    /// preserving each block's isDualSecond flag (derived from its character cue).
    private static func dialogueBlocks(
        in lines: [FountainLine]
    ) -> [(linesInBlock: [FountainLine], isDualSecond: Bool)] {
        var blocks: [(linesInBlock: [FountainLine], isDualSecond: Bool)] = []
        var current: [FountainLine] = []
        var currentIsDualSecond = false

        func flush() {
            if !current.isEmpty {
                blocks.append((current, currentIsDualSecond))
            }
            current = []
            currentIsDualSecond = false
        }

        for line in lines {
            switch line.element {
            case .character:
                flush()
                current.append(line)
                currentIsDualSecond = line.isDualSecond
            case .dialogue, .parenthetical:
                if !current.isEmpty {
                    current.append(line)
                }
            default:
                flush()
            }
        }
        flush()
        return blocks
    }

    /// Sum of lines saved by treating each (firstBlock, dualSecondBlock) pair
    /// as max(first, second) instead of first+second. Walks blocks in order;
    /// when block i+1 is isDualSecond, blocks i and i+1 form a pair.
    /// Greedy two-at-a-time pairing — for a chain (A, B^, C^), pairs (A,B),
    /// leaves C solo. Documented limitation; chain-of-three is exotic.
    private static func dualPairAdjustment(lines: [FountainLine]) -> Int {
        let blocks = dialogueBlocks(in: lines)
        var adjustment = 0
        var i = 0
        while i < blocks.count - 1 {
            if blocks[i + 1].isDualSecond {
                let firstLines = blocks[i].linesInBlock.reduce(0) {
                    $0 + lineCount(for: $1)
                }
                let secondLines = blocks[i + 1].linesInBlock.reduce(0) {
                    $0 + lineCount(for: $1)
                }
                adjustment += min(firstLines, secondLines)
                i += 2
            } else {
                i += 1
            }
        }
        return adjustment
    }

    /// Distinct uppercased character names mentioned in the script. Populated
    /// from `.character` lines; used by 3b autocomplete.
    public var characterNames: Set<String> {
        Set(lines.compactMap { line in
            guard line.element == .character,
                  !line.content.isEmpty else { return nil }
            return line.content.uppercased()
        })
    }

    /// Estimated length of the scene starting at `line` in pages (fractional).
    /// Walks from `line` until the next sceneHeading (or end of script),
    /// summing line counts and applying dual-pair adjustment within the scene.
    public func sceneLength(startingAt line: FountainLine) -> Double {
        let linesPerPage = 55
        var sceneLines: [FountainLine] = []
        var insideTarget = false
        for candidate in lines {
            if candidate.range.location == line.range.location {
                insideTarget = true
                sceneLines.append(candidate)
                continue
            }
            if insideTarget {
                if candidate.element == .sceneHeading {
                    break
                }
                sceneLines.append(candidate)
            }
        }
        let rawTotal = sceneLines.reduce(0) { $0 + Self.lineCount(for: $1) }
        let adjustment = Self.dualPairAdjustment(lines: sceneLines)
        return Double(max(0, rawTotal - adjustment)) / Double(linesPerPage)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass (GREEN)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/FountainScriptPageCountTests -only-testing:MaughamTests/FountainScriptPageNumberTests -only-testing:MaughamTests/FountainScriptSceneLengthTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: All page-count tests pass, including the new dual-pair tests.

- [ ] **Step 5: Run the full Fountain test suite to check for regressions**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/FountainTokenizerTests -only-testing:MaughamTests/FountainScriptPageCountTests -only-testing:MaughamTests/FountainScriptPageNumberTests -only-testing:MaughamTests/FountainScriptSceneLengthTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Editor/Fountain/FountainScript.swift MaughamTests/FountainScriptPageCountTests.swift MaughamTests/FountainScriptPageNumberTests.swift MaughamTests/Fountain/FountainScriptSceneLengthTests.swift
git commit -m "$(cat <<'EOF'
feat(fountain): treat dual pairs as max-of-pair in page-count heuristic

Adds dialogueBlocks + dualPairAdjustment helpers and threads them
through estimatedPageCount, pageNumber(at:), and sceneLength(startingAt:).
Greedy two-at-a-time pairing; chain-of-three pairs first two, leaves
the third solo. Page-count semantics now match Final Draft for dual
dialogue.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Integration test — binding-contract regression net

Add one test in `EditorIntegrationHarnessTests.swift` proving that typing `^` into a character cue does NOT fire `applyExternalText`. Per Editor AREA.md, every new screenplay-mode authoring path must add this assertion.

**Files:**
- Modify: `MaughamTests/Editor/EditorIntegrationHarnessTests.swift`

- [ ] **Step 1: Locate the existing integration test for shape reference**

Run: `grep -n "test_endOfFileTyping_doesNotFireApplyExternalText\|EditorIntegrationHarness" MaughamTests/Editor/EditorIntegrationHarnessTests.swift | head -10`
Expected: shows the existing test method signature + how the harness is constructed.

- [ ] **Step 2: Write the failing/passing test (this test passes immediately if the binding contract is intact)**

Append to `MaughamTests/Editor/EditorIntegrationHarnessTests.swift` (before the closing `}` of the class). Mirror the shape of `test_endOfFileTyping_doesNotFireApplyExternalText`:

```swift
    func test_typingCaretIntoCharacterCue_doesNotFireApplyExternalText() async throws {
        // Start a screenplay document with an existing first block; then
        // simulate typing a second character cue ending in `^`. The binding
        // contract requires that none of this typing path triggers
        // applyExternalText — that path is reserved for cloud-conflict
        // resolution only.
        let harness = try await EditorIntegrationHarness.makeScreenplay(
            initialText: "BRICK\nHello.\n\n")

        try await harness.assertNoApplyExternalText {
            // Type "STEVE " then "^" then "\nHi." one character at a time.
            for ch in "STEVE ^\nHi." {
                try await harness.typeCharacter(String(ch))
            }
        }
    }
```

If the harness API surface uses different method names (`makeScreenplay`, `typeCharacter`, `assertNoApplyExternalText`), inspect the existing test and adjust signatures to match. The contract — wrap typing in `assertNoApplyExternalText { ... }` — is the invariant.

- [ ] **Step 3: Run the test**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing:MaughamTests/Editor/EditorIntegrationHarnessTests/test_typingCaretIntoCharacterCue_doesNotFireApplyExternalText CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: PASS. If it FAILS with `applyExternalTextCallCount > 0`, that's a real regression — some path in the tokenizer or renderer is roundtripping back through `applyExternalText` (probably via the binding setter writing twice). Investigate before continuing.

- [ ] **Step 4: Commit**

```bash
git add MaughamTests/Editor/EditorIntegrationHarnessTests.swift
git commit -m "$(cat <<'EOF'
test(editor): typing ^ into character cue stays inside binding contract

Regression net per Editor AREA.md: every new screenplay-mode authoring
path must assert applyExternalText doesn't fire during typing. Dual-
dialogue cue entry is a new path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Docs Bundle A part 2 — Dual dialogue section + prose tweaks

Now that the feature ships, document it. Lands here so the help doc never describes shipping behavior that isn't actually shipping yet.

**Files:**
- Modify: `Maugham/Resources/fountain-syntax.md`

- [ ] **Step 1: Add the Dual dialogue section**

In `Maugham/Resources/fountain-syntax.md`, find the `### Parenthetical` section. Insert this content immediately AFTER that section ends and BEFORE the `### Transition` section.

```markdown
### Dual dialogue

For simultaneous speech — two characters talking at once, or interrupting each other — add a trailing `^` to the **second** character cue. The pair renders stacked in the editor, with the `^`-marked block offset visually to the right:

```
BRICK
Screw retirement.

STEVE ^
Screw retirement.
```

The `^` itself fades to dim, like other forced-syntax markers. Page count treats the pair as the height of the longer block (Final Draft semantics), not the sum — so a dual pair won't inflate your page count.

**Asymmetric layout.** Maugham renders dual dialogue as **stacked + visually offset** rather than true side-by-side columns. The first block sits at the normal cue position; the second block is pushed right. The on-disk `.fountain` file is standard Fountain — opens correctly in Highland, Slugline, FountainJS, and other tools that may render true columns. A future print/PDF export milestone may upgrade Maugham's on-screen layout to true columns too.

**Pairing.** Maugham pairs blocks two-at-a-time, greedily. A chain like `A`, `B^`, `C^` pairs (A,B) and leaves C standing alone. Multi-speaker chains are exotic; if you actually need them, file an issue.
```

- [ ] **Step 2: Touch up the "Layout follows the Cole & Haag" paragraph**

In `Maugham/Resources/fountain-syntax.md`, find line ~5 (the paragraph beginning "The underlying parser is `FountainTokenizer.swift`."). Append the following sentence to that paragraph:

```markdown
 Dual-dialogue second blocks render with deeper indents to mark the simultaneous-speech pair visually.
```

(Single-sentence append; preserve the existing paragraph wording.)

- [ ] **Step 3: Touch up the Page count paragraph**

In `Maugham/Resources/fountain-syntax.md`, find the existing `## Page count` section (around line 189). Append the following sentence to the *first* paragraph of that section (the one that describes the 55-lines-per-page heuristic):

```markdown
 Dual-dialogue pairs count as the height of the longer block (matching Final Draft's side-by-side semantics), not the sum.
```

- [ ] **Step 4: Verify the help sheet still renders**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Maugham/Resources/fountain-syntax.md
git commit -m "$(cat <<'EOF'
docs(fountain): document dual dialogue + page-count + layout caveats

Closes the docs side of dual dialogue: new ### Dual dialogue section,
plus single-sentence appends to the Layout intro and the Page count
explainer. Frames the asymmetric-offset rendering as Maugham-specific
and points writers at Highland/Slugline for true-columns rendering.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Manual smoke + finalize

**Files:**
- None modified.

- [ ] **Step 1: Run the full test suite one more time**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: All tests pass. Existing test count was 873 before this milestone; expect roughly 873 + 19 new = 892 tests passing.

If anything fails, fix before continuing. Do NOT commit a "tests skipped" placeholder.

- [ ] **Step 2: Build the app in Debug for manual smoke**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Hand off to user for manual smoke test**

Report to user:

> All 892 tests passing. Built clean. Ready for manual smoke:
>
> 1. Launch the Debug build (Xcode → Run, or `open build/Debug/Maugham.app` from this worktree).
> 2. New project → Screenplay → "Smoke".
> 3. Type:
>    ```
>    BRICK
>    Screw retirement.
>
>    STEVE ^
>    Screw retirement.
>    ```
> 4. Confirm:
>    - The `^` renders faded (dim color), not bold.
>    - The STEVE cue and its dialogue sit visibly further right than BRICK's.
>    - Inspector page count is sensible (not inflated by the second block).
>    - ⌘/ → Fountain tab → scroll to find the new Dual dialogue section, the Title page section, Character extensions, Inline emphasis, Inline task anchors.
> 5. ⌘Q. Relaunch. Open Smoke from Recents. Confirm still rendered correctly.
>
> Report any visual oddities — especially around indent values feeling too tight or the `^` fade overlapping other markers.

- [ ] **Step 4: Once user confirms smoke passes, ready for merge**

The branch `worktree-screenplay-syntax-docs-and-dual-dialogue` is ready. From the worktree:

```bash
git log --oneline main..HEAD
```

Expected: 6 new commits ahead of `main` (Task 1, 2, 3, 4, 5, 6, 7 commits = 7 commits, since the spec commit `bc7228c`/`fb5207c` was already on the branch from setup). Actually verify: cherry-picked spec + 7 task commits = 8 ahead of origin/main. (Local main has the spec at bc7228c so ahead-of-local-main = 7.)

Decision point — finishing-a-development-branch skill kicks in here. The user picks: merge to main, open a PR, or hand off for review.

Cut a release when this lands:

1. Write `docs/release-notes/v0.X.Y.md` (template at `docs/release-notes/_template.md`).
2. `./scripts/cut-release.sh 0.X.Y`.
3. `git push --tags`.

Version number `0.X.Y` is decided at tag time per CLAUDE.md Releases section — don't bump `project.yml`.

---

## Self-review notes

Spec coverage verified against `docs/superpowers/specs/2026-05-26-screenplay-syntax-docs-and-dual-dialogue-design.md`:

- ✅ Title page section (Task 1)
- ✅ Character extensions (Task 1)
- ✅ Inline emphasis (Task 1)
- ✅ Inline task anchors (Task 1)
- ✅ Remove dual-dialogue from "Not supported" (Task 1)
- ✅ Dual dialogue section + prose tweaks (Task 7, deferred for honesty)
- ✅ `isDualSecond` field on FountainLine (Task 2)
- ✅ Tokenizer detection of trailing `^` (Task 2)
- ✅ Propagation to dialogue/parenthetical (Task 2)
- ✅ Edge cases: `^^`, `^STEVE`, `@steve ^`, dangling, caret in action (Task 2 tests)
- ✅ Marker fade for trailing `^` (Task 3)
- ✅ Renderer dual-second paragraph styles (Task 4)
- ✅ Token-walk lookup of `isDualSecond` from script (Task 4)
- ✅ `dialogueBlocks` + `dualPairAdjustment` helpers (Task 5)
- ✅ Integration into `estimatedPageCount`, `pageNumber(at:)`, `sceneLength(startingAt:)` (Task 5)
- ✅ Chain-of-three greedy pairing tested (Task 5)
- ✅ Binding-contract integration test (Task 6)
- ✅ Manual smoke procedure (Task 8)
- ✅ Release notes pointer (Task 8)

Placeholder scan: no TBDs, no "implement appropriate error handling", no "similar to Task N". Each step has the exact code/command and expected output.

Type consistency: `isDualSecond` used identically across `FountainLine`, `FountainTokenizer`, `FountainScript`, `ScreenplayMode`. Method names `dialogueBlocks`, `dualPairAdjustment`, `extractDualMarker` consistent everywhere. Indent values (42/60, 32/58, 37/53) match the spec table.

Fixture file (`MaughamTests/Fixtures/dual-dialogue.fountain`) mentioned in the spec but not actually needed by any test in this plan — the tests use inline string literals which is the project's prevailing pattern (verified against existing `FountainScriptPageCountTests.swift`). Fixture file omitted from the plan; if a future task wants one, it can add it then.

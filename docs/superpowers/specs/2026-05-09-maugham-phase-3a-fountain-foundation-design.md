# Maugham — Phase 3a: Fountain Foundation + Styling + Page Count

**Date:** 2026-05-09
**Status:** Spec approved; writing plan next.
**Scope:** First sub-milestone of Phase 3 (Screenplay parity). Lands the Fountain parser, per-element auto-formatting, and page count. Subsequent milestones add Tab/Enter cycling and character autocomplete (3b) and the scene navigator (3c).

---

## 1. Goals & non-goals

### Goals

- Open a `.fountain` file in Maugham's editor and see it rendered with proper screenplay typography — scene headings bold, characters centered, dialogue indented, transitions right-aligned, sections / synopses / boneyard / notes styled.
- Parse Fountain into a typed structure (`FountainScript`) shaped to support 3b (Tab/Enter cycling, character autocomplete) and 3c (scene navigator) without rework.
- Compute a meaningful page count using the standard Final Draft line-wrap heuristic.
- Surface page count in the existing goal indicator capsule. Optional `pageTarget` on `ProjectTargets` lets a screenwriter aim for "a 110-page feature".

### Non-goals (explicit deferrals)

- No Tab/Enter element cycling (3b).
- No character autocomplete (3b).
- No scene navigator (3c).
- No title page block — `Title:` / `Author:` lines render as plain action in 3a; deferred to a follow-on (3b or 3c).
- No multi-file screenplay support — single-file Screenplay project type only.
- No FDX import/export, scene numbers, dual dialogue, MORE/CONT'D — Phase 4.
- No inline emphasis inside dialogue (`*italic*` / `**bold**` mid-line) — possible 3b/3c.
- No production page-fidelity simulator with margins / orphan control — Phase 4+.

---

## 2. Architecture overview

```
                +-------------------------------------+
                |          ScreenplayMode             |
                |  (struct, conforms to WritingMode)  |
                +------+------------------------------+
                       |
    parse(text) ───────┼───── tokenize(text) -> [Token]
                       |       (projects FountainScript -> Tokens)
                       |
                       v
                +-------------------------------------+
                |         FountainTokenizer           |
                |  parse(text) -> FountainScript      |
                |  (line-based state machine)         |
                +------+------------------------------+
                       |
                       v
                +-------------------------------------+
                |          FountainScript             |
                |  lines: [FountainLine]              |
                |  estimatedPageCount: Double         |
                |  characterNames: Set<String>        |
                +-------------------------------------+
                       ^
                       |
                       +-- FountainLine
                            range: NSRange
                            element: ScreenplayElement
                            content: String           // text minus syntax markers
                            isForced: Bool            // came from @, !, ., > marker
                            sourceCase: SourceCase    // .upper / .mixed / .lower
```

`FountainTokenizer.parse(text) -> FountainScript` is the single entry point. Pure logic, no AppKit dependencies. Uses a line scanner with a small state machine (states: `.normal`, `.boneyard`, `.note` for multi-line notes). Line-based, not regex-pass based, because Fountain element classification is fundamentally context-sensitive — the same line can be a Scene Heading or Character or Action depending on what came before and after. Independent regex passes (the MarkdownTokenizer pattern) cannot express these dependencies cleanly.

`ScreenplayMode` holds no state. On each editor cycle:

- `tokenize(text)` calls `FountainTokenizer.parse` and projects each `FountainLine` to one `Token`. The Token system gains a single new variant: `.fountainElement(ScreenplayElement, isForced: Bool)`. No bloat — one new case carries the whole structural classification.
- `applyTypography(...)` re-parses the storage's string (cheap; ~1ms on a feature-length script) and walks `FountainScript.lines`, applying per-element paragraph styles plus the display-uppercase font feature where applicable.
- `metrics(text)` calls `parse`, returns `EditorMetrics` extended with `pageCount: Double?`.

**Why re-parse instead of caching FountainScript across calls.** Caching across `tokenize` and `applyTypography` would require either mutable state on ScreenplayMode (currently a struct, like ProseMode) or a plumbing change to `WritingMode` protocol. Parsing a 110-page feature is well under 5ms; the simplicity of pure functions is worth the duplication.

---

## 3. Element coverage & parsing rules

### 3.1 The `ScreenplayElement` enum

```swift
public enum ScreenplayElement: Equatable, Hashable {
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
```

Inline notes within an action line keep the line classified as `.action`; the note's range gets sub-classification via a separate inline-span pass at styling time. Multi-line notes (`[[ ... ]]` spanning newlines) classify the whole block as `.note`.

### 3.2 Recognition rules

| Element | Recognition rule | Source markers |
|---|---|---|
| `.action` | Default; any non-blank line that doesn't match another rule. | None or `!` (forced) |
| `.sceneHeading` | Line starts with `INT.`/`EXT.`/`EST.`/`I/E.`/`INT/EXT.` (case-insensitive) AND has a blank line above; OR forced via leading `.` (with no second `.`) | `INT.` etc., or `.` |
| `.character` | Line is ALL UPPERCASE letters (digits / standard punctuation allowed), preceded by blank line, followed by non-blank line; OR forced via `@` | ALL-CAPS, or `@` |
| `.dialogue` | Non-blank line immediately following a Character or Parenthetical, until next blank line | None |
| `.parenthetical` | Line starts with `(` and ends with `)`, between Character and Dialogue | `(` `)` wrapping |
| `.transition` | Line ends with `TO:` and is ALL UPPERCASE preceded by blank; OR forced via leading `>` | `>` prefix |
| `.centered` | Line wrapped in `>...<` | `>` `<` |
| `.lyric` | Line starts with `~` | `~` prefix |
| `.section(level:)` | Line starts with one to six `#` characters followed by a space | `#`...`######` |
| `.synopsis` | Line starts with a single `=` followed by a space (and is NOT three-or-more `=`) | `=` |
| `.pageBreak` | Line is exactly three or more `=` characters with no other content | `===` |
| `.boneyard` | Multi-line block bracketed by `/* */`; each line in the range gets this kind | `/*` ... `*/` |
| `.note` | Multi-line `[[ ... ]]` block; each line gets `.note`. Inline `[[ ... ]]` within an action line: line stays `.action`; note range styled separately | `[[` `]]` |

### 3.3 Parser state machine

Pseudocode for the line scanner:

```
state := .normal
prevBlank := true
prevElement := .action
for each line:
    if state == .boneyard:
        if line contains "*/":
            state := .normal
        classify as .boneyard
    else if state == .note:
        if line contains "]]":
            state := .normal
        classify as .note
    else if line starts with "/*":
        if line does NOT contain "*/" later: state := .boneyard
        classify as .boneyard
    else if line is blank:
        prevBlank := true
        classify as .action with empty content
    else:
        element := classify(line, prevBlank, prevElement)
        prevBlank := false
        prevElement := element
        classify as element
```

`classify(line, prevBlank, prevElement)` checks forced markers first (`@`, `!`, `.`, `>`, `~`, `#`, `=`, `===`, `>...<`), then context-sensitive rules:

1. Line is exactly three-plus `=` → `.pageBreak`
2. Forced markers (in order: `>...<` for centered, `>` for transition, `.` (single) for sceneHeading, `@` for character, `!` for action, `~` for lyric, `#`+ for section, `=` (single) for synopsis)
3. Scene Heading prefix (`INT.`, `EXT.`, `EST.`, `I/E.`, `INT/EXT.`) + prevBlank → `.sceneHeading`
4. ALL-CAPS line (with optional digits/punct) + prevBlank + (next line non-blank, looked ahead) → `.character`
5. ALL-CAPS line ending in `TO:` + prevBlank → `.transition`
6. prev element ∈ {`.character`, `.parenthetical`, `.dialogue`} AND line starts with `(` and ends with `)` → `.parenthetical`
7. prev element ∈ {`.character`, `.parenthetical`, `.dialogue`} AND line is non-blank → `.dialogue`
8. Default → `.action`

The `prevBlank` discipline is what distinguishes Character from Action: an ALL-CAPS line in the middle of action paragraphs (e.g., "He yelled SOMETHING") stays Action because no blank line precedes.

### 3.4 `sourceCase` and `isForced` derivation

- `sourceCase` is computed from the line's *content* (after stripping forced markers): if the content has any letter and all letters are uppercase → `.upper`; if any are lowercase and any are uppercase → `.mixed`; if all are lowercase → `.lower`.
- `isForced` is true when the element was classified via a forced marker (`@`, `!`, `.`, `>`, `~`, etc.), false otherwise.

Display-uppercase decisions in the styler use both fields: apply uppercase font feature only when `isForced && sourceCase != .upper` for the three relevant element kinds (Character, Scene Heading, Transition).

### 3.5 Inline notes

Inline notes (`[[ … ]]` not crossing a newline) are detected during a second pass over each line's content. When found within an `.action` (or any other) line, they produce a `FountainInlineSpan(range, kind: .note)` in `FountainLine.inlineSpans`. The styler applies dim italic to that range without re-classifying the parent line.

```swift
public enum SourceCase: Equatable { case upper, mixed, lower, neutral }
// .neutral when the line has no letters (e.g., punctuation-only)

public struct FountainInlineSpan: Equatable {
    public enum Kind: Equatable { case note }
    public let range: NSRange
    public let kind: Kind
}

public struct FountainLine: Equatable {
    public let range: NSRange
    public let element: ScreenplayElement
    public let content: String
    public let isForced: Bool
    public let sourceCase: SourceCase
    public let inlineSpans: [FountainInlineSpan]   // empty by default
}

public struct FountainScript: Equatable {
    public let lines: [FountainLine]
    public var estimatedPageCount: Double { /* §5 algorithm */ }
    public var characterNames: Set<String> {
        // 3a only needs this trivially for page-count tests; 3b will use it for autocomplete.
        Set(lines.compactMap { line in
            guard line.element == .character else { return nil }
            return line.content.uppercased()
        })
    }
}
```

---

## 4. Per-element styling

`ScreenplayMode.applyTypography` walks `FountainScript.lines` and, for each line, builds an `NSMutableParagraphStyle` based on the element kind. Indents below are in monospace character widths, converted to points via the body font's per-glyph advance × N (the standard macOS technique for character-aligned indentation).

### 4.1 Page width override

ScreenplayMode uses a **fixed 60-character text container width** regardless of `typography.pageWidthCharacters` (which is a prose-oriented user setting). This matches the Cole & Haag / Final Draft standard: 8.5"×11" page, Courier 10cpi, 1.5" left margin, 1" right margin → 6" text width = 60 characters.

`ScreenplayMode.textColumnWidth(typography:)` overrides the protocol default to return `avgCharWidth × 60`, ignoring `typography.pageWidthCharacters`. This keeps screenplay layout consistent across users regardless of their prose-mode preferences. Other typography settings (font family, font size, line height, paragraph spacing) still apply normally.

### 4.2 Indentation and alignment table

Indent columns assume the standard 60-character screenplay page (Cole & Haag).

| Element | Head indent | Tail indent | Alignment | Weight | Other |
|---|---|---|---|---|---|
| Action | 0ch | 60ch | `.left` | regular | — |
| Scene Heading | 0ch | 60ch | `.left` | bold | display-uppercase if forced+mixed |
| Character | 22ch | 60ch | `.left` | regular | display-uppercase if forced+mixed |
| Parenthetical | 15ch | 35ch | `.left` | regular | italic |
| Dialogue | 10ch | 45ch | `.left` | regular | — |
| Transition | 0ch | 60ch | `.right` | bold | display-uppercase if forced+mixed |
| Centered | 0ch | 60ch | `.center` | bold | — |
| Lyric | 0ch | 60ch | `.left` | regular | italic |
| Section (any level) | 0ch | 60ch | `.left` | bold | underline |
| Synopsis | 0ch | 60ch | `.left` | regular | italic; secondaryText 60% |
| Boneyard | 0ch | 60ch | `.left` | regular | italic; secondaryText 40% |
| Note (block or inline) | inherit | inherit | inherit | regular | italic; secondaryText 40% |
| Page Break | 0ch | 60ch | `.center` | regular | dim; rendered as a faint dashed paragraph |

Sections render the same style regardless of `level` value — the level field is captured for 3c (scene navigator may surface it as outline depth) but is visually neutral in 3a.

Character widths are computed once per `applyTypography` call from the body font and reused across all lines in that pass.

### 4.3 Display-uppercase mechanism

For lines that are `.character`, `.sceneHeading`, or `.transition` AND have `isForced == true` AND `sourceCase != .upper`, we render the line in visual uppercase while keeping the source text on disk mixed-case. The `NSTextStorage` content stays as-typed (so `cat file.fountain` still shows `@Sam`), and cursor / selection arithmetic stays correct because the character indices haven't changed.

**Implementation strategy.** Cocoa does not have a built-in `NSAttributedString.Key` that converts lowercase glyphs to uppercase at render time (the OpenType `case` feature controls case-sensitive punctuation forms; `kUpperCaseType` controls small-caps variant selection — neither performs lowercase→uppercase substitution). The realistic approaches, in order of preference:

1. **Custom `NSLayoutManager` glyph substitution.** Subclass `NSLayoutManager` and override `showCGGlyphs(_:positions:count:font:matrix:attributes:in:)`. For ranges carrying a custom marker attribute (e.g., `.maughamDisplayUppercase`), regenerate glyphs from the uppercased character data before drawing. Source string and selection indices stay untouched. This is the right Cocoa-native technique.
2. **Fallback if (1) interacts badly with TextKit 1/2 boundary or with focus-dimming attributes.** Render as-typed (option A): forced character `@Sam` displays as `Sam`. The screenplay still styles correctly (centered/indented), only the casing is preserved. The writer can manually type `@SAM` if they want uppercase.

The plan will spike (1) early. If the spike succeeds with clean smoke behavior, ship it. If it surfaces TextKit edge cases that risk shipping bugs, fall back to (2) and document the deferral as a 3b/3c follow-on.

A unit test exercises the layout manager subclass directly (input string + range marked uppercase → output glyphs match the uppercase-substituted string).

### 4.4 Theme integration

Dim color values come from the resolved theme palette:

- Synopsis: `palette.secondaryText` at 60% opacity
- Boneyard / Note: `palette.secondaryText` at 40% opacity

Body color stays `palette.bodyText` for all other elements. The theme palette is already passed through `applyTypography`; no new plumbing.

### 4.5 Inline note styling pass

After the per-line paragraph styling pass, a second pass walks `inlineSpans` for any line that has them and applies the dim italic foreground attribute to those sub-ranges. This is one extra `setAttributes(_:range:)` call per inline note — negligible cost.

---

## 5. Page count algorithm

`FountainScript.estimatedPageCount: Double` computes:

```swift
let linesPerPage = 55                  // Final Draft standard
let charsPerActionLine = 60            // matches Action width in §4.2
let charsPerDialogueLine = 35          // matches Dialogue width (45 - 10)
let charsPerParenthetical = 20         // matches Parenthetical width (35 - 15)
let sceneHeadingExtraBlankLines = 1    // implicit blank above scene heading

var totalLines = 0
for line in script.lines {
    switch line.element {
    case .action:
        let wraps = ceiling(line.content.count / charsPerActionLine)
        totalLines += max(wraps, 1)
    case .dialogue:
        let wraps = ceiling(line.content.count / charsPerDialogueLine)
        totalLines += max(wraps, 1)
    case .parenthetical:
        let wraps = ceiling(line.content.count / charsPerParenthetical)
        totalLines += max(wraps, 1)
    case .sceneHeading:
        totalLines += 1 + sceneHeadingExtraBlankLines
    case .character, .transition, .centered, .lyric:
        totalLines += 1
    case .section, .synopsis, .boneyard, .note, .pageBreak:
        totalLines += 0   // not counted toward page count
    }
}

return Double(totalLines) / Double(linesPerPage)
```

Wrap widths intentionally match the visual layout widths in §4.2 — page count math and styling math agree.

Sections, synopses, boneyard, notes, and page breaks don't count — they're working-doc metadata, not script content. Empty action lines (paragraph breaks) count as 1 line via the `max(wraps, 1)` clause.

For display, the goal indicator formats to one decimal: `27.5 pages` or `127.0 / 110 pages`.

---

## 6. Goal indicator + ProjectTargets schema migration

### 6.1 `ProjectTargets` extension

```swift
public struct ProjectTargets: Codable, Equatable {
    public var totalWords: Int?
    public var deadline: Date?
    public var pageTarget: Int?     // NEW
    public init(totalWords: Int? = nil,
                deadline: Date? = nil,
                pageTarget: Int? = nil) {
        self.totalWords = totalWords
        self.deadline = deadline
        self.pageTarget = pageTarget
    }
}
```

JSON manifests written before 3a decode unchanged: missing key → `nil`. No `schemaVersion` bump needed; the field is additive and the existing decoder already tolerates unknown / missing keys (per master spec foundations). We follow the 2c `deadline` precedent.

### 6.2 Inspector field

For Screenplay project types only, `InspectorView` shows a "Page target" numeric field below the existing word target field. For non-screenplay projects, the field is hidden — mirrors how the existing word target works for prose. The field's binding writes through to `ProjectStore.manifest.targets.pageTarget`, debounced via the existing manifest-save scheduler.

### 6.3 `EditorMetrics` schema extension

```swift
public struct EditorMetrics {
    public let wordCount: Int
    public let characterCount: Int
    public let readingMinutes: Int
    public let pageCount: Double?    // NEW; nil for non-screenplay modes
}
```

`ProseMode.metrics` returns `pageCount: nil`. `ScreenplayMode.metrics` returns the computed value. All call sites that destructure metrics handle nil naturally; the goal indicator and any future metric consumer treat nil as "no page count for this mode".

### 6.4 `GoalIndicatorState` rendering

`GoalIndicatorState` gains `pageCount: Double?` and `pageTarget: Int?` derived from `EditorMetrics.pageCount` and `ProjectTargets.pageTarget`. The capsule view conditionally renders:

- **Screenplay project + `pageTarget` set**: `"127.5 / 110 pages"` (rounded to one decimal)
- **Screenplay project + no `pageTarget`**: `"127.5 pages"`
- **Non-screenplay**: existing word count behavior, untouched

Page text generation uses `+`-concatenation with explicit `let s: String = ...` bindings, NOT `\(value.formatted(.number))` chained interpolations — per the SourceKit-budget lesson banked from 2c (the multi-`.formatted` interpolation pattern hit Swift's type-check ceiling). Pre-emptive: build the formatted string in plain Swift, then hand a single String to the SwiftUI Text view.

---

## 7. Testing strategy

### 7.1 Pure-logic unit tests

**`FountainTokenizerTests.swift` (~18 tests)**

- Each element kind: minimal positive case (`testActionLine`, `testSceneHeadingINT`, `testSceneHeadingEXT`, `testCharacterAllCaps`, `testCharacterForcedAt`, `testDialogueAfterCharacter`, `testParentheticalBetweenCharacterAndDialogue`, `testTransitionToColon`, `testTransitionForced`, `testCenteredAngleBrackets`, `testLyricTilde`, `testSectionLevel1`, `testSectionLevel3`, `testSynopsisEquals`, `testPageBreakTripleEquals`)
- Forced syntax: `@Sam` → `.character`, `!CRY` → `.action`, `.barbershop` → `.sceneHeading`, `>cut to:` → `.transition`, `>centered<` → `.centered`, `~lyric` → `.lyric`
- Dialogue continuation: Character → Parenthetical → Dialogue → second Dialogue line; correct elements and `prevBlank` tracking
- Multi-line boneyard: `/* line one\nline two\nline three */` → all three lines `.boneyard`, line after `*/` returns to normal classification
- Multi-line note block: `[[ note one\nnote two ]]` → both lines `.note`
- Inline note within action: `Action with [[ note ]] inside.` → line classified `.action`, one inline span at the `[[ ... ]]` range
- `sourceCase` derivation: `BARRY` → `.upper`, `@Sam` → `.mixed`, `~oh la la` → `.lower`
- Edge cases: trailing whitespace on Character line (must strip and still recognize), CRLF line endings, empty document, document ending without trailing newline, single-line document with one `.action` line

**`FountainScriptPageCountTests.swift` (~6 tests)**

- Empty script → 0 pages
- One short scene with five lines of action → ~0.18 pages (10/55)
- Long single-action paragraph: 600 chars → wraps to ~11 lines → ~0.20 pages
- Same 600 chars as dialogue (narrower wrap) → more lines than action → larger page count
- Boneyard / Notes / Sections excluded: a script with one `.action` line plus 100 lines of `.boneyard` matches the page count of the script with just one `.action` line
- Reference script fixture: a known short Fountain sample (committed under `MaughamTests/Fixtures/sample-screenplay.fountain`) computes within ±5% of its known Final Draft page count; assertion uses ±0.5 pages tolerance

### 7.2 Integration tests

**`ScreenplayModeStylingTests.swift` (~5 tests)**

- `tokenize` over a small fixture returns expected `Token`s with `.fountainElement` kinds in correct order
- `applyTypography` over an `NSTextStorage` populated with a fixture produces correct `NSParagraphStyle` alignment per line range — verified by reading back attributes from storage at known character offsets
- `metrics` on ScreenplayMode returns non-nil `pageCount`; `ProseMode.metrics` returns `pageCount == nil` for the same input
- Display-uppercase: a forced character line `@Sam` after `applyTypography` has font feature settings indicating uppercase substitution at the line's range
- `tokenize` over an empty string returns `[]` (consistent with existing protocol contract)

**`ProjectTargetsMigrationTests.swift` (~2 tests)**

- A manifest JSON without `pageTarget` decodes to `ProjectTargets` with `pageTarget == nil`
- Round-trip: a manifest with `pageTarget: 110` encodes, decodes, and equals the original

Total expected new tests: ~31. Combined with existing 275, target test count after 3a is **~306 passing**.

### 7.3 Smoke checklist (required before tagging milestone-3a)

1. New Screenplay project → opens with empty `.fountain` → editor shows monospace plain
2. Type `INT. KITCHEN - DAY` → blank line → `BARRY` → blank line → `Hello.` → see scene heading bold, character indented at 17ch, dialogue indented at 9ch
3. Type `@Sam` (forced character lowercase) → see `SAM` rendered uppercase via glyph feature; verify source still `@Sam` on disk via Terminal `cat`
4. Type `> SMASH CUT TO:` → see right-aligned bold uppercase
5. Type `# ACT TWO` → see bold underline section
6. Type `[[ todo ]]` inline within an action paragraph → action stays styled normally; the `[[ … ]]` range renders dim italic
7. Type `/* cut */` → see dim italic boneyard
8. Goal indicator capsule shows page count in real time as text grows
9. Set page target via Inspector → goal indicator switches to "X / Y pages" format
10. Open the committed reference fountain script → page count within ±5% of its known Final Draft page count
11. Theme switch (Light / Dark / Sepia) → all element styling re-applies correctly with theme colors
12. Resize editor pane wide and narrow → indent columns track monospace character widths consistently
13. ⌘\ no-chrome mode → editor still styled correctly
14. Switch active document from prose → screenplay → prose → no leftover styling, no crashes
15. Type a script that crosses 1.0 pages, then 5.0 pages → goal indicator updates smoothly without UI hitches

---

## 8. Out of scope for 3a (each item scheduled to a specific milestone)

| Item | Scheduled milestone | Notes |
|---|---|---|
| Tab/Enter element cycling | **3b** | Editing UX milestone — cycle Action → Character → Dialogue → Parenthetical → ... on Tab; Enter follows screenplay flow conventions. |
| Character autocomplete | **3b** | Suggest names from `FountainScript.characterNames` (already populated by 3a's parser). |
| Scene navigator (slugline jump list) | **3c** | Replaces or augments the manuscript binder for Screenplay project types. |
| Title page block (`Title:` / `Author:` / `Credit:` etc.) | **3c** | Parsed as a metadata block at the document head; rendered styled inline; optionally mirrored in Inspector. Discrete UI feature, fits 3c's polish framing. |
| Inline emphasis inside dialogue (`*italic*`, `**bold**` mid-line) | **3c** (or Phase 4 if 3c capacity is tight) | Extends `inlineSpans` with `.italic` / `.bold` kinds; styling pass adds character-level attributes. Smallest of the deferrals. |
| Multi-file screenplay (one file per scene) | **new 3d** | Architectural change: binder, ProjectFactory, multi-document loader, page-count summing across files. Bigger than polish — gets its own sub-milestone. Phase 3 grows from 3 to 4 sub-milestones (3a, 3b, 3c, 3d). |
| FDX import/export | **Phase 4** | Master spec assigns to Phase 4 (Final Draft parity). |
| Scene numbers | **Phase 4** | Master spec assigns to Phase 4. |
| Dual dialogue | **Phase 4** | Master spec assigns to Phase 4. |
| MORE / CONT'D markers | **Phase 4** | Master spec assigns to Phase 4. |
| Revisions / colored pages | **Phase 4** | Master spec assigns to Phase 4. |
| Production page-fidelity simulator (margins, orphan control) | **Phase 4+** | Out of Phase 3 entirely. |

---

## 9. Risks & mitigations

- **Display-uppercase glyph substitution is the single highest-risk piece.** Cocoa offers no built-in attribute that converts lowercase glyphs to uppercase at render time. The plan is to subclass `NSLayoutManager` and substitute glyphs at draw time for ranges marked with a custom attribute. This is a known but fiddly Cocoa technique. The codebase uses NSTextView's default layout system, which on macOS 14+ is TextKit 2 (NSTextLayoutManager). To use NSLayoutManager glyph substitution we either (a) force the screenplay text view onto TextKit 1 by setting `usesTextKit2 = false` (per-NSTextView, harmless to other features), or (b) use TextKit 2's NSTextLayoutManagerDelegate/NSTextLineFragment hooks. The plan task 8 will spike (a) first as the simpler path. If the spike surfaces interactions that risk shipping bugs (cursor jitter, focus dimming layering, selection mis-rendering), fall back to option A behavior — render forced-character lines as-typed. The user accepted option B in the brainstorm with the understanding that A is the fallback. Document any deferral as a 3b/3c follow-on.
- **Re-parsing on every edit could feel slow on long scripts.** Measure on a 110-page sample during implementation; if >5ms per cycle, consider memoizing `(text-hash, FountainScript)` inside ScreenplayMode (would require it becoming a class — defer until measured). Likely won't be needed.
- **Page count diverges from Final Draft on action-heavy scripts.** Wrap widths are approximations. Spec calls for ±5% on the reference fixture; if real scripts diverge more, tune the wrap constants in a follow-up.
- **InspectorView may regrow the SwiftUI body type-check timeout.** The page target field is conditionally shown for screenplay projects only. Per the 2c lesson, if `InspectorView.body` starts hitting the type-check ceiling, factor the new field into a private `@ViewBuilder` method or modifier struct.
- **Fixed 60-char width may surprise users with unusual typography settings.** A user with `pageWidthCharacters` set to 80 for prose will see screenplays render at 60 (narrower than their other documents). This is by design — screenplay format is canonical 60ch — but worth documenting in the user-facing release notes for milestone-3a.
- **Smoke step 3 (verify source on disk) requires the user to run `cat`.** If the smoke is performed without that step, a regression in display-uppercase that mistakenly modifies source content could ship undetected. Make this step non-skippable in the smoke checklist.

---

## 10. Implementation sequencing (preview for the plan)

Approximate order; the plan will detail per-task TDD steps.

1. `ScreenplayElement` enum, `SourceCase` enum, `FountainInlineSpan`, `FountainLine`, `FountainScript` value types — pure data, no logic.
2. `FountainTokenizer.parse` — line-based state machine. ~18 unit tests drive the implementation.
3. `FountainScript.estimatedPageCount` — computed property on FountainScript with the constants from §5. ~6 unit tests.
4. Add `.fountainElement(ScreenplayElement, isForced: Bool)` to Token.Kind. Add `pageCount: Double?` to EditorMetrics. Update ProseMode to return `pageCount: nil`.
5. `ScreenplayMode.tokenize` projects FountainScript to Tokens. `ScreenplayMode.metrics` computes page count. `ScreenplayMode.textColumnWidth` overrides to fixed 60-char width.
6. `ScreenplayMode.applyTypography` paragraph-style pipeline (action / scene heading / character / dialogue / parenthetical / transition / centered / lyric).
7. `ScreenplayMode.applyTypography` extension: section / synopsis / boneyard / note / page break dim/styled rendering; inline note span pass.
8. Display-uppercase via custom NSLayoutManager subclass. New file `Maugham/Editor/ScreenplayLayoutManager.swift`. EditorSurface (where NSTextView is constructed) installs the custom layout manager when the active mode is ScreenplayMode. Custom attribute `.maughamDisplayUppercase` marks ranges; the layout manager substitutes glyphs at draw time. **Spike this task early.** If it doesn't smoke cleanly, fall back to option A and remove the layout manager subclass; the rest of 3a still ships.
9. `ProjectTargets.pageTarget` field; manifest migration test.
10. `InspectorView` page target field for screenplay projects (factored as a private `@ViewBuilder` method to pre-empt SwiftUI body type-check timeout).
11. `GoalIndicatorState.pageCount` / `pageTarget` plumbing; capsule formats screenplay variant.
12. Reference fixture screenplay + page count integration test.
13. Smoke checklist execution; fix any visible regressions; commit with `feat:` / `fix:` discipline.
14. Tag `milestone-3a`; push.

The plan will translate this into ~14–16 fully-specified tasks with code blocks, dispatched via `superpowers:subagent-driven-development`. Model selection (per banked feedback): tokenizer / page-count / value types are sonnet (substantive pure logic with rich tests); paragraph-style table is haiku (mechanical mapping); the NSLayoutManager spike is opus (TextKit edge cases, multi-file reasoning).

---

## 11. Decisions banked during brainstorm

- Element coverage: option B — core elements + forced syntax + structural extras (Sections, Synopses, Page Breaks, Boneyard, Notes). Title page deferred.
- Page count algorithm: option B — line-based simulation using Final Draft wrap-width heuristic.
- Forced-character casing: option B — visually uppercase via `kUpperCaseType` glyph feature; source stays mixed-case on disk.
- Goal indicator format: option C — pages vs page target; `pageTarget: Int?` joins `ProjectTargets`.

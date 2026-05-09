# Maugham — Phase 3b: Editing UX (Tab/Enter cycling + character autocomplete + element gutter)

**Date:** 2026-05-09
**Status:** Spec approved; writing plan next.
**Scope:** Second sub-milestone of Phase 3 (Screenplay parity). Lands the screenwriting input experience: Tab/Shift+Tab cycle the current line through screenplay elements with source-text mutation via forced-syntax markers, character autocomplete suggests previously-used names via an `NSPopover`, and an element gutter shows each line's classified type as feedback.

**Builds on:** milestone-3a (Fountain parser + per-element styling + page count). All 3b work plugs into the existing `EditorCoordinator` ↔ `ScreenplayMode` pipeline.

---

## 1. Goals & non-goals

### Goals

- Tab cycles the current line forward through `[.action, .character, .dialogue, .parenthetical, .transition]`. Shift+Tab cycles backward. The cycle uses the Highland order — the smallest cycle that covers the daily screenwriting flow.
- Tab on a blank/new line uses smart context-aware starting points (after Character + Enter, first Tab goes to Dialogue; after Dialogue + Enter, first Tab goes to Parenthetical; etc.).
- On Tab cycle, the line's source text is mutated to apply forced-syntax markers where applicable (`@` for Character, `.` for Scene Heading, `>` for Transition, `(...)` wrap for Parenthetical, `~` for Lyric). Action and Dialogue have no forced markers — Dialogue is skipped from the cycle when context doesn't support it.
- Character autocomplete: when the active line is a Character cue and the writer has typed at least one character, an `NSPopover` shows up to 8 ranked suggestions from `FountainScript.characterNames`. Up/Down navigates; Enter or Tab accepts; Escape dismisses.
- Element gutter: a thin column to the left of the centered text shows a 3-5 character abbreviation per line (`SCENE`, `CHAR`, `DLG`, `PAR`, `TRANS`, `CTR`, `LYR`, `§N`, `SYN`, `PAGE`, `CUT`, `NOTE`). Action lines get no label. Per-project toggle in Project Settings (default ON for screenplay).

### Non-goals (explicit deferrals)

| Item | Scheduled milestone | Notes |
|---|---|---|
| Title page block | **3c** | `Title:` / `Author:` / `Credit:` etc. — discrete metadata block at the document head. |
| Scene navigator | **3c** | Slugline jump list. |
| Inline emphasis (`*italic*` / `**bold**` mid-line) | **3c** | Extends `inlineSpans`. |
| ⌘? syntax help overlay | **3c** | HUD-style popover sourced from `docs/markdown-syntax.md` / `docs/fountain-syntax.md`. |
| Multi-file screenplay | **3d** | Architectural: binder, ProjectFactory, multi-document loader. |
| Display-uppercase glyph substitution | **deferred** | Carry forward as TextKit 2 reattempt — out of 3b scope. |
| FDX import/export, scene numbers, dual dialogue, MORE/CONT'D, revisions | **Phase 4** | Master spec assigns to Final Draft parity. |

---

## 2. Architecture overview

```
                +-----------------------------------+
                |       EditorCoordinator           |
                |  (NSTextViewDelegate, mode-aware) |
                +--+------+----------+--------------+
                   |      |          |
                   |      |          | doCommandBy: (when ScreenplayMode)
                   |      |          v
                   |      |   +------------------------+
                   |      |   |  ScreenplayCycle       |
                   |      |   |  pure logic:           |
                   |      |   |  cycleForward(from:)   |
                   |      |   |  cycleBackward(from:)  |
                   |      |   |  startingElement(after:)|
                   |      |   +------------------------+
                   |      |              |
                   |      |              v
                   |      |   +------------------------+
                   |      |   |  ScreenplayLineMutator |
                   |      |   |  mutate(line:to:) ->   |
                   |      |   |    (text, cursorOffset)|
                   |      |   +------------------------+
                   |      |
                   |      | textDidChange (autocomplete trigger)
                   |      v
                   |  +-----------------------------+
                   |  |  CharacterAutocompleter     |
                   |  |  - NSPopover w/ NSTableView |
                   |  |  - suggestions sourced from |
                   |  |    FountainScript           |
                   |  +-----------------------------+
                   |
                   | retokenizeAndStyle (existing)
                   v
                +-----------------------------------+
                |   ScreenplayMode.applyTypography  |
                +-----------------------------------+
                                |
                                v (gutter view reads same parse)
                +-----------------------------------+
                |   ElementGutterView (new)         |
                |   - NSView in scroll-clip area    |
                |   - draws per-line abbreviations  |
                |   - scroll-synced via bounds notif|
                +-----------------------------------+
```

`EditorCoordinator` gains:
- A new property `lastParsedScript: FountainScript?` cached during `retokenizeAndStyle`. Both the autocompleter and gutter view read from it (single source).
- A `textView(_:doCommandBy:)` implementation that, when `mode is ScreenplayMode`, intercepts `insertTab:`, `insertBacktab:`, `cancelOperation:`, and (when popover visible) `moveUp:` / `moveDown:` / `insertNewline:`.
- An `autocompleter: CharacterAutocompleter` instance owning the popover lifecycle.

`EditorSurface` gains:
- A sibling `ElementGutterView` view inside the `NSScrollView`'s clip view, layered to the left of the text view inside the centered-column inset. Mode-conditional (only attached when `mode is ScreenplayMode`).

---

## 3. Tab cycle — order and starting points

### 3.1 Cycle order (per Q1)

Highland-style: `[.action, .character, .dialogue, .parenthetical, .transition]`.

`cycleForward` advances through the array (wrapping `transition` back to `action`). `cycleBackward` reverses. Both skip elements that aren't valid in current context (see §3.2).

### 3.2 Skip-Dialogue rule

`.dialogue` is context-sensitive — it requires a preceding `.character` or `.parenthetical` line. If the line above the active line is neither Character nor Parenthetical (and not another Dialogue continuing a block), Tab cycling forward from `.character` or `.parenthetical` SKIPS `.dialogue` and lands on the next element (e.g., `.parenthetical`). Symmetrically for backward cycling.

This keeps the cycle ergonomic: Tab never lands on an element the parser will silently demote to `.action`.

### 3.3 Smart starting point on blank lines (per Q4)

When the active line is empty AND has no forced-syntax marker yet, `ScreenplayCycle.startingElement(after:)` decides where the FIRST Tab press lands. Subsequent Tab presses on the same blank line cycle forward through the cycle order from that starting point.

| Prev line element | First Tab on blank line goes to |
|---|---|
| `.action` | `.character` |
| `.sceneHeading` | `.action` |
| `.character` | `.dialogue` |
| `.parenthetical` | `.dialogue` |
| `.dialogue` | `.parenthetical` |
| `.transition` | `.sceneHeading` |
| `.centered` / `.lyric` / `.section` / `.synopsis` / `.boneyard` / `.note` / `.pageBreak` | `.action` |

`.sceneHeading` is reachable via smart starting point (Tab after Transition) but is NOT in the standard cycle order. After landing on `.sceneHeading`, a subsequent forward Tab routes to `.action` (treating `.sceneHeading` as adjacent to `.action` for cycling purposes).

### 3.4 Source mutation on cycle (per Q2)

`ScreenplayLineMutator.mutate(line:to:neighborhood:)` returns a `(text: String, cursorOffset: Int)` tuple. The caller replaces the line's text and positions the cursor.

The mutator's behavior depends on whether the target element has a **context-sensitive alternative** (an existing way to be classified as that element without a forced marker):

| Element | Has context-sensitive alternative? |
|---|---|
| `.character` | YES — ALL UPPERCASE letters + blank line above + non-blank line below |
| `.sceneHeading` | YES — begins with `INT.`/`EXT.`/`EST.`/`I/E.`/`INT/EXT.` (case-insensitive) + blank line above |
| `.transition` | YES — ALL UPPERCASE ending in `TO:` + blank line above |
| `.parenthetical` | NO — Fountain requires `(...)` wrapping |
| `.lyric` | NO — Fountain requires leading `~` |
| `.section` | NO — Fountain requires leading `#` |
| `.synopsis` | NO — Fountain requires leading `= ` |
| `.dialogue` | (no marker exists; pure context-sensitive — see §3.2 skip rule) |
| `.action` | (default; no marker; mutator strips other markers) |

For elements WITH a context-sensitive alternative, the mutator applies the forced marker **only when context doesn't already satisfy the alternative**. Source files stay clean for the common path: a writer typing `BARRY` (caps) on a blank-line-above + content-below position gets a Character cue without any `@` insertion.

For elements WITHOUT an alternative, the mutator always applies the marker (because there's no other way).

The mutator needs `neighborhood: LineNeighborhood` — a small struct passed by the caller — to make the context-sensitive checks. The caller (`EditorCoordinator`) computes it from `lastParsedScript.lines` adjacent to the active line.

```swift
public struct LineNeighborhood: Equatable {
    public let prevIsBlank: Bool      // line above is blank, OR line is doc start
    public let nextIsBlank: Bool      // line below is blank, OR line is doc end
}
```

#### Per-element mutation

| Target element | Mutation |
|---|---|
| `.action` | Strip any leading forced marker (`@`, `.`, `>`, `~`, `#…`, `= `). If line is wrapped in `(...)`, strip the parens. Cursor: end of resulting text. |
| `.sceneHeading` | If line already begins with `.` (forced), OR with `INT.`/`EXT.`/`EST.`/`I/E.`/`INT/EXT.` AND `neighborhood.prevIsBlank`: leave as-is. Else: prepend `.`. Cursor: end. |
| `.character` | If line is ALL UPPERCASE letters (with optional digits/punct) AND `neighborhood.prevIsBlank` AND NOT `neighborhood.nextIsBlank`: leave as-is — context already classifies it as Character. Else if line begins with `@`: leave as-is. Else: prepend `@`. Cursor: end. |
| `.dialogue` | No marker available; line text unchanged. Skip-Dialogue rule applies if context doesn't support it (§3.2). Cursor: end. |
| `.parenthetical` | If line is already `(...)`: leave alone. Else: wrap content in `(...)`. Cursor: position 1 (inside the opening paren). Always applies — no context-sensitive alternative. |
| `.transition` | If line begins with `>`: leave as-is. Else if line is ALL UPPERCASE ending in `TO:` AND `neighborhood.prevIsBlank`: leave as-is — context already classifies it as Transition. Else: prepend `> `. Cursor: end. |
| `.lyric` | If line begins with `~`: leave as-is. Else: prepend `~`. Always applies — no alternative. (Not reachable from 3b's cycle; entry exists for completeness.) |

#### Examples (3b user flow)

- Writer types `BARRY` on a fresh line (after a blank line). Tab cycle to Character: **no mutation** — line stays `BARRY`. Context already classifies it.
- Writer types `barry` (lowercase). Tab cycle to Character: line becomes `@barry`. Marker needed because lowercase doesn't classify.
- Writer types `Sam` (mixed case). Tab cycle to Character: line becomes `@Sam`.
- Writer types `BARRY` mid-action-paragraph (no blank above). Tab cycle to Character: line becomes `@BARRY`. Marker needed because prev-blank fails — without `@`, the parser would call this an Action line.
- Writer types `SMASH CUT TO:` after a blank line. Tab cycle to Transition: **no mutation** — context already classifies it.
- Writer types `quietly`. Tab cycle to Parenthetical: line becomes `(quietly)` (always applies).

The mutator is pure logic — given a line's current text, target element, and neighborhood, it returns the new text and cursor offset. Idempotent: cycling A→B→A returns to the original text. Deterministic given the same `(line, target, neighborhood)` inputs.

### 3.5 Tab on non-empty line

When the active line is non-empty, Tab determines the line's CURRENT classified element via the cached `FountainScript.lines`, then cycles forward (or backward for Shift+Tab) using the rules above. The mutator strips the previous element's markers (if any) before applying the new ones.

### 3.6 Tab on empty line

When the active line is empty, Tab uses the smart starting point on first press. Source mutation places the appropriate forced-syntax marker (or no marker for `.action`/`.dialogue`) and positions the cursor. Subsequent Tab presses cycle forward from there, applying mutator transforms.

---

## 4. Enter behavior

Enter (`insertNewline:`) is **NOT intercepted** by `EditorCoordinator.doCommandBy` for cycling purposes. NSTextView's default behavior — insert `\n` at cursor — applies. Element classification of the new line happens naturally via `FountainTokenizer`'s context-sensitive rules: prev-blank tracking, Character → Dialogue chain, etc.

**The smart starting point logic (§3.3) is what makes Enter "feel screenwriterly"** — after Character + Enter, hitting Tab on the blank line takes the writer directly to Dialogue. No special Enter handler needed.

When the autocomplete popover is visible, Enter is intercepted to mean "accept selection" (see §5).

---

## 5. Character autocomplete

### 5.1 Trigger conditions

The popover appears when ALL of these are true:
- `mode is ScreenplayMode`
- Active line classifies as `.character` (per the cached `lastParsedScript`)
- Active line content (excluding any `@` prefix) has length ≥ 1
- `lastParsedScript.characterNames` is non-empty
- The cursor is at the END of the line (not mid-line — autocompleting in the middle of an existing name is confusing)

The popover dismisses when:
- Cursor moves off the line (Enter, click away)
- Active line stops classifying as `.character`
- Popover loses focus
- Escape is pressed
- Typed text doesn't prefix-match or substring-match any candidate

### 5.2 Suggestion ranking

Candidates come from `FountainScript.characterNames: Set<String>` (already populated in 3a). Filtering and ranking:

1. Compute the active line's content (uppercased, stripping `@` prefix).
2. Among `characterNames`, find candidates that prefix-match the content. Sort alphabetically.
3. Among the rest, find candidates that contain the content as a substring (excluding those already in step 2). Sort alphabetically.
4. Concatenate: prefix matches first, substring matches second.
5. Cap the concatenated list at 8. (If prefix matches alone exceed 8, substring matches are dropped entirely.)

If the active content is exactly equal to an existing name, the popover still appears (so the writer can confirm "yes, this is the same character") — but Enter on that match is a no-op visually since the text is unchanged.

### 5.3 Popover UI

`NSPopover` configured with:
- `behavior = .transient` (auto-dismisses on focus loss; we manage the keystroke routing manually)
- `contentSize` derived from suggestion count: width = 200pt, height = `min(8, suggestionCount) × rowHeight + padding`
- `positioningRect` = the cursor's screen rect (computed via `firstRect(forCharacterRange:)`)
- `preferredEdge = .minY` (popover hangs below the line)

Content view: `NSTableView` (single column, single-select) inside an `NSScrollView` (no actual scroll needed since we cap at 8, but the table needs the wrapper for AppKit reasons).

Each row: character name in monospace at body font size, padded 4pt vertical / 8pt horizontal. Active row uses system selection background.

### 5.4 Keystroke routing while popover is visible

Routed by `EditorCoordinator.textView(_:doCommandBy:)`:

| Selector | Behavior |
|---|---|
| `moveUp:` (Up arrow) | `autocompleter.moveSelectionUp()` |
| `moveDown:` (Down arrow) | `autocompleter.moveSelectionDown()` |
| `insertNewline:` (Enter) | `autocompleter.acceptSelection(in: textView)` — replaces line content with selected name; dismisses |
| `insertTab:` (Tab) | Same as Enter — accepts selection. (Writer can dismiss with Escape if they want Tab to do its element-cycling thing.) |
| `cancelOperation:` (Escape) | `autocompleter.dismiss()` — keeps text as-typed |

Other selectors are NOT intercepted — they propagate to NSTextView's defaults, and `textDidChange` fires afterward to update suggestions.

### 5.5 Acceptance behavior

When the writer accepts a suggestion:
1. The active line's text is replaced with the selected name (uppercased), preserving any leading `@` prefix if present.
2. Cursor is placed at the end of the line.
3. Popover dismisses.
4. Re-parse triggers naturally via `textDidChange`.

---

## 6. Element gutter

### 6.1 Visual

A thin column to the left of the centered text column, drawn inside the editor scroll view's clip view. Each line of the document gets one row in the gutter. The row contains a 3-5 character uppercase abbreviation if the line classifies as a non-Action element; Action lines get no label (default state).

| Element | Gutter label |
|---|---|
| `.action` | (blank) |
| `.sceneHeading` | `SCENE` |
| `.character` | `CHAR` |
| `.dialogue` | `DLG` |
| `.parenthetical` | `PAR` |
| `.transition` | `TRANS` |
| `.centered` | `CTR` |
| `.lyric` | `LYR` |
| `.section(level: N)` | `§N` (e.g., `§1`, `§2`, ..., `§6`) |
| `.synopsis` | `SYN` |
| `.pageBreak` | `PAGE` |
| `.boneyard` | `CUT` |
| `.note` | `NOTE` |

### 6.2 Typography

- Font: system monospace at 0.7× the body font's point size
- Color: `palette.syntaxPunctuation` (the project's standard "secondary" color slot)
- Alignment: right-aligned within the gutter (so labels read into the text column, like line numbers in Xcode)
- Baseline: matches the corresponding text line's first baseline

### 6.3 Implementation

`ElementGutterView: NSView`:
- Holds a weak reference to its associated `NSTextView` (so it can read the text view's frame and layout manager for line geometry)
- Holds a weak reference to its `EditorCoordinator` and reads `coordinator?.lastParsedScript` on every repaint (FountainScript is a value type — the gutter snapshots it at draw time)
- Subscribes to `NSText.didChangeNotification` (re-classifies on edit)
- Subscribes to `NSScrollView.contentView.boundsDidChangeNotification` (repaints on scroll)
- Subscribes to `NSWindow.didChangeBackingPropertiesNotification` (theme/typography changes — coarse but reliable)

`draw(_:)` walks visible glyph ranges via the text view's layout manager, looks up each line's classified element, and draws the abbreviation at the line's baseline.

### 6.4 Layout

The `NSScrollView`'s clip view contains:
- The existing `NSTextView` (centered via `textContainerInset`)
- A new `ElementGutterView` positioned to the LEFT of the text view, occupying the left portion of the inset

The gutter's width is `gutterWidth = max(40pt, 5 × charWidth)`, where `charWidth` is the body font's average monospace advance (computed via the same pangram-measurement helper used by `ScreenplayMode.textColumnWidth`). The text view's `textContainerInset.width` already provides ≥ 40pt of space when the editor pane is wide enough; the gutter is layered into that space.

When the editor pane is narrow (squeezed by binder + inspector), the inset shrinks. If the inset goes below `gutterWidth`, the gutter hides itself rather than overlap the text. Hide threshold is `gutterWidth + 8pt` of inset clearance.

### 6.5 Mode awareness

The gutter is created and added to the clip view ONLY when `mode is ScreenplayMode`. For prose modes, the gutter view is removed from the hierarchy. EditorSurface's `updateNSView` reconciles this when the active mode changes.

### 6.6 Settings

`ProjectSettingsSheet` gains a "Show element gutter" toggle for screenplay projects. Defaults to ON. The toggle writes through to a new `ProjectSettings` field (or, more precisely, a field on the existing per-project settings store — TBD location during implementation).

When OFF, the gutter view is removed from the clip view; existing styling and Tab cycling still work.

---

## 7. EditorCoordinator changes

### 7.1 New property: `lastParsedScript`

```swift
private(set) var lastParsedScript: FountainScript?
```

Set inside `retokenizeAndStyle()` after `ScreenplayMode.tokenize` runs (which already calls `FountainTokenizer.parse` internally). Both the autocompleter and gutter read from this property — single source.

For prose modes, `lastParsedScript` stays `nil`.

### 7.2 New `doCommandBy:` implementation

Conceptual sketch (the plan will detail the full code):

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

### 7.3 New `cycleElementForward` / `cycleElementBackward`

Computes:
1. The active line's character range and content (via the text storage).
2. The active line's current classified element (via `lastParsedScript.lines.first(where: { line.range covers cursor })`).
3. **Choose target element:**
   - If the line is **empty AND `lastCycleTarget` is set**: target = `ScreenplayCycle.cycleForward(from: lastCycleTarget)` (subsequent Tab on the same blank line).
   - Else if the line is **empty (no `lastCycleTarget`)**: target = `ScreenplayCycle.startingElement(after: prevLineElement)` (first Tab on a fresh blank line).
   - Else (non-empty line): target = `ScreenplayCycle.cycleForward(from: currentElement)`.
   - In all cases, apply skip-Dialogue rule if context doesn't support it.
4. Compute `LineNeighborhood(prevIsBlank:, nextIsBlank:)` from `lastParsedScript` (a line is "blank" if `content.isEmpty`; a line is treated as "blank" beyond the document boundaries).
5. Apply `ScreenplayLineMutator.mutate(line:to:neighborhood:)` to compute new text + cursor offset.
6. Replace the line's text via `textView.shouldChangeText(in:replacementString:)` (so undo records the change) and reposition the cursor.
7. Update `lastCycleTarget = target`.

**`lastCycleTarget` lifecycle.** Stored as a property on `EditorCoordinator`. Cleared (set to `nil`) when:
- The cursor moves to a different line (subscribe to `NSTextView.didChangeSelectionNotification`; clear if `selectedRange.location` falls outside the previous active line's range).
- Any non-Tab keystroke triggers `textDidChange`.
- The active line gains content via the cycle's mutator (transition from empty to non-empty — subsequent Tabs use the parser's classification of the now-non-empty line, not the cached target).

### 7.4 Autocomplete trigger in `textDidChange`

After the existing `binding.wrappedValue = textView.string` and `retokenizeAndStyle()` calls:

```swift
if mode is ScreenplayMode, let script = lastParsedScript {
    autocompleter.update(textView: textView, script: script)
}
```

`update(textView:script:)` checks the trigger conditions (§5.1) and shows/dismisses/updates the popover accordingly.

---

## 8. Testing strategy

### 8.1 Pure-logic unit tests

**`ScreenplayCycleTests.swift` (~10 tests):**
- `cycleForward` from each element produces the next-in-order element
- `cycleBackward` from each element produces the previous-in-order element
- `cycleForward(from: .transition) == .action` (wrap-around)
- `cycleBackward(from: .action) == .transition`
- `startingElement(after:)` for each element kind matches the table in §3.3
- Skip-Dialogue forward: `cycleForward(from: .character, prevElement: .action) == .parenthetical` (skipping Dialogue because prev is Action, not Character)
- Skip-Dialogue backward symmetric

**`ScreenplayLineMutatorTests.swift` (~16 tests):**
- Action: strips `@` from `@BARRY` → `BARRY`; strips `> ` from `> CUT TO:` → `CUT TO:`; strips parens from `(quietly)` → `quietly`; strips leading `.` from `.barbershop` → `barbershop`
- Scene heading + prevBlank: `INT. ROOM - DAY` → unchanged; `barbershop` → `.barbershop`
- Scene heading + NOT prevBlank: `INT. ROOM - DAY` → `.INT. ROOM - DAY` (forced marker added because context fails)
- Character + prevBlank + nextNonBlank: `BARRY` → unchanged
- Character + NOT prevBlank: `BARRY` → `@BARRY` (marker needed because mid-paragraph)
- Character + nextBlank (orphan): `BARRY` → `@BARRY` (marker needed because would otherwise be demoted to Action)
- Character lowercase: `barry` → `@barry` (marker always needed for non-uppercase)
- Character mixed case: `Sam` → `@Sam`
- Character already forced: `@Sam` → unchanged
- Dialogue: any text → unchanged (no marker)
- Parenthetical: `quietly` → `(quietly)` with cursor offset 1; `(quietly)` → unchanged
- Transition + prevBlank + ALL CAPS + ends `TO:`: `CUT TO:` → unchanged
- Transition + NOT prevBlank: `CUT TO:` → `> CUT TO:`
- Transition lowercase: `cut to:` → `> cut to:`
- Lyric: `la la la` → `~la la la`; `~la la la` → unchanged
- Round-trip: mutate→.character then mutate→.action returns original (modulo case normalization)
- Idempotent: applying the same mutation twice = applying once

### 8.2 Integration tests

**`CharacterAutocompleterTests.swift` (~6 tests):**
- Triggers when active line is `.character` with content
- Suppresses when active line is `.action`
- Suppresses when `characterNames` is empty
- Ranking: prefix matches before substring matches
- Cap: at most 8 candidates surfaced
- Acceptance: replaces line content with selected name + uppercases

**`ElementGutterViewTests.swift` (~4 tests):**
- Computes correct label for each element kind
- Action returns nil/empty (no label drawn)
- Hide-when-narrow: returns `false` from `shouldDraw` when inset insufficient
- Theme-color-applied: gutter color matches palette.syntaxPunctuation after a theme change

**`ProjectSettingsGutterToggleTests.swift` (~2 tests):**
- Toggle persists in project settings
- Default is ON for new screenplay projects

### 8.3 Smoke checklist (manual, required before tagging milestone-3b)

1. New Screenplay project. On the empty document, hit Tab. Line gets `@` prefix; cursor positioned after; gutter shows `CHAR`.
2. Type `BARRY`, hit Enter. Line is now `@BARRY` (the `@` survives — actually, since `BARRY` is already ALL CAPS, the mutator would normalize to just `BARRY` if Tab were re-pressed, but the `@` stays from the initial Tab). Verify gutter still shows `CHAR`.
3. On the next blank line, hit Tab. Cursor stays at column 0 (Dialogue has no marker), but gutter shows `DLG`. Type `Hello.` — line classifies as Dialogue; gutter still `DLG`.
4. Hit Enter, hit Tab. Gutter shows `PAR`. Line wraps to `()` with cursor inside. Type `quietly`. Line is `(quietly)`; gutter still `PAR`.
5. Hit Enter twice (blank line, then Action). Hit Tab on the blank line — gutter shows `CHAR` (cycle starts at Character because prev was Action).
6. Type `S` — autocomplete popover appears with `BARRY` (and SAM if applicable from earlier scenes).
7. Press Down arrow → selection moves to the next candidate. Press Enter — line is filled with the selected name.
8. Press Escape on a popover — it dismisses without filling.
9. Hit Shift+Tab on a Parenthetical line — cycles back to Dialogue.
10. Type a Transition: `> SMASH CUT TO:` (forced). Hit Enter. Hit Tab on the blank line — gutter shows `SCENE` (smart starting point routes Transition→Scene Heading).
11. Toggle "Show element gutter" off in Project Settings — gutter hides, screenplay still functional.
12. Resize editor pane narrow — gutter shrinks, then hides when inset goes below threshold.
13. Switch to a prose document — no gutter shown.
14. Theme switch — gutter abbreviations re-render with new palette colors.
15. Open the reference fixture screenplay (`MaughamTests/Fixtures/sample-screenplay.fountain`) — every line shows its correct gutter label without performance hitches on scroll.

---

## 9. Risks & mitigations

- **NSPopover keystroke / first-responder coordination is fiddly.** Popovers can absorb focus or block keystrokes if not configured carefully. Mitigation: configure `behavior = .transient` and route ALL keystrokes via the editor's `doCommandBy:` rather than popover-internal handlers. The popover is purely visual.
- **Skip-Dialogue rule changes effective cycle length per context.** Writers may be confused why Tab sometimes goes Character → Parenthetical (skipping Dialogue) and sometimes Character → Dialogue. Mitigation: the gutter shows what the line ACTUALLY classifies as after Tab — instant visual confirmation. Document the rule in the eventual `⌘?` syntax help overlay (3c).
- **`ElementGutterView` scroll-sync edge cases.** SwiftUI `NSViewRepresentable` wrappers around scroll views have firing-order quirks (banked from 2b's editor gutter fixes). Mitigation: use the same `setFrameSize(_:)` override pattern from `MaughamTextView` for the gutter view's repaint trigger. Add an explicit `viewDidMoveToWindow` recompute in the gutter view as well.
- **Tab on indented continuation of an action paragraph.** If a writer hits Tab in the middle of an action paragraph (cursor in mid-text), the cycle should operate on the line containing the cursor, not insert a Tab character. NSTextView's default behavior is to insert a tab character — `doCommandBy` overrides that. Mitigation: if the cursor is inside an `.action` line that is part of a multi-line action paragraph, Tab still cycles (and applies a marker if cycling to e.g., Character); writers who need a literal tab character can use Option-Tab (the NSResponder selector for that is `insertTabIgnoringFieldEditor:`, which we don't intercept).
- **InspectorView body type-check ceiling.** The new "Show element gutter" toggle adds another conditional row. Same precaution as 3a's `pageTargetRow()`: factor into a private `@ViewBuilder`. (Note: this toggle goes in `ProjectSettingsSheet`, not `InspectorView`, so the ceiling concern is on a different file but the same pattern applies.)
- **First-time user confusion: "what does Tab do here?".** Without onboarding, the cycle is invisible. Mitigation: the gutter labels make it self-explanatory after the first Tab press (gutter changes, indent changes, marker appears). The 3c `⌘?` help overlay will document the cycle for users who want a reference.
- **Re-parsing on every keystroke.** ScreenplayMode already re-parses on every `textDidChange` (3a). Adding gutter + autocompleter doesn't add new parses — they read from the same `lastParsedScript` cache. Mitigation: ensure the cache is set BEFORE the autocompleter and gutter are notified, so they always read fresh data.

---

## 10. Implementation sequencing (preview for the plan)

Approximate order; ~14-16 tasks. The plan will detail per-task TDD steps with full code blocks.

1. `ScreenplayCycle` enum + pure-logic helpers + tests (~10 tests)
2. `LineNeighborhood` struct + `ScreenplayLineMutator` pure logic + tests (~16 tests)
3. `EditorCoordinator.lastParsedScript` cache + plumbing
4. `EditorCoordinator.doCommandBy` Tab/Shift-Tab dispatch (no autocomplete yet) + line-mutation + cursor positioning
5. Verify Enter behavior is naturally correct (no special handler) via integration test
6. `CharacterAutocompleter` data layer (suggestions + ranking + cap) + tests
7. `CharacterAutocompleter` NSPopover UI (NSTableView + sizing + positioning)
8. Autocomplete keystroke routing in `EditorCoordinator.doCommandBy`
9. `ElementGutterView` NSView subclass: per-line label drawing + abbreviation lookup
10. `ElementGutterView` scroll-sync hooks + repaint on text-change/theme-change
11. `ElementGutterView` mode-conditional integration into `EditorSurface`
12. Project Settings: "Show element gutter" toggle (per-project, default ON for screenplay)
13. Smoke checklist execution; fix any visible regressions; commit with `feat:` / `fix:` discipline
14. Tag `milestone-3b`; push.

Model selection (per banked feedback): pure-logic types = sonnet (substantive). Autocompleter data layer = sonnet (multi-file). NSPopover wiring = opus (NSResponder + lifecycle fiddly). ElementGutterView = opus (NSView + scroll-sync edge cases banked from 2b). Settings toggle = haiku.

---

## 11. Decisions banked during brainstorm

- **Cycle order**: option A (Highland — Action → Character → Dialogue → Parenthetical → Transition).
- **Source mutation on cycle**: option A (apply forced-syntax markers).
- **Autocomplete UX**: option A (NSPopover popup menu).
- **Tab starting point on blank lines**: option A (smart, context-aware via `startingElement(after:)`).
- **Gutter indicator**: option B (included; small abbreviations per non-Action line; per-project toggle).

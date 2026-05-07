# Maugham Phase 1c — Focus Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A focused writing posture in one keystroke. `⌘\` collapses window chrome to a centered text column at the configured page width; `⌘⇧F` adds full-screen on top of that; typewriter scroll keeps the active line vertically centered; sentence and paragraph focus dim everything outside the active region; a quiet goal indicator shows word count and reading time; `⌘S` flashes "Saved." to honour the muscle memory reflex even though autosave already persists. After 1c the editor *feels* like a focus tool, not a generic text view.

**Architecture:** Focus preferences (typewriter, sentence focus, paragraph focus, goal indicators, page-width centering) become persisted `@Observable` properties on `ThemeManager` (deliberately accepting the misnomer for now — see Decisions). `FocusFinder` is a pure-logic helper for sentence/paragraph ranges via `NSAttributedString.enumerateSubstrings`. `EditorCoordinator` gains two behaviors triggered on selection change: (1) typewriter scroll, (2) focus-dim attribute application. `ProseMode` constrains the text container to the configured page width and centers it. `ProjectWindow` grows a no-chrome toggle (`⌘\`), a full-screen command (`⌘⇧F`), a goal indicators footer, and a save-flash overlay; ⌘S is a global app command that posts a notification. Per-window state (`isNoChromeOn`, `isFullScreen`) lives in `@State` and is intentionally not persisted — sticky-per-window, not sticky-globally, per master spec.

**Tech Stack:** Swift 5.10+, SwiftUI, AppKit (NSTextView, NSLayoutManager, NSTextContainer, NSWindow titlebar/toolbar manipulation), Foundation (`NSAttributedString.enumerateSubstrings(in:options: .bySentences/.byParagraphs)`), XCTest. macOS 14+ deployment. xcodegen-managed project.

**Anchor:** This plan implements `Section 2 — The Editor → Focus mode features` (master design lines 218–230) plus the `Focus mode (the most important UI state)` description (line 374). The eight-step manual smoke test in Task 12 maps to those rows of the master spec table.

**Execution branch:** `feat/phase-1c-focus` (created in Task 1; merge to main on milestone tag).

---

## Decisions (call out before implementing)

These shape the work; push back during plan review if any are wrong.

1. **Per-project typography overrides are NOT in 1c.** The 1b plan deferred them to 1c, but they require either an inspector or a "Project Settings…" sheet, and neither has shipped. Cleaner to land 1c as a coherent UX milestone and bring per-project typography in 1d alongside the inspector. If you'd rather pull them in, we'd add a Task between T9 and T10 plus a manifest schema migration in `ProjectManifest`.

2. **Sentence and paragraph focus are separate booleans** (per master spec table), not a tri-state enum. When both are on, sentence focus wins (smaller region). UI exposes them as two checkboxes with a hint that turning sentence on overrides paragraph.

3. **Focus prefs live on `ThemeManager`** even though the name no longer matches what it manages. Renaming to `WritingPreferences` would touch every `@Environment(ThemeManager.self)` site (3 files). Defer the rename to 1d when more prefs accumulate. The cost today is one misnomer; the cost of renaming later is mechanical.

4. **Typewriter scroll** keeps the active line's vertical center at the visible area's vertical center. Triggers on selection change. Smooth scroll (`textView.scrollRangeToVisible` + `setSelectedRange` doesn't smooth; we'll use `NSAnimationContext`).

5. **Focus dimming** is applied as a foreground-color alpha multiplication over the existing token attributes — NOT as a separate dim layer. The non-active region's `.foregroundColor` is replaced with the same color at 0.4 alpha. Re-applied on every selection change AND every text change.

6. **No-chrome mode (⌘\) toggles**: window title bar visibility, toolbar (we don't have one yet so this is a no-op for now), and the project's binder/inspector chrome (also doesn't exist yet). For 1c the visible effect is: title bar disappears, leaving just the centered text column. ESC restores. Per-window state.

7. **Full-screen focus (⌘⇧F)** enters macOS native full-screen and *also* turns on no-chrome. Exiting full-screen (via the green button or ⌘⇧F again) restores no-chrome to its previous state.

8. **⌘S dummy save** posts an app-level notification; `ProjectWindow` listens and shows a "Saved." overlay that fades after 1.2s. Real autosave is unchanged. The user explicitly asked for this reflex (saved in memory `feedback_ux_reflexes.md`).

9. **Goal indicators** is a small label in the project window's bottom-right showing `1,247 words · 6 min read` (using the existing `ProseMode.metrics`). On by default per master spec. Toggleable via Settings → Editor.

10. **Page width is enforced even when no-chrome is OFF** — the centered column is always 70 chars wide (or whatever the user picked). Today the editor fills the full window width which looks careless. This is a small but visible 1c improvement.

---

## File Structure (created or modified during this plan)

```
Maugham/Editor/
  FocusFinder.swift               # NEW — sentence/paragraph range computation
  EditorCoordinator.swift         # MODIFIED — typewriter + focus dim on selection change
  EditorSurface.swift             # MODIFIED — pass prefs into coordinator
  ProseMode.swift                 # MODIFIED — page-width container constraint
Maugham/Theme/
  ThemeManager.swift              # MODIFIED — add focus prefs (4 new properties)
  TypographySettings.swift        # MODIFIED — keep page width, no schema change here
Maugham/Views/
  ProjectWindow.swift             # MODIFIED — no-chrome toggle, full-screen, footer, save flash
  GoalIndicatorView.swift         # NEW — small footer view
  SaveFlashOverlay.swift          # NEW — transient "Saved." overlay
  SettingsTabs/EditorSettingsTab.swift  # MODIFIED — add focus toggles
Maugham/MaughamApp.swift          # MODIFIED — add ⌘S, ⌘\, ⌘⇧F commands
MaughamTests/
  FocusFinderTests.swift          # NEW
  ThemeManagerTests.swift         # MODIFIED — extend with focus prefs persistence tests
```

Two new main-target files (FocusFinder + GoalIndicatorView + SaveFlashOverlay = three actually), plus modifications. One new test file.

---

## Task 1: Create feature branch

**Working directory:** `/Users/denver/src/Maugham`

- [ ] **Step 1: Confirm clean main and create branch**

```bash
git status
git log --oneline -3
git checkout -b feat/phase-1c-focus
```

Expected: working tree clean, latest commits on main are `741ed57` (1b smoke checklist), `0c5a242`, `0c4e18e`. Branch creation prints `Switched to a new branch 'feat/phase-1c-focus'`.

No commit for this task.

---

## Task 2: Extend ThemeManager with focus preferences

**Files:**
- Modify: `Maugham/Theme/ThemeManager.swift`
- Modify: `MaughamTests/ThemeManagerTests.swift`

We're adding four sticky-globally preferences that the focus features read: `typewriterScroll`, `sentenceFocus`, `paragraphFocus`, `goalIndicatorsVisible`. Each persists in UserDefaults under its own key.

- [ ] **Step 1: Add failing tests**

Append to `MaughamTests/ThemeManagerTests.swift` inside the existing `ThemeManagerTests` class (before the closing `}`):

```swift
    func test_freshManager_focusPrefsHaveExpectedDefaults() {
        XCTAssertFalse(manager.typewriterScroll)
        XCTAssertFalse(manager.sentenceFocus)
        XCTAssertFalse(manager.paragraphFocus)
        XCTAssertTrue(manager.goalIndicatorsVisible)
    }

    func test_typewriterScrollMutation_persists() {
        manager.typewriterScroll = true
        let other = ThemeManager(defaults: defaults)
        XCTAssertTrue(other.typewriterScroll)
    }

    func test_sentenceFocusMutation_persists() {
        manager.sentenceFocus = true
        let other = ThemeManager(defaults: defaults)
        XCTAssertTrue(other.sentenceFocus)
    }

    func test_paragraphFocusMutation_persists() {
        manager.paragraphFocus = true
        let other = ThemeManager(defaults: defaults)
        XCTAssertTrue(other.paragraphFocus)
    }

    func test_goalIndicatorsMutation_persists() {
        manager.goalIndicatorsVisible = false
        let other = ThemeManager(defaults: defaults)
        XCTAssertFalse(other.goalIndicatorsVisible)
    }
```

- [ ] **Step 2: Regenerate, run tests, expect 5 failures (compile errors — properties not found)**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ThemeManagerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error `value of type 'ThemeManager' has no member 'typewriterScroll'` (and similar).

- [ ] **Step 3: Implement properties on ThemeManager**

Replace the entire body of `Maugham/Theme/ThemeManager.swift` with:

```swift
import Foundation
import SwiftUI

/// Reads / writes user-level theme + typography + focus preferences via
/// UserDefaults. Observable so SwiftUI views update automatically.
///
/// NOTE: name is becoming a misnomer as it now also manages focus prefs.
/// Rename to `WritingPreferences` is deferred to milestone 1d when more
/// prefs accumulate.
@MainActor
@Observable
public final class ThemeManager {
    private static let themeKey = "maugham.theme"
    private static let typographyKey = "maugham.typography"
    private static let typewriterKey = "maugham.typewriterScroll"
    private static let sentenceFocusKey = "maugham.sentenceFocus"
    private static let paragraphFocusKey = "maugham.paragraphFocus"
    private static let goalIndicatorsKey = "maugham.goalIndicatorsVisible"

    private let defaults: UserDefaults

    public var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: Self.themeKey) }
    }

    public var typography: TypographySettings {
        didSet {
            if let data = try? JSONEncoder().encode(typography) {
                defaults.set(data, forKey: Self.typographyKey)
            }
        }
    }

    public var typewriterScroll: Bool {
        didSet { defaults.set(typewriterScroll, forKey: Self.typewriterKey) }
    }

    public var sentenceFocus: Bool {
        didSet { defaults.set(sentenceFocus, forKey: Self.sentenceFocusKey) }
    }

    public var paragraphFocus: Bool {
        didSet { defaults.set(paragraphFocus, forKey: Self.paragraphFocusKey) }
    }

    public var goalIndicatorsVisible: Bool {
        didSet {
            defaults.set(goalIndicatorsVisible, forKey: Self.goalIndicatorsKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let raw = defaults.string(forKey: Self.themeKey),
           let t = Theme(rawValue: raw) {
            self.theme = t
        } else {
            self.theme = .followSystem
        }

        if let data = defaults.data(forKey: Self.typographyKey),
           let t = try? JSONDecoder().decode(TypographySettings.self, from: data) {
            self.typography = t
        } else {
            self.typography = .defaults
        }

        // Bool defaults: UserDefaults.bool returns false for missing keys, so
        // we use object(forKey:) to distinguish "absent" from "explicitly false".
        self.typewriterScroll =
            defaults.object(forKey: Self.typewriterKey) as? Bool ?? false
        self.sentenceFocus =
            defaults.object(forKey: Self.sentenceFocusKey) as? Bool ?? false
        self.paragraphFocus =
            defaults.object(forKey: Self.paragraphFocusKey) as? Bool ?? false
        self.goalIndicatorsVisible =
            defaults.object(forKey: Self.goalIndicatorsKey) as? Bool ?? true
    }
}
```

- [ ] **Step 4: Regenerate, run, expect all ThemeManager tests passing (4 original + 5 new = 9)**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ThemeManagerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Maugham/Theme/ThemeManager.swift MaughamTests/ThemeManagerTests.swift
git commit -m "feat: add focus preferences to ThemeManager"
```

---

## Task 3: FocusFinder — sentence/paragraph range computation

**Files:**
- Create: `Maugham/Editor/FocusFinder.swift`
- Create: `MaughamTests/FocusFinderTests.swift`

Pure logic for "given text and a cursor location, what's the sentence/paragraph containing it?". Uses Foundation's built-in tokenizers via `NSString.enumerateSubstrings(in:options:)`.

- [ ] **Step 1: Write failing tests**

`MaughamTests/FocusFinderTests.swift`:
```swift
import XCTest
@testable import Maugham

final class FocusFinderTests: XCTestCase {

    // MARK: - Sentences

    func test_sentenceRange_inSingleSentence_returnsWholeText() {
        let text = "Just a sentence."
        let range = FocusFinder.sentenceRange(in: text, cursor: 5)
        XCTAssertEqual(text.trimmedRange(range), "Just a sentence.")
    }

    func test_sentenceRange_picksContainingSentence() {
        let text = "First sentence. Second sentence. Third."
        // Cursor inside "Second sentence."
        let range = FocusFinder.sentenceRange(in: text, cursor: 18)
        XCTAssertEqual(text.trimmedRange(range), "Second sentence.")
    }

    func test_sentenceRange_atSentenceBoundary_picksFollowingSentence() {
        let text = "First. Second."
        // Cursor right after the period of "First."
        let range = FocusFinder.sentenceRange(in: text, cursor: 7)
        XCTAssertEqual(text.trimmedRange(range), "Second.")
    }

    func test_sentenceRange_emptyText_returnsZeroRange() {
        let range = FocusFinder.sentenceRange(in: "", cursor: 0)
        XCTAssertEqual(range, NSRange(location: 0, length: 0))
    }

    func test_sentenceRange_cursorBeyondText_clampsToLastSentence() {
        let text = "Only one."
        let range = FocusFinder.sentenceRange(in: text, cursor: 999)
        XCTAssertEqual(text.trimmedRange(range), "Only one.")
    }

    // MARK: - Paragraphs

    func test_paragraphRange_inSingleParagraph_returnsWholeText() {
        let text = "A single paragraph with several sentences. Like this."
        let range = FocusFinder.paragraphRange(in: text, cursor: 10)
        XCTAssertEqual(text.trimmedRange(range), text)
    }

    func test_paragraphRange_picksContainingParagraph() {
        let text = "First para.\n\nSecond para has\ntwo lines.\n\nThird."
        // Cursor inside "Second para has\ntwo lines."
        let range = FocusFinder.paragraphRange(in: text, cursor: 18)
        XCTAssertEqual(
            text.trimmedRange(range),
            "Second para has\ntwo lines."
        )
    }

    func test_paragraphRange_emptyText_returnsZeroRange() {
        let range = FocusFinder.paragraphRange(in: "", cursor: 0)
        XCTAssertEqual(range, NSRange(location: 0, length: 0))
    }
}

private extension String {
    func trimmedRange(_ range: NSRange) -> String {
        let nsText = self as NSString
        guard NSMaxRange(range) <= nsText.length else { return "" }
        return nsText
            .substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 2: Regenerate, run, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FocusFinderTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `cannot find 'FocusFinder' in scope`.

- [ ] **Step 3: Implement FocusFinder**

`Maugham/Editor/FocusFinder.swift`:
```swift
import Foundation

/// Given a body of text and a cursor location, returns the range of the
/// containing sentence or paragraph. Used by the editor to compute the
/// "active region" for sentence/paragraph focus dimming.
public enum FocusFinder {

    public static func sentenceRange(in text: String, cursor: Int) -> NSRange {
        rangeOf(.bySentences, in: text, cursor: cursor)
    }

    public static func paragraphRange(in text: String, cursor: Int) -> NSRange {
        rangeOf(.byParagraphs, in: text, cursor: cursor)
    }

    private static func rangeOf(
        _ option: NSString.EnumerationOptions,
        in text: String,
        cursor: Int
    ) -> NSRange {
        let nsText = text as NSString
        guard nsText.length > 0 else { return NSRange(location: 0, length: 0) }

        // Clamp cursor into [0, length]. Cursor at end clamps to last unit.
        let clamped = max(0, min(cursor, nsText.length))
        // For cursor at end-of-string, step back by 1 so the enumerator hits
        // the final unit (it iterates over substrings, not gaps).
        let probe = clamped == nsText.length ? max(0, clamped - 1) : clamped

        var found = NSRange(location: 0, length: nsText.length)
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [option, .substringNotRequired]
        ) { _, range, _, stop in
            if NSLocationInRange(probe, range)
                || (range.location == probe) {
                found = range
                stop.pointee = true
            }
        }
        return found
    }
}
```

- [ ] **Step 4: Regenerate, run, expect 8 tests passing**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FocusFinderTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

If a test fails because of how `enumerateSubstrings` handles whitespace adjacency, iterate on the helper logic — NOT the test. The test cases reflect the spec's "the active region around the cursor" intent.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/FocusFinder.swift MaughamTests/FocusFinderTests.swift
git commit -m "feat: add FocusFinder for sentence and paragraph ranges"
```

---

## Task 4: Centered, page-width text container in ProseMode

**Files:**
- Modify: `Maugham/Editor/ProseMode.swift`
- Modify: `Maugham/Editor/EditorSurface.swift`

The editor currently fills the full window width. We constrain it to `pageWidthCharacters × em-width` and center it horizontally with theme-colored gutters. This change is visual; tests stay smoke-build.

- [ ] **Step 1: Add a public typography metrics helper to ProseMode**

The container width depends on the body font. Add a public method that ProseMode can compute and the surface can apply.

In `Maugham/Editor/ProseMode.swift`, add this method after `bodyTypingAttributes`:

```swift
    /// Width of the body text column, in points, given the configured page
    /// width (in characters) and current font. Uses a generous "M" glyph
    /// width as the per-character estimate.
    public func textColumnWidth(
        typography: TypographySettings
    ) -> CGFloat {
        let font = baseFont(for: typography)
        let em = ("M" as NSString)
            .size(withAttributes: [.font: font]).width
        return em * CGFloat(typography.pageWidthCharacters)
    }
```

Also add the matching protocol requirement to `Maugham/Editor/WritingMode.swift` — append before the closing brace of `protocol WritingMode`:

```swift
    /// Body text column width in points, given the configured page width.
    func textColumnWidth(typography: TypographySettings) -> CGFloat
```

- [ ] **Step 2: Apply container width in EditorSurface**

In `Maugham/Editor/EditorSurface.swift`, modify `makeNSView` to size the text container to the configured column width and let the scroll view handle horizontal centering via `textContainerInset`. Replace the `makeNSView` body with:

```swift
    func makeNSView(context: Context) -> NSScrollView {
        let textView = MaughamTextView()
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.delegate = context.coordinator
        textView.string = text
        textView.textContainerInset = NSSize(width: 0, height: 24)

        // Constrain text container to a fixed column width so long lines wrap
        // at pageWidthCharacters even when the window is wide.
        if let container = textView.textContainer {
            let columnWidth = mode.textColumnWidth(typography: typography)
            container.widthTracksTextView = false
            container.size = NSSize(width: columnWidth,
                                    height: .greatestFiniteMagnitude)
            textView.frame = NSRect(x: 0, y: 0,
                                    width: columnWidth, height: 0)
        }

        let scrollView = CenteringScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        context.coordinator.attach(to: textView)
        return scrollView
    }
```

Then update `updateNSView` to recompute the column width when typography changes. Replace its body with:

```swift
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.applyExternalText(text)
        }
        if context.coordinator.theme != theme
            || context.coordinator.typography != typography {
            context.coordinator.applyAppearance(
                theme: theme, typography: typography)

            if let container = textView.textContainer {
                let columnWidth = mode.textColumnWidth(typography: typography)
                container.size = NSSize(width: columnWidth,
                                        height: .greatestFiniteMagnitude)
                textView.frame.size.width = columnWidth
                scrollView.needsLayout = true
            }
        }
    }
```

Finally add the `CenteringScrollView` private subclass after `MaughamTextView`:

```swift
/// NSScrollView subclass that horizontally centers its document view inside
/// the visible area whenever the document is narrower than the clip view.
private final class CenteringScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let documentView else { return }
        let clipBounds = contentView.bounds
        let docFrame = documentView.frame
        if docFrame.size.width < clipBounds.width {
            var origin = documentView.frame.origin
            origin.x = (clipBounds.width - docFrame.size.width) / 2
            documentView.frame.origin = origin
        }
    }
}
```

- [ ] **Step 3: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run full test suite to confirm no regressions**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```

Expected: 85 tests passing (77 from before + 5 ThemeManager + 8 FocusFinder − 5 already counted = … actually 77 + 5 + 8 = 90). Recount: 1b shipped 77 total. T2 added 5 to ThemeManagerTests. T3 added 8 in FocusFinderTests. So 77 + 5 + 8 = 90 total expected.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/ProseMode.swift Maugham/Editor/EditorSurface.swift Maugham/Editor/WritingMode.swift
git commit -m "feat: constrain editor to centered page-width column"
```

---

## Task 5: Typewriter scroll in EditorCoordinator

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`
- Modify: `Maugham/Editor/EditorSurface.swift`

When `typewriterScroll` is on, after every selection change scroll the text view so the active line's vertical center sits at the visible area's vertical center. Smoke-build only.

- [ ] **Step 1: Add typewriter setting to coordinator**

In `Maugham/Editor/EditorCoordinator.swift`, add a stored property for typewriter scroll alongside theme/typography. Replace the `init` and add a setter method.

Modify the property block at the top of the class to include:

```swift
    private var binding: Binding<String>
    private let mode: any WritingMode
    private(set) var theme: Theme
    private(set) var typography: TypographySettings
    private(set) var typewriterScroll: Bool

    private var isApplyingExternalUpdate = false
    weak var textView: NSTextView?
```

Update `init` signature and body:

```swift
    init(text: Binding<String>,
         mode: any WritingMode,
         theme: Theme,
         typography: TypographySettings,
         typewriterScroll: Bool) {
        self.binding = text
        self.mode = mode
        self.theme = theme
        self.typography = typography
        self.typewriterScroll = typewriterScroll
    }
```

Add a method to update the typewriter setting:

```swift
    func applyTypewriterScroll(_ enabled: Bool) {
        self.typewriterScroll = enabled
        guard enabled, let textView else { return }
        scrollSelectionToVerticalCenter(in: textView)
    }
```

Implement the scroll helper at the bottom of the class (above the closing `}`):

```swift
    private func scrollSelectionToVerticalCenter(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: textView.selectedRange(),
            actualCharacterRange: nil)
        let lineRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: textContainer)
        let viewRect = textView.convert(lineRect, to: nil)
        guard let scrollView = textView.enclosingScrollView else { return }
        let visible = scrollView.contentView.documentVisibleRect
        let targetY = lineRect.midY - visible.height / 2
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        _ = viewRect  // silence unused-variable warning
    }
```

In the existing `textDidChange` and `textViewDidChangeSelection` paths, invoke the scroll helper when typewriter mode is on. Add a new delegate method below `textDidChange`:

```swift
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              !isApplyingExternalUpdate else { return }
        if typewriterScroll {
            scrollSelectionToVerticalCenter(in: textView)
        }
    }
```

And in `textDidChange`, after the `binding.wrappedValue = ...` line, add:

```swift
        if typewriterScroll {
            scrollSelectionToVerticalCenter(in: textView)
        }
```

- [ ] **Step 2: Pass typewriterScroll through EditorSurface**

In `Maugham/Editor/EditorSurface.swift`, add a new field to the struct and forward it to the coordinator. After `let mode: any WritingMode`, add:

```swift
    let typewriterScroll: Bool
```

Update `makeCoordinator`:

```swift
    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(
            text: $text, mode: mode,
            theme: theme, typography: typography,
            typewriterScroll: typewriterScroll)
    }
```

In `updateNSView`, after the existing appearance check, add:

```swift
        if context.coordinator.typewriterScroll != typewriterScroll {
            context.coordinator.applyTypewriterScroll(typewriterScroll)
        }
```

- [ ] **Step 3: Update ProjectWindow callsite**

In `Maugham/Views/ProjectWindow.swift`, the `EditorSurface(...)` invocation now requires `typewriterScroll`. Replace the EditorSurface call with:

```swift
                EditorSurface(
                    text: Binding(
                        get: { store.manuscriptText },
                        set: { newValue in
                            store.manuscriptText = newValue
                            Task { try? await store.save() }
                        }
                    ),
                    theme: themeManager.theme,
                    typography: themeManager.typography,
                    mode: ProseMode(),
                    typewriterScroll: themeManager.typewriterScroll
                )
```

- [ ] **Step 4: Smoke-build + tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(Executed |TEST FAILED|TEST SUCCEEDED)" | tail -3
```

Expected: 90 tests passing, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/EditorCoordinator.swift Maugham/Editor/EditorSurface.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: typewriter scroll keeps active line vertically centered"
```

---

## Task 6: Sentence and paragraph focus dimming

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift`
- Modify: `Maugham/Editor/EditorSurface.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

When `sentenceFocus` or `paragraphFocus` is on, dim everything outside the active region by replacing foreground colors with their 0.4-alpha version. Triggered on selection change AND text change. Sentence focus wins when both are on.

- [ ] **Step 1: Add focus settings to coordinator**

In `Maugham/Editor/EditorCoordinator.swift`, add two more properties next to `typewriterScroll`:

```swift
    private(set) var sentenceFocus: Bool
    private(set) var paragraphFocus: Bool
```

Update the init signature to:

```swift
    init(text: Binding<String>,
         mode: any WritingMode,
         theme: Theme,
         typography: TypographySettings,
         typewriterScroll: Bool,
         sentenceFocus: Bool,
         paragraphFocus: Bool) {
        self.binding = text
        self.mode = mode
        self.theme = theme
        self.typography = typography
        self.typewriterScroll = typewriterScroll
        self.sentenceFocus = sentenceFocus
        self.paragraphFocus = paragraphFocus
    }
```

Add a setter method for focus prefs:

```swift
    func applyFocusPrefs(sentence: Bool, paragraph: Bool) {
        self.sentenceFocus = sentence
        self.paragraphFocus = paragraph
        guard let textView else { return }
        retokenizeAndStyle()
        applyFocusDim(in: textView)
    }
```

Modify `retokenizeAndStyle` to also call `applyFocusDim`:

```swift
    private func retokenizeAndStyle() {
        guard let textView, let storage = textView.textStorage else { return }
        let tokens = mode.tokenize(textView.string)
        mode.applyTypography(
            in: storage,
            theme: theme,
            typography: typography,
            tokens: tokens)
        textView.typingAttributes = mode.bodyTypingAttributes(
            theme: theme, typography: typography)
        applyFocusDim(in: textView)
    }
```

Modify `textViewDidChangeSelection` to also dim:

```swift
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              !isApplyingExternalUpdate else { return }
        if typewriterScroll {
            scrollSelectionToVerticalCenter(in: textView)
        }
        applyFocusDim(in: textView)
    }
```

Implement `applyFocusDim`:

```swift
    private func applyFocusDim(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let useSentence = sentenceFocus
        let useParagraph = paragraphFocus && !sentenceFocus
        guard useSentence || useParagraph else { return }

        let cursor = textView.selectedRange().location
        let activeRange = useSentence
            ? FocusFinder.sentenceRange(in: textView.string, cursor: cursor)
            : FocusFinder.paragraphRange(in: textView.string, cursor: cursor)

        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }

        storage.beginEditing()
        // Dim everything before the active range
        if activeRange.location > 0 {
            dim(storage, in: NSRange(location: 0, length: activeRange.location))
        }
        // Dim everything after the active range
        let afterStart = NSMaxRange(activeRange)
        if afterStart < fullRange.length {
            dim(storage,
                in: NSRange(location: afterStart,
                            length: fullRange.length - afterStart))
        }
        storage.endEditing()
    }

    private func dim(_ storage: NSTextStorage, in range: NSRange) {
        storage.enumerateAttribute(
            .foregroundColor, in: range, options: []
        ) { value, subrange, _ in
            guard let color = value as? NSColor else { return }
            let dimmed = color.withAlphaComponent(0.4)
            storage.addAttribute(.foregroundColor,
                                  value: dimmed, range: subrange)
        }
    }
```

- [ ] **Step 2: Pass focus prefs through EditorSurface**

In `Maugham/Editor/EditorSurface.swift`, add two more fields:

```swift
    let sentenceFocus: Bool
    let paragraphFocus: Bool
```

Update `makeCoordinator`:

```swift
    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(
            text: $text, mode: mode,
            theme: theme, typography: typography,
            typewriterScroll: typewriterScroll,
            sentenceFocus: sentenceFocus,
            paragraphFocus: paragraphFocus)
    }
```

In `updateNSView`, after the typewriter check, add:

```swift
        if context.coordinator.sentenceFocus != sentenceFocus
            || context.coordinator.paragraphFocus != paragraphFocus {
            context.coordinator.applyFocusPrefs(
                sentence: sentenceFocus, paragraph: paragraphFocus)
        }
```

- [ ] **Step 3: Update ProjectWindow callsite**

Add the two new arguments to the EditorSurface invocation in `Maugham/Views/ProjectWindow.swift`:

```swift
                EditorSurface(
                    text: Binding(
                        get: { store.manuscriptText },
                        set: { newValue in
                            store.manuscriptText = newValue
                            Task { try? await store.save() }
                        }
                    ),
                    theme: themeManager.theme,
                    typography: themeManager.typography,
                    mode: ProseMode(),
                    typewriterScroll: themeManager.typewriterScroll,
                    sentenceFocus: themeManager.sentenceFocus,
                    paragraphFocus: themeManager.paragraphFocus
                )
```

- [ ] **Step 4: Smoke-build + tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(Executed |TEST FAILED|TEST SUCCEEDED)" | tail -3
```

Expected: 90 tests passing, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/EditorCoordinator.swift Maugham/Editor/EditorSurface.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: sentence and paragraph focus dim non-active regions"
```

---

## Task 7: Settings UI for focus toggles

**Files:**
- Modify: `Maugham/Views/SettingsTabs/EditorSettingsTab.swift`

Add focus mode toggles to the existing Editor tab. Group them under a "Focus" section. The toggles bind directly to `themeManager` properties via `@Bindable`.

- [ ] **Step 1: Add focus section to EditorSettingsTab**

Replace the entire body of `Maugham/Views/SettingsTabs/EditorSettingsTab.swift` with:

```swift
import SwiftUI

struct EditorSettingsTab: View {
    @Bindable var themeManager: ThemeManager

    var body: some View {
        Form {
            Section("Typography") {
                Picker("Font", selection: Binding(
                    get: { themeManager.typography.fontFamily },
                    set: { themeManager.typography.fontFamily = $0 }
                )) {
                    ForEach(TypographySettings.curatedFonts, id: \.fontName) { font in
                        Text(font.displayName).tag(font.fontName)
                    }
                }
                .pickerStyle(.menu)

                Stepper(
                    "Size: \(themeManager.typography.fontSize) pt",
                    value: Binding(
                        get: { themeManager.typography.fontSize },
                        set: { themeManager.typography.fontSize = $0 }
                    ),
                    in: 12...24
                )

                VStack(alignment: .leading) {
                    Text("Line height: \(String(format: "%.2f", themeManager.typography.lineHeightMultiplier))")
                    Slider(value: Binding(
                        get: { themeManager.typography.lineHeightMultiplier },
                        set: { themeManager.typography.lineHeightMultiplier = $0 }
                    ), in: 1.4...2.0, step: 0.05)
                }

                Stepper(
                    "Page width: \(themeManager.typography.pageWidthCharacters) chars",
                    value: Binding(
                        get: { themeManager.typography.pageWidthCharacters },
                        set: { themeManager.typography.pageWidthCharacters = $0 }
                    ),
                    in: 60...90
                )

                VStack(alignment: .leading) {
                    Text("Paragraph spacing: \(String(format: "%.1f", themeManager.typography.paragraphSpacingMultiplier))×")
                    Slider(value: Binding(
                        get: { themeManager.typography.paragraphSpacingMultiplier },
                        set: { themeManager.typography.paragraphSpacingMultiplier = $0 }
                    ), in: 0.0...2.0, step: 0.1)
                }
            }

            Section("Focus") {
                Toggle("Typewriter scrolling",
                       isOn: $themeManager.typewriterScroll)
                Toggle("Sentence focus",
                       isOn: $themeManager.sentenceFocus)
                Toggle("Paragraph focus",
                       isOn: $themeManager.paragraphFocus)
                Text("Sentence focus, when on, takes precedence over paragraph focus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show goal indicators",
                       isOn: $themeManager.goalIndicatorsVisible)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/SettingsTabs/EditorSettingsTab.swift
git commit -m "feat: settings UI for focus prefs (typewriter, focus, goal indicators)"
```

---

## Task 8: No-chrome mode (⌘\)

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift`
- Modify: `Maugham/MaughamApp.swift`

`⌘\` toggles a per-window "no chrome" state. Visible effect: title bar hides; the centered text column remains. ESC restores. Per master spec, this state is per-window and not persisted.

- [ ] **Step 1: Add no-chrome state to ProjectWindow**

In `Maugham/Views/ProjectWindow.swift`, add a new state property and a notification observer. Replace the struct body with the following — keeping the existing `body` group structure and `load()` method, but inserting `@State private var isNoChromeOn` and the `.onReceive` modifiers:

Add these properties near the top of `struct ProjectWindow`:

```swift
    @State private var isNoChromeOn: Bool = false
    @State private var window: NSWindow?
```

Wrap the `Group { ... }` in a `ZStack` so we can later add the save flash overlay. Replace the `var body: some View { ... }` block with:

```swift
    var body: some View {
        Group {
            if let store {
                ZStack(alignment: .bottomTrailing) {
                    EditorSurface(
                        text: Binding(
                            get: { store.manuscriptText },
                            set: { newValue in
                                store.manuscriptText = newValue
                                Task { try? await store.save() }
                            }
                        ),
                        theme: themeManager.theme,
                        typography: themeManager.typography,
                        mode: ProseMode(),
                        typewriterScroll: themeManager.typewriterScroll,
                        sentenceFocus: themeManager.sentenceFocus,
                        paragraphFocus: themeManager.paragraphFocus
                    )
                }
                .navigationTitle(store.manifest.title)
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Couldn't open project")
                        .font(.headline)
                    Text(loadError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(48)
            } else {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(WindowAccessor(window: $window))
        .task(id: url) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleNoChrome)) { _ in
            isNoChromeOn.toggle()
            applyNoChrome()
        }
        .onChange(of: isNoChromeOn) { _, _ in
            applyNoChrome()
        }
    }

    private func applyNoChrome() {
        guard let window else { return }
        window.titlebarAppearsTransparent = isNoChromeOn
        window.titleVisibility = isNoChromeOn ? .hidden : .visible
        window.standardWindowButton(.closeButton)?.isHidden = isNoChromeOn
        window.standardWindowButton(.miniaturizeButton)?.isHidden = isNoChromeOn
        window.standardWindowButton(.zoomButton)?.isHidden = isNoChromeOn
    }
```

Add the notification name and the `WindowAccessor` helper at the bottom of the file (outside the `ProjectWindow` struct):

```swift
extension Notification.Name {
    static let maughamToggleNoChrome =
        Notification.Name("maugham.toggleNoChrome")
    static let maughamToggleFullScreen =
        Notification.Name("maugham.toggleFullScreen")
    static let maughamDummySave =
        Notification.Name("maugham.dummySave")
}

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if self.window == nil {
                self.window = nsView.window
            }
        }
    }
}
```

- [ ] **Step 2: Add ⌘\ command to MaughamApp**

In `Maugham/MaughamApp.swift`, extend the `.commands` block on the welcome window. Replace the existing commands block with:

```swift
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") {
                    NotificationCenter.default.post(name: .maughamNewProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Project…") {
                    NotificationCenter.default.post(name: .maughamOpenProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("View") {
                Button("Toggle Focus Mode") {
                    NotificationCenter.default.post(
                        name: .maughamToggleNoChrome, object: nil)
                }
                .keyboardShortcut("\\", modifiers: .command)
                Button("Toggle Full-Screen Focus") {
                    NotificationCenter.default.post(
                        name: .maughamToggleFullScreen, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
```

- [ ] **Step 3: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/ProjectWindow.swift Maugham/MaughamApp.swift
git commit -m "feat: ⌘\\ toggles no-chrome focus mode (per-window)"
```

---

## Task 9: Full-screen focus (⌘⇧F)

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift`

`⌘⇧F` toggles macOS native full-screen and auto-enables no-chrome on entering. Exiting full-screen via the green button does NOT auto-disable no-chrome (user can ⌘\ separately).

- [ ] **Step 1: Add full-screen toggle handler**

In `Maugham/Views/ProjectWindow.swift`, add another `.onReceive` to the `body` chain (after the existing toggleNoChrome one):

```swift
        .onReceive(NotificationCenter.default.publisher(for: .maughamToggleFullScreen)) { _ in
            toggleFullScreen()
        }
```

Add the helper method below `applyNoChrome`:

```swift
    private func toggleFullScreen() {
        guard let window else { return }
        let wasFullScreen = window.styleMask.contains(.fullScreen)
        if !wasFullScreen && !isNoChromeOn {
            isNoChromeOn = true
            applyNoChrome()
        }
        window.toggleFullScreen(nil)
    }
```

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/ProjectWindow.swift
git commit -m "feat: ⌘⇧F enters full-screen and turns on no-chrome"
```

---

## Task 10: Goal indicators footer

**Files:**
- Create: `Maugham/Views/GoalIndicatorView.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

A small unobtrusive label in the project window's bottom-right corner showing word count and reading time. Updates live as the user types. Hidden when `goalIndicatorsVisible` is off.

- [ ] **Step 1: Implement GoalIndicatorView**

`Maugham/Views/GoalIndicatorView.swift`:
```swift
import SwiftUI

struct GoalIndicatorView: View {
    let metrics: EditorMetrics

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .regular, design: .default))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .padding(12)
    }

    private var label: String {
        let words = metrics.wordCount
        let mins = metrics.readingMinutes
        let wordsLabel = words.formatted(.number)
        if mins == 0 {
            return "\(wordsLabel) words"
        }
        return "\(wordsLabel) words · \(mins) min read"
    }
}
```

- [ ] **Step 2: Add metrics state and footer to ProjectWindow**

In `Maugham/Views/ProjectWindow.swift`, add a state property:

```swift
    @State private var metrics: EditorMetrics =
        EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0)
```

Inside the `ZStack(alignment: .bottomTrailing) { ... }`, add the indicator after the `EditorSurface(...)` block:

```swift
                    if themeManager.goalIndicatorsVisible {
                        GoalIndicatorView(metrics: metrics)
                    }
```

Update the EditorSurface's `set:` closure to recompute metrics on text change:

```swift
                        set: { newValue in
                            store.manuscriptText = newValue
                            metrics = ProseMode().metrics(newValue)
                            Task { try? await store.save() }
                        }
```

And in `load()`, set initial metrics after the store loads:

Replace `loadError = nil` (the line right after `store = try await ProjectStore.load(from: url)`) with:

```swift
            store = try await ProjectStore.load(from: url)
            if let store {
                metrics = ProseMode().metrics(store.manuscriptText)
            }
            loadError = nil
```

- [ ] **Step 3: Smoke-build + tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "(Executed |TEST FAILED|TEST SUCCEEDED)" | tail -3
```

Expected: 90 tests passing, `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/GoalIndicatorView.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat: quiet goal indicators footer (word count, reading time)"
```

---

## Task 11: ⌘S dummy save flash

**Files:**
- Create: `Maugham/Views/SaveFlashOverlay.swift`
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

`⌘S` posts a `maughamDummySave` notification at the app level. `ProjectWindow` listens, shows a transient "Saved." capsule that fades after 1.2s. Real autosave is unchanged. Honours the user's reflex even when redundant.

- [ ] **Step 1: Implement SaveFlashOverlay**

`Maugham/Views/SaveFlashOverlay.swift`:
```swift
import SwiftUI

struct SaveFlashOverlay: View {
    @Binding var isShowing: Bool

    var body: some View {
        Group {
            if isShowing {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Saved")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 16)
        .animation(.easeInOut(duration: 0.18), value: isShowing)
    }
}
```

- [ ] **Step 2: Add ⌘S command to MaughamApp**

In `Maugham/MaughamApp.swift`, add a Save command to the `.commands` block. After the existing `CommandMenu("View")` block, append a `CommandGroup`:

```swift
            CommandGroup(after: .saveItem) {
                Button("Save") {
                    NotificationCenter.default.post(
                        name: .maughamDummySave, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
```

- [ ] **Step 3: Wire flash overlay into ProjectWindow**

In `Maugham/Views/ProjectWindow.swift`, add a state property:

```swift
    @State private var showingSaveFlash: Bool = false
```

Inside the `ZStack` (change the ZStack alignment to `.top` since the flash sits at the top, or layer two ZStacks). Actually keep `.bottomTrailing` as the outer alignment for the goal indicator and add a `.overlay(alignment: .top)` on the EditorSurface for the flash. Replace the inner EditorSurface block (everything between `ZStack(alignment: .bottomTrailing) {` and the `if themeManager.goalIndicatorsVisible` line) with:

```swift
                    EditorSurface(
                        text: Binding(
                            get: { store.manuscriptText },
                            set: { newValue in
                                store.manuscriptText = newValue
                                metrics = ProseMode().metrics(newValue)
                                Task { try? await store.save() }
                            }
                        ),
                        theme: themeManager.theme,
                        typography: themeManager.typography,
                        mode: ProseMode(),
                        typewriterScroll: themeManager.typewriterScroll,
                        sentenceFocus: themeManager.sentenceFocus,
                        paragraphFocus: themeManager.paragraphFocus
                    )
                    .overlay(alignment: .top) {
                        SaveFlashOverlay(isShowing: $showingSaveFlash)
                    }
```

Add a new `.onReceive` modifier on the `body` chain:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .maughamDummySave)) { _ in
            showSaveFlash()
        }
```

Add the helper method below `toggleFullScreen()`:

```swift
    @MainActor
    private func showSaveFlash() {
        showingSaveFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            await MainActor.run { showingSaveFlash = false }
        }
    }
```

- [ ] **Step 4: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/SaveFlashOverlay.swift Maugham/Views/ProjectWindow.swift Maugham/MaughamApp.swift
git commit -m "feat: ⌘S flashes 'Saved' for muscle-memory reflex"
```

---

## Task 12: End-to-end smoke test + tag milestone-1c

- [ ] **Step 1: Run the full test suite**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep "Executed " | tail -1
```

Expected: 90 tests passing (77 from 1b + 5 ThemeManager + 8 FocusFinder).

- [ ] **Step 2: Manual smoke test (eight steps from master spec table)**

In Xcode, ⌘R to run, or `open` the built `.app`. Walk these eight checks:

1. Open a project from Recents. Editor renders in a centered text column at 70 chars wide with theme-colored gutters on either side. Resize the window — the column stays centered.
2. Settings (⌘,) → Editor → Focus → toggle "Typewriter scrolling" on. Type a few lines. The active line stays at the vertical center.
3. Settings → Focus → toggle "Sentence focus" on. Type a paragraph. Only the current sentence is full-color; the rest dims to 0.4 alpha.
4. Toggle "Sentence focus" off, "Paragraph focus" on. Now only the current paragraph is full-color.
5. Press `⌘\`. Title bar hides. Press `⌘\` again — title bar restores. (Note: ESC restores too in macOS 14+ when titlebar is transparent? Actually the ESC handling is implicit via the keystroke — verify the window behavior.)
6. Press `⌘⇧F`. Window enters full-screen with no-chrome already on. Press `⌘⇧F` again to exit.
7. Goal indicator visible at bottom-right showing word count and reading time. Type more — counters update live. Settings → Focus → uncheck "Show goal indicators" — capsule disappears.
8. Press `⌘S` while editing. A "Saved" capsule briefly fades in at the top-center then fades out after ~1.2s. (No actual change to disk — autosave already does that — but the reflex is honoured.)

If all eight pass, milestone 1c is healthy.

- [ ] **Step 3: Tag milestone-1c and merge to main**

```bash
git checkout main
git merge --ff-only feat/phase-1c-focus
git tag -a milestone-1c -m "Maugham milestone 1c — Focus Chrome

Centered page-width column; typewriter scroll; sentence and paragraph
focus dimming; ⌘\\ no-chrome mode; ⌘⇧F full-screen focus; quiet goal
indicators (word count + reading time); ⌘S dummy save flash for
muscle-memory reflex. Focus prefs persist via UserDefaults; per-window
state (no-chrome, full-screen) intentionally not persisted per spec."
git tag --list 'milestone-*'
```

Expected: `milestone-1a milestone-1b milestone-1c` listed.

- [ ] **Step 4: Update README**

Append after the existing 1b smoke section in `README.md`:

```markdown

## Phase 1c smoke test

Once running on milestone-1c:

1. Open a project from Recents. Editor sits in a centered 70-char column with theme-colored gutters; resizing keeps it centered.
2. Settings → Editor → Focus → enable Typewriter scrolling. Active line stays at the vertical center as you type.
3. Enable Sentence focus. Only the current sentence is full color; the rest dims.
4. Switch to Paragraph focus. The current paragraph is full color; siblings dim.
5. ⌘\\ hides the title bar; press again to restore.
6. ⌘⇧F enters full-screen with no-chrome already on; ⌘⇧F again exits.
7. Toggle "Show goal indicators" — the bottom-right capsule appears or disappears.
8. ⌘S flashes "Saved" briefly at the top of the editor (autosave is real; this is just the reflex).

If all eight pass, milestone 1c is healthy.
```

```bash
git add README.md
git commit -m "docs: add phase 1c smoke test checklist"
```

---

## Self-review checklist

- [x] **Spec coverage:** Every row of the master spec's focus-mode table (lines 218–230) maps to a task — typewriter (T5), sentence focus (T6), paragraph focus (T6), no-chrome ⌘\\ (T8), full-screen focus ⌘⇧F (T9), goal indicators (T10). ⌘S muscle-memory reflex from `feedback_ux_reflexes.md` covered in T11. Centered page width covered in T4. Settings exposure in T7.
- [x] **Placeholder scan:** No "TBD", "TODO", "implement later". Every step has actual code or actual commands.
- [x] **Type consistency:** `typewriterScroll`, `sentenceFocus`, `paragraphFocus`, `goalIndicatorsVisible` consistent across ThemeManager (T2), Settings UI (T7), EditorCoordinator (T5–T6), EditorSurface (T5–T6), ProjectWindow (T5–T6, T10). `FocusFinder.sentenceRange`/`paragraphRange` signatures consistent across T3 (definition) and T6 (use). `EditorMetrics` from milestone 1b reused in T10 unchanged.
- [x] **TDD:** Pure-logic tasks (2, 3) follow TDD with explicit fail/pass test runs. Smoke-build tasks (4, 5, 6, 7, 8, 9, 10, 11) skip dedicated tests where AppKit-seam testing has poor cost/benefit, with manual smoke-test coverage in T12.
- [x] **Decisions:** All non-obvious choices called out at the top of the plan so the implementer can flag them before writing code rather than discovering them mid-task.

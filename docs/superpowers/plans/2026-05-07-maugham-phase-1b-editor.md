# Maugham Phase 1b — Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace milestone-1a's `PlaceholderEditor` with a real Maugham editor: an `EditorSurface` (NSTextView-backed via `NSViewRepresentable`) driven by a `WritingMode` protocol, with `ProseMode` (Markdown) as the first concrete mode, configurable typography, three themes (Light / Dark / Sepia plus Follow System), and a Settings window opened by ⌘,. After 1b, writing in Maugham feels like a real writing app — proper typography, calm syntax highlighting, smart punctuation.

**Architecture:** Pure-logic units first (Token, Theme, TypographySettings, MarkdownTokenizer, SmartTypography, ProseMode), each unit-tested in isolation. Then the NSTextView wrapper layer (EditorCoordinator + EditorSurface), smoke-tested via build + manual run. Then SwiftUI Settings UI (5 tabs). Existing `ProjectWindow` updated to use `EditorSurface`. `MaughamApp` updated to add a Settings scene.

**Tech Stack:** Swift 5.10+, SwiftUI, AppKit (NSTextView, TextKit 2), Foundation, XCTest. macOS 14+ deployment. xcodegen-managed project. No third-party Swift dependencies.

**Anchor:** This plan implements the spec at `docs/superpowers/specs/2026-05-07-maugham-phase-1b-editor-design.md`.

**Execution branch:** `feat/phase-1b-editor` (created in Task 1; merge to main on milestone tag).

---

## File Structure (created or modified during this plan)

```
Maugham/Editor/                       # NEW
  Token.swift                         # NEW
  WritingMode.swift                   # NEW (protocol + EditorMetrics)
  ProseMode.swift                     # NEW
  EditorCoordinator.swift             # NEW (NSTextViewDelegate)
  EditorSurface.swift                 # NEW (NSViewRepresentable)
  Tokenizer/                          # NEW
    MarkdownTokenizer.swift           # NEW
    SmartTypography.swift             # NEW
Maugham/Theme/                        # NEW
  Theme.swift                         # NEW (enum + palettes)
  TypographySettings.swift            # NEW (Codable struct)
  ThemeManager.swift                  # NEW (@Observable; UserDefaults)
Maugham/Views/
  ProjectWindow.swift                 # MODIFIED — uses EditorSurface
  SettingsView.swift                  # NEW (TabView root)
  SettingsTabs/                       # NEW
    EditorSettingsTab.swift           # NEW
    ThemeSettingsTab.swift            # NEW
    TypographySettingsTab.swift       # NEW
    GeneralSettingsTab.swift          # NEW (1d placeholder)
    AboutSettingsTab.swift            # NEW
Maugham/MaughamApp.swift              # MODIFIED — adds Settings scene
MaughamTests/
  TokenTests.swift                    # NEW
  ThemeTests.swift                    # NEW
  TypographySettingsTests.swift       # NEW
  ThemeManagerTests.swift             # NEW
  MarkdownTokenizerTests.swift        # NEW
  SmartTypographyTests.swift          # NEW
  ProseModeTests.swift                # NEW
```

13 new Swift files in main target, 5 new test files, 2 modified files.

---

## Task 1: Create feature branch

**Working directory:** `/Users/denver/src/Maugham`

- [ ] **Step 1: Confirm clean main and create branch**

```bash
git status
git log --oneline -3
git checkout -b feat/phase-1b-editor
```

Expected: working tree clean, latest commit on main is `e4e7b1b` (the 1b spec). Branch creation prints `Switched to a new branch 'feat/phase-1b-editor'`.

No commit for this task — branch creation is preparatory.

---

## Task 2: Token type

**Files:**
- Create: `Maugham/Editor/Token.swift`
- Create: `MaughamTests/TokenTests.swift`

- [ ] **Step 1: Write the failing test**

`MaughamTests/TokenTests.swift`:
```swift
import XCTest
@testable import Maugham

final class TokenTests: XCTestCase {
    func test_kindEquality_distinguishesHeadingLevels() {
        XCTAssertNotEqual(Token.Kind.heading(level: 1), .heading(level: 2))
        XCTAssertEqual(Token.Kind.heading(level: 3), .heading(level: 3))
    }

    func test_kindEquality_distinguishesEmphasisStrength() {
        XCTAssertNotEqual(Token.Kind.emphasis(strong: false),
                          .emphasis(strong: true))
    }

    func test_kindEquality_distinguishesLinkHrefs() {
        XCTAssertNotEqual(Token.Kind.link(href: "a"),
                          .link(href: "b"))
        XCTAssertEqual(Token.Kind.link(href: "a"),
                       .link(href: "a"))
    }

    func test_token_equatableByRangeAndKind() {
        let a = Token(range: NSRange(location: 0, length: 5), kind: .plain)
        let b = Token(range: NSRange(location: 0, length: 5), kind: .plain)
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Regenerate, run test, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/TokenTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error `cannot find type 'Token' in scope`.

- [ ] **Step 3: Implement `Token`**

`Maugham/Editor/Token.swift`:
```swift
import Foundation

/// A classified range of source text, produced by a `WritingMode`'s tokenizer
/// and consumed by the editor coordinator to apply theme attributes.
public struct Token: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case emphasis(strong: Bool)
        case code
        case link(href: String)
        case listMarker
        case blockquote
        case horizontalRule
        case syntaxPunctuation
        case plain
    }

    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}
```

- [ ] **Step 4: Regenerate, run test, expect pass**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/TokenTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: 4 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Token.swift MaughamTests/TokenTests.swift
git commit -m "feat: add Token type for syntax highlighting"
```

---

## Task 3: WritingMode protocol + EditorMetrics

**Files:**
- Create: `Maugham/Editor/WritingMode.swift`

No dedicated test — the protocol has no executable behavior. Concrete conformances (Task 9 ProseMode) are tested directly.

- [ ] **Step 1: Implement WritingMode + EditorMetrics**

`Maugham/Editor/WritingMode.swift`:
```swift
import Foundation
import AppKit

/// Metrics computed by a writing mode for a given manuscript text.
public struct EditorMetrics: Equatable, Sendable {
    public var wordCount: Int
    public var characterCount: Int
    public var readingMinutes: Int

    public init(wordCount: Int, characterCount: Int, readingMinutes: Int) {
        self.wordCount = wordCount
        self.characterCount = characterCount
        self.readingMinutes = readingMinutes
    }
}

/// Pluggable mode that classifies text and applies typography for an
/// `EditorSurface`. ProseMode (Markdown) is the milestone-1b implementation.
public protocol WritingMode: Sendable {
    /// Classify the given text into syntax-highlighting tokens.
    func tokenize(_ text: String) -> [Token]

    /// Apply theme + typography attributes to a text storage based on tokens.
    func applyTypography(
        in storage: NSTextStorage,
        theme: Theme,
        typography: TypographySettings,
        tokens: [Token]
    )

    /// If the user's typed replacement should auto-transform (em dash, etc.),
    /// return the substitution; otherwise nil.
    func smartTypographyTransform(
        currentText: String,
        replacementRange: NSRange,
        replacement: String,
        settings: TypographySettings
    ) -> String?

    /// Compute metrics for the manuscript.
    func metrics(_ text: String) -> EditorMetrics
}
```

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

This will fail because `Theme` and `TypographySettings` don't exist yet. That's expected — they arrive in Tasks 4 and 5. Skip this build verification; the file compiles correctly once those types exist.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Editor/WritingMode.swift
git commit -m "feat: add WritingMode protocol and EditorMetrics"
```

---

## Task 4: Theme enum + palette

**Files:**
- Create: `Maugham/Theme/Theme.swift`
- Create: `MaughamTests/ThemeTests.swift`

- [ ] **Step 1: Write the failing test**

`MaughamTests/ThemeTests.swift`:
```swift
import XCTest
import AppKit
@testable import Maugham

final class ThemeTests: XCTestCase {
    func test_allCases_containsThreeBuiltinsPlusFollowSystem() {
        XCTAssertEqual(Set(Theme.allCases), [.light, .dark, .sepia, .followSystem])
    }

    func test_palette_lightHasWhiteBackground() {
        XCTAssertEqual(Theme.light.palette.background, NSColor(rgbHex: 0xFFFFFF))
    }

    func test_palette_darkHasDarkBackground() {
        XCTAssertEqual(Theme.dark.palette.background, NSColor(rgbHex: 0x1E1E1E))
    }

    func test_palette_sepiaHasPaperBackground() {
        XCTAssertEqual(Theme.sepia.palette.background, NSColor(rgbHex: 0xFBF0D9))
    }

    func test_followSystem_resolvesToLightOrDark() {
        // We can't deterministically test which one, but resolving must not crash
        // and must return one of {.light, .dark}.
        let resolved = Theme.followSystem.resolved(systemAppearanceIsDark: false)
        XCTAssertEqual(resolved, .light)
        let resolvedDark = Theme.followSystem.resolved(systemAppearanceIsDark: true)
        XCTAssertEqual(resolvedDark, .dark)
    }

    func test_codable_roundTripsRawValues() throws {
        for theme in Theme.allCases {
            let data = try JSONEncoder().encode(theme)
            let decoded = try JSONDecoder().decode(Theme.self, from: data)
            XCTAssertEqual(decoded, theme)
        }
    }
}
```

- [ ] **Step 2: Regenerate, run test, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ThemeTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error `cannot find type 'Theme' in scope`.

- [ ] **Step 3: Implement Theme + ThemePalette**

`Maugham/Theme/Theme.swift`:
```swift
import Foundation
import AppKit

/// User-selectable theme. `followSystem` resolves to `.light` or `.dark`
/// based on the running app's effective appearance.
public enum Theme: String, Codable, CaseIterable, Equatable, Sendable {
    case light
    case dark
    case sepia
    case followSystem = "follow_system"

    public func resolved(systemAppearanceIsDark: Bool) -> Theme {
        switch self {
        case .followSystem: return systemAppearanceIsDark ? .dark : .light
        default: return self
        }
    }

    public var palette: ThemePalette {
        switch self {
        case .light:        return .light
        case .dark:         return .dark
        case .sepia:        return .sepia
        case .followSystem:
            // Should not happen — UI should resolve before calling palette.
            // Default to light for safety.
            return .light
        }
    }
}

public struct ThemePalette: Equatable, Sendable {
    public var background: NSColor
    public var bodyText: NSColor
    public var syntaxPunctuation: NSColor
    public var heading: NSColor
    public var code: NSColor
    public var link: NSColor
    public var blockquoteBar: NSColor
    public var caret: NSColor
    public var selection: NSColor

    public static let light = ThemePalette(
        background: NSColor(rgbHex: 0xFFFFFF),
        bodyText: NSColor(rgbHex: 0x1A1A1A),
        syntaxPunctuation: NSColor(rgbHex: 0xA0A0A0),
        heading: NSColor(rgbHex: 0x0A0A0A),
        code: NSColor(rgbHex: 0x5A4A20),
        link: NSColor(rgbHex: 0x0066CC),
        blockquoteBar: NSColor(rgbHex: 0xD0D0D0),
        caret: NSColor(rgbHex: 0x0A0A0A),
        selection: NSColor(rgbHex: 0xB5D5FF)
    )

    public static let dark = ThemePalette(
        background: NSColor(rgbHex: 0x1E1E1E),
        bodyText: NSColor(rgbHex: 0xE0E0E0),
        syntaxPunctuation: NSColor(rgbHex: 0x6E6E6E),
        heading: NSColor(rgbHex: 0xFFFFFF),
        code: NSColor(rgbHex: 0xD5C18A),
        link: NSColor(rgbHex: 0x5AA8FF),
        blockquoteBar: NSColor(rgbHex: 0x404040),
        caret: NSColor(rgbHex: 0xE0E0E0),
        selection: NSColor(rgbHex: 0x264F78)
    )

    public static let sepia = ThemePalette(
        background: NSColor(rgbHex: 0xFBF0D9),
        bodyText: NSColor(rgbHex: 0x3C2E1F),
        syntaxPunctuation: NSColor(rgbHex: 0xA6916D),
        heading: NSColor(rgbHex: 0x2D1F0F),
        code: NSColor(rgbHex: 0x5A4520),
        link: NSColor(rgbHex: 0x704528),
        blockquoteBar: NSColor(rgbHex: 0xD8C2A0),
        caret: NSColor(rgbHex: 0x3C2E1F),
        selection: NSColor(rgbHex: 0xE2C9A8)
    )
}

extension NSColor {
    /// Convenience initializer from a 6-digit hex value (0xRRGGBB).
    public convenience init(rgbHex: UInt32) {
        let r = CGFloat((rgbHex >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgbHex >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgbHex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
```

- [ ] **Step 4: Regenerate, run test, expect pass**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ThemeTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: 6 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Theme/Theme.swift MaughamTests/ThemeTests.swift
git commit -m "feat: add Theme enum with Light/Dark/Sepia/Follow-System palettes"
```

---

## Task 5: TypographySettings struct

**Files:**
- Create: `Maugham/Theme/TypographySettings.swift`
- Create: `MaughamTests/TypographySettingsTests.swift`

- [ ] **Step 1: Write the failing test**

`MaughamTests/TypographySettingsTests.swift`:
```swift
import XCTest
@testable import Maugham

final class TypographySettingsTests: XCTestCase {
    func test_defaults_matchSpec() {
        let s = TypographySettings.defaults
        XCTAssertEqual(s.fontFamily, "Iowan Old Style")
        XCTAssertEqual(s.fontSize, 17)
        XCTAssertEqual(s.lineHeightMultiplier, 1.7, accuracy: 0.001)
        XCTAssertEqual(s.pageWidthCharacters, 70)
        XCTAssertEqual(s.paragraphSpacingMultiplier, 0.6, accuracy: 0.001)
        XCTAssertTrue(s.smartQuotes)
        XCTAssertTrue(s.emDashAutoReplace)
        XCTAssertTrue(s.ellipsisAutoReplace)
    }

    func test_codable_roundTrips() throws {
        let s = TypographySettings(
            fontFamily: "New York",
            fontSize: 19,
            lineHeightMultiplier: 1.6,
            pageWidthCharacters: 80,
            paragraphSpacingMultiplier: 0.8,
            smartQuotes: false,
            emDashAutoReplace: false,
            ellipsisAutoReplace: false
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(TypographySettings.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    func test_curatedFonts_includesExpectedFamilies() {
        let names = TypographySettings.curatedFonts.map(\.fontName)
        XCTAssertTrue(names.contains("Iowan Old Style"))
        XCTAssertTrue(names.contains("New York"))
        XCTAssertTrue(names.contains("Charter"))
    }
}
```

- [ ] **Step 2: Regenerate, run test, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/TypographySettingsTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error `cannot find type 'TypographySettings' in scope`.

- [ ] **Step 3: Implement TypographySettings**

`Maugham/Theme/TypographySettings.swift`:
```swift
import Foundation

/// User-configurable typography settings persisted via @AppStorage in 1b.
/// Per-project overrides arrive in milestone 1c.
public struct TypographySettings: Codable, Equatable, Sendable {
    public var fontFamily: String
    public var fontSize: Int
    public var lineHeightMultiplier: Double
    public var pageWidthCharacters: Int
    public var paragraphSpacingMultiplier: Double
    public var smartQuotes: Bool
    public var emDashAutoReplace: Bool
    public var ellipsisAutoReplace: Bool

    public init(
        fontFamily: String,
        fontSize: Int,
        lineHeightMultiplier: Double,
        pageWidthCharacters: Int,
        paragraphSpacingMultiplier: Double,
        smartQuotes: Bool,
        emDashAutoReplace: Bool,
        ellipsisAutoReplace: Bool
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeightMultiplier = lineHeightMultiplier
        self.pageWidthCharacters = pageWidthCharacters
        self.paragraphSpacingMultiplier = paragraphSpacingMultiplier
        self.smartQuotes = smartQuotes
        self.emDashAutoReplace = emDashAutoReplace
        self.ellipsisAutoReplace = ellipsisAutoReplace
    }

    public static let defaults = TypographySettings(
        fontFamily: "Iowan Old Style",
        fontSize: 17,
        lineHeightMultiplier: 1.7,
        pageWidthCharacters: 70,
        paragraphSpacingMultiplier: 0.6,
        smartQuotes: true,
        emDashAutoReplace: true,
        ellipsisAutoReplace: true
    )

    public struct CuratedFont: Equatable, Sendable {
        public let displayName: String
        public let fontName: String
    }

    public static let curatedFonts: [CuratedFont] = [
        CuratedFont(displayName: "Iowan Old Style", fontName: "Iowan Old Style"),
        CuratedFont(displayName: "New York", fontName: "New York"),
        CuratedFont(displayName: "Charter", fontName: "Charter"),
    ]
}
```

- [ ] **Step 4: Regenerate, run test, expect pass**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/TypographySettingsTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: 3 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Theme/TypographySettings.swift MaughamTests/TypographySettingsTests.swift
git commit -m "feat: add TypographySettings with defaults and curated fonts"
```

---

## Task 6: ThemeManager (UserDefaults-backed)

**Files:**
- Create: `Maugham/Theme/ThemeManager.swift`
- Create: `MaughamTests/ThemeManagerTests.swift`

- [ ] **Step 1: Write the failing test**

`MaughamTests/ThemeManagerTests.swift`:
```swift
import XCTest
@testable import Maugham

@MainActor
final class ThemeManagerTests: XCTestCase {
    var defaults: UserDefaults!
    var manager: ThemeManager!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "ThemeManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        manager = ThemeManager(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults = nil
        manager = nil
        try await super.tearDown()
    }

    func test_freshManager_returnsDefaults() {
        XCTAssertEqual(manager.theme, .followSystem)
        XCTAssertEqual(manager.typography, .defaults)
    }

    func test_themeMutation_persistsAndIsObservable() {
        manager.theme = .sepia
        let other = ThemeManager(defaults: defaults)
        XCTAssertEqual(other.theme, .sepia)
    }

    func test_typographyMutation_persists() {
        var t = TypographySettings.defaults
        t.fontSize = 22
        manager.typography = t
        let other = ThemeManager(defaults: defaults)
        XCTAssertEqual(other.typography.fontSize, 22)
    }

    func test_corruptStoredData_fallsBackToDefaults() {
        defaults.set("not json", forKey: "maugham.typography")
        let m = ThemeManager(defaults: defaults)
        XCTAssertEqual(m.typography, .defaults)
    }
}
```

- [ ] **Step 2: Regenerate, run test, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ThemeManagerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error `cannot find type 'ThemeManager' in scope`.

- [ ] **Step 3: Implement ThemeManager**

`Maugham/Theme/ThemeManager.swift`:
```swift
import Foundation
import SwiftUI

/// Reads / writes user-level theme + typography preferences via UserDefaults.
/// Observable so SwiftUI views update automatically.
@MainActor
@Observable
public final class ThemeManager {
    private static let themeKey = "maugham.theme"
    private static let typographyKey = "maugham.typography"

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
    }
}
```

- [ ] **Step 4: Regenerate, run test, expect pass**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ThemeManagerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: 4 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Theme/ThemeManager.swift MaughamTests/ThemeManagerTests.swift
git commit -m "feat: add ThemeManager with UserDefaults persistence"
```

---

## Task 7: MarkdownTokenizer

**Files:**
- Create: `Maugham/Editor/Tokenizer/MarkdownTokenizer.swift`
- Create: `MaughamTests/MarkdownTokenizerTests.swift`

- [ ] **Step 1: Write the failing test**

`MaughamTests/MarkdownTokenizerTests.swift`:
```swift
import XCTest
@testable import Maugham

final class MarkdownTokenizerTests: XCTestCase {
    private let tokenizer = MarkdownTokenizer()

    func test_emptyText_producesNoTokens() {
        XCTAssertEqual(tokenizer.tokenize(""), [])
    }

    func test_plainText_producesPlainToken() {
        let tokens = tokenizer.tokenize("just words")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .plain)
        XCTAssertEqual(tokens[0].range, NSRange(location: 0, length: 10))
    }

    func test_h1_producesHeadingAndPunctuation() {
        let tokens = tokenizer.tokenize("# Hello")
        // expect: syntaxPunctuation "# " + heading(1) "Hello"
        let kinds = tokens.map(\.kind)
        XCTAssertTrue(kinds.contains(.syntaxPunctuation))
        XCTAssertTrue(kinds.contains(.heading(level: 1)))
    }

    func test_h3_producesHeading3() {
        let tokens = tokenizer.tokenize("### Hello")
        XCTAssertTrue(tokens.contains { $0.kind == .heading(level: 3) })
    }

    func test_bold_producesEmphasisStrongAndPunctuation() {
        let tokens = tokenizer.tokenize("**bold**")
        let kinds = tokens.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .syntaxPunctuation }.count, 2)
        XCTAssertTrue(kinds.contains(.emphasis(strong: true)))
    }

    func test_italic_producesEmphasisAndPunctuation() {
        let tokens = tokenizer.tokenize("*italic*")
        let kinds = tokens.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .syntaxPunctuation }.count, 2)
        XCTAssertTrue(kinds.contains(.emphasis(strong: false)))
    }

    func test_inlineCode_producesCodeAndPunctuation() {
        let tokens = tokenizer.tokenize("`code`")
        let kinds = tokens.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .syntaxPunctuation }.count, 2)
        XCTAssertTrue(kinds.contains(.code))
    }

    func test_link_producesLinkAndPunctuation() {
        let tokens = tokenizer.tokenize("[hi](https://x.com)")
        let kinds = tokens.map(\.kind)
        XCTAssertTrue(kinds.contains(.link(href: "https://x.com")))
        XCTAssertTrue(kinds.contains(.syntaxPunctuation))
    }

    func test_listMarker_producesListMarker() {
        let tokens = tokenizer.tokenize("- item")
        XCTAssertTrue(tokens.contains { $0.kind == .listMarker })
    }

    func test_blockquote_producesBlockquote() {
        let tokens = tokenizer.tokenize("> quoted")
        XCTAssertTrue(tokens.contains { $0.kind == .blockquote })
    }

    func test_horizontalRule_producesHR() {
        let tokens = tokenizer.tokenize("---")
        XCTAssertTrue(tokens.contains { $0.kind == .horizontalRule })
    }

    func test_multilineDocument_tokenizesEachLine() {
        let md = """
        # Title

        Some **bold** text and a [link](https://x.com).
        """
        let tokens = tokenizer.tokenize(md)
        let kinds = Set(tokens.map { String(describing: $0.kind) })
        // Loose check: we expect at least heading, emphasis, link, plain, syntaxPunctuation
        XCTAssertTrue(kinds.contains { $0.contains("heading") })
        XCTAssertTrue(kinds.contains { $0.contains("emphasis") })
        XCTAssertTrue(kinds.contains { $0.contains("link") })
    }

    func test_tokensAreNonOverlapping_andSortedByLocation() {
        let md = "# A\n\n**b** and *c*"
        let tokens = tokenizer.tokenize(md)
        let sorted = tokens.sorted { $0.range.location < $1.range.location }
        XCTAssertEqual(tokens, sorted, "tokens must be in source order")
        for i in 1..<tokens.count {
            let prev = tokens[i - 1].range
            let cur = tokens[i].range
            XCTAssertGreaterThanOrEqual(cur.location, prev.location + prev.length,
                                        "tokens must not overlap")
        }
    }
}
```

- [ ] **Step 2: Regenerate, run test, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/MarkdownTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error `cannot find type 'MarkdownTokenizer' in scope`.

- [ ] **Step 3: Implement MarkdownTokenizer**

`Maugham/Editor/Tokenizer/MarkdownTokenizer.swift`:
```swift
import Foundation

/// Regex-based Markdown tokenizer. Classifies ranges of text into Token kinds
/// for syntax highlighting. Does not handle tables, fenced code blocks, or
/// nested emphasis — defer to later milestones if needed.
public struct MarkdownTokenizer: Sendable {

    public init() {}

    public func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        var tokens: [Token] = []

        // Headings: ^(#{1,6})\s+
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^(#{1,6})\s+([^\n]*)"#,
            into: &tokens) { match in
                let hashes = match.range(at: 1)
                let content = match.range(at: 2)
                let level = nsText.substring(with: hashes).count
                return [
                    Token(range: NSRange(location: hashes.location,
                                          length: content.location - hashes.location),
                          kind: .syntaxPunctuation),
                    Token(range: content, kind: .heading(level: level)),
                ]
            }

        // Bold: \*\*([^*]+)\*\*
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"\*\*([^*\n]+)\*\*"#,
            into: &tokens) { match in
                let outer = match.range(at: 0)
                let inner = match.range(at: 1)
                let openPunct = NSRange(location: outer.location, length: 2)
                let closePunct = NSRange(location: inner.location + inner.length, length: 2)
                return [
                    Token(range: openPunct, kind: .syntaxPunctuation),
                    Token(range: inner, kind: .emphasis(strong: true)),
                    Token(range: closePunct, kind: .syntaxPunctuation),
                ]
            }

        // Italic: (?<!\*)\*([^*\n]+)\*(?!\*)
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#,
            into: &tokens) { match in
                let outer = match.range(at: 0)
                let inner = match.range(at: 1)
                let openPunct = NSRange(location: outer.location, length: 1)
                let closePunct = NSRange(location: inner.location + inner.length, length: 1)
                return [
                    Token(range: openPunct, kind: .syntaxPunctuation),
                    Token(range: inner, kind: .emphasis(strong: false)),
                    Token(range: closePunct, kind: .syntaxPunctuation),
                ]
            }

        // Inline code: `([^`\n]+)`
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"`([^`\n]+)`"#,
            into: &tokens) { match in
                let outer = match.range(at: 0)
                let inner = match.range(at: 1)
                let openPunct = NSRange(location: outer.location, length: 1)
                let closePunct = NSRange(location: inner.location + inner.length, length: 1)
                return [
                    Token(range: openPunct, kind: .syntaxPunctuation),
                    Token(range: inner, kind: .code),
                    Token(range: closePunct, kind: .syntaxPunctuation),
                ]
            }

        // Link: \[([^\]\n]+)\]\(([^\)\n]+)\)
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#,
            into: &tokens) { match in
                let outer = match.range(at: 0)
                let labelInner = match.range(at: 1)
                let href = match.range(at: 2)
                let hrefString = nsText.substring(with: href)

                let labelOpen = NSRange(location: outer.location, length: 1)        // [
                let labelClose = NSRange(location: labelInner.location + labelInner.length, length: 1)  // ]
                let parensOpen = NSRange(location: labelClose.location + 1, length: 1)  // (
                let parensCloseLoc = href.location + href.length
                let parensClose = NSRange(location: parensCloseLoc, length: 1)
                return [
                    Token(range: labelOpen, kind: .syntaxPunctuation),
                    Token(range: labelInner, kind: .link(href: hrefString)),
                    Token(range: labelClose, kind: .syntaxPunctuation),
                    Token(range: parensOpen, kind: .syntaxPunctuation),
                    Token(range: href, kind: .syntaxPunctuation),
                    Token(range: parensClose, kind: .syntaxPunctuation),
                ]
            }

        // List marker: ^(\s*)([-*+]|\d+\.)\s
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^(\s*)([-*+]|\d+\.)\s"#,
            into: &tokens) { match in
                let marker = match.range(at: 2)
                return [Token(range: marker, kind: .listMarker)]
            }

        // Blockquote: ^>\s
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^(>)\s"#,
            into: &tokens) { match in
                return [Token(range: match.range(at: 1), kind: .blockquote)]
            }

        // Horizontal rule: ^---+\s*$
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^(---+)\s*$"#,
            into: &tokens) { match in
                return [Token(range: match.range(at: 1), kind: .horizontalRule)]
            }

        // Sort by location and fill gaps with .plain tokens
        tokens.sort { $0.range.location < $1.range.location }
        let merged = fillGapsWithPlain(tokens, fullRange: fullRange)
        return merged
    }

    // MARK: - Helpers

    private func addMatches(
        in nsText: NSString,
        fullRange: NSRange,
        pattern: String,
        into tokens: inout [Token],
        _ build: (NSTextCheckingResult) -> [Token]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        regex.enumerateMatches(in: nsText as String, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            // Skip if any of the new tokens overlap with already-classified ranges
            let candidates = build(match)
            for c in candidates {
                if !tokens.contains(where: { $0.range.intersection(c.range) != nil }) {
                    tokens.append(c)
                }
            }
        }
    }

    private func fillGapsWithPlain(_ classified: [Token], fullRange: NSRange) -> [Token] {
        var result: [Token] = []
        var cursor = 0
        for token in classified {
            if token.range.location > cursor {
                let gap = NSRange(location: cursor, length: token.range.location - cursor)
                result.append(Token(range: gap, kind: .plain))
            }
            result.append(token)
            cursor = token.range.location + token.range.length
        }
        if cursor < fullRange.length {
            let gap = NSRange(location: cursor, length: fullRange.length - cursor)
            result.append(Token(range: gap, kind: .plain))
        }
        return result
    }
}
```

- [ ] **Step 4: Regenerate, run test, expect pass**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/MarkdownTokenizerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: 13 tests passing.

If a test fails because of regex edge cases (which are common with Markdown), the implementer should iterate on the failing pattern, NOT on the test, and report which tests took multiple iterations to pass.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Tokenizer/MarkdownTokenizer.swift MaughamTests/MarkdownTokenizerTests.swift
git commit -m "feat: add regex-based Markdown tokenizer"
```

---

## Task 8: SmartTypography transforms

**Files:**
- Create: `Maugham/Editor/Tokenizer/SmartTypography.swift`
- Create: `MaughamTests/SmartTypographyTests.swift`

- [ ] **Step 1: Write the failing test**

`MaughamTests/SmartTypographyTests.swift`:
```swift
import XCTest
@testable import Maugham

final class SmartTypographyTests: XCTestCase {

    func test_emDash_doubleHyphenBecomesEmDash() {
        let result = SmartTypography.transform(
            currentText: "He said-",
            replacementRange: NSRange(location: 8, length: 0),
            replacement: "-",
            settings: .defaults
        )
        XCTAssertEqual(result, "—")
    }

    func test_emDash_singleHyphenIsNotTransformed() {
        let result = SmartTypography.transform(
            currentText: "He said",
            replacementRange: NSRange(location: 7, length: 0),
            replacement: "-",
            settings: .defaults
        )
        XCTAssertNil(result)
    }

    func test_emDash_disabledByFlag() {
        var settings = TypographySettings.defaults
        settings.emDashAutoReplace = false
        let result = SmartTypography.transform(
            currentText: "He said-",
            replacementRange: NSRange(location: 8, length: 0),
            replacement: "-",
            settings: settings
        )
        XCTAssertNil(result)
    }

    func test_ellipsis_threeDotsBecomesEllipsis() {
        let result = SmartTypography.transform(
            currentText: "Wait..",
            replacementRange: NSRange(location: 6, length: 0),
            replacement: ".",
            settings: .defaults
        )
        XCTAssertEqual(result, "…")
    }

    func test_ellipsis_dotFollowedByDigitIsNotTransformed() {
        // Don't ruin "version 1.0.." typing
        let result = SmartTypography.transform(
            currentText: "v1.0.",
            replacementRange: NSRange(location: 5, length: 0),
            replacement: "0",
            settings: .defaults
        )
        XCTAssertNil(result)
    }

    func test_smartQuote_openingDoubleQuote() {
        let result = SmartTypography.transform(
            currentText: "He said ",
            replacementRange: NSRange(location: 8, length: 0),
            replacement: "\"",
            settings: .defaults
        )
        XCTAssertEqual(result, "\u{201C}") // “
    }

    func test_smartQuote_closingDoubleQuote() {
        let result = SmartTypography.transform(
            currentText: "He said \u{201C}hi",
            replacementRange: NSRange(location: 11, length: 0),
            replacement: "\"",
            settings: .defaults
        )
        XCTAssertEqual(result, "\u{201D}") // ”
    }

    func test_smartQuote_disabledByFlag() {
        var settings = TypographySettings.defaults
        settings.smartQuotes = false
        let result = SmartTypography.transform(
            currentText: "",
            replacementRange: NSRange(location: 0, length: 0),
            replacement: "\"",
            settings: settings
        )
        XCTAssertNil(result)
    }
}
```

- [ ] **Step 2: Regenerate, run test, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/SmartTypographyTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error `cannot find type 'SmartTypography' in scope`.

- [ ] **Step 3: Implement SmartTypography**

`Maugham/Editor/Tokenizer/SmartTypography.swift`:
```swift
import Foundation

/// Computes optional auto-replacements for typographic input:
/// `--` -> em dash, `...` -> ellipsis, `"` / `'` -> curly quotes.
public enum SmartTypography {

    /// Returns a substitution string if the user's replacement should be
    /// auto-transformed; otherwise nil. Caller (the editor coordinator)
    /// applies the substitution by re-issuing the text replacement.
    public static func transform(
        currentText: String,
        replacementRange: NSRange,
        replacement: String,
        settings: TypographySettings
    ) -> String? {
        // Em dash: replacement "-" preceded by another "-"
        if settings.emDashAutoReplace, replacement == "-",
           replacementRange.location > 0 {
            let nsText = currentText as NSString
            let prevRange = NSRange(location: replacementRange.location - 1, length: 1)
            if nsText.substring(with: prevRange) == "-" {
                // Caller is responsible for replacing the previous "-" too;
                // we return the em dash as the substitute for the just-typed "-",
                // and a separate convention is that the coordinator deletes
                // the preceding "-" before inserting our value.
                return "—"
            }
        }

        // Ellipsis: replacement "." preceded by ".."
        if settings.ellipsisAutoReplace, replacement == ".",
           replacementRange.location >= 2 {
            let nsText = currentText as NSString
            let prevRange = NSRange(location: replacementRange.location - 2, length: 2)
            if nsText.substring(with: prevRange) == ".." {
                // Don't transform "1.0.0" — only when not preceded by a digit
                if replacementRange.location >= 3 {
                    let beforeDots = NSRange(
                        location: replacementRange.location - 3, length: 1)
                    let prefixChar = nsText.substring(with: beforeDots)
                    if let scalar = prefixChar.unicodeScalars.first,
                       CharacterSet.decimalDigits.contains(scalar) {
                        return nil
                    }
                }
                return "…"
            }
        }

        // Smart double quote
        if settings.smartQuotes, replacement == "\"" {
            return isOpeningContext(text: currentText, at: replacementRange.location)
                ? "\u{201C}" : "\u{201D}"
        }

        // Smart single quote
        if settings.smartQuotes, replacement == "'" {
            return isOpeningContext(text: currentText, at: replacementRange.location)
                ? "\u{2018}" : "\u{2019}"
        }

        return nil
    }

    /// True when the cursor is at the start of input or after whitespace —
    /// we should produce an opening curly quote. Otherwise, closing.
    private static func isOpeningContext(text: String, at location: Int) -> Bool {
        guard location > 0 else { return true }
        let nsText = text as NSString
        guard location <= nsText.length else { return true }
        let prev = nsText.substring(
            with: NSRange(location: location - 1, length: 1))
        if prev.isEmpty { return true }
        if let scalar = prev.unicodeScalars.first,
           CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return true
        }
        return false
    }
}
```

- [ ] **Step 4: Regenerate, run test, expect pass**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/SmartTypographyTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: 8 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/Tokenizer/SmartTypography.swift MaughamTests/SmartTypographyTests.swift
git commit -m "feat: add smart typography transforms (em dash, ellipsis, quotes)"
```

---

## Task 9: ProseMode

**Files:**
- Create: `Maugham/Editor/ProseMode.swift`
- Create: `MaughamTests/ProseModeTests.swift`

- [ ] **Step 1: Write the failing test**

`MaughamTests/ProseModeTests.swift`:
```swift
import XCTest
import AppKit
@testable import Maugham

final class ProseModeTests: XCTestCase {
    private let mode = ProseMode()

    func test_tokenize_delegatesToMarkdownTokenizer() {
        let tokens = mode.tokenize("# Title")
        XCTAssertTrue(tokens.contains { $0.kind == .heading(level: 1) })
    }

    func test_metrics_countsWordsAndCharacters() {
        let metrics = mode.metrics("hello world this is text")
        XCTAssertEqual(metrics.wordCount, 5)
        XCTAssertEqual(metrics.characterCount, 24)
    }

    func test_metrics_emptyString() {
        let metrics = mode.metrics("")
        XCTAssertEqual(metrics.wordCount, 0)
        XCTAssertEqual(metrics.characterCount, 0)
        XCTAssertEqual(metrics.readingMinutes, 0)
    }

    func test_metrics_readingMinutes_at200WPM() {
        let words = Array(repeating: "word", count: 600).joined(separator: " ")
        let metrics = mode.metrics(words)
        // 600 / 200 wpm = 3 minutes
        XCTAssertEqual(metrics.readingMinutes, 3)
    }

    func test_smartTypographyTransform_delegatesToSmartTypography() {
        let result = mode.smartTypographyTransform(
            currentText: "ah-",
            replacementRange: NSRange(location: 3, length: 0),
            replacement: "-",
            settings: .defaults)
        XCTAssertEqual(result, "—")
    }

    func test_applyTypography_setsBackgroundAndAttributes() {
        let storage = NSTextStorage(string: "hello")
        let tokens = [Token(range: NSRange(location: 0, length: 5), kind: .plain)]
        mode.applyTypography(in: storage, theme: .light,
                             typography: .defaults, tokens: tokens)

        // After applyTypography, every char should have a font attribute.
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(attrs[.font])
        XCTAssertNotNil(attrs[.foregroundColor])
    }
}
```

- [ ] **Step 2: Regenerate, run test, expect failure**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProseModeTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: build error `cannot find type 'ProseMode' in scope`.

- [ ] **Step 3: Implement ProseMode**

`Maugham/Editor/ProseMode.swift`:
```swift
import Foundation
import AppKit

/// Markdown-flavored prose mode. Used by EditorSurface for `.md` documents.
public struct ProseMode: WritingMode {
    private let tokenizer: MarkdownTokenizer
    private static let wordsPerMinute = 200

    public init(tokenizer: MarkdownTokenizer = MarkdownTokenizer()) {
        self.tokenizer = tokenizer
    }

    public func tokenize(_ text: String) -> [Token] {
        tokenizer.tokenize(text)
    }

    public func smartTypographyTransform(
        currentText: String,
        replacementRange: NSRange,
        replacement: String,
        settings: TypographySettings
    ) -> String? {
        SmartTypography.transform(
            currentText: currentText,
            replacementRange: replacementRange,
            replacement: replacement,
            settings: settings)
    }

    public func metrics(_ text: String) -> EditorMetrics {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.isEmpty
            ? 0
            : trimmed.split(whereSeparator: \.isWhitespace).count
        let chars = (text as NSString).length
        let mins = words / Self.wordsPerMinute
        return EditorMetrics(
            wordCount: words,
            characterCount: chars,
            readingMinutes: mins
        )
    }

    public func applyTypography(
        in storage: NSTextStorage,
        theme: Theme,
        typography: TypographySettings,
        tokens: [Token]
    ) {
        let resolved = theme.resolved(systemAppearanceIsDark: false)
        let palette = resolved.palette
        let baseFont = NSFont(
            name: typography.fontFamily,
            size: CGFloat(typography.fontSize)
        ) ?? NSFont.systemFont(ofSize: CGFloat(typography.fontSize))

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = CGFloat(typography.lineHeightMultiplier)
        paragraph.paragraphSpacing =
            baseFont.pointSize * CGFloat(typography.paragraphSpacingMultiplier)

        storage.beginEditing()
        let fullRange = NSRange(location: 0, length: storage.length)
        // Reset to body defaults
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: palette.bodyText,
            .paragraphStyle: paragraph,
        ], range: fullRange)

        for token in tokens {
            guard NSMaxRange(token.range) <= storage.length else { continue }
            let attrs = attributes(
                for: token.kind, palette: palette, baseFont: baseFont)
            storage.addAttributes(attrs, range: token.range)
        }
        storage.endEditing()
    }

    private func attributes(
        for kind: Token.Kind,
        palette: ThemePalette,
        baseFont: NSFont
    ) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .heading(let level):
            let scale: CGFloat = level == 1 ? 1.6 : level == 2 ? 1.4 : level == 3 ? 1.25 : 1.1
            let font = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold),
                size: baseFont.pointSize * scale
            ) ?? baseFont
            return [.font: font, .foregroundColor: palette.heading]

        case .emphasis(let strong):
            let traits: NSFontDescriptor.SymbolicTraits = strong ? .bold : .italic
            let font = NSFont(
                descriptor: baseFont.fontDescriptor.withSymbolicTraits(traits),
                size: baseFont.pointSize
            ) ?? baseFont
            return [.font: font]

        case .code:
            let mono = NSFont.monospacedSystemFont(
                ofSize: baseFont.pointSize - 1, weight: .regular)
            return [.font: mono, .foregroundColor: palette.code]

        case .link:
            return [.foregroundColor: palette.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue]

        case .listMarker, .blockquote, .horizontalRule:
            return [.foregroundColor: palette.syntaxPunctuation]

        case .syntaxPunctuation:
            return [.foregroundColor: palette.syntaxPunctuation]

        case .plain:
            return [:]
        }
    }
}
```

- [ ] **Step 4: Regenerate, run test, expect pass**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/ProseModeTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: 6 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Editor/ProseMode.swift MaughamTests/ProseModeTests.swift
git commit -m "feat: add ProseMode composing tokenizer + transforms + metrics"
```

---

## Task 10: EditorCoordinator (NSTextViewDelegate)

**Files:**
- Create: `Maugham/Editor/EditorCoordinator.swift`

The coordinator is testable in isolation only with significant scaffolding around NSTextView. For 1b we smoke-test it via the `EditorSurface` in Task 11 and the manual smoke test. No dedicated test file.

- [ ] **Step 1: Implement EditorCoordinator**

`Maugham/Editor/EditorCoordinator.swift`:
```swift
import Foundation
import AppKit
import SwiftUI

/// NSTextViewDelegate that mediates between SwiftUI's @Binding and NSTextView.
/// Handles the isApplyingExternalUpdate guard so that external state changes
/// don't clobber the user's editing context.
@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate {
    private var binding: Binding<String>
    private let mode: any WritingMode
    private(set) var theme: Theme
    private(set) var typography: TypographySettings

    private var isApplyingExternalUpdate = false
    weak var textView: NSTextView?

    init(text: Binding<String>,
         mode: any WritingMode,
         theme: Theme,
         typography: TypographySettings) {
        self.binding = text
        self.mode = mode
        self.theme = theme
        self.typography = typography
    }

    /// Set the text view from outside (called by EditorSurface.makeNSView).
    func attach(to textView: NSTextView) {
        self.textView = textView
        applyAppearance(theme: theme, typography: typography)
        retokenizeAndStyle()
    }

    /// External (binding-side) update — replace text without disturbing user.
    func applyExternalText(_ text: String) {
        guard let textView, textView.string != text else { return }
        isApplyingExternalUpdate = true
        defer { isApplyingExternalUpdate = false }

        // Preserve cursor where possible
        let oldSelection = textView.selectedRange()
        textView.string = text
        let clamped = NSRange(
            location: min(oldSelection.location, text.utf16.count),
            length: 0
        )
        textView.setSelectedRange(clamped)
        retokenizeAndStyle()
    }

    /// Theme/typography changed — re-style without re-text.
    func applyAppearance(theme: Theme, typography: TypographySettings) {
        self.theme = theme
        self.typography = typography
        guard let textView else { return }
        textView.backgroundColor = theme.resolved(
            systemAppearanceIsDark: NSApp.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]) == .darkAqua
        ).palette.background
        textView.insertionPointColor = theme.resolved(
            systemAppearanceIsDark: NSApp.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]) == .darkAqua
        ).palette.caret
        retokenizeAndStyle()
    }

    private func retokenizeAndStyle() {
        guard let textView, let storage = textView.textStorage else { return }
        let tokens = mode.tokenize(textView.string)
        mode.applyTypography(
            in: storage,
            theme: theme,
            typography: typography,
            tokens: tokens)
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView,
                  shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        guard let replacementString,
              !isApplyingExternalUpdate else { return true }

        // Smart typography handling
        if let substitute = mode.smartTypographyTransform(
            currentText: textView.string,
            replacementRange: affectedCharRange,
            replacement: replacementString,
            settings: typography
        ) {
            // Em dash: special-case — also delete the preceding "-"
            var range = affectedCharRange
            if substitute == "—" && range.location > 0 {
                range = NSRange(location: range.location - 1,
                                length: range.length + 1)
            }
            textView.insertText(substitute, replacementRange: range)
            return false
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              !isApplyingExternalUpdate else { return }
        // Update binding then restyle
        binding.wrappedValue = textView.string
        retokenizeAndStyle()
    }
}
```

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. (No EditorSurface yet, so the coordinator isn't used by anything — it just compiles.)

- [ ] **Step 3: Commit**

```bash
git add Maugham/Editor/EditorCoordinator.swift
git commit -m "feat: add EditorCoordinator (NSTextViewDelegate with binding mediation)"
```

---

## Task 11: EditorSurface (NSViewRepresentable)

**Files:**
- Create: `Maugham/Editor/EditorSurface.swift`

Smoke-build only.

- [ ] **Step 1: Implement EditorSurface**

`Maugham/Editor/EditorSurface.swift`:
```swift
import SwiftUI
import AppKit

/// SwiftUI host for an NSTextView-backed editor surface, driven by a
/// WritingMode (ProseMode in 1b).
struct EditorSurface: NSViewRepresentable {
    @Binding var text: String
    let theme: Theme
    let typography: TypographySettings
    let mode: any WritingMode

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(
            text: $text, mode: mode,
            theme: theme, typography: typography)
    }

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
        textView.textContainerInset = NSSize(width: 24, height: 24)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        context.coordinator.attach(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.applyExternalText(text)
        }
        if context.coordinator.theme != theme
            || context.coordinator.typography != typography {
            context.coordinator.applyAppearance(
                theme: theme, typography: typography)
        }
    }
}

/// NSTextView subclass that lets us tweak first-responder-only behaviors
/// without subclassing the more invasive parts.
private final class MaughamTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
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
git add Maugham/Editor/EditorSurface.swift
git commit -m "feat: add EditorSurface NSViewRepresentable for NSTextView editing"
```

---

## Task 12: Update ProjectWindow to use EditorSurface

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Replace ProjectWindow with version using EditorSurface**

`Maugham/Views/ProjectWindow.swift`:
```swift
import SwiftUI

struct ProjectWindow: View {
    @State private var store: ProjectStore?
    @State private var loadError: String?
    @State private var themeManager = ThemeManager()

    let url: URL

    var body: some View {
        Group {
            if let store {
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
                    mode: ProseMode()
                )
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
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        do {
            store = try await ProjectStore.load(from: url)
            loadError = nil
        } catch ProjectStoreError.manifestNotFound {
            loadError = "No project.maugham.json was found in this folder."
        } catch ProjectStoreError.manifestUnreadable(let msg) {
            loadError = "Manifest is corrupt or unreadable: \(msg)"
        } catch ProjectStoreError.manuscriptUnreadable(let msg) {
            loadError = "Manuscript file couldn't be read: \(msg)"
        } catch {
            loadError = error.localizedDescription
        }
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
git add Maugham/Views/ProjectWindow.swift
git commit -m "feat: ProjectWindow uses EditorSurface and ThemeManager"
```

---

## Task 13: SettingsView root + EditorSettingsTab

**Files:**
- Create: `Maugham/Views/SettingsView.swift`
- Create: `Maugham/Views/SettingsTabs/EditorSettingsTab.swift`

- [ ] **Step 1: Implement SettingsView root**

`Maugham/Views/SettingsView.swift`:
```swift
import SwiftUI

struct SettingsView: View {
    @State private var themeManager = ThemeManager()

    var body: some View {
        TabView {
            EditorSettingsTab(themeManager: themeManager)
                .tabItem { Label("Editor", systemImage: "textformat") }
            ThemeSettingsTab(themeManager: themeManager)
                .tabItem { Label("Theme", systemImage: "paintbrush") }
            TypographySettingsTab(themeManager: themeManager)
                .tabItem { Label("Typography", systemImage: "quote.bubble") }
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 540, minHeight: 360)
        .padding(20)
    }
}
```

- [ ] **Step 2: Implement EditorSettingsTab**

`Maugham/Views/SettingsTabs/EditorSettingsTab.swift`:
```swift
import SwiftUI

struct EditorSettingsTab: View {
    @Bindable var themeManager: ThemeManager

    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 3: Smoke-build (will fail until other tabs exist)**

The build will fail because `ThemeSettingsTab`, `TypographySettingsTab`, `GeneralSettingsTab`, `AboutSettingsTab` don't exist yet. That's expected — they're created in Tasks 14–16. Skip the build verification here.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/SettingsView.swift Maugham/Views/SettingsTabs/EditorSettingsTab.swift
git commit -m "feat: add SettingsView root and Editor tab"
```

---

## Task 14: ThemeSettingsTab

**Files:**
- Create: `Maugham/Views/SettingsTabs/ThemeSettingsTab.swift`

- [ ] **Step 1: Implement ThemeSettingsTab**

`Maugham/Views/SettingsTabs/ThemeSettingsTab.swift`:
```swift
import SwiftUI

struct ThemeSettingsTab: View {
    @Bindable var themeManager: ThemeManager

    var body: some View {
        Form {
            Picker("Theme", selection: $themeManager.theme) {
                Text("Follow System").tag(Theme.followSystem)
                Text("Light").tag(Theme.light)
                Text("Dark").tag(Theme.dark)
                Text("Sepia").tag(Theme.sepia)
            }
            .pickerStyle(.radioGroup)

            Text("Light and Dark match the system appearance you expect; "
                 + "Sepia is a paper-like warm neutral. "
                 + "Follow System mirrors macOS's current Light/Dark mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 2: Smoke-build (will still fail)**

Skip until Task 16.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/SettingsTabs/ThemeSettingsTab.swift
git commit -m "feat: add Theme settings tab"
```

---

## Task 15: TypographySettingsTab

**Files:**
- Create: `Maugham/Views/SettingsTabs/TypographySettingsTab.swift`

- [ ] **Step 1: Implement TypographySettingsTab**

`Maugham/Views/SettingsTabs/TypographySettingsTab.swift`:
```swift
import SwiftUI

struct TypographySettingsTab: View {
    @Bindable var themeManager: ThemeManager

    var body: some View {
        Form {
            Toggle("Smart quotes (\u{201C}\u{2026}\u{201D} instead of \"\u{2026}\")",
                   isOn: $themeManager.typography.smartQuotes)
            Toggle("Em-dash auto-replace (-- becomes —)",
                   isOn: $themeManager.typography.emDashAutoReplace)
            Toggle("Ellipsis auto-replace (... becomes …)",
                   isOn: $themeManager.typography.ellipsisAutoReplace)

            Text("These transformations happen as you type and respect undo. "
                 + "Disable them if you prefer raw ASCII.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 2: Smoke-build (will still fail until Task 16)**

Skip.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Views/SettingsTabs/TypographySettingsTab.swift
git commit -m "feat: add Typography settings tab"
```

---

## Task 16: GeneralSettingsTab + AboutSettingsTab

**Files:**
- Create: `Maugham/Views/SettingsTabs/GeneralSettingsTab.swift`
- Create: `Maugham/Views/SettingsTabs/AboutSettingsTab.swift`

- [ ] **Step 1: Implement GeneralSettingsTab (placeholder)**

`Maugham/Views/SettingsTabs/GeneralSettingsTab.swift`:
```swift
import SwiftUI

struct GeneralSettingsTab: View {
    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 8) {
                Text("General settings")
                    .font(.headline)
                Text("Default project location, default author name, and other "
                     + "general preferences arrive in milestone 1d.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 2: Implement AboutSettingsTab**

`Maugham/Views/SettingsTabs/AboutSettingsTab.swift`:
```swift
import SwiftUI

struct AboutSettingsTab: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Maugham")
                .font(.system(size: 36, weight: .light, design: .serif))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer().frame(height: 12)
            Link("github.com/dtrouton/Maugham",
                 destination: URL(string: "https://github.com/dtrouton/Maugham")!)
                .font(.callout)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 3: Smoke-build now succeeds**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. The full settings view tree compiles.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/SettingsTabs/GeneralSettingsTab.swift Maugham/Views/SettingsTabs/AboutSettingsTab.swift
git commit -m "feat: add General (placeholder) and About settings tabs"
```

---

## Task 17: Wire Settings scene into MaughamApp

**Files:**
- Modify: `Maugham/MaughamApp.swift`

- [ ] **Step 1: Add Settings scene to MaughamApp**

Open `Maugham/MaughamApp.swift` and add a `Settings` scene to the `body`. Replace the entire `body` with:

```swift
    var body: some Scene {
        Window("Maugham — Welcome", id: "welcome") {
            WelcomeHost()
        }
        .windowResizability(.contentSize)
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
        }

        WindowGroup(id: "project", for: URL.self) { $url in
            if let url {
                ProjectWindow(url: url)
                    .navigationTitle(url.lastPathComponent)
            } else {
                Text("No project URL").foregroundStyle(.secondary)
            }
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
```

The `Settings` scene at the end is what makes ⌘, open the settings window — SwiftUI provides this binding automatically when the scene exists.

- [ ] **Step 2: Smoke-build**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Maugham/MaughamApp.swift
git commit -m "feat: wire Settings scene into MaughamApp"
```

---

## Task 18: End-to-end smoke test + tag

- [ ] **Step 1: Run the full test suite**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: all tests pass. The 1a tests (33) plus the 1b tests (TokenTests 4 + ThemeTests 6 + TypographySettingsTests 3 + ThemeManagerTests 4 + MarkdownTokenizerTests 13 + SmartTypographyTests 8 + ProseModeTests 6 = 44) for **77 total**.

- [ ] **Step 2: Manual smoke test (eight steps from spec)**

In Xcode, ⌘R to run. Walk these eight steps:

1. Launch Maugham, open the milestone-1a Smoke Test project from recents.
2. Editor uses Iowan Old Style at 17pt, line height ~1.7. Background follows system.
3. Type `**bold** and *italic* and \`code\`.` Verify asterisks/backticks dim, bold renders bold, italic renders italic.
4. Open Settings (⌘,) → Theme tab. Switch to Sepia. Editor background turns paper-yellow.
5. Type `--` and watch it become `—`. Type `...` and watch it become `…`. Type `"hello"` and see curly quotes.
6. Settings → Typography. Disable smart quotes. Type `"world"` — straight quotes.
7. Settings → Editor. Drag size slider to 22pt. Editor reflows.
8. Quit and relaunch. Settings persist (still 22pt, Sepia, smart quotes still off).

If all eight pass, milestone 1b is healthy.

- [ ] **Step 3: Tag milestone-1b and merge to main**

```bash
git checkout main
git merge --ff-only feat/phase-1b-editor
git tag -a milestone-1b -m "Maugham milestone 1b — Editor

Real Maugham editor: NSTextView-backed EditorSurface driven by ProseMode
(Markdown), with regex-based tokenizer, smart typography (em dash,
ellipsis, smart quotes), three themes (Light, Dark, Sepia + Follow
System), Iowan Old Style typography defaults, configurable via the
Settings window (⌘,)."
git tag --list 'milestone-*'
```

Expected: `milestone-1a milestone-1b` listed.

- [ ] **Step 4: Update README**

Append to README.md after the existing 1a smoke test section:

```markdown

## Phase 1b smoke test

Once running on milestone-1b:

1. Open Maugham, open a Short Story project.
2. Editor uses Iowan Old Style 17pt with calm syntax highlighting.
3. Type `**bold**` — asterisks dim, "bold" renders bold.
4. ⌘, → Theme → Sepia. Background turns paper-yellow.
5. Type `--` and `...` — see them transform to `—` and `…`.
6. ⌘, → Editor → drag size slider. Editor reflows live.
7. Quit and relaunch. Settings persist.

If all seven pass, milestone 1b is healthy.
```

```bash
git add README.md
git commit -m "docs: add phase 1b smoke test checklist"
```

---

## Self-review checklist

- [x] **Spec coverage:** Every spec section has a task — Token (T2), WritingMode (T3), Theme/palette (T4), TypographySettings (T5), ThemeManager (T6), MarkdownTokenizer (T7), SmartTypography (T8), ProseMode (T9), EditorCoordinator (T10), EditorSurface (T11), ProjectWindow update (T12), Settings UI (T13–17), smoke test (T18). The eight-step manual smoke test from the spec is exactly the manual check in T18.
- [x] **Placeholder scan:** No "TBD", "TODO", "implement later". Every step has actual code or actual commands.
- [x] **Type consistency:** `Theme.followSystem` is consistent across spec/types/tabs. `TypographySettings.defaults` referenced consistently. `Token.Kind.syntaxPunctuation` consistent. `ProseMode()` zero-arg init consistent. `ThemeManager.theme`/`.typography` properties consistent across tabs.
- [x] **TDD:** Pure-logic tasks (2, 4, 5, 6, 7, 8, 9) follow TDD. NSTextView-touching tasks (10, 11) are smoke-build only — appropriate test strategy explained in spec.
- [x] **Commit cadence:** 18 tasks → 18 commits + 1 README commit + 1 milestone tag = 20 history entries.

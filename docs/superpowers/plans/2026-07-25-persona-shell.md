# Persona Shell (M1B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Maugham project window four optional personas — Plan, Author, Review, Publish — that reconfigure all three columns, with a pane registry that later milestones register into rather than hardcode against.

**Architecture:** A new `Persona` enum drives three things: which `DetailSegment`s the right-pane picker offers (via a pure registry), what the left and centre columns render, and a segmented bar in the window toolbar. Persona lives as `@State` on `ProjectWindow` (so two windows can sit in different personas simultaneously) and persists to the per-project `UIState`. The nine existing right-pane shortcuts migrate from an exhausted `⌘⌥1–8` numeric space to mnemonic `⌘⌥`-letters, freeing `⌘1–4` for the personas themselves.

**Tech Stack:** Swift 6, SwiftUI + AppKit, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md` §6 (the shell). This plan implements 1B of milestone M1; 1A (the spine) and 1C (canvas + promotion) follow on the same branch.

## Global Constraints

- **Branch:** `feat/persona-shell-2026-07-25`. Never commit to `main`.
- **`ProjectWindow.body` is at the SwiftUI type-checker ceiling.** Ten extracted `ViewModifier`s already exist for this reason, three carrying comments recording an actual Release-only build failure. **Add nothing inline to the modifier chain at `ProjectWindow.swift:158–310`.** New chrome goes inside an existing modifier; new behaviour goes in a new `.modifier(...)` line.
- **After any `ProjectWindow.body` change, run a Release build before finishing the task:** `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`. Debug passing is not sufficient evidence.
- **Test commands:**
  - Mac: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
  - Single suite: append `-only-testing:MaughamTests/<SuiteName>`
  - Phone: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
  - **MaughamCore is NOT in the Maugham scheme.** If you touch `Packages/MaughamCore/`, you must also run `swift test --package-path Packages/MaughamCore`. Nothing else runs those 61 test files — not CI, not the documented loop.
- **Run `./gen.sh` after adding any new source file.** `Maugham.xcodeproj/` is generated and gitignored; `project.yml` is the source of truth. Never hand-edit `project.pbxproj`; never commit anything under `Maugham.xcodeproj/`.
- **No UI automation exists in this repo.** There is no `XCUIApplication` anywhere. A view is tested by extracting its logic as `static` functions on the view type and calling them directly, plus a store-seam test driving a real `ProjectStore`. `MaughamTests/Views/PalettePaneTests.swift` is the canonical example of both halves.
- **Test style:** XCTest only (zero `import Testing` in the repo). `final class <Thing>Tests: XCTestCase`, methods named `test_<subject>_<expectation>`, `@MainActor` on the class whenever it touches `Document` / `ProjectStore` / `DocumentStore`.
- **Tripwire — ADR 0021:** any raw `NotificationCenter.default.post(` or `.maugham*` publisher/observer fails `TripwireGrepTests.test_noRawMaughamPostsOrSubscriptionsOutsideWrapper`. This scans **`MaughamTests/` as well as `Maugham/`** — it will bite your test code. Use `MaughamEvent.post(_:to:)` and the `.onKeyWindowCommand` family.
- **Tripwire — ContentUnavailableView:** any `ContentUnavailableView(` in `Maugham/Views/` must have `.frame(maxWidth: .infinity, maxHeight: .infinity)` within 4 lines, and the enclosing `VStack` needs `alignment: .top`.
- **Tripwire — identity literals:** the bare quoted literals `"Maugham"` and `"maugham"` are forbidden outside `BuildVariant.swift`. Use `BuildVariant.current.displayName` etc.
- **Persona is a value type — do NOT add it to the `onDisappear` scorch block** at `ProjectWindow.swift:181–185`. That block nils heavy state (`store`, `documentStore`, `lastParsedScript`); nil-ing a persona would hand a re-shown zombie window a bogus default.

### The keymap this plan establishes

| Key | Meaning | Change |
|---|---|---|
| `⌘1` `⌘2` `⌘3` `⌘4` | Plan / Author / Review / Publish | **new** (⌘1–4 are currently unbound app-wide) |
| `⌘⌥I` | Inspector pane | was `⌘⌥1` |
| `⌘⌥R` | Research pane | was `⌘⌥2` |
| `⌘⌥O` | Outline pane | was `⌘⌥3` |
| `⌘⌥H` | History pane | was `⌘⌥4` |
| `⌘⌥T` | Tasks pane | was `⌘⌥5` |
| `⌘⌥B` | Inbox pane | was `⌘⌥6` |
| `⌘⌥P` | Palette pane | was `⌘⌥7` |
| `⌘⌥L` | Translation pane | was `⌘⌥8` |
| `⌘⌥A` | Annotations pane | **unchanged** |
| `⌘⌥0` | Toggle inspector column | was `⌘⌥I` (Xcode uses ⌘⌥0 for exactly this) |
| `⌘⌥⇧R` | Toggle Review Mode | was `⌘⌥R` |

Reserved for later milestones, do not assign: `⌘⌥D` diagnostics, `⌘⌥E` references, `⌘⌥G` intent, `⌘⌥V` visual language.

---

## File Structure

| File | Responsibility |
|---|---|
| `Maugham/Models/Persona.swift` *(new)* | The enum, its display metadata, and the persona→panes registry. Pure, no SwiftUI. |
| `Maugham/Views/PersonaBar.swift` *(new)* | The segmented control. Pure view + `static` helpers for testing. |
| `Maugham/Stores/UIState.swift` | Gains `persona`; schema 3 → 4. |
| `Maugham/Views/ProjectWindow.swift` | `@State persona`, restore in `load()`, `PersonaModifier`, `TopChromeModifier` gains the bar, column builders branch. |
| `Maugham/Views/DetailPaneToggle.swift` | Picker filtered by persona; shortcuts → letters; badge offset fixed. |
| `Maugham/MaughamApp.swift` | `⌘1–4` commands; retarget `⌘⌥1/2/3`; move `⌘⌥I` and `⌘⌥R`. |
| `Maugham/Models/MaughamNotifications.swift` | `maughamSetPersona`. |
| `Maugham/Resources/KeyboardShortcuts.swift` | In-app cheatsheet (currently stale — this plan fixes it). |
| `docs/guide/reference.md`, `docs/guide/right-pane.md` | Test-enforced shortcut and segment documentation. |

---

## Task 1: Persona model and UIState persistence

**Files:**
- Create: `Maugham/Models/Persona.swift`
- Create: `MaughamTests/PersonaTests.swift`
- Modify: `Maugham/Stores/UIState.swift`
- Modify: `MaughamTests/UIStateTests.swift` (create if absent)

**Interfaces:**
- Produces: `Persona` (`.plan`, `.author`, `.review`, `.publish`), `Persona.displayName: String`, `Persona.systemImageName: String`, `Persona.shortcutKey: Character`; `UIState.persona: Persona`.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/PersonaTests.swift`:

```swift
import XCTest
@testable import Maugham

final class PersonaTests: XCTestCase {
    func test_allCases_areInStageOrder() {
        XCTAssertEqual(Persona.allCases, [.plan, .author, .review, .publish])
    }

    func test_rawValues_areStableSnakeCaseTokens() {
        XCTAssertEqual(Persona.plan.rawValue, "plan")
        XCTAssertEqual(Persona.author.rawValue, "author")
        XCTAssertEqual(Persona.review.rawValue, "review")
        XCTAssertEqual(Persona.publish.rawValue, "publish")
    }

    func test_shortcutKeys_areOneThroughFourInOrder() {
        XCTAssertEqual(Persona.allCases.map(\.shortcutKey), ["1", "2", "3", "4"])
    }

    func test_everyPersona_hasNonEmptyDisplayNameAndIcon() {
        for persona in Persona.allCases {
            XCTAssertFalse(persona.displayName.isEmpty, "\(persona) has no display name")
            XCTAssertFalse(persona.systemImageName.isEmpty, "\(persona) has no icon")
        }
    }

    func test_decode_ofUnrecognisedRawValue_fallsBackToAuthor() throws {
        // Forward tolerance: a project written by a newer build naming a
        // persona this build has never heard of must open in the default
        // rather than refuse. Persona is presentation state, not identity —
        // unlike ResearchRole it does not need lossless round-tripping.
        let json = Data(#""somethingNewer""#.utf8)
        let decoded = try JSONDecoder().decode(Persona.self, from: json)
        XCTAssertEqual(decoded, .author)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PersonaTests`
Expected: FAIL — "cannot find type 'Persona' in scope"

- [ ] **Step 3: Write minimal implementation**

Create `Maugham/Models/Persona.swift`:

```swift
import Foundation

/// The window's current working mode. Four optional lenses over one project —
/// never gates. Every persona is reachable at any time regardless of project
/// state; nothing is disabled, and nothing is required before writing.
///
/// Decoding is forward-tolerant: an unrecognised raw value becomes `.author`
/// rather than throwing, so a project touched by a newer build still opens.
/// This is deliberately weaker than `ResearchRole`'s lossless `.unknown`
/// sentinel — persona is presentation state, not identity, so there is nothing
/// to preserve on behalf of the newer build.
public enum Persona: String, Codable, Equatable, Sendable, CaseIterable {
    case plan
    case author
    case review
    case publish

    /// The default a fresh project opens in. Authoring is the mode most of a
    /// writer's hours are spent in, and the one whose layout matches today's
    /// window exactly — so an upgrading writer sees no change until they ask.
    public static let `default`: Persona = .author

    public var displayName: String {
        switch self {
        case .plan: return "Plan"
        case .author: return "Author"
        case .review: return "Review"
        case .publish: return "Publish"
        }
    }

    public var systemImageName: String {
        switch self {
        case .plan: return "lightbulb"
        case .author: return "pencil.line"
        case .review: return "text.magnifyingglass"
        case .publish: return "book.closed"
        }
    }

    /// ⌘1–⌘4. Ordering is the stage arc, and `allCases` order must match.
    public var shortcutKey: Character {
        switch self {
        case .plan: return "1"
        case .author: return "2"
        case .review: return "3"
        case .publish: return "4"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Persona(rawValue: raw) ?? .default
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PersonaTests`
Expected: PASS, 5 tests

- [ ] **Step 5: Write the failing UIState test**

Create or extend `MaughamTests/UIStateTests.swift`:

```swift
import XCTest
@testable import Maugham

final class UIStatePersonaTests: XCTestCase {
    func test_currentSchemaVersion_is4() {
        XCTAssertEqual(UIState.currentSchemaVersion, 4)
    }

    func test_empty_defaultsToAuthorPersona() {
        XCTAssertEqual(UIState.empty.persona, .author)
    }

    func test_decode_ofV3StateWithoutPersona_defaultsToAuthor() throws {
        // A project last opened by a pre-persona build has no `persona` key.
        // It must decode, not throw, and land on the default.
        let json = Data("""
        {"schemaVersion":3,"isNoChromeOn":false,"binderSegment":"manuscript",
         "researchPreviewVisible":false,"detailSegment":"inspector",
         "outlineLayout":"table","isReviewModeOn":false}
        """.utf8)
        let decoded = try JSONDecoder().decode(UIState.self, from: json)
        XCTAssertEqual(decoded.persona, .author)
    }

    func test_persona_roundTripsThroughEncoding() throws {
        var state = UIState.empty
        state.persona = .plan
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.persona, .plan)
    }

    func test_loadOrEmpty_rejectsStateFromANewerSchema() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UIStatePersonaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ui-state.json")
        try Data(#"{"schemaVersion":99,"persona":"plan"}"#.utf8).write(to: url)

        XCTAssertEqual(UIState.loadOrEmpty(from: url).persona, .author,
                       "a newer schema must fall back to .empty, not adopt its values")
    }
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/UIStatePersonaTests`
Expected: FAIL — `UIState.currentSchemaVersion` is 3; `persona` does not exist.

- [ ] **Step 7: Add the field to UIState**

In `Maugham/Stores/UIState.swift`:

1. Line 6 — bump the version:
```swift
    static let currentSchemaVersion = 4
```

2. After the `isReviewModeOn` declaration (line 18), add:
```swift
    /// The window's working mode. Persisted per PROJECT, not per window —
    /// `UIState` lives at `.maugham/ui-state.json` and two windows on the same
    /// project share it, last-writer-wins. That is deliberate and matches
    /// `isNoChromeOn` / `isReviewModeOn`, which have the same shape. Runtime
    /// per-window independence comes from `ProjectWindow`'s `@State`; only the
    /// mode a *freshly opened* window starts in is shared.
    var persona: Persona
```

3. Add `persona: Persona = .default` as the final parameter of the memberwise init (line 20–38) and assign it in the body.

4. Add `case persona` to `CodingKeys` (lines 42–45).

5. In `init(from:)` (lines 47–62), alongside the other tolerant decodes:
```swift
        persona = (try? c.decode(Persona.self, forKey: .persona)) ?? .default
```

- [ ] **Step 8: Run to verify it passes**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/UIStatePersonaTests`
Expected: PASS, 5 tests

- [ ] **Step 9: Run the full suite — one known break**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: everything passes. `ProjectManifestTests.swift:94` asserts `ProjectManifest.currentSchemaVersion == 3` — that is the **manifest** schema, a different constant from `UIState.currentSchemaVersion`. It must NOT change here. If it fails you edited the wrong file.

- [ ] **Step 10: Commit**

```bash
git add Maugham/Models/Persona.swift Maugham/Stores/UIState.swift MaughamTests/PersonaTests.swift MaughamTests/UIStateTests.swift
git commit -m "feat: Persona enum and UIState persistence"
```

---

## Task 2: The persona → pane registry

**Files:**
- Modify: `Maugham/Models/Persona.swift`
- Create: `MaughamTests/PersonaPaneRegistryTests.swift`

**Interfaces:**
- Consumes: `Persona` (Task 1), `DetailSegment` (existing, `Maugham/Models/DetailSegment.swift`).
- Produces: `Persona.panes: [DetailSegment]`, `Persona.defaultPane: DetailSegment`, `Persona.coerce(_ segment: DetailSegment) -> DetailSegment`.

This is the mechanism M1A and M1C register into. Later milestones add a `DetailSegment` case and one line to a persona's `panes` array — they do not touch the picker, the shortcuts, or the window.

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/PersonaPaneRegistryTests.swift`:

```swift
import XCTest
@testable import Maugham

final class PersonaPaneRegistryTests: XCTestCase {
    func test_everyPersona_offersAtLeastTwoPanes() {
        // A one-pane picker reads as broken chrome rather than a choice.
        for persona in Persona.allCases {
            XCTAssertGreaterThanOrEqual(persona.panes.count, 2,
                                        "\(persona) offers \(persona.panes.count) pane(s)")
        }
    }

    func test_everyPersona_listsEachPaneAtMostOnce() {
        for persona in Persona.allCases {
            XCTAssertEqual(Set(persona.panes).count, persona.panes.count,
                           "\(persona) lists a duplicate pane")
        }
    }

    func test_everyDetailSegment_appearsInAtLeastOnePersona() {
        // Guards the failure mode where a new pane is added to DetailSegment
        // but never registered, making it permanently unreachable.
        let registered = Set(Persona.allCases.flatMap(\.panes))
        for segment in DetailSegment.allCases {
            XCTAssertTrue(registered.contains(segment),
                          "\(segment) is registered in no persona and is unreachable")
        }
    }

    func test_defaultPane_isTheFirstRegisteredPane() {
        for persona in Persona.allCases {
            XCTAssertEqual(persona.defaultPane, persona.panes.first)
        }
    }

    func test_authorPersona_excludesAnnotations() {
        // The two-loop separation from the design: adjudicating durable notes
        // is a review activity. Diagnostics (M1B+1) serve the fast loop.
        XCTAssertFalse(Persona.author.panes.contains(.annotations))
    }

    func test_reviewPersona_leadsWithAnnotations() {
        XCTAssertEqual(Persona.review.defaultPane, .annotations)
    }

    func test_inboxIsPlanningOnly() {
        // Phone captures are raw planning material. They previously sat
        // between Tasks and Palette, which is why the segment needed an
        // unread badge to be discoverable at all.
        for persona in Persona.allCases where persona != .plan {
            XCTAssertFalse(persona.panes.contains(.inbox), "\(persona) should not offer the inbox")
        }
        XCTAssertTrue(Persona.plan.panes.contains(.inbox))
    }

    func test_coerce_keepsAPaneThePersonaOffers() {
        XCTAssertEqual(Persona.author.coerce(.tasks), .tasks)
    }

    func test_coerce_redirectsAPaneThePersonaDoesNotOffer() {
        XCTAssertEqual(Persona.author.coerce(.annotations), Persona.author.defaultPane)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PersonaPaneRegistryTests`
Expected: FAIL — "value of type 'Persona' has no member 'panes'"

- [ ] **Step 3: Write the implementation**

Append to `Maugham/Models/Persona.swift`:

```swift
// MARK: - Pane registry

public extension Persona {
    /// The right-pane segments this persona offers, in picker order. The first
    /// is the persona's default.
    ///
    /// THIS IS THE EXTENSION POINT. A milestone adding a right-pane surface
    /// adds its `DetailSegment` case and one entry here — it does not touch
    /// `DetailPaneToggle`, the shortcut table, or `ProjectWindow`.
    ///
    /// Reserved for later milestones of this redesign: `.diagnostics` →
    /// author; `.references` → author, review; `.intent` → plan, author,
    /// review, publish; `.visualLanguage` → plan, review, publish;
    /// `.editions` → publish.
    var panes: [DetailSegment] {
        switch self {
        case .plan:
            return [.research, .outline, .palette, .inbox, .inspector]
        case .author:
            return [.inspector, .outline, .research, .tasks, .palette]
        case .review:
            return [.annotations, .history, .inspector, .outline, .tasks]
        case .publish:
            // Thin until M1D gives Publishing its own surfaces (editions,
            // config, visual language). Translation is genuinely its work
            // today; inspector keeps the picker from being a single button.
            return [.translation, .inspector]
        }
    }

    var defaultPane: DetailSegment {
        // `panes` is never empty — PersonaPaneRegistryTests enforces ≥2.
        panes.first ?? .inspector
    }

    /// Map a segment onto one this persona actually offers. Used when the
    /// writer switches persona while sitting on a pane the destination does
    /// not have — the same shape as `BinderSegment.documentHome(for:)`, which
    /// exists because re-deriving that check inline shipped a real bug
    /// (2026-07-02 smoke finding).
    func coerce(_ segment: DetailSegment) -> DetailSegment {
        panes.contains(segment) ? segment : defaultPane
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PersonaPaneRegistryTests`
Expected: PASS, 9 tests

- [ ] **Step 5: Commit**

```bash
git add Maugham/Models/Persona.swift MaughamTests/PersonaPaneRegistryTests.swift
git commit -m "feat: persona to pane registry as the extension point for later panes"
```

---

## Task 3: Keyspace migration — panes take letters

**Files:**
- Modify: `Maugham/MaughamApp.swift:177–228` (View menu)
- Modify: `Maugham/Views/DetailPaneToggle.swift:101–160` (picker + shortcuts + help strings)
- Modify: `Maugham/Resources/KeyboardShortcuts.swift`
- Modify: `docs/guide/reference.md`
- Modify: `MaughamTests/GuideMarkdownViewTests.swift:130`
- Create: `MaughamTests/PersonaKeyspaceTests.swift`

**Interfaces:**
- Consumes: `Persona` (Task 1).
- Produces: every right-pane segment reachable by `⌘⌥<letter>` through the **menu → `maughamSetDetailSegment` → `SessionAndNavigationModifier`** path (which also forces `showInspector = true`).

This task also removes a real asymmetry: today `⌘⌥1/2/3/A` go via the menu and reveal a hidden inspector column, while `⌘⌥4–8` are `.keyboardShortcut` attached to `Picker` tags and silently do nothing when the column is hidden.

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/PersonaKeyspaceTests.swift`:

```swift
import XCTest
@testable import Maugham

/// Source-text guards. These read the real files rather than exercising
/// SwiftUI, which this repo has no automation for.
final class PersonaKeyspaceTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func test_noPaneUsesANumericCommandOptionShortcut() throws {
        // The flat ⌘⌥ numeric space is retired. ⌘⌥0 is the inspector-column
        // toggle (Xcode's key for the same thing) and is the sole exception.
        for path in ["Maugham/MaughamApp.swift", "Maugham/Views/DetailPaneToggle.swift"] {
            let text = try source(path)
            for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9"] {
                XCTAssertFalse(
                    text.contains(#"keyboardShortcut("\#(digit)", modifiers: [.command, .option])"#),
                    "\(path) still binds ⌘⌥\(digit)")
            }
        }
    }

    func test_allPaneShortcutsAreDeclaredInTheMenuNotThePicker() throws {
        // One dispatch path, so every pane shortcut reveals a hidden column.
        let picker = try source("Maugham/Views/DetailPaneToggle.swift")
        XCTAssertFalse(picker.contains("keyboardShortcut("),
                       "DetailPaneToggle must not declare shortcuts; the View menu owns them")
    }

    func test_everyDetailSegmentHasAMenuShortcut() throws {
        let app = try source("Maugham/MaughamApp.swift")
        for segment in DetailSegment.allCases {
            XCTAssertTrue(app.contains(#""segment": "\#(segment.rawValue)""#),
                          "no View-menu item posts \(segment.rawValue)")
        }
    }

    func test_personaShortcutsAreBound() throws {
        let app = try source("Maugham/MaughamApp.swift")
        for persona in Persona.allCases {
            XCTAssertTrue(
                app.contains(#"keyboardShortcut("\#(persona.shortcutKey)", modifiers: .command)"#),
                "⌘\(persona.shortcutKey) is not bound for \(persona.displayName)")
        }
    }

    func test_reviewModeAndInspectorToggleMovedOffTheirOldKeys() throws {
        let app = try source("Maugham/MaughamApp.swift")
        XCTAssertTrue(app.contains(#"keyboardShortcut("r", modifiers: [.command, .option, .shift])"#),
                      "Toggle Review Mode should be ⌘⌥⇧R, freeing ⌘⌥R for Research")
        XCTAssertTrue(app.contains(#"keyboardShortcut("0", modifiers: [.command, .option])"#),
                      "Toggle Inspector should be ⌘⌥0, freeing ⌘⌥I for the Inspector pane")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PersonaKeyspaceTests`
Expected: FAIL on all five — `⌘⌥1` still present, picker still declares shortcuts, etc.

- [ ] **Step 3: Move the two colliding toggles**

In `Maugham/MaughamApp.swift`, line 186 — Toggle Review Mode:
```swift
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
```

Line 195 — Toggle Inspector:
```swift
                .keyboardShortcut("0", modifiers: [.command, .option])
```

- [ ] **Step 4: Replace the four pane menu items with all nine**

In `Maugham/MaughamApp.swift`, replace the block at lines 201–217 (the four `Button`s carrying `⌘⌥1`, `⌘⌥2`, `⌘⌥3`, `⌘⌥A`) with:

```swift
                Divider()

                // Right-pane segments. All nine are declared here rather than
                // on the Picker in DetailPaneToggle, so every one reveals a
                // hidden inspector column (SessionAndNavigationModifier sets
                // showInspector = true). Splitting these across two dispatch
                // paths meant ⌘⌥4–8 silently no-opped with the column closed.
                Button("Inspector") { postSegment(.inspector) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Research") { postSegment(.research) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Outline") { postSegment(.outline) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Annotations") { postSegment(.annotations) }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Button("History") { postSegment(.history) }
                    .keyboardShortcut("h", modifiers: [.command, .option])
                Button("Tasks") { postSegment(.tasks) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Inbox") { postSegment(.inbox) }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Button("Palette") { postSegment(.palette) }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Translation") { postSegment(.translation) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
```

Add this helper as a private method on the same type that owns `body` (place it immediately after the `.commands` block closes, around line 256):

```swift
    /// One spelling of the segment post, so the nine menu items can't drift
    /// apart. `.keyWindow` scope: only the focused project window responds.
    private func postSegment(_ segment: DetailSegment) {
        MaughamEvent.post(.maughamSetDetailSegment,
                          to: .keyWindow,
                          payload: ["segment": segment.rawValue])
    }
```

- [ ] **Step 5: Strip the shortcuts from the picker**

In `Maugham/Views/DetailPaneToggle.swift`, delete the five `.keyboardShortcut(...)` lines at 121, 125, 129, 133, 137, and update every `.help()` string at lines 106–137 to the new keys:

```swift
                .help("Inspector — document metadata, tags, links (⌘⌥I)")
                .help("Annotations — review Claude's comments and suggested edits (⌘⌥A)")
                .help("Research — this document's own and linked research (⌘⌥R)")
                .help("Outline — table or corkboard structure view (⌘⌥O)")
                .help("History — read-only timeline of edits, annotations, and checkpoints (⌘⌥H)")
                .help("Tasks — todos in this document and across the project (⌘⌥T)")
                .help("Inbox — triage captures from MaughamPhone (⌘⌥B)")
                .help("Palette Card (⌘⌥P)")
                .help("Translation — source text and translator queries (⌘⌥L)")
```

- [ ] **Step 6: Update the in-app cheatsheet**

In `Maugham/Resources/KeyboardShortcuts.swift`, replace the three stale pane entries (lines 34–36) with the full set:

```swift
        Entry(label: "Plan mode", shortcut: "⌘1"),
        Entry(label: "Author mode", shortcut: "⌘2"),
        Entry(label: "Review mode", shortcut: "⌘3"),
        Entry(label: "Publish mode", shortcut: "⌘4"),
        Entry(label: "Inspector pane", shortcut: "⌘⌥I"),
        Entry(label: "Research pane", shortcut: "⌘⌥R"),
        Entry(label: "Outline pane", shortcut: "⌘⌥O"),
        Entry(label: "Annotations pane", shortcut: "⌘⌥A"),
        Entry(label: "History pane", shortcut: "⌘⌥H"),
        Entry(label: "Tasks pane", shortcut: "⌘⌥T"),
        Entry(label: "Inbox pane", shortcut: "⌘⌥B"),
        Entry(label: "Palette pane", shortcut: "⌘⌥P"),
        Entry(label: "Translation pane", shortcut: "⌘⌥L"),
        Entry(label: "Toggle inspector column", shortcut: "⌘⌥0"),
```

- [ ] **Step 7: Update the guide**

In `docs/guide/reference.md`, the single shortcut table: replace the `⌘⌥1`/`⌘⌥2`/`⌘⌥3` rows with the thirteen rows above, keeping the existing `⌘⌥A` row and amending `⌘⌥R` → `⌘⌥⇧R` and `⌘⌥I` → `⌘⌥0`. Count the resulting rows.

Then in `MaughamTests/GuideMarkdownViewTests.swift:130`, update the literal to the new count:
```swift
        XCTAssertEqual(rows.count, 33, "one row per documented shortcut")
```
(33 assumes 23 existing + 13 new − 3 replaced. **Count the actual table** and use that number; do not trust this arithmetic.)

- [ ] **Step 8: Run the targeted tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PersonaKeyspaceTests -only-testing:MaughamTests/DocSyncTests -only-testing:MaughamTests/GuideMarkdownViewTests -only-testing:MaughamTests/KeyboardShortcutsTests`
Expected: PASS.

**`DocSyncTests.test_detailPaneToggleShortcutsDocumentedInReferenceMd` must be repointed, not left to pass vacuously.** It extracts `⌘⌥`-shortcuts from `DetailPaneToggle.swift`, which after Step 5 declares none — so it would pass while asserting nothing, which is worse than deleting it. The guard is still wanted; only its source file moved. In `MaughamTests/DocSyncTests.swift`, change the file it reads from `Maugham/Views/DetailPaneToggle.swift` to `Maugham/MaughamApp.swift`, rename the method to `test_paneShortcutsDocumentedInReferenceMd`, and update its doc comment to say the View menu now owns every pane shortcut. The existing regex (`\.keyboardShortcut\("([^"]+)",\s*modifiers:\s*\[\.command,\s*\.option\]\)`) already matches letters and needs no change.

Add an anti-vacuity guard, since the whole point of this edit is that a guard which extracts nothing passes silently. Note `MaughamApp.swift` also carries non-pane `⌘⌥` bindings (`⌘⌥0` inspector column, `⌘⌥F` find in project, `⌘⌥Z` restore), so the count is *more* than the nine panes — assert a floor, not equality. `⌘⌥⇧R` does not match: its modifier list is `[.command, .option, .shift]`.

```swift
        XCTAssertGreaterThanOrEqual(shortcuts.count, DetailSegment.allCases.count,
                                    "extracted \(shortcuts.count) ⌘⌥ shortcuts — expected at least "
                                    + "one per DetailSegment case; a regex that matches nothing "
                                    + "makes this whole test vacuous")
```

- [ ] **Step 9: Full suite + Release build**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO
```
Expected: both succeed.

- [ ] **Step 10: Commit**

```bash
git add Maugham/MaughamApp.swift Maugham/Views/DetailPaneToggle.swift \
        Maugham/Resources/KeyboardShortcuts.swift docs/guide/reference.md \
        MaughamTests/PersonaKeyspaceTests.swift MaughamTests/GuideMarkdownViewTests.swift
git commit -m "feat: migrate right-pane shortcuts to mnemonic letters, unify dispatch"
```

---

## Task 4: Persona state, event, and restore

**Files:**
- Modify: `Maugham/Models/MaughamNotifications.swift`
- Modify: `Maugham/MaughamApp.swift` (View menu)
- Modify: `Maugham/Views/ProjectWindow.swift` (`@State`, `PersonaModifier`, `load()`)
- Create: `MaughamTests/PersonaModifierTests.swift`

**Interfaces:**
- Consumes: `Persona`, `Persona.coerce(_:)` (Tasks 1–2).
- Produces: `Notification.Name.maughamSetPersona`; `ProjectWindow.persona` `@State`; `PersonaModifier` (file-private).

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/PersonaModifierTests.swift`:

```swift
import XCTest
@testable import Maugham

@MainActor
final class PersonaModifierTests: XCTestCase {
    func test_applyPersonaChange_coercesASegmentTheDestinationLacks() {
        // Sitting on Annotations in Review, then switching to Author, which
        // does not offer it. Landing on a blank pane would read as a bug.
        let result = PersonaModifier.applyPersonaChange(to: .author, currentSegment: .annotations)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, Persona.author.defaultPane)
    }

    func test_applyPersonaChange_keepsASegmentTheDestinationOffers() {
        let result = PersonaModifier.applyPersonaChange(to: .review, currentSegment: .outline)
        XCTAssertEqual(result.segment, .outline, "Outline exists in Review; don't disturb it")
    }

    func test_applyPersonaChange_toTheSamePersona_isIdentity() {
        let result = PersonaModifier.applyPersonaChange(to: .author, currentSegment: .tasks)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, .tasks)
    }

    func test_personaFromPayload_parsesAValidRawValue() {
        XCTAssertEqual(PersonaModifier.persona(fromPayload: "review"), .review)
    }

    func test_personaFromPayload_rejectsGarbage() {
        XCTAssertNil(PersonaModifier.persona(fromPayload: "nonsense"))
        XCTAssertNil(PersonaModifier.persona(fromPayload: nil))
    }
}
```

Note the asymmetry with Task 1: `Persona.init(from:)` is deliberately lenient for stored state, but `persona(fromPayload:)` is strict, because a malformed event payload is a bug in our own code, not a forward-compatibility case.

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PersonaModifierTests`
Expected: FAIL — "cannot find 'PersonaModifier' in scope"

- [ ] **Step 3: Declare the notification**

In `Maugham/Models/MaughamNotifications.swift`, beside `maughamSetDetailSegment`:

```swift
    /// Scope: .keyWindow — payload ["persona": Persona.rawValue].
    /// Only the focused project window switches; other windows keep their own
    /// persona, which is the point of per-window modes.
    static let maughamSetPersona = Notification.Name("maugham.set.persona")
```

- [ ] **Step 4: Add the ⌘1–4 menu items**

In `Maugham/MaughamApp.swift`, at the top of the `CommandGroup(after: .toolbar)` block (before the existing focus-mode items around line 178):

```swift
                ForEach(Persona.allCases, id: \.self) { persona in
                    Button(persona.displayName) {
                        MaughamEvent.post(.maughamSetPersona,
                                          to: .keyWindow,
                                          payload: ["persona": persona.rawValue])
                    }
                    .keyboardShortcut(KeyEquivalent(persona.shortcutKey), modifiers: .command)
                }

                Divider()
```

- [ ] **Step 5: Add the modifier and state**

In `Maugham/Views/ProjectWindow.swift`, add beside `detailSegment` (line 53):

```swift
    @State private var persona: Persona = .default
```

Add a file-private modifier next to the other extracted ones (after `FocusPostureModifier`, around line 1329):

```swift
/// Persona switching. Extracted so ProjectWindow.body's modifier chain gains
/// exactly one expression — the chain is at the SwiftUI type-checker ceiling
/// and three sibling modifiers exist because inlining broke the Release build.
private struct PersonaModifier: ViewModifier {
    @Binding var persona: Persona
    @Binding var detailSegment: DetailSegment
    @Binding var showInspector: Bool
    let window: NSWindow?
    let documentStore: DocumentStore?

    struct Change: Equatable {
        let persona: Persona
        let segment: DetailSegment
    }

    /// Pure core, so the coercion is testable without SwiftUI.
    static func applyPersonaChange(to persona: Persona, currentSegment: DetailSegment) -> Change {
        Change(persona: persona, segment: persona.coerce(currentSegment))
    }

    static func persona(fromPayload raw: String?) -> Persona? {
        guard let raw else { return nil }
        return Persona(rawValue: raw)
    }

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamSetPersona, window: window) { note in
                guard let next = Self.persona(fromPayload: note.userInfo?["persona"] as? String)
                else { return }
                let change = Self.applyPersonaChange(to: next, currentSegment: detailSegment)
                persona = change.persona
                detailSegment = change.segment
                showInspector = true
                documentStore?.updateUIState { $0.persona = change.persona }
            }
    }
}
```

Add one line to the chain in `ProjectWindow.body`, immediately after the existing `.modifier(FocusPostureModifier(…))` at line 274:

```swift
        .modifier(PersonaModifier(persona: $persona,
                                  detailSegment: $detailSegment,
                                  showInspector: $showInspector,
                                  window: window,
                                  documentStore: documentStore))
```

- [ ] **Step 6: Restore on open**

In `ProjectWindow.load()`, beside the other `uiState` restores (after line 1114):

```swift
        self.persona = ds.uiState.persona
        self.detailSegment = ds.uiState.persona.coerce(ds.uiState.detailSegment)
```

The second line matters: a project last opened before this milestone has a saved `detailSegment` that the default persona may not offer.

- [ ] **Step 7: Run to verify it passes**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PersonaModifierTests`
Expected: PASS, 5 tests

- [ ] **Step 8: Full suite + Release build**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO
```
Expected: both succeed. If the Release build reports "unable to type-check this expression in reasonable time", you added more than one expression to the chain — move work into `PersonaModifier`.

- [ ] **Step 9: Commit**

```bash
git add Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift \
        Maugham/Views/ProjectWindow.swift MaughamTests/PersonaModifierTests.swift
git commit -m "feat: persona state, scoped event, and restore on open"
```

---

## Task 5: The persona bar

**Files:**
- Create: `Maugham/Views/PersonaBar.swift`
- Create: `MaughamTests/Views/PersonaBarTests.swift`
- Modify: `Maugham/Views/ProjectWindow.swift` (`TopChromeModifier`, lines 366–378 and its call site at 159)

**Interfaces:**
- Consumes: `Persona`, `Notification.Name.maughamSetPersona` (Tasks 1, 4).
- Produces: `PersonaBar(persona:onSelect:)`; `PersonaBar.isVisible(isNoChromeOn:)`.

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/Views/PersonaBarTests.swift`:

```swift
import XCTest
@testable import Maugham

final class PersonaBarTests: XCTestCase {
    func test_isHidden_inNoChromeFocusMode() {
        // Must #2, get out of the way: the bar is permanent chrome and has to
        // disappear with the titlebar under ⌘\. Nothing in this codebase hides
        // automatically — every SwiftUI view that vanishes in focus mode
        // checks isNoChromeOn explicitly.
        XCTAssertFalse(PersonaBar.isVisible(isNoChromeOn: true))
    }

    func test_isVisible_normally() {
        XCTAssertTrue(PersonaBar.isVisible(isNoChromeOn: false))
    }

    func test_accessibilityLabel_namesThePersonaAndItsKey() {
        XCTAssertEqual(PersonaBar.accessibilityLabel(for: .plan), "Plan mode, Command 1")
        XCTAssertEqual(PersonaBar.accessibilityLabel(for: .publish), "Publish mode, Command 4")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PersonaBarTests`
Expected: FAIL — "cannot find 'PersonaBar' in scope"

- [ ] **Step 3: Write the view**

Create `Maugham/Views/PersonaBar.swift`:

```swift
import SwiftUI

/// The four-persona switcher. Lives in the window's top safe-area inset via
/// TopChromeModifier, so ProjectWindow.body's modifier chain is untouched.
///
/// Clicking a segment posts `.maughamSetPersona` exactly as ⌘1–4 do, so there
/// is ONE code path that changes persona and applies the segment coercions —
/// `PersonaModifier`. The bar deliberately holds no mutation logic of its own.
/// (The `.keyWindow` scope is safe here: the bar is window chrome, never
/// inside a sheet or confirmationDialog, so the receiving window is key.)
struct PersonaBar: View {
    let persona: Persona
    let onSelect: (Persona) -> Void

    static func isVisible(isNoChromeOn: Bool) -> Bool { !isNoChromeOn }

    static func accessibilityLabel(for persona: Persona) -> String {
        "\(persona.displayName) mode, Command \(persona.shortcutKey)"
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Persona.allCases, id: \.self) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    Label(candidate.displayName, systemImage: candidate.systemImageName)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: candidate == persona ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(candidate == persona
                                      ? Color.accentColor.opacity(0.18)
                                      : Color.clear))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("\(candidate.displayName) (⌘\(candidate.shortcutKey))")
                .accessibilityLabel(Self.accessibilityLabel(for: candidate))
                .accessibilityAddTraits(candidate == persona ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PersonaBarTests`
Expected: PASS, 3 tests

- [ ] **Step 5: Mount it in TopChromeModifier**

In `Maugham/Views/ProjectWindow.swift`, extend `TopChromeModifier` (lines 366–378) with the three new properties and the bar:

```swift
    private struct TopChromeModifier: ViewModifier {
        let projectURL: URL
        let persona: Persona
        let isNoChromeOn: Bool
        let onSelectPersona: (Persona) -> Void

        func body(content: Content) -> some View {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if PersonaBar.isVisible(isNoChromeOn: isNoChromeOn) {
                            PersonaBar(persona: persona, onSelect: onSelectPersona)
                            Divider()
                        }
                        UpdateBannerView()
                        BackupRecoveryBanner(projectURL: projectURL)
                    }
                }
                .focusedSceneValue(\.projectURL, projectURL)
        }
    }
```

Update the call site at line 159. The closure only posts — it must NOT duplicate the mutation block from `PersonaModifier.body`, which already handles this event:

```swift
        .modifier(TopChromeModifier(
            projectURL: url,
            persona: persona,
            isNoChromeOn: isNoChromeOn,
            onSelectPersona: { next in
                MaughamEvent.post(.maughamSetPersona,
                                  to: .keyWindow,
                                  payload: ["persona": next.rawValue])
            }))
```

One code path for persona changes, whether they arrive from ⌘1–4 or from a click. Duplicating the coercion logic here is how the two drift.

- [ ] **Step 6: Full suite + Release build**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO
```
Expected: both succeed. `TopChromeModifier` exists precisely because two inline banner views once broke Release-only; if it fails now, extract the closure into a private method on `ProjectWindow`.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Views/PersonaBar.swift Maugham/Views/ProjectWindow.swift MaughamTests/Views/PersonaBarTests.swift
git commit -m "feat: persona bar in the top chrome, hidden in focus mode"
```

---

## Task 6: Persona-aware right pane

**Files:**
- Modify: `Maugham/Views/DetailPaneToggle.swift`
- Modify: `MaughamTests/DetailPaneToggleTasksTests.swift`
- Create: `MaughamTests/Views/DetailPaneTogglePersonaTests.swift`

**Interfaces:**
- Consumes: `Persona.panes`, `Persona.coerce(_:)` (Task 2).
- Produces: `DetailPaneToggle(persona:…)`; `DetailPaneToggle.badgeOffsetSegments(persona:) -> Int?`.

This task also fixes a latent bug. The inbox unread badge is positioned by a hardcoded two-segment-width offset that assumes inbox is third-from-last — an assumption that has already silently broken once. Under personas the picker length varies, so the offset must be computed.

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/Views/DetailPaneTogglePersonaTests.swift`:

```swift
import XCTest
@testable import Maugham

final class DetailPaneTogglePersonaTests: XCTestCase {
    func test_badgeOffset_isComputedFromTheInboxPositionInThisPersona() {
        // Plan offers [research, outline, palette, inbox, inspector] —
        // inbox is second from the end, so the badge shifts by 1 segment.
        XCTAssertEqual(DetailPaneToggle.badgeOffsetSegments(persona: .plan), 1)
    }

    func test_badgeOffset_isNilWhereThePersonaHasNoInbox() {
        for persona in Persona.allCases where persona != .plan {
            XCTAssertNil(DetailPaneToggle.badgeOffsetSegments(persona: persona),
                         "\(persona) has no inbox segment to badge")
        }
    }

    func test_visibleSegments_matchTheRegistry() {
        XCTAssertEqual(DetailPaneToggle.visibleSegments(persona: .author, hideOutline: false),
                       Persona.author.panes)
    }

    func test_visibleSegments_dropOutlineWhenHidden() {
        let segments = DetailPaneToggle.visibleSegments(persona: .author, hideOutline: true)
        XCTAssertFalse(segments.contains(.outline))
        XCTAssertEqual(segments.count, Persona.author.panes.count - 1)
    }

    func test_visibleSegments_areNeverEmpty() {
        for persona in Persona.allCases {
            for hideOutline in [true, false] {
                XCTAssertFalse(
                    DetailPaneToggle.visibleSegments(persona: persona, hideOutline: hideOutline).isEmpty,
                    "\(persona) hideOutline=\(hideOutline) produced an empty picker")
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/DetailPaneTogglePersonaTests`
Expected: FAIL — "type 'DetailPaneToggle' has no member 'badgeOffsetSegments'"

- [ ] **Step 3: Add the pure helpers**

In `Maugham/Views/DetailPaneToggle.swift`, add a `persona` property beside the existing `hideOutline` (line 10) and to the `init` (line 40), then add:

```swift
    /// The segments this picker shows, in order. Ordering comes from the
    /// persona registry, not from `DetailSegment.allCases` — so adding a case
    /// to the enum does not silently change any picker.
    static func visibleSegments(persona: Persona, hideOutline: Bool) -> [DetailSegment] {
        persona.panes.filter { !(hideOutline && $0 == .outline) }
    }

    /// How many segment-widths to shift the inbox unread badge left from the
    /// trailing edge, or nil when this persona has no inbox.
    ///
    /// SwiftUI's segmented Picker cannot badge a segment directly, so the
    /// badge is overlaid top-trailing and shifted. This was previously the
    /// hardcoded literal 2 ("inbox is third-to-last"), which silently moved
    /// the badge onto the wrong tab when translation was added. Under personas
    /// the picker length varies, so it must be derived.
    static func badgeOffsetSegments(persona: Persona, hideOutline: Bool = false) -> Int? {
        let segments = visibleSegments(persona: persona, hideOutline: hideOutline)
        guard let index = segments.firstIndex(of: .inbox) else { return nil }
        return segments.count - 1 - index
    }
```

- [ ] **Step 4: Drive the picker from the registry**

Replace the hand-written `Picker` body (lines 103–138) with:

```swift
        Picker("Right pane", selection: $segment) {
            ForEach(Self.visibleSegments(persona: persona, hideOutline: hideOutline), id: \.self) { seg in
                Image(systemName: seg.systemImageName)
                    .tag(seg)
                    .help(seg.helpText)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
```

Add the two presentation properties to `Maugham/Models/DetailSegment.swift` as an extension, so icon and help text live beside the case rather than in the picker:

```swift
public extension DetailSegment {
    var systemImageName: String {
        switch self {
        case .inspector: return "info.circle"
        case .annotations: return "text.bubble"
        case .research: return "doc.text.magnifyingglass"
        case .outline: return "list.bullet.indent"
        case .history: return "clock.arrow.circlepath"
        case .tasks: return "checklist.checked"
        case .inbox: return "tray"
        case .palette: return "paintpalette"
        case .translation: return "character.book.closed"
        }
    }

    var helpText: String {
        switch self {
        case .inspector: return "Inspector — document metadata, tags, links (⌘⌥I)"
        case .annotations: return "Annotations — review Claude's comments and suggested edits (⌘⌥A)"
        case .research: return "Research — this document's own and linked research (⌘⌥R)"
        case .outline: return "Outline — table or corkboard structure view (⌘⌥O)"
        case .history: return "History — read-only timeline of edits, annotations, and checkpoints (⌘⌥H)"
        case .tasks: return "Tasks — todos in this document and across the project (⌘⌥T)"
        case .inbox: return "Inbox — triage captures from MaughamPhone (⌘⌥B)"
        case .palette: return "Palette Card (⌘⌥P)"
        case .translation: return "Translation — source text and translator queries (⌘⌥L)"
        }
    }
}
```

- [ ] **Step 5: Fix the badge offset**

Replace the hardcoded `segmentCount` and two-segment shift (lines 143–156) with the derived value:

```swift
        .overlay(alignment: .topTrailing) {
            if inboxCount > 0,
               let shift = Self.badgeOffsetSegments(persona: persona, hideOutline: hideOutline) {
                GeometryReader { geo in
                    let segments = Self.visibleSegments(persona: persona, hideOutline: hideOutline).count
                    let segmentWidth = geo.size.width / CGFloat(max(segments, 1))
                    InboxBadge(count: inboxCount)
                        .offset(x: -CGFloat(shift) * segmentWidth)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                }
            }
        }
```

Read the existing overlay at `DetailPaneToggle.swift:141–160` first and keep its badge view verbatim — only `segmentCount` and the `.offset(x:)` arithmetic change. The current code hardcodes `let segmentCount = hideOutline ? 8 : 9` and shifts by exactly two segment widths; both become derived.

- [ ] **Step 6: Replace the outline coercion with registry coercion**

Replace the `.onAppear` block (lines 83–88) with:

```swift
        .onAppear {
            let visible = Self.visibleSegments(persona: persona, hideOutline: hideOutline)
            if !visible.contains(segment) {
                segment = visible.first ?? persona.defaultPane
            }
        }
        .onChange(of: persona) { _, newPersona in
            let visible = Self.visibleSegments(persona: newPersona, hideOutline: hideOutline)
            if !visible.contains(segment) {
                segment = visible.first ?? newPersona.defaultPane
            }
        }
```

- [ ] **Step 7: Update the call site**

In `ProjectWindow.inspectorPane` (lines 885–900), pass `persona: persona` to `DetailPaneToggle`.

- [ ] **Step 8: Retire the ordering assertions**

`MaughamTests/DetailPaneToggleTasksTests.swift:18–20` asserts `allCases.last == .translation`, `order[count-2] == .palette`, `order[count-3] == .inbox`. Those existed only to protect the hardcoded badge offset, which Step 5 removed. Delete the three assertions and replace with:

```swift
    func test_badgeOffsetIsDerivedNotPositional() {
        // Replaces the former allCases-ordering assertions. The badge offset
        // used to depend on inbox being third-to-last in DetailSegment.allCases;
        // it is now computed from the persona's own pane list, so enum ordering
        // is free to change. See DetailPaneTogglePersonaTests.
        XCTAssertEqual(DetailPaneToggle.badgeOffsetSegments(persona: .plan), 1)
    }
```

- [ ] **Step 9: Full suite + Release build**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO
```
Expected: both succeed.

- [ ] **Step 10: Commit**

```bash
git add Maugham/Views/DetailPaneToggle.swift Maugham/Models/DetailSegment.swift \
        Maugham/Views/ProjectWindow.swift MaughamTests/Views/DetailPaneTogglePersonaTests.swift \
        MaughamTests/DetailPaneToggleTasksTests.swift
git commit -m "feat: persona-filtered right pane, derived inbox badge offset"
```

---

## Task 7: Persona-aware left and centre columns

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift` (`binderColumn`, `contentColumn`)
- Modify: `Maugham/Views/BinderPaneToggle.swift`
- Modify: `Maugham/Views/CollectionBinderPaneToggle.swift`
- Create: `MaughamTests/PersonaBinderSegmentTests.swift`

**Interfaces:**
- Consumes: `Persona` (Task 1), `BinderSegment` (existing).
- Produces: `Persona.binderSegments(for: ProjectType) -> [BinderSegment]`, `Persona.binderHome(for: ProjectType) -> BinderSegment`.

Scope note: Plan and Publish do not get new *centre* surfaces here — the canvas is M1C and editions are M1D. What changes is which binder segments each persona offers, so entering Plan lands you in research rather than the manuscript.

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/PersonaBinderSegmentTests.swift`:

```swift
import XCTest
@testable import Maugham

final class PersonaBinderSegmentTests: XCTestCase {
    func test_planPersona_leadsWithResearch() {
        XCTAssertEqual(Persona.plan.binderHome(for: .novel), .research)
    }

    func test_authorPersona_leadsWithTheDocumentHome() {
        XCTAssertEqual(Persona.author.binderHome(for: .novel), .manuscript)
        XCTAssertEqual(Persona.author.binderHome(for: .screenplay), .scenes,
                       "screenplay binders have no Manuscript segment")
    }

    func test_reviewPersona_leadsWithTheDocumentHome() {
        XCTAssertEqual(Persona.review.binderHome(for: .screenplay), .scenes)
    }

    func test_everyPersonaBinderHome_isAmongItsOwnSegments() {
        for persona in Persona.allCases {
            for type in ProjectType.allCases where type != .unknown {
                let segments = persona.binderSegments(for: type)
                XCTAssertTrue(segments.contains(persona.binderHome(for: type)),
                              "\(persona)/\(type) home is not in its segment list")
            }
        }
    }

    func test_screenplayPersonasNeverOfferManuscript() {
        // documentHome(for:)'s doc comment records the 2026-07-02 smoke bug:
        // forcing .manuscript on a screenplay drops into a one-row BinderView.
        for persona in Persona.allCases {
            XCTAssertFalse(persona.binderSegments(for: .screenplay).contains(.manuscript),
                           "\(persona) offers Manuscript on a screenplay")
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PersonaBinderSegmentTests`
Expected: FAIL — "value of type 'Persona' has no member 'binderHome'"

- [ ] **Step 3: Write the implementation**

Append to `Maugham/Models/Persona.swift`:

```swift
// MARK: - Left column

public extension Persona {
    /// Binder segments this persona offers, in picker order. `.trash` and
    /// `.find` stay conditional on their existing runtime predicates and are
    /// appended by the toggles, not listed here.
    func binderSegments(for projectType: ProjectType) -> [BinderSegment] {
        let home = BinderSegment.documentHome(for: projectType)
        switch self {
        case .plan:
            return [.research, .palette, home]
        case .author:
            return [home, .research, .palette]
        case .review:
            return [home, .research]
        case .publish:
            return [home, .research]
        }
    }

    /// Where this persona lands when entered. Always routed through
    /// `BinderSegment.documentHome(for:)` for manuscript-shaped segments —
    /// re-deriving the screenplay check inline shipped a real bug.
    func binderHome(for projectType: ProjectType) -> BinderSegment {
        binderSegments(for: projectType).first ?? BinderSegment.documentHome(for: projectType)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/PersonaBinderSegmentTests`
Expected: PASS, 5 tests

- [ ] **Step 5: Wire the binder toggles**

Add a `persona: Persona` property to both `BinderPaneToggle` and `CollectionBinderPaneToggle` and pass it from `ProjectWindow.binderColumn` (lines 633–654).

In `BinderPaneToggle`, replace the hand-written picker (lines 16–31) with:

```swift
    /// Segments this picker shows: the persona's own list, plus the two
    /// conditional ones. Trash and Find are runtime-gated and persona-
    /// independent — a writer mid-search keeps the Find segment in every mode.
    static func visibleSegments(persona: Persona,
                                projectType: ProjectType,
                                hasTrash: Bool,
                                findActive: Bool) -> [BinderSegment] {
        var segments = persona.binderSegments(for: projectType)
        if hasTrash { segments.append(.trash) }
        if findActive { segments.append(.find) }
        return segments
    }

    private var segmentPicker: some View {
        Picker("Binder", selection: $segment) {
            ForEach(Self.visibleSegments(persona: persona,
                                         projectType: projectType,
                                         hasTrash: !store.trashEntries.isEmpty,
                                         findActive: findActive), id: \.self) { seg in
                Text(seg.displayName(for: projectType)).tag(seg)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
```

Add the label helper to `Maugham/Models/BinderSegment.swift`, so the collection binder's "Pieces" relabelling lives beside the case rather than being duplicated in two toggles:

```swift
public extension BinderSegment {
    /// A collection's manuscript segment is labelled "Pieces"; every other
    /// project type calls it "Manuscript".
    func displayName(for projectType: ProjectType) -> String {
        switch self {
        case .manuscript: return projectType == .collection ? "Pieces" : "Manuscript"
        case .research: return "Research"
        case .palette: return "Palette"
        case .scenes: return "Scenes"
        case .trash: return "Trash"
        case .find: return "Find"
        }
    }
}
```

Apply the same `segmentPicker` replacement to `CollectionBinderPaneToggle` (lines 21–31), which now differs from `BinderPaneToggle` only in its `switch segment` body.

Leave both files' existing `.onChange` coercion guards (`BinderPaneToggle:68–77`, `CollectionBinderPaneToggle:74–83`) exactly as they are — they handle trash-emptied and find-closed, which is orthogonal to persona.

- [ ] **Step 6: Coerce the binder segment on persona change**

Extend `PersonaModifier.applyPersonaChange` to carry the binder segment too. Replace the `Change` struct and function with:

```swift
    struct Change: Equatable {
        let persona: Persona
        let segment: DetailSegment
        let binderSegment: BinderSegment
    }

    static func applyPersonaChange(to persona: Persona,
                                   currentSegment: DetailSegment,
                                   currentBinderSegment: BinderSegment,
                                   projectType: ProjectType) -> Change {
        let allowed = persona.binderSegments(for: projectType)
        // .trash and .find are transient and persona-independent — a writer
        // mid-search should not be yanked out of it by switching persona.
        let keepBinder = allowed.contains(currentBinderSegment)
            || currentBinderSegment == .trash
            || currentBinderSegment == .find
        return Change(persona: persona,
                      segment: persona.coerce(currentSegment),
                      binderSegment: keepBinder ? currentBinderSegment
                                                : persona.binderHome(for: projectType))
    }
```

Update both call sites (the modifier body in `PersonaModifier`, and the `onSelectPersona` closure passed to `TopChromeModifier` at `ProjectWindow.swift:159`) to pass `binderSegment` and `store.manifest.type`, and to assign `binderSegment = change.binderSegment`.

**This is a source-breaking signature change.** The three tests written in Task 4 call the two-argument `applyPersonaChange(to:currentSegment:)` and will not compile. Update them to the new signature — the expectations are unchanged:

```swift
    func test_applyPersonaChange_coercesASegmentTheDestinationLacks() {
        let result = PersonaModifier.applyPersonaChange(
            to: .author, currentSegment: .annotations,
            currentBinderSegment: .manuscript, projectType: .novel)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, Persona.author.defaultPane)
    }

    func test_applyPersonaChange_keepsASegmentTheDestinationOffers() {
        let result = PersonaModifier.applyPersonaChange(
            to: .review, currentSegment: .outline,
            currentBinderSegment: .manuscript, projectType: .novel)
        XCTAssertEqual(result.segment, .outline, "Outline exists in Review; don't disturb it")
    }

    func test_applyPersonaChange_toTheSamePersona_isIdentity() {
        let result = PersonaModifier.applyPersonaChange(
            to: .author, currentSegment: .tasks,
            currentBinderSegment: .manuscript, projectType: .novel)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, .tasks)
    }
```

Then add the two new binder-coercion tests:

```swift
    func test_applyPersonaChange_movesBinderHomeWhenTheSegmentIsUnavailable() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, currentSegment: .inspector,
            currentBinderSegment: .manuscript, projectType: .novel)
        XCTAssertEqual(result.binderSegment, .research)
    }

    func test_applyPersonaChange_preservesAnActiveFind() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, currentSegment: .inspector,
            currentBinderSegment: .find, projectType: .novel)
        XCTAssertEqual(result.binderSegment, .find, "switching persona must not cancel a search")
    }
```

- [ ] **Step 7: Full suite + Release build**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO
```
Expected: both succeed. `BinderSegmentDocumentHomeTests` must still pass untouched — `documentHome(for:)` keeps its meaning.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Models/Persona.swift Maugham/Views/ProjectWindow.swift \
        Maugham/Views/BinderPaneToggle.swift Maugham/Views/CollectionBinderPaneToggle.swift \
        MaughamTests/PersonaBinderSegmentTests.swift MaughamTests/PersonaModifierTests.swift
git commit -m "feat: persona-aware binder segments with find-preserving coercion"
```

---

## Task 8: Documentation and the ADR

**Files:**
- Create: `docs/adr/0025-persona-shell.md`
- Modify: `docs/guide/right-pane.md`
- Modify: `Maugham/Views/AREA.md`
- Modify: `CLAUDE.md`
- Modify: `docs/roadmap.md`
- Modify: `Maugham/Resources/Samples/novel/manuscript/02-try-it.md`

CLAUDE.md's Default Workflow item 10 requires sibling-doc sweeps in the same commit as the change that falsifies them.

- [ ] **Step 1: Write the ADR**

Create `docs/adr/0025-persona-shell.md` covering: the four personas as optional lenses (not gates, resolving the tension with constitution must #2, "imposes no method"); the pane registry as the extension point; the keyspace migration and why the flat numeric space was retired; per-window persona with per-project persistence and the honest limitation; and that ADR 0005 (right-pane mode-swap) is **amended, not superseded** — the mode-swap pattern survives, it is now scoped by persona.

- [ ] **Step 2: Update the guide**

`docs/guide/right-pane.md` must mention every `DetailSegment` case name — `DocSyncTests:174–186` enforces this. Add a section explaining that panes are grouped by persona and which persona each belongs to.

- [ ] **Step 3: Sweep the false claims**

- `Maugham/Views/AREA.md` — add `PersonaBar` and `PersonaModifier` to the extracted-ViewModifier roster; note that `TopChromeModifier` now owns the persona bar.
- `CLAUDE.md:110` — "Right-pane mode-swap (⌘⌥1/2/3) is the established pattern (ADR 0005)" is now false. Rewrite to name the persona registry and cite ADR 0025.
- `docs/roadmap.md` — add the milestone under Group 1.
- `Maugham/Resources/Samples/novel/manuscript/02-try-it.md` — shipped sample content referencing the old shortcuts.

- [ ] **Step 4: Verify the doc gates**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/DocSyncTests -only-testing:MaughamTests/GuideDocsDriftTests -only-testing:MaughamTests/GuideMarkdownViewTests`
Expected: PASS.

- [ ] **Step 5: Final full run, both schemes**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO
```

The phone should be entirely unaffected — this plan touches no `MaughamCore` or `MaughamPhone` source. If a phone test fails, something leaked into the shared package and needs backing out.

- [ ] **Step 6: Commit**

```bash
git add docs/adr/0025-persona-shell.md docs/guide/right-pane.md Maugham/Views/AREA.md \
        CLAUDE.md docs/roadmap.md Maugham/Resources/Samples/novel/manuscript/02-try-it.md
git commit -m "docs: ADR 0025 persona shell, guide and sibling-doc sweep"
```

---

## Smoke test (manual, by the writer)

Automated tests cannot see any of this — there is no UI automation in the repo, and every seam bug in this project's history was found by hand.

1. Launch, open an existing project. It opens in **Author**, laid out exactly as before.
2. `⌘1` → Plan. Binder shows Research; right pane offers Research / Outline / Palette / Inbox / Inspector.
3. `⌘3` → Review. Right pane leads with Annotations. `⌘⌥A` still works.
4. `⌘2` → Author. Annotations is gone from the picker; the pane fell back rather than blanking.
5. `⌘⌥H`, `⌘⌥T`, `⌘⌥P` with the inspector column **closed** — each should open the column and select the pane. This is the asymmetry Task 3 fixed; on `main` these silently do nothing.
6. `⌘\` focus mode — the persona bar disappears with the titlebar. `⌘\` again — it returns.
7. Open a **second window** on a different project, switch it to Plan. The first window stays in Author.
8. Quit and relaunch. Each project reopens in its last persona.
9. Open a **screenplay**. No persona offers a Manuscript binder segment; Plan lands on Research, Author on Scenes.
10. With unread phone captures pending, enter Plan and confirm the badge sits on the **Inbox** tab, not a neighbour.
11. `⌘F`, search, then `⌘1` — the search survives the persona change.

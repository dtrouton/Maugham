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
        // The menu items post via a shared `postSegment(_:)` helper
        // (one spelling of the payload so they can't drift apart), so the
        // literal `"segment": "<rawValue>"` string only exists once, inside
        // that helper — the per-segment guard here checks the call site
        // instead: `postSegment(.<rawValue>)`.
        //
        // **`.research`/`.outline`/`.palette` are the re-pointed three**
        // (shell-finish stage-3a Task 5): their menu items still carry their
        // old letters, but no longer dispatch through `postSegment` — the
        // segment is retiring under them (Task 6 deletes the cases outright)
        // while the tree/altitude surfaces the keys now reach have taken
        // over. Each gets its own dedicated event instead.
        let app = try source("Maugham/MaughamApp.swift")
        let repointed: [DetailSegment: String] = [
            .research: "maughamRevealResearchSection",
            .outline: "maughamSelectProjectRow",
            .palette: "maughamRevealPaletteSection",
        ]
        for segment in DetailSegment.allCases {
            if let event = repointed[segment] {
                XCTAssertTrue(app.contains("MaughamEvent.post(.\(event), to: .keyWindow)"),
                              "no View-menu item posts the re-pointed event for \(segment.rawValue)")
            } else {
                XCTAssertTrue(app.contains("postSegment(.\(segment.rawValue))"),
                              "no View-menu item posts \(segment.rawValue)")
            }
        }
    }

    /// **⌘⌥P is Author's only route to the palette**, as of task 6b of the
    /// persona shell's slice 2 (§6.1): the binder's Palette segment is Plan's
    /// now, and `PalettePane` on the right is what a drafting writer consults.
    ///
    /// Re-pointed by shell-finish stage-3a Task 5 to open the tree's own
    /// Palette section instead — `test_everyDetailSegmentHasAMenuShortcut`
    /// above proves a menu item posts the new event, and `DocSyncTests` proves
    /// every ⌘⌥ token in this file appears in `reference.md`'s table — but
    /// neither pairs the letter with the event, so a swap between two items
    /// would satisfy both. This asserts the pairing for the one item that is
    /// now a persona's sole route. Read as "the first `.keyboardShortcut` after
    /// the item that posts the event", rather than a whitespace-exact literal —
    /// indentation is not what this is guarding.
    func test_thePaletteMenuItemIsTheOneBoundToCommandOptionP() throws {
        let app = try source("Maugham/MaughamApp.swift")
        let item = try XCTUnwrap(
            app.range(of: "MaughamEvent.post(.maughamRevealPaletteSection, to: .keyWindow)"),
            "no View-menu item posts .maughamRevealPaletteSection")
        let after = app[item.upperBound...]
        let shortcut = try XCTUnwrap(after.range(of: ".keyboardShortcut("),
                                     "the Palette item carries no shortcut at all")
        XCTAssertTrue(
            after[shortcut.lowerBound...].hasPrefix(
                #".keyboardShortcut("p", modifiers: [.command, .option])"#),
            "the Palette item's own shortcut must be ⌘⌥P — found "
            + String(after[shortcut.lowerBound...].prefix(60)))

        // The control: the same read on a different item must NOT answer ⌘⌥P,
        // or "the next shortcut in the file" would be reporting a constant.
        let other = try XCTUnwrap(app.range(of: "postSegment(.inbox)"))
        let afterOther = app[other.upperBound...]
        let otherShortcut = try XCTUnwrap(afterOther.range(of: ".keyboardShortcut("))
        XCTAssertFalse(
            afterOther[otherShortcut.lowerBound...].hasPrefix(
                #".keyboardShortcut("p", modifiers: [.command, .option])"#),
            "control: Inbox must not also read as ⌘⌥P")
    }

    func test_reviewModeAndInspectorToggleMovedOffTheirOldKeys() throws {
        let app = try source("Maugham/MaughamApp.swift")
        XCTAssertTrue(app.contains(#"keyboardShortcut("r", modifiers: [.command, .option, .shift])"#),
                      "Toggle Review Mode should be ⌘⌥⇧R, freeing ⌘⌥R for Research")
        XCTAssertTrue(app.contains(#"keyboardShortcut("0", modifiers: [.command, .option])"#),
                      "Toggle Inspector should be ⌘⌥0, freeing ⌘⌥I for the Inspector pane")
    }

    func test_personaShortcutsAreBound() throws {
        let app = try source("Maugham/MaughamApp.swift")
        for persona in Persona.allCases {
            XCTAssertTrue(
                app.contains(#"keyboardShortcut("\#(persona.shortcutKey)", modifiers: .command)"#),
                "⌘\(persona.shortcutKey) is not bound for \(persona.displayName)")
        }
    }

    func test_everyPersonaHasAMenuItem() throws {
        let app = try source("Maugham/MaughamApp.swift")
        for persona in Persona.allCases {
            XCTAssertTrue(app.contains("postPersona(.\(persona.rawValue))"),
                          "no View-menu item posts \(persona.rawValue)")
        }
    }
}

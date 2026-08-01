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
        let app = try source("Maugham/MaughamApp.swift")
        for segment in DetailSegment.allCases {
            XCTAssertTrue(app.contains("postSegment(.\(segment.rawValue))"),
                          "no View-menu item posts \(segment.rawValue)")
        }
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

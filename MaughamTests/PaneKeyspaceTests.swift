import XCTest
@testable import Maugham

/// Source-text guards on the `⌘⌥` pane keys. These read the real files rather
/// than exercising SwiftUI, which this repo has no automation for. (The
/// keyspace suite's persona half — ⌘1–⌘4 bound to the personas — retired with
/// them in shell p1 Task 6; ⌘1/⌘2/⌘3 are the right column's three positions
/// since shell plan 3 Task 9, pinned in `RightColumnMountingTests`.)
final class PaneKeyspaceTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func test_noPaneUsesANumericCommandOptionShortcut() throws {
        // The flat ⌘⌥ numeric space is retired. ⌘⌥0 is the inspector-column
        // toggle (Xcode's key for the same thing) and is the sole exception.
        for path in ["Maugham/MaughamApp.swift", "Maugham/Views/RightColumnControl.swift",
                     "Maugham/Views/RightColumn.swift"] {
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
        for path in ["Maugham/Views/RightColumnControl.swift", "Maugham/Views/RightColumn.swift"] {
            let picker = try source(path)
            XCTAssertFalse(picker.contains("keyboardShortcut("),
                           "\(path) must not declare shortcuts; the View menu owns them")
        }
        // The control: the menu is where they are.
        XCTAssertTrue(try source("Maugham/MaughamApp.swift").contains("keyboardShortcut("),
                      "control: the read can see a shortcut where there is one")
    }

    // `test_everyPositionAndPullUpHasAMenuShortcut` lives in
    // `RightColumnMountingTests` (shell plan 3 Task 9).

    /// **The three re-pointed keys must never regress to their old spelling.**
    /// `.outline`/`.research`/`.palette` are not right-column positions or
    /// pull-ups, so `postSegment(.outline)` etc. cannot even compile — but the
    /// spelling itself is censused rather than left to the type system alone,
    /// and since the pane picker died (shell plan 3 Task 9) no `postSegment(`
    /// survives in the menu at all.
    func test_noPostSegmentSpellingSurvivesForTheThreeRepointedCases() throws {
        let app = try source("Maugham/MaughamApp.swift")
        for dead in ["outline", "research", "palette"] {
            XCTAssertFalse(app.contains("postSegment(.\(dead))"),
                           "postSegment(.\(dead)) survives — Research/Outline/Palette "
                           + "route through their new events, never the old pane")
            for post in ["postPosition", "postPullUp"] {
                XCTAssertFalse(app.contains("\(post)(.\(dead))"),
                               "\(post)(.\(dead)) — Research/Outline/Palette are tree "
                               + "sections and the Book's view, never a right-column position")
            }
        }
        XCTAssertFalse(app.contains("postSegment("), "the pane picker's post is gone from the menu")
    }

    /// Self-check: the assertion above must be able to fail.
    func test_noPostSegmentSpellingCensusFiresOnPlantedOffender() {
        let planted = "Button(\"Outline\") { postSegment(.outline) }"
        for dead in ["outline", "research", "palette"] {
            let hit = planted.contains("postSegment(.\(dead))")
            XCTAssertEqual(hit, dead == "outline",
                           "self-check: the planted offender should be caught only for "
                           + "the spelling it actually contains")
        }
    }

    /// The first `.keyboardShortcut(` after the View-menu item that contains
    /// `item` — read rather than whitespace-matched, since indentation is not
    /// what these guard.
    private func shortcut(after item: String, in app: String) throws -> String {
        let at = try XCTUnwrap(app.range(of: item), "no View-menu item contains \(item)")
        let after = app[at.upperBound...]
        let key = try XCTUnwrap(after.range(of: ".keyboardShortcut("),
                                "the item \(item) carries no shortcut at all")
        return String(after[key.lowerBound...].prefix(60))
    }

    /// **⌘⌥P opens the tree's Palette section** (shell-finish stage-3a Task
    /// 5). `DocSyncTests` proves every ⌘⌥ token in this file appears in
    /// `reference.md`'s table, but does not pair the letter with the event, so
    /// a swap between two items would satisfy it. This asserts the pairing.
    func test_thePaletteMenuItemIsTheOneBoundToCommandOptionP() throws {
        let app = try source("Maugham/MaughamApp.swift")
        XCTAssertTrue(
            try shortcut(after: "MaughamEvent.post(.maughamRevealPaletteSection, to: .keyWindow)",
                         in: app)
                .hasPrefix(#".keyboardShortcut("p", modifiers: [.command, .option])"#),
            "the Palette item's own shortcut must be ⌘⌥P")

        // The control: the same read on a different item must NOT answer ⌘⌥P,
        // or "the next shortcut in the file" would be reporting a constant.
        XCTAssertFalse(
            try shortcut(after: "MaughamEvent.postResolve(.mine)", in: app)
                .hasPrefix(#".keyboardShortcut("p", modifiers: [.command, .option])"#),
            "control: Tasks must not also read as ⌘⌥P")
    }

    /// **⌘⌥B opens the Inbox** — the Inbox is a tree row whose centre is the
    /// inbox (shell p1 Task 3), so the key opens it as a click on that row
    /// would, rather than selecting a right-column pane (the `.inbox` segment
    /// is deleted, shell p1 Task 6).
    func test_theInboxMenuItemIsTheOneBoundToCommandOptionB() throws {
        let app = try source("Maugham/MaughamApp.swift")
        XCTAssertTrue(
            try shortcut(after: "MaughamEvent.post(.maughamOpenInbox, to: .keyWindow)", in: app)
                .hasPrefix(#".keyboardShortcut("b", modifiers: [.command, .option])"#),
            "the Inbox item's own shortcut must be ⌘⌥B")
    }

    func test_reviewModeAndInspectorToggleMovedOffTheirOldKeys() throws {
        let app = try source("Maugham/MaughamApp.swift")
        XCTAssertTrue(app.contains(#"keyboardShortcut("r", modifiers: [.command, .option, .shift])"#),
                      "⌘⌥⇧R is the read-through item's (Toggle Review Mode's old key), freeing ⌘⌥R for Research")
        XCTAssertTrue(app.contains(#"keyboardShortcut("0", modifiers: [.command, .option])"#),
                      "Toggle Inspector should be ⌘⌥0, freeing ⌘⌥I for the Inspector pane")
    }
}

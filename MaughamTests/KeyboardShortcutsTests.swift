import XCTest
@testable import Maugham

final class KeyboardShortcutsTests: XCTestCase {
    func test_all_isNonEmpty() {
        XCTAssertFalse(KeyboardShortcuts.all.isEmpty)
    }

    func test_all_containsBaselineCategories() {
        let names = Set(KeyboardShortcuts.all.map(\.category))
        XCTAssertTrue(names.contains("File"))
        XCTAssertTrue(names.contains("Edit"))
        XCTAssertTrue(names.contains("View"))
        XCTAssertTrue(names.contains("Help"))
    }

    func test_each_category_has_at_least_one_entry() {
        for category in KeyboardShortcuts.all {
            XCTAssertFalse(category.items.isEmpty,
                "category \(category.category) is empty")
        }
    }

    func test_theCanvasKeysAreListed() throws {
        let canvas = try XCTUnwrap(KeyboardShortcuts.all.first { $0.category == "Canvas" })
        let listed = Dictionary(uniqueKeysWithValues: canvas.items.map { ($0.label, $0.shortcut) })
        let expected: [String: String] = [
            "Finish scrap": "↩",
            "New line in scrap": "⇧↩",
            "Finish scrap (Escape)": "⎋",
            "New joined scrap": "⇥",
            "New scrap below": "⌘↩",
            "New scrap / edit selected": "↩",
            "Move selection": "←↑→↓",
            "Rename region": "↩",
            "Canvas from tree (Plan)": "⇥",
            "Back to tree": "⇧⇥",
        ]
        XCTAssertEqual(canvas.items.count, expected.count)
        XCTAssertEqual(listed, expected)
    }
}

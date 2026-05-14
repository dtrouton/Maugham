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
}

import XCTest
@testable import Maugham

final class TrashEntryTests: XCTestCase {
    func test_daysRemaining_freshEntry_is30() {
        let entry = TrashEntry(
            id: "20260512-153045-abc",
            trashedAt: Date(),
            originalRelativePath: "manuscript/foo.md",
            displayTitle: "Foo",
            itemMetadata: Data())
        XCTAssertEqual(entry.daysRemaining, 30)
    }

    func test_daysRemaining_almostExpired_is0orLess() {
        let entry = TrashEntry(
            id: "20260412-153045-abc",
            trashedAt: Date(timeIntervalSinceNow: -29 * 86_400),
            originalRelativePath: "manuscript/foo.md",
            displayTitle: "Foo",
            itemMetadata: Data())
        XCTAssertLessThanOrEqual(entry.daysRemaining, 1)
        XCTAssertGreaterThanOrEqual(entry.daysRemaining, 0)
    }
}

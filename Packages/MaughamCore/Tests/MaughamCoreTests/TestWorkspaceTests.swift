import XCTest
@testable import MaughamCore

final class TestWorkspaceTests: XCTestCase {
    func test_require_throws_forPathOutsideWorkspace() {
        let outside = URL(fileURLWithPath: "/tmp/not-the-workspace/Proj")
        XCTAssertThrowsError(try TestWorkspace.require(outside)) { err in
            guard case TestWorkspaceError.outsideWorkspace = err else {
                return XCTFail("expected outsideWorkspace, got \(err)")
            }
        }
    }

    func test_require_passes_forPathInsideWorkspace() throws {
        let inside = TestWorkspace.root.appendingPathComponent("Smoke")
        XCTAssertNoThrow(try TestWorkspace.require(inside))
    }

    func test_require_rejects_siblingPrefixCollision() {
        // "<root>Evil" shares a string prefix with root but is NOT inside it.
        let sibling = URL(fileURLWithPath: TestWorkspace.root.path + "Evil/Proj")
        XCTAssertThrowsError(try TestWorkspace.require(sibling))
    }
}

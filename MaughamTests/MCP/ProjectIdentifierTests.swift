import XCTest
@testable import Maugham

final class ProjectIdentifierTests: XCTestCase {
    func test_id_isDeterministicForSamePath() {
        let url = URL(fileURLWithPath: "/Users/denver/projects/Novel1")
        XCTAssertEqual(ProjectIdentifier.id(for: url), ProjectIdentifier.id(for: url))
    }

    func test_id_differsForDifferentPaths() {
        let a = URL(fileURLWithPath: "/Users/denver/projects/Novel1")
        let b = URL(fileURLWithPath: "/Users/denver/projects/Novel2")
        XCTAssertNotEqual(ProjectIdentifier.id(for: a), ProjectIdentifier.id(for: b))
    }

    func test_id_hasExpectedPrefix() {
        let url = URL(fileURLWithPath: "/tmp/proj")
        XCTAssertTrue(ProjectIdentifier.id(for: url).hasPrefix("proj_"))
    }

    func test_id_length() {
        let url = URL(fileURLWithPath: "/tmp/proj")
        // "proj_" (5) + 40 hex chars
        XCTAssertEqual(ProjectIdentifier.id(for: url).count, 45)
    }
}

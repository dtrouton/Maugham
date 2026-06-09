import XCTest
import MaughamCore
@testable import Maugham

final class ProjectTypeTests: XCTestCase {
    func test_rawValuesAreStableSnakeCase() {
        XCTAssertEqual(ProjectType.shortStory.rawValue, "short_story")
        XCTAssertEqual(ProjectType.novel.rawValue, "novel")
        XCTAssertEqual(ProjectType.screenplay.rawValue, "screenplay")
        XCTAssertEqual(ProjectType.collection.rawValue, "collection")
    }

    func test_allCasesIsExhaustive() {
        XCTAssertEqual(Set(ProjectType.allCases),
                       [.shortStory, .novel, .screenplay, .collection])
    }

    func test_codableRoundTripsAllCases() throws {
        let original = ProjectType.allCases
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([ProjectType].self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // ADR 0015: an unknown `type` written by a newer Maugham must NOT throw
    // (which would make the whole project.maugham.json undecodable → project
    // unopenable). It degrades to `.unknown`; the schemaVersion gate is the
    // primary defence against genuinely-newer-schema projects.
    func test_decodingUnknownValueDegradesToUnknownNotThrow() throws {
        let data = "\"poem\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(ProjectType.self, from: data), .unknown)
    }

    // `.unknown` is decode-only and excluded from the picker's allCases.
    func test_unknownIsExcludedFromAllCases() {
        XCTAssertFalse(ProjectType.allCases.contains(.unknown))
    }
}

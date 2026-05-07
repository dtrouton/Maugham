import XCTest
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

    func test_decodingUnknownValueThrows() {
        let data = "\"poem\"".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ProjectType.self, from: data))
    }
}

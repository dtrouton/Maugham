import XCTest
@testable import Maugham

final class CollectionLinkFileTests: XCTestCase {
    func test_linkFile_roundTrip() throws {
        let now = Date()
        let file = CollectionLinkFile(
            version: 1,
            title: "The Long One",
            path: "/Users/denver/Documents/Long",
            bookmark: "AAEC",
            linkedAt: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CollectionLinkFile.self, from: data)
        XCTAssertEqual(decoded.title, "The Long One")
        XCTAssertEqual(decoded.path, "/Users/denver/Documents/Long")
        XCTAssertEqual(decoded.bookmark, "AAEC")
        XCTAssertEqual(decoded.version, 1)
    }
}

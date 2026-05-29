import XCTest
import MaughamCore
@testable import Maugham

final class StructureItemCodableTests: XCTestCase {

    func test_v1JSON_withoutTagsOrLinks_decodes() throws {
        // A v1 manifest's structure entry has no tags / links fields.
        let json = """
        {
          "id": "doc-1",
          "title": "Chapter 1",
          "type": "document",
          "path": "manuscript/01-chapter-1.md"
        }
        """
        let item = try JSONDecoder().decode(
            StructureItem.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(item.id, "doc-1")
        XCTAssertNil(item.tags)
        XCTAssertNil(item.links)
    }

    func test_v2JSON_withTagsAndLinks_roundtrips() throws {
        let original = StructureItem(
            id: "doc-1", title: "Chapter 1", type: .document,
            path: "manuscript/01-chapter-1.md",
            tags: ["margaret", "lighthouse"],
            links: ["doc-2", "doc-3"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StructureItem.self, from: data)
        XCTAssertEqual(decoded.tags, ["margaret", "lighthouse"])
        XCTAssertEqual(decoded.links, ["doc-2", "doc-3"])
    }
}

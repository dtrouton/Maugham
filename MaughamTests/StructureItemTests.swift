import XCTest
import MaughamCore
@testable import Maugham

final class StructureItemTests: XCTestCase {
    func test_documentLeaf_decodesAndEncodes() throws {
        let json = """
        {
          "id": "ch-1",
          "title": "Opening",
          "type": "document",
          "path": "manuscript/01-opening.md",
          "synopsis": "Larry returns from the war.",
          "status": "draft",
          "wordTarget": 3000
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(StructureItem.self, from: json)
        XCTAssertEqual(item.id, "ch-1")
        XCTAssertEqual(item.title, "Opening")
        XCTAssertEqual(item.type, .document)
        XCTAssertEqual(item.path, "manuscript/01-opening.md")
        XCTAssertEqual(item.synopsis, "Larry returns from the war.")
        XCTAssertEqual(item.status, "draft")
        XCTAssertEqual(item.wordTarget, 3000)
        XCTAssertNil(item.children)

        let reEncoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(StructureItem.self, from: reEncoded)
        XCTAssertEqual(decoded, item)
    }

    func test_groupWithChildren_decodes() throws {
        let json = """
        {
          "id": "act-1",
          "title": "Act One",
          "type": "group",
          "children": [
            {"id":"ch-1","title":"Opening","type":"document","path":"a.md"}
          ]
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(StructureItem.self, from: json)
        XCTAssertEqual(item.type, .group)
        XCTAssertNil(item.path)
        XCTAssertEqual(item.children?.count, 1)
        XCTAssertEqual(item.children?.first?.id, "ch-1")
    }

    func test_minimalDocument_decodesWithOnlyRequiredFields() throws {
        let json = """
        {"id":"x","title":"X","type":"document","path":"x.md"}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(StructureItem.self, from: json)
        XCTAssertNil(item.synopsis)
        XCTAssertNil(item.status)
        XCTAssertNil(item.wordTarget)
        XCTAssertNil(item.children)
    }
}

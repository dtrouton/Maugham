import XCTest
import MaughamCore
@testable import Maugham

final class ResearchItemTests: XCTestCase {
    func test_assetImage_decodes() throws {
        let json = """
        {
          "id": "larry",
          "title": "Larry Darrell",
          "type": "asset",
          "kind": "image",
          "path": "research/characters/larry-portrait.jpg",
          "caption": "Late 1920s, Paris",
          "tags": ["protagonist"],
          "links": ["ch-1", "ch-7"]
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(ResearchItem.self, from: json)
        XCTAssertEqual(item.id, "larry")
        XCTAssertEqual(item.type, .asset)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.path, "research/characters/larry-portrait.jpg")
        XCTAssertEqual(item.caption, "Late 1920s, Paris")
        XCTAssertEqual(item.tags, ["protagonist"])
        XCTAssertEqual(item.links, ["ch-1", "ch-7"])
    }

    func test_assetLink_decodesWithUrlNotPath() throws {
        let json = """
        {
          "id": "wiki",
          "title": "Razor's Edge wiki",
          "type": "asset",
          "kind": "link",
          "url": "https://example.com"
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(ResearchItem.self, from: json)
        XCTAssertEqual(item.kind, .link)
        XCTAssertEqual(item.url, "https://example.com")
        XCTAssertNil(item.path)
    }

    func test_groupWithChildren_decodes() throws {
        let json = """
        {
          "id": "characters",
          "title": "Characters",
          "type": "group",
          "children": [
            {"id":"a","title":"A","type":"asset","kind":"image","path":"a.jpg"}
          ]
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(ResearchItem.self, from: json)
        XCTAssertEqual(item.type, .group)
        XCTAssertNil(item.kind)
        XCTAssertEqual(item.children?.count, 1)
    }

    func test_allAssetKinds_roundTrip() throws {
        for kind in ResearchItem.AssetKind.allCases {
            let item = ResearchItem(id: "x", title: "X", type: .asset, kind: kind)
            let data = try JSONEncoder().encode(item)
            let decoded = try JSONDecoder().decode(ResearchItem.self, from: data)
            XCTAssertEqual(decoded.kind, kind, "round-trip failed for \(kind)")
        }
    }
}

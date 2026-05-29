import XCTest
import MaughamCore
@testable import Maugham

final class StructureItemPieceFieldsTests: XCTestCase {
    func test_pieceKind_roundTrip() throws {
        let item = StructureItem(
            id: "doc-1", title: "Story A", type: .document,
            pieceKind: .loose)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(StructureItem.self, from: data)
        XCTAssertEqual(decoded.pieceKind, .loose)
    }

    func test_pageTarget_roundTrip() throws {
        let item = StructureItem(
            id: "doc-1", title: "Screenplay A", type: .document,
            pageTarget: 5, pieceKind: .loose)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(StructureItem.self, from: data)
        XCTAssertEqual(decoded.pageTarget, 5)
    }

    func test_linkedProjectFields_roundTrip() throws {
        let bookmark = Data([0x01, 0x02, 0x03])
        let item = StructureItem(
            id: "doc-1", title: "The Long One", type: .document,
            pieceKind: .reference,
            linkedProjectPath: "/Users/x/Projects/Long",
            linkedProjectBookmark: bookmark)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(StructureItem.self, from: data)
        XCTAssertEqual(decoded.linkedProjectPath, "/Users/x/Projects/Long")
        XCTAssertEqual(decoded.linkedProjectBookmark, bookmark)
        XCTAssertEqual(decoded.pieceKind, .reference)
    }

    func test_olderManifest_decodesWithNilDefaults() throws {
        // No piece-kind fields in the JSON — pre-collection-milestone manifest shape.
        let raw = """
        {"id":"doc-1","title":"Ch 1","type":"document","path":"manuscript/c1.md"}
        """
        let item = try JSONDecoder().decode(StructureItem.self, from: Data(raw.utf8))
        XCTAssertNil(item.pieceKind)
        XCTAssertNil(item.pageTarget)
        XCTAssertNil(item.linkedProjectPath)
        XCTAssertNil(item.linkedProjectBookmark)
    }
}

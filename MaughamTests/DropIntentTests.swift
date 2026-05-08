import XCTest
@testable import Maugham

final class DropIntentTests: XCTestCase {

    private func makeDocument(id: String) -> StructureItem {
        StructureItem(id: id, title: "Doc \(id)", type: .document, path: "x")
    }

    private func makeGroup(id: String) -> StructureItem {
        StructureItem(id: id, title: "Group \(id)", type: .group, path: "x", children: [])
    }

    func test_topThirdOnDocument_isInsertAbove() {
        let intent = DropIntent.classify(
            position: .top, target: makeDocument(id: "doc-1"))
        XCTAssertEqual(intent, .insertAbove(targetId: "doc-1"))
    }

    func test_bottomThirdOnDocument_isInsertBelow() {
        let intent = DropIntent.classify(
            position: .bottom, target: makeDocument(id: "doc-1"))
        XCTAssertEqual(intent, .insertBelow(targetId: "doc-1"))
    }

    func test_middleOnDocument_isInsertBelow() {
        // Documents can't have children — middle drop becomes "below".
        let intent = DropIntent.classify(
            position: .middle, target: makeDocument(id: "doc-1"))
        XCTAssertEqual(intent, .insertBelow(targetId: "doc-1"))
    }

    func test_middleOnGroup_isInsertChild() {
        let intent = DropIntent.classify(
            position: .middle, target: makeGroup(id: "grp-1"))
        XCTAssertEqual(intent, .insertChild(parentId: "grp-1"))
    }

    func test_topOnGroup_isInsertAbove() {
        let intent = DropIntent.classify(
            position: .top, target: makeGroup(id: "grp-1"))
        XCTAssertEqual(intent, .insertAbove(targetId: "grp-1"))
    }
}

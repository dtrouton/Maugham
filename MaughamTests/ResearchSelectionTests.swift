import XCTest
import MaughamCore
@testable import Maugham

final class ResearchSelectionTests: XCTestCase {

    private func note(_ id: String) -> ResearchItem {
        ResearchItem(id: id, title: id, type: .asset, kind: .document,
                     path: "research/\(id).md", addedAt: Date())
    }

    func test_previewId_singleSelection() {
        XCTAssertEqual(ResearchSelectionSync.previewId(for: ["a"]), "a")
    }

    func test_previewId_multiOrEmpty_isNil() {
        XCTAssertNil(ResearchSelectionSync.previewId(for: []))
        XCTAssertNil(ResearchSelectionSync.previewId(for: ["a", "b"]))
    }

    func test_orderedSelection_followsManifestTreeOrder() {
        var group = ResearchItem(id: "g", title: "G", type: .group, kind: nil,
                                 path: "research/g", addedAt: Date())
        group.children = [note("b")]
        let research = [note("a"), group, note("c")]
        let ordered = ResearchSelectionSync.orderedSelection(
            ["c", "b", "a"], in: research)
        XCTAssertEqual(ordered, ["a", "b", "c"])
    }

    func test_expandedDragIds() {
        XCTAssertEqual(
            ResearchSelectionSync.expandedDragIds(
                draggedId: "a", selection: ["a", "b"], in: [note("a"), note("b")]),
            ["a", "b"])
        XCTAssertEqual(
            ResearchSelectionSync.expandedDragIds(
                draggedId: "c", selection: ["a", "b"], in: [note("a"), note("b"), note("c")]),
            ["c"],
            "dragging a row outside the selection moves only that row")
    }
}

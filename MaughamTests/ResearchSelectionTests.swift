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

    // MARK: - postRemovalInsertionIndex
    // `moveResearchItems(atIndex:)` removes the batch BEFORE inserting, so
    // the drop index must be computed against the sibling list with the
    // moving ids filtered out. Regression: computing against the pre-removal
    // list made "[A,B,C,D,E], drag {A,B} below D" land as [C,D,E,A,B]
    // instead of [C,D,A,B,E].

    private let abcde = ["a", "b", "c", "d", "e"]

    func test_postRemovalIndex_earlierItemsPastLaterTarget_bottom() {
        // Filtered siblings [c,d,e]; below d → index 2 (→ [C,D,A,B,E]).
        XCTAssertEqual(
            ResearchSelectionSync.postRemovalInsertionIndex(
                targetId: "d", position: .bottom,
                movingIds: ["a", "b"], siblings: abcde.map(note)),
            2)
    }

    func test_postRemovalIndex_earlierItemsPastLaterTarget_top() {
        // Filtered siblings [c,d,e]; above d → index 1 (→ [C,A,B,D,E]).
        XCTAssertEqual(
            ResearchSelectionSync.postRemovalInsertionIndex(
                targetId: "d", position: .top,
                movingIds: ["a", "b"], siblings: abcde.map(note)),
            1)
    }

    func test_postRemovalIndex_laterItemsBeforeEarlierTarget_unaffected() {
        // Moving [d,e] above b: nothing moved precedes the target, so the
        // index matches the naive one. Filtered [a,b,c]; above b → 1.
        XCTAssertEqual(
            ResearchSelectionSync.postRemovalInsertionIndex(
                targetId: "b", position: .top,
                movingIds: ["d", "e"], siblings: abcde.map(note)),
            1)
    }

    func test_postRemovalIndex_middleNonGroup_insertsAfterTarget() {
        XCTAssertEqual(
            ResearchSelectionSync.postRemovalInsertionIndex(
                targetId: "c", position: .middle,
                movingIds: ["a"], siblings: abcde.map(note)),
            2)
    }

    func test_postRemovalIndex_targetInsideBatch_isNil() {
        XCTAssertNil(
            ResearchSelectionSync.postRemovalInsertionIndex(
                targetId: "b", position: .bottom,
                movingIds: ["a", "b"], siblings: abcde.map(note)),
            "dropping onto a row that is itself moving has no anchor")
    }

    func test_postRemovalIndex_targetNotASibling_isNil() {
        XCTAssertNil(
            ResearchSelectionSync.postRemovalInsertionIndex(
                targetId: "zz", position: .bottom,
                movingIds: ["a"], siblings: abcde.map(note)))
    }

    // MARK: - moveTargets

    func test_moveTargets_excludesMovingGroupAndDescendants() throws {
        var outer = ResearchItem(id: "outer", title: "Outer", type: .group,
                                 kind: nil, path: "research/outer", addedAt: Date())
        var inner = ResearchItem(id: "inner", title: "Inner", type: .group,
                                 kind: nil, path: "research/outer/inner", addedAt: Date())
        inner.children = []
        outer.children = [inner]
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [outer])

        let targets = ResearchSelectionSync.moveTargets(
            forIds: ["outer"], manifest: manifest)
        let ids = targets.map(\.id)
        XCTAssertTrue(ids.contains("shared"))
        XCTAssertFalse(ids.contains("group-outer"), "can't move into itself")
        XCTAssertFalse(ids.contains("group-inner"), "can't move into own descendant")
    }

    func test_moveTargets_roleBearing_isEmpty() throws {
        var palette = ResearchItem(id: "pal", title: "Palette", type: .group,
                                   kind: nil, path: "research/palette", addedAt: Date())
        palette.role = .paletteGroup
        let manifest = ProjectManifest(
            type: .collection, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [palette])

        XCTAssertTrue(ResearchSelectionSync.moveTargets(
            forIds: ["pal"], manifest: manifest).isEmpty)
    }
}

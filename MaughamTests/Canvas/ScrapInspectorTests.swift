import XCTest
@testable import Maugham

/// The third arm of the canvas inspector. Which SwiftUI arm renders cannot be
/// asserted (`_ConditionalContent` is branch-invariant), so the decision the
/// view makes is lifted into `artifactState` and pinned here — the same shape
/// `RegionInspector.citeAffordance` uses.
@MainActor
final class ScrapInspectorTests: XCTestCase {

    private let a = CanvasNodeID("a")

    private func model(promoted: String? = nil) -> CanvasModel {
        let m = CanvasModel()
        m.withScene { s in
            s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80,
                                promotedItemID: promoted))
        }
        m.setScrapText("The falls at night\n\nSodium light.", for: a)
        return m
    }

    func test_theSelectedNodeResolvesThroughTheSceneAndNotTheRawId() {
        let m = model()
        XCTAssertNil(m.selectedNode, "no selection")
        m.selection = .node(a)
        XCTAssertEqual(m.selectedNode?.id, a)
        m.withScene { $0.remove(a) }
        XCTAssertNil(m.selectedNode,
                     "a stale id left by an undo answers nil rather than being "
                     + "handed out as a card that no longer exists")
    }

    func test_aRegionSelectionIsNotANodeSelection() {
        let m = model()
        m.selection = .region(CanvasRegionID("r1"))
        XCTAssertNil(m.selectedNode)
    }

    // MARK: - What the pane says

    func test_anUnpromotedCardSaysSoRatherThanShowingNothing() {
        XCTAssertEqual(ScrapInspector.artifactState(promotedItemID: nil, title: nil),
                       .notPromoted)
    }

    func test_aPromotedCardNamesWhatItBecame() {
        XCTAssertEqual(
            ScrapInspector.artifactState(promotedItemID: "res-a", title: "The falls at night"),
            .promoted(itemID: "res-a", title: "The falls at night"))
    }

    /// The dangling mark: the note was deleted after the promotion. The pane has
    /// to say so — silently showing "not promoted" would be a lie the writer
    /// cannot check, and showing a raw id would be one they cannot read.
    func test_aMarkWhoseArtifactIsGoneSaysThatRatherThanPretendingItIsUnpromoted() {
        XCTAssertEqual(ScrapInspector.artifactState(promotedItemID: "res-gone", title: nil),
                       .artifactMissing(itemID: "res-gone"))
    }
}

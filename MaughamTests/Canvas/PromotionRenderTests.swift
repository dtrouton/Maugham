import XCTest
import SwiftUI
@testable import Maugham

/// The promoted mark, drawn. Every assertion is a two-render diff over scenes
/// that differ in exactly one model fact, with a control that must measure
/// zero — the 1C-b raster pattern, because "some pixels changed" proves nothing
/// without one.
@MainActor
final class PromotionRenderTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let r1 = CanvasRegionID("r1")
    private let size = CGSize(width: 800, height: 600)

    private func scene(promotedNode: Bool = false, promotedRegion: Bool = false) -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 100, y: 100),
                            width: 240, cachedHeight: 80,
                            promotedItemID: promotedNode ? "res-a" : nil))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 40, y: 40, width: 500, height: 300),
                                    promotedItemID: promotedRegion ? "res-fog" : nil))
        return s
    }

    func test_theControlMeasuresZeroSoAChangedCountMeansSomething() throws {
        let one = try render(scene: scene(), size: size)
        let two = try render(scene: scene(), size: size)
        XCTAssertEqual(one.differingPixels(from: two,
                                           in: CGRect(origin: .zero, size: size)), 0)
    }

    func test_aPromotedCardIsDrawnDifferentlyFromAnUnpromotedOne() throws {
        let plain = try render(scene: scene(), size: size)
        let marked = try render(scene: scene(promotedNode: true), size: size)
        XCTAssertGreaterThan(
            marked.differingPixels(from: plain, in: CGRect(x: 90, y: 90, width: 40, height: 100)),
            0,
            "a writer must be able to see which cards have produced something")
    }

    /// The mark is on the card's own left edge — not out on the ground, and not
    /// over where the text starts.
    func test_theMarkSitsInsideTheCardAndClearOfItsText() throws {
        let plain = try render(scene: scene(), size: size)
        let marked = try render(scene: scene(promotedNode: true), size: size)
        XCTAssertEqual(
            marked.differingPixels(from: plain,
                                   in: CGRect(x: 60, y: 100, width: 35, height: 80)), 0,
            "nothing changes on the ground to the left of the card")
        XCTAssertEqual(
            marked.differingPixels(from: plain,
                                   in: CGRect(x: 115, y: 100, width: 200, height: 80)), 0,
            "and nothing changes where the writer's words are")
    }

    /// Permanent chrome, not selection chrome: the mark is there whether or not
    /// the card is selected. Selecting an unpromoted card must not produce it,
    /// and deselecting a promoted one must not take it away.
    func test_theMarkIsPermanentChromeAndNotSelectionChrome() throws {
        let box = CGRect(x: 95, y: 95, width: 30, height: 90)
        let unselectedMarked = try render(scene: scene(promotedNode: true), size: size)
        let selectedMarked = try render(scene: scene(promotedNode: true), size: size,
                                        selection: .node(a))
        let selectedPlain = try render(scene: scene(), size: size, selection: .node(a))

        XCTAssertGreaterThan(unselectedMarked.differingPixels(from: try render(scene: scene(),
                                                                              size: size),
                                                              in: box), 0,
                             "drawn with nothing selected at all")
        XCTAssertGreaterThan(selectedMarked.differingPixels(from: selectedPlain, in: box), 0,
                             "and still drawn when the card IS selected")
    }

    func test_aPromotedRegionIsDrawnDifferentlyInItsChromeBar() throws {
        let plain = try render(scene: scene(), size: size)
        let marked = try render(scene: scene(promotedRegion: true), size: size)
        XCTAssertGreaterThan(
            marked.differingPixels(from: plain, in: CGRect(x: 35, y: 35, width: 30, height: 30)),
            0)
    }

    func test_anItemNodeGetsNoMarkBecauseItCannotBePromoted() throws {
        var withItem = CanvasScene()
        withItem.insert(CanvasNode(id: .item("r-9"), kind: .item(.project(id: "r-9")),
                                   origin: CGPoint(x: 100, y: 100), width: 180,
                                   cachedHeight: 120, promotedItemID: "res-nonsense"))
        var withoutMark = CanvasScene()
        withoutMark.insert(CanvasNode(id: .item("r-9"), kind: .item(.project(id: "r-9")),
                                      origin: CGPoint(x: 100, y: 100), width: 180,
                                      cachedHeight: 120))
        XCTAssertEqual(
            try render(scene: withItem, size: size)
                .differingPixels(from: try render(scene: withoutMark, size: size),
                                 in: CGRect(origin: .zero, size: size)), 0,
            "an item already exists as itself; a mark on one is meaningless and a "
            + "hand-edited sidecar can put one there")
    }
}


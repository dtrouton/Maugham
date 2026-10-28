import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// **SwiftUI can call `EditorSurface.makeNSView` a second time with the SAME
/// coordinator** (no `dismantleNSView` between): a `ProjectWindow` opened onto
/// a selected document does it in its first layout pass. The coordinator is
/// then attached to a NEW text view, and `attach(to:)` moves everything bound
/// to the old one — an overlay left on the discarded view draws nowhere the
/// writer can see (the blank table card, 2026-10-28).
@MainActor
final class EditorReattachOverlayTests: XCTestCase {
    override class func setUp() { super.setUp(); FontWarmup.ensure() }

    private static let text = "![Cash](figures/cash.csv){#tbl:cash}\n\nAfter."
    private let card = FigureCardModel(kind: .table, headerRows: [["Year", "Cash"]],
                                       bodyRows: [["2024", "1"]], columnAlignments: [.left, .right])

    /// What a second `makeNSView` builds, minus SwiftUI: a text view in a
    /// scroll view in a window, the same coordinator its delegate.
    private func secondTextView(text: String, coordinator: EditorCoordinator) -> MaughamTextView {
        let tv = MaughamTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        _ = tv.layoutManager
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        sv.documentView = tv
        let window = TestWindow.make(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                                     contentView: sv, present: .unshown)
        addTeardownBlock { @MainActor in window.close() }
        tv.string = text
        tv.delegate = coordinator
        tv.coordinator = coordinator
        return tv
    }

    private func harness() -> EditorIntegrationHarness {
        let harness = EditorIntegrationHarness(
            mode: ProseMode(reservesFigureThumbnails: true), initialText: Self.text, cursorLocation: 0)
        let c = harness.coordinator
        c.figureImageResolver = { _ in .notLocal }
        c.figureCardModel = { [card] _ in card }
        c.answersInsertCommands = true
        c.referenceIndex = { .empty }
        c.attach(to: harness.textView)   // makeNSView, first call
        return harness
    }

    /// The figure and label overlays move, and the card draws on the new view.
    func test_aSecondAttachMovesTheFigureAndLabelOverlays_andTheCardDraws() throws {
        let harness = harness()
        let c = harness.coordinator
        XCTAssertTrue(c.figureThumbnailOverlay?.superview === harness.textView, "premise: installed once")
        XCTAssertTrue(c.referenceLabelOverlay?.superview === harness.textView, "premise: installed once")

        let tv = secondTextView(text: Self.text, coordinator: c)
        c.attach(to: tv)   // makeNSView, second call: no dismantle between

        let overlay = try XCTUnwrap(c.figureThumbnailOverlay)
        XCTAssertTrue(overlay.superview === tv, "the figure overlay is on the text view being edited")
        XCTAssertTrue(overlay.associatedTextView === tv)
        XCTAssertTrue(c.referenceLabelOverlay?.superview === tv, "the label overlay moved too")
        XCTAssertEqual(harness.textView.subviews.count, 0, "nothing is left on the discarded view")
        XCTAssertNil(harness.textView.delegate, "and it no longer calls back")
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        overlay.display()
        XCTAssertEqual(overlay.lastDrawn, [.card(.table)], "the card draws under its line")
    }

    /// Review's mark renderer and rail, and translation review's badges, move too.
    func test_aSecondAttachMovesTheReviewAndTranslationOverlays() throws {
        let harness = harness()
        let c = harness.coordinator
        c.setReviewMode(true)
        XCTAssertTrue(c.setTranslationReview(true))
        c.syncTranslationBadgeOverlay()
        XCTAssertTrue(c.markRenderer?.superview === harness.textView, "premise")
        XCTAssertTrue(c.marginRail?.superview === harness.textView, "premise")
        XCTAssertTrue(c.translationBadgeOverlay?.superview === harness.textView, "premise")

        let tv = secondTextView(text: Self.text, coordinator: c)
        c.attach(to: tv)

        XCTAssertTrue(c.markRenderer?.superview === tv, "the mark renderer moved")
        XCTAssertTrue(c.marginRail?.superview === tv, "the rail moved")
        XCTAssertTrue(c.translationBadgeOverlay?.superview === tv, "the badges moved")
        XCTAssertEqual(harness.textView.subviews.count, 0, "nothing is left on the discarded view")
    }

    /// Attaching the same text view again keeps every overlay in place.
    func test_reattachingTheSameTextViewKeepsItsOverlays() throws {
        let harness = harness()
        let c = harness.coordinator
        let overlay = try XCTUnwrap(c.figureThumbnailOverlay)
        c.attach(to: harness.textView)
        XCTAssertTrue(c.figureThumbnailOverlay === overlay, "the same overlay, not a second one")
        XCTAssertEqual(harness.textView.subviews.filter { $0 is FigureThumbnailOverlay }.count, 1)
    }
}

/// An expanded grid on the replaced text view folds as a teardown does: its
/// panel and dimming leave the old view and the new view gets the overlay.
@MainActor
final class EditorReattachGridTests: FigureGridMountedTestCase {
    func test_aSecondAttachFoldsAnExpandedGridOffTheOldTextView() async throws {
        let m = try await mount()
        let line = location(m, "![Cash](")
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: line))
        let grid = try await opened(m)
        let panel = try XCTUnwrap(grid.panel)
        XCTAssertTrue(panel.superview === m.textView, "premise: the grid is mounted")

        let frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let tv = MaughamTextView(frame: frame)
        _ = tv.layoutManager
        let sv = NSScrollView(frame: frame)
        sv.documentView = tv
        let window = TestWindow.make(contentRect: frame, contentView: sv, present: .unshown)
        addTeardownBlock { @MainActor in window.close() }
        tv.string = m.textView.string
        tv.delegate = m.coordinator
        m.coordinator.attach(to: tv)

        XCTAssertNil(m.coordinator.figureGrid, "the grid folded")
        XCTAssertNil(panel.superview, "its panel left the old view")
        XCTAssertNil(grid.dim.superview, "and its dimming")
        await m.coordinator.figureGridFolding?.value
        XCTAssertTrue(m.coordinator.figureThumbnailOverlay?.superview === tv)
    }
}

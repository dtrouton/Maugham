import XCTest
import AppKit
@testable import Maugham

/// The measurement the publish-department P2 handoff asked for: does the
/// selection toolbar (Comment / Suggest / Query / Translator's note) fit
/// inside the narrowest centre column the writer can drag the editor to
/// (`ProjectWindow.centreColumnFloor`)?
///
/// `SelectionToolbarView` sizes itself to its stack's `fittingSize` at
/// `init(frame:)` (see `SelectionToolbarView.swift`) — the width is a pure
/// frame read, no window or hosting view needed to measure it. A `TestWindow`
/// mount is used nowhere in this suite; if one is ever added here it must go
/// through `TestWindow` (the headless-gate tripwire).
@MainActor
final class SelectionToolbarWidthTests: XCTestCase {

    /// Pin: measured 369pt for the four buttons (Comment / Suggest / Query /
    /// Translator's note) against today's 480pt centre-column floor — no
    /// overhang, ~87pt of headroom before the 24pt margin this assertion
    /// requires runs out. Kept as the pin per the brief: a future button
    /// added to the toolbar, or a floor narrowed below today's, fails this
    /// loudly instead of silently clipping.
    func test_theToolbarFitsInsideTheCentreColumnFloorWithMargin() {
        let toolbar = SelectionToolbarView(frame: .zero)
        let margin: CGFloat = 24
        XCTAssertLessThanOrEqual(
            toolbar.frame.width, ProjectWindow.centreColumnFloor - margin,
            "the toolbar is \(toolbar.frame.width)pt wide against a "
            + "\(ProjectWindow.centreColumnFloor)pt centre-column floor "
            + "(margin \(margin)pt) — it will overhang the narrowest centre "
            + "column the writer can drag the editor to")
    }

    /// Every button the toolbar declares (`Kind.allCases`) is present, enabled
    /// and on screen — the width pin above is meaningless if it passed only
    /// because a button silently failed to lay out.
    func test_everyButtonIsPresentEnabledAndVisible() {
        let toolbar = SelectionToolbarView(frame: .zero)
        var buttons: [NSButton] = []
        collect(NSButton.self, in: toolbar, into: &buttons)

        XCTAssertEqual(buttons.count, SelectionToolbarView.Kind.allCases.count,
                       "expected one button per Kind")
        for button in buttons {
            XCTAssertTrue(button.isEnabled, "\(button.title) is disabled")
            XCTAssertFalse(button.isHidden, "\(button.title) is hidden")
        }

        let titles = Set(buttons.map(\.title))
        for kind in SelectionToolbarView.Kind.allCases {
            XCTAssertTrue(titles.contains(kind.rawValue), "no button drawn for \(kind.rawValue)")
        }
    }
}

import XCTest
import AppKit
import SwiftUI
@testable import Maugham

/// **The toolbar at the window's minimum width, measured** (shell p5 Task
/// 5). The running round's short form is chosen against an estimate
/// (`RunningRound.leadingReserve`); this mounts the window's real toolbar
/// modifier (`ProjectWindow.TopChromeModifier`) over a three-column split at
/// production's floors, at `ProjectWindow.windowFloor`, and reads each item's
/// frame off the laid-out `NSToolbar` synchronously — nothing is pressed or
/// waited on (tripwire 33).
///
/// Every item is drawn at once: read-through's padlock, the running round in
/// the form production picks, the language switch, the view switch and the
/// right column's toggle. In the app the two switches never show together
/// (a piece has no views, the Book has no languages), so this is a superset
/// of the widest real toolbar.
@MainActor
final class ToolbarWidthTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.close() }
        windows.removeAll()
        super.tearDown()
    }

    /// A long round on a long title, in the language with the longest name
    /// the switch is likely to carry.
    private let line = RunningRound.Line(
        text: "Translating \u{00b7} Portuguese (Brazil) \u{00b7} \u{201C}The Long Winter of the "
            + "Harbourmaster\u{2019}s Daughter\u{201D}, reading",
        docId: "doc-a", language: "pt-br", compact: "Portuguese (Brazil) 12/24")
    private let reading = LanguageSwitch.Offer(languages: ["sr", "pt-br"], current: "pt-br",
                                               showsSourceUnder: true)

    private struct Measured {
        let window: NSWindow
        /// Every toolbar item drawing a view, in window coordinates, with
        /// whether the toolbar shows it (not in its overflow menu).
        let items: [(frame: NSRect, visible: Bool)]
    }

    private func mount(width: CGFloat, full: Bool?) -> Measured {
        let isFull = full ?? RunningRound.drawsFull(
            line, windowWidth: width, languageSwitchTitle: LanguageSwitch.title(of: reading.current),
            viewSwitch: true, textWidth: RunningRound.measured)
        let detail = ProjectWindow.effectiveDetailColumnWidth(
            persisted: UIState.defaultDetailColumnWidth, containerWidth: Double(width))
        let view = NavigationSplitView {
            Color.gray.navigationSplitViewColumnWidth(min: ProjectWindow.binderColumnFloor, ideal: 240)
        } content: {
            Color.white.navigationSplitViewColumnWidth(min: ProjectWindow.centreColumnFloor, ideal: 720)
        } detail: {
            Color.clear.frame(width: detail).navigationSplitViewColumnWidth(detail)
        }
        .navigationTitle("The Long Winter")
        .frame(minWidth: ProjectWindow.windowFloor, minHeight: ProjectWindow.windowHeightFloor)
        .modifier(ProjectWindow.TopChromeModifier(
            projectURL: TestTemp.root.appendingPathComponent("Toolbar-\(UUID().uuidString)"),
            store: nil, isNoChromeOn: false,
            readThroughOffer: ReadThroughOffer(docId: "doc-a", isOn: false, isEnabled: true, reason: nil),
            window: nil, showInspector: .constant(true),
            centreViewOffer: .book(.cards), chooseCentreView: { _ in }, goToCentre: { _ in },
            readingOffer: reading, runningRound: line, runningRoundIsFull: isFull,
            openRunningRound: { _ in }))
        // The scene's own environment (`MaughamApp`): the banners read it.
        .environment(BackupCoordinator())
        let window = TestWindow.mount(view, size: CGSize(width: width, height: ProjectWindow.windowHeightFloor),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                                  .fullSizeContentView])
        windows.append(window)
        window.contentView?.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let toolbar = window.toolbar
        let visible = Set((toolbar?.visibleItems ?? []).map(ObjectIdentifier.init))
        let items = (toolbar?.items ?? []).compactMap { item -> (NSRect, Bool)? in
            guard let view = item.view else { return nil }
            return (view.convert(view.bounds, to: nil),
                    visible.contains(ObjectIdentifier(item)) && view.window != nil)
        }
        return Measured(window: window, items: items)
    }

    /// **At the minimum width every item fits**: the padlock, the running
    /// round in its short form, both switches and the right column's toggle
    /// are on the toolbar — none in its overflow — each whole inside the
    /// window, none over another; and the leading chrome ends inside the
    /// estimate the short form is chosen against.
    func test_everyItemFitsAtTheWindowsMinimumWidth() throws {
        let measured = mount(width: ProjectWindow.windowFloor, full: nil)
        let width = measured.window.frame.width
        // The premise, off the window actually got (CI's display is narrower).
        try XCTSkipIf(width > ProjectWindow.windowFloor + 1,
                      "the window opened at \(width)pt, not the \(ProjectWindow.windowFloor)pt floor")
        XCTAssertFalse(RunningRound.drawsFull(
            line, windowWidth: width, languageSwitchTitle: LanguageSwitch.title(of: reading.current),
            viewSwitch: true, textWidth: RunningRound.measured),
                       "premise: at the floor the running round draws its short form")
        // The sidebar's own toggle, then the padlock, the round, the two
        // switches and the right column's toggle.
        XCTAssertEqual(measured.items.count, 6, "\(measured.items)")
        for (index, item) in measured.items.enumerated() {
            XCTAssertTrue(item.visible, "item \(index) is in the overflow: \(measured.items)")
            XCTAssertGreaterThan(item.frame.width, 0, "item \(index)")
            XCTAssertGreaterThanOrEqual(item.frame.minX, -0.5, "item \(index): \(item.frame)")
            XCTAssertLessThanOrEqual(item.frame.maxX, width + 0.5, "item \(index) runs off \(width)pt: \(item.frame)")
        }
        let frames = measured.items.map(\.frame).sorted { $0.minX < $1.minX }
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(a.maxX, b.minX + 0.5, "two items overlap: \(a) and \(b)")
        }
        // The leading chrome — window buttons, the sidebar's toggle and the
        // padlock — ends inside the reserve the short form is chosen against.
        let trailingGroup = frames.filter { $0.minX > width / 2 }
        let leading = frames.filter { $0.minX <= width / 2 }
        XCTAssertEqual(trailingGroup.count, 4, "the round, two switches, the toggle: \(frames)")
        let leadingEnd = try XCTUnwrap(leading.map(\.maxX).max())
        XCTAssertLessThanOrEqual(leadingEnd, RunningRound.leadingReserve,
                                 "the leading chrome ends at \(leadingEnd)pt, past the estimate")
    }

    /// **The control**: the full sentence forced at the same width is what
    /// the short form exists to prevent — the measurement sees an item pushed
    /// into the overflow (or off the window), so a pass above means something.
    func test_theFullSentenceForcedAtTheFloorIsSeenToOverflow() throws {
        let measured = mount(width: ProjectWindow.windowFloor, full: true)
        let width = measured.window.frame.width
        try XCTSkipIf(width > ProjectWindow.windowFloor + 1,
                      "the window opened at \(width)pt, not the \(ProjectWindow.windowFloor)pt floor")
        let lost = measured.items.filter { !$0.visible || $0.frame.maxX > width + 0.5 }
        let frames = measured.items.map(\.frame).sorted { $0.minX < $1.minX }
        let overlaps = zip(frames, frames.dropFirst()).filter { $0.maxX > $1.minX + 0.5 }
        XCTAssertFalse(lost.isEmpty && overlaps.isEmpty && measured.items.count == 6,
                       "the full sentence fit at the floor, so the short-form test proves nothing: \(measured.items)")
    }
}

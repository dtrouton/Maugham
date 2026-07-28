import XCTest
import AppKit
import SwiftUI
@testable import Maugham

/// The command that reaches the sheet. **The delivery path is the subject**:
/// this area has shipped a whole feature nothing could reach (1C-a's ⌘Z, built
/// and twenty-two tests deep, greyed out in the Edit menu), and the lesson from
/// the mode-UX milestone is that anything with a menu item or a key equivalent
/// needs one test that models the real path.
@MainActor
final class PromotionCommandTests: XCTestCase {

    private let a = CanvasNodeID("a")

    // MARK: - Enablement

    func test_theCommandIsOfferedOnlyOnTheCanvasWithSomethingSelected() {
        let model = CanvasModel()
        XCTAssertFalse(CanvasPromotionModifier.isPromotable(binderSegment: .canvas,
                                                            selection: model.selection))
        XCTAssertTrue(CanvasPromotionModifier.isPromotable(binderSegment: .canvas,
                                                           selection: .node(a)))
        XCTAssertFalse(CanvasPromotionModifier.isPromotable(binderSegment: .manuscript,
                                                            selection: .node(a)),
                       "the manuscript editor has no canvas selection to promote")
        XCTAssertFalse(CanvasPromotionModifier.isPromotable(binderSegment: .research,
                                                            selection: .region(CanvasRegionID("r"))))
    }

    func test_everySelectionKindIsPromotable() {
        // A caller census in enum form: adding a `CanvasSelection` case makes
        // this fail to compile rather than silently shipping a fourth primitive
        // the command ignores.
        for selection: CanvasSelection in [.node(a), .region(CanvasRegionID("r")),
                                           .line(CanvasLineID("l"))] {
            XCTAssertTrue(CanvasPromotionModifier.isPromotable(binderSegment: .canvas,
                                                               selection: selection),
                          "\(selection)")
        }
    }

    // MARK: - The real delivery path

    /// A real `NSWindow` that reports itself key.
    ///
    /// **The OS will not grant key status in this test host, and that is
    /// measured rather than assumed.** `MaughamEventLivenessTests` already
    /// records it ("Key-window STATUS is not reliably grantable in a headless
    /// test host"); re-measured 2026-07-28 for this test —
    /// `NSApp.setActivationPolicy(.regular)` + `activate(ignoringOtherApps:)` +
    /// `makeKeyAndOrderFront` + `makeKey`, then three seconds of run loop, and
    /// `NSApp.isActive` was still false and `isKeyWindow` still false while
    /// `canBecomeKey` was true. The host app is never frontmost under
    /// `xcodebuild`.
    ///
    /// So the ONE fact the host cannot supply is substituted, and nothing else
    /// is: this is a real `NSWindow`, `EventReceiverContext.forWindow` reads
    /// `isKeyWindow` off it through the real property, and `shouldDeliver` makes
    /// the real decision. **Do not replace it with a hand-built
    /// `EventReceiverContext`** — that skips `forWindow` and its liveness read,
    /// which are half of what the drop rule is made of.
    private final class KeyStubWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    /// A `.keyWindow` post is delivered to the key window's receivers and to no
    /// others. Driven through REAL `NSWindow`s because the drop rule is about
    /// key status — the v0.24.0 bug was a post made while a dialog held it.
    ///
    /// The `other` window is genuinely not key (nothing is, here), so its arm is
    /// the unsubstituted half: a real window that does not hold key status drops
    /// the command, which is precisely the v0.24.0 shape.
    func test_theCommandReachesTheKeyWindowAndOnlyTheKeyWindow() {
        let key = KeyStubWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        // Test-owned windows. Without this, `close()` over-releases under ARC and
        // takes the whole test process down — measured: the runner reported
        // "Restarting after unexpected exit, crash, or test timeout".
        key.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        key.makeKeyAndOrderFront(nil)
        other.orderFront(nil)
        defer { key.close(); other.close() }
        XCTAssertFalse(other.isKeyWindow, "the control arm must really not be key")

        var keyGot = 0, otherGot = 0
        let token = NotificationCenter.default.addObserver(   // adr-0021-ok: test observer
            forName: .maughamPromoteCanvasSelection, object: nil, queue: nil) { note in
            if MaughamEvent.shouldDeliver(note, to: .forWindow(key, kind: .keyWindow)) {
                keyGot += 1
            }
            if MaughamEvent.shouldDeliver(note, to: .forWindow(other, kind: .keyWindow)) {
                otherGot += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
        XCTAssertEqual(keyGot, 1)
        XCTAssertEqual(otherGot, 0)
    }

    /// The receive half through the PRODUCTION helper rather than through
    /// `shouldDeliver` directly: a SwiftUI view carrying the real
    /// `.onKeyWindowCommand(.maughamPromoteCanvasSelection, window:)` — the same
    /// call `CanvasPromotionModifier.body` makes — hosted in a real window, fires
    /// on the real post, and stays silent for a window that is not key.
    ///
    /// This is the arm that models 1C-a's ⌘Z defect: everything either side of
    /// the receiver can be green while nothing reaches it.
    func test_theProductionReceiverFiresOnTheRealPostAndOnlyForTheKeyWindow() {
        var keyFired = 0, otherFired = 0
        let key = KeyStubWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        key.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer { key.close(); other.close() }

        let keyHost = NSHostingView(rootView: AnyView(
            Color.clear.onKeyWindowCommand(.maughamPromoteCanvasSelection,
                                           window: key) { _ in keyFired += 1 }))
        let otherHost = NSHostingView(rootView: AnyView(
            Color.clear.onKeyWindowCommand(.maughamPromoteCanvasSelection,
                                           window: other) { _ in otherFired += 1 }))
        keyHost.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        otherHost.frame = keyHost.frame
        key.contentView?.addSubview(keyHost)
        other.contentView?.addSubview(otherHost)
        key.makeKeyAndOrderFront(nil)
        other.orderFront(nil)
        // Let SwiftUI mount both hosts so their `.onReceive` subscriptions exist
        // before the post — an unmounted view is subscribed to nothing, and that
        // false negative would look exactly like a broken command.
        pump()

        MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
        pump()

        XCTAssertEqual(keyFired, 1,
                       "the production onKeyWindowCommand receiver must fire for the key window")
        XCTAssertEqual(otherFired, 0,
                       "a window that is not key must receive nothing (the v0.24.0 shape)")
    }

    private func pump() {
        for _ in 0..<20 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// The inspector buttons post the SAME command the menu posts, so a writer
    /// who clicks and a writer who presses ⌘⇧↩ take the same path.
    func test_theInspectorButtonsPostTheSameCommandAsTheMenu() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Canvas
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham/Canvas")
        // Task 6 adds "ScrapInspector.swift" to this list in its own commit —
        // see that task's steps. It is not listed here because a task must end
        // green: a deliberately-red test is indistinguishable from a broken one
        // by the time anybody else looks at it.
        for file in ["RegionInspector.swift", "LineInspector.swift"] {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains(".maughamPromoteCanvasSelection"),
                          "\(file) must reach promotion through the one command. A "
                          + "closure of its own would be a second path that can "
                          + "drift from the keystroke.")
        }
    }

    /// The name must not collide with the collection-piece promotion that
    /// already exists (`MaughamNotifications.swift:126`).
    func test_theCanvasCommandIsNotThePiecePromotionCommand() {
        XCTAssertNotEqual(Notification.Name.maughamPromoteCanvasSelection,
                          Notification.Name.maughamPromotePiece)
    }
}

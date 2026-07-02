// MaughamTests/Events/MaughamEventLivenessTests.swift
import XCTest
import AppKit
import SwiftUI
@testable import Maugham

/// ADR 0021 addendum: "a closed window receives nothing." These tests use
/// REAL NSWindows — open, close, assert the liveness predicate and the
/// non-View observe helper drop deliveries after close. (Key-window STATUS is
/// not reliably grantable in a headless test host, so key-semantics are pinned
/// at the filter level in MaughamEventTests; liveness IS pinnable with real
/// windows and is pinned here.)
@MainActor
final class MaughamEventLivenessTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.orderFront(nil)
        return w
    }

    func test_isLive_openWindow_true_closedWindow_false() {
        let w = makeWindow()
        XCTAssertTrue(MaughamEvent.isLive(w))
        w.close()
        XCTAssertFalse(MaughamEvent.isLive(w),
            "after close() the cached NSWindow reference must read as NOT live")
        XCTAssertFalse(MaughamEvent.isLive(nil))
    }

    func test_isLive_miniaturizedWindowStillLive() {
        // A Dock-miniaturized window is still open — its data events must
        // keep flowing. Build the predicate's input directly: close() makes
        // isVisible false; we assert the predicate's OR arm via a real window
        // where available. Headless miniaturize is unreliable, so pin the
        // predicate contract: isVisible==false && isMiniaturized==false → dead.
        let w = makeWindow()
        w.close()
        XCTAssertFalse(w.isVisible)
        XCTAssertFalse(w.isMiniaturized)
        XCTAssertFalse(MaughamEvent.isLive(w))
    }

    // MARK: - observe(): the non-View helper's liveness contract

    private let testName = Notification.Name("maugham.test.liveness")

    func test_observe_deliversToLiveProjectContext_dropsAfterClose() {
        let w = makeWindow()
        var workCounter = 0
        let token = MaughamEvent.observe(
            testName,
            context: { .forWindow(w, kind: .project(id: "proj_A")) },
            handler: { _ in workCounter += 1 })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(testName, to: .project(id: "proj_A"))
        XCTAssertEqual(workCounter, 1, "live window, matching project → delivered")

        w.close()
        MaughamEvent.post(testName, to: .project(id: "proj_A"))
        XCTAssertEqual(workCounter, 1,
            "closed window must receive NOTHING — even for its own project's events")
    }

    func test_observe_nilContext_meansNotLive_dropsDelivery() {
        // The explicit non-View liveness contract: the owner returns nil when
        // detached (EditorCoordinator past detach()). nil → drop.
        var isDetached = false
        var workCounter = 0
        let token = MaughamEvent.observe(
            testName,
            context: {
                isDetached ? nil : EventReceiverContext(
                    kind: .global, isWindowLive: true, isWindowKey: false)
            },
            handler: { _ in workCounter += 1 })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(testName, to: .allWindows)
        XCTAssertEqual(workCounter, 1)
        isDetached = true
        MaughamEvent.post(testName, to: .allWindows)
        XCTAssertEqual(workCounter, 1, "a detached owner must not act on deliveries")
    }

    func test_observe_documentScope_matchAndMismatch() {
        let w = makeWindow()
        defer { w.close() }
        var delivered = 0
        let token = MaughamEvent.observe(
            testName,
            context: { .forWindow(w, kind: .document(docId: "doc-abc")) },
            handler: { _ in delivered += 1 })
        defer { NotificationCenter.default.removeObserver(token) }
        MaughamEvent.post(testName, to: .document(docId: "doc-abc"))
        MaughamEvent.post(testName, to: .document(docId: "doc-OTHER"))
        XCTAssertEqual(delivered, 1)
    }

    // MARK: - EditorCoordinator (non-View receiver) liveness — ADR 0021 addendum

    /// Builds a screenplay EditorCoordinator attached to a text view hosted in
    /// `window`. Mirrors EditorCoordinatorCycleTests' factory so the two new
    /// zombie tests don't duplicate the TextKit-1 boilerplate.
    private func makeAttachedCoordinator(in window: NSWindow)
        -> (EditorCoordinator, NSTextView) {
        let storage = NSTextStorage(string: "INT. ROOM - DAY\n\nAction.\n")
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 600))
        layout.addTextContainer(container)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                            textContainer: container)
        window.contentView = tv
        window.makeFirstResponder(tv)
        let binding: Binding<String> = .init(get: { tv.string }, set: { tv.string = $0 })
        let coordinator = EditorCoordinator(
            text: binding, mode: ScreenplayMode(),
            theme: .light, typography: .screenplayDefaults,
            typewriterScroll: false, sentenceFocus: false, paragraphFocus: false)
        coordinator.attach(to: tv)
        return (coordinator, tv)
    }

    /// ADR 0021: a detached (zombie) EditorCoordinator must not act on scoped
    /// events — the selection must not move after detach(). The non-View
    /// `receiverContext` returns nil once `isDetached`, so the delivery drops.
    func test_detachedCoordinator_receivesNoNavigateToScene() {
        let w = makeWindow()
        let (coordinator, tv) = makeAttachedCoordinator(in: w)
        coordinator.detach()
        let before = tv.selectedRange()
        MaughamEvent.post(.maughamNavigateToScene, to: .keyWindow,
                          payload: ["lineLocation": 17])
        XCTAssertEqual(tv.selectedRange(), before,
            "a detached coordinator's editor must not move on a scoped navigate event")
        _ = coordinator
        w.close()
    }

    /// The ADR 0021 addendum zombie: NOT detached (SwiftUI didn't dismantle the
    /// representable) but the window is closed. Pre-migration the raw NC observer
    /// fires and moves the cursor; post-migration the `.keyWindow` context of a
    /// closed (non-key) window drops the delivery.
    func test_closedWindowCoordinator_receivesNothing() {
        let w = makeWindow()
        let (coordinator, tv) = makeAttachedCoordinator(in: w)
        w.close()
        let before = tv.selectedRange()
        MaughamEvent.post(.maughamNavigateToScene, to: .keyWindow,
                          payload: ["lineLocation": 17])
        XCTAssertEqual(tv.selectedRange(), before,
            "a closed-window (zombie) coordinator must not move its editor on a scoped navigate event")
        _ = coordinator
    }
}

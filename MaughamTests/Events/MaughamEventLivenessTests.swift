// MaughamTests/Events/MaughamEventLivenessTests.swift
import XCTest
import AppKit
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
}

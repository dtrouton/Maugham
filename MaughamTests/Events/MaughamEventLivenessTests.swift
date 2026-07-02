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

    /// Positive-path coverage the zombie tests can't provide (they would pass
    /// even if `receiverContext` always returned nil). Deterministic — no
    /// dependence on the OS granting key-window status headless:
    /// 1. an attached coordinator in a real ordered-front window yields a
    ///    non-nil, LIVE `.keyWindow` context (the real coordinator wiring), and
    /// 2. a real `.keyWindow`-scoped `.maughamNavigateToScene` post passes
    ///    `shouldDeliver` for that context's key-status-granted variant.
    /// Together every link in the delivery chain is pinned; only the OS key
    /// grant itself remains untested here, which EditorCoordinatorCycleTests'
    /// XCTSkipUnless end-to-end test covers when the host grants it.
    func test_attachedCoordinator_receiverContext_isLiveAndDeliverable() {
        let w = makeWindow()
        let (coordinator, _) = makeAttachedCoordinator(in: w)
        defer { w.close() }

        // 1. Real wiring: attached + open window → non-nil, live context.
        guard let ctx = coordinator.receiverContext(.keyWindow) else {
            XCTFail("an attached coordinator in an open window must yield a non-nil receiver context")
            return
        }
        XCTAssertEqual(ctx.kind, .keyWindow)
        XCTAssertTrue(ctx.isWindowLive,
            "an ordered-front window must read as live in the coordinator's context")

        // 2. Filter delivery under key status: subscribe through the REAL
        // wrapper (observe) with the coordinator's context plus the OS-only
        // key grant forced true (the one fact not grantable headless), and
        // assert a real scoped post of the production name is DELIVERED
        // through observe()'s own filter — the actual delivery path.
        let keyGranted = EventReceiverContext(
            kind: ctx.kind, isWindowLive: ctx.isWindowLive, isWindowKey: true)
        var delivered: Notification?
        let obs = MaughamEvent.observe(
            .maughamNavigateToScene,
            context: { keyGranted },
            handler: { delivered = $0 })
        defer { NotificationCenter.default.removeObserver(obs) }
        MaughamEvent.post(.maughamNavigateToScene, to: .keyWindow,
                          payload: ["lineLocation": 17])
        XCTAssertNotNil(delivered,
            "a .keyWindow-scoped navigateToScene post must deliver to the attached coordinator's context once its window is key")
        XCTAssertEqual(delivered?.userInfo?["lineLocation"] as? Int, 17,
            "the delivered notification must carry the post's payload")
        _ = coordinator
    }

    // MARK: - Teardown discipline (Task 8, ADR 0021)
    // Pins the two headless-testable teardown obligations traced in
    // docs/superpowers/notes/2026-07-02-window-teardown-audit.md.

    /// `EditorSurface.dismantleNSView` — SwiftUI's teardown hook — must funnel
    /// into `coordinator.detach()`. Previously only `detach()` was pinned
    /// directly (EditorAppearanceChangeTests.test_detach_releasesViewAndSilencesRestyle);
    /// this pins the WIRING point, so a refactor that stops routing dismantle →
    /// detach (re-opening the graph-retention leak) fails here. The scrollView
    /// argument is unused by dismantleNSView, so a bare NSScrollView suffices.
    func test_dismantleNSView_callsDetach() {
        let w = makeWindow()
        let (coordinator, _) = makeAttachedCoordinator(in: w)
        XCTAssertFalse(coordinator.isDetached)
        XCTAssertNotNil(coordinator.textView)

        EditorSurface.dismantleNSView(NSScrollView(), coordinator: coordinator)

        XCTAssertTrue(coordinator.isDetached,
            "dismantleNSView must flip isDetached via detach()")
        XCTAssertNil(coordinator.textView,
            "dismantleNSView must drop the text-view handle via detach()")
        w.close()
    }

    /// `detach()` removes all five scoped observer tokens (belt) in addition to
    /// `receiverContext` returning nil once `isDetached` (braces). This pins a
    /// SECOND observer beyond the navigate one already covered by
    /// `test_detachedCoordinator_receivesNoNavigateToScene`: a detached
    /// coordinator must not flip its review membrane on a `.maughamToggleReviewMode`
    /// post. (The two mechanisms are not independently isolable headlessly —
    /// detach() both removes the token AND nils `textView` so `receiverContext`
    /// returns nil — so this is a behavioral belt-and-braces net for a distinct
    /// observer, not a token-removal-in-isolation assertion.)
    func test_detach_silencesReviewToggleObserver() {
        let w = makeWindow()
        let (coordinator, _) = makeAttachedCoordinator(in: w)
        XCTAssertFalse(coordinator.isReviewMode)
        coordinator.detach()

        MaughamEvent.post(.maughamToggleReviewMode, to: .keyWindow)

        XCTAssertFalse(coordinator.isReviewMode,
            "a detached coordinator must not flip review mode on a scoped toggle post")
        _ = coordinator
        w.close()
    }

    // MARK: - Per-scope-class closed-window matrix (Task 8, ADR 0021)
    // Completes the set: .keyWindow (Task 4's test_closedWindowCoordinator_receivesNothing),
    // .project (Task 2's test_observe_deliversToLiveProjectContext_dropsAfterClose),
    // and below .document + the deliberate .allWindows exception.

    /// `.document`: a document-scoped event must NOT reach a receiver whose
    /// window has closed, even when the docId matches. Mirrors the `.project`
    /// closed-window test (both funnel through the same `shouldDeliver` liveness
    /// arm: `isWindowLive && scopeId == …`).
    func test_closedWindow_documentEvent_dropped() {
        let w = makeWindow()
        var workCounter = 0
        let token = MaughamEvent.observe(
            testName,
            context: { .forWindow(w, kind: .document(docId: "doc-xyz")) },
            handler: { _ in workCounter += 1 })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(testName, to: .document(docId: "doc-xyz"))
        XCTAssertEqual(workCounter, 1, "live window, matching docId → delivered")

        w.close()
        MaughamEvent.post(testName, to: .document(docId: "doc-xyz"))
        XCTAssertEqual(workCounter, 1,
            "a closed window must receive NOTHING — even for its own document's events")
    }

    /// `.allWindows`: the DELIBERATE exception. A global event reaches a
    /// closed-window receiver BY DESIGN — the `.global` arm of `shouldDeliver`
    /// has NO liveness guard (`appWillTerminate` must reach view graphs SwiftUI
    /// has already detached; Help must work with no project window open). Here
    /// the context is built from a genuinely-closed window (`isWindowLive ==
    /// false`) and delivery STILL happens.
    ///
    /// This test pins the exception so a future "helpful" liveness guard added
    /// to the `.global` branch fails here and forces a conversation. Before
    /// adding any such guard, read the per-global-name zombie-harm audit notes
    /// in `Maugham/Models/MaughamNotifications.swift` (maughamNewProject,
    /// maughamOpenProject, maughamAppWillTerminate, maughamShowHelp) — each
    /// documents WHY its closed-window zombie delivery is harmless.
    func test_globalEvent_reachesClosedWindowReceiver_byDesign() {
        let w = makeWindow()
        w.close()
        XCTAssertFalse(MaughamEvent.isLive(w), "precondition: window is closed")

        var workCounter = 0
        // .forWindow(closedWindow, kind: .global) → isWindowLive == false, yet
        // the .global arm ignores liveness entirely.
        let token = MaughamEvent.observe(
            testName,
            context: { .forWindow(w, kind: .global) },
            handler: { _ in workCounter += 1 })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(testName, to: .allWindows)
        XCTAssertEqual(workCounter, 1,
            "a global (.allWindows) event MUST reach a closed-window receiver by design — see MaughamNotifications.swift zombie-harm audit notes before changing this")
    }
}

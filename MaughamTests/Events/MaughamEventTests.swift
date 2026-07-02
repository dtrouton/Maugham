// MaughamTests/Events/MaughamEventTests.swift
import XCTest
@testable import Maugham

/// ADR 0021: scope is declared at the post site and enforced by ONE filter.
/// These tests exercise the pure core — post encoding + shouldDeliver — with
/// hand-built contexts (no real windows; liveness with real windows is
/// MaughamEventLivenessTests).
final class MaughamEventTests: XCTestCase {

    private let testName = Notification.Name("maugham.test.event")

    private func capturePost(_ scope: EventScope,
                             object: Any? = nil,
                             payload: [AnyHashable: Any] = [:]) -> Notification {
        var captured: Notification?
        let obs = NotificationCenter.default.addObserver(
            forName: testName, object: nil, queue: nil) { captured = $0 }
        defer { NotificationCenter.default.removeObserver(obs) }
        MaughamEvent.post(testName, to: scope, object: object, payload: payload)
        return captured!
    }

    // MARK: - Post encoding

    func test_post_encodesKeyWindowScope() {
        let note = capturePost(.keyWindow)
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeKindKey] as? String, "key-window")
        XCTAssertNil(note.userInfo?[MaughamEvent.scopeIdKey])
    }

    func test_post_encodesProjectScopeWithId() {
        let note = capturePost(.project(id: "proj_A"))
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeKindKey] as? String, "project")
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeIdKey] as? String, "proj_A")
    }

    func test_post_encodesDocumentScopeWithDocId() {
        let note = capturePost(.document(docId: "doc-abc"))
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeKindKey] as? String, "document")
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeIdKey] as? String, "doc-abc")
    }

    func test_post_preservesObjectAndPayload() {
        let payloadObject = NSObject()
        let note = capturePost(.allWindows, object: payloadObject, payload: ["id": "ch-1"])
        XCTAssertTrue(note.object as? NSObject === payloadObject)
        XCTAssertEqual(note.userInfo?["id"] as? String, "ch-1")
        XCTAssertEqual(note.userInfo?[MaughamEvent.scopeKindKey] as? String, "all-windows")
    }

    func test_projectScope_forURL_usesProjectIdentifier() {
        let url = URL(fileURLWithPath: "/tmp/some-project")
        XCTAssertEqual(EventScope.project(for: url),
                       EventScope.project(id: ProjectIdentifier.id(for: url)))
    }

    // MARK: - shouldDeliver: key-window class

    private func note(_ scope: EventScope, payload: [AnyHashable: Any] = [:]) -> Notification {
        capturePost(scope, payload: payload)
    }

    private func ctx(_ kind: EventReceiverContext.Kind,
                     live: Bool = true, key: Bool = false) -> EventReceiverContext {
        EventReceiverContext(kind: kind, isWindowLive: live, isWindowKey: key)
    }

    func test_keyWindowEvent_deliveredOnlyToKeyWindow() {
        let n = note(.keyWindow)
        XCTAssertTrue(MaughamEvent.shouldDeliver(n, to: ctx(.keyWindow, key: true)))
        XCTAssertFalse(MaughamEvent.shouldDeliver(n, to: ctx(.keyWindow, key: false)),
            "a non-key window must not receive a key-window command (the toggleInspector bug class)")
    }

    /// The toggleInspector regression shape: one event, two windows, exactly
    /// one delivery (ProjectWindow.swift:185 had NO guard — ⌘⌥I toggled BOTH).
    func test_toggleInspector_regression_singleWindowDelivery() {
        var deliveries = 0
        let keyCtx = ctx(.keyWindow, key: true)
        let backgroundCtx = ctx(.keyWindow, key: false)
        let obs = NotificationCenter.default.addObserver(
            forName: .maughamToggleInspector, object: nil, queue: nil) { n in
            if MaughamEvent.shouldDeliver(n, to: keyCtx) { deliveries += 1 }
            if MaughamEvent.shouldDeliver(n, to: backgroundCtx) { deliveries += 1 }
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        MaughamEvent.post(.maughamToggleInspector, to: .keyWindow)
        XCTAssertEqual(deliveries, 1, "⌘⌥I must toggle exactly ONE window's inspector")
    }

    // MARK: - shouldDeliver: document / project classes

    func test_documentEvent_deliveredOnlyToMatchingDocId() {
        let n = note(.document(docId: "doc-abc"))
        XCTAssertTrue(MaughamEvent.shouldDeliver(n, to: ctx(.document(docId: "doc-abc"))))
        XCTAssertFalse(MaughamEvent.shouldDeliver(n, to: ctx(.document(docId: "doc-xyz"))))
    }

    func test_projectEvent_deliveredOnlyToMatchingProjectId() {
        let n = note(.project(id: "proj_A"))
        XCTAssertTrue(MaughamEvent.shouldDeliver(n, to: ctx(.project(id: "proj_A"))))
        XCTAssertFalse(MaughamEvent.shouldDeliver(n, to: ctx(.project(id: "proj_B"))),
            "the script.did.update cross-window defect: a foreign project's event must be dropped")
    }

    // MARK: - shouldDeliver: liveness (closed windows receive NOTHING)

    func test_closedWindow_receivesNoDocumentOrProjectEvents() {
        XCTAssertFalse(MaughamEvent.shouldDeliver(
            note(.document(docId: "doc-abc")),
            to: ctx(.document(docId: "doc-abc"), live: false)),
            "a zombie receiver for the RIGHT doc must still be dropped when its window is closed")
        XCTAssertFalse(MaughamEvent.shouldDeliver(
            note(.project(id: "proj_A")),
            to: ctx(.project(id: "proj_A"), live: false)))
        XCTAssertFalse(MaughamEvent.shouldDeliver(
            note(.keyWindow), to: ctx(.keyWindow, live: false, key: false)))
    }

    /// ADR 0021 spec deviation 1: `.maughamNavigateToDocument` is a DATA event,
    /// not a menu command — a wiki-link click or the separate stats-window scene
    /// must navigate the (live, non-key) project window. The old key-window
    /// receiver guard could never pass while the stats window was key. This is
    /// exactly that broken shape: project-scoped, live, NOT key → must deliver.
    func test_navigateToDocument_projectScoped_deliversToNonKeyProjectWindow() {
        let n = note(.project(id: "proj_A"))
        XCTAssertTrue(
            MaughamEvent.shouldDeliver(
                n, to: ctx(.project(id: "proj_A"), live: true, key: false)),
            "a project-scoped navigate must reach a live, non-key project window")
    }

    func test_globalEvent_deliveredEvenWithoutLiveWindow() {
        // Deliberate: .onGlobalEvent has NO liveness guard (appWillTerminate
        // must reach everything). Per-name zombie-harm audit is in the docs.
        XCTAssertTrue(MaughamEvent.shouldDeliver(
            note(.allWindows), to: ctx(.global, live: false)))
    }

    // MARK: - shouldDeliver: scope-kind mismatch + unscoped posts

    func test_unscopedRawPost_isDropped() {
        var captured: Notification?
        let obs = NotificationCenter.default.addObserver(
            forName: testName, object: nil, queue: nil) { captured = $0 }
        defer { NotificationCenter.default.removeObserver(obs) }
        // adr-0021-ok: deliberately-raw post proving the helper drops legacy/unscoped traffic
        NotificationCenter.default.post(name: testName, object: nil)
        XCTAssertFalse(MaughamEvent.shouldDeliver(captured!, to: ctx(.keyWindow, key: true)),
            "an unscoped post must never be delivered through a scoped helper")
        XCTAssertFalse(MaughamEvent.shouldDeliver(captured!, to: ctx(.global)))
    }

    func test_scopeKindMismatch_isDropped() {
        // Posted .project but subscribed via the key-window helper: wiring bug, drop.
        let n = note(.project(id: "proj_A"))
        XCTAssertFalse(MaughamEvent.shouldDeliver(n, to: ctx(.keyWindow, key: true)))
    }

    func test_payloadMustNotShadowReservedKeys() {
        // Reserved keys are the wrapper's channel; a payload collision is a
        // programmer error. Verify post keeps the SCOPE's value.
        let n = capturePost(.project(id: "real"),
                            payload: ["unrelated": "fine"])
        XCTAssertEqual(n.userInfo?[MaughamEvent.scopeIdKey] as? String, "real")
    }
}

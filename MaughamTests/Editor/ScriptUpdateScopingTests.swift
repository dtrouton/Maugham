import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

/// Channel A (ADR 0017 addendum → ADR 0021): `.maughamScriptDidUpdate` must be
/// scoped to its origin project so an unrelated window flipping to a screenplay
/// piece can't invalidate (and re-lay-out) another window's editor or clobber
/// its scene-navigator payload. The routing now rides the `MaughamEvent`
/// wrapper (`.project(id:)` scope) — the tactical `ScriptUpdateRouting`
/// helper it absorbed is gone. See Editor AREA.md.
@MainActor
final class ScriptUpdateScopingTests: XCTestCase {

    private func makeScript() -> FountainScript {
        FountainTokenizer().parse("INT. ROOM - DAY\n\nAction line.\n")
    }

    /// Capture the exact Notification the wrapper posts for `scope`.
    private func post(_ scope: EventScope, object: Any?) -> Notification {
        var captured: Notification?
        let obs = NotificationCenter.default.addObserver(
            forName: .maughamScriptDidUpdate, object: nil, queue: nil) { captured = $0 }
        defer { NotificationCenter.default.removeObserver(obs) }
        MaughamEvent.post(.maughamScriptDidUpdate, to: scope, object: object)
        return captured!
    }

    private func ctx(_ id: String) -> EventReceiverContext {
        EventReceiverContext(
            kind: .project(id: id), isWindowLive: true, isWindowKey: false)
    }

    // MARK: - Scope filter (the three behaviors, through the wrapper)

    func test_foreignProjectPost_notDelivered() {
        let note = post(.project(id: "proj_B"), object: makeScript())
        XCTAssertFalse(
            MaughamEvent.shouldDeliver(note, to: ctx("proj_A")),
            "a script originating from project B must not be adopted by project A")
    }

    func test_ownProjectPost_delivered() {
        let note = post(.project(id: "proj_A"), object: makeScript())
        XCTAssertTrue(
            MaughamEvent.shouldDeliver(note, to: ctx("proj_A")),
            "a script originating from this window's own project must be delivered")
    }

    func test_unscopedRawPost_notDelivered() {
        var captured: Notification?
        let obs = NotificationCenter.default.addObserver(
            forName: .maughamScriptDidUpdate, object: nil, queue: nil) { captured = $0 }
        defer { NotificationCenter.default.removeObserver(obs) }
        // adr-0021-ok: deliberately-raw legacy post proving the helper drops it
        NotificationCenter.default.post(
            name: .maughamScriptDidUpdate, object: makeScript())
        XCTAssertFalse(
            MaughamEvent.shouldDeliver(captured!, to: ctx("proj_A")),
            "an unscoped post (no origin) must be dropped, not blindly adopted")
    }

    // MARK: - Poster stamps the scope keys

    func test_poster_carriesProjectScopeInUserInfo() {
        let storage = NSTextStorage(string: "INT. ROOM - DAY\n\nAction.\n")
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 600))
        layout.addTextContainer(container)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                            textContainer: container)
        let binding: Binding<String> = .init(
            get: { tv.string }, set: { tv.string = $0 })
        let coordinator = EditorCoordinator(
            text: binding, mode: ScreenplayMode(),
            theme: .light, typography: .screenplayDefaults,
            typewriterScroll: false, sentenceFocus: false, paragraphFocus: false)
        coordinator.scriptOriginProjectId = "proj_origin_under_test"

        var receivedKind: String?
        var receivedId: String?
        let obs = NotificationCenter.default.addObserver(
            forName: .maughamScriptDidUpdate, object: nil, queue: nil) { note in
            receivedKind = note.userInfo?[MaughamEvent.scopeKindKey] as? String
            receivedId = note.userInfo?[MaughamEvent.scopeIdKey] as? String
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        // attach → retokenizeAndStyle posts synchronously (non-debounced).
        coordinator.attach(to: tv)

        XCTAssertEqual(receivedKind, "project",
            "the coordinator must post its script under the .project scope")
        XCTAssertEqual(receivedId, "proj_origin_under_test",
            "the coordinator must stamp its origin project id as the scope id")
    }
}

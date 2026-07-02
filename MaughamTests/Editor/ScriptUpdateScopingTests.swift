import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

/// Fix 1 (Channel A): `.maughamScriptDidUpdate` must be scoped to its origin
/// project so an unrelated window flipping to a screenplay piece can't
/// invalidate (and re-lay-out) another window's editor or clobber its
/// scene-navigator payload. See ADR 0017 addendum + Editor AREA.md.
@MainActor
final class ScriptUpdateScopingTests: XCTestCase {

    private func makeScript() -> FountainScript {
        FountainTokenizer().parse("INT. ROOM - DAY\n\nAction line.\n")
    }

    // MARK: - Receiver filter

    func test_acceptedScript_rejectsForeignProjectOrigin() {
        let note = Notification(
            name: .maughamScriptDidUpdate,
            object: makeScript(),
            userInfo: [ScriptUpdateRouting.projectIdKey: "proj_B"])
        XCTAssertNil(
            ScriptUpdateRouting.acceptedScript(from: note, forProjectId: "proj_A"),
            "a script originating from project B must not be adopted by project A")
    }

    func test_acceptedScript_acceptsOwnProjectOrigin() {
        let note = Notification(
            name: .maughamScriptDidUpdate,
            object: makeScript(),
            userInfo: [ScriptUpdateRouting.projectIdKey: "proj_A"])
        XCTAssertNotNil(
            ScriptUpdateRouting.acceptedScript(from: note, forProjectId: "proj_A"),
            "a script originating from this window's own project must be accepted")
    }

    func test_acceptedScript_rejectsMissingOrigin() {
        let note = Notification(
            name: .maughamScriptDidUpdate,
            object: makeScript(),
            userInfo: nil)
        XCTAssertNil(
            ScriptUpdateRouting.acceptedScript(from: note, forProjectId: "proj_A"),
            "an unscoped post (no origin) must be rejected, not blindly adopted")
    }

    // MARK: - Poster carries origin

    func test_poster_carriesProjectIdInUserInfo() {
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

        var receivedId: String?
        let obs = NotificationCenter.default.addObserver(
            forName: .maughamScriptDidUpdate, object: nil, queue: nil) { note in
            receivedId = note.userInfo?[ScriptUpdateRouting.projectIdKey] as? String
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        // attach → retokenizeAndStyle posts synchronously (non-debounced).
        coordinator.attach(to: tv)

        XCTAssertEqual(receivedId, "proj_origin_under_test",
            "the coordinator must stamp its origin project id onto the post")
    }
}

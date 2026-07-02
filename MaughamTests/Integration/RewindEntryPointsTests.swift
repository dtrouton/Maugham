import XCTest
import MaughamCore
@testable import Maugham

/// Spec §7.6: both Rewind entry points (header button + per-row ↺) must
/// route through the same event → modal. The test asserts the event
/// contract: header posts maughamOpenRewind with no scrub payload (= open at
/// .now), per-row posts with scrub_op_id in the payload.
///
/// Scope is declared at the post site (ADR 0021): both entry points post to
/// `.project(for: projectURL)`, so RewindModifier's `.onProjectEvent` presents
/// the modal only on a live window on that project — multi-window setups don't
/// all open their own modal on a single click. The tests receive through the
/// REAL wrapper (`MaughamEvent.observe`) with a live matching-project context,
/// so the project-scope filter itself is on the asserted path.
///
/// Why this matters: prevents a future commit from giving the per-row
/// button a "convenience" shortcut path that bypasses the modal, OR
/// dropping the project scope so every open ProjectWindow opens its own modal.
@MainActor
final class RewindEntryPointsTests: XCTestCase {

    /// A live receiver context on `projectURL`'s project — the shape a real
    /// ProjectWindow on that project presents to the delivery filter.
    private func projectContext(for projectURL: URL) -> EventReceiverContext {
        EventReceiverContext(
            kind: .project(id: ProjectIdentifier.id(for: projectURL)),
            isWindowLive: true, isWindowKey: false)
    }

    func test_headerNotification_carriesProjectScope() {
        let projectURL = URL(fileURLWithPath: "/tmp/MaughamRewindEntryTest-header")
        var observed: Notification?
        let exp = expectation(description: "header notification")
        let token = MaughamEvent.observe(
            .maughamOpenRewind,
            context: { self.projectContext(for: projectURL) },
            handler: { note in
                observed = note
                exp.fulfill()
            })
        defer { NotificationCenter.default.removeObserver(token) }
        MaughamEvent.post(.maughamOpenRewind, to: .project(for: projectURL))
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(observed?.userInfo?[MaughamEvent.scopeKindKey] as? String, "project")
        XCTAssertEqual(observed?.userInfo?[MaughamEvent.scopeIdKey] as? String,
                       ProjectIdentifier.id(for: projectURL),
                       "Header entry must scope to the originating project")
        XCTAssertNil(observed?.userInfo?["scrub_op_id"],
                     "Header entry must NOT carry a scrub_op_id")
    }

    func test_perRowNotification_carriesProjectScopeAndOpId() {
        let projectURL = URL(fileURLWithPath: "/tmp/MaughamRewindEntryTest-row")
        var observed: Notification?
        let exp = expectation(description: "row notification")
        let token = MaughamEvent.observe(
            .maughamOpenRewind,
            context: { self.projectContext(for: projectURL) },
            handler: { note in
                observed = note
                exp.fulfill()
            })
        defer { NotificationCenter.default.removeObserver(token) }
        MaughamEvent.post(
            .maughamOpenRewind, to: .project(for: projectURL),
            payload: ["scrub_op_id": "01TESTOPID"])
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(observed?.userInfo?[MaughamEvent.scopeIdKey] as? String,
                       ProjectIdentifier.id(for: projectURL))
        XCTAssertEqual(observed?.userInfo?["scrub_op_id"] as? String, "01TESTOPID")
    }
}

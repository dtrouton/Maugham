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
/// all open their own modal on a single click.
///
/// Why this matters: prevents a future commit from giving the per-row
/// button a "convenience" shortcut path that bypasses the modal, OR
/// dropping the project scope so every open ProjectWindow opens its own modal.
final class RewindEntryPointsTests: XCTestCase {
    func test_headerNotification_carriesProjectScope() {
        let projectURL = URL(fileURLWithPath: "/tmp/MaughamRewindEntryTest-header")
        var observed: Notification?
        let exp = expectation(description: "header notification")
        let token = NotificationCenter.default.addObserver(
            forName: .maughamOpenRewind, object: nil, queue: nil
        ) { note in
            observed = note
            exp.fulfill()
        }
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
        let token = NotificationCenter.default.addObserver(
            forName: .maughamOpenRewind, object: nil, queue: nil
        ) { note in
            observed = note
            exp.fulfill()
        }
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

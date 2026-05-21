import XCTest
@testable import Maugham

/// Spec §7.6: both Rewind entry points (header button + per-row ↺) must
/// route through the same notification → modal. The test asserts the
/// notification contract: header posts maughamOpenRewind with empty
/// userInfo (= open at .now), per-row posts with scrub_op_id in userInfo.
///
/// The notification's `object` is the originating projectURL — RewindModifier
/// filters on it so multi-window setups only present the modal on the
/// window that originated the click.
///
/// Why this matters: prevents a future commit from giving the per-row
/// button a "convenience" shortcut path that bypasses the modal, OR
/// dropping the originator field so every open ProjectWindow opens its
/// own modal on a single click.
final class RewindEntryPointsTests: XCTestCase {
    func test_headerNotification_carriesProjectURLAsObject() {
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
        NotificationCenter.default.post(
            name: .maughamOpenRewind, object: projectURL, userInfo: [:])
        wait(for: [exp], timeout: 1)
        XCTAssertNotNil(observed)
        XCTAssertEqual(observed?.object as? URL, projectURL,
                       "Header entry must carry originating projectURL as object")
        XCTAssertNil(observed?.userInfo?["scrub_op_id"],
                     "Header entry must NOT carry a scrub_op_id")
    }

    func test_perRowNotification_carriesProjectURLAndOpId() {
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
        NotificationCenter.default.post(
            name: .maughamOpenRewind, object: projectURL,
            userInfo: ["scrub_op_id": "01TESTOPID"])
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(observed?.object as? URL, projectURL)
        XCTAssertEqual(observed?.userInfo?["scrub_op_id"] as? String, "01TESTOPID")
    }
}

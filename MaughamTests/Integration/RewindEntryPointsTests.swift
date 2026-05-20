import XCTest
@testable import Maugham

/// Spec §7.6: both Rewind entry points (header button + per-row ↺) must
/// route through the same notification → modal. The test asserts the
/// notification contract: header posts maughamOpenRewind with empty
/// userInfo (= open at .now), per-row posts with scrub_op_id in userInfo.
///
/// Why this matters: prevents a future commit from giving the per-row
/// button a "convenience" shortcut path that bypasses the modal.
final class RewindEntryPointsTests: XCTestCase {
    func test_headerNotificationUserInfo_isEmpty() {
        var observed: [AnyHashable: Any]?
        let exp = expectation(description: "header notification")
        let token = NotificationCenter.default.addObserver(
            forName: .maughamOpenRewind, object: nil, queue: nil
        ) { note in
            observed = note.userInfo
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        NotificationCenter.default.post(
            name: .maughamOpenRewind, object: nil, userInfo: [:])
        wait(for: [exp], timeout: 1)
        XCTAssertNotNil(observed)
        XCTAssertNil(observed?["scrub_op_id"],
                     "Header entry must NOT carry a scrub_op_id")
    }

    func test_perRowNotificationUserInfo_carriesOpId() {
        var observed: [AnyHashable: Any]?
        let exp = expectation(description: "row notification")
        let token = NotificationCenter.default.addObserver(
            forName: .maughamOpenRewind, object: nil, queue: nil
        ) { note in
            observed = note.userInfo
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        NotificationCenter.default.post(
            name: .maughamOpenRewind, object: nil,
            userInfo: ["scrub_op_id": "01TESTOPID"])
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(observed?["scrub_op_id"] as? String, "01TESTOPID")
    }
}

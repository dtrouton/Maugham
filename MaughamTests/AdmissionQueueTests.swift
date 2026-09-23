// MaughamTests/AdmissionQueueTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The admission sheet advances to the next stranger** (P3b smoke find F4),
/// decided with no window at all (tripwire 33).
///
/// On the smoke, two strangers were waiting and admitting the first did not
/// bring up the second: the admission's own continuation took down whatever
/// sheet was up by then — the second stranger's, which the settlement had
/// already put up — and the close read as *Not now*.
final class AdmissionQueueTests: XCTestCase {

    private func request(_ fingerprint: String) -> AdmissionRequest {
        AdmissionRequest(
            fingerprint: fingerprint, ownName: "Mac \(fingerprint)",
            code: DeviceCode.short(fingerprint), waitingCount: 1,
            proposedLabel: "Mac \(fingerprint)", knownLabels: [])
    }

    private lazy var sam = request("aaaa1111")
    private lazy var ren = request("bbbb2222")

    /// Two strangers waiting: Sam's sheet is up, Ren is next.
    private func twoWaiting() -> AdmissionQueue {
        var queue = AdmissionQueue()
        queue.rederived([sam, ren])
        XCTAssertEqual(queue.presented, sam, "the head goes up")
        return queue
    }

    // MARK: - Admit brings up the next

    func test_admittingTheFirstBringsUpTheSecond() {
        var queue = twoWaiting()

        queue.admitted(sam.fingerprint)
        XCTAssertNil(queue.presented, "Sam's sheet comes down first")
        let dismissal = queue.sheetClosed()

        XCTAssertFalse(dismissal, "an answered sheet is not a Not now")
        XCTAssertEqual(queue.presented, ren, "and Ren's goes up once it has")
    }

    /// **F4 itself.** The settlement the admission announced re-derives the
    /// queue before the admission's own continuation resumes.
    func test_theSettlementArrivingFirstDoesNotCostTheSecondStrangerTheirSheet() {
        var queue = twoWaiting()

        // The book announces Sam is in: the queue no longer holds her, so her
        // sheet comes down…
        queue.rederived([ren])
        XCTAssertNil(queue.presented, "a sheet whose subject was let in comes down")
        XCTAssertTrue(queue.isClosing)
        // …and nothing goes up while it is still closing, or its close would
        // be read as the writer dismissing Ren.
        queue.rederived([ren])
        XCTAssertNil(queue.presented, "nothing goes up while a sheet is closing")
        // It closes; Ren goes up.
        XCTAssertFalse(queue.sheetClosed())
        XCTAssertEqual(queue.presented, ren)

        // Now the admission resumes. It must take down SAM's sheet, which is
        // not up — never Ren's.
        queue.admitted(sam.fingerprint)
        XCTAssertEqual(queue.presented, ren,
                       "the admission's continuation must not take down the next stranger's sheet")
        XCTAssertFalse(queue.dismissed.contains(ren.fingerprint))
    }

    func test_theContinuationArrivingFirstIsTheOrdinaryOrderAndAlsoAdvances() {
        var queue = twoWaiting()

        queue.admitted(sam.fingerprint)
        queue.rederived([ren])
        XCTAssertNil(queue.presented, "still closing, so the settlement puts nothing up")
        queue.sheetClosed()

        XCTAssertEqual(queue.presented, ren)
        XCTAssertTrue(queue.dismissed.isEmpty)
    }

    // MARK: - Not now

    func test_notNowBringsUpTheNextAndNeverReasksTheOneDeclined() {
        var queue = twoWaiting()

        queue.notNow(sam.fingerprint)
        XCTAssertNil(queue.presented)
        XCTAssertFalse(queue.sheetClosed(),
                       "the press already recorded the Not now; the close is not a second one")
        XCTAssertEqual(queue.presented, ren, "the next stranger comes up")

        // The book re-derives while Ren's sheet is up; Sam is still waiting.
        queue.rederived([sam, ren])
        XCTAssertEqual(queue.presented, ren)
        queue.admitted(ren.fingerprint)
        queue.sheetClosed()

        XCTAssertNil(queue.presented,
                     "Sam was put off for this window, so she is not asked again straight away")
        queue.rederived([sam])
        XCTAssertNil(queue.presented, "not by a later re-derivation either — until the next open")
    }

    func test_escapeIsNotNowAndStillBringsUpTheNext() {
        var queue = twoWaiting()

        // SwiftUI writes nil through the binding, then reports the close.
        queue.presented = nil
        XCTAssertTrue(queue.sheetClosed(), "an unanswered sheet that closed was put off")

        XCTAssertEqual(queue.presented, ren)
        XCTAssertTrue(queue.dismissed.contains(sam.fingerprint))
    }

    func test_theWritersOwnAdmitPressAsksAboutEveryoneAgain() {
        var queue = twoWaiting()
        queue.notNow(sam.fingerprint)
        queue.sheetClosed()
        queue.admitted(ren.fingerprint)
        queue.sheetClosed()

        queue.forgetDismissals()
        queue.rederived([sam])

        XCTAssertEqual(queue.presented, sam)
    }

    /// A close SwiftUI never delivered must not stall the queue for ever: the
    /// writer's own press recovers it.
    func test_aCloseThatNeverReportedIsForgottenByTheWritersPress() {
        var queue = twoWaiting()
        queue.admitted(sam.fingerprint)   // down, and no close ever reported
        queue.rederived([ren])
        XCTAssertNil(queue.presented)

        queue.forgetDismissals()
        queue.rederived([ren])

        XCTAssertEqual(queue.presented, ren)
    }
}

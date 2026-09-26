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

    func test_admittingTheFirstBringsUpTheSecondOnceTheBookHasSettled() {
        var queue = twoWaiting()

        queue.admitted(sam.fingerprint)
        XCTAssertNil(queue.presented, "Sam's sheet comes down first")
        let dismissal = queue.sheetClosed()
        XCTAssertFalse(dismissal, "an answered sheet is not a Not now")
        XCTAssertNil(queue.presented,
                     "nothing goes up from a queue the admission has overtaken")

        queue.rederived([ren])
        XCTAssertEqual(queue.presented, ren, "and Ren's goes up from the settled answer")
    }

    /// **The review's Important 1**: F1's merge-by-default returning through
    /// F4's path. Two new Macs both called "MacBook Air", no such label yet:
    /// both propose it. Sam is admitted AS "MacBook Air"; the continuation
    /// lands first, the sheet closes, and only then the settlement arrives —
    /// with Ren's proposal withdrawn because it is now a merge.
    func test_theNextSheetIsDrawnFromTheSettledQueueNotTheOneTheAdmissionOvertook() {
        func mac(_ fingerprint: String, proposing label: String, sharesWith: String?)
            -> AdmissionRequest
        {
            AdmissionRequest(
                fingerprint: fingerprint, ownName: "MacBook Air",
                code: DeviceCode.short(fingerprint), waitingCount: 1,
                proposedLabel: label,
                knownLabels: sharesWith.map { [$0] } ?? [],
                sharesItsNameWith: sharesWith)
        }
        let samBefore = mac(sam.fingerprint, proposing: "MacBook Air", sharesWith: nil)
        let renBefore = mac(ren.fingerprint, proposing: "MacBook Air", sharesWith: nil)
        let renAfter = mac(ren.fingerprint, proposing: "", sharesWith: "MacBook Air")
        var queue = AdmissionQueue()
        queue.rederived([samBefore, renBefore])

        queue.admitted(sam.fingerprint)   // the continuation
        queue.sheetClosed()               // the close
        XCTAssertNil(queue.presented,
                     "Ren's pre-admission request, pre-filled with a merge, never goes up")

        queue.rederived([renAfter])       // the settlement
        let up = try? XCTUnwrap(queue.presented)
        XCTAssertEqual(up, renAfter)
        XCTAssertEqual(up.map { AdmissionDecision.outcome(for: $0, typedLabel: $0.proposedLabel) },
                       .notNow, "the field starts on nothing, not on a merge")
    }

    /// Review Minor 3: a close SwiftUI never reports must not block every
    /// later sheet until the writer presses Admit… or reopens the book.
    func test_aCloseThatNeverReportsIsGivenUpAfterTwoDerivations() {
        var queue = twoWaiting()
        queue.rederived([ren])          // Sam let in elsewhere: her sheet comes down…
        XCTAssertTrue(queue.isClosing)  // …and its close is never reported.

        queue.rederived([ren])
        XCTAssertNil(queue.presented, "one derivation is still a close in flight")
        queue.rederived([ren])

        XCTAssertEqual(queue.presented, ren, "two is a report that is not coming")
        XCTAssertFalse(queue.dismissed.contains(ren.fingerprint))
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

    /// F2: the stranger up is re-described as their lines arrive, and keeps
    /// the sheet it has.
    func test_aFresherDescriptionOfTheStrangerUpReplacesTheOneShown() {
        var queue = twoWaiting()
        var fresher = sam
        fresher.described = AdmissionWaiting(pieces: [], captures: 2)

        queue.rederived([fresher, ren])

        XCTAssertEqual(queue.presented, fresher)
        XCTAssertEqual(queue.presented?.id, sam.id, "the same sheet, not a new one")
        queue.admitted(sam.fingerprint)
        XCTAssertNil(queue.presented)
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

    // MARK: - F10's late capture (P3c plan 2 Task 8)

    /// **A capture arriving while a sheet is up re-describes it** — the sheet
    /// up keeps its identity and says the newer words; the order is unchanged.
    func test_aLateCaptureRedescribesTheSheetThatIsUp() throws {
        var queue = twoWaiting()
        XCTAssertNil(queue.presented?.described, "premise: nothing described yet")
        let described = try XCTUnwrap(AdmissionWaiting.describe(
            holder: sam.fingerprint, waiting: [:],
            captures: [sam.fingerprint: 1], order: []))

        queue.redescribed { $0.fingerprint == sam.fingerprint ? described : nil }

        XCTAssertEqual(queue.presented?.fingerprint, sam.fingerprint, "the same sheet")
        XCTAssertEqual(queue.presented?.described, described, "saying the newer words")
        XCTAssertEqual(AdmissionSheet.waitingLine(for: try XCTUnwrap(queue.presented)),
                       described.line)
        XCTAssertEqual(queue.queue.map(\.fingerprint), [sam.fingerprint, ren.fingerprint],
                       "who is waiting, and in what order, is not a description's to move")
    }

    /// The other direction: a re-description decides nothing a derivation
    /// decides — a queue an admission has overtaken puts nothing up, and a
    /// dismissal stays a dismissal.
    func test_aRedescriptionPutsNothingUpAndForgetsNoDismissal() {
        var queue = twoWaiting()
        queue.admitted(sam.fingerprint)
        _ = queue.sheetClosed()
        XCTAssertNil(queue.presented, "premise: waiting for the settlement")

        queue.redescribed { _ in nil }
        XCTAssertNil(queue.presented, "a description is not a settlement")
        XCTAssertTrue(queue.awaitingSettlement)

        var dismissed = twoWaiting()
        dismissed.notNow(sam.fingerprint)
        dismissed.redescribed { _ in nil }
        XCTAssertTrue(dismissed.dismissed.contains(sam.fingerprint))
        XCTAssertFalse(dismissed.queue.contains { $0.fingerprint == sam.fingerprint })
    }

    /// **The wiring**: the modifier re-describes on the inbox's own refresh
    /// counter (`InboxPane`'s `.task(id: store.refreshes)` precedent) — no new
    /// event. A source read, because the trigger is a view modifier and
    /// tripwire 33 forbids mounting it to wait on its effect.
    func test_theSheetRedescribesOnTheInboxsOwnRefreshCounter() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Views/AdmissionModifier.swift")
        // Code lines only: a commented-out modifier is not a trigger.
        let code = try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
        XCTAssertTrue(code.contains(
            ".task(id: documentStore?.inboxStore.refreshes) { redescribe() }"),
            "the sheet re-describes when the inbox refreshes")
        XCTAssertTrue(code.contains { $0.hasPrefix("admissions.redescribed") },
                      "through the queue's own re-description")
    }
}

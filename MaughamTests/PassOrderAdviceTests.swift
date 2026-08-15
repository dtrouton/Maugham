import XCTest
import MaughamCore
@testable import Maugham

/// **The advisory nudge** (M3 P2 Task 8) — the one sentence the queue says
/// when a writer is working a late pass over a piece whose earlier passes are
/// still open.
///
/// It is *advice*, and the constitution's "lenses, not gates" is the whole
/// design: there is no dialog, no confirmation and nothing disabled. A writer
/// who wants to proofread a chapter before its structural pass is finished is
/// allowed to, and the only thing Maugham does about it is say so quietly.
///
/// The rule is pure so the truth table is assertable with no window, no store
/// and no project: the earliest pass ordered BEFORE the active one whose state
/// is not final. `.done` and `.skipped` are the only two final states —
/// untouched (absent key, absent dictionary), `.inProgress` and `.unknown` all
/// count as open. `.unknown` counting as open is the `PassState` doc's own
/// precedent: a state written by a newer build reads as untouched to this one,
/// and treating an unreadable state as *finished* would silence the advice on
/// exactly the piece whose state this build cannot vouch for.
final class PassOrderAdviceTests: XCTestCase {

    private let passes = ReviewPass.presets  // structural, line, copyedit, proof

    // MARK: - The nudge fires

    func test_anUntouchedEarlierPassIsTheAdvice() {
        let advice = PassOrderAdvice.openEarlierPass(
            activePassId: "proof", passes: passes, passStates: nil)
        XCTAssertEqual(advice?.id, "structural")
    }

    func test_theEARLIESTOpenPassIsTheAdvice_notTheNearest() {
        // Structural untouched, line done: the advice names structural, the
        // one furthest back, because that is the work most likely to make the
        // proof pass wasted.
        let advice = PassOrderAdvice.openEarlierPass(
            activePassId: "proof", passes: passes,
            passStates: ["line": .done])
        XCTAssertEqual(advice?.id, "structural")
    }

    func test_anInProgressEarlierPassCountsAsOpen() {
        let advice = PassOrderAdvice.openEarlierPass(
            activePassId: "copyedit", passes: passes,
            passStates: ["structural": .done, "line": .inProgress])
        XCTAssertEqual(advice?.id, "line")
    }

    /// The `.unknown`-never-final precedent (`PassState`'s type doc): a state
    /// this build cannot read is not a state this build may call finished.
    func test_anUnknownEarlierPassCountsAsOpen() {
        let advice = PassOrderAdvice.openEarlierPass(
            activePassId: "proof", passes: passes,
            passStates: ["structural": .done,
                         "line": .unknown("re_reading"),
                         "copyedit": .done])
        XCTAssertEqual(advice?.id, "line")
    }

    func test_theAdviceCarriesTheWritersOwnNameForThePass() {
        // A customized list: the caption says what the writer calls it, not a
        // preset label and not the raw id.
        let custom = [ReviewPass(id: "structural", name: "Shape"),
                      ReviewPass(id: "proof", name: "Final read")]
        let advice = PassOrderAdvice.openEarlierPass(
            activePassId: "proof", passes: custom, passStates: nil)
        XCTAssertEqual(advice?.name, "Shape")
    }

    // MARK: - The nudge stays quiet

    func test_theFirstPassHasNothingBeforeIt() {
        XCTAssertNil(PassOrderAdvice.openEarlierPass(
            activePassId: "structural", passes: passes, passStates: nil))
    }

    func test_everyEarlierPassDoneIsNoAdvice() {
        XCTAssertNil(PassOrderAdvice.openEarlierPass(
            activePassId: "proof", passes: passes,
            passStates: ["structural": .done, "line": .done, "copyedit": .done]))
    }

    /// Skipped is a decision, not an omission — a writer who has ruled that a
    /// piece needs no line pass has answered the question the nudge asks.
    func test_aSkippedEarlierPassIsNotAdvisedAbout() {
        XCTAssertNil(PassOrderAdvice.openEarlierPass(
            activePassId: "copyedit", passes: passes,
            passStates: ["structural": .skipped, "line": .skipped]))
    }

    func test_doneAndSkippedMixed_isStillQuiet() {
        XCTAssertNil(PassOrderAdvice.openEarlierPass(
            activePassId: "proof", passes: passes,
            passStates: ["structural": .done, "line": .skipped, "copyedit": .done]))
    }

    /// A pass id that is not in the list has no position, so there is no
    /// "before" to look in. (The queue never asks this — its pass id comes
    /// through `validatedActivePass` — but a retired id reaching here must be
    /// silence rather than an advice about the whole list.)
    func test_anActivePassAbsentFromTheListIsNoAdvice() {
        XCTAssertNil(PassOrderAdvice.openEarlierPass(
            activePassId: "retired", passes: passes, passStates: nil))
    }

    /// Only what is EARLIER matters. A later pass left open is the work still
    /// ahead of the writer, and mentioning it would make the caption fire on
    /// every piece from the first pass onwards.
    func test_aLaterOpenPassIsNeverTheAdvice() {
        XCTAssertNil(PassOrderAdvice.openEarlierPass(
            activePassId: "line", passes: passes,
            passStates: ["structural": .done]))
    }
}

import XCTest
@testable import MaughamCore

/// Truth table for `ReviewStatus.derived` (M3 P1 Task 3) — the single
/// projection that replaces four divergent view-layer switches.
final class ReviewStatusTests: XCTestCase {

    private let passes = ReviewPass.presets  // structural, line, copyedit, proof

    // MARK: - No pass states at all → legacy fallback

    func test_nilPassStates_legacyFinal_mapsToFinal() {
        XCTAssertEqual(
            ReviewStatus.derived(passStates: nil, passes: passes, legacyStatus: "final"),
            .final)
    }

    func test_nilPassStates_legacyRevising_mapsToRevising() {
        XCTAssertEqual(
            ReviewStatus.derived(passStates: nil, passes: passes, legacyStatus: "revising"),
            .revising)
    }

    func test_nilPassStates_legacyNil_mapsToDraft() {
        XCTAssertEqual(
            ReviewStatus.derived(passStates: nil, passes: passes, legacyStatus: nil),
            .draft)
    }

    func test_nilPassStates_legacyDraft_mapsToDraft() {
        XCTAssertEqual(
            ReviewStatus.derived(passStates: nil, passes: passes, legacyStatus: "draft"),
            .draft)
    }

    func test_nilPassStates_legacyGarbage_mapsToDraft() {
        XCTAssertEqual(
            ReviewStatus.derived(passStates: nil, passes: passes, legacyStatus: "wat"),
            .draft)
    }

    func test_emptyPassStatesDict_behavesLikeNil() {
        XCTAssertEqual(
            ReviewStatus.derived(passStates: [:], passes: passes, legacyStatus: "final"),
            .final)
    }

    func test_emptyPassesList_fallsBackToLegacyEvenWithStates() {
        // Nothing to score against — the project has no passes at all —
        // so even non-empty passStates can't be evaluated; legacy wins.
        XCTAssertEqual(
            ReviewStatus.derived(
                passStates: ["structural": .done], passes: [], legacyStatus: "final"),
            .final)
    }

    // MARK: - With pass states: inProgress dominates

    func test_anyInProgress_isRevising() {
        let states: [String: PassState] = [
            "structural": .done, "line": .inProgress, "copyedit": .done, "proof": .done,
        ]
        XCTAssertEqual(ReviewStatus.derived(passStates: states, passes: passes, legacyStatus: nil), .revising)
    }

    func test_onlyInProgress_isRevising() {
        let states: [String: PassState] = ["structural": .inProgress]
        XCTAssertEqual(ReviewStatus.derived(passStates: states, passes: passes, legacyStatus: nil), .revising)
    }

    // MARK: - Nothing touched (states present but none match current passes) → draft

    func test_statesPresentButNoneMatchCurrentPasses_isDraft() {
        let states: [String: PassState] = ["retired-pass-id": .done]
        XCTAssertEqual(ReviewStatus.derived(passStates: states, passes: passes, legacyStatus: "final"), .draft)
    }

    // MARK: - Mix of touched/untouched → revising

    func test_someTouchedSomeUntouched_isRevising() {
        let states: [String: PassState] = ["structural": .done]
        XCTAssertEqual(ReviewStatus.derived(passStates: states, passes: passes, legacyStatus: nil), .revising)
    }

    func test_threeOfFourDoneOneUntouched_isRevising() {
        let states: [String: PassState] = [
            "structural": .done, "line": .done, "copyedit": .done,
        ]
        XCTAssertEqual(ReviewStatus.derived(passStates: states, passes: passes, legacyStatus: nil), .revising)
    }

    // MARK: - Every pass touched, all done/skipped → final

    func test_allDone_isFinal() {
        let states: [String: PassState] = [
            "structural": .done, "line": .done, "copyedit": .done, "proof": .done,
        ]
        XCTAssertEqual(ReviewStatus.derived(passStates: states, passes: passes, legacyStatus: nil), .final)
    }

    /// The spec's recorded edge: skipping every pass is a deliberate
    /// adjudication and reads as finished, not as untouched.
    func test_allSkipped_isFinal() {
        let states: [String: PassState] = [
            "structural": .skipped, "line": .skipped, "copyedit": .skipped, "proof": .skipped,
        ]
        XCTAssertEqual(ReviewStatus.derived(passStates: states, passes: passes, legacyStatus: nil), .final)
    }

    func test_mixOfDoneAndSkipped_isFinal() {
        let states: [String: PassState] = [
            "structural": .done, "line": .skipped, "copyedit": .done, "proof": .skipped,
        ]
        XCTAssertEqual(ReviewStatus.derived(passStates: states, passes: passes, legacyStatus: nil), .final)
    }

    // MARK: - .unknown never silently completes final

    func test_allTouchedButOneUnknown_isNeverFinal() {
        let states: [String: PassState] = [
            "structural": .done, "line": .done, "copyedit": .done, "proof": .unknown("future_state"),
        ]
        let result = ReviewStatus.derived(passStates: states, passes: passes, legacyStatus: nil)
        XCTAssertNotEqual(result, .final)
        XCTAssertEqual(result, .revising)
    }

    func test_unknownPlusUntouched_isRevisingNeverFinal() {
        let states: [String: PassState] = ["structural": .unknown("future_state")]
        let result = ReviewStatus.derived(passStates: states, passes: passes, legacyStatus: nil)
        XCTAssertNotEqual(result, .final)
        XCTAssertEqual(result, .revising)
    }

    func test_allUnknown_isRevisingNeverFinal() {
        let states: [String: PassState] = [
            "structural": .unknown("x"), "line": .unknown("x"),
            "copyedit": .unknown("x"), "proof": .unknown("x"),
        ]
        let result = ReviewStatus.derived(passStates: states, passes: passes, legacyStatus: nil)
        XCTAssertNotEqual(result, .final)
        XCTAssertEqual(result, .revising)
    }

    // MARK: - Custom (non-preset) pass lists

    func test_customPassList_allDoneIsFinal() {
        let custom = [ReviewPass(id: "beta", name: "Beta Read")]
        let states: [String: PassState] = ["beta": .done]
        XCTAssertEqual(ReviewStatus.derived(passStates: states, passes: custom, legacyStatus: nil), .final)
    }

    // MARK: - rawValue stability (StatusSwatch and any future persistence key off this)

    func test_rawValues() {
        XCTAssertEqual(ReviewStatus.draft.rawValue, "draft")
        XCTAssertEqual(ReviewStatus.revising.rawValue, "revising")
        XCTAssertEqual(ReviewStatus.final.rawValue, "final")
    }
}

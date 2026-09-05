import XCTest
@testable import Maugham
import MaughamCore

/// **Which loop asked for a run** (two loops P1 Task 1).
///
/// The mint is a total function over `Persona` and nothing else, so it is
/// assertable without a window, a run or a store — which is the point: the one
/// production site that calls it (`CompilerRunModifier`) is a `ViewModifier`
/// no test can mount, and a census is all that guards the call. What the
/// census cannot check is the ANSWER, and that is what this file is.
final class RunKindTests: XCTestCase {

    /// **Every persona, named individually.** Written over `Persona.allCases`
    /// so a fifth persona fails to compile here rather than quietly defaulting
    /// to `.check` — the `switch` in `RunKind.of(persona:)` is exhaustive, and
    /// this is the assertion that says a new case must be decided rather than
    /// inherited.
    func test_reviewMintsARound_andEveryOtherPersonaMintsACheck() {
        XCTAssertEqual(RunKind.of(persona: .review), .round,
                       "Review's Run round is the round verb")
        XCTAssertEqual(RunKind.of(persona: .author), .check,
                       "Author's \u{2318}R is the check verb")
        XCTAssertEqual(RunKind.of(persona: .plan), .check,
                       "Plan has no run key of its own; a run reaching the "
                       + "orchestrator from it is a check")
        XCTAssertEqual(RunKind.of(persona: .publish), .check,
                       "…and so is one from Publish")

        // The census over the enum: every case is named above. A fifth persona
        // makes this fail rather than letting the four assertions above pass
        // over a case nobody decided.
        XCTAssertEqual(Persona.allCases, [.plan, .author, .review, .publish],
                       "a new persona must be given a RunKind above rather than "
                       + "inheriting .check by omission")
    }

    /// The raw values are a disk format — `CompilerRun.kind` is written into
    /// the per-document sidecar — so a rename reads back as an unrecognised
    /// word on every record already written. Pinned for the reason
    /// `DraftStage`'s and `SynthesisSource`'s are.
    func test_theRawValuesAreTheSidecarsWords() {
        XCTAssertEqual(RunKind.check.rawValue, "check")
        XCTAssertEqual(RunKind.round.rawValue, "round")
        XCTAssertEqual(RunKind(rawValue: "check"), .check)
        XCTAssertEqual(RunKind(rawValue: "round"), .round)
    }

    // MARK: - The legacy rule (whole-branch review, finding 1)

    /// **The coach's lane is the one id where a stored `passId` does not name
    /// the verb.**
    ///
    /// Before this milestone the coach was the default reader of every
    /// unassigned piece, so an Author ⌘R — a wet-ink check by every account
    /// including the spec's §1, which names that fusion as the defect — wrote
    /// `passId: "workshop"` on its record. Reading those back as rounds
    /// empties Author's pane over a piece checked yesterday, resets the delta
    /// marker so the next ⌘R re-reads the whole chapter, and draws
    /// the coach's letter in Review's cockpit as a standing round. So the
    /// inference is: no lane, or the coach's, is a check.
    func test_aLegacyRecordInTheCoachsLaneIsACheck() {
        XCTAssertEqual(makeLegacyRun(passId: ReviewPass.coachPreset.id).effectiveKind, .check,
                       "a run filed in the coach's lane was an Author keystroke")
        XCTAssertEqual(makeLegacyRun(passId: nil).effectiveKind, .check,
                       "and so was one filed in no lane at all")
    }

    /// The other half, unchanged: a stage lane is a rung on the ladder, and a
    /// run filed in one was a numbered round.
    func test_aLegacyRecordInAStageLaneIsARound() {
        XCTAssertEqual(makeLegacyRun(passId: "line").effectiveKind, .round)
    }

    /// **A record that says what it is is never inferred about.** The
    /// inference exists for records written before `kind` did; a declared kind
    /// wins over any lane, including the coach's.
    func test_aDeclaredKindOutranksTheInference() {
        var declared = makeLegacyRun(passId: ReviewPass.coachPreset.id)
        declared.kind = .round
        XCTAssertEqual(declared.effectiveKind, .round,
                       "the record declared a round; nothing infers over that")

        var check = makeLegacyRun(passId: "line")
        check.kind = .check
        XCTAssertEqual(check.effectiveKind, .check)
    }

    /// A record of the shape written before `kind` existed: no `kind`, a lane
    /// or no lane, and nothing else this pin depends on.
    private func makeLegacyRun(passId: String?) -> CompilerRun {
        CompilerRun(
            id: "01JRUN", at: Date(timeIntervalSince1970: 1_780_000_000),
            model: "sonnet", lastOpId: "op1", deltaSummary: "1 new, 0 revised",
            intentSnapshot: nil, passId: passId, round: passId == nil ? nil : 1)
    }
}

import XCTest
@testable import Maugham
import MaughamCore

/// **Which loop asked for a run** (two loops P1 Task 1; shell p1 Task 5).
///
/// The kind is the COMMAND's (`RunCommand`), a total function over four
/// cases and nothing else, so it is assertable without a window, a run or a
/// store. Which piece a command reads, and the receiver's arms, are
/// `CompilerRunCommandTests`' and `WiringCensusTests`' to pin.
final class RunKindTests: XCTestCase {

    /// **Every command, named individually**: two checks, two rounds, and the
    /// cold read of each. Written out rather than derived, so a change to one
    /// arm of `RunCommand`'s switches is a red line here.
    func test_eachCommandNamesItsKindAndOnlyTheColdReadsAreFresh() {
        XCTAssertEqual(RunCommand.checkWriting.kind, .check)
        XCTAssertFalse(RunCommand.checkWriting.isFreshEyes)
        XCTAssertEqual(RunCommand.reread.kind, .check)
        XCTAssertTrue(RunCommand.reread.isFreshEyes)
        XCTAssertEqual(RunCommand.runRound.kind, .round)
        XCTAssertFalse(RunCommand.runRound.isFreshEyes)
        XCTAssertEqual(RunCommand.freshEyes.kind, .round)
        XCTAssertTrue(RunCommand.freshEyes.isFreshEyes)
        XCTAssertEqual(RunCommand.allCases, [.checkWriting, .reread, .runRound, .freshEyes],
                       "a fifth command must be decided above rather than inherited")
    }

    /// The File menu's fixed titles, and one event per command — four
    /// promises, four events, none shared.
    func test_theTitlesAreFixedAndEachCommandPostsItsOwnEvent() {
        XCTAssertEqual(RunCommand.allCases.map(\.title),
                       ["Check Writing", "Reread", "Run Round", "Fresh Eyes"])
        XCTAssertEqual(Set(RunCommand.allCases.map(\.event)).count, RunCommand.allCases.count)
        XCTAssertEqual(RunCommand.checkWriting.event, .maughamRunCompiler)
        XCTAssertEqual(RunCommand.reread.event, .maughamFreshEyesCompiler)
        XCTAssertEqual(RunCommand.runRound.event, .maughamRunRound)
        XCTAssertEqual(RunCommand.freshEyes.event, .maughamFreshEyesRound)
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

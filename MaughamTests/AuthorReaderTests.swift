import XCTest
import MaughamCore
@testable import Maugham

/// **Who reads a CHECK** (two loops P1, spec §2).
///
/// `ProjectManifest.authorReader` is the only place Author's ⌘R decides who
/// is reading, and the rule is one sentence: the coach while her seat is
/// held, nobody once it is vacated. The pass a piece sits in on the review
/// board is not an input — that is `RoundEditor`'s question, and asking it
/// here is the defect this split exists to end.
///
/// The round loop's own resolution is pinned by `RoundEditorTests`; what a
/// check actually STAMPS is pinned in `CompilerRunCommandTests`
/// (`test_aCheckUnderTheCoachStampsNoLaneAndNoRoundAndIsSignedByHer`).
final class AuthorReaderTests: XCTestCase {

    // MARK: - Fixtures

    private func manifest(
        passes: [ReviewPass] = [], coachVacated: Bool = false
    ) -> ProjectManifest {
        ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [], reviewPasses: passes,
            coachVacated: coachVacated)
    }

    // MARK: - The two arms

    /// The default this milestone keeps: a writer who never opens Review is
    /// read by the coach.
    func test_aHeldSeatIsTheCoachs() {
        XCTAssertEqual(manifest().authorReader, .coach(ReviewPass.coachPreset))
    }

    /// Vacating the seat is the one off switch: the check goes back to the
    /// all-altitudes reader M2 shipped.
    func test_aVacatedSeatIsNobodys() {
        XCTAssertEqual(manifest(coachVacated: true).authorReader, .nobody)
    }

    /// **The falsifier for the whole split.** A piece parked in Gould's lane
    /// on the review board is STILL the coach's to check — the stage is the
    /// round loop's fact, and a check that read it would sign Author's notes
    /// with an editor the writer never asked for and file them in a lane they
    /// were not standing in. This is the control `PieceReader` would fail: it
    /// answered `.stage(Gould)` for exactly this project.
    func test_aStageRecordedForThePieceDoesNotChangeWhoChecksIt() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "ch-1", passId: "copyedit")
        let m = manifest()

        XCTAssertEqual(m.authorReader, .coach(ReviewPass.coachPreset),
                       "the check loop must not read the board's lane")
        XCTAssertEqual(m.roundEditor(forPiece: "ch-1", memory: memory)?.id, "copyedit",
                       "control: the stage really is recorded \u{2014} the round "
                       + "loop finds it, and only the round loop")
    }

    /// The resolution is per PROJECT: there is no piece in the signature, and
    /// nothing about a piece can change the answer.
    func test_theResolutionIsPerProjectAndNotPerPiece() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "ch-1", passId: "line")
        let m = manifest()

        XCTAssertEqual(m.authorReader, .coach(ReviewPass.coachPreset))
        XCTAssertEqual(m.roundEditor(forPiece: "ch-5", memory: memory), nil,
                       "control: the pieces really do differ for the round loop")
    }

    // MARK: - What each arm answers

    /// The coach travels to the run as an `ActivePass` like any pass: her id,
    /// her effective fields, and `isCoach` — which is what
    /// `CompilerPrompt.passSection` reads to frame her as a teacher.
    func test_theCoachsActivePassCarriesHerEffectiveFieldsAndIsCoach() throws {
        let pass = try XCTUnwrap(manifest().authorReader.activePass,
                                 "the coach must produce an ActivePass")
        XCTAssertEqual(pass.id, "workshop")
        XCTAssertEqual(pass.name, "Workshop")
        XCTAssertEqual(pass.editorName, "Le Guin")
        XCTAssertEqual(pass.brief, ReviewPass.coachPreset.effectiveBrief,
                       "her doctrine must travel through effectiveBrief")
        XCTAssertTrue(pass.isCoach,
                      "nothing downstream can phrase her as a teacher without this")
    }

    /// **The nobody arm, and the one surviving use of the passless name.**
    /// No `ActivePass` at all is what the orchestrator reads as the M2 lane:
    /// no round number, no stamp, notes signed "Claude".
    func test_nobodyHasNoActivePassAndSignsWithThePasslessName() {
        let reader = manifest(coachVacated: true).authorReader
        XCTAssertNil(reader.activePass,
                     "nobody must be the nil frame \u{2014} an ActivePass here "
                     + "would brief a reader that does not exist")
        XCTAssertEqual(reader.editorName, CompilerOrchestrator.passlessEditorName)
        XCTAssertEqual(reader.editorName, "Claude",
                       "control: the constant really is M2's identity")
    }

    /// `editorName` is the byline the Author header and the note's author
    /// both read. The held arm answers the coach's own editor, never the
    /// passless constant.
    func test_editorNameIsTheCoachsForTheHeldArm() {
        XCTAssertEqual(manifest().authorReader.editorName, "Le Guin")
    }
}

import XCTest
import MaughamCore
@testable import Maugham

/// **Who reads this piece — the one resolution** (editorial letter P1 spec
/// §4.1, "The resolution has one spelling").
///
/// `ProjectManifest.reader(forPiece:memory:)` is the only place *stage /
/// coach / nobody* is decided. Everything that names a reader — the
/// orchestrator's `activePass` closure, the Author header, the round lines,
/// the annotation author stamp — asks it rather than re-deriving the rule,
/// which is what keeps the header, the promise and the result from naming
/// three different people.
///
/// The rule under test, in one sentence: a stored active-pass id that still
/// names a stage wins; otherwise the coach, if the writer has not vacated her
/// seat; otherwise nobody.
final class PieceReaderTests: XCTestCase {

    // MARK: - Fixtures

    private func manifest(
        passes: [ReviewPass] = [], coachVacated: Bool = false
    ) -> ProjectManifest {
        ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [], reviewPasses: passes,
            coachVacated: coachVacated)
    }

    private func memory(_ piece: String, _ passId: String) -> ActivePassMemory {
        var memory = ActivePassMemory.empty
        memory.record(piece: piece, passId: passId)
        return memory
    }

    // MARK: - The three arms

    /// A piece the writer put in a lane is that lane's, exactly as before the
    /// coach existed.
    func test_aStoredIdThatStillNamesAStageResolvesToThatStage() {
        let reader = manifest().reader(
            forPiece: "ch-1", memory: memory("ch-1", "copyedit"))
        XCTAssertEqual(reader, .stage(ReviewPass.presets[2]),
                       "a recorded stage is the piece's reader; got \(reader)")
    }

    /// **The default this milestone is about.** A piece nobody has assigned —
    /// which is every piece of a writer who never opens Review — is the
    /// coach's.
    func test_anUnassignedPieceWithTheSeatHeldIsTheCoachs() {
        let reader = manifest().reader(forPiece: "ch-1", memory: .empty)
        XCTAssertEqual(reader, .coach(ReviewPass.coachPreset),
                       "an unassigned piece must fall to the held seat; got \(reader)")
    }

    /// Vacating the seat is the one off switch: the piece goes back to the
    /// all-altitudes reader M2 shipped.
    func test_anUnassignedPieceWithTheSeatVacatedIsNobodys() {
        let reader = manifest(coachVacated: true).reader(
            forPiece: "ch-1", memory: .empty)
        XCTAssertEqual(reader, .nobody,
                       "a vacated seat must resolve to nobody; got \(reader)")
    }

    /// **Deleting a pass gives its pieces back to Le Guin** (spec §4.1, stated
    /// there so it is not a surprise). A stored id that no longer names a
    /// stage already reads as unassigned through `validatedActivePass`, and an
    /// unassigned piece is the coach's — so the piece is coached, not handed
    /// to "Claude".
    func test_aRetiredIdFallsToTheCoachRatherThanToNobody() {
        let customized = [ReviewPass(id: "vibes", name: "Vibes")]
        let reader = manifest(passes: customized).reader(
            forPiece: "ch-1", memory: memory("ch-1", "copyedit"))
        XCTAssertEqual(reader, .coach(ReviewPass.coachPreset),
                       "a retired pass id must fall to the coach; got \(reader)")
    }

    /// The same retired id with the seat vacated has nowhere left to fall.
    func test_aRetiredIdWithTheSeatVacatedIsNobodys() {
        let customized = [ReviewPass(id: "vibes", name: "Vibes")]
        let reader = manifest(passes: customized, coachVacated: true).reader(
            forPiece: "ch-1", memory: memory("ch-1", "copyedit"))
        XCTAssertEqual(reader, .nobody,
                       "retired id plus vacated seat leaves nobody; got \(reader)")
    }

    /// The memory is per piece, so one assignment says nothing about the
    /// piece beside it — the frontier is coached while the finished chapter is
    /// edited (spec §4.1, "What this means in Author").
    func test_theResolutionIsPerPiece() {
        let recorded = memory("ch-1", "line")
        let m = manifest()
        XCTAssertEqual(m.reader(forPiece: "ch-1", memory: recorded),
                       .stage(ReviewPass.presets[1]))
        XCTAssertEqual(m.reader(forPiece: "ch-5", memory: recorded),
                       .coach(ReviewPass.coachPreset),
                       "the piece next door is still unassigned and still hers")
    }

    /// A customized ladder that still contains the stored id resolves to the
    /// writer's OWN pass object, not the preset sharing its id — the rename is
    /// theirs and the reader must carry it.
    func test_aCustomizedStageResolvesToTheWritersOwnPass() {
        let mine = ReviewPass(id: "copyedit", name: "Polish", editorName: "Marta")
        let reader = manifest(passes: [mine]).reader(
            forPiece: "ch-1", memory: memory("ch-1", "copyedit"))
        XCTAssertEqual(reader, .stage(mine))
    }

    // MARK: - What each arm answers

    /// The coach travels to the run as an `ActivePass` like any pass: her id
    /// is the lane, her effective fields are the byline and the doctrine, and
    /// `isCoach` is the one thing that distinguishes her downstream.
    func test_theCoachsActivePassCarriesHerEffectiveFieldsAndIsCoach() {
        let pass = try? XCTUnwrap(
            manifest().reader(forPiece: "ch-1", memory: .empty).activePass)
        guard let pass else { return XCTFail("the coach must produce an ActivePass") }
        XCTAssertEqual(pass.id, "workshop")
        XCTAssertEqual(pass.name, "Workshop")
        XCTAssertEqual(pass.editorName, "Le Guin")
        XCTAssertEqual(pass.brief, ReviewPass.coachPreset.effectiveBrief,
                       "her doctrine must travel through effectiveBrief")
        XCTAssertTrue(pass.isCoach,
                      "nothing downstream can phrase her as a teacher without this")
    }

    /// A stage is not a coach — the flag is a discriminator, not decoration,
    /// and a stage carrying it would frame Gould as somebody's teacher.
    func test_aStagesActivePassIsNotACoach() {
        let pass = try? XCTUnwrap(
            manifest().reader(forPiece: "ch-1", memory: memory("ch-1", "copyedit"))
                .activePass)
        guard let pass else { return XCTFail("a stage must produce an ActivePass") }
        XCTAssertFalse(pass.isCoach)
        XCTAssertEqual(pass.editorName, "Gould",
                       "effectiveEditorName, never the raw field")
        XCTAssertEqual(pass.brief, ReviewPass.presets[2].effectiveBrief)
    }

    /// **The nobody arm, and the one surviving use of the passless name.**
    /// No `ActivePass` at all is what the orchestrator reads as the M2 lane:
    /// no round number, no stamp, notes signed "Claude".
    func test_nobodyHasNoActivePassNoLaneAndSignsWithThePasslessName() {
        let reader = manifest(coachVacated: true).reader(
            forPiece: "ch-1", memory: .empty)
        XCTAssertNil(reader.activePass,
                     "nobody must be the nil lane — an ActivePass here would "
                     + "mint a round for a reader that does not exist")
        XCTAssertNil(reader.laneId)
        XCTAssertEqual(reader.editorName, CompilerOrchestrator.passlessEditorName)
        XCTAssertEqual(reader.editorName, "Claude",
                       "control: the constant really is M2's identity")
    }

    /// The lane a round files in is the pass's own id, for both held arms.
    func test_theLaneIdIsThePassesOwnId() {
        XCTAssertEqual(
            manifest().reader(forPiece: "ch-1", memory: .empty).laneId, "workshop")
        XCTAssertEqual(
            manifest().reader(forPiece: "ch-1", memory: memory("ch-1", "line")).laneId,
            "line")
    }

    /// `editorName` is the byline the header, the round line and the note's
    /// author all read. A held arm answers the pass's own editor, never the
    /// passless constant.
    func test_editorNameIsThePassesEditorForBothHeldArms() {
        XCTAssertEqual(
            manifest().reader(forPiece: "ch-1", memory: .empty).editorName, "Le Guin")
        XCTAssertEqual(
            manifest().reader(forPiece: "ch-1", memory: memory("ch-1", "structural"))
                .editorName,
            "Perkins")
    }
}

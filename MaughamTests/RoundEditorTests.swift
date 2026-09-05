import XCTest
import MaughamCore
@testable import Maugham

/// **Who reads a ROUND** (two loops P1, spec §2).
///
/// `ProjectManifest.roundEditor(forPiece:memory:)` is the only place Review's
/// Run decides who is reading, and the rule is one sentence: the stage the
/// writer put this piece in, validated against the ladder as it stands, or
/// nobody at all.
///
/// `nil` is a REFUSAL rather than a fallback — no round is possible, and
/// `CompilerOrchestrator` starts nothing. That half is pinned where it
/// happens, in `CompilerRunCommandTests`
/// (`test_aRoundWithNoStageIsRefusedAndStartsNothing`); this file pins the
/// resolution itself.
final class RoundEditorTests: XCTestCase {

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

    // MARK: - The rule

    /// A piece the writer put in a lane is that lane's, exactly as before the
    /// loops parted.
    func test_aStoredIdThatStillNamesAStageResolvesToThatStage() {
        XCTAssertEqual(
            manifest().roundEditor(forPiece: "ch-1", memory: memory("ch-1", "copyedit")),
            ReviewPass.presets[2])
    }

    /// **No stage is no round.** Not the coach, not "Claude" — nobody, and
    /// the press that asked for one is refused.
    func test_noStoredIdIsNoEditor() {
        XCTAssertNil(manifest().roundEditor(forPiece: "ch-1", memory: .empty),
                     "an unassigned piece has no round editor, held seat or not")
    }

    /// **A retired pass id is no editor either.** Under `PieceReader` this
    /// case fell to the coach and quietly filed a round in her lane; the
    /// round loop refuses instead, because the lane the writer chose is gone
    /// and no other lane is a substitute for it.
    func test_aRetiredIdIsNoEditor() {
        let customized = [ReviewPass(id: "vibes", name: "Vibes")]
        XCTAssertNil(
            manifest(passes: customized)
                .roundEditor(forPiece: "ch-1", memory: memory("ch-1", "copyedit")))
    }

    /// **The coach is never a round editor, even with her id stored.**
    /// `validatedActivePass` checks against `effectiveReviewPasses`, which she
    /// is deliberately absent from — so this is the rule and not an accident
    /// of the lookup, and it holds whether or not her seat is held.
    func test_theCoachsOwnIdResolvesToNoEditor() {
        let stored = memory("ch-1", ReviewPass.coachPreset.id)
        XCTAssertNil(manifest().roundEditor(forPiece: "ch-1", memory: stored),
                     "a stored workshop id must not make the coach a round editor")
        XCTAssertNil(
            manifest(coachVacated: true).roundEditor(forPiece: "ch-1", memory: stored),
            "and vacating the seat cannot change that answer either")
        XCTAssertEqual(manifest().authorReader, .coach(ReviewPass.coachPreset),
                       "control: her seat really is held \u{2014} she reads "
                       + "checks, and nothing else")
    }

    /// The seat says nothing about a round in either direction: a stage
    /// resolves the same whether or not the coach is sitting.
    func test_theSeatDoesNotChangeAStagesAnswer() {
        let stored = memory("ch-1", "line")
        XCTAssertEqual(
            manifest().roundEditor(forPiece: "ch-1", memory: stored),
            ReviewPass.presets[1])
        XCTAssertEqual(
            manifest(coachVacated: true).roundEditor(forPiece: "ch-1", memory: stored),
            ReviewPass.presets[1])
    }

    /// The memory is per piece, so one assignment says nothing about the
    /// piece beside it.
    func test_theResolutionIsPerPiece() {
        let recorded = memory("ch-1", "line")
        let m = manifest()
        XCTAssertEqual(m.roundEditor(forPiece: "ch-1", memory: recorded),
                       ReviewPass.presets[1])
        XCTAssertNil(m.roundEditor(forPiece: "ch-5", memory: recorded),
                     "the piece next door is unassigned, and unassigned is no round")
    }

    /// A customized ladder that still contains the stored id resolves to the
    /// writer's OWN pass object, not the preset sharing its id — the rename is
    /// theirs and the round must carry it.
    func test_aCustomizedStageResolvesToTheWritersOwnPass() {
        let mine = ReviewPass(id: "copyedit", name: "Polish", editorName: "Marta")
        XCTAssertEqual(
            manifest(passes: [mine])
                .roundEditor(forPiece: "ch-1", memory: memory("ch-1", "copyedit")),
            mine)
        XCTAssertEqual(
            manifest(passes: [mine])
                .roundEditor(forPiece: "ch-1", memory: memory("ch-1", "copyedit"))?
                .effectiveEditorName,
            "Marta",
            "effectiveEditorName, never the raw field \u{2014} this is what "
            + "signs the round's notes")
    }
}

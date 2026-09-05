import Foundation
import MaughamCore

extension ProjectManifest {

    /// **Who reads a ROUND** — Review's Run button, and Review's ⌘R (two
    /// loops P1, spec §2). The stage the writer put this piece in, or nobody
    /// at all.
    ///
    /// `nil` does not mean "fall back to somebody". It means **no round is
    /// possible**: `CompilerOrchestrator.runRequested` refuses the press with
    /// `Acknowledgment.noEditor` and starts nothing — no session, no marker
    /// move, no record. A round is a numbered entry in a named lane, and a
    /// lane with no pass is not a lane the writer can ever compare anything
    /// against.
    ///
    /// **The coach is never a round editor, even if her id is stored.**
    /// `ActivePassMemory.validatedActivePass` is the one place a stored id is
    /// checked, and it is checked against `effectiveReviewPasses`, which the
    /// coach is deliberately absent from — so `workshop` in the memory reads
    /// as no pass at all and this answers `nil`. That is the rule rather than
    /// an accident of the lookup, which is why `RoundEditorTests` asserts it
    /// directly. Her seat belongs to the check loop (`AuthorReader`), and
    /// nothing in this file names it: `TripwireGrepTests`' census fails if
    /// `effectiveCoach` appears here.
    ///
    /// A **retired** pass id answers `nil` for the same reason: the id no
    /// longer names a stage, so there is no lane to file in. Under
    /// `PieceReader` that case fell to the coach and quietly filed a round in
    /// her lane; now it refuses, and the flash says what to do.
    ///
    /// `piece` is a piece id, which for the compiler is the document id —
    /// every reader of the memory keys it the same way.
    func roundEditor(forPiece piece: String, memory: ActivePassMemory) -> ReviewPass? {
        let passes = effectiveReviewPasses
        guard let id = memory.validatedActivePass(forPiece: piece, in: passes)
        else { return nil }
        return passes.first { $0.id == id }
    }
}

import Foundation
import MaughamCore

/// **Who reads a piece** — the one resolution of *stage pass / coach /
/// nobody* (editorial letter P1, spec §4.1 "The resolution has one
/// spelling").
///
/// Three surfaces name the reader and they must never name three different
/// people: the run's own briefing and the byline it signs notes with, the
/// Author header's reader line and empty-state promise, and the round lines
/// after a check finishes. Each of those asks
/// `ProjectManifest.reader(forPiece:memory:)` below; none re-derives the
/// rule.
///
/// **`nobody` is M2's lane and nothing else.** No `ActivePass` at all is what
/// `CompilerOrchestrator` reads as the passless run: no round number, no pass
/// stamp on what it writes, notes signed
/// `CompilerOrchestrator.passlessEditorName`. That constant's ONE production
/// use is this enum's `nobody` arm (`TripwireGrepTests`' census) — the mint
/// site reads `PieceReader.nobody.editorName` rather than the constant, so
/// there is one place that decides what an unread piece's notes are signed.
///
/// Lives in the Mac app rather than MaughamCore because `ActivePassMemory` —
/// the memory the resolution reads — is the Mac's own UI state.
enum PieceReader: Equatable {
    /// A ladder pass the writer put this piece in, in Review.
    case stage(ReviewPass)
    /// The coach, holding her seat over a piece nobody has assigned.
    case coach(ReviewPass)
    /// Nobody: the seat is vacant and the piece is unassigned. M2's
    /// all-altitudes ⌘R.
    case nobody

    /// The pass behind a held arm — `nil` for `nobody`. Private because the
    /// three answers below are what callers are meant to read: a caller
    /// reaching for the `ReviewPass` would be one `effectiveEditorName` away
    /// from re-deriving what `editorName` already resolved.
    private var heldPass: ReviewPass? {
        switch self {
        case .stage(let pass), .coach(let pass): return pass
        case .nobody: return nil
        }
    }

    /// Whether the held pass is the coach. Only `activePass` reads it, so the
    /// discriminator crosses the seam exactly once, as
    /// `CompilerOrchestrator.ActivePass.isCoach`.
    private var isCoach: Bool {
        if case .coach = self { return true }
        return false
    }

    /// What the run is briefed as, and what it files under — `nil` for
    /// `nobody`, which is the whole of the passless case.
    ///
    /// **`effectiveEditorName`/`effectiveBrief`, never the raw fields** (M4 P1
    /// Task 1's rule): a customized manifest can store a preset-id pass that
    /// predates both, and reading `pass.editorName` here would sign a Copyedit
    /// round's notes with nothing at all.
    var activePass: CompilerOrchestrator.ActivePass? {
        guard let pass = heldPass else { return nil }
        return CompilerOrchestrator.ActivePass(
            id: pass.id, name: pass.name,
            editorName: pass.effectiveEditorName,
            brief: pass.effectiveBrief,
            isCoach: isCoach)
    }

    /// The byline: who signs this piece's notes, and whose name the header
    /// and the round lines say. Never nil — an unread piece is still signed,
    /// and "Claude" is the name it is signed with.
    var editorName: String {
        heldPass?.effectiveEditorName ?? CompilerOrchestrator.passlessEditorName
    }

    /// The diagnostics lane a round files in, `nil` when there is no round to
    /// file. The coach has one like any pass — that is what gives her
    /// numbered rounds and a since-line with no orchestrator change.
    var laneId: String? { heldPass?.id }
}

extension ProjectManifest {

    /// **The one resolution.** A stored active-pass id that still names a
    /// stage wins; else the coach, if the writer has not vacated her seat;
    /// else nobody.
    ///
    /// The memory read is `ActivePassMemory.validatedActivePass` and is never
    /// re-derived here (`AnnotationPassStampTests`' census): a stored id that
    /// no longer names a stage already reads as unassigned there. Under this
    /// rule that hands the piece to the coach rather than to "Claude" —
    /// deleting a pass gives its pieces back to Le Guin (spec §4.1, stated so
    /// it is not a surprise).
    ///
    /// `piece` is a piece id, which for the compiler is the document id: both
    /// existing readers of the memory key it the same way.
    func reader(forPiece piece: String, memory: ActivePassMemory) -> PieceReader {
        let passes = effectiveReviewPasses
        if let id = memory.validatedActivePass(forPiece: piece, in: passes),
           let pass = passes.first(where: { $0.id == id }) {
            return .stage(pass)
        }
        if let coach = effectiveCoach { return .coach(coach) }
        return .nobody
    }
}

import Foundation
import MaughamCore

/// **Who reads a CHECK** — Author's ⌘R, and every persona's but Review's
/// (two loops P1, spec §2 "The check and the round part ways").
///
/// The coach while her seat is held, nobody once it is vacated. That is the
/// whole rule, and the shortness is the point: a check is the writer's own
/// loop, and the pass a piece sits in on the review board is a fact about the
/// ROUND loop that Author has no business reading. `PieceReader` — the one
/// resolution this type replaces — answered *stage / coach / nobody* for both
/// verbs, which is how a chapter parked in Gould's lane came to have its
/// Author checks signed "Gould" and filed as rounds in a lane the writer was
/// not standing in.
///
/// **There is no stage arm, and no `ActivePassMemory` is read here.** A
/// second arm would be the defect coming back, so the absence is guarded
/// rather than merely intended: `TripwireGrepTests`' census fails if this
/// file so much as names the memory. Who reads a round is `RoundEditor`'s
/// question, one file over.
///
/// **`nobody` is M2's lane and nothing else.** No `ActivePass` at all is what
/// `CompilerOrchestrator` reads as the passless run: no round number, no pass
/// stamp on what it writes, notes signed
/// `CompilerOrchestrator.passlessEditorName`. That constant's ONE production
/// use is this enum's `nobody` arm (`TripwireGrepTests`' census) — the mint
/// site reads `AuthorReader.nobody.editorName` rather than the constant, so
/// there is one place that decides what an unread piece's notes are signed.
///
/// Lives in the Mac app rather than MaughamCore because the resolution it
/// belongs to — the pair with `RoundEditor` — reads the Mac's own UI state on
/// the other side.
///
/// P2 adds `.firstReader`.
enum AuthorReader: Equatable {
    /// The coach, holding her seat. Every piece is hers while it is held:
    /// the check loop does not ask which lane a piece is parked in.
    case coach(ReviewPass)
    /// Nobody: the writer vacated the seat. M2's all-altitudes ⌘R.
    case nobody

    /// The pass behind the held arm — `nil` for `nobody`. Private because the
    /// two answers below are what callers are meant to read: a caller
    /// reaching for the `ReviewPass` would be one `effectiveEditorName` away
    /// from re-deriving what `editorName` already resolved.
    private var heldPass: ReviewPass? {
        switch self {
        case .coach(let pass): return pass
        case .nobody: return nil
        }
    }

    /// What the check is briefed as — `nil` for `nobody`, which is the whole
    /// of the passless case.
    ///
    /// **`isCoach` is unconditionally true here**, because the only held arm
    /// is the coach's. It is what `CompilerPrompt.passSection` reads to frame
    /// her as a teacher rather than an editor, and a check is the one verb
    /// that can ever carry it: a round's `ActivePass` is always a stage's.
    ///
    /// **`effectiveEditorName`/`effectiveBrief`, never the raw fields** (M4 P1
    /// Task 1's rule): a customized manifest can store a preset-id pass that
    /// predates both, and reading `pass.editorName` here would sign a check's
    /// notes with nothing at all.
    var activePass: CompilerOrchestrator.ActivePass? {
        guard let pass = heldPass else { return nil }
        return CompilerOrchestrator.ActivePass(
            id: pass.id, name: pass.name,
            editorName: pass.effectiveEditorName,
            brief: pass.effectiveBrief,
            isCoach: true)
    }

    /// The byline: who signs this piece's check notes, and whose name the
    /// Author header says. Never nil — an unread piece is still signed, and
    /// "Claude" is the name it is signed with.
    var editorName: String {
        heldPass?.effectiveEditorName ?? CompilerOrchestrator.passlessEditorName
    }
}

extension ProjectManifest {

    /// **The check's reader, and it is per PROJECT rather than per piece.**
    /// The seat is held over a book, not over a chapter, and there is nothing
    /// else left in the rule — so a `forPiece:` parameter here would be an
    /// argument this resolution could only ignore, and a seam suggesting a
    /// per-piece answer that no longer exists.
    var authorReader: AuthorReader {
        effectiveCoach.map(AuthorReader.coach) ?? .nobody
    }
}

import Foundation
import MaughamCore

/// **The queue's advisory nudge** (M3 P2 Task 8): when a writer works a piece
/// through a late pass while an earlier one is still open, say so — once,
/// quietly, in a caption.
///
/// *Lenses, not gates* (the constitution). There is no dialog, nothing
/// disabled, and nothing refused: proofreading a chapter whose structural pass
/// is unfinished is a legitimate thing for a writer to do, and the only cost
/// of doing it is a line of text that names what is still open. The passes are
/// an ORDER, not a workflow the app enforces.
///
/// Pure, so the whole truth table is assertable without a pane, a store or a
/// project on disk: `PassOrderAdviceTests`.
enum PassOrderAdvice {

    /// The earliest pass ordered BEFORE `activePassId` whose state is not
    /// final, or nil when there is nothing to say.
    ///
    /// **Only `.done` and `.skipped` are final.** An absent key (and an absent
    /// dictionary) is a pass the writer has never ruled on — the commonest
    /// reason to nudge at all — and `.inProgress` is by definition unfinished.
    /// `.unknown` counts as open on `PassState`'s own precedent: a state
    /// written by a newer build reads as untouched to this one, and calling an
    /// unreadable state *finished* would silence the advice on exactly the
    /// piece whose state this build cannot vouch for.
    ///
    /// **Earliest, not nearest.** Of several open earlier passes, the one
    /// furthest back is the one whose work is most likely to undo the pass the
    /// writer is on, and one caption naming one pass is the whole budget.
    ///
    /// An `activePassId` the list does not contain has no position, so there
    /// is no "before" to search and the answer is silence. The queue never
    /// asks that — its pass id comes through
    /// `ActivePassMemory.validatedActivePass` — but a retired id arriving here
    /// must not read as "everything is earlier than this".
    static func openEarlierPass(
        activePassId: String,
        passes: [ReviewPass],
        passStates: [String: PassState]?
    ) -> ReviewPass? {
        guard let position = passes.firstIndex(where: { $0.id == activePassId })
        else { return nil }
        return passes[..<position].first { pass in
            switch passStates?[pass.id] {
            case .done, .skipped: return false
            case .inProgress, .unknown, nil: return true
            }
        }
    }

    /// The caption itself, so the pane and the test agree on the sentence.
    static func caption(for pass: ReviewPass) -> String {
        "\(pass.name) still open on this piece"
    }
}

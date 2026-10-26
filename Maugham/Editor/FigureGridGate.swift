import Foundation
import MaughamCore

/// **Whether a table figure's grid opens, and whether it may be changed**
/// (report plan 7c Task 8, rulings R7c-5 and R7c-6) — pure, so every row is
/// pinned without a window (`FigureGridGateTests`).
///
/// The inputs are gathered by the coordinator: `figureMayEdit` is the
/// FIGURE's drawing posture asked of the window's one door
/// (`DocumentStore.posture(forDocId:)`, `.allows(.editFigure)`), never a rung
/// (tripwires 47, 51); `parked` and `hostClosed` are the visit's host; the
/// modes are the editor's own flags. Asked at expand, when the visit mounts,
/// whenever the figure's drawn posture changes (the controller observes the
/// door: a trust change, *Edit Anyway*), at every `figureCardVersion` edge,
/// when a mode flag flips, and after a write the host refused.
///
/// Only the cells, the structure and the name answer to this gate. The
/// caption is the figure line's TEXT, so it follows the text's membrane
/// (`EditorEditPolicy.allowsTextMutation`) on its own — each field disables
/// on its own (R7c-6).
enum FigureGridGate {

    enum Mode: Equatable {
        /// The grid opens and may be changed.
        case editable
        /// The grid opens to be read — selected and scrolled, its bars
        /// disabled, typing answered with the reason's sentence.
        case readOnly(Reason)
        /// The card stays a card (translation review shows a derived
        /// surface; there is no figure line of the writer's to open).
        case noExpand

        var readOnlyReason: Reason? {
            if case .readOnly(let reason) = self { return reason }
            return nil
        }
    }

    /// Why the grid may be read but not changed, first match wins.
    enum Reason: Equatable {
        /// Parked in Research (ruling P-5): its content is the Research copy's.
        case parked
        /// The visit's host was closed under it.
        case closed
        /// The figure's posture refuses `.editFigure` — another piece's
        /// author, a reviewer, a yield until *Edit Anyway*, a permit this
        /// build cannot read, or a posture still settling.
        case notYours
        /// A read-only iCloud share: the folder takes no writes.
        case viewOnlyShare
        /// The window's explicit review mode (⌘⌥⇧R) — never the review
        /// forced where the text is not hers (R7c-6).
        case reviewMode

        /// The line the read-only grid answers typing with.
        var sentence: String {
            switch self {
            case .parked: return FigureParkedRefused.notice(for: .table)
            case .closed: return "This table was closed, so it can’t be changed here."
            case .notYours: return "This table isn’t yours to change — you can read it."
            case .viewOnlyShare: return "This share is view-only, so the table can’t be changed."
            case .reviewMode: return "You’re reviewing — the table can be read, not changed."
            }
        }
    }

    static func mode(figureMayEdit: Bool, parked: Bool, hostClosed: Bool, shareIsReadOnly: Bool,
                     isReviewMode: Bool, isTranslationReview: Bool) -> Mode {
        if isTranslationReview { return .noExpand }
        if parked { return .readOnly(.parked) }
        if hostClosed { return .readOnly(.closed) }
        if !figureMayEdit { return .readOnly(.notYours) }
        if shareIsReadOnly { return .readOnly(.viewOnlyShare) }
        if isReviewMode { return .readOnly(.reviewMode) }
        return .editable
    }
}

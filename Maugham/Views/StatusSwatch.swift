import SwiftUI
import MaughamCore

/// The one place a `ReviewStatus` becomes a `Color` (M3 P1 Task 3) — every
/// status dot in the tree (`OutlineTable`, `BinderRow`, `CorkboardGrid`,
/// `PieceRow`) used to carry its own copy of this switch, and the four had
/// already drifted (`PieceRow` alone painted an explicit `.gray` for legacy
/// `"draft"`; the other three fell through their `default:` to `.secondary`
/// for the same input). Converging them here is itself the fix for that
/// drift — see each call site's comment for what, if anything, its pixels
/// change.
///
/// **No `default:`** — `ReviewStatus` has exactly three cases and a fourth
/// must be reasoned about here, not silently swallowed.
enum StatusSwatch {
    static func color(for status: ReviewStatus) -> Color {
        switch status {
        case .draft: return .secondary
        case .revising: return .orange
        case .final: return .green
        }
    }

    /// The one spelling of a `ReviewStatus` in WORDS (M3 P1 Task 4), beside
    /// the one spelling of it in colour. Used by the Inspector's read-only
    /// projection row and by the altitude table's Status column — which used
    /// to print the raw legacy `status` string, and would have gone on
    /// printing "draft" for a piece whose passes were all done, since nothing
    /// writes that string any more.
    ///
    /// **No `default:`** — same rule as `color(for:)`.
    static func label(for status: ReviewStatus) -> String {
        switch status {
        case .draft: return "Draft"
        case .revising: return "Revising"
        case .final: return "Final"
        }
    }

    /// Whether a row should draw a dot at all — **is this piece TOUCHED?**
    /// (M3 P1 Task 4.)
    ///
    /// `PieceRow` has always suppressed the dot for a piece with no status,
    /// and that suppression is worth keeping: a Collection's pieces are
    /// created with `status == nil`, so drawing every one of them would put a
    /// column of identical gray "draft" dots down a pane where nothing has
    /// been adjudicated — noise that says the same thing about every row.
    ///
    /// But the guard used to read the RAW legacy string, and Task 4 is the
    /// task that stops anything writing it. A piece whose review record is
    /// entirely `passStates` — every piece from here on — derives a real
    /// status and would have drawn NO dot: the ladder would set Structural to
    /// Done and the pane would show nothing at all. So the presence question
    /// is asked of the same two inputs the projection reads: a piece is
    /// touched if it has any pass state, or a non-empty legacy status.
    ///
    /// It is deliberately NOT `derived(…) != .draft`. Untouched and
    /// deliberately-still-draft are different facts, and the second one is a
    /// dot the writer put there.
    static func showsDot(passStates: [String: PassState]?, legacyStatus: String?) -> Bool {
        if let passStates, !passStates.isEmpty { return true }
        if let legacyStatus, !legacyStatus.isEmpty { return true }
        return false
    }
}

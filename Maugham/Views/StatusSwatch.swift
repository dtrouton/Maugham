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
}

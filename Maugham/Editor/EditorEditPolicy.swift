import Foundation

/// Decides whether the editor membrane permits manuscript text mutation.
///
/// Review posture (WF1) makes the editor annotate-only: the manuscript text is
/// read-only while selection, scrolling, copy, and the annotation surfaces stay
/// live. This enum is the single, pure decision point so the rule is unit-
/// testable away from AppKit. `EditorCoordinator` keys its
/// `textView(_:shouldChangeTextIn:replacementString:)` guard off it.
enum EditorEditPolicy {
    /// True when manuscript text may be mutated through the editor; false in
    /// review posture (annotate-only).
    ///
    /// Two independent reasons block mutation:
    ///   - `isReviewMode`: the user is manually reviewing (⌘⌥R) — a soft,
    ///     toggleable posture an author opts into.
    ///   - `lockEditing`: the user is NOT an author of this manuscript (an
    ///     iCloud reviewer, or the still-resolving `.unknown` role). This is the
    ///     hard floor: it cannot be toggled off, so a reviewer's ⌘⌥R can flip the
    ///     review RENDER but never unlock the text. The membrane is the authority
    ///     here — the manual toggle never wins over the role lock.
    static func allowsTextMutation(isReviewMode: Bool, lockEditing: Bool) -> Bool {
        !isReviewMode && !lockEditing
    }
}

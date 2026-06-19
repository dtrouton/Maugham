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
    static func allowsTextMutation(isReviewMode: Bool) -> Bool {
        !isReviewMode
    }
}

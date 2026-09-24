import Foundation

/// Decides whether the editor membrane permits manuscript text mutation.
///
/// Review posture makes the editor annotate-only: the manuscript text is
/// read-only while selection, scrolling, copy, and the annotation surfaces stay
/// live. This enum is the single, pure decision point so the rule is unit-
/// testable away from AppKit. `EditorCoordinator` keys its
/// `textView(_:shouldChangeTextIn:replacementString:)` guard off it.
enum EditorEditPolicy {
    /// True when manuscript text may be mutated through the editor; false in
    /// review posture (annotate-only).
    ///
    /// Three independent reasons block mutation:
    ///   - `isReviewMode`: the user is manually reviewing (⌘⌥⇧R) — a soft,
    ///     toggleable posture an author opts into.
    ///   - `lockEditing`: this device may not write this manuscript's text —
    ///     its posture refuses `.writeText` (the permit's answer, or
    ///     `Posture.settling` while nothing is decided yet), or the iCloud
    ///     share is read-only, an OS-level lock that claims no role
    ///     (`EditorControlMirror.membrane`, P3c). This is the hard floor: it
    ///     cannot be toggled off, so a reviewer's ⌘⌥⇧R can flip the review
    ///     RENDER but never unlock the text. The membrane is the authority
    ///     here — the manual toggle never wins over the lock.
    ///   - `isTranslationReview`: the editor is displaying a derived translated
    ///     surface (Task 11) rather than the source manuscript. The buffer the
    ///     reader is inspecting is NOT the op-log-backed text, so any edit would
    ///     be meaningless — the membrane blocks all mutation so the read-only
    ///     translated view produces zero ops.
    ///
    /// `isTranslationReview` defaults to false so the two-reason call sites
    /// (review render + lock, pre-Task-11) keep compiling unchanged.
    static func allowsTextMutation(isReviewMode: Bool, lockEditing: Bool,
                                   isTranslationReview: Bool = false) -> Bool {
        !isReviewMode && !lockEditing && !isTranslationReview
    }
}

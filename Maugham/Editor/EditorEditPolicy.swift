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
    ///   - `isReviewMode`: the review render — forced where the posture
    ///     refuses the text, or a piece in read-through.
    ///   - `lockEditing`: this device may not write this manuscript's text —
    ///     its posture refuses `.writeText` (the permit's answer, or
    ///     `Posture.settling` while nothing is decided yet), or the iCloud
    ///     share is read-only, an OS-level lock that claims no role
    ///     (`EditorControlMirror.membrane`, P3c). This is the hard floor: it
    ///     cannot be toggled off: nothing that flips the review RENDER
    ///     unlocks the text. The membrane is the authority here.
    ///   - `isReadingTranslation`: the editor is displaying a derived translated
    ///     surface (Task 11) rather than the source manuscript. The buffer the
    ///     reader is inspecting is NOT the op-log-backed text, so any edit would
    ///     be meaningless — the membrane blocks all mutation so the read-only
    ///     translated view produces zero ops.
    ///
    ///   - `isInReadThrough`: the piece the buffer holds is in read-through —
    ///     typing off, decisions on. A belt beside the view's `isEditable`,
    ///     which refuses first (`EditorCoordinator.refreshEditability`).
    ///
    /// Every reason is required: a caller that left one out would answer
    /// "typing allowed" for a translation or a piece in read-through.
    static func allowsTextMutation(isReviewMode: Bool, lockEditing: Bool,
                                   isReadingTranslation: Bool,
                                   isInReadThrough: Bool) -> Bool {
        !isReviewMode && !lockEditing && !isReadingTranslation && !isInReadThrough
    }

    /// True when a click on a checkbox glyph may flip it. A flip writes text
    /// through `checkboxToggleHandler`, so it asks the membrane a keystroke
    /// asks: the hard lock (a posture that refuses `.writeText`, a read-only
    /// share) and the translated view. A click that flipped anyway would, in
    /// the yield case, sign text in a piece the writer has not claimed (#74).
    ///
    /// `isReviewMode` is deliberately NOT a parameter: the writer's own review
    /// render keeps checkboxes live, matching the Tasks pane.
    static func allowsCheckboxToggle(lockEditing: Bool,
                                     isReadingTranslation: Bool) -> Bool {
        !lockEditing && !isReadingTranslation
    }
}

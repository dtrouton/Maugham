import SwiftUI
import MaughamCore

/// **The editor's membrane, decided from the posture** (P3c Task 3) — pure, so
/// both directions are pinned without a window (`ReviewModeMembraneTests`).
///
/// - `lockEditing` is the hard floor: the posture refuses `.writeText`, or the
///   iCloud share is read-only (an OS-level lock that claims no role).
/// - `isReviewMode` is the manual ⌘⌥⇧R toggle, or forced on where the posture
///   refuses the text — a reviewer's Mac opens in review mode, so the
///   selection toolbar offers annotation.
///
/// Keyed on `allows(.writeText)`, never on `isRestricted` (controller ruling
/// E): an author of some pieces inside her own piece is restricted (she may
/// not start a piece) and may type every word of it. `Posture.settling` —
/// nothing decided yet — refuses `.writeText`, so it LOCKS: a verb appearing a
/// frame late is fine, one appearing that must not is not. `nil` is no
/// manuscript document in the editor: nothing to lock.
enum EditorControlMirror {
    struct Membrane: Equatable {
        let lockEditing: Bool
        let isReviewMode: Bool
    }

    static func membrane(
        posture: Posture?, manualReview: Bool, shareIsReadOnly: Bool
    ) -> Membrane {
        let mayWrite = posture?.allows(.writeText) ?? true
        return Membrane(
            lockEditing: !mayWrite || shareIsReadOnly,
            isReviewMode: manualReview || !mayWrite)
    }
}

/// Mirrors posture + appearance changes from ProjectWindow-owned sources into
/// the `EditorControl` model (ADR 0017). Extracted into a ViewModifier to stay
/// under ProjectWindow.body's SwiftUI type-checker ceiling.
struct EditorControlMirrorModifier: ViewModifier {
    /// Computed in `ProjectWindow`'s body from the drawing posture door, so a
    /// selection change AND a `postureEpoch` bump both arrive here as a change
    /// of this value.
    let membrane: EditorControlMirror.Membrane
    /// The same door's answer, whole, for the margin card's dispositions
    /// (P3c Task 5) — mirrored beside the membrane rather than folded into it,
    /// because the membrane is the pinned lock decision and nothing more.
    let posture: Posture?
    let effectiveTypography: TypographySettings
    @Binding var editorControl: EditorControl
    @Environment(UserPreferences.self) private var userPreferences

    func body(content: Content) -> some View {
        content
            .onChange(of: membrane) { _, membrane in
                editorControl.isReviewMode = membrane.isReviewMode
                editorControl.lockEditing = membrane.lockEditing
            }
            .onChange(of: posture) { _, posture in editorControl.posture = posture }
            .onChange(of: userPreferences.theme) { _, t in editorControl.theme = t }
            .onChange(of: effectiveTypography) { _, t in editorControl.typography = t }
            .onChange(of: userPreferences.typewriterScroll) { _, v in
                editorControl.typewriterScroll = v
            }
            .onChange(of: userPreferences.sentenceFocus) { _, v in
                editorControl.sentenceFocus = v
            }
            .onChange(of: userPreferences.paragraphFocus) { _, v in
                editorControl.paragraphFocus = v
            }
            .onAppear {
                // Seed the model from current sources (onChange only fires on
                // transitions, not on first render).
                editorControl.isReviewMode = membrane.isReviewMode
                editorControl.lockEditing = membrane.lockEditing
                editorControl.posture = posture
                editorControl.theme = userPreferences.theme
                editorControl.typography = effectiveTypography
                editorControl.typewriterScroll = userPreferences.typewriterScroll
                editorControl.sentenceFocus = userPreferences.sentenceFocus
                editorControl.paragraphFocus = userPreferences.paragraphFocus
            }
    }
}

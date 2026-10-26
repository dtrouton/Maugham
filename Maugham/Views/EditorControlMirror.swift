import SwiftUI
import MaughamCore

/// **The editor's membrane, decided from the posture** — pure, so both
/// directions are pinned without a window (`ReviewModeMembraneTests`).
///
/// - `lockEditing` is the hard floor: the posture refuses `.writeText`, or the
///   iCloud share is read-only (an OS-level lock that claims no role).
/// - `isReviewMode` is the manual ⌘⌥⇧R toggle, or forced on where the posture
///   refuses the text — a reviewer's Mac opens in review mode, so the
///   selection toolbar offers annotation.
///
/// Keyed on `allows(.writeText)`, never on `isRestricted` (controller ruling
/// E): an author of some pieces inside her own piece is restricted (she may
/// not start a piece) and may type every word of it. `Posture.settling` refuses
/// `.writeText`, so it LOCKS: a verb appearing a frame late is fine, one
/// appearing that must not is not. `nil` is no manuscript document in the
/// editor: nothing to lock.
enum EditorControlMirror {
    struct Membrane: Equatable {
        let lockEditing: Bool
        let isReviewMode: Bool
        /// The share input on its own, for the figure grid's gate
        /// (`FigureGridGate`), which answers to the figure's posture and
        /// never to the text's.
        var shareIsReadOnly: Bool = false
        /// The explicit ⌘⌥⇧R toggle alone, for the figure grid's gate —
        /// `isReviewMode` is also forced where the text is refused.
        var manualReview: Bool = false
    }

    static func membrane(
        posture: Posture?, manualReview: Bool, shareIsReadOnly: Bool
    ) -> Membrane {
        let mayWrite = posture?.allows(.writeText) ?? true
        return Membrane(
            lockEditing: !mayWrite || shareIsReadOnly,
            isReviewMode: manualReview || !mayWrite,
            shareIsReadOnly: shareIsReadOnly, manualReview: manualReview)
    }
}

/// **Whether the Insert menu's items are enabled** (plan 3a Task 4) — the
/// window's answer to "may the key window's editor take an inserted report
/// element?", published to the menu bar as `FocusedValues.mayInsertReportElement`.
/// Pure, so every refusal is pinned without a window (`InsertCommandTests`).
///
/// The editor's membrane refuses on its own all the same (defence in depth):
/// a disabled item is what the writer sees, the membrane is what holds.
enum InsertMenuGate {
    /// True only when all of these hold:
    /// - the centre shows the bare editor — `.editor(altitude: false, cover: nil)`.
    ///   Altitude, the canvas, a research subject, a Collection reference and
    ///   every cover (Publish's problems and translation round draw over a
    ///   chapter too) hide the text the insert would land in;
    /// - the editor holds a manuscript document (`posture` non-nil) whose
    ///   format takes report elements (`format`, not a screenplay);
    /// - its posture `allows(.writeText)`, and the iCloud share is writable;
    /// - the editor is not in review mode (⌘⌥⇧R) or translation review.
    static func isEnabled(posture: Posture?, format: DocumentFormat?,
                          manualReview: Bool, shareIsReadOnly: Bool,
                          isTranslationReview: Bool, route: CentreRoute?) -> Bool {
        guard case .editor(altitude: false, cover: nil)? = route,
              let posture, let format, !format.isScreenplay else { return false }
        return posture.allows(.writeText) && !shareIsReadOnly
            && !manualReview && !isTranslationReview
    }
}

/// Mirrors posture + appearance changes from ProjectWindow-owned sources into
/// the `EditorControl` model (ADR 0017). A modifier for `ProjectWindow.body`'s
/// type-check ceiling.
struct EditorControlMirrorModifier: ViewModifier {
    /// Computed in `ProjectWindow`'s body from the drawing posture door, so a
    /// selection change AND a `postureEpoch` bump both arrive here as a change
    /// of this value.
    let membrane: EditorControlMirror.Membrane
    /// The same door's answer, whole, for the margin card's dispositions —
    /// mirrored beside the membrane rather than folded into it, because the
    /// membrane is the pinned lock decision and nothing more.
    let posture: Posture?
    /// Whether the Insert menu's items are enabled (`InsertMenuGate`), published
    /// to the menu bar beside the membrane it shadows — the window publishes it
    /// here because this modifier already carries the window's editor posture.
    let mayInsertReportElement: Bool
    let effectiveTypography: TypographySettings
    @Binding var editorControl: EditorControl
    @Environment(UserPreferences.self) private var userPreferences

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.mayInsertReportElement, mayInsertReportElement)
            .onChange(of: membrane) { _, membrane in
                editorControl.isReviewMode = membrane.isReviewMode
                editorControl.lockEditing = membrane.lockEditing
                editorControl.shareIsReadOnly = membrane.shareIsReadOnly
                editorControl.isManualReviewMode = membrane.manualReview
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
                editorControl.shareIsReadOnly = membrane.shareIsReadOnly
                editorControl.isManualReviewMode = membrane.manualReview
                editorControl.posture = posture
                editorControl.theme = userPreferences.theme
                editorControl.typography = effectiveTypography
                editorControl.typewriterScroll = userPreferences.typewriterScroll
                editorControl.sentenceFocus = userPreferences.sentenceFocus
                editorControl.paragraphFocus = userPreferences.paragraphFocus
                // Not mirrored here: `referenceIndexVersion` and
                // `figureCardVersion` are written by `EditorHost`, which owns
                // the index and the cards (report plan 7a Task 4).
            }
    }
}

import Foundation
import MaughamCore
import Observation

/// First-class model for editor CONTROL state — the configuration the editor
/// needs that is NOT the manuscript text. The data plane (text) is owned by
/// `Document`; this is its control-plane analogue (ADR 0017).
///
/// `ProjectWindow` owns one of these and mirrors its derived control into it;
/// the `EditorCoordinator` observes it via `withObservationTracking`. Flow is
/// strictly one-way (sources → model → coordinator); the coordinator never
/// writes back.
///
/// INVARIANT D1: only genuine control state lives here — never text- or
/// cursor-derived values. If a per-keystroke value leaked in, the coordinator's
/// observation would fire on the typing hot path.
@Observable
final class EditorControl {
    // Posture (membrane).
    var isReviewMode: Bool = false
    var lockEditing: Bool = false

    /// Selected translation language, or nil when the editor shows the source
    /// manuscript (Task 11). Non-nil ⇒ the editor is in read-only translation
    /// review: the coordinator flips its membrane (via `applyControl` →
    /// `setTranslationReview`) and EditorHost swaps in the derived translated
    /// surface. One-way (sources → model → coordinator); the UI sets it in a
    /// later task. Genuine control state — never text-/cursor-derived (D1).
    var translationLanguage: String? = nil

    // Appearance.
    var theme: Theme = .light
    var typography: TypographySettings = .defaults
    var typewriterScroll: Bool = false
    var sentenceFocus: Bool = false
    var paragraphFocus: Bool = false

    // Review render set (open annotations shown in review posture).
    var reviewAnnotations: [Annotation] = []

    init() {}
}

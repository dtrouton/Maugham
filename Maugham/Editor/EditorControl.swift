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

    /// Ordered per-paragraph translation freshness for the staleness-badge
    /// overlay + the dimmed-missing treatment (Task 12), paired with the rendered
    /// translated surface those paragraph offsets map into. `.empty` when not in
    /// translation review. Threaded ONE-WAY (sources → model → coordinator) on
    /// EXPLICIT translation events only — a language change, an
    /// `annotationsVersion` tick while in the posture, or a re-mount — never off
    /// `displayText`. D1-safe for the same reason `translationLanguage` /
    /// `reviewAnnotations` are: the translation-review surface is READ-ONLY, so
    /// this never changes on the typing hot path. `renderedText` is the SAME
    /// string EditorHost swaps into the editor buffer, so the coordinator's
    /// `TranslationBadgeLayout` offsets map cleanly onto the live surface.
    var translationBadges: TranslationBadgeModel = .empty

    /// The ordered translation-freshness entries + the rendered translated
    /// surface they index into. Equatable so the coordinator can no-op-guard the
    /// per-`applyControl` push (like `reviewAnnotations`).
    struct TranslationBadgeModel: Equatable {
        var entries: [TranslationBadgeLayout.Entry]
        var renderedText: String
        static let empty = TranslationBadgeModel(entries: [], renderedText: "")
    }

    init() {}
}

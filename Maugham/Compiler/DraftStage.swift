import Foundation

/// Whether the run's own delta reads as laying down new text or reworking
/// existing text — **derived, never set**, and never stored anywhere but the
/// letter (`Letter.stage`, constraint 23). Spec
/// `2026-08-29-the-editorial-letter-design.md` §3.8: a first draft in motion
/// should not be line-edited, so drafting earns a short letter and revising
/// earns the full one.
enum DraftStage: String, Codable, Equatable, Sendable {
    case drafting = "drafting"
    case revising = "revising"

    /// Drafting iff the delta is mostly new (`counts.new > counts.revised`)
    /// AND the frontier moved in the latest session
    /// (`signals?.sessionsSinceFrontierMoved == 0`).
    ///
    /// A `nil` frontier — nothing was ever typed new in Maugham for this
    /// document, `ProcessSignals.frontier` — reads as revising: there is no
    /// frontier to have just moved, whatever the counts say. `signals == nil`
    /// (no reading taken) decides on the counts alone.
    static func derive(
        counts: CompilerOrchestrator.DeltaCounts,
        signals: ProcessSignals?
    ) -> DraftStage {
        guard counts.new > counts.revised else { return .revising }
        guard let signals else { return .drafting }
        return signals.sessionsSinceFrontierMoved == 0 ? .drafting : .revising
    }

    /// Fresh Eyes always rereads cold and gets the full letter; otherwise a
    /// drafting stage earns the short one (spec §3.8).
    func dosage(freshEyes: Bool) -> LetterDosage {
        guard !freshEyes else { return .full }
        return self == .drafting ? .short : .full
    }

    /// The word the lane line shows — the rawValue, so
    /// "Le Guin · round 3 · drafting". Read from exactly two view files:
    /// `ReviewRoundCockpit.swift` and `LetterSection.swift` (constraint 28) —
    /// a third reader is a second place the lane's spelling could drift.
    var laneWord: String { rawValue }
}

/// How much letter a stage earns, enforced at BOTH ends (constraint 24):
/// `DiagnosticIngest.parseLetter` caps to this at ingest, and
/// `CompilerPrompt.stageSection` states the same doctrine to the model — so
/// the short letter is short whatever the model did, not just what it was
/// asked to do.
enum LetterDosage: Equatable, Sendable {
    case full
    case short

    var questionsCap: Int {
        switch self {
        case .full: return DiagnosticIngest.letterQuestionsCap
        case .short: return 1
        }
    }

    var allowsExercise: Bool { self == .full }
    var allowsScenes: Bool { self == .full }
}

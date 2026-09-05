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
    /// **The first reader's letter** (two loops P2, spec §4.3) — and the one
    /// dose that is not a stage's.
    ///
    /// `.full` and `.short` are two amounts of the SAME letter: a craft
    /// verdict, dosed by how far along the draft is. This one is a different
    /// letter — `answer`, `about`, `working` (what she loved and why, as a
    /// reader) and at most one question. The parts it drops are dropped
    /// because they are craft: the one thing to fix, the habits across the
    /// whole piece and the exercise that goes with one, the scene table, and
    /// the ledger's `retired` list. A reader who names a habit and prescribes
    /// an exercise for it has become an editor, which is the whole thing
    /// §4.3 exists to prevent.
    ///
    /// **Its precedence over the stage is the orchestrator's** (Task 4): who
    /// is reading decides the dose before how far along the draft is, and a
    /// cold read does not make a first reader write a craft letter. Nothing
    /// here chooses between them — this case only says what the dose IS, and
    /// `DiagnosticIngest.parseLetter` enforces it whatever the model wrote.
    case reader

    var questionsCap: Int {
        switch self {
        case .full: return DiagnosticIngest.letterQuestionsCap
        // A reader asks at most one question for the short letter's reason
        // and one of her own: she is reporting a reading, not conducting an
        // interview.
        case .short, .reader: return 1
        }
    }

    var allowsExercise: Bool { self == .full }
    var allowsScenes: Bool { self == .full }
    /// **The two flags the reader's letter added** (two loops P2 Task 3).
    /// Both are true for every stage dose — a drafting letter still names the
    /// one thing and still reports a habit that runs through the whole delta
    /// (`stageSection` says so in as many words) — and false for the reader
    /// alone, so the dose that drops them is the one that is not a craft
    /// verdict.
    var allowsOneThing: Bool { self != .reader }
    /// Governs the `retired` list as well as the habits themselves: retiring
    /// a lesson is a report on the writer's own ledger, which is the same
    /// craft register the habits are in and nothing a reader is briefed on.
    var allowsHabits: Bool { self != .reader }
    /// **The letter's process line is craft too** (controller ruling, two
    /// loops P2 Task 3 review). It says how long the writer has been reworking
    /// a paragraph and what their frontier is doing — an observation about
    /// their practice, made from numbers Maugham counted off the op log — and
    /// a first reader who reported it would be doing exactly what her
    /// instruction forbids: talking about the writing instead of the reading.
    /// A drafting letter still carries it, which is why this is a flag rather
    /// than a second reading of `allowsHabits`.
    ///
    /// Task 4 also stops briefing her on the numbers at all (`signals: nil`);
    /// this end is what makes the drop true whatever the model wrote.
    var allowsProcess: Bool { self != .reader }
}

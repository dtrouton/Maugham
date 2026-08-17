import Foundation

/// A named editing pass on the manifest's `reviewPasses` list — the Review
/// persona's column headers on the board (M3 P1).
///
/// Position is array order; there is no separate order field, so reordering
/// is rewriting the array (Task 9's editor). `id` is stable identity: piece
/// `passStates` (Task 2) keys on it, and a rename must not disturb a single
/// piece's recorded state.
///
/// **Preset ids are a STABLE CONTRACT.** `"structural"`, `"line"`,
/// `"copyedit"`, `"proof"` are cited by P3's round records and must never
/// change once a project has states keyed on them — treat a rename of a
/// preset id as a breaking change to every project that has never customized
/// its pass list.
public struct ReviewPass: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String

    /// The editorial brief for this pass's rounds — what they attend to,
    /// and (as sharply) what they leave alone. Own field wins; a
    /// preset-id pass with no stored brief of its own falls back to the
    /// matching preset's brief via `effectiveBrief` — never read directly
    /// at a call site (M4 P1).
    public var brief: String?

    /// This pass's named editor voice — the four presets are Perkins,
    /// Lish, Gould, Argus. Own field wins; falls back through
    /// `effectiveEditorName`, never read directly at a call site
    /// (M4 P1).
    public var editorName: String?

    public init(id: String, name: String, brief: String? = nil, editorName: String? = nil) {
        self.id = id
        self.name = name
        self.brief = brief
        self.editorName = editorName
    }

    /// The brief a reader should actually use: this pass's own `brief`,
    /// else — because a customized manifest can store a preset-id pass
    /// (renamed, reordered, or just re-saved) that predates this field and
    /// so carries none of its own — the brief of the preset sharing this
    /// pass's `id`, else nil. nil means "no doctrine for this pass";
    /// callers building a briefing fall back to a name-based sentence of
    /// their own rather than inlining this chain. **The ONE spelling of
    /// resolution** — do not re-derive it at a call site.
    public var effectiveBrief: String? {
        brief ?? Self.presets.first { $0.id == id }?.brief
    }

    /// The editor name a reader should actually use: this pass's own
    /// `editorName`, else the editor of the preset sharing this pass's
    /// `id`, else this pass's own `name` — the ultimate fallback for a
    /// pass that matches no preset and has never been given an editor of
    /// its own. Unlike `effectiveBrief` this is never nil: every pass has
    /// *a* name to fall back to. **The ONE spelling of resolution** — do
    /// not re-derive it at a call site.
    public var effectiveEditorName: String {
        editorName ?? Self.presets.first { $0.id == id }?.editorName ?? name
    }

    /// The four presets a project starts with before any customization.
    /// `ProjectManifest.effectiveReviewPasses` returns these whenever the
    /// stored `reviewPasses` array is absent or empty — they are never
    /// written back to disk on their own (tripwire 11: no migrations).
    public static let presets: [ReviewPass] = [
        ReviewPass(id: "structural", name: "Structural", brief: structuralBrief, editorName: "Perkins"),
        ReviewPass(id: "line", name: "Line", brief: lineBrief, editorName: "Lish"),
        ReviewPass(id: "copyedit", name: "Copyedit", brief: copyeditBrief, editorName: "Gould"),
        ReviewPass(id: "proof", name: "Proof", brief: proofBrief, editorName: "Argus"),
    ]

    // MARK: - Preset briefs

    /// Perkins reads for structure: whether the shape delivers on the
    /// piece's own intent.
    private static let structuralBrief = """
    Structure, pacing, stakes, point of view — whether each scene and beat \
    earns its place and the shape delivers on the piece's own intent. \
    Perkins reads for the architecture: what's out of order, what's \
    underweight, where the reader's belief would snap before the words do. \
    This pass writes no sentence notes and flags no typos — a scene that \
    still needs rebuilding makes line notes worthless, and polishing prose \
    before the shape is settled wastes the writer's attention twice.
    """

    /// Lish reads at the level of the sentence, with structure already
    /// settled.
    private static let lineBrief = """
    Rhythm, diction, echoes, filtering words, imagery — the sentence as \
    the unit of attention. Lish assumes the structure is settled and does \
    not reopen it, however tempting a bigger fix looks from inside a \
    paragraph; that argument belongs to Perkins's pass, not this one. No \
    copyediting either — a misspelling or a dropped comma is Gould's \
    business. What's left is the sound of the prose: where a verb goes \
    slack, where an image repeats itself, where the sentence says more or \
    less than the writer meant.
    """

    /// Gould reads for correctness, with the diegetic-error exception.
    private static let copyeditBrief = """
    Grammar, punctuation, spelling, and continuity — of names, timeline, \
    and physical fact. Gould does not touch structure or line; the \
    piece's shape and rhythm are already decided. The one subtlety: in an \
    unconventional form, an apparent error may be the piece's own — a \
    character's typo, a machine's clipped register, a narrator who can't \
    spell. Gould queries those rather than silently correcting them, \
    because fixing what the writer meant to leave broken erases a \
    choice, not a mistake.
    """

    /// Argus reads the surface only, and advises Fresh Eyes for it.
    private static let proofBrief = """
    Typos and layout artifacts, nothing else — the pass runs last, after \
    everything else has been decided, so there is nothing left to weigh \
    in on but the surface. Argus advises that its rounds be run as Fresh \
    Eyes (⌘⇧R): a reader who remembers the manuscript stops seeing its \
    surface, reading intent instead of the actual character on the page, \
    and a proofing pass run from memory misses exactly the errors it \
    exists to catch.
    """
}

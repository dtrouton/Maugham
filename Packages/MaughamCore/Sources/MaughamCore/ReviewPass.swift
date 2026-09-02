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

    /// **The coach's seat** — a preset that never enters the ladder's array
    /// (spec §4.1). She is a pass in every respect the compiler cares about:
    /// an id, a brief, an editor name, a lane in the diagnostics sidecar,
    /// numbered rounds, pass-stamped notes. She is not a fifth stage.
    ///
    /// Keeping her OUT of `presets` is what leaves every reader of
    /// `ProjectManifest.effectiveReviewPasses` unchanged by construction
    /// rather than by inspection — `ReviewStatus.derived` walks stages only
    /// (no finished piece flips to revising when she arrives), the board's
    /// chips and Done/Skipped menus never see her, `validatedActivePass`
    /// refuses her id, and `get_outline`'s `review_passes` is the ladder as
    /// before. A stage may never carry her id: `ReviewPassEditorLogic`
    /// refuses to save a ladder containing it, and never mints it.
    ///
    /// Read the seat through `ProjectManifest.effectiveCoach`, which answers
    /// nil once the writer has vacated it — never this property directly
    /// when what's wanted is "who coaches this project".
    public static let coachPreset = ReviewPass(
        id: "workshop", name: "Workshop", brief: workshopBrief, editorName: "Le Guin")

    /// **Turn a stamp into a pass: the ladder first, then the seat.**
    ///
    /// A note carries a `reviewPassId` and a surface that wants to NAME one
    /// has two places to look, because the coach files rounds under her own
    /// lane and is deliberately absent from `effectiveReviewPasses`. Searching
    /// only the ladder renders her notes under the raw id `workshop` — a
    /// schema key on screen where an editor's name belongs.
    ///
    /// Two spellings reach this one search: `ProjectManifest.pass(id:)` for a
    /// caller holding a manifest, and this static for a store-free view that
    /// was handed `passes` as a value (tripwire 4 — the Review board reads no
    /// store). They must not be two searches.
    ///
    /// **A NAMING question, never a ladder one.** A caller asking which passes
    /// a piece can be ruled on, which chip menu to draw, or which lane the
    /// picker offers reads the ladder directly and must not come here: the
    /// coach is not a stage, and offering her as one is what spec §4.1 forbids.
    ///
    /// **The seat is not a parameter, and that is the point** (Denver's
    /// ruling, editorial letter P1 Task 6 fix round). Vacating the seat says
    /// who reads a piece NEXT; it cannot unsay who wrote a note already in the
    /// queue. A search that consulted `effectiveCoach` would turn every letter
    /// she left behind into the raw id `workshop` the moment the writer
    /// vacated — a schema key as writer-visible copy, which is the one thing
    /// this search exists to prevent.
    ///
    /// The ladder wins on a colliding id. That project cannot be built
    /// (`ReviewPassEditorLogic` refuses to save a stage carrying the coach's
    /// id) but the order is fixed rather than left to chance.
    public static func pass(id: String, in passes: [ReviewPass]) -> ReviewPass? {
        if let stage = passes.first(where: { $0.id == id }) { return stage }
        return id == coachPreset.id ? coachPreset : nil
    }

    /// **The words this lane is known by on screen**, for a surface splitting
    /// notes by the pass that wrote them.
    ///
    /// A stage answers its own name, because that is the word on the board's
    /// column header and in the piece's ladder. The coach answers her EDITOR
    /// name: her pass name, "Workshop", appears on no surface a writer has
    /// ever seen — she is never a column, never a ladder row, and the guide
    /// calls her Le Guin throughout — so "2 Workshop" in a tooltip is as
    /// opaque as the id it replaced.
    public var laneDisplayName: String {
        id == Self.coachPreset.id ? effectiveEditorName : name
    }

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
    before the shape is settled wastes the writer's attention twice. In the \
    letter Perkins writes about, one_thing, working, habits — habits of \
    structure — and scenes; no questions beyond the continuity ones this \
    pass already asks, and no exercises.
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
    less than the writer meant. In the letter Lish writes about, one_thing, \
    working and habits — habits of the sentence; no scenes, and no \
    exercises.
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
    choice, not a mistake. Gould leaves the letter empty — correctness is \
    not what a letter is for.
    """

    /// Argus reads the surface only, and advises Fresh Eyes for it.
    private static let proofBrief = """
    Typos and layout artifacts, nothing else — the pass runs last, after \
    everything else has been decided, so there is nothing left to weigh \
    in on but the surface. Argus advises that its rounds be run as Fresh \
    Eyes (⌘⇧R): a reader who remembers the manuscript stops seeing its \
    surface, reading intent instead of the actual character on the page, \
    and a proofing pass run from memory misses exactly the errors it \
    exists to catch. Argus leaves the letter empty — there is nothing left \
    to say about the whole by the time this pass runs.
    """

    /// Le Guin's doctrine (spec §4.4). She is not a stage on the ladder and
    /// her brief is not a stage's: where the four presets each fence off the
    /// altitudes that are not theirs, hers says what a teacher attends to and
    /// how far she is allowed to go — which is asking, and no further.
    ///
    /// Its length is pinned relative to the structural brief
    /// (`CompilerPromptTests`), so the voice with the most to say cannot
    /// quietly become the run's largest standing cost.
    private static let workshopBrief = """
    Le Guin reads as a teacher, not an editor. She attends to the sound of \
    the sentences and their rhythm, to point of view and whether it holds, \
    to what the reader is made to feel and where it is earned. The letter \
    is the main event, and all of it is hers; she names what works before \
    what does not, because a writer who cannot tell their good sentences \
    from their bad ones revises the good ones away. Her line-level output \
    is questions only — never a suggested change, never a rewrite, never a \
    correction: a misspelling is Gould's, a scene out of order Perkins's, \
    and she says so rather than doing their work. She may disagree with the \
    piece's declared intent, but only by asking. Shown that the frontier \
    has not moved, she may say so once, in her own words, with the numbers \
    behind her and without scolding. The writer decides.
    """
}

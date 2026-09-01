import Foundation

/// Which of the v2 contract's sections a note came out of (spec §5). The
/// enumeration is the whole vocabulary: v2 has no severity, and the section a
/// note came from is the only classification it carries.
///
/// **`nil` is meaningful and is not a fourth case.** It marks a record a v1
/// run wrote, before the sections existed — `DiagnosticsStore.load` drops
/// those as superseded, so a nil `kind` never survives a relaunch.
enum DiagnosticKind: String, Codable, Sendable {
    /// A declared clause the wet ink pulls against. Carries `clauseQuote`.
    case conformanceStrain
    /// A question about an established fact or rule. Carries `clauseQuote`
    /// (the schema's `cites`).
    case continuity
    /// What happened in the reading itself. Its `category` is the schema's
    /// two-valued `kind` (`dream_break` / `belief`).
    case readerReport
    /// A question the sixth section's editorial letter asked (spec §3.2).
    /// Carries neither a clause nor a category: it is identified by the
    /// paragraph it names and by being the letter's, which is exactly why it
    /// is a kind of its own — a coach's question and a continuity question
    /// about one paragraph are two findings, and one fingerprint for both
    /// would have the mint's dedupe silently discard the second.
    ///
    /// **It never reaches the sidecar.** `SectionedOutcome.sidecarDiagnostics`
    /// keeps conformance strains alone; this kind exists to carry a letter
    /// question as far as `CompilerNote`, which turns it into a `.query`.
    case letterQuestion
}

/// One note the compiler raised against a document, from the newest
/// `CompilerRun` that has not yet been superseded or dismissed.
///
/// `anchor == nil` marks a note with no `¶` to track (e.g. "the outline
/// promised a scene that never got written"). An anchored diagnostic goes
/// stale the moment its paragraph's text changes; `DiagnosticsStore.live` is
/// what tells the two apart. A v2 note's anchor is its FIRST resolving ref,
/// so that one staleness rule keeps working unchanged — `refs` are display,
/// never liveness.
struct Diagnostic: Identifiable, Codable, Equatable, Sendable {
    let id: String                 // ULID
    let docId: String
    let anchor: Anchor?            // nil = no ¶ to track
    struct Anchor: Codable, Equatable, Sendable {
        let paragraphId: String
        let anchorText: String
    }

    /// One paragraph a note points at, and the words the writer will see in
    /// its place. **No surface ever renders `paragraphId`** — the whole point
    /// of v2's `refs` is that the writer reads their own prose rather than a
    /// four-character token (spec §5, requirement 3).
    ///
    /// `excerpt` is captured AT INGEST from live text, on `Anchor.anchorText`'s
    /// discipline: it is what the paragraph said when the note landed, never
    /// text the model echoed back.
    struct Ref: Codable, Equatable, Sendable {
        let paragraphId: String
        let excerpt: String
    }

    let body: String
    /// v2 mints no free-form tag (spec §5: "removed from the shipped design").
    /// The one value that still lands here is the reader section's own
    /// schema-pinned kind — `dream_break` or `belief` — which is content, not
    /// a severity. `nil` on every other v2 note; free-form on v1 records.
    let category: String?
    let runId: String

    // The v2 fields. All optional and all appended, so a v1 sidecar decodes
    // through the synthesised `decodeIfPresent` without a hand-written
    // initializer and every v1 construction site still compiles.

    /// Which section raised this. `nil` = a v1 record; see `DiagnosticKind`.
    var kind: DiagnosticKind?
    /// Every paragraph the note points at, in the order the model gave them.
    /// `anchor` is the first of these; the rest are display-only.
    var refs: [Ref]?
    /// The writer's own words this note is measured against — a conformance
    /// strain's `clause_quote`, or a continuity question's `cites`. One field
    /// for both because they are the same thing wearing two schema names, and
    /// a second field would be a second spelling to keep in step.
    var clauseQuote: String?
}

/// One compiler pass against a document: what it checked against, and the
/// op-log position it checked as of. `lastOpId` is the delta marker: the next
/// run diffs from here to describe what's new since.
struct CompilerRun: Codable, Equatable, Sendable {
    let id: String
    let at: Date
    let model: String
    /// The delta marker AFTER this run. `var` because a later run can advance
    /// it without replacing anything — see `DiagnosticsStore.advanceMarker`.
    var lastOpId: String?
    let deltaSummary: String       // e.g. "3 new, 2 revised ¶"
    let intentSnapshot: String?    // what the run checked against
    /// How many notes this run raised that Maugham could not place —
    /// `DiagnosticIngest.SectionedOutcome.droppedDangling`, carried rather
    /// than counted and dropped.
    ///
    /// **It is the difference between a clean bill and a silent one.** A run
    /// whose every note named a paragraph that has since changed accepts
    /// nothing, and a pane reading only `accepted.isEmpty` puts the seal and
    /// "Nothing to flag." over a check that did flag things. The compiler
    /// looked, spoke, and was mistranscribed; the surface says so.
    var droppedDangling: Int = 0

    /// Every clause this run checked and how each fared — the conformance
    /// summary the pane leads with (spec §5's first section).
    ///
    /// **On the run rather than beside the notes, because most of it produces
    /// no note at all.** A clause that holds and a clause the delta is silent
    /// about are both real answers the writer wants to see, and neither is a
    /// `Diagnostic`; only a strain is. Keeping the whole list here means the
    /// summary and the notes are superseded together by the next run, which is
    /// the one thing that must never come apart — a summary from run N over run
    /// N+1's notes reads as a check that was never made.
    ///
    /// `nil` marks a record written before the sections existed, exactly as
    /// `Diagnostic.kind == nil` does. Task 4 owns this field's own suite; it is
    /// here because the run that writes it is this task's.
    ///
    /// **This one run's snapshot is also `DiagnosticsStore.replace`'s source
    /// for the drift ring** (`DiagnosticsStore.clauseStatusHistory`,
    /// `DriftDetector`): every non-`nil` value here is appended there,
    /// oldest dropped past `DiagnosticsStore.clauseHistoryDepth`, so a
    /// pattern across runs survives this field's own supersession.
    var clauseStatuses: [DiagnosticIngest.ClauseStatus]?

    /// How many reader reports this run discarded over the schema's cap of
    /// three. `nil` marks a record written before the reader section existed.
    /// The run record carries it so the pane can say how many the model
    /// over-reported; the register never shows the truncation — the schema's
    /// enforcement is the cap of three accepted, not a count of the rest.
    var truncatedReader: Int?

    // The round stamps (M3-P3 §6). All four are optional and all four are
    // written by the run at the keystroke; a run made with no review pass
    // active carries `passId == nil` and `round == nil`, which is an ordinary
    // M2 run rather than a degenerate round.

    /// The review pass the writer had active on this piece when the run
    /// started — the round's **comparison lane** (`SinceLastRound`'s decision
    /// 1). `nil` is the passless lane, which is a lane of its own.
    var passId: String?
    /// Which round of that pass this run is, counting from 1. `nil` on a
    /// passless run: nothing to number, and a number with no lane could not be
    /// compared against anything.
    var round: Int?
    /// Whether this round was read cold — the session retired and the whole
    /// piece re-read (⌘⇧R) rather than the delta since the marker.
    var freshEyes: Bool?
    /// The round's judgement of whether the draft has drifted from the
    /// declared intent. A `String` rather than an enum for the same reason
    /// `RoundFingerprint.kind` is: it is a model's verdict on a wire this
    /// build may outlive, and an unrecognised word must read as unrecognised
    /// rather than fail the sidecar.
    ///
    /// **Distinct from `DriftDetector`** (M2's clause-strain *pattern* across
    /// runs), which keeps its own meaning and its own pane line. This is the
    /// per-round judged verdict; never overload the bare word.
    var intentDriftVerdict: String?

    /// **How many notes this run put in the writer's queue** (M4 P1) — the
    /// continuity questions and reader reports it minted as annotations, after
    /// the dedupe dropped what was already open and after any that could not be
    /// placed failed their own append.
    ///
    /// **It exists so the pane cannot affirm a falsehood.** The sidecar now
    /// keeps conformance strains alone, so a run that raised three questions
    /// and no strain stores nothing here — and a surface reading only
    /// "were there diagnostics?" answers "Nothing to flag" over a check that
    /// flagged three things. `droppedDangling`'s reasoning, one milestone on
    /// and one direction over: that field says the run spoke and Maugham could
    /// not place it; this one says the run spoke and Maugham put it somewhere
    /// else.
    ///
    /// `nil` is "no mint has happened" — a preview (which mints nothing until
    /// its turn ends) and every record written before this field existed. `0`
    /// is a finished run that had nothing to mint, or whose every note was a
    /// duplicate of one already open.
    var mintedNotes: Int?

    /// **How many findings this run raised that the writer is already holding
    /// in ANOTHER pass's lane** (#42 F-H) — distinct findings the dedupe
    /// refused where **no lane holding them is this run's own**, counted by the
    /// mint at the one place it already compares fingerprints. Own-lane
    /// presence wins: one fingerprint can be held by two open notes at once
    /// (settle one, let the next lane re-raise it, reopen the first), and a
    /// finding standing in this run's own lane is the *persisting* case,
    /// already on the since-line — counting it here as well would say one
    /// finding is two. Per FINDING, not per matched note.
    ///
    /// **It exists because the since-line's three counts are lane-local and
    /// this case falls between them.** `SinceLastRound` reads only notes in the
    /// round's own lane, and the dedupe mints nothing for a cross-lane
    /// re-raise, so a Line round that engaged a question open in Structural
    /// read "0 resolved · 0 persisting · 0 new" — a check that did engage the
    /// piece, reported as one that found nothing in it.
    ///
    /// **Notes only, and only findings that HAVE a fingerprint.** The mint sees
    /// `SectionedOutcome.mintable` — continuity questions and reader reports —
    /// so a conformance strain re-raised across lanes is report-side and takes
    /// no part; and an anchorless craft note carries no fingerprint at all, so
    /// it is neither deduped nor counted here (`RoundFingerprint` has no
    /// discriminator to make one from).
    ///
    /// **Recorded is not the same as drawn, and three states record it with no
    /// since-line to carry it** (whole-branch review I2): round 1 of a lane
    /// (nothing behind it to be "since"), a Fresh Eyes round, and a passless
    /// run (no round number at all). Since that review the other two surfaces
    /// carry it — `RoundNarrative.freshEyesHeader` appends the same clause, and
    /// the Diagnostics pane's empty state says "Nothing new to flag." instead
    /// of sealing over it. The residual: a passless run that also raised a
    /// conformance strain draws a report rather than an empty state, so its
    /// count is stored and shown nowhere.
    ///
    /// `nil` is "no mint has happened", exactly as for `mintedNotes`: a preview
    /// and every record written before this field existed. `0` is a finished
    /// run that found nothing standing in another lane.
    var openInOtherLanes: Int?

    /// **The sixth section, P1** — one editorial letter, read as prose rather
    /// than a list of findings. `nil` marks a record written before the
    /// section existed, on the same convention as `clauseStatuses`.
    var letter: Letter?

    init(id: String, at: Date, model: String, lastOpId: String?,
         deltaSummary: String, intentSnapshot: String?, droppedDangling: Int = 0,
         clauseStatuses: [DiagnosticIngest.ClauseStatus]? = nil,
         truncatedReader: Int? = nil, passId: String? = nil, round: Int? = nil,
         freshEyes: Bool? = nil, intentDriftVerdict: String? = nil,
         mintedNotes: Int? = nil, openInOtherLanes: Int? = nil, letter: Letter? = nil) {
        self.id = id
        self.at = at
        self.model = model
        self.lastOpId = lastOpId
        self.deltaSummary = deltaSummary
        self.intentSnapshot = intentSnapshot
        self.droppedDangling = droppedDangling
        self.clauseStatuses = clauseStatuses
        self.truncatedReader = truncatedReader
        self.passId = passId
        self.round = round
        self.freshEyes = freshEyes
        self.intentDriftVerdict = intentDriftVerdict
        self.mintedNotes = mintedNotes
        self.openInOtherLanes = openInOtherLanes
        self.letter = letter
    }

    /// Hand-written for one field: a sidecar written before `droppedDangling`
    /// existed decodes as zero rather than failing the whole file. The
    /// synthesised decoder does not fall back to a property's default, and a
    /// throw here reads to the writer as a document that was never checked
    /// (`DiagnosticsStore.load` treats an undecodable file as empty).
    /// `clauseStatuses`, `truncatedReader` and the four round stamps need no
    /// such care — they are optional, so `decodeIfPresent` is what the
    /// synthesised decoder would have written anyway; they are spelled out
    /// here only because this initializer exists. **Every field this struct
    /// gains needs a line here**: the hand-written decoder does not consult a
    /// property's default, so a field added to the type and forgotten here
    /// decodes as an uninitialized-property compile error at best and, when
    /// it is non-optional, throws on every pre-existing sidecar.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decode(Date.self, forKey: .at)
        model = try c.decode(String.self, forKey: .model)
        lastOpId = try c.decodeIfPresent(String.self, forKey: .lastOpId)
        deltaSummary = try c.decode(String.self, forKey: .deltaSummary)
        intentSnapshot = try c.decodeIfPresent(String.self, forKey: .intentSnapshot)
        droppedDangling = try c.decodeIfPresent(Int.self, forKey: .droppedDangling) ?? 0
        clauseStatuses = try c.decodeIfPresent(
            [DiagnosticIngest.ClauseStatus].self, forKey: .clauseStatuses)
        truncatedReader = try c.decodeIfPresent(Int.self, forKey: .truncatedReader)
        passId = try c.decodeIfPresent(String.self, forKey: .passId)
        round = try c.decodeIfPresent(Int.self, forKey: .round)
        freshEyes = try c.decodeIfPresent(Bool.self, forKey: .freshEyes)
        intentDriftVerdict = try c.decodeIfPresent(
            String.self, forKey: .intentDriftVerdict)
        mintedNotes = try c.decodeIfPresent(Int.self, forKey: .mintedNotes)
        openInOtherLanes = try c.decodeIfPresent(Int.self, forKey: .openInOtherLanes)
        letter = try c.decodeIfPresent(Letter.self, forKey: .letter)
    }
}

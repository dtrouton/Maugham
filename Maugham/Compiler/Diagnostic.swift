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
    /// `DiagnosticIngest.Outcome.droppedDangling`, carried rather than counted
    /// and dropped.
    ///
    /// **It is the difference between a clean bill and a silent one.** A run
    /// whose every note named a paragraph that has since changed accepts
    /// nothing, and a pane reading only `accepted.isEmpty` puts the seal and
    /// "Nothing to flag." over a check that did flag things. The compiler
    /// looked, spoke, and was mistranscribed; the surface says so.
    var droppedDangling: Int = 0

    init(id: String, at: Date, model: String, lastOpId: String?,
         deltaSummary: String, intentSnapshot: String?, droppedDangling: Int = 0) {
        self.id = id
        self.at = at
        self.model = model
        self.lastOpId = lastOpId
        self.deltaSummary = deltaSummary
        self.intentSnapshot = intentSnapshot
        self.droppedDangling = droppedDangling
    }

    /// Hand-written for one field: a sidecar written before `droppedDangling`
    /// existed decodes as zero rather than failing the whole file. The
    /// synthesised decoder does not fall back to a property's default, and a
    /// throw here reads to the writer as a document that was never checked
    /// (`DiagnosticsStore.load` treats an undecodable file as empty).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decode(Date.self, forKey: .at)
        model = try c.decode(String.self, forKey: .model)
        lastOpId = try c.decodeIfPresent(String.self, forKey: .lastOpId)
        deltaSummary = try c.decode(String.self, forKey: .deltaSummary)
        intentSnapshot = try c.decodeIfPresent(String.self, forKey: .intentSnapshot)
        droppedDangling = try c.decodeIfPresent(Int.self, forKey: .droppedDangling) ?? 0
    }
}

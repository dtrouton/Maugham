import Foundation

/// One note the compiler raised against a document, from the newest
/// `CompilerRun` that has not yet been superseded or dismissed.
///
/// `anchor == nil` marks a **drift diagnostic** — pinned, with no `¶` to
/// track (e.g. "the outline promised a scene that never got written"). An
/// anchored diagnostic goes stale the moment its paragraph's text changes;
/// `DiagnosticsStore.live` is what tells the two apart.
struct Diagnostic: Identifiable, Codable, Equatable, Sendable {
    let id: String                 // ULID
    let docId: String
    let anchor: Anchor?            // nil = drift diagnostic (pinned, no ¶)
    struct Anchor: Codable, Equatable, Sendable {
        let paragraphId: String
        let anchorText: String
    }
    let body: String
    let category: String?          // free-form, display-only
    let runId: String
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

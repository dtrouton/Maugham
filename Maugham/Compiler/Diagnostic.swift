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
}

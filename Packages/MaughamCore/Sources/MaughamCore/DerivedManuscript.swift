import Foundation

/// The single sanctioned way to read a CLOSED manuscript document's content —
/// derived from the op log, NEVER the `.md`/`.fountain` file (ADR 0018). Open
/// docs use the live in-memory `Document`; everything else uses this.
///
/// Fully synchronous; no `Document` actor. Composes the existing primitives:
/// `OpLogStore.loadSyncMerged` (ADR 0012 partition-aware merge) →
/// `Deriver.deriveWithSequenceFallback` (op-log-only; legacy order synthesised
/// from the ops, never the file) → `Materializer.materialize`.
public enum DerivedManuscript {

    /// Anchored (materialised) manuscript text for `docId`, derived from the op
    /// log. Contains the inline `<!-- ¶id -->` anchors, exactly as autosave would
    /// write the `.md`. Empty string when the doc has no ops. THROWS when a
    /// history file is unreadable-yet-present (RULING-54): a closed-doc reader
    /// — MCP `read_document` included — must never hand back a manuscript
    /// silently shortened by a file it could not read.
    public static func materialize(forDocId docId: String, in projectURL: URL) throws -> String {
        let s = try derivedState(forDocId: docId, in: projectURL)
        return Materializer.materialize(paragraphs: s.paragraphs, sequence: s.sequence)
    }

    /// The derived `paragraphs` map + `sequence`, for callers that need them
    /// directly (task derivation, word count) without re-anchoring. Throws as
    /// `materialize` does.
    public static func derivedState(forDocId docId: String, in projectURL: URL) throws -> Deriver.DerivedState {
        Deriver.deriveWithSequenceFallback(
            ops: try OpLogStore.loadSyncMerged(forDocId: docId, in: projectURL))
    }
}

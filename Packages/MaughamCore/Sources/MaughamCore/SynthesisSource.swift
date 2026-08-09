import Foundation

/// Typed replacement for the prior `String?` field on `Op.Provenance`.
/// The raw values are the snake_case strings used on disk; existing op
/// logs decode without migration via RawRepresentable Codable.
///
/// `rewind` is new in milestone-history-rewind; the other three predate it.
public enum SynthesisSource: String, Codable, Equatable, Hashable, Sendable {
    case paragraphDeleted = "paragraph_deleted"
    case diskAtIngest = "disk_at_ingest"
    case useCloudResolution = "use_cloud_resolution"
    case rewind

    /// Ops synthesized by ⌘Z-undoing a History Rewind restore (or another
    /// compound undo that rebuilds document state): the restore-back plus its
    /// lifecycle compensations. Distinct from `.rewind` so HistoryPane can
    /// tell "the writer rewound" from "the writer undid a rewind".
    case undoRewind = "undo_rewind"

    /// RULING-33: a reject that beat an accept across a merge, carrying the
    /// inverse so the manuscript agrees with the status the log settled on.
    /// Written only by `Document.repairRejectedButSplicedAnnotations` after an
    /// op-log merge — nothing a writer does directly produces one, which is
    /// why it is stamped: the paragraph moved and no gesture of theirs moved
    /// it. Distinct from `.useCloudResolution` (the `.md` conflict path, which
    /// is about bytes on disk rather than a lifecycle race).
    case rejectConvergence = "reject_convergence"

    /// Cross-version forward-tolerance (ADR 0015): a synthesis source written
    /// by a newer build decodes to `.unknown` rather than throwing — which
    /// would quarantine the whole `Op` and silently drop the edits it carries.
    /// `synthesisSource` is forensic/provenance metadata (consumed only by the
    /// HistoryPane display, which already has `default:` arms), so an unknown
    /// cause degrades to a generic label, never to data loss.
    ///
    /// SCHEMA CONTRACT (ADR 0015, audit N4): **adding a case ⇒ bump
    /// `ProjectManifest.currentSchemaVersion`.** `decodeGuardingSchema` is the
    /// real protection; this tolerance is the within-version net. `.unknown`
    /// re-encodes LOSSILY as the literal `"unknown"`. Carried on `Op` (append-only
    /// log, not rewritten), so the lossy re-encode is benign here; the bump
    /// remains the discipline that keeps the gate honest.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SynthesisSource(rawValue: raw) ?? .unknown
    }
}

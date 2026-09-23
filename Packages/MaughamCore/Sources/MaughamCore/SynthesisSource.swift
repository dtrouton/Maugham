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

    /// **A crashed session's pending buffer, folded in by the LOAD** (signed op
    /// log P3b Task 3, handoff ruling 3). Written by both arms of
    /// `Document.load`'s recovery fold — the one that recovers TEXT and the one
    /// that recovers ORDER alone.
    ///
    /// One case for the two arms deliberately: the CAUSE is the same act —
    /// a buffer the last session did not get to spend — and what a reader needs
    /// to know is *the load wrote this, not a person*. Which half of the buffer
    /// survived is already legible from the op itself (`changes` empty, or not).
    ///
    /// **It is provenance and it changes no judgment.** `Permit.allows` is asked
    /// about a KIND (`PermitPartition.writtenOp` decodes nothing else), so the
    /// field cannot reach the permission table from either direction: on an
    /// author-signed line it is a note in the margin, and an assistant- or
    /// translator-signed ordinary `typingBurst` stays REFUSED whatever it says.
    /// `Permit.isALoadEmission` is deliberately NOT widened to `typingBurst` —
    /// a field the assistant writes is a field the assistant can write, and
    /// *MCP never mutates manuscript text* must not rest on its good manners.
    ///
    /// What it IS for: the release census (`LoadBurstCensus`) can tell the
    /// load's own bursts from a person's typing, and History can say which was
    /// which.
    case pendingRecovery = "pending_recovery"

    /// **The task-anchor splice's burst** (same task). `Document
    /// .rebuildTasksCache` mints inline `<!-- t-… -->` anchors and records them
    /// into the pending buffer; the next flush carries them. That burst is the
    /// derivation's own emission rather than anything the writer typed.
    ///
    /// Written only when the flushed changes are the splice's ALONE — a burst
    /// carrying the writer's own words through the same function stays
    /// unlabelled, because it IS the writer's words plus an anchor and calling
    /// the whole thing housekeeping would be the more dangerous of the two
    /// mistakes.
    ///
    /// Same non-judgment as `pendingRecovery` above, for the same reason.
    case anchorSplice = "anchor_splice"

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

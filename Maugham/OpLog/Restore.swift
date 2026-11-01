// Maugham/OpLog/Restore.swift
import Foundation
import MaughamCore

public enum Restore {
    public enum Scope: Equatable {
        case document
        case paragraph(String)
    }

    /// Build a checkpoint_restore op that turns `current` into `target` for the
    /// given scope. Returns nil when no changes are needed.
    public static func buildRestoreOp(
        current: Deriver.DerivedState,
        target: Deriver.DerivedState,
        scope: Scope,
        docId: String,
        device: String,
        session: String,
        sourceCheckpoint: String,
        synthesisSource: SynthesisSource? = nil
    ) -> Op? {
        let candidatePids: [String]
        switch scope {
        case .document:
            candidatePids = Array(Set(current.paragraphs.keys).union(target.paragraphs.keys))
        case .paragraph(let pid):
            candidatePids = [pid]
        }
        var changes: [Op.ParagraphChange] = []
        for pid in candidatePids {
            let curr = current.paragraphs[pid]
            let tgt = target.paragraphs[pid]
            guard curr != tgt, let next = tgt else { continue }
            changes.append(.init(paragraphId: pid, prior: curr, next: next))
        }
        guard !changes.isEmpty else { return nil }
        return Op(
            opId: ULID.generate(),
            docId: docId,
            at: Date(),
            device: device,
            session: session,
            kind: .checkpointRestore,
            changes: changes,
            sequence: nil,
            provenance: .init(
                sourceCheckpoint: sourceCheckpoint,
                synthesisSource: synthesisSource))
    }

    /// **The lines that reopen the accepts a checkpoint revert takes back**
    /// (#128 item 2, RULING-28): one changes-free `claudeAcceptRevert` per
    /// note in `stranded` (`RewindImpact.strandedAccepts(in:revertedBy:
    /// through:amendments:)`) — the full rewind's step-8 instrument, stamped
    /// with the checkpoint rather than `.rewind`. Built, never appended: the
    /// caller appends them behind the restore op they answer, and the writer
    /// census counts that caller (`manuscriptWriterCallSites`).
    static func strandedAcceptReverts(
        _ stranded: [RewindImpact.StrandedAccept],
        docId: String, device: String, session: String,
        sourceCheckpoint: String
    ) -> [Op] {
        stranded.map { note in
            Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .claudeAcceptRevert,
                changes: [],
                sequence: nil,
                provenance: Op.Provenance(
                    sessionId: session,
                    sourceCheckpoint: sourceCheckpoint,
                    sourceAnnotationId: note.annotationId))
        }
    }
}

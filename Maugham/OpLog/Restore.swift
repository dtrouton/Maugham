// Maugham/OpLog/Restore.swift
import Foundation

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
        sourceCheckpoint: String
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
            provenance: .init(sourceCheckpoint: sourceCheckpoint))
    }
}

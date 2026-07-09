import Foundation
import MaughamCore

/// Inverse-op factory for task undo — the Mac-side sibling of MaughamCore's
/// `AnnotationInverse`. Task types are Mac-only (the phone has no tasks
/// surface), so this lives in the Mac target rather than in Core.
///
/// Pure function; no I/O, no `UndoManager`. The caller captures `prior` — the
/// PRE-mutation `WriterTask` snapshot — before appending the forward op,
/// because task ops carry ONLY new values (no priors on `Op.Provenance`). The
/// inverse is reconstructed from that snapshot.
///
/// Returns `nil` for kinds with no op-level inverse.
public enum TaskInverse {
    public static func inverse(
        undoing kind: OpKind, prior: WriterTask,
        docId: String, device: String, session: String, sessionId: String?
    ) -> Op? {
        let inverseKind: OpKind
        let provenance: Op.Provenance
        switch kind {
        case .taskStatusChange:
            inverseKind = .taskStatusChange
            provenance = Op.Provenance(
                sessionId: sessionId, taskId: prior.id,
                taskStatus: prior.status.rawValue)
        case .taskPriorityChange:
            inverseKind = .taskPriorityChange
            provenance = Op.Provenance(
                sessionId: sessionId, taskId: prior.id,
                taskPriority: prior.priority)
        case .taskParentChange:
            inverseKind = .taskParentChange
            // "" is the clear-parent sentinel (Document+Tasks.swift:276 convention).
            provenance = Op.Provenance(
                sessionId: sessionId, taskId: prior.id,
                taskParentId: prior.parentTaskId ?? "")
        case .taskBodyEdit:
            inverseKind = .taskBodyEdit
            provenance = Op.Provenance(
                sessionId: sessionId, taskId: prior.id,
                taskBody: prior.body)
        case .taskCreate:
            // Undo a create by archiving. Carry body + kind so the deriver can
            // still synthesize an Archived-filter entry (archiveTask convention).
            inverseKind = .taskArchive
            provenance = Op.Provenance(
                sessionId: sessionId, taskId: prior.id,
                taskBody: prior.body, taskKind: prior.kind.rawValue)
        case .taskArchive:
            // Undo an archive by restoring the pre-archive status.
            inverseKind = .taskStatusChange
            provenance = Op.Provenance(
                sessionId: sessionId, taskId: prior.id,
                taskStatus: prior.status.rawValue)
        default:
            return nil
        }
        return Op(
            opId: ULID.generate(), docId: docId, at: Date(),
            device: device, session: session,
            kind: inverseKind, changes: [], sequence: nil,
            provenance: provenance)
    }
}

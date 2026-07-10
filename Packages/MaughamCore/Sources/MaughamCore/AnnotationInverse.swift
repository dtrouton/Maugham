import Foundation

/// The inverse-op factory for annotation lifecycle undo — the single place
/// that knows which compensating op undoes which resolution. Pure: no I/O,
/// no UndoManager (MaughamCore stays UndoManager-free). Consumed by the Mac
/// ⌘Z registrar AND the phone's Reopen action so neither reimplements the
/// decision (cross-surface contract, tripwire 19).
public enum AnnotationInverse {
    public enum Decline: Equatable, Sendable {
        case noInverse(OpKind)          // e.g. .claudeAccept — use claudeAcceptRevert instead
        case stateDrifted               // current status no longer matches what's being undone
    }
    public enum Outcome { case op(Op), declined(Decline) }

    /// Compensating reopen for undoing a resolution. `currentStatus == nil`
    /// means the annotation is currently withdrawn (absent from projection).
    public static func reopenOp(
        undoing kind: OpKind,
        annotationId: String,
        currentStatus: AnnotationStatus?,
        docId: String, device: String, session: String,
        appVersion: String? = nil, osVersion: String? = nil
    ) -> Outcome {
        // Which resolutions have a reopen inverse, and what current status
        // each expects. Accept is deliberately excluded: its inverse is
        // claudeAcceptRevert (v0.17.0), which also restores text.
        let expected: AnnotationStatus?
        switch kind {
        case .claudeReject:       expected = .rejected
        case .claudeArchive:      expected = .archived
        case .annotationWithdraw: expected = nil   // withdrawn = absent from projection
        default:                  return .declined(.noInverse(kind))
        }
        guard currentStatus == expected else { return .declined(.stateDrifted) }
        return .op(Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .annotationReopen, changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                sourceAnnotationId: annotationId,
                appVersion: appVersion,
                osVersion: osVersion)))
    }

    /// Compensating edit for undoing an annotationEdit: another edit carrying
    /// the prior body (and prior suggested replacement, when present).
    public static func editRevertOp(
        annotationId: String,
        priorBody: String,
        priorSuggested: (paragraphId: String, prior: String?, next: String)?,
        authorSourceKind: String?, authorDisplayName: String?, authorCollaboratorId: String?,
        docId: String, device: String, session: String
    ) -> Op {
        let changes: [Op.ParagraphChange] = priorSuggested.map {
            [.init(paragraphId: $0.paragraphId, prior: $0.prior, next: $0.next)]
        } ?? []
        return Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .annotationEdit, changes: changes, sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                annotationBody: priorBody,
                sourceAnnotationId: annotationId,
                authorSourceKind: authorSourceKind,
                authorDisplayName: authorDisplayName,
                authorCollaboratorId: authorCollaboratorId))
    }
}

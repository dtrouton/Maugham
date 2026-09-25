import Foundation

/// The inverse-op factory for annotation lifecycle undo — the single place
/// that knows which compensating op undoes which resolution. Pure: no I/O,
/// no UndoManager (MaughamCore stays UndoManager-free). Consumed by the Mac
/// ⌘Z registrar AND the phone's Reopen action so neither reimplements the
/// decision (cross-surface contract, tripwire 19).
public enum AnnotationInverse {
    public enum Decline: Equatable, Sendable {
        case noInverse(OpKind)          // e.g. an accept that spliced text — use claudeAcceptRevert
        case stateDrifted               // current status no longer matches what's being undone
    }
    public enum Outcome { case op(Op), declined(Decline) }

    /// Compensating reopen for undoing a resolution. `currentStatus == nil`
    /// means the annotation is currently withdrawn (absent from projection).
    ///
    /// **`acceptSplicedManuscriptText` is read by the `.claudeAccept` arm and
    /// by nothing else, and its default is the dangerous answer on purpose**
    /// — a caller that has not thought about the distinction declines, exactly
    /// as every caller did before this parameter existed. Accepting a
    /// *suggestion* rewrites the paragraph, and its inverse has to restore
    /// that prose (`claudeAcceptRevert`, v0.17.0); a bare reopen there would
    /// leave the manuscript rewritten with the note open again, which is the
    /// reason accept was excluded outright until 2026-08-18. Accepting a
    /// comment, a query or a craft note moves no text at all — the accept op
    /// carries no `changes` — so the reopen IS the whole inverse. Only the
    /// caller can see which kind it is holding, so the caller says.
    public static func reopenOp(
        undoing kind: OpKind,
        annotationId: String,
        currentStatus: AnnotationStatus?,
        acceptSplicedManuscriptText: Bool = true,
        docId: String, device: String, session: String,
        appVersion: String? = nil, osVersion: String? = nil
    ) -> Outcome {
        // Which resolutions have a reopen inverse, and what current status
        // each expects.
        let expected: AnnotationStatus?
        switch kind {
        case .claudeReject:       expected = .rejected
        case .claudeArchive:      expected = .archived
        case .annotationStet:     expected = .stetted
        case .annotationWithdraw: expected = nil   // withdrawn = absent from projection
        case .claudeAccept:
            guard !acceptSplicedManuscriptText else { return .declined(.noInverse(kind)) }
            expected = .accepted
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
    ///
    /// Takes no collaborator id: the revert is a NEW edit, not a restoration
    /// of the original op's own field, and `author_collaborator_id` is decoded
    /// and never written (P3 spec §8). What it is stamped with is only what
    /// the caller passes — `device:` is the Document's own (the actor it was
    /// loaded as, on the Mac that undid it), not a record of which hand
    /// pressed ⌘Z — and, like every line, it is attributed to the key that
    /// signs it (RULING-55). `authorSourceKind`/`authorDisplayName` are the
    /// caller's label for the note's author, carried as given.
    public static func editRevertOp(
        annotationId: String,
        priorBody: String,
        priorSuggested: (paragraphId: String, prior: String?, next: String)?,
        authorSourceKind: String?, authorDisplayName: String?,
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
                authorDisplayName: authorDisplayName))
    }

    /// Compensating triage for undoing an `annotationTriage`: another triage
    /// carrying the mark the note had BEFORE it. `priorMark: nil` means the
    /// note was untriaged, and the revert op carries no mark — which is how
    /// the deriver reads "back to untriaged", the same latest-op-wins rule
    /// that made the original triage stick.
    ///
    /// Never a reopen: triage resolved nothing, so there is nothing to reopen.
    /// This factory cannot decline — a triage is an overwrite, so drifting
    /// state changes what the revert lands on but never whether it is valid.
    public static func triageRevertOp(
        annotationId: String,
        priorMark: TriageMark?,
        docId: String, device: String, session: String
    ) -> Op {
        Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .annotationTriage, changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                sourceAnnotationId: annotationId,
                triageMark: priorMark?.rawValue))
    }
}

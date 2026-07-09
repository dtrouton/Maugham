import Foundation

public enum AnnotationDeriver {

    /// Build the annotation projection from an op log + current paragraph map.
    /// Pure function: same inputs → same output.
    public static func derive(
        ops: [Op],
        paragraphs: [String: String]
    ) -> [Annotation] {
        // 1. Index lifecycle ops by sourceAnnotationId; latest wins.
        var latestLifecycle: [String: Op] = [:]
        for op in ops where isLifecycleKind(op.kind) {
            guard let src = op.provenance?.sourceAnnotationId else { continue }
            if let prior = latestLifecycle[src] {
                if op.opId > prior.opId { latestLifecycle[src] = op }
            } else {
                latestLifecycle[src] = op
            }
        }

        // 1a. Author self-service: edits (latest-by-opId wins per target) and
        //     withdrawals (target dropped entirely). Both reference the
        //     creation op via `sourceAnnotationId`. The creation op is never
        //     mutated — these are separate append-only ops.
        var latestEdit: [String: Op] = [:]
        var withdrawn: Set<String> = []
        for op in ops {
            guard let src = op.provenance?.sourceAnnotationId else { continue }
            switch op.kind {
            case .annotationEdit:
                if let prior = latestEdit[src] {
                    if op.opId > prior.opId { latestEdit[src] = op }
                } else {
                    latestEdit[src] = op
                }
            case .annotationWithdraw:
                withdrawn.insert(src)
            default:
                break
            }
        }

        // 2. Walk creation ops; build annotations.
        var result: [Annotation] = []
        for op in ops {
            guard let kind = AnnotationKind.fromOpKind(op.kind) else {
                continue
            }
            // Withdrawn annotations are dropped from the derived set entirely
            // (the withdraw op stays in the log for audit/rewind).
            if withdrawn.contains(op.opId) { continue }

            let change = op.changes.first
            let paragraphId: String? = (kind == .craftNote)
                ? nil : change?.paragraphId
            let priorText = change?.prior

            // Author self-service edit (latest-by-opId) overrides the body and,
            // for a suggestedChange, the suggested replacement. An edit without
            // a suggested payload leaves the original suggestion intact.
            let edit = latestEdit[op.opId]
            let suggested: String? = {
                guard kind == .suggestedChange else { return nil }
                if let editNext = edit?.changes.first?.next { return editNext }
                return change?.next
            }()
            let body = edit?.provenance?.annotationBody
                ?? op.provenance?.annotationBody ?? ""

            let lifecycle = latestLifecycle[op.opId]
            let (status, userResponse, resolvedAt) = resolution(
                creation: op, lifecycle: lifecycle)

            let paragraphStale: Bool = {
                guard kind != .craftNote, let pid = paragraphId,
                      let captured = priorText else { return false }
                return paragraphs[pid] != captured
            }()

            // Author + span anchor are carried on the op's provenance; the span
            // is re-resolved against the live paragraph on every derive.
            let prov = op.provenance
            let author = prov?.authorSourceKind
                .flatMap { AnnotationAuthor.SourceKind(rawValue: $0) }
                .map { AnnotationAuthor(sourceKind: $0, displayName: prov?.authorDisplayName ?? "", collaboratorId: prov?.authorCollaboratorId) }
            let span = prov?.spanQuote.map {
                SpanAnchor(quote: $0, prefix: prov?.spanPrefix ?? "", suffix: prov?.spanSuffix ?? "", posHint: prov?.spanPosHint ?? 0)
            }
            let resolvedSpanRange: Range<Int>?
            if let span, let pid = paragraphId, let text = paragraphs[pid] {
                // Re-find against DISPLAY text (anchors stripped) so the resolved
                // range is in display coordinates — matching the surface the span
                // was captured against and what the editor highlights. Idempotent
                // (no-op) when the paragraph has no inline anchors.
                let displayText = MarkdownDisplayFilter.stripTaskAnchorsInline(text)
                resolvedSpanRange = SpanAnchorResolver.resolve(anchor: span, in: displayText)
            } else {
                resolvedSpanRange = nil
            }
            let spanIsStale = (span != nil && resolvedSpanRange == nil)
            let isStale = paragraphStale || spanIsStale

            result.append(Annotation(
                id: op.opId,
                kind: kind,
                paragraphId: paragraphId,
                body: body,
                suggestedText: suggested,
                priorText: priorText,
                createdAt: op.at,
                createdBySession: op.provenance?.sessionId,
                status: status,
                userResponse: userResponse,
                resolvedAt: resolvedAt,
                isStale: isStale,
                author: author,
                span: span,
                resolvedSpanRange: resolvedSpanRange))
        }
        // Newest first by createdAt; tie-break by op_id (descending) for
        // stable ordering of same-instant ops.
        result.sort { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id > b.id
        }
        return result
    }

    // MARK: - Helpers

    private static func isLifecycleKind(_ kind: OpKind) -> Bool {
        switch kind {
        case .claudeAccept, .claudeReject, .claudeArchive, .claudeAcceptRevert: return true
        default: return false
        }
    }

    private static func resolution(
        creation: Op, lifecycle: Op?
    ) -> (AnnotationStatus, String?, Date?) {
        guard let lifecycle else {
            return (.open, creation.provenance?.userResponse, nil)
        }
        if lifecycle.kind == .claudeAcceptRevert {
            return (.open, creation.provenance?.userResponse, nil)
        }
        let status: AnnotationStatus = {
            switch lifecycle.kind {
            case .claudeAccept:  return .accepted
            case .claudeReject:  return .rejected
            case .claudeArchive: return .archived
            default:             return .open
            }
        }()
        return (status, lifecycle.provenance?.userResponse, lifecycle.at)
    }
}

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

        // 2. Walk creation ops; build annotations.
        var result: [Annotation] = []
        for op in ops {
            guard let kind = AnnotationKind.fromOpKind(op.kind) else {
                continue
            }
            let change = op.changes.first
            let paragraphId: String? = (kind == .craftNote)
                ? nil : change?.paragraphId
            let priorText = change?.prior
            let suggested: String? = (kind == .suggestedChange)
                ? change?.next : nil
            let body = op.provenance?.annotationBody ?? ""

            let lifecycle = latestLifecycle[op.opId]
            let (status, userResponse, resolvedAt) = resolution(
                creation: op, lifecycle: lifecycle)

            let isStale: Bool = {
                guard kind != .craftNote, let pid = paragraphId,
                      let captured = priorText else { return false }
                return paragraphs[pid] != captured
            }()

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
                isStale: isStale))
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
        case .claudeAccept, .claudeReject, .claudeArchive: return true
        default: return false
        }
    }

    private static func resolution(
        creation: Op, lifecycle: Op?
    ) -> (AnnotationStatus, String?, Date?) {
        guard let lifecycle else {
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

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
        for op in ops {
            guard op.kind == .annotationEdit,
                  let src = op.provenance?.sourceAnnotationId else { continue }
            if let prior = latestEdit[src] {
                if op.opId > prior.opId { latestEdit[src] = op }
            } else {
                latestEdit[src] = op
            }
        }

        // 1a2. The latest rejection per target, for RULING-31's reason
        //      history: a reopened note keeps its most recent rejection reason
        //      visible as part of its record.
        var latestReject: [String: Op] = [:]
        for op in ops {
            guard op.kind == .claudeReject,
                  let src = op.provenance?.sourceAnnotationId else { continue }
            if let prior = latestReject[src] {
                if op.opId > prior.opId { latestReject[src] = op }
            } else {
                latestReject[src] = op
            }
        }

        // 1b. Withdraw / reopen: latest-by-opId wins between the two per
        // target (a reopen newer than a withdraw cancels the withdrawal; a
        // later withdraw re-drops it). `annotationReopen` here is the
        // withdraw-compensation path — the reject/archive-compensation path
        // is handled by `isLifecycleKind` + `resolution` below.
        var withdrawState: [String: Op] = [:]
        for op in ops {
            guard op.kind == .annotationWithdraw || op.kind == .annotationReopen,
                  let src = op.provenance?.sourceAnnotationId else { continue }
            if let prior = withdrawState[src] {
                if op.opId > prior.opId { withdrawState[src] = op }
            } else {
                withdrawState[src] = op
            }
        }
        let withdrawn = Set(withdrawState.filter { $0.value.kind == .annotationWithdraw }.keys)

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

            // Translation-pass language tag — query-only. add_query encodes its
            // whole Params into `toolArgs` provenance, so decode it back out
            // here; malformed/absent toolArgs → nil, never throws.
            let language: String? = (kind == .query)
                ? decodeToolArgsLanguage(prov?.toolArgs) : nil

            // RULING-31: a reopened note carries its most recent PRIOR
            // rejection's reason as history (only while open — a live
            // resolution's own userResponse takes the stage otherwise).
            let previousRejectionReason: String? = {
                guard status == .open,
                      let lifecycle, lifecycle.kind == .annotationReopen,
                      let reject = latestReject[op.opId],
                      reject.opId < lifecycle.opId else { return nil }
                return reject.provenance?.userResponse
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
                isStale: isStale,
                author: author,
                span: span,
                resolvedSpanRange: resolvedSpanRange,
                language: language,
                previousRejectionReason: previousRejectionReason))
        }
        // Newest first by createdAt; tie-break by op_id (descending) for
        // stable ordering of same-instant ops.
        result.sort { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id > b.id
        }
        return result
    }

    /// A withdrawn (writer-deleted) annotation, as the Deleted view lists it
    /// (RULING-34: delete is normalised for annotations too — recoverable
    /// later, not gone at one keystroke's mercy). Deliberately NOT a fifth
    /// `AnnotationStatus` case: withdrawal is absence from the projection, and
    /// widening the status enum would ripple through every filter, surface and
    /// wire format for what is a listing concern.
    public struct WithdrawnAnnotation: Equatable, Sendable {
        public let id: String
        public let kind: AnnotationKind
        public let body: String
        public let withdrawnAt: Date
    }

    /// The annotations whose latest withdraw/reopen op is a WITHDRAW — the
    /// Deleted view's content, newest withdrawal first. Body honours the
    /// latest self-service edit, same as the live projection.
    public static func deriveWithdrawn(ops: [Op]) -> [WithdrawnAnnotation] {
        var latestEdit: [String: Op] = [:]
        var withdrawState: [String: Op] = [:]
        for op in ops {
            guard let src = op.provenance?.sourceAnnotationId else { continue }
            switch op.kind {
            case .annotationEdit:
                if latestEdit[src].map({ op.opId > $0.opId }) ?? true { latestEdit[src] = op }
            case .annotationWithdraw, .annotationReopen:
                if withdrawState[src].map({ op.opId > $0.opId }) ?? true { withdrawState[src] = op }
            default:
                break
            }
        }
        var result: [WithdrawnAnnotation] = []
        for op in ops {
            guard let kind = AnnotationKind.fromOpKind(op.kind),
                  let latest = withdrawState[op.opId],
                  latest.kind == .annotationWithdraw else { continue }
            let body = latestEdit[op.opId]?.provenance?.annotationBody
                ?? op.provenance?.annotationBody ?? ""
            result.append(WithdrawnAnnotation(
                id: op.opId, kind: kind, body: body, withdrawnAt: latest.at))
        }
        result.sort { $0.withdrawnAt > $1.withdrawnAt }
        return result
    }

    /// The one withdrawn-or-not rule, shared by every surface (tripwire 19):
    /// an annotation is withdrawn iff the LATEST of its withdraw/reopen ops by
    /// opId is a withdraw — the same latest-first resolution `derive` applies.
    /// The Mac's accept guard and the phone's writer both call this; neither
    /// restates it.
    public static func isWithdrawn(annotationId: String, in ops: [Op]) -> Bool {
        var latest: Op?
        for op in ops {
            guard op.kind == .annotationWithdraw || op.kind == .annotationReopen,
                  op.provenance?.sourceAnnotationId == annotationId else { continue }
            if latest.map({ op.opId > $0.opId }) ?? true { latest = op }
        }
        return latest?.kind == .annotationWithdraw
    }

    // MARK: - Helpers

    /// The subset of an annotation op's `toolArgs` we read back — the
    /// translation-pass language tag written by add_query.
    private struct ToolArgsLanguage: Decodable { let language: String? }

    /// Decode the `language` tag out of an op's `toolArgs` JSON string, if
    /// present. Absent or malformed JSON → nil (never throws).
    private static func decodeToolArgsLanguage(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(ToolArgsLanguage.self, from: data))?.language
    }

    private static func isLifecycleKind(_ kind: OpKind) -> Bool {
        switch kind {
        case .claudeAccept, .claudeReject, .claudeArchive, .claudeAcceptRevert,
             .annotationReopen:
            return true
        default: return false
        }
    }

    private static func resolution(
        creation: Op, lifecycle: Op?
    ) -> (AnnotationStatus, String?, Date?) {
        guard let lifecycle else {
            return (.open, creation.provenance?.userResponse, nil)
        }
        if lifecycle.kind == .claudeAcceptRevert || lifecycle.kind == .annotationReopen {
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

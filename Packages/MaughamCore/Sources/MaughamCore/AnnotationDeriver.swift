import Foundation

public enum AnnotationDeriver {

    /// Build the annotation projection from an op log + current paragraph map.
    /// Pure function: same inputs → same output.
    ///
    /// `amendments` is P3a Task 6's *whose annotation is it* rule, and its
    /// default is the pre-P3a behaviour — every edit, every withdrawal and
    /// every reopen stands. A reopen is judged twice (ruling P): by ownership
    /// where it undoes a withdrawal, by author rights where it undoes a
    /// disposition. A caller holding a verified trust table passes
    /// `AnnotationAmendments.judged`; a caller with none (the phone, a rewind
    /// projection, a test) does not, and gets exactly what it always got.
    public static func derive(
        ops: [Op],
        paragraphs: [String: String],
        amendments: AnnotationAmendments = .honourEverything
    ) -> [Annotation] {
        let creations = creationOps(in: ops)
        // 1. Index lifecycle ops by sourceAnnotationId; latest wins.
        //
        // **A reopen is judged here as a DISPOSITION** (ruling P): in this
        // fold it cancels an archive, a rejection or a stet, which only author
        // rights may undo — never the same-person arm, so her own note the
        // root archived stays archived when she reopens it. The table lets a
        // reopen through on the reviewer row (`Permit.group`), because the
        // partition cannot see what it undoes; this is where that is decided.
        var latestLifecycle: [String: Op] = [:]
        for op in ops where isHonouredLifecycleOp(op, amendments: amendments) {
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
                  let src = op.provenance?.sourceAnnotationId,
                  honours(op, src, creations, amendments) else { continue }
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

        // 1b. Withdraw / reopen: the latest HONOURED op of the two per target
        // decides (a reopen newer than a withdraw cancels the withdrawal; a
        // later withdraw re-drops it). `annotationReopen` here is the
        // withdraw-compensation path — the reject/archive-compensation path
        // is the lifecycle fold above. Both kinds are judged by the ownership
        // rule, and a reopen against the WITHDRAWAL it undoes (ruling P,
        // Ruling D): see `withdrawalStates`.
        let withdrawState = withdrawalStates(
            in: ops, creations: creations, amendments: amendments)
        let withdrawn = Set(withdrawState.filter { $0.value.kind == .annotationWithdraw }.keys)

        // 1c. Triage (M3 P2): the latest `annotationTriage` op per target
        //     carries the mark. Deliberately NOT folded into
        //     `latestLifecycle` — a triaged note is still open, so a triage
        //     must never displace a resolution, nor be displaced by one.
        var latestTriage: [String: Op] = [:]
        for op in ops {
            guard op.kind == .annotationTriage,
                  let src = op.provenance?.sourceAnnotationId else { continue }
            if latestTriage[src].map({ op.opId > $0.opId }) ?? true {
                latestTriage[src] = op
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
            let author = Self.author(of: op)
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

            // Translation-pass language tag. `add_query` encodes its whole
            // Params into `toolArgs` provenance, so decode it back out here;
            // malformed/absent toolArgs → nil, never throws.
            //
            // **Queries AND craft notes**, because a translator's
            // whole-document question is a craft note: `addAnnotation` refuses
            // a `.query` with no anchor, so the one kind of translation
            // question that has no paragraph — "tú or usted throughout?" — can
            // only land as a `.craftNote`, and while the tag stopped at this
            // line that question was invisible to every reader that filters by
            // language. It was never re-briefed to a later round and never
            // counted in `translation_status.open_queries`, so a fresh session
            // asked it again, forever. No other craft note carries a
            // `language` key in its toolArgs (`add_craft_note`'s Params have
            // no such field; the compiler's mint writes no toolArgs at all),
            // so widening the decode tags exactly the notes that meant it.
            let language: String? = (kind == .query || kind == .craftNote)
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

            // The writer's triage mark (M3 P2) — parse-or-nil, mirroring the
            // no-`.unknown`-case reasoning on `TriageMark` itself: the mark is
            // a projection this deriver never re-encodes, so a raw value a
            // newer build wrote surfaces as untriaged here while staying
            // intact on the wire.
            let triage = latestTriage[op.opId]?.provenance?.triageMark
                .flatMap { TriageMark(rawValue: $0) }

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
                previousRejectionReason: previousRejectionReason,
                triage: triage,
                reviewPassId: prov?.reviewPassId,
                compilerRunId: prov?.compilerRunId,
                compilerRound: prov?.compilerRound,
                compilerFingerprint: prov?.compilerFingerprint,
                lessonHeading: prov?.compilerLessonHeading))
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
        /// Who made the note, as its creation op stamped it — so the Deleted
        /// view can offer Restore on the writer's OWN deleted note (ruling P;
        /// `AnnotationOwnership.isOwn(author:localName:)`).
        public let author: AnnotationAuthor?
        /// Who DELETED it, as the honoured withdraw op stamped it — Restore's
        /// question (controller Ruling D): she may undo her own Delete, and
        /// the root's Delete of her note is the root's.
        public let withdrawnBy: AnnotationAuthor?
    }

    /// The annotations whose latest withdraw/reopen op is a WITHDRAW — the
    /// Deleted view's content, newest withdrawal first. Body honours the
    /// latest self-service edit, same as the live projection.
    public static func deriveWithdrawn(
        ops: [Op], amendments: AnnotationAmendments = .honourEverything
    ) -> [WithdrawnAnnotation] {
        let creations = creationOps(in: ops)
        var latestEdit: [String: Op] = [:]
        for op in ops where op.kind == .annotationEdit {
            guard let src = op.provenance?.sourceAnnotationId,
                  honours(op, src, creations, amendments) else { continue }
            if latestEdit[src].map({ op.opId > $0.opId }) ?? true { latestEdit[src] = op }
        }
        let withdrawState = withdrawalStates(
            in: ops, creations: creations, amendments: amendments)
        var result: [WithdrawnAnnotation] = []
        for op in ops {
            guard let kind = AnnotationKind.fromOpKind(op.kind),
                  let latest = withdrawState[op.opId],
                  latest.kind == .annotationWithdraw else { continue }
            let body = latestEdit[op.opId]?.provenance?.annotationBody
                ?? op.provenance?.annotationBody ?? ""
            result.append(WithdrawnAnnotation(
                id: op.opId, kind: kind, body: body, withdrawnAt: latest.at,
                author: author(of: op), withdrawnBy: author(of: latest)))
        }
        result.sort { $0.withdrawnAt > $1.withdrawnAt }
        return result
    }

    /// The one withdrawn-or-not rule, shared by every surface (tripwire 19):
    /// an annotation is withdrawn iff the LATEST HONOURED of its
    /// withdraw/reopen ops by opId is a withdraw — the same walk `derive`
    /// applies (`withdrawalStates`).
    /// The Mac's accept guard and the phone's writer both call this; neither
    /// restates it.
    public static func isWithdrawn(
        annotationId: String, in ops: [Op],
        amendments: AnnotationAmendments = .honourEverything
    ) -> Bool {
        var creations: [String: Op] = [:]
        if let creation = ops.first(where: { $0.opId == annotationId }) {
            creations[annotationId] = creation
        }
        return withdrawalStates(
            in: ops, creations: creations, amendments: amendments,
            only: annotationId)[annotationId]?.kind == .annotationWithdraw
    }

    /// **Is this a lifecycle op the deriver honours?** — the lifecycle kinds,
    /// less a reopen that fails the DISPOSITION judgement (ruling P). The one
    /// predicate for every reader that walks the raw lifecycle ops of a
    /// stream (the Mac's rewind, its preview, the reject/splice repair): a
    /// reopen the fold does not honour never happened as far as the status
    /// goes, so a reader taking "the latest lifecycle op" must not see it.
    public static func isHonouredLifecycleOp(
        _ op: Op, amendments: AnnotationAmendments = .honourEverything
    ) -> Bool {
        guard isLifecycleKind(op.kind) else { return false }
        return op.kind != .annotationReopen || amendments.honoursAsDisposition(op)
    }

    /// **The latest honoured withdraw-or-reopen per target** — the one
    /// withdrawn-or-not walk behind `derive`, `deriveWithdrawn` and
    /// `isWithdrawn` (tripwire 19).
    ///
    /// Walked in opId order per target, because a reopen is judged against
    /// the WITHDRAWAL it undoes (ruling P, controller Ruling D): the latest
    /// honoured withdraw before it. The ownership rule (`honours`) is asked
    /// with that withdrawal standing where a creation usually stands, so a
    /// reopen is honoured from author rights, or from the same writer as the
    /// one who DELETED — she undoes her own Delete, and the root's Delete of
    /// her note stays the root's. A reopen with no honoured withdrawal before
    /// it cancels nothing and is skipped; under `.honourEverything` that
    /// leaves exactly the pre-P3a answer (the latest op wins).
    private static func withdrawalStates(
        in ops: [Op], creations: [String: Op], amendments: AnnotationAmendments,
        only: String? = nil
    ) -> [String: Op] {
        var byTarget: [String: [Op]] = [:]
        for op in ops where op.kind == .annotationWithdraw || op.kind == .annotationReopen {
            guard let src = op.provenance?.sourceAnnotationId,
                  only.map({ $0 == src }) ?? true else { continue }
            byTarget[src, default: []].append(op)
        }
        var out: [String: Op] = [:]
        for (src, list) in byTarget {
            var latest: Op?
            for op in list.sorted(by: { $0.opId < $1.opId }) {
                if op.kind == .annotationWithdraw {
                    guard honours(op, src, creations, amendments) else { continue }
                } else {
                    guard let withdrawal = latest,
                          withdrawal.kind == .annotationWithdraw,
                          creations[src] == nil
                            || amendments.honours(op, creation: withdrawal)
                    else { continue }
                }
                latest = op
            }
            out[src] = latest
        }
        return out
    }

    // MARK: - Helpers

    /// The author an op stamped — a creation's for the live projection and
    /// the Deleted view alike, and a withdrawal's for who deleted it.
    private static func author(of op: Op) -> AnnotationAuthor? {
        let prov = op.provenance
        return prov?.authorSourceKind
            .flatMap { AnnotationAuthor.SourceKind(rawValue: $0) }
            .map { AnnotationAuthor(sourceKind: $0, displayName: prov?.authorDisplayName ?? "", collaboratorId: prov?.authorCollaboratorId) }
    }

    /// Every annotation-CREATION op, by its own opId — which is the id an
    /// amendment names in `sourceAnnotationId`.
    ///
    /// Built once per derivation rather than searched per amendment: the
    /// ownership rule needs the creation op (its `device` is who made the
    /// note), and a project's queue walk runs this over every document.
    private static func creationOps(in ops: [Op]) -> [String: Op] {
        var out: [String: Op] = [:]
        for op in ops where AnnotationKind.fromOpKind(op.kind) != nil {
            if out[op.opId] == nil { out[op.opId] = op }
        }
        return out
    }

    /// Does this amendment stand? **An amendment naming a creation op this
    /// stream does not hold is left alone**, which is the pre-P3a answer and
    /// the only honest one: the note it amends is not in the projection
    /// either, so there is nothing to decide and nothing to protect.
    private static func honours(
        _ amendment: Op, _ sourceAnnotationId: String,
        _ creations: [String: Op], _ amendments: AnnotationAmendments
    ) -> Bool {
        guard let creation = creations[sourceAnnotationId] else { return true }
        return amendments.honours(amendment, creation: creation)
    }

    /// The subset of an annotation op's `toolArgs` we read back — the
    /// translation-pass language tag written by add_query.
    private struct ToolArgsLanguage: Decodable { let language: String? }

    /// Decode the `language` tag out of an op's `toolArgs` JSON string, if
    /// present. Absent or malformed JSON → nil (never throws).
    private static func decodeToolArgsLanguage(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(ToolArgsLanguage.self, from: data))?.language
    }

    /// Which op kinds settle (or re-open) an annotation. `internal` rather
    /// than `private` so the contract tests can pin membership directly — the
    /// list is the difference between a note leaving the queue and a note
    /// merely being marked, and `.annotationTriage`'s ABSENCE from it is as
    /// load-bearing as `.annotationStet`'s presence.
    static func isLifecycleKind(_ kind: OpKind) -> Bool {
        switch kind {
        case .claudeAccept, .claudeReject, .claudeArchive, .claudeAcceptRevert,
             .annotationReopen, .annotationStet:
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
            case .annotationStet: return .stetted
            default:             return .open
            }
        }()
        return (status, lifecycle.provenance?.userResponse, lifecycle.at)
    }
}

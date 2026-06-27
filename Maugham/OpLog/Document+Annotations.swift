import Foundation
import MaughamCore

extension Document {

    internal static func isAnnotationOpKind(_ kind: OpKind) -> Bool {
        switch kind {
        case .claudeComment, .claudeSuggestion, .claudeQuery, .claudeCraftNote,
             .claudeAccept, .claudeReject, .claudeArchive,
             .annotationEdit, .annotationWithdraw:
            return true
        default:
            return false
        }
    }

    // MARK: - Annotation read API

    public func annotations(
        filter: AnnotationFilter = AnnotationFilter()
    ) -> [Annotation] {
        if !_annotationsCacheValid {
            rebuildAnnotationsCache()
        }
        return _annotationsCache.filter { ann in
            if let kinds = filter.kinds, !kinds.contains(ann.kind) { return false }
            if let statuses = filter.statuses, !statuses.contains(ann.status) { return false }
            if let pid = filter.paragraphId, ann.paragraphId != pid { return false }
            return true
        }
    }

    internal func invalidateAnnotationsCache() {
        _annotationsCacheValid = false
        annotationsVersion &+= 1
    }

    private func rebuildAnnotationsCache() {
        _annotationsCache = AnnotationDeriver.derive(
            ops: _opLogMirror, paragraphs: paragraphs)
        _annotationsCacheValid = true
    }

    // MARK: - Annotation mutation API

    @discardableResult
    public func addAnnotation(
        kind: AnnotationKind,
        paragraphId: String?,
        body: String,
        suggestedText: String? = nil,
        prompt: String? = nil,
        toolArgs: String? = nil,
        span: SpanAnchor? = nil,
        author: AnnotationAuthor? = nil
    ) async throws -> String {
        let opKind: OpKind = {
            switch kind {
            case .comment:         return .claudeComment
            case .suggestedChange: return .claudeSuggestion
            case .query:           return .claudeQuery
            case .craftNote:       return .claudeCraftNote
            }
        }()
        // Validate the paragraph anchor before persisting. For paragraph-
        // scoped kinds (comment/query/suggested_change), the caller must
        // supply a paragraph_id that exists in the current sequence. A
        // stale id (from an old read_document response that the caller
        // didn't refresh after the user edited) would otherwise silently
        // persist as an orphan annotation with prior_text=null — the
        // staleness check has nothing to compare against, the annotation
        // can never be acted on meaningfully, and the row clutters the
        // history with no path to recovery.
        //
        // Throws a structured tool error (MCPError.paragraphNotFound) so
        // MCP clients receive a tools/call result with isError=true and a
        // machine-readable body `{"error":"paragraph_not_found",...}`
        // rather than a generic JSON-RPC failure they surface as "Tool
        // execution failed."
        if kind != .craftNote {
            guard let pid = paragraphId else {
                throw MCPError.paragraphNotFound(
                    paragraphId: "<nil>", currentCount: sequence.count)
            }
            if !sequence.contains(pid) {
                throw MCPError.paragraphNotFound(
                    paragraphId: pid, currentCount: sequence.count)
            }
            // sequence said pid is present but paragraphs map is missing
            // the text — defensive check for an internal inconsistency
            // that shouldn't happen with current code paths but would
            // otherwise persist as a null prior_text again.
            if paragraphs[pid] == nil {
                throw MCPError.priorTextCaptureFailed(paragraphId: pid)
            }
        }
        let changes: [Op.ParagraphChange] = {
            switch kind {
            case .craftNote:
                return []
            case .suggestedChange:
                guard let pid = paragraphId else { return [] }
                let prior = paragraphs[pid]
                return [.init(paragraphId: pid,
                              prior: prior,
                              next: Self.suggestionNext(
                                  prior: prior, span: span,
                                  suggestedText: suggestedText ?? ""))]
            case .comment, .query:
                guard let pid = paragraphId else { return [] }
                let prior = paragraphs[pid]
                return [.init(paragraphId: pid, prior: prior, next: "")]
            }
        }()
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: opKind, changes: changes, sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                prompt: prompt,
                toolArgs: toolArgs,
                annotationBody: body,
                authorSourceKind: author?.sourceKind.rawValue,
                authorDisplayName: author?.displayName,
                authorCollaboratorId: author?.collaboratorId,
                spanQuote: span?.quote,
                spanPrefix: span?.prefix,
                spanSuffix: span?.suffix,
                spanPosHint: span?.posHint))
        try await opStore.append(op)
        _opLogMirror.append(op)
        _hasAnyAnnotationOps = true
        invalidateAnnotationsCache()
        invalidateTasksCache()
        return op.opId
    }

    /// Create a human-authored annotation (review toolbar / collaborator
    /// review). Thin wrapper over `addAnnotation` that stamps the provenance
    /// author as `.human` with the reviewer's display name + optional
    /// collaborator id. Span-anchored to a sub-paragraph quote when supplied.
    @discardableResult
    public func addReviewerAnnotation(
        kind: AnnotationKind,
        paragraphId: String,
        span: SpanAnchor?,
        body: String,
        suggestedText: String? = nil,
        authorName: String,
        authorId: String? = nil
    ) async throws -> String {
        try await addAnnotation(
            kind: kind,
            paragraphId: paragraphId,
            body: body,
            suggestedText: suggestedText,
            span: span,
            author: AnnotationAuthor(
                sourceKind: .human,
                displayName: authorName,
                collaboratorId: authorId))
    }

    /// Build the `next` paragraph text for a suggested-change op. A SPAN-anchored
    /// (sub-paragraph) suggestion SPLICES: only the anchored span is replaced by
    /// `suggestedText`, leaving the rest of the paragraph intact. A paragraph-
    /// level suggestion (no span / empty quote / span no longer resolvable —
    /// e.g. the Claude/MCP `add_suggested_change` contract) replaces the WHOLE
    /// paragraph. Accept applies `next` as the full paragraph
    /// (`paragraphs[pid] = next`), so `next` must already be the complete
    /// intended paragraph — hence the splice happens here, at authoring time.
    static func suggestionNext(
        prior: String?, span: SpanAnchor?, suggestedText: String
    ) -> String {
        guard let prior, let span,
              let range = SpanAnchorResolver.resolve(anchor: span, in: prior)
        else { return suggestedText }
        let chars = Array(prior)
        return String(chars[..<range.lowerBound])
            + suggestedText
            + String(chars[range.upperBound...])
    }

    /// Reconstruct the sub-paragraph `SpanAnchor` an annotation op was created
    /// with, from its persisted provenance. Returns nil for a paragraph-level
    /// annotation (no span quote).
    static func spanAnchor(from provenance: Op.Provenance?) -> SpanAnchor? {
        guard let provenance,
              let quote = provenance.spanQuote, !quote.isEmpty else { return nil }
        return SpanAnchor(
            quote: quote,
            prefix: provenance.spanPrefix ?? "",
            suffix: provenance.spanSuffix ?? "",
            posHint: provenance.spanPosHint ?? 0)
    }

    /// Author self-service: edit YOUR OWN annotation's body (and, for a
    /// suggested change, the replacement text). Appends an `annotationEdit` op
    /// referencing the creation op via `sourceAnnotationId`; the creation op is
    /// never mutated (append-only). The deriver applies the latest edit by
    /// opId. Stamps the local human author identically to
    /// `addReviewerAnnotation` so the forensic record carries who edited it.
    ///
    /// Ownership is enforced at the UI layer (`AnnotationOwnership.isOwn`): the
    /// Edit affordance only appears on the reviewer's own rows. This method
    /// trusts that gate — there are no accounts in WF1-local.
    public func editReviewerAnnotation(
        id: String,
        newBody: String,
        newSuggestedText: String?,
        authorName: String,
        authorId: String? = nil
    ) async throws {
        // Carry the new suggested replacement through the same channel the
        // original suggestion uses: ParagraphChange.next. Only attach it when
        // the caller supplied one (editing a suggestion). A nil leaves the
        // original suggestion intact in the deriver. The span is reconstructed
        // from the creation op's provenance so an edited SPAN suggestion still
        // splices (replaces only the span) rather than the whole paragraph.
        let changes: [Op.ParagraphChange] = {
            guard let suggested = newSuggestedText,
                  let creation = _opLogMirror.first(where: { $0.opId == id }),
                  let pid = creation.changes.first?.paragraphId else { return [] }
            let prior = creation.changes.first?.prior
            return [.init(paragraphId: pid,
                          prior: prior,
                          next: Self.suggestionNext(
                              prior: prior,
                              span: Self.spanAnchor(from: creation.provenance),
                              suggestedText: suggested))]
        }()
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .annotationEdit, changes: changes, sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                annotationBody: newBody,
                sourceAnnotationId: id,
                authorSourceKind: AnnotationAuthor.SourceKind.human.rawValue,
                authorDisplayName: authorName,
                authorCollaboratorId: authorId))
        try await opStore.append(op)
        _opLogMirror.append(op)
        _hasAnyAnnotationOps = true
        invalidateAnnotationsCache()
        invalidateTasksCache()
    }

    /// Author self-service: withdraw (delete) YOUR OWN annotation. Appends an
    /// `annotationWithdraw` op referencing the creation op; the deriver drops
    /// the annotation from the projection entirely. The op stays in the log
    /// (append-only / audit / rewind). Ownership gated at the UI layer.
    public func withdrawReviewerAnnotation(
        id: String,
        authorName: String,
        authorId: String? = nil
    ) async throws {
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .annotationWithdraw, changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                sourceAnnotationId: id,
                authorSourceKind: AnnotationAuthor.SourceKind.human.rawValue,
                authorDisplayName: authorName,
                authorCollaboratorId: authorId))
        try await opStore.append(op)
        _opLogMirror.append(op)
        _hasAnyAnnotationOps = true
        invalidateAnnotationsCache()
        invalidateTasksCache()
    }

    public func acceptAnnotation(
        id: String,
        userResponse: String? = nil
    ) async throws {
        guard let creation = _opLogMirror.first(where: { $0.opId == id }),
              let kind = AnnotationKind.fromOpKind(creation.kind) else {
            return  // unknown id or non-annotation op — no-op
        }

        // Determine the changes payload. Only suggestedChange mutates the
        // manuscript on accept.
        let changes: [Op.ParagraphChange] = {
            switch kind {
            case .suggestedChange:
                return creation.changes   // re-applies prior/next on replay
            case .comment, .query, .craftNote:
                return []
            }
        }()

        let acceptOp = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .claudeAccept,
            changes: changes,
            sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                sourceAnnotationId: id,
                userResponse: userResponse))
        try await opStore.append(acceptOp)
        _opLogMirror.append(acceptOp)
        _hasAnyAnnotationOps = true

        // Apply manuscript mutation for suggestedChange. This is the
        // "two effects, one op" case: the same op resolves the annotation
        // AND mutates `paragraphs` + writes `_displayText`. The single-
        // observable-write rule still holds because annotationsVersion and
        // displayText are distinct surfaces driving distinct views.
        if kind == .suggestedChange, let change = changes.first {
            paragraphs[change.paragraphId] = change.next
            pending.recordChange(
                paragraphId: change.paragraphId,
                prior: change.prior, next: change.next)
            burstScheduler.recordActivity()
            autosaveScheduler.schedule(())
            recomputeDisplayText()
        }

        invalidateAnnotationsCache()
        invalidateTasksCache()   // accept may have changed paragraph text → inline tasks
    }

    public func rejectAnnotation(
        id: String, userResponse: String? = nil
    ) async throws {
        try await appendLifecycleOp(
            kind: .claudeReject,
            sourceAnnotationId: id,
            userResponse: userResponse)
    }

    public func archiveAnnotation(id: String) async throws {
        try await appendLifecycleOp(
            kind: .claudeArchive,
            sourceAnnotationId: id,
            userResponse: nil)
    }

    /// Shared helper for reject/archive (and the paragraph-deletion sweep in
    /// T12, which uses `synthesisSource = "paragraph_deleted"`).
    private func appendLifecycleOp(
        kind: OpKind,
        sourceAnnotationId: String,
        userResponse: String?,
        synthesisSource: SynthesisSource? = nil
    ) async throws {
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: kind, changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                synthesisSource: synthesisSource,
                sourceAnnotationId: sourceAnnotationId,
                userResponse: userResponse))
        try await opStore.append(op)
        _opLogMirror.append(op)
        _hasAnyAnnotationOps = true
        invalidateAnnotationsCache()
        invalidateTasksCache()
    }

    /// Merge a fresh sweep reason into any pending one. The merge unions
    /// the removed sets so multiple deletion paths between two
    /// `flushBurstNow` runs accumulate correctly.
    internal func flagSweep(_ reason: SweepReason) {
        if let existing = _pendingSweep {
            _pendingSweep = existing.merging(reason)
        } else {
            _pendingSweep = reason
        }
    }

    /// Auto-archive any open annotations anchored to paragraphs that the
    /// caller observed being removed. Synthesizes `claude_archive` lifecycle
    /// ops with `provenance.synthesisSource = "paragraph_deleted"` for
    /// forensic context.
    ///
    /// The `reason.removed` set is the *exact* group of paragraph ids
    /// whose annotations should be archived — not "anything not in
    /// `sequence`." This matters for transient `Document` instances loaded
    /// by `withAnnotationDocument`: their reconstructed sequence can be a
    /// strict subset of the live Document's in-memory sequence, and
    /// archiving every annotation not in the reconstruction would falsely
    /// vanish open annotations the live editor is still working on.
    ///
    /// Runs from flushBurstNow (every 30s idle / 90s max during typing)
    /// and from external-change handlers. NOT scheduled from per-keystroke
    /// paragraph mutation — see setFullText for the cycle/reentrancy
    /// rationale.
    internal func sweepOrphanedAnnotations(reason: SweepReason) async {
        if !_annotationsCacheValid {
            rebuildAnnotationsCache()
        }
        let removed = reason.removed
        let orphans = _annotationsCache.filter { ann in
            ann.status == .open
                && ann.kind != .craftNote
                && (ann.paragraphId.map { removed.contains($0) } ?? false)
        }
        for orphan in orphans {
            try? await appendLifecycleOp(
                kind: .claudeArchive,
                sourceAnnotationId: orphan.id,
                userResponse: nil,
                synthesisSource: reason.cause)
        }
        // appendLifecycleOp already invalidates the cache on each call;
        // no extra invalidation needed here.
    }
}

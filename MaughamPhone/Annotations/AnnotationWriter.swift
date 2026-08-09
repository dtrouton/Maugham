import Foundation
import MaughamCore

/// Phone-side writer that appends annotation-lifecycle ops (Accept / Reject /
/// Archive) to a document's op log. The correctness-critical counterpart to the
/// Mac's annotation-resolution path (spec §3.9).
///
/// THE LOAD-BEARING RULE — accept copies the suggestion's change verbatim.
/// The Mac re-materializes the manuscript on next load by replaying ops through
/// `Deriver.derive`, and ONLY `claudeAccept` (not the original
/// `claudeSuggestion`) is in the manuscript-apply set (`Deriver.appliesToManuscript`).
/// So when the writer accepts a `.suggestedChange`, the `claudeAccept` op MUST
/// carry the creation op's `ParagraphChange` verbatim — otherwise the accepted
/// suggestion silently fails to materialize after a Mac restart. For
/// comment/query/craftNote there is no manuscript mutation, so `changes` is empty.
///
/// Per-device partitioning (ADR 0012): the phone only ever appends to its OWN
/// stream `.maugham/ops/<docId>.<deviceSlug>.jsonl` (where `docId` is already the
/// full `doc-<hex>` or `scene-<hex>` form per ADR 0008); the Mac globs siblings and merges by `opId`. Each op is encoded with `JSONLAppendStore<Op>.dateEncoding`
/// (ISO8601-with-fractional-seconds) so the Mac decodes the bytes losslessly, and
/// appended through `CoordinatedFileIO` — the same `NSFileCoordinator` cooperation
/// the inbox writer uses (`InboxCaptureWriter`).
struct AnnotationWriter {
    let projectRoot: URL
    /// The annotation's document id — the full `doc-<hex>` or `scene-<hex>` form
    /// per ADR 0008 (same string the creation op carries in `op.docId`). The op-log file is `<docId>.<slug>.jsonl`.
    let docId: String
    /// `phone:<uuid>` (`PhoneDeviceID.current()`) — also drives the device slug.
    let deviceId: String
    var io: CoordinatedFileIO = .live
    /// e.g. `CFBundleShortVersionString` — forensic only; the deriver ignores it.
    var appVersion: String
    /// e.g. "iOS 17.4" — forensic only.
    var osVersion: String
    /// Injectable clock so tests can pin `at` deterministically.
    var now: () -> Date = { Date() }
    /// One session id per writer instance — groups all ops from a single
    /// writing/review session so the Mac history pane shows them together (not as
    /// a string of one-op "sessions"). Reused for every op this writer appends; the
    /// same value populates both `Op.session` and `provenance.sessionId`.
    /// Injectable so tests can pin it deterministically.
    var session: String = ULID.generate()
    /// Whether the malformed-suggestion guard trips an `assertionFailure` before
    /// throwing. True in production so upstream corruption aborts a Debug build
    /// loudly; the throws-test flips it off to exercise the thrown error without
    /// aborting the test process.
    var assertOnMalformed: Bool = true

    /// Thrown when an op can't be built faithfully. Surfaced to the caller (F.5's
    /// action handler) so the user sees an alert rather than a phantom accept.
    enum WriteError: Error {
        /// A `.suggestedChange` reached `makeAccept` missing the fields needed to
        /// reconstruct its `ParagraphChange`. This is upstream corruption
        /// (`AnnotationDeriver` always populates them), so we fail loud rather than
        /// emit an empty-changes accept — which would mark the annotation accepted
        /// while materializing nothing (silent manuscript data loss).
        case malformedSuggestion(annotationId: String)
        /// `makeReopen` was asked to reopen an annotation whose status has no
        /// reopen inverse — either the local status isn't rejected/archived, or
        /// `AnnotationInverse.reopenOp` declined (state drifted since this view
        /// last re-derived, e.g. another device already reopened it). Either way,
        /// no op is appended — the caller shows an alert rather than a phantom
        /// reopen.
        case notReopenable(annotationId: String)
        /// `makeAcceptRevert` was given an `acceptOp` with no `changes` — upstream
        /// corruption (a real `claudeAccept` for a `.suggestedChange` always
        /// carries the full-paragraph change; see `makeAccept`'s load-bearing
        /// rule). Fail loud rather than fabricate a revert with no paragraph to
        /// restore.
        case malformedAcceptRevert(annotationId: String)
        /// `makeAccept` found the suggestion's span no longer resolvable against
        /// the current paragraph. RULING-5: it MUST NOT be applied — the caller
        /// shows the refusal; the writer may ask for a fresh suggestion. Same
        /// decision as the Mac's `AnnotationAcceptError.suggestionAnchorLost`,
        /// made by the same shared `SuggestionSplice.attempt`.
        case suggestionAnchorLost(annotationId: String)
        /// `makeAccept` was given merged ops in which this annotation's latest
        /// withdraw/reopen op is a WITHDRAW: the writer deleted it (possibly on
        /// another device) and a stale view must not splice its text anyway
        /// (RULING-33's status/manuscript agreement; the Mac's guard is the
        /// same shared `AnnotationDeriver.isWithdrawn` — tripwire 19).
        case annotationWithdrawn(annotationId: String)
    }

    // MARK: - Paths

    /// This device's own op-log stream for `docId`. Delegates to
    /// `OpLogStore.opLogFileURL(forDocId:deviceSlug:in:)` — the single source of
    /// truth for op-log filename construction — so the Mac and phone can never drift
    /// on filename shape. The `docId` is already the full `doc-<hex>` or `scene-<hex>`
    /// form per ADR 0008 (same string the creation op carries in `op.docId`); do NOT
    /// double-prefix it or the file lands in an untracked stream the Mac's
    /// `load(docId:)` glob never finds and the accept/reject silently never reaches the Mac.
    private var opLogURL: URL {
        OpLogStore.opLogFileURL(
            forDocId: docId,
            deviceSlug: DeviceSlug.make(from: deviceId),
            in: projectRoot
        )
    }

    // MARK: - Pure builders (testable without I/O)

    /// Build a `claudeAccept` op for `annotation`.
    ///
    /// For a `.suggestedChange`, `changes` carries the FULL resulting paragraph
    /// as `next` so the Mac re-applies it on replay (the load-bearing rule above).
    /// The annotation stores the BARE suggested text; the full paragraph is
    /// produced here by `SuggestionSplice.apply`, which splices the bare text into
    /// the span (`annotation.span`, re-resolved against `currentParagraph`) so a
    /// one-word suggestion replaces one word, not the whole paragraph. A
    /// paragraph-level suggestion (no span) replaces the whole paragraph — the
    /// bare text already is that paragraph. Identical to the Mac's
    /// `Document.acceptAnnotation` (shared `SuggestionSplice`, cross-surface
    /// contract). `currentParagraph` is the live paragraph text from the caller's
    /// materialised map; nil falls back to `annotation.priorText`.
    ///
    /// For every other kind there is nothing to materialize, so `changes` is
    /// empty: a comment/query/craftNote accept must NOT fabricate a manuscript
    /// change.
    ///
    /// Fail loud: a `.suggestedChange` missing `paragraphId` or `suggestedText` is
    /// upstream corruption — emitting an empty-changes accept would mark the
    /// annotation accepted while materializing nothing (silent manuscript data
    /// loss), so we `assertionFailure` (Debug) then `throw .malformedSuggestion`
    /// rather than fabricate or drop the change.
    func makeAccept(
        for annotation: Annotation, currentParagraph: String? = nil,
        verifyingAgainst ops: [Op]? = nil
    ) throws -> Op {
        if let ops, AnnotationDeriver.isWithdrawn(annotationId: annotation.id, in: ops) {
            throw WriteError.annotationWithdrawn(annotationId: annotation.id)
        }
        let changes: [Op.ParagraphChange]
        if annotation.kind == .suggestedChange {
            guard let pid = annotation.paragraphId, let bare = annotation.suggestedText else {
                if assertOnMalformed {
                    assertionFailure("malformed .suggestedChange reached makeAccept: \(annotation.id)")
                }
                throw WriteError.malformedSuggestion(annotationId: annotation.id)
            }
            let current = currentParagraph ?? annotation.priorText ?? ""
            switch SuggestionSplice.attempt(
                suggestion: bare, span: annotation.span, to: current) {
            case .applied(let next):
                changes = [Op.ParagraphChange(paragraphId: pid, prior: current, next: next)]
            case .anchorLost:
                // RULING-5: a span whose quoted phrase is gone is refused, not
                // guessed at — same decision, same shared splice, as the Mac.
                throw WriteError.suggestionAnchorLost(annotationId: annotation.id)
            }
        } else {
            // comment/query/craftNote: nothing to materialize.
            changes = []
        }
        return makeLifecycleOp(for: annotation, kind: .claudeAccept, changes: changes, userResponse: nil)
    }

    /// Build a `claudeReject` op. Carries no manuscript change; the optional
    /// `reason` lands in `provenance.userResponse`.
    func makeReject(for annotation: Annotation, reason: String?) -> Op {
        makeLifecycleOp(for: annotation, kind: .claudeReject, changes: [], userResponse: reason)
    }

    /// Build a `claudeArchive` op. No manuscript change, no user response.
    func makeArchive(for annotation: Annotation) -> Op {
        makeLifecycleOp(for: annotation, kind: .claudeArchive, changes: [], userResponse: nil)
    }

    /// Shared lifecycle-op assembly. The writer's `session` populates both
    /// `Op.session` and `provenance.sessionId`; `sequence` is nil (lifecycle ops
    /// never reorder paragraphs); `sourceAnnotationId` keys the op back to the
    /// creation op so `AnnotationDeriver` resolves the annotation's status.
    private func makeLifecycleOp(
        for annotation: Annotation,
        kind: OpKind,
        changes: [Op.ParagraphChange],
        userResponse: String?
    ) -> Op {
        Op(
            opId: ULID.generate(),
            docId: docId,
            at: now(),
            device: deviceId,
            session: session,
            kind: kind,
            changes: changes,
            sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                annotationBody: nil,
                sourceAnnotationId: annotation.id,
                userResponse: userResponse,
                appVersion: appVersion,
                osVersion: osVersion
            )
        )
    }

    /// Build the compensating `annotation_reopen` op for a rejected/archived
    /// annotation. The inverse DECISION — which resolution kinds have a reopen
    /// inverse, and the state-drift guard — lives entirely in
    /// `AnnotationInverse.reopenOp` (MaughamCore, cross-surface contract,
    /// tripwire 19); this only maps the annotation's local status to the
    /// resolution kind it undoes and adds the phone's write-path stamping
    /// (`docId`/`deviceId`/`session`, forensic `appVersion`/`osVersion`) —
    /// exactly the fields `makeLifecycleOp` stamps above.
    ///
    /// An accepted suggestion has NO reopen inverse — use `makeAcceptRevert`
    /// instead, which also restores the pre-accept text (Mac Revert parity).
    func makeReopen(for annotation: Annotation) throws -> Op {
        let undone: OpKind
        switch annotation.status {
        case .rejected: undone = .claudeReject
        case .archived: undone = .claudeArchive
        case .open, .accepted:
            throw WriteError.notReopenable(annotationId: annotation.id)
        }
        guard case .op(let op) = AnnotationInverse.reopenOp(
            undoing: undone,
            annotationId: annotation.id,
            currentStatus: annotation.status,
            docId: docId, device: deviceId, session: session,
            appVersion: appVersion, osVersion: osVersion
        ) else {
            // State drifted since this view last re-derived (e.g. another
            // device already reopened it) — no op to append.
            throw WriteError.notReopenable(annotationId: annotation.id)
        }
        return op
    }

    /// Full revert of an accepted suggestion — same behavior as the Mac
    /// Annotations pane's Revert: restores the pre-accept text over whatever
    /// the paragraph currently holds AND reopens the annotation (user decision
    /// 2026-07-09; `claudeAcceptRevert` WITH changes, mirroring the Mac's
    /// `Document.revertAcceptedAnnotation`: `ParagraphChange(paragraphId: pid,
    /// prior: currentText, next: acceptChange.prior ?? "")`).
    ///
    /// `acceptOp` is the latest `claudeAccept` op for this annotation — the
    /// caller (the detail view's re-derive) locates it from the ops it already
    /// loaded. `currentParagraph` is the live paragraph text at revert time
    /// (may have drifted since the accept; the caller is responsible for the
    /// drift confirm, mirroring the Mac's `acceptedTextDrifted` gate).
    func makeAcceptRevert(
        for annotation: Annotation, acceptOp: Op, currentParagraph: String?
    ) throws -> Op {
        guard let change = acceptOp.changes.first else {
            throw WriteError.malformedAcceptRevert(annotationId: annotation.id)
        }
        let restored = change.prior ?? ""
        return Op(
            opId: ULID.generate(),
            docId: docId, at: now(),
            device: deviceId, session: session,
            kind: .claudeAcceptRevert,
            changes: [Op.ParagraphChange(
                paragraphId: change.paragraphId, prior: currentParagraph ?? "", next: restored)],
            sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                sourceAnnotationId: annotation.id,
                appVersion: appVersion,
                osVersion: osVersion))
    }

    // MARK: - Build + coordinated append

    @discardableResult
    func accept(
        _ annotation: Annotation, currentParagraph: String? = nil,
        verifyingAgainst ops: [Op]? = nil
    ) async throws -> Op {
        try await append(makeAccept(
            for: annotation, currentParagraph: currentParagraph, verifyingAgainst: ops))
    }

    @discardableResult
    func reject(_ annotation: Annotation, reason: String?) async throws -> Op {
        try await append(makeReject(for: annotation, reason: reason))
    }

    @discardableResult
    func archive(_ annotation: Annotation) async throws -> Op {
        try await append(makeArchive(for: annotation))
    }

    /// Reopen a rejected/archived annotation. See `makeReopen`.
    @discardableResult
    func reopen(_ annotation: Annotation) async throws -> Op {
        try await append(makeReopen(for: annotation))
    }

    /// Full revert of an accepted suggestion. See `makeAcceptRevert`.
    @discardableResult
    func revertAccept(
        _ annotation: Annotation, acceptOp: Op, currentParagraph: String?
    ) async throws -> Op {
        try await append(makeAcceptRevert(
            for: annotation, acceptOp: acceptOp, currentParagraph: currentParagraph))
    }

    /// Encode + coordinated-append one op to this device's op-log stream.
    /// `coordinatedAppendLine` creates intermediate dirs + the file on first use,
    /// so this is the single coordination site for the whole append (no separate
    /// `ensureDirectory` pass — that would run a redundant second coordination).
    private func append(_ op: Op) async throws -> Op {
        let line = try encode(op)
        try io.coordinatedAppendLine(line, to: opLogURL)
        return op
    }

    /// Encode with the Mac reader's exact date strategy so the bytes decode
    /// losslessly through `JSONLAppendStore<Op>` on the Mac.
    private func encode(_ op: Op) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(op)
    }
}


extension AnnotationWriter.WriteError: LocalizedError {
    /// A raw Foundation rendering of these ("…WriteError error 3.") reached a
    /// writer once (branch review); every case names itself now.
    var errorDescription: String? {
        switch self {
        case .malformedSuggestion:
            return "This suggestion is malformed and can’t be applied."
        case .notReopenable:
            return "This annotation can’t be reopened — its status changed on another device."
        case .malformedAcceptRevert:
            return "This accept can’t be reverted — its record is incomplete."
        case .suggestionAnchorLost:
            return "The passage this suggestion would replace is no longer in the paragraph. The suggestion stays open — ask Claude for a fresh one."
        case .annotationWithdrawn:
            return "You deleted this suggestion on another device, so it can no longer be applied."
        }
    }
}

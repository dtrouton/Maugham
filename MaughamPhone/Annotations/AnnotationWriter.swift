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
/// stream `.maugham/ops/d_<docId>.<deviceSlug>.jsonl`; the Mac globs siblings and
/// merges by `opId`. Each op is encoded with `JSONLAppendStore<Op>.dateEncoding`
/// (ISO8601-with-fractional-seconds) so the Mac decodes the bytes losslessly, and
/// appended through `CoordinatedFileIO` — the same `NSFileCoordinator` cooperation
/// the inbox writer uses (`InboxCaptureWriter`).
struct AnnotationWriter {
    let projectRoot: URL
    /// The annotation's document id; the op-log file is `d_<docId>.<slug>.jsonl`.
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
    }

    // MARK: - Paths

    private var opsDir: URL {
        projectRoot.appendingPathComponent(".maugham/ops", isDirectory: true)
    }

    /// This device's own op-log stream for `docId`. Matches the Mac's
    /// `OpLogStore.opLogFileURLs` per-device sibling convention.
    private var opLogURL: URL {
        opsDir.appendingPathComponent("d_\(docId).\(DeviceSlug.make(from: deviceId)).jsonl")
    }

    // MARK: - Pure builders (testable without I/O)

    /// Build a `claudeAccept` op for `annotation`.
    ///
    /// For a `.suggestedChange`, `changes` is the creation op's `ParagraphChange`
    /// rebuilt verbatim — `(paragraphId, prior, next)` = `(annotation.paragraphId,
    /// annotation.priorText, annotation.suggestedText)` — so the Mac re-applies the
    /// edit on replay (the load-bearing rule above). For every other kind there is
    /// nothing to materialize, so `changes` is empty: a comment/query/craftNote
    /// accept must NOT fabricate a manuscript change.
    ///
    /// Fail loud: a `.suggestedChange` missing `paragraphId` or `suggestedText` is
    /// upstream corruption — emitting an empty-changes accept would mark the
    /// annotation accepted while materializing nothing (silent manuscript data
    /// loss), so we `assertionFailure` (Debug) then `throw .malformedSuggestion`
    /// rather than fabricate or drop the change.
    func makeAccept(for annotation: Annotation) throws -> Op {
        let changes: [Op.ParagraphChange]
        if annotation.kind == .suggestedChange {
            guard let pid = annotation.paragraphId, let next = annotation.suggestedText else {
                if assertOnMalformed {
                    assertionFailure("malformed .suggestedChange reached makeAccept: \(annotation.id)")
                }
                throw WriteError.malformedSuggestion(annotationId: annotation.id)
            }
            changes = [Op.ParagraphChange(paragraphId: pid, prior: annotation.priorText, next: next)]
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

    // MARK: - Build + coordinated append

    @discardableResult
    func accept(_ annotation: Annotation) async throws -> Op {
        try await append(makeAccept(for: annotation))
    }

    @discardableResult
    func reject(_ annotation: Annotation, reason: String?) async throws -> Op {
        try await append(makeReject(for: annotation, reason: reason))
    }

    @discardableResult
    func archive(_ annotation: Annotation) async throws -> Op {
        try await append(makeArchive(for: annotation))
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

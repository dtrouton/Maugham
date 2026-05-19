import Foundation
import AppKit

/// Per-manuscript canonical state. Owns its op log + pending buffer +
/// burst scheduler + autosave + conflict detection. The single
/// `displayText` property is the only observed text-state; SwiftUI body
/// re-evaluates against it, and every internal mutation path writes
/// `_displayText` exactly once at the end so updateNSView always sees a
/// consistent (textView, text) pair.
///
/// See docs/superpowers/specs/2026-05-19-document-first-class-oplog-design.md
@MainActor
@Observable
public final class Document {

    // === Public observed state ===
    public private(set) var displayText: String = ""
    public var cursorLocation: Int = 0
    public private(set) var pendingConflict: ConflictState?

    // === Internal state ===
    private let url: URL
    public let docId: String
    private let device: String
    private let session: String
    private let presenter: NSFilePresenter?
    private let opStore: OpLogStore
    private let pending: PendingBuffer
    private let burstScheduler: BurstScheduler

    private var paragraphs: [String: String]
    private var sequence: [String]
    private var lastWrittenText: String

    private var _annotationsCache: [Annotation] = []
    private var _annotationsCacheValid: Bool = false
    public private(set) var annotationsVersion: Int = 0

    /// Mirror of every op append for synchronous annotation derivation.
    /// Populated at load(...) with the result of opStore.load, then kept
    /// in sync by every mutation path that calls opStore.append.
    fileprivate var _opLogMirror: [Op] = []

    /// Sticky flag: true once the doc has ever had an annotation op
    /// (creation OR lifecycle). Lets the hot typing path short-circuit
    /// per-keystroke annotation work (invalidateAnnotationsCache + sweep)
    /// when the document has never seen an annotation, which is the common
    /// case. Set at load() time by scanning the mirror, and stays true once
    /// flipped — annotations are append-only, so the flag only ratchets up.
    private var _hasAnyAnnotationOps: Bool = false

    /// Hot-path check whether any of the seven annotation-related OpKinds
    /// has ever been observed on this document. Reads the cached flag.
    private static func isAnnotationOpKind(_ kind: OpKind) -> Bool {
        switch kind {
        case .claudeComment, .claudeSuggestion, .claudeQuery, .claudeCraftNote,
             .claudeAccept, .claudeReject, .claudeArchive:
            return true
        default:
            return false
        }
    }

    /// Internal autosave debounce (replaces DocumentStore.scheduleSave).
    private var autosaveScheduler: DebounceScheduler<Void>!

    private init(
        url: URL, docId: String, device: String, session: String,
        presenter: NSFilePresenter?, opStore: OpLogStore,
        pending: PendingBuffer, burstScheduler: BurstScheduler,
        paragraphs: [String: String], sequence: [String],
        lastWrittenText: String
    ) {
        self.url = url
        self.docId = docId
        self.device = device
        self.session = session
        self.presenter = presenter
        self.opStore = opStore
        self.pending = pending
        self.burstScheduler = burstScheduler
        self.paragraphs = paragraphs
        self.sequence = sequence
        self.lastWrittenText = lastWrittenText
    }

    /// Construct a Document from an on-disk manuscript file. Runs the
    /// Bootstrap migration if needed (the .md lacks inline ¶id markers
    /// or no op log exists yet). Recovers from a crashed pending buffer
    /// by folding its contents into a synthesized typing_burst op.
    public static func load(
        url: URL,
        device: String,
        session: String,
        presenter: NSFilePresenter?
    ) async throws -> Document {
        try await load(
            url: url, device: device, session: session, presenter: presenter,
            burstIdle: .seconds(30), burstMax: .seconds(90))
    }

    /// Internal overload that accepts custom burst thresholds. Used by tests
    /// to avoid waiting 30 seconds for the default idle threshold.
    internal static func load(
        url: URL,
        device: String,
        session: String,
        presenter: NSFilePresenter?,
        burstIdle: Duration,
        burstMax: Duration
    ) async throws -> Document {
        // Resolve doc-id by looking up the manifest. For tests + initial
        // setup, fall back to a deterministic id derived from the path.
        let docId = try resolveDocId(for: url)

        // projectURL is the parent of the manuscript/ folder.
        let projectURL = url.deletingLastPathComponent()
            .deletingLastPathComponent()

        // Bootstrap detection.
        let opLogPath = projectURL
            .appendingPathComponent(".maugham/ops/\(docId).jsonl")
        let logExists = FileManager.default.fileExists(atPath: opLogPath.path)
        let storedBytes = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let parsed = ParagraphParser.parse(storedBytes)
        let needsBootstrap = !logExists || parsed.allSatisfy { $0.id == nil }

        if needsBootstrap {
            _ = try await Bootstrap.run(
                projectURL: projectURL, docId: docId,
                mdURL: url, device: device, session: session)
        }

        let opStore = OpLogStore(projectURL: projectURL, presenter: presenter)
        let pending = PendingBuffer(projectURL: projectURL, docId: docId)
        try await pending.loadFromDisk()

        var ops = try await opStore.load(docId: docId)

        // Crash recovery: fold any pending changes into a real op.
        if !pending.isEmpty() {
            let recovered = Op(
                opId: ULID.generate(), docId: docId, at: Date(),
                device: device, session: session, kind: .typingBurst,
                changes: pending.snapshot())
            try await opStore.append(recovered)
            try await pending.clear()
            ops.append(recovered)
        }

        var initial = Deriver.derive(ops: ops)
        // If the op log is empty but the on-disk file is fully tagged
        // (Bootstrap.run short-circuited with `allHaveIds`), seed the
        // in-memory paragraph map from the parsed file. Without this,
        // `handleExternalDiskChange` would compare against an empty
        // derived state and mis-classify subsequent external edits.
        if initial.paragraphs.isEmpty && parsed.contains(where: { $0.id != nil }) {
            var paragraphs: [String: String] = [:]
            var sequence: [String] = []
            for p in parsed {
                guard let id = p.id else { continue }
                paragraphs[id] = p.text
                sequence.append(id)
            }
            initial = Deriver.DerivedState(paragraphs: paragraphs, sequence: sequence)
        }
        let lastWritten = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        // BurstScheduler with caller-supplied thresholds (defaults: 30s/90s).
        let burstHolder = WeakBurstHolder()
        let burst = BurstScheduler(
            idle: burstIdle, max: burstMax
        ) {
            Task { @MainActor in
                try? await burstHolder.document?.flushBurstNow()
            }
        }

        let doc = Document(
            url: url, docId: docId, device: device, session: session,
            presenter: presenter, opStore: opStore, pending: pending,
            burstScheduler: burst,
            paragraphs: initial.paragraphs, sequence: initial.sequence,
            lastWrittenText: lastWritten)
        burstHolder.document = doc

        // Initialize autosave + displayText.
        doc.autosaveScheduler = DebounceScheduler<Void>(
            delay: .milliseconds(750)
        ) { [weak doc] _ in
            try? await doc?.performAutosave()
        }
        doc.recomputeDisplayText()
        doc._opLogMirror = ops
        doc._annotationsCacheValid = false
        doc._hasAnyAnnotationOps = ops.contains {
            Document.isAnnotationOpKind($0.kind)
        }
        return doc
    }

    private func recomputeDisplayText() {
        var rendered = ""
        for id in sequence {
            guard let text = paragraphs[id] else { continue }
            if !rendered.isEmpty { rendered.append("\n\n") }
            rendered.append(text)
        }
        displayText = rendered
    }

    private func performAutosave() async throws {
        // Mirror pending buffer to disk for crash recovery.
        try? await pending.flushToDisk()

        let bytes = materialize()
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var writeErr: Error?
        coord.coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordErr
        ) { wu in
            do {
                try bytes.data(using: .utf8)?.write(to: wu, options: .atomic)
                self.lastWrittenText = bytes
            } catch {
                writeErr = error
            }
        }
        if let coordErr { throw coordErr }
        if let writeErr { throw writeErr }
    }

    public func materialize() -> String {
        return Materializer.materialize(
            paragraphs: paragraphs, sequence: sequence)
    }

    /// Returns the full op log for this document, ordered by `op_id`
    /// (ULID timestamp-prefixed → chronologically stable across devices).
    /// Prefers the in-memory mirror populated at `load(...)`; falls back
    /// to a disk read only if the mirror hasn't been seeded yet.
    public func opLog() async throws -> [Op] {
        if !_opLogMirror.isEmpty { return _opLogMirror }
        return try await opStore.load(docId: docId)
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

    fileprivate func invalidateAnnotationsCache() {
        _annotationsCacheValid = false
        annotationsVersion &+= 1
    }

    private func rebuildAnnotationsCache() {
        _annotationsCache = AnnotationDeriver.derive(
            ops: _opLogMirror, paragraphs: paragraphs)
        _annotationsCacheValid = true
    }

    // === Mutation API (Task 6) ===
    public func setFullText(_ text: String) {
        // Build the next stored form by running restoreComments against
        // the current materialized state. This is the same parse+diff
        // that EditorHost used to do; relocating it to Document.
        let priorStored = Materializer.materialize(
            paragraphs: paragraphs, sequence: sequence)
        let nextStored = RenderFilter.restoreComments(
            stored: priorStored, displayEdited: text)

        // Parse the new stored form to extract paragraph-level changes.
        let priorParsed = ParagraphParser.parse(priorStored)
        let nextParsed = ParagraphParser.parse(nextStored)
        var priorById: [String: String] = [:]
        for p in priorParsed {
            if let id = p.id { priorById[id] = p.text }
        }

        // Collect changes and the new sequence.
        var changes: [Op.ParagraphChange] = []
        var newSequence: [String] = []
        for p in nextParsed {
            guard let id = p.id else { continue }
            newSequence.append(id)
            let prior = priorById[id]
            if prior != p.text {
                changes.append(.init(paragraphId: id, prior: prior, next: p.text))
                pending.recordChange(
                    paragraphId: id, prior: prior, next: p.text)
            }
        }

        // Update internal derived state.
        var newParagraphs: [String: String] = paragraphs
        for change in changes {
            newParagraphs[change.paragraphId] = change.next
        }
        let sequenceChanged = (newSequence != sequence)
        self.paragraphs = newParagraphs
        self.sequence = newSequence

        // Tickle the burst scheduler so the typing_burst op fires on
        // idle / max thresholds.
        if !changes.isEmpty || sequenceChanged {
            burstScheduler.recordActivity()
            autosaveScheduler.schedule(())
            // Only touch the annotation cache when the doc actually has
            // annotation ops. For docs without annotations (the common case),
            // bumping annotationsVersion on every keystroke is pure
            // observable-write churn that races with displayText updates
            // and can leave NSTextView's spellchecker holding stale ranges
            // (FAULT: NSRangeException in NSTextCheckingController).
            if _hasAnyAnnotationOps {
                invalidateAnnotationsCache()
            }
        }

        // T12: auto-archive annotations whose paragraph dropped out of
        // `sequence` on this edit. Fire-and-forget on the main actor.
        // Skip entirely when the doc has no annotations — the sweep would
        // be a no-op but the Task scheduling itself adds main-actor churn.
        if _hasAnyAnnotationOps {
            Task { @MainActor in await self.sweepOrphanedAnnotations() }
        }

        // ONE @Observable write at the end — but mirror the user's input
        // VERBATIM rather than re-rendering from paragraphs. ParagraphParser
        // strips trailing whitespace and newlines from paragraph text; a
        // round-trip through recomputeDisplayText() would shorten what the
        // user just typed (e.g. pressing Enter at end of paragraph yields
        // textView.string="Hello\n" but paragraphs={id:"Hello"} renders to
        // "Hello"). SwiftUI then sees displayText shorter than textView.string
        // and fires applyExternalText, which clobbers cursor position and —
        // when NSSpellChecker / inline-prediction has a pending marked-range
        // mid-correction — underflows the selection fixup and crashes
        // (`Range {N, UInt.max-2} out of bounds`).
        //
        // The canonical state for ops lives in paragraphs/sequence (updated
        // above). The .md on disk is materialized via materialize(). Both of
        // those paths normalize whitespace, which is the existing data-loss
        // tradeoff we already documented. But the live editor view must
        // stay byte-for-byte synchronized with textView.string while the
        // user is typing, or NSTextView's invariants break.
        displayText = text
    }

    public func setParagraph(id: String, text: String) {
        let prior = paragraphs[id]
        guard prior != text else { return }
        pending.recordChange(paragraphId: id, prior: prior, next: text)
        paragraphs[id] = text
        burstScheduler.recordActivity()
        autosaveScheduler.schedule(())
        recomputeDisplayText()
    }

    public func insertParagraph(after: String?, text: String) -> String {
        let newId = ParagraphID.mint()
        paragraphs[newId] = text
        if let after, let idx = sequence.firstIndex(of: after) {
            sequence.insert(newId, at: idx + 1)
        } else {
            sequence.append(newId)
        }
        pending.recordChange(paragraphId: newId, prior: nil, next: text)
        burstScheduler.recordActivity()
        autosaveScheduler.schedule(())
        if _hasAnyAnnotationOps {
            Task { @MainActor in await self.sweepOrphanedAnnotations() }
        }
        recomputeDisplayText()
        return newId
    }

    public func deleteParagraph(id: String) {
        guard paragraphs[id] != nil else { return }
        let priorText = paragraphs[id]
        paragraphs.removeValue(forKey: id)
        sequence.removeAll { $0 == id }
        // Record deletion as an op with empty next text (consumer-visible
        // marker that the paragraph went away; sequence change carries the
        // ordering).
        pending.recordChange(paragraphId: id, prior: priorText, next: "")
        burstScheduler.recordActivity()
        autosaveScheduler.schedule(())
        if _hasAnyAnnotationOps {
            Task { @MainActor in await self.sweepOrphanedAnnotations() }
        }
        recomputeDisplayText()
    }

    public func reorder(sequence: [String]) {
        self.sequence = sequence
        // No paragraph-change ops for pure reorder; the next typing_burst
        // emission will carry the new sequence as its `sequence` field.
        burstScheduler.recordActivity()
        autosaveScheduler.schedule(())
        if _hasAnyAnnotationOps {
            Task { @MainActor in await self.sweepOrphanedAnnotations() }
        }
        recomputeDisplayText()
    }

    // MARK: - Annotation mutation API

    @discardableResult
    public func addAnnotation(
        kind: AnnotationKind,
        paragraphId: String?,
        body: String,
        suggestedText: String? = nil,
        prompt: String? = nil,
        toolArgs: String? = nil
    ) async throws -> String {
        let opKind: OpKind = {
            switch kind {
            case .comment:         return .claudeComment
            case .suggestedChange: return .claudeSuggestion
            case .query:           return .claudeQuery
            case .craftNote:       return .claudeCraftNote
            }
        }()
        let changes: [Op.ParagraphChange] = {
            switch kind {
            case .craftNote:
                return []
            case .suggestedChange:
                guard let pid = paragraphId else { return [] }
                let prior = paragraphs[pid]
                return [.init(paragraphId: pid,
                              prior: prior,
                              next: suggestedText ?? "")]
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
                annotationBody: body))
        try await opStore.append(op)
        _opLogMirror.append(op)
        _hasAnyAnnotationOps = true
        invalidateAnnotationsCache()
        return op.opId
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
        synthesisSource: String? = nil
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
    }

    /// Auto-archive any open annotations anchored to paragraphs no longer
    /// present in `sequence`. Synthesizes `claude_archive` lifecycle ops with
    /// `provenance.synthesisSource = "paragraph_deleted"` for forensic context.
    ///
    /// Note: sync mutation paths schedule this via `Task { } ` and return
    /// immediately. Tests that depend on observing the post-sweep state must
    /// `await Task.sleep(for: .milliseconds(50))` (or similar yield) after
    /// the mutation. UI re-renders naturally on the cache invalidation that
    /// bumps `annotationsVersion`.
    private func sweepOrphanedAnnotations() async {
        let presentIds = Set(sequence)
        if !_annotationsCacheValid {
            rebuildAnnotationsCache()
        }
        let orphans = _annotationsCache.filter { ann in
            ann.status == .open
                && ann.kind != .craftNote
                && (ann.paragraphId.map { !presentIds.contains($0) } ?? false)
        }
        for orphan in orphans {
            try? await appendLifecycleOp(
                kind: .claudeArchive,
                sourceAnnotationId: orphan.id,
                userResponse: nil,
                synthesisSource: "paragraph_deleted")
        }
        // appendLifecycleOp already invalidates the cache on each call;
        // no extra invalidation needed here.
    }

    public func flushBurstNow() async throws {
        guard !pending.isEmpty() else { return }
        let changes = pending.snapshot()
        // Capture the latest sequence on the burst so cross-Mac merge sees
        // ordering changes.
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .typingBurst,
            changes: changes,
            sequence: sequence,
            provenance: nil)
        try await opStore.append(op)
        _opLogMirror.append(op)
        invalidateAnnotationsCache()
        try await pending.clear()
    }

    public func close() async {
        // Flush any pending burst so editorial classification survives the
        // close (matches EditorHost's onDocChange behaviour).
        try? await flushBurstNow()
        // Flush any pending autosave so the .md reflects the final state.
        await autosaveScheduler.flush()
    }
    public func handleExternalDiskChange(diskMd: String) async throws {
        // Echo guard: this is the file change we ourselves just wrote.
        guard diskMd != lastWrittenText else { return }

        let derivedMd = materialize()
        let classification = Reconciler.classify(
            diskMd: diskMd, derivedMd: derivedMd)

        switch classification {
        case .echo:
            return

        case .silentIngest(let changes):
            // Construct an external_edit op carrying the changes.
            let op = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .externalEdit,
                changes: changes,
                sequence: nil,
                provenance: .init(synthesisSource: "disk_at_ingest"))
            try await opStore.append(op)
            _opLogMirror.append(op)
            invalidateAnnotationsCache()
            // Update internal state.
            for change in changes {
                paragraphs[change.paragraphId] = change.next
            }
            lastWrittenText = diskMd
            recomputeDisplayText()

        case .needsSheet(let orphanCount):
            // Surface a pending conflict. UI reads document.pendingConflict.
            pendingConflict = ConflictState(
                path: url.path,
                localText: derivedMd,
                externalText: diskMd,
                externalModifiedAt: Date())
            _ = orphanCount  // (currently unused; could feed into the UI sheet)
        }
    }

    public func handleExternalLogChange() async throws {
        // Reload the log file (OpLogStore.load dedupes by op_id and sorts).
        let ops = try await opStore.load(docId: docId)

        // Re-derive from the merged log.
        let state = Deriver.derive(ops: ops)
        self.paragraphs = state.paragraphs
        self.sequence = state.sequence
        self._opLogMirror = ops
        // Re-derive the sticky flag from the merged log: cross-Mac sync
        // could deliver annotation ops on a doc that previously had none.
        self._hasAnyAnnotationOps = ops.contains {
            Document.isAnnotationOpKind($0.kind)
        }
        invalidateAnnotationsCache()

        // T12: auto-archive annotations anchored to paragraphs that vanished
        // in the merged state.
        await sweepOrphanedAnnotations()

        // No conflict UI for log merge. Just publish the new state.
        recomputeDisplayText()
    }

    public func resolveConflictKeepMine() async throws {
        guard let conflict = pendingConflict else { return }

        // Preserve the external version as a conflict backup before
        // overwriting (matches DocumentStore's existing backup behaviour).
        try writeConflictBackup(text: conflict.externalText, kind: "cloud")

        // Schedule an autosave of our current derived state. The disk
        // re-write happens via the autosave path.
        autosaveScheduler.schedule(())
        await autosaveScheduler.flush()
        pendingConflict = nil
    }

    public func resolveConflictUseExternal() async throws {
        guard let conflict = pendingConflict else { return }

        // Preserve our local version as a backup before accepting external.
        try writeConflictBackup(text: conflict.localText, kind: "local")

        // Ingest the external bytes as a synthesized external_edit op,
        // same as the silent-ingest path would have done if IDs had been
        // intact.
        try await handleExternalDiskChangeForceIngest(diskMd: conflict.externalText)
        pendingConflict = nil
    }

    private func handleExternalDiskChangeForceIngest(diskMd: String) async throws {
        // For "Use cloud" resolution: ignore the Reconciler classification
        // and ingest the diskMd verbatim. The new paragraphs may get fresh
        // IDs minted by restoreComments since the user-typed IDs are gone.
        let priorStored = materialize()
        let nextStored = RenderFilter.restoreComments(
            stored: priorStored, displayEdited:
                RenderFilter.stripComments(diskMd))
        let parsed = ParagraphParser.parse(nextStored)

        var newParagraphs: [String: String] = [:]
        var newSequence: [String] = []
        var changes: [Op.ParagraphChange] = []
        for p in parsed {
            guard let id = p.id else { continue }
            let prior = paragraphs[id]
            newParagraphs[id] = p.text
            newSequence.append(id)
            if prior != p.text {
                changes.append(.init(paragraphId: id, prior: prior, next: p.text))
            }
        }

        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .externalEdit,
            changes: changes,
            sequence: newSequence,
            provenance: .init(synthesisSource: "use_cloud_resolution"))
        try await opStore.append(op)
        _opLogMirror.append(op)
        invalidateAnnotationsCache()
        self.paragraphs = newParagraphs
        self.sequence = newSequence
        self.lastWrittenText = diskMd
        // T12: auto-archive annotations anchored to paragraphs that vanished
        // in the force-ingest from disk.
        await sweepOrphanedAnnotations()
        recomputeDisplayText()
    }

    private func writeConflictBackup(text: String, kind: String) throws {
        let projectURL = url.deletingLastPathComponent()
            .deletingLastPathComponent()
        let conflictsDir = projectURL.appendingPathComponent(".maugham/conflicts")
        try FileManager.default.createDirectory(
            at: conflictsDir, withIntermediateDirectories: true)
        let filename = url.lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupName = ext.isEmpty
            ? "\(stem)-\(kind)-\(stamp)"
            : "\(stem)-\(kind)-\(stamp).\(ext)"
        let backupURL = conflictsDir.appendingPathComponent(backupName)
        try text.data(using: .utf8)?.write(to: backupURL, options: [.atomic])
    }
}

/// Looks up the doc-id for a manuscript path. For now resolves via the
/// manifest if available; falls back to a deterministic hash of the
/// relative path. Test helper; real lookup will use ProjectStore.
internal func resolveDocId(for url: URL) throws -> String {
    let projectURL = url.deletingLastPathComponent()
        .deletingLastPathComponent()
    let manifestURL = projectURL
        .appendingPathComponent("project.maugham.json")
    let relativePath = url.path
        .replacingOccurrences(of: projectURL.path + "/", with: "")
    if let data = try? Data(contentsOf: manifestURL) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let manifest = try? dec.decode(ProjectManifest.self, from: data),
           let item = findItemByPath(relativePath, in: manifest.structure) {
            return item.id
        }
    }
    // Fallback: deterministic id from path. Sufficient for tests.
    return "doc-\(relativePath.hashValue.magnitude)"
}

private func findItemByPath(_ path: String, in items: [StructureItem]) -> StructureItem? {
    for item in items {
        if item.path == path { return item }
        if let kids = item.children,
           let found = findItemByPath(path, in: kids) { return found }
    }
    return nil
}

/// Indirection so BurstScheduler's fire closure can reference the
/// Document without a retain cycle.
@MainActor
private final class WeakBurstHolder {
    weak var document: Document?
}

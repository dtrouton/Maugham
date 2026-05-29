import Foundation
import MaughamCore
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

    /// Snapshot of "the last bytes we know are on disk, because we put them
    /// there." Used by `handleExternalDiskChange` to skip echoes: when the
    /// presenter fires after our own autosave or our own ingest, `diskMd`
    /// will equal `lastDiskEcho.bytes` and the change is a no-op.
    ///
    /// Mutation is restricted to the autosave path, the silent-ingest branch
    /// of `handleExternalDiskChange`, and `handleExternalDiskChangeForceIngest`
    /// — see `EchoState.afterWrite(bytes:)`. Anything else trying to assign
    /// here is a contract violation; the typed wrapper exists specifically
    /// to keep that surface small.
    private var lastDiskEcho: EchoState

    private var _annotationsCache: [Annotation] = []
    private var _annotationsCacheValid: Bool = false
    public private(set) var annotationsVersion: Int = 0

    // Task cache mirrors the annotation cache pattern. Invalidated alongside
    // every annotation invalidation site so paragraph mutations, lifecycle
    // ops, and external-log merges all refresh task derivation too.
    // See `docs/superpowers/specs/2026-05-23-tasks-design.md` §6.
    private var _tasksCache: [WriterTask] = []
    private var _tasksCacheValid: Bool = false
    public private(set) var tasksVersion: Int = 0

    /// Re-entrancy guard for `rebuildTasksCache`. Appending rebalance ops
    /// triggers `invalidateTasksCache()` (rebalance ops are
    /// `.taskPriorityChange`, an invalidating kind). Without this guard the
    /// next `tasks(filter:)` call would rebuild again. The rebalance is
    /// mathematically idempotent (next derive emits zero rebalance ops since
    /// priorities are now well-spaced), so this guard makes the invariant
    /// *enforceable in tests* — not because there's a correctness hole.
    private var _isRebuildingTasks: Bool = false

    /// Mirror of every op append for synchronous annotation derivation.
    /// Populated at load(...) with the result of opStore.load, then kept
    /// in sync by every mutation path that calls opStore.append.
    fileprivate var _opLogMirror: [Op] = []

    /// Diagnostic accessor: size of the in-memory op log mirror.
    public var opLogMirrorCount: Int { _opLogMirror.count }

    /// Synchronous read of the in-memory op log mirror. Distinct from
    /// `opLog()` (the disk-backed async accessor) — this reads what's been
    /// observed by every in-process mutation path. Used by tests + the task
    /// cache to derive tasks without an async hop.
    public var opLogSnapshot: [Op] { _opLogMirror }

    /// Sticky flag: true once the doc has ever had an annotation op
    /// (creation OR lifecycle). Lets the hot typing path short-circuit
    /// per-keystroke annotation work (invalidateAnnotationsCache + sweep)
    /// when the document has never seen an annotation, which is the common
    /// case. Set at load() time by scanning the mirror, and stays true once
    /// flipped — annotations are append-only, so the flag only ratchets up.
    private var _hasAnyAnnotationOps: Bool = false

    /// Last observed cursor position from the editor's selection-change
    /// notifications. Updated via `recordCursorAt(_:)`. Used by `setFullText`
    /// as the pre-edit cursor input to V2 task-anchor alignment when an
    /// explicit value isn't passed by the caller (e.g., legacy code paths
    /// and tests that don't thread cursor info).
    private var _lastSeenCursor: Int? = nil

    /// Pending post-edit cursor position, captured by the editor coordinator
    /// inside `textDidChange` just before the binding setter fires. Consumed
    /// by the next `setFullText` call (cleared in the process). When unset,
    /// V2 alignment degrades to per-paragraph (no cross-paragraph cut/paste
    /// detection) — see spec §2.4.3.
    private var _pendingPostEditCursor: Int? = nil

    /// Pending orphan-annotation sweep carrying the *exact* paragraph ids
    /// observed disappearing since the last sweep. Replaces the older
    /// `_pendingOrphanSweep: Bool` flag — see `SweepReason.swift` for the
    /// rationale.
    ///
    /// Sweep is gated on this value rather than on `!pending.isEmpty()`
    /// because paragraph DELETIONS don't write anything to `pending` —
    /// `setFullText` only records changes for paragraphs in `nextParsed`,
    /// so a deletion produces an empty pending. Without the explicit
    /// removed-set, the alternatives were either spurious sweeps (a
    /// transient `Document` close fires `flushBurstNow` against a
    /// reconstructed sequence and falsely archives every paragraph-anchored
    /// annotation whose id isn't in the reconstructed view) or missed
    /// sweeps (gate on pending and never run sweep on legitimate deletions).
    private var _pendingSweep: SweepReason? = nil

    /// Hot-path check whether any of the seven annotation-related OpKinds
    /// has ever been observed on this document. Reads the cached flag.
    /// Whether a paragraph-text delta touches inline-task markup. Used to
    /// gate the tasks-cache invalidation fast path so non-checkbox typing
    /// stays off the observable-write hot loop (annotation cache + sweep
    /// pay the same observation cost and are intentionally deferred to
    /// burst flush — see setFullText note for the AttributeGraph cycle /
    /// reentrant-layout history). Two markup syntaxes count:
    ///
    /// - Markdown `- [ ]` / `- [x]` (3-char bracket glyph)
    /// - Fountain `[[todo: …]]` / `[[done: …]]`
    ///
    /// True when either prior or next text contains a checkbox/todo
    /// marker — covers add, remove, and toggle equally. Cheap substring
    /// scan; no regex needed because the body-hash deriver re-runs on
    /// the cache rebuild anyway.
    private static func changeTouchesTaskMarkup(
        prior: String?, next: String?
    ) -> Bool {
        func hasMarkup(_ s: String) -> Bool {
            return s.contains("- [ ]") || s.contains("- [x]")
                || s.contains("[[todo:") || s.contains("[[done:")
        }
        if let p = prior, hasMarkup(p) { return true }
        if let n = next, hasMarkup(n) { return true }
        return false
    }

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
        lastDiskEcho: EchoState
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
        self.lastDiskEcho = lastDiskEcho
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

        // projectURL is wherever `project.maugham.json` lives. Walk up
        // from the doc's URL until we find it. For Novel/Screenplay this
        // is 2 levels up (manuscript/<file>.md → project/); for Collection
        // it can be 3 (pieces/<piece-folder>/<file>.md → project/) or
        // deeper for research notes. Defaulting to a fixed 2-level
        // deletingLastPathComponent landed inside the piece folder for
        // Collections and made every .maugham/ops/<docId>.jsonl path
        // resolve to a non-existent location, silently dropping ops.
        let projectURL = resolveProjectURL(for: url)

        // Bootstrap detection. Per-device partitioning (ADR 0012) means a doc's
        // log may exist only as `<docId>.<slug>.jsonl` with no legacy
        // `<docId>.jsonl`; check the whole globbed set, or a doc whose only
        // writer was a non-current device reads as "no log" and re-bootstraps.
        let logExists = !OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL).isEmpty
        let storedBytes = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let parsed = ParagraphParser.parse(storedBytes)
        // `parsed.isEmpty` (empty .md) used to satisfy `allSatisfy { id == nil }`
        // vacuously, triggering bootstrap that emitted a junk op with empty
        // changes + empty sequence. Filter empty .md out explicitly. The
        // empty case happens transiently for newly-created docs before
        // first autosave; there's nothing to bootstrap. Bootstrap.run also
        // has its own empty-parsed guard, so this is belt-and-braces.
        let needsBootstrap = (!logExists || parsed.allSatisfy { $0.id == nil })
            && !parsed.isEmpty

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
        // Capture sequence from the parsed .md — autosave wrote the .md
        // after the last burst flushed, so its paragraph anchor ordering
        // is more current than the op log's last-explicit sequence. Without
        // this the recovered op leaves sequence at whatever the last
        // bursted op said (often a stale shape from before the user split
        // / inserted paragraphs), which strands new paragraph ids out of
        // sequence and collapses displayText to the stale ordering.
        if !pending.isEmpty() {
            let recoveredSequence = parsed.compactMap(\.id)
            let recovered = Op(
                opId: ULID.generate(), docId: docId, at: Date(),
                device: device, session: session, kind: .typingBurst,
                changes: pending.snapshot(),
                sequence: recoveredSequence.isEmpty ? nil : recoveredSequence)
            try await opStore.append(recovered)
            try await pending.clear()
            ops.append(recovered)
        }

        var initial = Deriver.derive(ops: ops)
        // Two recovery paths from non-canonical op-log states:
        //
        // 1. Empty paragraphs + tagged on-disk file: `Bootstrap.run`
        //    short-circuited with `allHaveIds` so no bootstrap op was
        //    emitted. Seed paragraphs + sequence from the parsed file.
        //
        // 2. Non-empty paragraphs but empty sequence: an older typing_burst
        //    landed without populating its `sequence` field (predates the
        //    fix that always captures sequence on burst). The deriver
        //    leaves sequence=[] in that case, which collapses displayText
        //    to "" and stops the doc rendering. Recover the sequence from
        //    the parsed on-disk file's id order — that's the source of
        //    truth for paragraph ordering anyway.
        if initial.paragraphs.isEmpty && parsed.contains(where: { $0.id != nil }) {
            var paragraphs: [String: String] = [:]
            var sequence: [String] = []
            for p in parsed {
                guard let id = p.id else { continue }
                paragraphs[id] = p.text
                sequence.append(id)
            }
            initial = Deriver.DerivedState(paragraphs: paragraphs, sequence: sequence)
        } else if initial.sequence.isEmpty && !initial.paragraphs.isEmpty {
            // Legacy log: typing_burst captured changes but not the
            // `sequence` field. The on-disk .md is the more current source
            // for both paragraph text AND order — autosave runs faster
            // than the burst scheduler so the .md reflects edits the op
            // log hasn't seen yet (e.g., user split a paragraph by adding
            // blank lines; autosave wrote the new anchors but the typing
            // burst hasn't fired yet so the new paragraph_ids aren't in
            // initial.paragraphs).
            //
            // Trust parsed entirely when it has anchored paragraphs.
            // Without this, addAnnotation for a freshly-minted paragraph
            // id reads paragraphs[id]=nil and persists prior_text=nil,
            // which silently breaks the staleness check for every
            // markdown annotation on a legacy doc.
            var freshParagraphs: [String: String] = [:]
            var freshSequence: [String] = []
            for p in parsed {
                guard let id = p.id else { continue }
                freshParagraphs[id] = p.text
                freshSequence.append(id)
            }
            if !freshSequence.isEmpty {
                initial = Deriver.DerivedState(
                    paragraphs: freshParagraphs, sequence: freshSequence)
            } else {
                // .md has no anchored content — fall back to whatever
                // the op log gave us so the doc still renders.
                initial = Deriver.DerivedState(
                    paragraphs: initial.paragraphs,
                    sequence: Array(initial.paragraphs.keys))
            }
        }

        // 3. Stale-sequence recovery. The op log's last explicit sequence
        //    may predate paragraph splits / inserts that autosave wrote
        //    to .md but the typing burst never captured (e.g., crash
        //    before flush, or the legacy crash-recovery path above prior
        //    to its sequence fix). When the parsed .md contains anchored
        //    paragraph ids that are NOT in `initial.sequence`, the .md is
        //    the more current source — trust its ordering.
        //
        //    Also drop orphan entries from `paragraphs` whose ids the
        //    new (parsed) sequence doesn't reference. Leaving them in
        //    place pollutes `tasks(filter:)` (the deriver walks every
        //    paragraph in `paragraphs`, not just those in `sequence`)
        //    with stale inline-task derivations.
        let parsedIds = parsed.compactMap(\.id)
        if !parsedIds.isEmpty {
            let parsedIdSet = Set(parsedIds)
            let sequenceIdSet = Set(initial.sequence)
            let parsedHasIdsNotInSequence = !parsedIdSet.isSubset(of: sequenceIdSet)
            let sequenceHasIdsNotInParsed = !sequenceIdSet.isSubset(of: parsedIdSet)
            if parsedHasIdsNotInSequence || sequenceHasIdsNotInParsed {
                var freshParagraphs: [String: String] = [:]
                for p in parsed {
                    guard let id = p.id else { continue }
                    // Prefer the op log's text if the op log knows this id
                    // (it may carry edits autosave hasn't redrawn yet);
                    // fall back to the parsed text otherwise.
                    freshParagraphs[id] = initial.paragraphs[id] ?? p.text
                }
                initial = Deriver.DerivedState(
                    paragraphs: freshParagraphs, sequence: parsedIds)
            }
        }

        // 4. Orphan-paragraph drop. Even when sequence and parsed agree,
        //    `paragraphs` can still carry entries for ids the writer
        //    split / merged away in earlier sessions (typing_burst doesn't
        //    delete entries from the deriver's accumulator, only updates
        //    them; once a paragraph_id is dropped from `sequence` its
        //    last-known text lingers forever in the in-memory map).
        //    These orphans poison the inline-task deriver (it walks every
        //    paragraph, not just sequence) — surfacing phantom checkbox
        //    rows in the Tasks pane that have no matching paragraph in
        //    the .md. Restrict `paragraphs` to keys in `sequence`.
        if !initial.sequence.isEmpty {
            let sequenceIdSet = Set(initial.sequence)
            let paragraphsHasOrphans = initial.paragraphs.keys.contains {
                !sequenceIdSet.contains($0)
            }
            if paragraphsHasOrphans {
                let trimmed = initial.paragraphs.filter {
                    sequenceIdSet.contains($0.key)
                }
                initial = Deriver.DerivedState(
                    paragraphs: trimmed, sequence: initial.sequence)
            }
        }
        let lastWritten = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let initialEcho = EchoState.initialLoad(bytes: lastWritten)

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
            lastDiskEcho: initialEcho)
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
            // Strip per-task `<!--t-XXXXXX-->` anchors from each paragraph
            // for editor display. The anchors are intentionally kept in
            // `paragraphs[id]` so V2 alignment can round-trip them through
            // `setFullText`; they only matter on disk + in op-log derivation,
            // never as visible glyphs in the editor. Mirror of how paragraph
            // anchors live in the .md but never in `displayText`.
            rendered.append(RenderFilter.stripTaskAnchorsInline(text))
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
                self.lastDiskEcho = .afterWrite(bytes: bytes)
            } catch {
                writeErr = error
            }
        }
        if let coordErr { throw coordErr }
        if let writeErr { throw writeErr }
    }

    /// Returns the paragraph id of the paragraph containing `location` in
    /// `displayText`, or nil if no `<!-- ¶id -->` comment precedes `location`
    /// in the current materialized text. The id is recovered by scanning
    /// backwards from `location` for the nearest preceding inline-comment
    /// anchor in the materialized (stored) form, which includes the anchors
    /// that `displayText` strips.
    ///
    /// Cost: O(characters up to `location`). Fine at human typing speed
    /// (a few times per second) even for large manuscripts (~100 KB).
    /// Returns the current text of the paragraph with the given id, or nil
    /// if the id isn't in `sequence`. Read-only; mutation goes through
    /// `setParagraph(id:text:)`. Used by editor click handlers (e.g.,
    /// markdown-checkbox toggle) to read the in-memory paragraph before
    /// writing a flipped variant back.
    public func paragraph(id: String) -> String? {
        return paragraphs[id]
    }

    public func paragraphId(at location: Int) -> String? {
        // We need the materialized form (which retains <!-- ¶id --> anchors)
        // because displayText strips them. Walk the materialized text up to
        // the corresponding offset and remember the last anchor seen.
        //
        // Mapping from displayText offset to materialized offset is
        // non-trivial, so instead we walk the paragraphs in sequence order —
        // the same order as displayText — accumulating display-offset to find
        // which paragraph the cursor is in, then return that paragraph's id.
        let clamped = max(0, min(location, displayText.count))
        var offset = 0
        for id in sequence {
            guard let text = paragraphs[id] else { continue }
            let length = text.count
            // The paragraph covers [offset, offset + length).
            // The "\n\n" separator is at [offset+length, offset+length+2).
            // Cursor at offset+length is still "inside" this paragraph
            // (end of its content, before the separator).
            if clamped <= offset + length {
                return id
            }
            offset += length + 2  // +2 for "\n\n" separator
        }
        // Cursor is past all paragraphs — return the last id if any.
        return sequence.last
    }

    /// Returns the NSRange within `displayText` covering the paragraph with
    /// the given id, or nil if the id isn't in `sequence`. Used by editor
    /// navigation (e.g., clicking an annotation row jumps the textView to
    /// the anchored paragraph). The range corresponds to the stripped
    /// display form — anchors aren't visible there — and to the structure
    /// that `recomputeDisplayText` produces: paragraphs joined by "\n\n".
    public func displayRange(forParagraphId paragraphId: String) -> NSRange? {
        // Compute offsets against the STRIPPED form (what the editor shows).
        // `paragraphs[id]` carries `<!--t-XXXXXX-->` task anchors that don't
        // appear in displayText. Using raw lengths here drifted every
        // paragraph's offset by the cumulative anchor-character count of
        // prior paragraphs — the last paragraph was most wrong, which is
        // why "click last task" missed the target paragraph (Bug 1) and
        // earlier clicks landed a few characters past paragraph start
        // (Bug 3).
        var offset = 0
        for id in sequence {
            guard let text = paragraphs[id] else { continue }
            let stripped = RenderFilter.stripTaskAnchorsInline(text)
            let length = (stripped as NSString).length
            if id == paragraphId {
                return NSRange(location: offset, length: length)
            }
            offset += length
            offset += 2  // "\n\n" separator between paragraphs
        }
        return nil
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

    // MARK: - Task read API

    /// Project the current op log + paragraph map into the filtered task
    /// list. Same caching pattern as `annotations(filter:)`. Inline-task
    /// status is text-is-state (read from paragraph contents); pane-created
    /// task lifecycle rides the op log. See spec §6.
    public func tasks(filter: TaskFilter) -> [WriterTask] {
        if !_tasksCacheValid { rebuildTasksCache() }
        return _tasksCache.filter { task in
            guard filter.statuses.contains(task.status) else { return false }
            switch filter.scope {
            case .document(let scopeDocId):
                return task.anchor?.docId == scopeDocId
            case .project:
                return true
            }
        }
    }

    fileprivate func invalidateTasksCache() {
        _tasksCacheValid = false
        tasksVersion &+= 1
    }

    private func rebuildTasksCache() {
        guard !_isRebuildingTasks else {
            // Re-entrancy guard: rebalance op append triggers
            // invalidateTasksCache, AND so does the .taskCreate op emitted
            // per minted anchor in this same rebuild. Both arrive during
            // an in-flight derive whose result is mathematically idempotent
            // for the next call (rebalance has well-spaced priorities, mints
            // have anchored bodies that the deriver leaves alone). Returning
            // early here is the correct outcome — the freshly invalidated
            // cache will lazily rebuild on the next external `tasks(filter:)`
            // call.
            return
        }
        _isRebuildingTasks = true
        defer { _isRebuildingTasks = false }

        let (tasks, rebalanceOps, mintedAnchors) = TaskDeriver.derive(
            ops: _opLogMirror, paragraphs: paragraphs, docId: docId)
        _tasksCache = tasks
        _tasksCacheValid = true

        // Persist minted anchors back into paragraph text so autosave writes
        // the anchored .md on the next 750ms cycle. The mutation to
        // `paragraphs` is silent: we don't invalidate the tasks cache (we
        // already have the derive result — and the next derive against the
        // newly anchored paragraphs would produce zero new mints). The
        // .taskCreate ops we emit per mint give cross-Mac merge an
        // authoritative creation timestamp + session id; appendTaskOpInternal
        // does invalidate the cache but the re-entrancy guard catches that
        // and short-circuits, which is exactly the intended behavior.
        if !mintedAnchors.isEmpty {
            applyMintedAnchors(mintedAnchors)
            for mint in mintedAnchors {
                let synth = "inline:\(docId):\(mint.anchorId)"
                let op = Op(
                    opId: ULID.generate(),
                    docId: docId, at: Date(),
                    device: device, session: session,
                    kind: .taskCreate,
                    changes: [], sequence: nil,
                    provenance: Op.Provenance(
                        sessionId: session,
                        taskId: synth,
                        taskBody: mint.body,
                        taskKind: mint.kind.rawValue))
                appendTaskOpInternal(op)
            }
            autosaveScheduler.schedule(())
        }

        // TaskDeriver returns rebalance ops with placeholder ids
        // ("rebalance_<task_id>") for determinism inside the pure projection.
        // Rewrite each to a freshly-minted ULID and append via the standard
        // path. The rebalance is mathematically idempotent (next derive
        // emits zero rebalance ops since priorities are now well-spaced),
        // so the re-invalidation triggered by the appends is harmless.
        for op in rebalanceOps {
            let standardized = op.withReplacedOpId(ULID.generate())
            appendTaskOpInternal(standardized)
        }
    }

    /// Splice freshly-minted task anchors back into paragraph text. Each
    /// `MintedAnchor` carries the paragraph id, line index, and (for
    /// Fountain inline tasks) an intra-line UTF-16 offset for the anchor
    /// span insertion point. Markdown line-style tasks get the anchor
    /// appended at end-of-line with a separating space.
    ///
    /// Mutates `paragraphs` directly and records the new text in the
    /// pending buffer so the next `typingBurst` op captures the anchored
    /// form — without this, the .md on disk would carry anchors but the
    /// op log would replay the un-anchored prior text and clobber them
    /// on reload (Deriver folds typing_burst into the paragraph map,
    /// taking precedence over disk parse). Does NOT invalidate the tasks
    /// cache; the caller — `rebuildTasksCache` — already holds the
    /// post-mint derive result.
    private func applyMintedAnchors(_ mints: [TaskDeriver.MintedAnchor]) {
        // Group by paragraph so we apply all mints to a paragraph in one
        // splice pass (line indices remain stable when we walk lines once).
        var byParagraph: [String: [TaskDeriver.MintedAnchor]] = [:]
        for mint in mints {
            byParagraph[mint.paragraphId, default: []].append(mint)
        }
        for (pid, group) in byParagraph {
            guard let current = paragraphs[pid] else { continue }
            var lines = current.split(
                separator: "\n", omittingEmptySubsequences: false
            ).map(String.init)
            // Sort mints within a line by descending intraLineOffset so the
            // earlier insertion doesn't shift offsets for later ones on the
            // same line. Cross-line ordering doesn't matter because each
            // line is mutated independently.
            let sorted = group.sorted { a, b in
                if a.lineIndex != b.lineIndex { return a.lineIndex < b.lineIndex }
                let aOff = a.intraLineOffset ?? Int.max
                let bOff = b.intraLineOffset ?? Int.max
                return aOff > bOff
            }
            for mint in sorted {
                guard mint.lineIndex >= 0, mint.lineIndex < lines.count else {
                    continue
                }
                let comment = TaskAnchorID.formatComment(mint.anchorId)
                let line = lines[mint.lineIndex]
                if let intra = mint.intraLineOffset {
                    // Fountain inline: splice anchor at the UTF-16 offset.
                    let ns = line as NSString
                    if intra >= 0 && intra <= ns.length {
                        let head = ns.substring(with: NSRange(location: 0, length: intra))
                        let tail = ns.substring(from: intra)
                        lines[mint.lineIndex] = head + comment + tail
                    }
                } else {
                    // Markdown line-style: append at end-of-line with a space
                    // separator (matches the format the deriver expects).
                    lines[mint.lineIndex] = "\(line) \(comment)"
                }
            }
            let priorText = paragraphs[pid]
            let nextText = lines.joined(separator: "\n")
            paragraphs[pid] = nextText
            // Record into pending so the next typing_burst carries the
            // anchored form. Without this, reload-from-log replays the
            // un-anchored prior text into paragraphs and strips the anchor.
            pending.recordChange(
                paragraphId: pid, prior: priorText, next: nextText)
            burstScheduler.recordActivity()
        }
    }

    /// Sync helper for task-lifecycle and rebalance ops. Updates the
    /// in-memory mirror immediately so the next `tasks(filter:)` reflects
    /// the change without waiting for the async disk append. Fires a
    /// fire-and-forget `opStore.append` so the op also lands in
    /// `.maugham/ops/<docId>.jsonl`. JSONLAppendStore dedupes by opId, so
    /// even pathological re-entry is safe on disk.
    private func appendTaskOpInternal(_ op: Op) {
        _opLogMirror.append(op)
        invalidateTasksCache()
        // Annotation cache only invalidates for annotation ops — task ops
        // don't change annotation derivation, so skip the bump.
        let store = opStore
        Task { @MainActor in
            try? await store.append(op)
        }
    }

    // MARK: - Task mutation API

    /// Create a new pane-anchored task on this document. Returns a synthetic
    /// preview `WriterTask`; the real derived task lands via the deriver on
    /// the next `tasks(filter:)` call (and matches this preview field-for-
    /// field by construction).
    @discardableResult
    public func createPaneTask(body: String, parentTaskId: String?) -> WriterTask {
        let opId = ULID.generate()
        let priority = lowestPriorityForDoc() + 1.0
        let parentField: String? = parentTaskId
        let op = Op(
            opId: opId,
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskCreate,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: opId,
                taskBody: body,
                taskPriority: priority,
                taskParentId: parentField,
                taskKind: TaskKind.paneCreated.rawValue))
        appendTaskOpInternal(op)
        return WriterTask(
            id: opId, kind: .paneCreated,
            anchor: TaskAnchor(docId: docId, paragraphId: nil),
            body: body, status: .open, priority: priority,
            parentTaskId: parentTaskId,
            createdAt: op.at,
            createdBySession: session)
    }

    public func setTaskStatus(id: String, status: TaskStatus) {
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskStatusChange,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskStatus: status.rawValue))
        appendTaskOpInternal(op)
    }

    public func setTaskPriority(id: String, priority: Double) {
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskPriorityChange,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskPriority: priority))
        appendTaskOpInternal(op)
    }

    public func setTaskParent(id: String, parentTaskId: String?) {
        // "" sentinel clears parent (matches TaskDeriver convention); any
        // non-empty value sets it. The deriver maps "" → nil on read.
        let parentField = parentTaskId ?? ""
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskParentChange,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskParentId: parentField))
        appendTaskOpInternal(op)
    }

    public func editPaneTaskBody(id: String, body: String) {
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskBodyEdit,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskBody: body))
        appendTaskOpInternal(op)
    }

    public func archiveTask(id: String) {
        // Capture body + kind BEFORE archiving so the .taskArchive op
        // carries enough info for the deriver to synthesize an entry in
        // the Archived filter. Inline tasks become derive-invisible after
        // archive (the anchor is spliced out of paragraph text); without
        // this metadata they'd vanish from the pane entirely, losing the
        // audit trail.
        let archived = _tasksCache.first(where: { $0.id == id })

        // Emit the .taskArchive op first so the lifecycle event lands in the
        // op log even when no anchor can be located (pane-created tasks, or
        // an inline anchor that's already been spliced out of the .md).
        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .taskArchive,
            changes: [], sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                taskId: id,
                taskBody: archived?.body,
                taskKind: archived?.kind.rawValue))
        appendTaskOpInternal(op)

        // Extract the anchor id from the synth-id. Pane-created tasks have
        // `id == opId` (no `inline:` prefix) and never carry inline text —
        // op-only archive is sufficient.
        guard let anchorId = Self.extractAnchorId(fromTaskId: id) else { return }
        guard let location = locateTaskAnchor(anchorId: anchorId) else {
            // Anchor isn't in any paragraph — already spliced out or never
            // present (e.g. stale tasks pane row). Op-only archive.
            return
        }

        guard let para = paragraphs[location.paragraphId] else { return }
        let mutated = Self.spliceArchivedTask(
            from: para,
            anchorRangeInLine: location.anchorRangeInLine,
            lineIndex: location.lineIndex)
        if mutated.isEmpty {
            // Sole task in the paragraph → paragraph collapses. The sweep
            // reason carries the removed id so annotations on it archive
            // through the normal path.
            deleteParagraph(id: location.paragraphId)
        } else {
            setParagraph(id: location.paragraphId, text: mutated)
        }
    }

    /// Extract the 6-char anchor id from a task synth-id of the form
    /// `inline:<docId>:<anchorId>`. Returns nil for pane-created task ids
    /// (which are bare ULIDs with no `inline:` prefix).
    internal static func extractAnchorId(fromTaskId id: String) -> String? {
        guard id.hasPrefix("inline:") else { return nil }
        // docId can itself be arbitrary, but task synth-ids always end with
        // `:<anchorId>` and anchorId never contains `:`. Trailing component.
        guard let lastColon = id.lastIndex(of: ":") else { return nil }
        let anchor = String(id[id.index(after: lastColon)...])
        return TaskAnchorID.parseComment(TaskAnchorID.formatComment(anchor))
    }

    /// Find a task anchor across all paragraphs in `paragraphs` (not just
    /// those in `sequence` — defensive against orphan paragraphs that haven't
    /// been pruned yet). Returns the (paragraphId, 0-based line index within
    /// that paragraph, NSRange of the anchor span within that line).
    internal func locateTaskAnchor(
        anchorId: String
    ) -> (paragraphId: String, lineIndex: Int, anchorRangeInLine: NSRange)? {
        let target = TaskAnchorID.formatComment(anchorId)
        // Walk in sequence order first so the result is deterministic when
        // an orphan paragraph also happens to contain the anchor.
        var visited = Set<String>()
        for pid in sequence {
            visited.insert(pid)
            if let hit = Self.locateAnchor(target, in: paragraphs[pid] ?? "") {
                return (pid, hit.lineIndex, hit.range)
            }
        }
        for (pid, text) in paragraphs where !visited.contains(pid) {
            if let hit = Self.locateAnchor(target, in: text) {
                return (pid, hit.lineIndex, hit.range)
            }
        }
        return nil
    }

    private static func locateAnchor(
        _ target: String, in paragraph: String
    ) -> (lineIndex: Int, range: NSRange)? {
        let lines = paragraph.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            let ns = line as NSString
            let r = ns.range(of: target)
            if r.location != NSNotFound {
                return (idx, r)
            }
        }
        return nil
    }

    /// Splice an archived task out of its paragraph text per spec §2.7.
    ///
    /// - Line-style (`- [ ] body <!--t-XXXXXX-->`): delete the whole line +
    ///   its terminating `\n` (or the leading `\n` if last line). If only
    ///   one line existed, returns "" so the caller can collapse the
    ///   paragraph.
    /// - Inline (`[[todo: body]]<!--t-XXXXXX-->` mid-prose): splice the
    ///   bracketed segment + its anchor; collapse one adjacent whitespace
    ///   when both sides are whitespace-bordered. When only one side is
    ///   whitespace, splice the segment + that one whitespace. When neither
    ///   side is whitespace (word-glue, rare), splice only the segment.
    internal static func spliceArchivedTask(
        from paragraph: String,
        anchorRangeInLine: NSRange,
        lineIndex: Int
    ) -> String {
        let lines = paragraph.components(separatedBy: "\n")
        guard lineIndex >= 0, lineIndex < lines.count else { return paragraph }
        let line = lines[lineIndex]
        let ns = line as NSString

        // Decide line-style vs inline by whether the line — once stripped of
        // the anchor — matches the markdown checkbox shape. The anchor sits
        // at the very end of a line-style task: anything between `]` and
        // the anchor is whitespace + body + optional trailing space.
        let checkboxPrefix = try! NSRegularExpression(
            pattern: #"^\s*- \[(?: |x)\] "#)
        let prefixMatch = checkboxPrefix.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length))
        let anchorAtLineEnd = (anchorRangeInLine.location
            + anchorRangeInLine.length == ns.length)
        let isLineStyle: Bool = {
            guard let m = prefixMatch else { return false }
            guard anchorAtLineEnd else { return false }
            // The anchor must be the only `<!--t-…-->` span on this line for
            // line-style treatment — multiple-anchors-per-line falls through
            // to the inline splice path. (Multi-anchor lines are unusual for
            // checkbox lines but possible if a writer types one inline.)
            let countRegex = try! NSRegularExpression(
                pattern: #"<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->"#)
            let count = countRegex.numberOfMatches(
                in: line, range: NSRange(location: 0, length: ns.length))
            _ = m  // suppress unused-warning when count != 1
            return count == 1
        }()

        if isLineStyle {
            // Delete the entire line, plus one surrounding `\n`. Joining the
            // remaining lines with "\n" handles both:
            //   - middle / first line: leading `\n` of next line is dropped
            //     implicitly by the join.
            //   - last line: the trailing `\n` before this line is dropped
            //     because we remove the array element before joining.
            var mutated = lines
            mutated.remove(at: lineIndex)
            return mutated.joined(separator: "\n")
        }

        // Inline splice. Find the full bracketed segment + anchor span. The
        // anchor span ends at `anchorRangeInLine.upperBound`; the segment
        // start is the leftmost `[[` before the anchor whose matched
        // `[[(todo|done): …]]<!--t-XXXXXX-->` ends exactly at the anchor.
        let segmentPattern = #"\[\[(?:todo|done):\s*.*?\]\]<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->"#
        // swiftlint:disable:next force_try
        let segmentRegex = try! NSRegularExpression(pattern: segmentPattern)
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = segmentRegex.matches(in: line, range: fullRange)
        guard let segment = matches.first(where: { match in
            // Match ends exactly at the anchor's end → this is the bracketed
            // segment that owns the target anchor.
            match.range.location + match.range.length
                == anchorRangeInLine.location + anchorRangeInLine.length
        }) else {
            // Couldn't pair a `[[…]]` to this anchor (malformed inline; e.g.
            // glued anchor with no preceding `[[`). Conservative: drop only
            // the anchor span itself.
            let mutatedLine = ns.replacingCharacters(
                in: anchorRangeInLine, with: "")
            return Self.replaceLine(lines, at: lineIndex, with: mutatedLine)
        }

        let segRange = segment.range
        let before = segRange.location == 0
            ? ""
            : ns.substring(with: NSRange(
                location: segRange.location - 1, length: 1))
        let afterStart = segRange.location + segRange.length
        let after = afterStart >= ns.length
            ? ""
            : ns.substring(with: NSRange(location: afterStart, length: 1))
        let leftIsWS = !before.isEmpty
            && before.rangeOfCharacter(from: .whitespaces) != nil
        let rightIsWS = !after.isEmpty
            && after.rangeOfCharacter(from: .whitespaces) != nil

        var spliceStart = segRange.location
        var spliceLength = segRange.length
        if leftIsWS && rightIsWS {
            // Both sides whitespace → consume the LEADING whitespace char
            // (collapses "X _seg_ Y" to "X Y").
            spliceStart -= 1
            spliceLength += 1
        } else if leftIsWS && !rightIsWS {
            // Only left whitespace → consume it (trailing-of-paragraph case
            // "X _seg_$" → "X$").
            spliceStart -= 1
            spliceLength += 1
        } else if !leftIsWS && rightIsWS {
            // Only right whitespace → consume it (start-of-paragraph case
            // "^_seg_ X" → "X").
            spliceLength += 1
        }
        // else: neither side whitespace (word-glue) → splice only the segment

        let spliceRange = NSRange(location: spliceStart, length: spliceLength)
        let mutatedLine = ns.replacingCharacters(in: spliceRange, with: "")
        return Self.replaceLine(lines, at: lineIndex, with: mutatedLine)
    }

    private static func replaceLine(
        _ lines: [String], at index: Int, with newLine: String
    ) -> String {
        var mutated = lines
        mutated[index] = newLine
        return mutated.joined(separator: "\n")
    }


    /// Lowest priority across the doc's currently-derived tasks. Pane-created
    /// tasks get `lowest + 1.0` so they land at the head of the list (the
    /// user's most-recent-first reading default). Returns 0.0 when there are
    /// no tasks yet.
    private func lowestPriorityForDoc() -> Double {
        // Use the cached projection; build it if necessary.
        if !_tasksCacheValid { rebuildTasksCache() }
        let priorities = _tasksCache
            .filter { $0.anchor?.docId == docId }
            .map(\.priority)
        return priorities.min() ?? 0.0
    }

    // MARK: - Cursor side-channel for V2 task-anchor alignment

    /// Record the latest selection-change cursor offset. Called by the
    /// editor coordinator's `textViewDidChangeSelection` so V2 alignment in
    /// `setFullText` knows where the caret was *before* a text edit. Plain
    /// storage — no version bump, no cache invalidation, no observable
    /// surface. Cheap to call on every selection change.
    public func recordCursorAt(_ offset: Int) {
        _lastSeenCursor = offset
    }

    /// Record the post-edit cursor position captured by the editor
    /// coordinator inside `textDidChange`, just before the binding setter
    /// fires. Consumed by the next `setFullText` call. Like
    /// `recordCursorAt(_:)`, this is plain storage — no observation.
    public func recordPostEditCursor(_ offset: Int) {
        _pendingPostEditCursor = offset
    }

    // === Mutation API (Task 6) ===
    public func setFullText(
        _ text: String,
        preEditCursor: Int? = nil,
        postEditCursor: Int? = nil
    ) {
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

        // V2 task-anchor alignment (spec §2.4.1). Inputs:
        //   - priorById[id] is the *anchored* prior paragraph text.
        //   - nextParsed[*].text is the *anchor-free* new paragraph text
        //     (restoreComments parses the displayEdited form which strips
        //     task anchors).
        // The aligner re-injects task anchors per paragraph, runs a
        // cross-paragraph correlation pass to detect cut/paste with
        // cursor bias, and reports anchors that couldn't be paired —
        // those become .taskArchive ops at the end of this method.
        let effectivePre = preEditCursor ?? _lastSeenCursor
        let effectivePost = postEditCursor ?? _pendingPostEditCursor
        _pendingPostEditCursor = nil
        let alignment = TaskAnchorAlignment.align(
            priorById: priorById,
            nextParagraphs: nextParsed.compactMap { p -> (id: String, text: String)? in
                guard let id = p.id else { return nil }
                return (id, p.text)
            },
            priorSequence: sequence,
            nextSequence: nextParsed.compactMap(\.id),
            preEditCursor: effectivePre,
            postEditCursor: effectivePost)

        // Collect changes and the new sequence. Use the V2-restored
        // (anchor-bearing) paragraph text rather than the raw nextParsed
        // text so the on-disk .md keeps its anchors across the round-trip.
        var changes: [Op.ParagraphChange] = []
        var newSequence: [String] = []
        for p in nextParsed {
            guard let id = p.id else { continue }
            newSequence.append(id)
            let restored = alignment.restoredById[id] ?? p.text
            let prior = priorById[id]
            if prior != restored {
                changes.append(.init(paragraphId: id, prior: prior, next: restored))
                pending.recordChange(
                    paragraphId: id, prior: prior, next: restored)
            }
        }

        // Update internal derived state.
        var newParagraphs: [String: String] = paragraphs
        for change in changes {
            newParagraphs[change.paragraphId] = change.next
        }
        let sequenceChanged = (newSequence != sequence)
        // Detect paragraph DELETIONS — any id in the prior sequence that's
        // missing from the next sequence. Flag a sweep so the next burst
        // flush archives annotations anchored to removed paragraphs.
        let removedIds = Set(self.sequence).subtracting(Set(newSequence))
        if let reason = SweepReason.userTyped(removed: removedIds) {
            flagSweep(reason)
        }
        // Prune `paragraphs` entries whose ids left `sequence` — without
        // this, merging two paragraphs (or any edit that drops a
        // paragraph_id) leaves its last-known text lingering in the map.
        // The inline-task deriver walks every paragraph entry (not just
        // sequence members) so an orphan paragraph would surface as a
        // phantom task in the Tasks pane until the next reload. Same
        // invariant we enforce at load time (`paragraphs.keys ⊆ sequence`)
        // applied live during editing. Annotations sweep is already
        // gated on `removedIds` via the SweepReason above, so this is
        // safe — annotations attached to removed paragraphs flow through
        // their own archive path.
        for orphanId in removedIds {
            newParagraphs.removeValue(forKey: orphanId)
        }
        self.paragraphs = newParagraphs
        self.sequence = newSequence

        // Tickle the burst scheduler so the typing_burst op fires on
        // idle / max thresholds.
        if !changes.isEmpty || sequenceChanged {
            burstScheduler.recordActivity()
            autosaveScheduler.schedule(())
        }

        // Inline-task fast path. Tasks pane reactivity expects "type
        // `- [ ]` → row appears" within a keystroke or two. Without this,
        // the cache only invalidates on burst flush (30s idle), so newly
        // typed checkboxes don't surface until the user idles or switches
        // documents. Scan only the affected paragraph deltas — non-
        // checkbox typing stays off the observable-write hot loop per
        // the annotation-storm reasoning above.
        let touchesTasks = changes.contains { change in
            Self.changeTouchesTaskMarkup(
                prior: change.prior, next: change.next)
        }
        // Also invalidate when a paragraph was REMOVED — its inline
        // tasks vanish even though no `change` exists for the removed
        // id (setFullText only emits changes for parsed paragraphs).
        // Without this, merging two checkbox paragraphs leaves the
        // pre-merge inline tasks frozen in the cache.
        if touchesTasks || !removedIds.isEmpty
            || !alignment.archivedAnchors.isEmpty {
            invalidateTasksCache()
        }

        // V2 alignment Pass 3: emit .taskArchive ops for every prior task
        // anchor that couldn't be paired with a new line. The cause is
        // recorded in `provenance.userResponse = "user-deleted"` so the
        // history pane can distinguish writer-deleted-the-line from explicit
        // kebab-Archive. These ops route through appendTaskOpInternal which
        // invalidates the cache (already done above, idempotent).
        for archived in alignment.archivedAnchors {
            let synth = "inline:\(docId):\(archived.anchorId)"
            let op = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .taskArchive,
                changes: [], sequence: nil,
                provenance: Op.Provenance(
                    sessionId: session,
                    userResponse: "user-deleted",
                    taskId: synth))
            appendTaskOpInternal(op)
        }

        // Intentionally NO per-keystroke annotation work here. Earlier
        // attempts to invalidate the annotation cache and schedule a sweep
        // on every keystroke created an observable-write storm: AnnotationsPane
        // observes `annotations(filter:)`, whose evaluation transitively
        // observes `paragraphs` on the @Observable Document. Bumping
        // `annotationsVersion` on every keystroke triggered cascading
        // re-renders (AttributeGraph cycle detection + NSHostingView
        // reentrant-layout warnings + applyExternalText feedback into
        // NSTextView that desynced its spellchecker ranges).
        //
        // Staleness + paragraph-deletion auto-archive run at typing-burst
        // flush time (flushBurstNow) instead, which fires every 30s idle /
        // 90s max. That's invisible to the user but eliminates the hot
        // observable-write path.

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
        // Inline tasks are derived from paragraph text. The pane checkbox
        // click handler routes through here for status flips, and writers
        // expect the pane to refresh immediately — not at the 30s burst
        // boundary. Cheap guard: only invalidate when checkbox markup is
        // actually touched, keeping non-checkbox typing off the
        // observable-write hot path (see setFullText note for the cycle
        // /reentrant-layout history).
        if Self.changeTouchesTaskMarkup(prior: prior, next: text) {
            invalidateTasksCache()
        }
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
        // Annotation cache + sweep are deferred to flushBurstNow to keep
        // the keystroke path off the observable-write hot loop. See note in
        // setFullText for the cycle-detection / reentrant-layout reasoning.
        recomputeDisplayText()
        return newId
    }

    public func deleteParagraph(id: String) {
        guard paragraphs[id] != nil else { return }
        let priorText = paragraphs[id]
        paragraphs.removeValue(forKey: id)
        sequence.removeAll { $0 == id }
        if let reason = SweepReason.userTyped(removed: [id]) {
            flagSweep(reason)
        }
        // Record deletion as an op with empty next text (consumer-visible
        // marker that the paragraph went away; sequence change carries the
        // ordering).
        pending.recordChange(paragraphId: id, prior: priorText, next: "")
        burstScheduler.recordActivity()
        autosaveScheduler.schedule(())
        // Annotation cache + sweep are deferred to flushBurstNow to keep
        // the keystroke path off the observable-write hot loop. See note in
        // setFullText for the cycle-detection / reentrant-layout reasoning.
        recomputeDisplayText()
    }

    public func reorder(sequence: [String]) {
        self.sequence = sequence
        // No paragraph-change ops for pure reorder; the next typing_burst
        // emission will carry the new sequence as its `sequence` field.
        burstScheduler.recordActivity()
        autosaveScheduler.schedule(())
        // Annotation cache + sweep are deferred to flushBurstNow to keep
        // the keystroke path off the observable-write hot loop. See note in
        // setFullText for the cycle-detection / reentrant-layout reasoning.
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
        invalidateTasksCache()
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
    private func flagSweep(_ reason: SweepReason) {
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
    private func sweepOrphanedAnnotations(reason: SweepReason) async {
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

    public func flushBurstNow() async throws {
        let hadPending = !pending.isEmpty()
        if hadPending {
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
            try await pending.clear()
            // Inline tasks are derived from paragraph text — any pending
            // typing change may have added/removed/toggled a `- [ ]` line.
            // Invalidate unconditionally on burst; the cache rebuilds lazily
            // on the next `tasks(filter:)` read.
            invalidateTasksCache()
        }

        // Annotation maintenance — two separate gates:
        //
        // 1. Cache invalidation on `hadPending`: any paragraph text
        //    change means staleness may have flipped on existing
        //    annotations whose priorText snapshot no longer matches
        //    paragraphs[pid]. Refresh the cache so isStale recomputes.
        //
        // 2. Sweep on `_pendingSweep`: only run the orphan archive pass
        //    when this Document instance observed a paragraph being
        //    removed since the last sweep, and only against that exact
        //    removed set. This avoids transient-Document close (via MCP's
        //    `withAnnotationDocument` for `list_annotations`) from running
        //    sweep against a sequence reconstructed from disk that's
        //    missing in-memory paragraph ids the live editor has minted
        //    but not yet bursted — which falsely archived every
        //    paragraph-anchored annotation in the process.
        if _hasAnyAnnotationOps {
            if hadPending {
                invalidateAnnotationsCache()
            }
            if let reason = _pendingSweep {
                await sweepOrphanedAnnotations(reason: reason)
                _pendingSweep = nil
            }
        }
    }

    /// Restore this document to the state it had immediately after the op
    /// with id `targetOpId` was applied. Appends a `.checkpointRestore` op
    /// with `provenance.synthesisSource = .rewind` and
    /// `provenance.sourceCheckpoint = targetOpId` (the field is overloaded
    /// for rewinds — its value is a past op_id rather than a checkpoint_id
    /// when `synthesisSource == .rewind`).
    ///
    /// Flushes any pending typing burst first so a mid-typing rewind doesn't
    /// lose the in-flight characters from the forensic log. Updates the
    /// in-memory paragraph map, sequence, and displayText to match the
    /// target state. Flags an orphan-annotation sweep with cause `.rewind`
    /// for any paragraph ids that disappeared, then flushes again so the
    /// sweep emits its `.claudeArchive` ops before this method returns.
    ///
    /// Returns a `RewindRestoreResult` carrying the restore op, the archive
    /// op ids the sweep produced, and the prior/new sequence counts so
    /// callers (the rewind modal) can render an impact summary without
    /// rummaging through the op log post-hoc.
    public func restoreToOp(opId targetOpId: String) async throws -> RewindRestoreResult {
        // 1. Flush any pending burst so the rewind boundary is clean.
        try await flushBurstNow()

        // 2. Derive the current and target states from the in-memory mirror.
        let currentOps = _opLogMirror
        let currentState = Deriver.derive(ops: currentOps)
        let targetState = Deriver.derive(
            ops: currentOps,
            upTo: .atOp(opId: targetOpId, at: Date()))

        let priorCount = currentState.sequence.count
        let newCount = targetState.sequence.count
        let priorIds = Set(currentState.sequence)
        let newIds = Set(targetState.sequence)
        let removedIds = Array(priorIds.subtracting(newIds))

        // 3. Build the restore op. `Restore.buildRestoreOp` covers the
        //    text-change case (paragraphs whose content differs and
        //    paragraphs present in target but not current). It returns nil
        //    in two situations:
        //
        //    a) target == current → genuine no-op; return early.
        //    b) target is a strict subset of current (pure deletion) →
        //       no text changes but sequence shrinks; we still need to
        //       record the restore so the sequence delta lives in the log.
        //
        //    To distinguish (a) from (b), check whether the sequences differ.
        let buildResult = Restore.buildRestoreOp(
            current: currentState,
            target: targetState,
            scope: .document,
            docId: docId,
            device: device,
            session: session,
            sourceCheckpoint: targetOpId,
            synthesisSource: .rewind)

        let baseOp: Op
        if let built = buildResult {
            baseOp = built
        } else if currentState.sequence != targetState.sequence {
            // Pure-deletion rewind: no paragraph-text change, only a
            // sequence shrink. Emit a checkpoint_restore with empty
            // `changes` so the sequence field below carries the delta.
            baseOp = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .checkpointRestore,
                changes: [],
                sequence: nil,
                provenance: .init(
                    sourceCheckpoint: targetOpId,
                    synthesisSource: .rewind))
        } else {
            // (a) Manuscript text is unchanged (target == current). Check
            // whether there are any task-lifecycle ops after `targetOpId`.
            // If so, we still need to append a `.checkpointRestore` marker so
            // `TaskDeriver` can detect the rewind boundary and exclude those
            // task ops from derivation. Without this marker, the task cache
            // would continue to reflect the post-boundary task ops even though
            // the user rewound past them.
            let taskKinds: Set<OpKind> = [
                .taskCreate, .taskStatusChange, .taskPriorityChange,
                .taskParentChange, .taskBodyEdit, .taskArchive
            ]
            let targetIdx = currentOps.firstIndex(where: { $0.opId == targetOpId })
            let hasTaskOpsAfterTarget = targetIdx.map { idx in
                currentOps.dropFirst(idx + 1).contains { taskKinds.contains($0.kind) }
            } ?? false

            guard hasTaskOpsAfterTarget else {
                // Genuine no-op: no manuscript change, no task ops to rewind.
                // `restoreOp == nil` signals "log was not extended."
                return RewindRestoreResult(
                    restoreOp: nil,
                    archivedAnnotationOpIds: [],
                    removedParagraphIds: [],
                    priorSequenceCount: priorCount,
                    newSequenceCount: newCount)
            }

            // Emit a task-rewind marker checkpoint_restore with empty changes
            // and no sequence change so `TaskDeriver` can slice at this boundary.
            baseOp = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .checkpointRestore,
                changes: [],
                sequence: nil,
                provenance: .init(
                    sourceCheckpoint: targetOpId,
                    synthesisSource: .rewind))
        }

        // 4. Stamp the post-restore sequence on the op so cross-Mac merge
        //    sees the ordering change. (Deriver folds `op.sequence` whenever
        //    it's non-nil, so this is how the new ordering survives replay.)
        let stampedOp = Op(
            opId: baseOp.opId,
            docId: baseOp.docId,
            at: baseOp.at,
            device: baseOp.device,
            session: baseOp.session,
            kind: baseOp.kind,
            changes: baseOp.changes,
            sequence: targetState.sequence,
            provenance: baseOp.provenance)
        try await opStore.append(stampedOp)
        _opLogMirror.append(stampedOp)

        // 5. Update in-memory derived state to match the target.
        self.paragraphs = targetState.paragraphs
        self.sequence = targetState.sequence
        recomputeDisplayText()

        // The restore op is a manuscript mutation; annotation cache
        // staleness (priorText snapshots may no longer match) needs to
        // refresh. Setting the sticky flag isn't required — restore alone
        // doesn't create annotation ops; the sweep below does that only
        // when there are removed paragraphs with open annotations on them.
        invalidateAnnotationsCache()
        invalidateTasksCache()   // rewind changed paragraph text → re-derive inline tasks

        // 6. Schedule an autosave so the .md on disk reflects the rewind.
        autosaveScheduler.schedule(())

        // 7. Flag a sweep with cause = .rewind for removed paragraphs and
        //    flush again so the sweep runs synchronously inside this call.
        //    The sweep only emits claude_archive ops for OPEN annotations
        //    anchored to ids in `removedIds`; annotations on surviving
        //    paragraphs are untouched. Capture the op count before/after
        //    so the returned `archivedAnnotationOpIds` reflects exactly
        //    what this restore caused (and nothing the merging path
        //    accumulated incidentally).
        //
        //    Gate on `_hasAnyAnnotationOps`: when the doc has never had
        //    an annotation, `flushBurstNow` skips the entire annotation
        //    block (including the `_pendingSweep = nil` reset), so any
        //    `_pendingSweep` we'd set here would linger until the user's
        //    first annotation triggered the gate — at which point the
        //    sweep would archive against a stale removed-set captured
        //    from a long-past restore. ULID collisions are astronomically
        //    unlikely but the leak is structural. Don't flag what
        //    `flushBurstNow` won't drain.
        if !removedIds.isEmpty, _hasAnyAnnotationOps,
           let reason = SweepReason.rewind(removed: Set(removedIds)) {
            flagSweep(reason)
        }
        let beforeFlushCount = _opLogMirror.count
        try await flushBurstNow()
        let newlyAppended = _opLogMirror.dropFirst(beforeFlushCount)
        let archivedIds = newlyAppended
            .filter { op in
                op.kind == .claudeArchive
                    && op.provenance?.synthesisSource == .rewind
            }
            .map(\.opId)

        return RewindRestoreResult(
            restoreOp: stampedOp,
            archivedAnnotationOpIds: archivedIds,
            removedParagraphIds: removedIds,
            priorSequenceCount: priorCount,
            newSequenceCount: newCount)
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
        // `lastDiskEcho` is updated atomically inside the autosave's
        // coordinated-write block, so by the time the presenter callback
        // hops back to the main actor the snapshot is already in place.
        guard diskMd != lastDiskEcho.bytes else { return }

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
                provenance: .init(synthesisSource: .diskAtIngest))
            try await opStore.append(op)
            _opLogMirror.append(op)
            invalidateAnnotationsCache()
            invalidateTasksCache()   // silent ingest changed paragraph text → re-derive inline tasks
            // Update internal state.
            for change in changes {
                paragraphs[change.paragraphId] = change.next
            }
            lastDiskEcho = .afterIngest(bytes: diskMd)
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

        // Echo guard: every op we ourselves appended is already in
        // _opLogMirror. If the disk log has no ops we haven't seen, this
        // is NSFilePresenter firing on our own write — bail out before
        // doing the destructive re-derivation that re-deriving sequence
        // from the log would entail. Without this, every addAnnotation /
        // typingBurst flush would trigger a presenter callback that
        // re-derived state from disk, clobbered sequence (when the legacy
        // op log doesn't capture sequence per burst), and triggered the
        // orphan sweep to mass-archive paragraph-anchored annotations.
        let mirrorIds = Set(_opLogMirror.map(\.opId))
        let newOps = ops.filter { !mirrorIds.contains($0.opId) }
        if newOps.isEmpty {
            return
        }

        // Re-derive from the merged log, but PRESERVE the recovered sequence
        // when the new derivation produces an empty one. The recovery code
        // in Document.load seeded sequence from the parsed .md file for the
        // legacy case where typing_burst ops didn't capture sequence; that
        // recovery happens once at load and would be lost on every external
        // change otherwise.
        let state = Deriver.derive(ops: ops)
        let priorSequence = self.sequence
        self.paragraphs = state.paragraphs
        if state.sequence.isEmpty && !state.paragraphs.isEmpty
           && !self.sequence.isEmpty {
            // Keep the previously-recovered sequence. The new ops added
            // paragraphs that aren't in `self.sequence` will appear at the
            // tail (handled by mutation paths going forward).
        } else {
            self.sequence = state.sequence
        }
        // External op-log changes (cross-Mac sync) can shrink sequence —
        // flag a sweep so any annotations on now-removed paragraphs get
        // auto-archived on the next burst.
        let removedFromLog = Set(priorSequence).subtracting(Set(self.sequence))
        if let reason = SweepReason.externalLog(removed: removedFromLog) {
            flagSweep(reason)
        }
        self._opLogMirror = ops
        // Re-derive the sticky flag from the merged log: cross-Mac sync
        // could deliver annotation ops on a doc that previously had none.
        self._hasAnyAnnotationOps = ops.contains {
            Document.isAnnotationOpKind($0.kind)
        }
        invalidateAnnotationsCache()
        invalidateTasksCache()   // log merge may have added task ops

        // Sweep only when a paragraph genuinely disappeared (flagged above
        // by comparing priorSequence to the merged-state sequence). For
        // cross-Mac sync that only adds new ops without dropping paragraphs,
        // no sweep is needed — and avoiding it prevents the false-archive
        // cascade when sequence reconstruction differs from the live view.
        if let reason = _pendingSweep {
            await sweepOrphanedAnnotations(reason: reason)
            _pendingSweep = nil
        }

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
            provenance: .init(synthesisSource: .useCloudResolution))
        try await opStore.append(op)
        _opLogMirror.append(op)
        invalidateAnnotationsCache()
        invalidateTasksCache()   // use-cloud resolution rewrote paragraph text
        let priorSequence = self.sequence
        self.paragraphs = newParagraphs
        self.sequence = newSequence
        self.lastDiskEcho = .afterIngest(bytes: diskMd)
        // Use-cloud conflict resolution can shrink sequence — flag a sweep
        // for any annotations on paragraphs that disappeared. Run sweep
        // directly here (it's already at an async boundary).
        let removedInResolution = Set(priorSequence).subtracting(Set(newSequence))
        if let reason = SweepReason.useCloud(removed: removedInResolution) {
            await sweepOrphanedAnnotations(reason: reason)
        }
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

/// Looks up the doc-id for a manuscript path. Walks UP the directory tree
/// until it finds `project.maugham.json`, then resolves the doc against
/// that project's manifest. Falls back to a deterministic hash of the
/// path if no manifest is found (test fixtures, headless tooling).
///
/// The walk-up matters for nested doc layouts: Novel/Screenplay projects
/// keep manuscripts at `<project>/manuscript/<file>.md` (2 levels), but
/// Collection projects put pieces at `<project>/pieces/<piece-folder>/<file>`
/// (3 levels) and research notes can be deeper still. A fixed
/// `deletingLastPathComponent().deletingLastPathComponent()` lands inside
/// the piece folder for Collections and silently triggers the hash fallback,
/// producing a docId that doesn't match the manifest's StructureItem.id.
/// Op log files then go to the wrong file, MCP annotations stop resolving,
/// and the editor's live Document gets a fabricated id no other lookup
/// can find.
internal func resolveDocId(for url: URL) throws -> String {
    var probe = url.deletingLastPathComponent()
    let fm = FileManager.default
    // Cap the walk at 16 ancestors so a malformed URL can't infinite-loop.
    for _ in 0..<16 {
        let manifestURL = probe.appendingPathComponent("project.maugham.json")
        if fm.fileExists(atPath: manifestURL.path) {
            let relativePath = url.path
                .replacingOccurrences(of: probe.path + "/", with: "")
            if let data = try? Data(contentsOf: manifestURL) {
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                if let manifest = try? dec.decode(
                    ProjectManifest.self, from: data),
                   let item = findItemByPath(
                    relativePath, in: manifest.structure) {
                    return item.id
                }
            }
            // Found the manifest but couldn't decode or match. Stop walking;
            // don't keep climbing into an unrelated parent project.
            let relativeFallback = url.path
                .replacingOccurrences(of: probe.path + "/", with: "")
            return "doc-\(relativeFallback.hashValue.magnitude)"
        }
        let parent = probe.deletingLastPathComponent()
        if parent.path == probe.path { break }   // hit root
        probe = parent
    }
    // No manifest found — hash-fallback against the basename so test fixtures
    // still get a stable id.
    let basename = url.lastPathComponent
    return "doc-\(basename.hashValue.magnitude)"
}

/// Walks up the directory tree from a doc's URL until it finds the directory
/// that contains `project.maugham.json`. Used by Document.load to anchor
/// `.maugham/ops/<docId>.jsonl` and other project-relative paths. Falls
/// back to two-level deletion (the legacy behavior) if no manifest is found,
/// which keeps test fixtures that fake a project structure without writing
/// a manifest working.
internal func resolveProjectURL(for url: URL) -> URL {
    var probe = url.deletingLastPathComponent()
    let fm = FileManager.default
    for _ in 0..<16 {
        if fm.fileExists(atPath:
            probe.appendingPathComponent("project.maugham.json").path) {
            return probe
        }
        let parent = probe.deletingLastPathComponent()
        if parent.path == probe.path { break }
        probe = parent
    }
    // Legacy fallback for tests that don't write a manifest: 2 levels up.
    return url.deletingLastPathComponent().deletingLastPathComponent()
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

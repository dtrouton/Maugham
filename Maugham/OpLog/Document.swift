import Foundation
import MaughamCore
import AppKit
import os

// Subsystem from the running bundle id so dev/stable logs separate without
// hardcoding "com.maugham" (tripwire 13 spirit). Mirrors DocumentStore's logger.
// `internal` (not `private`) so the `Document+*.swift` peer extensions can log
// source-of-truth op-append failures through the same facility.
internal let documentLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "Document")

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
    public internal(set) var pendingConflict: ConflictState?

    // === Internal state ===
    // Several of these are `internal` rather than `private` because the
    // method bodies that touch them live in `Document+*.swift` peer
    // extensions (Swift has no cross-file same-type `private`). They remain
    // logically private to the Document type cluster.
    internal let url: URL
    public let docId: String
    internal let device: String
    internal let session: String
    private let presenter: NSFilePresenter?
    internal let opStore: OpLogStore
    internal let pending: PendingBuffer
    internal let burstScheduler: BurstScheduler

    internal var paragraphs: [String: String]
    internal var sequence: [String]

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
    internal var lastDiskEcho: EchoState

    internal var _annotationsCache: [Annotation] = []
    internal var _annotationsCacheValid: Bool = false
    public internal(set) var annotationsVersion: Int = 0

    // Task cache mirrors the annotation cache pattern. Invalidated alongside
    // every annotation invalidation site so paragraph mutations, lifecycle
    // ops, and external-log merges all refresh task derivation too.
    // See `docs/superpowers/specs/2026-05-23-tasks-design.md` §6.
    internal var _tasksCache: [WriterTask] = []
    internal var _tasksCacheValid: Bool = false
    public internal(set) var tasksVersion: Int = 0

    /// Re-entrancy guard for `rebuildTasksCache`. Appending rebalance ops
    /// triggers `invalidateTasksCache()` (rebalance ops are
    /// `.taskPriorityChange`, an invalidating kind). Without this guard the
    /// next `tasks(filter:)` call would rebuild again. The rebalance is
    /// mathematically idempotent (next derive emits zero rebalance ops since
    /// priorities are now well-spaced), so this guard makes the invariant
    /// *enforceable in tests* — not because there's a correctness hole.
    internal var _isRebuildingTasks: Bool = false

    /// Mirror of every op append for synchronous annotation derivation.
    /// Populated at load(...) with the result of opStore.load, then kept
    /// in sync by every mutation path that calls opStore.append.
    internal var _opLogMirror: [Op] = []

    /// Diagnostic accessor: size of the in-memory op log mirror.
    public var opLogMirrorCount: Int { _opLogMirror.count }

    /// Synchronous read of the in-memory op log mirror. Distinct from
    /// `opLog()` (the disk-backed async accessor) — this reads what's been
    /// observed by every in-process mutation path. Used by tests + the task
    /// cache to derive tasks without an async hop.
    public var opLogSnapshot: [Op] { _opLogMirror }

    /// Append `op` to this document's persistent op store AND to the in-memory
    /// mirror in a single step, so the opId-set echo guard in
    /// `Document+ExternalChange` recognises it as self-authored and filters it
    /// on the next NSFilePresenter callback.
    ///
    /// Use this for ops whose write is initiated *outside* the normal
    /// `flushBurstNow` / annotation path but must still be reflected in the
    /// live Document's mirror — currently only the checkpoint breadcrumb op
    /// written by `CheckpointCapture.run`.
    public func appendMirrored(_ op: Op) async throws {
        try await opStore.append(op)
        _opLogMirror.append(op)
    }

    /// Sticky flag: true once the doc has ever had an annotation op
    /// (creation OR lifecycle). Lets the hot typing path short-circuit
    /// per-keystroke annotation work (invalidateAnnotationsCache + sweep)
    /// when the document has never seen an annotation, which is the common
    /// case. Set at load() time by scanning the mirror, and stays true once
    /// flipped — annotations are append-only, so the flag only ratchets up.
    internal var _hasAnyAnnotationOps: Bool = false

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
    internal var _pendingSweep: SweepReason? = nil

    /// Keyframe floor (ADR 0016 / growth spec §4.1 rule 2): emit an explicit
    /// `sequence` at least every Nth burst even when ordering is unchanged —
    /// a robustness anchor bounding how far back a reader reconstructs
    /// ordering. Default confirmed against the M0 baseline (spec §9.1).
    internal static let sequenceKeyframeInterval = 50

    /// Accumulated "paragraph ordering changed since the last sequence-bearing
    /// burst" flag (growth spec §4.2). Starts TRUE so the first burst after
    /// load always carries an ordering anchor (rule 3). Set by every in-place
    /// sequence mutator; cleared ONLY after a *successful* sequence-bearing
    /// append — on append failure it survives so the durable re-flush still
    /// carries the ordering signal (T7). Per-instance, not persisted — same
    /// lifecycle shape as `_pendingSweep`.
    internal var _orderingDirty: Bool = true

    /// Consecutive bursts emitted without an explicit `sequence` (rule 2 counter).
    internal var _burstsSinceKeyframe: Int = 0

    /// Internal autosave debounce (replaces DocumentStore.scheduleSave).
    internal var autosaveScheduler: DebounceScheduler<Void>!

    /// Test-observable count of close-time burst-flush failures that were
    /// handled (logged + pending durably re-flushed) rather than swallowed.
    /// Lets a regression test assert the failure was surfaced non-silently.
    /// Production code never reads it.
    internal private(set) var closeBurstFlushFailures: Int = 0

    /// Test-only override for the seal threshold used by close()/open-time
    /// maintenance. Production reads `OpLogStore.segmentSealThreshold`.
    internal static var segmentSealThresholdForTesting: Int? = nil

    internal init(
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

    internal func recomputeDisplayText() {
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

    internal func performAutosave() async throws {
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

    /// Returns the current text of the paragraph with the given id, or nil
    /// if the id isn't in `sequence`. Read-only; mutation goes through
    /// `setParagraph(id:text:)`. Used by editor click handlers (e.g.,
    /// markdown-checkbox toggle) to read the in-memory paragraph before
    /// writing a flipped variant back.
    public func paragraph(id: String) -> String? {
        return paragraphs[id]
    }

    /// Returns the paragraph id of the paragraph containing `location` in
    /// `displayText`, or nil if no paragraph id can be determined.
    ///
    /// `location` is a **UTF-16 offset** expressed against `displayText`
    /// (i.e. the value of `textView.selectedRange.location` in the editor,
    /// which is an `NSRange` over `textView.string` — the stripped display
    /// form).  Both the clamp and the per-paragraph length must therefore use
    /// `NSString.length` (UTF-16 code units), not Swift `String.count`
    /// (Unicode grapheme clusters), and must operate on the **stripped**
    /// paragraph text — the same form that `recomputeDisplayText` produces —
    /// so that emoji (U+1F389 = 2 UTF-16 units, 1 grapheme) and task anchors
    /// (stripped by `RenderFilter.stripTaskAnchorsInline`) don't shift offsets.
    ///
    /// This mirrors `displayRange(forParagraphId:)` and the private
    /// `TaskAnchorAlignment.cursorParagraph`, both of which already use
    /// `(stripped as NSString).length`.
    ///
    /// Cost: O(characters up to `location`). Fine at human typing speed
    /// (a few times per second) even for large manuscripts (~100 KB).
    public func paragraphId(at location: Int) -> String? {
        // Walk paragraphs in sequence order — the same order as displayText —
        // accumulating the UTF-16 display-offset to find which paragraph the
        // cursor is in, then return that paragraph's id.
        let displayLength = (displayText as NSString).length
        let clamped = max(0, min(location, displayLength))
        var offset = 0
        for id in sequence {
            guard let text = paragraphs[id] else { continue }
            // Strip inline task anchors before measuring — they are invisible
            // in displayText, so raw text.count would over-count the length
            // and push subsequent paragraphs' offset windows forward.
            let stripped = RenderFilter.stripTaskAnchorsInline(text)
            let length = (stripped as NSString).length
            // The paragraph covers [offset, offset + length).
            // The "\n\n" separator is at [offset+length, offset+length+2).
            // Cursor at offset+length is still "inside" this paragraph
            // (end of its content, before the separator).
            if clamped <= offset + length {
                return id
            }
            offset += length + 2  // +2 for "\n\n" separator (2 UTF-16 code units)
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
        if sequenceChanged { _orderingDirty = true }
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
        _orderingDirty = true
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
        _orderingDirty = true
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
        _orderingDirty = true
        // No paragraph-change ops for pure reorder; the next typing_burst
        // emission will carry the new sequence as its `sequence` field.
        burstScheduler.recordActivity()
        autosaveScheduler.schedule(())
        // Annotation cache + sweep are deferred to flushBurstNow to keep
        // the keystroke path off the observable-write hot loop. See note in
        // setFullText for the cycle-detection / reentrant-layout reasoning.
        recomputeDisplayText()
    }

    public func flushBurstNow() async throws {
        let hadPending = !pending.isEmpty()
        if hadPending {
            let changes = pending.snapshot()
            // Keyframed sequence emission (ADR 0016 / growth spec §4.1):
            // attach `sequence` only when the ordering changed since the last
            // sequence-bearing burst (`_orderingDirty`, which starts true so
            // the first burst after load anchors the session), or every
            // `sequenceKeyframeInterval`th burst as a robustness floor.
            // Otherwise emit nil — the deriver carries the last explicit
            // sequence forward (`Deriver.derive`), so cross-Mac merge still
            // sees every ordering change.
            let emitSequence = _orderingDirty
                || _burstsSinceKeyframe >= Self.sequenceKeyframeInterval
            let op = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .typingBurst,
                changes: changes,
                sequence: emitSequence ? sequence : nil,
                provenance: nil)
            try await opStore.append(op)
            _opLogMirror.append(op)
            // Clear the ordering signal ONLY after the append succeeded — a
            // throw above leaves `_orderingDirty` set so the close()-path
            // durable re-flush still carries it (spec §4.2 / T7).
            if emitSequence {
                _orderingDirty = false
                _burstsSinceKeyframe = 0
            } else {
                _burstsSinceKeyframe += 1
            }
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

    public func close() async {
        // Flush any pending burst so editorial classification survives the
        // close (matches EditorHost's onDocChange behaviour).
        //
        // `close()` runs on app quit AND every FS-surgery path. The burst this
        // flushes is the LAST edits before the close — exactly the ones we most
        // want to survive — so a swallowed `try?` here was a Tier-0
        // silent-manuscript-loss bug (sweep 7). On append failure we must not
        // drop the burst silently.
        //
        // Recovery guarantee: `flushBurstNow` clears the pending buffer ONLY
        // after a successful `opStore.append` — so on an append failure the
        // in-memory `PendingBuffer` is still intact. We durably re-persist it
        // to `.maugham/ops/<docId>.pending.jsonl`, which the next
        // `Document.load` folds back into a real op via the crash-recovery
        // path. That makes the durable re-persist explicit and local to
        // `close()` rather than leaning on `performAutosave`'s incidental
        // `flushToDisk`. We also record the failure non-silently (os.Logger +
        // a test-observable counter) so the drop leaves a forensic trace.
        do {
            try await flushBurstNow()
        } catch {
            try? await pending.flushToDisk()
            closeBurstFlushFailures += 1
            documentLog.error(
                "close() burst flush failed for doc \(self.docId, privacy: .public); pending buffer re-flushed to disk for crash recovery: \(error.localizedDescription, privacy: .public)")
        }
        // Flush any pending autosave so the .md reflects the final state.
        await autosaveScheduler.flush()

        // Seal-on-close (ADR 0016 / growth spec §5.2): rotate this device's
        // own oversized tail into an immutable compressed segment. Threshold-
        // gated (usually a no-op) and best-effort — a seal failure must never
        // block close; the next close or project-open maintenance retries.
        // Never mid-typing, never another device's file, never the legacy
        // unsuffixed file (sealTailIfNeeded's scope rules).
        do {
            _ = try await opStore.sealTailIfNeeded(
                docId: docId,
                deviceSlug: DeviceSlug.make(from: device),
                threshold: Self.segmentSealThresholdForTesting
                    ?? OpLogStore.segmentSealThreshold)
        } catch {
            documentLog.error(
                "op-log seal failed for \(self.docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

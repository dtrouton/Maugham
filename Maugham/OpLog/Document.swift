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

    /// True once `close()` has run. A closed Document is ABANDONED by contract:
    /// its `@State` box can stay retained by a dead SwiftUI scene graph
    /// (`StoredLocation<Optional<Document>>` under `GraphHost.sharedGraph` — see
    /// `docs/superpowers/notes/2026-07-02-scene-storage-spike.md`), which we
    /// cannot nil from outside. So `close()` HUSKS the heavy in-memory state
    /// (paragraphs / sequence / displayText / op-log mirror / caches — after the
    /// disk truth is durably written) to make the stranded instance weightless,
    /// and every mutation entry point no-ops (logged) on a closed doc rather than
    /// resurrecting the husk. Mirror of `EditorCoordinator.detach()`.
    public private(set) var isClosed = false

    /// Recovery spec §4: the read-only partial open. Set only by
    /// `Document.load(recovery: .readOnlyPartial)`; a doc carrying this state
    /// can write NOTHING — every path that reaches `opStore.append` or
    /// `pending.recordChange` refuses through `rejectMutationIfNotWritable`
    /// (or its throwing sibling `requireWritable`, for the entry points that
    /// owe their caller a value), no autosave scheduler exists, and `close()`
    /// husks without flushing, sealing, or clearing.
    ///
    /// The guarantee is held by a CENSUS, not by this sentence:
    /// `ReadOnlyRecoveryTests.test_everyOpLogWriterConsultsTheWritabilityChokePoint`
    /// scans `Document*.swift` and fails on a writer that skips the choke
    /// point, so a mutation entry point added later cannot quietly fall
    /// outside the claim. Its allowlist is the whole set of exemptions.
    public struct ReadOnlyRecoveryState: Equatable, Sendable {
        public let unreadableFiles: [CheckpointLoad.UnreadableFile]
        public init(unreadableFiles: [CheckpointLoad.UnreadableFile]) {
            self.unreadableFiles = unreadableFiles
        }
    }
    public internal(set) var readOnlyRecovery: ReadOnlyRecoveryState?
    public var isReadOnlyRecovery: Bool { readOnlyRecovery != nil }

    /// The pending file `load` found but could not recover (RULING-54,
    /// M9-OL-010): un-bursted keystrokes from a crashed session, already
    /// preserved in the quarantine record. Stamped by `Document.load` and
    /// CONSUMED ONCE by the first window-bound surface (EditorHost), which
    /// posts the document notice — load itself must not post, because a
    /// windowless post is dropped by the receive helpers' liveness guard and
    /// the writer is never told. A load that never binds a window (an MCP
    /// statement flow) leaves the stamp unconsumed; the quarantine record is
    /// the durable truth either way.
    public struct PendingRecoveryFailure: Equatable, Sendable {
        public let name: String
        public let reason: String
        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }
    public internal(set) var unrecoveredPendingFailure: PendingRecoveryFailure?

    /// Consume-once: returns the failure and marks it delivered, so a second
    /// surface cannot re-post the same notice.
    public func consumePendingRecoveryFailure() -> PendingRecoveryFailure? {
        defer { unrecoveredPendingFailure = nil }
        return unrecoveredPendingFailure
    }

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
    /// Mutation is restricted to the autosave path — see
    /// `EchoState.afterWrite(bytes:)`. Anything else trying to assign here is a
    /// contract violation; the typed wrapper exists specifically to keep that
    /// surface small.
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

    /// The ONE mirror-append (RULING-36: the timeline is the writer's own,
    /// under any clock). `handleExternalLogChange` replaces the mirror with a
    /// sorted merge; a LOCAL op minted after that sorts before a merged-in
    /// peer op from an ahead clock, and a raw append would leave the mirror
    /// unsorted — `currentFoldBasis`'s "last is newest" premise false, and a
    /// rewind prefix rendering the peer's text (M5-AN-046/047). Normal appends
    /// (monotonic local ULIDs) stay O(1); the re-sort runs only in the skew
    /// case the invariant exists to survive.
    internal func appendToMirror(_ op: Op) {
        if let last = _opLogMirror.last, op.opId < last.opId {
            _opLogMirror.append(op)
            _opLogMirror.sort { $0.opId < $1.opId }
        } else {
            _opLogMirror.append(op)
        }
    }

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
        // A checkpoint breadcrumb is derived from the doc's state, so on a
        // read-only recovery view it would stamp a durable marker over a
        // PARTIAL history — the one write that later reads would trust.
        if rejectMutationIfNotWritable("appendMirrored") { return }
        try await opStore.append(op)
        appendToMirror(op)
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

    /// Per-instance memo of candidate shingle/bigram sets for the
    /// `RenderFilter.restorePairs` fuzzy-match tiers. Candidate paragraph texts
    /// are stable across keystrokes (only the edited paragraph changes), so
    /// caching their (pure) set computation by text value pays off across the
    /// keystroke stream. Semantics-identical to the uncached path — see
    /// `RenderFilter.ShingleSetCache`. Dropped on `close()`.
    private let _shingleSetCache = RenderFilter.ShingleSetCache()

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

    /// How many notes the sweep has archived since the last burst boundary
    /// reported (RULING-32). The ruling asks for a BATCHED, quiet summary at
    /// the writing pause — silent in the moment, never a prompt — so the count
    /// accumulates across however many sweeps a burst window contains and
    /// `flushBurstNow` says it once. Reset by that report, not by the sweep,
    /// which is why it is a running total rather than the last sweep's size.
    /// Per-instance, never persisted; a close() flush reports whatever is left.
    internal var _sweptSinceLastReport: Int = 0

    /// What the annotation undos have DECLINED since the last report
    /// (RULING-22), counted per verb — the sweep's shape above (RULING-32),
    /// applied to the same problem one column over.
    ///
    /// One ⌘Z over a bulk action fires one undo closure PER NOTE
    /// (`NSUndoManager.groupsByEvent` folds a batch's registrations into a
    /// single event group, pinned by `AnnotationBulkActionsTests`), and each
    /// closure re-checks its own note before it acts. So a batch two of whose
    /// notes drifted used to post the SINGULAR sentence twice into a toast slot
    /// that holds one: the writer read "Couldn't undo stetting the note",
    /// which was false about the number and silent about the notes that did
    /// come back. Accumulate quietly, spend one sentence at the boundary.
    /// Per-instance, never persisted.
    internal var _declinedUndosSinceLastReport: [UndoDecline: Int] = [:]

    /// The scheduled spend of `_declinedUndosSinceLastReport` — see
    /// `declineUndo(_:)` for why one main-actor hop IS the burst boundary here.
    /// Nil whenever nothing is owed. Awaited by `awaitPendingUndoWork()`.
    internal var _undoDeclineReportTask: Task<Void, Never>?

    /// The annotation undos that can decline at fire time (RULING-22), and
    /// what each of them says.
    ///
    /// **The singular is byte-identical to what each site posted before this
    /// existed** — the four single-note decline tests are the proof — and the
    /// plural lives on the same line as the singular so the two cannot drift
    /// apart. A verb added here without a plural won't compile.
    internal enum UndoDecline: Hashable, CaseIterable {
        case annotationEdit, acceptNote, stet, triage

        /// One sentence for however many notes of this verb declined. A batch
        /// that ALSO undid some notes says nothing about them: the queue has
        /// the reopened rows in it, and a decline that spends its clause
        /// counting successes buries what the writer needs to act on.
        func sentence(count: Int) -> String {
            guard count > 1 else { return singular }
            return switch self {
            case .annotationEdit:
                "Couldn't undo \(count) annotation edits — they changed on another device."
            case .acceptNote:
                "Couldn't undo accepting \(count) notes — they changed on another device."
            case .stet:
                "Couldn't undo stetting \(count) notes — they changed on another device."
            case .triage:
                "Couldn't undo \(count) triage marks — they changed on another device."
            }
        }

        private var singular: String {
            switch self {
            case .annotationEdit:
                "Couldn't undo the annotation edit — it changed on another device."
            case .acceptNote:
                "Couldn't undo accepting the note — it changed on another device."
            case .stet:
                "Couldn't undo stetting the note — it changed on another device."
            case .triage:
                "Couldn't undo the triage mark — it changed on another device."
            }
        }
    }

    /// One-shot: the next external buffer apply (`applyExternalText`) was
    /// produced by a document-local mutation that registered its own
    /// UndoManager action (accept/revert of a suggestion) — the editor must
    /// NOT clear the undo stack for that one apply or it wipes the fresh
    /// registration. NOT observable (tripwire 6): consumed via
    /// `consumeUndoCoherentApplyFlag()` from EditorSurface.updateNSView.
    /// Discharged by the bound editor's next update pass whether or not a
    /// replace occurs; a Document with no attached editor keeps it armed only
    /// until first load (makeNSView seeds the buffer, so the first update
    /// pass discharges it without preserving).
    internal var _undoCoherentApplyPending = false

    /// One-shot read+clear. See `_undoCoherentApplyPending`.
    public func consumeUndoCoherentApplyFlag() -> Bool {
        let v = _undoCoherentApplyPending
        _undoCoherentApplyPending = false
        return v
    }

    /// Handle to the async work-hop spawned by the last undo/redo of an accepted
    /// suggestion. `NSUndoManager.undo()` invokes its handler synchronously, but
    /// the revert / re-accept it triggers is async (op-log append), so it hops to
    /// a detached task. This handle lets a caller `await` that hop's completion —
    /// used only by tests, which must know the op has landed (and the task has
    /// torn down) before they assert / close. Not observable.
    internal var _lastUndoWorkTask: Task<Void, Never>?

    /// Test seam: await the async revert/re-accept triggered by the last
    /// undo/redo, if any. No-op when nothing is pending.
    ///
    /// The decline report (`declineUndo`) is awaited AFTER the work hop and
    /// not instead of it: the closure schedules the report as it declines, so
    /// the task to wait on does not exist until the hop has run. Reading the
    /// property here rather than capturing it above is what makes one call
    /// enough for a single decline — which is why the single-note tests need
    /// no `settle` loop.
    public func awaitPendingUndoWork() async {
        await _lastUndoWorkTask?.value
        await _undoDeclineReportTask?.value
    }

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

    /// Whether a REAL ordering mutation happened since this Document was loaded.
    /// Distinct from `_orderingDirty` (which inits TRUE to anchor the first
    /// burst's keyframe): this inits FALSE and flips true only at the genuine
    /// ordering-change sites (`setFullText`'s sequenceChanged branch, insert /
    /// delete / reorder). It gates ONLY the ordering-only burst arm in
    /// `flushBurstNow` — without it, an UNTOUCHED doc's `close()` would see
    /// `_orderingDirty == true` (its init value) and append a junk
    /// `{changes: [], sequence}` op on every open/close cycle, turning every
    /// transient Document load (MCP annotation reads, task reads, wiki-rename,
    /// search-replace, binder navigation) into an op-log writer and letting that
    /// junk op's newest-ULID explicit sequence revert a peer device's not-yet-
    /// synced delete / reorder. Cleared alongside `_orderingDirty` after a
    /// successful sequence-bearing append. Per-instance, never persisted.
    internal var _orderingChangedSinceLoad: Bool = false

    /// Consecutive bursts emitted without an explicit `sequence` (rule 2 counter).
    internal var _burstsSinceKeyframe: Int = 0

    /// F7 ping-pong damping. The discard handler auto-rewrites the `.md` with
    /// op-log truth on every while-open external edit. If op-log sync lags the
    /// `.md` (iCloud's normal failure mode) or a version-skewed peer keeps
    /// writing anchored files, two devices bounce rewrites indefinitely. After
    /// `discardDampThreshold` discards with DISTINCT bytes in a session we stop
    /// auto-rewriting (still snapshot, op log still authoritative in memory) and
    /// log ONCE. Any local edit re-arms rewriting (via `noteLocalEdit`).
    /// `_discardedByteHashes` dedups byte-identical repeat deliveries so a
    /// re-fired presenter callback for the same bytes doesn't advance the count.
    /// It stores stable 64-bit hashes (`StableHash.fnv1a64Hex`, NOT the
    /// process-seed-randomised `String.hashValue` — tripwire) rather than full
    /// manuscript strings, and is capped at `discardSnapshotCap`, evicting oldest
    /// — damping only needs distinctness, so a hash collision (merely
    /// under-counts, safely) and a bounded window are both tolerable, and a
    /// runaway ping-pong loop can't grow it unbounded (Minor 5). Plain
    /// per-instance state (not observable) — same lifecycle as `_orderingDirty`;
    /// reset on `noteLocalEdit`, never persisted.
    internal static let discardDampThreshold = 3
    internal static let discardSnapshotCap = 8
    internal var _distinctDiscardCount = 0
    internal var _discardedByteHashes: [String] = []
    internal var _discardDampLogged = false

    /// Records a discard's bytes by stable hash and reports whether they are
    /// distinct from the recently-seen set (a byte-identical re-delivery returns
    /// false and must not advance the damping count). Insertion-ordered + capped
    /// at `discardSnapshotCap`, evicting oldest, so the window is bounded
    /// (Minor 5). Uses `StableHash.fnv1a64Hex` for determinism; the hash is never
    /// persisted, but the codebase forbids `String.hashValue` for id-shaped work.
    func noteDiscardDistinct(_ bytes: String) -> Bool {
        let h = StableHash.fnv1a64Hex(bytes)
        if _discardedByteHashes.contains(h) { return false }
        _discardedByteHashes.append(h)
        if _discardedByteHashes.count > Self.discardSnapshotCap {
            _discardedByteHashes.removeFirst(
                _discardedByteHashes.count - Self.discardSnapshotCap)
        }
        return true
    }

    /// Re-arm discard rewriting after a local edit — the writer is clearly the
    /// live source again, so a subsequent external divergence is a fresh event,
    /// not part of a bounce. Called from every local-edit path
    /// (`setFullText`/`setParagraph`) when a real change occurs. Cheap: an Int
    /// reset plus (usually-empty) array clear on the typing hot path.
    func noteLocalEdit() {
        guard _distinctDiscardCount != 0 || !_discardedByteHashes.isEmpty
            || _discardDampLogged else { return }
        _distinctDiscardCount = 0
        _discardedByteHashes.removeAll()
        _discardDampLogged = false
    }

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

    /// Test-only artificial delay injected inside the detached task-op disk
    /// append (`appendTaskOpInternal`). Makes the close-time drain race
    /// deterministically reproducible: with a delay set, an undrained
    /// `close()` returns before the append lands. Production leaves it nil.
    internal static var _testDelayTaskAppends: Duration? = nil

    /// In-flight detached task-op disk appends, keyed by a monotonic token so
    /// each self-prunes on completion (the set stays near-empty in steady
    /// state). `close()` drains these before husking so a prompt quit can't
    /// drop a task op or its ⌘Z compensating op (E1). See
    /// `appendTaskOpInternal` / `drainTaskAppends`.
    internal var inFlightTaskAppends: [UInt64: Task<Void, Never>] = [:]
    internal var _nextTaskAppendToken: UInt64 = 0

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

    /// The opId of the newest op this Document has folded — the basis a stamped
    /// pending sequence is measured against (Issue 2b). `_opLogMirror` is kept in
    /// opId order by every append path, so its last element is the newest.
    internal var currentFoldBasis: String? { _opLogMirror.last?.opId }

    internal func performAutosave() async throws {
        // Data-safety guard: a husked doc's `materialize()` is empty, so an
        // autosave firing after close() would write an EMPTY .md over the real
        // manuscript. close() flushes autosave BEFORE husking, so this only
        // rejects a stray post-close scheduler tail. A read-only recovery doc
        // has no scheduler at all, so this arm is belt for a hand-driven call.
        if rejectMutationIfNotWritable("performAutosave") { return }
        // Mirror pending buffer to disk for crash recovery. Carry the live
        // paragraph order so recovery is op-log-domain — not reconstructed from
        // the .md (ADR 0019). Stamp the basis (newest folded opId) so load can
        // tell a current pending order from one superseded by peer ops (Issue 2b).
        pending.setSequence(self.sequence, basis: currentFoldBasis)
        // The pending file is now the ONLY crash-recovery source (ADR 0019 made
        // the .md a clean derived render, no longer a fallback). A swallowed
        // `try?` here would drop the recovery mirror silently; record the
        // failure non-silently (matches close()'s catch) — the autosave still
        // proceeds to write the .md, but the forensic trace tells us the
        // pending mirror is stale.
        do {
            try await pending.flushToDisk()
        } catch {
            documentLog.error(
                "pending mirror flush failed for doc \(self.docId, privacy: .public); crash recovery may lose the un-bursted tail: \(error.localizedDescription, privacy: .public)")
        }

        // ADR 0019: the on-disk file is the clean display form (no ¶id / t-
        // anchors). The op log + in-memory NSTextStorage keep the anchors.
        let bytes = MarkdownDisplayFilter.stripAnchors(materialize())
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

    /// Returns the paragraph id at `location` (a UTF-16 offset into
    /// `displayText`) AND that paragraph's UTF-16 range within `displayText`,
    /// or nil if no paragraph can be determined. Used by the review toolbar to
    /// translate an absolute selection into a paragraph-relative span anchor.
    ///
    /// Same walk + same stripped/UTF-16 length discipline as `paragraphId(at:)`
    /// (anchors are invisible in `displayText`, so measure the stripped form in
    /// UTF-16 code units).
    public func paragraphRange(at location: Int) -> (id: String, range: NSRange)? {
        let displayLength = (displayText as NSString).length
        let clamped = max(0, min(location, displayLength))
        var offset = 0
        var lastId: String?
        var lastRange = NSRange(location: 0, length: 0)
        for id in sequence {
            guard let text = paragraphs[id] else { continue }
            let stripped = RenderFilter.stripTaskAnchorsInline(text)
            let length = (stripped as NSString).length
            if clamped <= offset + length {
                return (id, NSRange(location: offset, length: length))
            }
            lastId = id
            lastRange = NSRange(location: offset, length: length)
            offset += length + 2  // +2 for "\n\n" separator
        }
        // Cursor past all paragraphs — return the last paragraph if any.
        if let lastId { return (lastId, lastRange) }
        return nil
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
        // A closed doc is husked + abandoned; a late binding write (e.g. a
        // still-referenced zombie) must no-op rather than resurrect the husk
        // (which would parse `text` against empty prior state and re-populate
        // paragraphs). documentLog.error records the misuse.
        if rejectMutationIfNotWritable("setFullText") { return }
        // Parse-once keystroke path (perf fix B). The prior stored state is
        // already in hand as `paragraphs`/`sequence` — the load path and this
        // method's own orphan-prune below enforce `paragraphs.keys ⊆ sequence`,
        // so `{id: paragraphs[id]}` over `sequence` IS the same {id: anchored
        // text} map that `parse(materialize(paragraphs, sequence))` produced
        // before. We therefore skip the prior-side materialize→parse roundtrip
        // (two whole-doc parses) AND the next-side re-parse (another two): the
        // ONLY new bytes are the display `text`, so we parse exactly that once
        // and let `RenderFilter.restorePairs` reattach ids in-process.
        //
        // `priorById` carries the *anchored* prior text (V2 alignment + change
        // detection need the anchors). `restorePairs`, by contrast, compares
        // against anchor-STRIPPED text (the displayed text is anchor-free), so
        // it gets its own stripped map. Two distinct dictionaries — kept
        // distinct deliberately (see RenderFilter.restorePairs doc).
        var priorById: [String: String] = [:]
        var priorByIdStripped: [String: String] = [:]
        for id in sequence {
            guard let anchored = paragraphs[id] else { continue }
            priorById[id] = anchored
            // Strip is the identity for any paragraph carrying no `<!--`
            // (a task anchor is `<!--t-…-->`), so skip the regex for the
            // overwhelming majority of paragraphs — only the anchored few
            // pay the NSRegularExpression. Behavior-identical: the regex
            // literal requires `<!--` to match.
            priorByIdStripped[id] = anchored.contains("<!--")
                ? RenderFilter.stripTaskAnchorsInline(anchored)
                : anchored
        }

        // Fountain docs preserve the two-space "held blank" dialogue pause inside
        // the paragraph rather than splitting on it (E1); prose keeps
        // whitespace-only = blank. Consistent with Bootstrap + Document.load so
        // the same doc parses to the same ¶ split on every path.
        let isFountain = url.pathExtension.lowercased() == "fountain"
        let displayParsed = ParagraphParser.parse(
            text, preservesHeldBlankLines: isFountain)
        // `pairs` is exactly what `parse(restoreComments(...))` yielded before:
        // ids in display order paired with the (anchor-free) display text.
        let pairs = RenderFilter.restorePairs(
            priorByIdStripped: priorByIdStripped,
            storedOrder: sequence,
            displayParsed: displayParsed,
            cache: _shingleSetCache)

        // V2 task-anchor alignment (spec §2.4.1). Inputs:
        //   - priorById[id] is the *anchored* prior paragraph text.
        //   - pairs[*].text is the *anchor-free* new paragraph text
        //     (the display text strips task anchors).
        // The aligner re-injects task anchors per paragraph, runs a
        // cross-paragraph correlation pass to detect cut/paste with
        // cursor bias, and reports anchors that couldn't be paired —
        // those become .taskArchive ops at the end of this method.
        let effectivePre = preEditCursor ?? _lastSeenCursor
        let effectivePost = postEditCursor ?? _pendingPostEditCursor
        _pendingPostEditCursor = nil
        let alignment = TaskAnchorAlignment.align(
            priorById: priorById,
            nextParagraphs: pairs.map { (id: $0.id, text: $0.text) },
            priorSequence: sequence,
            nextSequence: pairs.map(\.id),
            preEditCursor: effectivePre,
            postEditCursor: effectivePost)

        // Collect changes and the new sequence. Use the V2-restored
        // (anchor-bearing) paragraph text rather than the raw display
        // text so the on-disk .md keeps its anchors across the round-trip.
        var changes: [Op.ParagraphChange] = []
        var newSequence: [String] = []
        for pair in pairs {
            let id = pair.id
            newSequence.append(id)
            let restored = alignment.restoredById[id] ?? pair.text
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
        if sequenceChanged {
            _orderingDirty = true
            _orderingChangedSinceLoad = true
        }
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
            noteLocalEdit()   // F7: a local edit re-arms discard rewriting
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
        if rejectMutationIfNotWritable("setParagraph") { return }
        let prior = paragraphs[id]
        guard prior != text else { return }
        pending.recordChange(paragraphId: id, prior: prior, next: text)
        paragraphs[id] = text
        burstScheduler.recordActivity()
        autosaveScheduler.schedule(())
        noteLocalEdit()   // F7: a local edit re-arms discard rewriting
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
        if rejectMutationIfNotWritable("insertParagraph") { return "" }
        // Unique against the doc's live id population (birthday hazard over
        // the ~1.05M id space — see ParagraphID.mintUnique).
        let newId = ParagraphID.mintUnique(
            excluding: Set(sequence).union(paragraphs.keys))
        paragraphs[newId] = text
        if let after, let idx = sequence.firstIndex(of: after) {
            sequence.insert(newId, at: idx + 1)
        } else {
            sequence.append(newId)
        }
        _orderingDirty = true
        _orderingChangedSinceLoad = true
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
        if rejectMutationIfNotWritable("deleteParagraph") { return }
        guard paragraphs[id] != nil else { return }
        let priorText = paragraphs[id]
        paragraphs.removeValue(forKey: id)
        sequence.removeAll { $0 == id }
        _orderingDirty = true
        _orderingChangedSinceLoad = true
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
        if rejectMutationIfNotWritable("reorder") { return }
        self.sequence = sequence
        _orderingDirty = true
        _orderingChangedSinceLoad = true
        // No paragraph-change ops for pure reorder; the next typing_burst
        // emission will carry the new sequence as its `sequence` field.
        burstScheduler.recordActivity()
        autosaveScheduler.schedule(())
        // Annotation cache + sweep are deferred to flushBurstNow to keep
        // the keystroke path off the observable-write hot loop. See note in
        // setFullText for the cycle-detection / reentrant-layout reasoning.
        recomputeDisplayText()
    }

    /// Say something to the writer. `Document` has no view, so this is the
    /// whole of its writer-facing surface: a project-scoped
    /// `.maughamDocumentNotice` the open window renders in its toast
    /// (`RewindModifier`). Used where the alternative was `documentLog` and
    /// nothing else — a declined ⌘Z (RULING-7, RULING-22) or a batch of
    /// auto-archived notes (RULING-32).
    ///
    /// `opStore.projectURL` is the project root, not this doc's file, so the
    /// scope matches what `RewindModifier` subscribes with.
    /// An annotation undo refused at fire time (RULING-22). Never posts in the
    /// moment — it accumulates, and one report at the boundary spends whatever
    /// the burst declined (`_declinedUndosSinceLastReport`).
    ///
    /// **The boundary is one main-actor hop after the last of the batch's undo
    /// closures.** `NSUndoManager.undo()` runs every closure in the event group
    /// SYNCHRONOUSLY, and each hops its op-log append into a fresh
    /// `Task { @MainActor }` (`OpUndoRegistrar`) — so by the time the FIRST
    /// decline runs, every sibling's task is already enqueued on this actor,
    /// and the report task created here is enqueued behind all of them. A
    /// declining closure never suspends (the drift re-check is a synchronous
    /// read of the derived projection), so every decline in the burst has
    /// landed in the dictionary before the report runs. No timer, no debounce,
    /// nothing to tune: the hop IS the boundary, and it is the same one
    /// `awaitPendingUndoWork()` lets a test stand on.
    internal func declineUndo(_ decline: UndoDecline) {
        _declinedUndosSinceLastReport[decline, default: 0] += 1
        guard _undoDeclineReportTask == nil else { return }
        _undoDeclineReportTask = Task { @MainActor [weak self] in
            self?.reportDeclinedUndos()
        }
    }

    /// Spend the burst's declines: one sentence per verb that declined, in
    /// `UndoDecline`'s own order so a batch spanning two verbs says the same
    /// two sentences in the same order every time (a dictionary's is not
    /// stable). One deliberate click is one verb, so two sentences is the rare
    /// case — and two honest ones beat one that names neither verb.
    private func reportDeclinedUndos() {
        _undoDeclineReportTask = nil
        let counts = _declinedUndosSinceLastReport
        _declinedUndosSinceLastReport = [:]
        for decline in UndoDecline.allCases {
            guard let n = counts[decline], n > 0 else { continue }
            notifyWriter(decline.sentence(count: n))
        }
    }

    internal func notifyWriter(_ message: String) {
        MaughamEvent.postNotice(message, projectURL: opStore.projectURL)
    }

    public func flushBurstNow() async throws {
        // Everything below this line appends ops, clears the pending buffer or
        // sweeps annotations — writes, every one. `close()` calls it while the
        // doc is still writable, so the normal path is unaffected; this rejects
        // a stray post-close call (which would append against husked state) and
        // a recovery doc's flush (spec §4: a partial view writes nothing).
        if rejectMutationIfNotWritable("flushBurstNow") { return }
        let hadPending = !pending.isEmpty()
        // Emit an op when there are pending TEXT changes OR an ordering-only
        // edit that recorded nothing in the pending buffer but flipped
        // `_orderingDirty` (a paragraph DELETE or a pure REORDER — `setFullText`
        // only records changes for paragraphs still present, so a deletion
        // leaves `pending` empty). Without the second arm, a delete-then-quit
        // emitted no op at all: the ordering change never reached the op log,
        // so the next load re-derived the pre-delete order and the paragraph
        // resurrected (F1). The sequence-only burst (`changes: []`, explicit
        // `sequence`) is that change's durable record — for this session and
        // for cross-device sync.
        //
        // Gated on `_orderingChangedSinceLoad` (NOT `_orderingDirty`): the
        // latter inits TRUE to anchor the first burst's keyframe, so an
        // untouched doc's close() would otherwise emit a junk sequence-only op
        // every open/close cycle. `_orderingChangedSinceLoad` inits FALSE and
        // flips true only on a genuine delete / reorder / insert, so this arm
        // fires only when ordering actually changed with nothing in `pending`.
        let emitOrderingOnly = !hadPending && _orderingChangedSinceLoad
        if hadPending || emitOrderingOnly {
            let changes = hadPending ? pending.snapshot() : []
            // Keyframed sequence emission (ADR 0016 / growth spec §4.1):
            // attach `sequence` only when the ordering changed since the last
            // sequence-bearing burst (`_orderingDirty`, which starts true so
            // the first burst after load anchors the session), or every
            // `sequenceKeyframeInterval`th burst as a robustness floor.
            // Otherwise emit nil — the deriver carries the last explicit
            // sequence forward (`Deriver.derive`), so cross-Mac merge still
            // sees every ordering change. An ordering-only burst only reaches
            // here with `_orderingDirty` set, so `emitSequence` is always true
            // for it — the sequence IS its payload.
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
            appendToMirror(op)
            // Clear the ordering signal ONLY after the append succeeded — a
            // throw above leaves `_orderingDirty` set so the close()-path
            // durable re-flush still carries it (spec §4.2 / T7).
            if emitSequence {
                _orderingDirty = false
                _orderingChangedSinceLoad = false
                _burstsSinceKeyframe = 0
            } else {
                _burstsSinceKeyframe += 1
            }
            // `clear()` is a no-op on the buffer for the ordering-only arm
            // (already empty) but also resets the durable `seq` + removes the
            // on-disk pending file, so the freshly-emitted order isn't left
            // behind as a phantom `{sequence, changes: []}` recovery candidate.
            try await pending.clear()
            // Inline tasks are derived from paragraph text — any pending
            // typing change may have added/removed/toggled a `- [ ]` line, and
            // a deleted paragraph can carry inline tasks too. Invalidate
            // unconditionally on burst; the cache rebuilds lazily on the next
            // `tasks(filter:)` read.
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

        // RULING-32 — the batched summary, at the writing pause. This IS the
        // burst boundary: the writer has stopped, so a quiet line costs them
        // nothing, where the same line during the burst would interrupt
        // typing. It is deliberately a report and not a prompt (the ruling
        // chose the batched option over tell-at-the-time), and it counts every
        // sweep since the last report rather than the last sweep alone —
        // deleting four paragraphs in one burst is one sentence, not four.
        if _sweptSinceLastReport > 0 {
            let n = _sweptSinceLastReport
            _sweptSinceLastReport = 0
            notifyWriter(
                "While you edited: \(n) \(n == 1 ? "note" : "notes") archived.")
        }
    }

    public func close() async {
        // Idempotent: a closed doc is already husked and its disk truth written,
        // so a second close (DocumentStore drain + EditorHost belt, or
        // appWillTerminate racing onDisappear) returns immediately rather than
        // re-running the flush machinery over husked state.
        guard !isClosed else { return }
        // A read-only recovery doc closes by husking alone: it has nothing to
        // flush (mutations refused), must not seal (maintenance writes), and
        // must not clear the pending file (it belongs to the REAL open that
        // follows recovery). It also has no autosave scheduler to flush.
        if isReadOnlyRecovery {
            isClosed = true
            huskInMemoryState()
            return
        }
        // Let any in-flight ⌘Z undo/redo hop finish on the LIVE (non-husked) doc
        // before husking (whole-branch review, 2026-07-11). An op-log undo runs
        // its mutation in `_lastUndoWorkTask`'s async hop (OpUndoRegistrar); a
        // COMPOUND undo (inline-task archive) restores paragraph text (guarded
        // `applyRestore`/`setFullText`) AND appends a status inverse
        // (`appendTaskOpInternal`) and reopens swept annotations. If close() husked
        // mid-hop, the text side would no-op (isClosed guard) while the op side
        // still appended — a TORN op log on reload. Awaiting the hop first makes
        // the undo apply atomically on a live doc; the isClosed guards on the op
        // funnels (fix 1b) are the belt for any hop that still resumes post-husk.
        // `nil?.value` is a no-op when no undo is pending. Drained AFTER, because
        // the hop's `appendTaskOpInternal` spawns a fresh detached append this
        // must then catch.
        await _lastUndoWorkTask?.value
        // Drain the detached task-op disk appends BEFORE anything else (E1).
        // `appendTaskOpInternal` updates the in-memory mirror synchronously
        // then disk-appends in a fire-and-forget Task; without this drain a
        // prompt quit returns from close() before those appends land and the
        // task op (or its ⌘Z compensating op) is silently lost on relaunch.
        // Drained ahead of flushBurstNow, which only invalidates the tasks
        // cache and so spawns no further task appends.
        await drainTaskAppends()
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
        var burstFlushSucceeded = true
        do {
            try await flushBurstNow()
        } catch {
            burstFlushSucceeded = false
            // Carry the live paragraph order onto the re-persisted pending buffer
            // (mirrors performAutosave) so crash recovery is op-log-domain — the
            // recovered burst restores ordering without the .md (ADR 0019). Stamp
            // the basis so load can distinguish this recovery order from one
            // superseded by peer ops (Issue 2b).
            pending.setSequence(self.sequence, basis: currentFoldBasis)
            try? await pending.flushToDisk()
            closeBurstFlushFailures += 1
            documentLog.error(
                "close() burst flush failed for doc \(self.docId, privacy: .public); pending buffer re-flushed to disk for crash recovery: \(error.localizedDescription, privacy: .public)")
        }
        // Flush any pending autosave so the .md reflects the final state.
        await autosaveScheduler.flush()

        // Issue 2a: a CLEAN close leaves NO pending file. The burst flush above
        // already persisted every un-bursted change as real ops and cleared the
        // pending buffer; the trailing autosave then re-created a
        // `{sequence, changes: []}` mirror that has ZERO recovery value now — but
        // if left on disk it is a stale ordering assertion that a peer's
        // while-closed delete/reorder (syncing in before the next open) could
        // reawaken. Remove it. On a FAILED burst flush the pending file is the
        // sole recovery source (re-persisted in the catch above) — keep it.
        if burstFlushSucceeded {
            try? await pending.clear()
        }

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

        // Drop the per-keystroke shingle/bigram memo — the doc is going away.
        _shingleSetCache.clear()

        // Husk (mirror of EditorCoordinator.detach()): the disk truth is now
        // durably written above (burst flushed, trailing autosave flushed,
        // pending cleared, tail sealed), so drop the O(doc) in-memory state.
        // This is the load-bearing memory win — a closed Document's `@State`
        // box can stay retained by a dead SwiftUI scene graph
        // (`StoredLocation<Optional<Document>>` under `GraphHost.sharedGraph`;
        // window close never dismantles it and we can't nil another view's
        // @State), so husking makes that stranded instance weightless. `isClosed`
        // (set FIRST) gates every mutation path so nothing resurrects the husk;
        // `performAutosave` also bails on it, so no stray scheduler tail can
        // write the now-empty `materialize()` over the on-disk manuscript.
        isClosed = true
        huskInMemoryState()
    }

    /// Drop the O(doc) in-memory state. Called from `close()` once the disk
    /// truth is durably written, and directly by the read-only recovery close
    /// (which has no disk truth to write). Callers set `isClosed` FIRST, so
    /// every mutation path is already gated before the state goes.
    private func huskInMemoryState() {
        paragraphs = [:]
        sequence = []
        displayText = ""
        _opLogMirror = []
        _annotationsCache = []
        _annotationsCacheValid = false
        _tasksCache = []
        _tasksCacheValid = false
        _discardedByteHashes = []
        // Drop the last-written-bytes snapshot (a full manuscript copy) while
        // honouring EchoState's two-call-site construction contract.
        lastDiskEcho = .afterWrite(bytes: "")
    }

    /// One choke point for "this instance must not mutate": closed (husked,
    /// abandoned) or read-only recovery (spec §4 — nothing derived from a
    /// partial view is ever written). Callers no-op; documentLog records it.
    ///
    /// The closed arm: a late mutation (a still-referenced zombie, an MCP
    /// misuse, a scheduler tail) must no-op rather than operate on husked state
    /// or resurrect it. Data safety is unaffected — the disk truth was written
    /// before husking.
    internal func rejectMutationIfNotWritable(_ site: StaticString) -> Bool {
        if isClosed {
            documentLog.error(
                "\(site, privacy: .public) called on a closed Document \(self.docId, privacy: .public); no-op (the instance is abandoned by contract)")
            return true
        }
        if isReadOnlyRecovery {
            documentLog.error(
                "\(site, privacy: .public) called on a read-only recovery Document \(self.docId, privacy: .public); no-op (nothing derived from a partial view is written)")
            return true
        }
        return false
    }

    /// The throwing form of `rejectMutationIfNotWritable`, for the mutation
    /// entry points that return a VALUE and so have no honest no-op to return
    /// (`addAnnotation` owes its caller an id, `restoreToOp` a result). Same
    /// choke point, same log line — a refusal here is loud rather than a
    /// fabricated success.
    internal func requireWritable(_ site: StaticString) throws {
        if rejectMutationIfNotWritable(site) {
            throw DocumentNotWritableError(site: "\(site)")
        }
    }

    /// The NARROWER arm of the choke point: refuse a read-only recovery view's
    /// write while leaving a CLOSED doc's behaviour byte-for-byte as it was.
    ///
    /// Used only where a closed-doc append is pinned by the behavioural
    /// register — claim **M5-AN-048**, which characterises five annotation
    /// mutators (craft-note creation, archive, reject, withdraw, edit) as
    /// appending to a husked doc. Its filing is `NO_RULING_REACHES`, so that is
    /// a characterised inconsistency rather than protected behaviour: widening
    /// these to the full guard would *improve* it to 7-of-7, but it would also
    /// re-decide a register claim, which belongs in its own change with the
    /// claim and its filing moving alongside. The recovery rung needs only the
    /// recovery arm, so that is all it takes.
    ///
    /// When M5-AN-048 is closed, the sites taking this arm collapse back onto
    /// `rejectMutationIfNotWritable` / `requireWritable` and this pair goes.
    /// They are enumerated in ONE place — `ReadOnlyRecoveryTests`'
    /// `narrowGuardAllowlist`, which is also what permits them: the census
    /// treats this arm as a guard only for a name on that list, so a new
    /// writer reaching for it is an offender. Count that array, not this
    /// comment, which said "four" over three sites.
    internal func rejectMutationIfReadOnlyRecovery(_ site: StaticString) -> Bool {
        guard isReadOnlyRecovery else { return false }
        documentLog.error(
            "\(site, privacy: .public) called on a read-only recovery Document \(self.docId, privacy: .public); no-op (nothing derived from a partial view is written)")
        return true
    }

    /// Throwing form of `rejectMutationIfReadOnlyRecovery`, for the
    /// value-returning entry points. Same M5-AN-048 scoping.
    internal func requireNotReadOnlyRecovery(_ site: StaticString) throws {
        if rejectMutationIfReadOnlyRecovery(site) {
            throw DocumentNotWritableError(site: "\(site)")
        }
    }
}

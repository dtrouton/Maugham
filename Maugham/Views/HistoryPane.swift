// Maugham/Views/HistoryPane.swift
import SwiftUI
import AppKit
import MaughamCore

// MARK: - History entry + filter

public enum HistoryEntry: Identifiable {
    case op(Op)
    case checkpoint(Checkpoint)

    public var id: String {
        switch self {
        case .op(let op): return "op:\(op.opId)"
        case .checkpoint(let cp): return "cp:\(cp.checkpointId)"
        }
    }
    public var timestamp: Date {
        switch self {
        case .op(let op): return op.at
        case .checkpoint(let cp): return cp.at
        }
    }

    public static func merge(
        ops: [Op], checkpoints: [Checkpoint]
    ) -> [HistoryEntry] {
        var all: [HistoryEntry] = []
        all.append(contentsOf: ops.map(HistoryEntry.op))
        all.append(contentsOf: checkpoints.map(HistoryEntry.checkpoint))
        all.sort { $0.timestamp > $1.timestamp }
        return all
    }
}

public enum HistoryFilter: String, CaseIterable, Identifiable, FilterRowItem {
    // No External filter (#91, Denver's ruling): nothing this build writes
    // records an edit made outside Maugham — an outside `.md` change is
    // discarded on re-materialize — so a chip for it promised an empty list.
    // `OpKind.externalEdit` still DECODES from old logs and still draws as a
    // row under All.
    case all, checkpoints, edits, annotations

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return "All"
        case .checkpoints: return "Checkpoints"
        case .edits: return "Edits"
        case .annotations: return "Annotations"
        }
    }

    public var symbolName: String {
        switch self {
        case .all: return "circle"           // unused (kept-short)
        case .checkpoints: return "flag.fill"
        case .edits: return "pencil"
        case .annotations: return "bubble.left"
        }
    }

    public func matches(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .checkpoints:
            switch entry {
            case .checkpoint: return true
            case .op(let op): return op.kind == .checkpointRestore
            }
        case .edits:
            if case .op(let op) = entry {
                return op.kind == .typingBurst || op.kind == .bootstrap
            }
            return false
        case .annotations:
            if case .op(let op) = entry {
                switch op.kind {
                case .claudeComment, .claudeSuggestion, .claudeAccept,
                     .claudeAcceptRevert, .claudeReject, .claudeArchive,
                     .claudeQuery, .claudeCraftNote:
                    return true
                default: return false
                }
            }
            return false
        }
    }
}

// MARK: - HistoryPane view

@MainActor
struct HistoryPane: View {
    let projectURL: URL
    let activeDocId: String
    let allDocIds: [String]
    let device: String
    let session: String
    let docPaths: [String: String]
    let documentStore: DocumentStore?

    @State private var filter: HistoryFilter = .all
    @State private var checkpoints: [Checkpoint] = []
    /// Checkpoint device files `reload()` could not read — name AND reason
    /// (RULING-54: an unreadable file used to read as EMPTY — every checkpoint
    /// from that device silently gone from this pane and from Rewind's
    /// targets). The pane shows a notice when non-empty, with the reasons in
    /// its tooltip: "permission denied" and "couldn't be downloaded" want
    /// opposite responses from the writer. The rows are intact on disk. The
    /// inbox pane's M8-IN-012 shape.
    @State private var unreadableCheckpointFiles: [CheckpointLoad.UnreadableFile] = []
    /// Set-aside (Plan B) op-log files for `activeDocId` still `.held` —
    /// `records(forDocId:in:)` already self-heals a stale `.held` row whose
    /// return actually succeeded, so this list is only ever the genuine
    /// article: history the writer cannot currently see.
    @State private var heldQuarantineRecords: [QuarantineRecord] = []
    /// How many CHANGES were set aside, by the REASON each was set aside for
    /// (signed op log P1; the reasons are P2b's), counting only what the writer
    /// has not yet acknowledged (P2a, D2) and only what is not in their draft
    /// already (P2 smoke, find 7). Counts rather than the records, because the
    /// notice is pure over them and reading the archives is `reload()`'s job,
    /// not `body`'s — and by reason rather than one total, because four of the
    /// six causes describe lines Maugham itself wrote on the writer's other
    /// machine (whole-branch review, I3).
    @State private var setAsideChangesByReason: [String: Int] = [:]
    /// Every set-aside record for this doc, acknowledged or not, by the name it
    /// is acknowledged under. The disclosure below the sentence lists these
    /// REGARDLESS: what an Acknowledge press puts down is the sentence, not the
    /// forensics. Resolved on `reload()` and held, because
    /// `SetAsideAcknowledgement.name(for:in:)` reads the quarantine directory
    /// and a per-row read from `body` is tripwire 4.
    @State private var setAsideRecordNames: [String] = []
    /// The same records as rows the disclosure can act on (P3b Task 8, spec
    /// §7.4): how many paragraphs each would hand back to the Inbox, whether
    /// this Mac has already sent them, and the sentence each is shown under.
    /// Resolved on `reload()` for `setAsideRecordNames`' reason — the count
    /// reads each archive.
    @State private var setAsideRows: [SetAsideDoor.Row] = []
    /// What the last **Send to Inbox** did, or why it could not. Shown on the
    /// row until the next reload, because a press that appeared to do nothing
    /// is worse than a refusal (the Retry notice's own rule).
    @State private var sendToInboxError: String?
    /// **How many waiting paragraphs each unsigned holder has**, and nothing
    /// else about the rows (P3b Task 8; narrowed in fix round 2's I1).
    ///
    /// This half re-runs the walk over the document's files, which is disk work
    /// and never `body`'s (tripwire 4). The SENTENCES are not here: they are
    /// composed in `body` from the live provenance and the live names, because
    /// a snapshot of them taken in `reload()` was taken before `reloadChain()`
    /// had resolved a single name and before a document opening in the same
    /// pass had a provenance at all — so Task 7's held sentences were
    /// intermittently not drawn, and a renamed person's was a reload behind.
    @State private var heldWordCounts: [String: Int] = [:]
    /// Holder → how many of the paragraphs held under it NOW this Mac has
    /// already sent (P3c Task 7, M2) — the same read as the counts above,
    /// counted off the lines rather than off a memory keyed by the holder.
    @State private var heldSentCounts: [String: Int] = [:]
    /// Device fingerprint → the name that device's registry record gives it,
    /// for the pending sentence (signed op log P2a). Empty when this project
    /// has no registry, and empty when one could not be read: a name is
    /// decoration on a count, so an unreadable registry costs the writer a code
    /// rather than the sentence. Resolved in `reload()` because reading it is
    /// disk work (tripwire 4).
    @State private var chainDeviceNames: [String: String] = [:]
    /// Whose chain this Mac is on, already as the sentence — nil when it has
    /// joined nobody's. The whole line rather than the root's fingerprint,
    /// because both halves it is built from (this device's registry memory and
    /// the people records) are resolved in the same off-actor read.
    @State private var joinedChainLine: String?
    /// **What retirement means, on the machine that did it** (fix round 1,
    /// Important 2). Nil until this Mac has retired itself in this book; a
    /// standing fact afterwards, drawn with no control, because there is
    /// nothing to press — a device cannot be un-retired.
    @State private var retirementLine: String?
    /// The project's dated trust events, already as drawn rows (signed op log
    /// P2b, ruling C). Resolved in `reloadChain` beside the names they are told
    /// in, because both come out of the same off-actor registry read.
    @State private var trustEventLines: [TrustEventLine] = []
    /// **History this Mac remembers and cannot find** (P3b Task 6): a stream
    /// found shorter than it was, or one the folder holds no file of at all.
    /// Resolved off the main actor with the registry read that names each
    /// device, like everything else here that touches disk (tripwire 4).
    @State private var lostHistoryRows: [LostHistoryRow] = []
    @State private var isRetryingQuarantine: Bool = false
    /// The report from the most recently completed Retry, kept only long
    /// enough for the writer to view or dismiss it — cleared when the sheet
    /// closes. Nil whenever nothing has just been recovered.
    @State private var recoveredReport: RecoveredHistoryReport?
    @State private var showingRecoveredHistorySheet: Bool = false
    @State private var ops: [Op] = []
    @State private var expanded: Set<String> = []
    @State private var selectedCheckpoint: Checkpoint?
    @State private var showingRestorePicker: Bool = false
    /// Hosting window for the ADR 0021 project scope + closed-window liveness
    /// guard on `.maughamCheckpointAdded`.
    @State private var window: NSWindow?

    /// What the OPEN document's load found out about its own history (signed
    /// op log P1). Nil when this doc is not open — the counts are a property of
    /// a load, and this pane must not perform one of its own to invent them.
    private var documentProvenance: OpLogProvenance? {
        documentStore?.document(forDocId: activeDocId)?.provenance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterToolbar
            Divider()
            // The standing notices, then the timeline: each a child that owns
            // no state, over values read in THIS body pass and the pane's own
            // verbs (`HistoryPaneVerbs`).
            HistoryNotices(
                projectURL: projectURL,
                unreadableCheckpointFiles: unreadableCheckpointFiles,
                heldQuarantineRecords: heldQuarantineRecords,
                isRetryingQuarantine: isRetryingQuarantine,
                documentProvenance: documentProvenance,
                setAsideChangesByReason: setAsideChangesByReason,
                lostHistoryRows: lostHistoryRows,
                chainDeviceNames: chainDeviceNames,
                heldRows: heldRows,
                retirementLine: retirementLine,
                joinedChainLine: joinedChainLine,
                setAsideRows: setAsideRows,
                sendToInboxError: sendToInboxError,
                recoveredReport: recoveredReport,
                showingRecoveredHistorySheet: $showingRecoveredHistorySheet,
                retryQuarantine: verbs.retryQuarantine,
                acknowledgeSetAside: verbs.acknowledgeSetAside,
                acknowledgeLostHistory: verbs.acknowledgeLostHistory,
                sendHeldWordsToInbox: verbs.sendHeldWordsToInbox,
                sendSetAsideToInbox: verbs.sendSetAsideToInbox)
            HistoryTimeline(
                filter: filter,
                ops: ops,
                checkpoints: checkpoints,
                trustEventLines: trustEventLines,
                projectURL: projectURL,
                activeDocId: activeDocId,
                allDocIds: allDocIds,
                documentStore: documentStore,
                expanded: $expanded,
                selectedCheckpoint: $selectedCheckpoint,
                showingRestorePicker: $showingRestorePicker,
                jump: verbs.jump)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor(window: $window))
        .task { await verbs.reload() }
        // **The counts follow the provenance** (fix round 2, I1): a document
        // whose load lands after this pane's first reload brings its held
        // holders with it, and the door must appear on that pass rather than
        // on whatever reload happens next.
        .task(id: heldHolderKey) { await verbs.reloadHeldWordCounts() }
        .onChange(of: activeDocId) { _, _ in Task { await verbs.reload() } }
        // Project-scoped (ADR 0021): only this project's checkpoint reloads
        // this pane. Fixes the cross-window leak where every open window's
        // HistoryPane reloaded on ANY project's checkpoint.
        .onProjectEvent(.maughamCheckpointAdded, url: projectURL, window: window) { _ in
            Task { await verbs.reload() }
        }
        // The set-aside rows are the one thing in this pane another surface
        // changes behind its back: `EditorHost`'s auto-return sweep runs on
        // every normal document open and can leave nothing held at all. Without
        // this the standing notice went stale and its Retry re-attempted a
        // record that had already come back (the review's I2).
        .onProjectEvent(.maughamQuarantineRecordsChanged, url: projectURL, window: window) { _ in
            Task { await verbs.reload() }
        }
        // A device was let in (signed op log P2b) — by this window's sheet, by
        // a second window on the same book, or silently at open. Both halves of
        // what this pane says about the chain have changed: the pending count
        // is smaller or gone, and there is a new dated entry saying who joined.
        // Without this the banner went on offering Admit… for a device that was
        // already in.
        .onProjectEvent(.maughamAdmissionSettled, url: projectURL, window: window) { _ in
            Task { await verbs.reload() }
        }
        .sheet(isPresented: $showingRestorePicker) {
            if let cp = selectedCheckpoint {
                PartialRestorePicker(
                    checkpoint: cp,
                    projectURL: projectURL,
                    activeDocId: activeDocId,
                    allDocIds: allDocIds,
                    figures: documentStore?.projectStore?.manifest.figures ?? [],
                    device: device,
                    session: session,
                    docPaths: docPaths,
                    documentStore: documentStore,
                    onComplete: {
                        showingRestorePicker = false
                        Task { await verbs.reload() }
                    },
                    onCancel: { showingRestorePicker = false }
                )
            }
        }
        // `onDismiss` clears `recoveredReport` — the row's "View" is a
        // pointer to a just-completed Retry, not durable state; the next
        // Retry (or reload finding new held records) replaces it.
        .sheet(isPresented: $showingRecoveredHistorySheet, onDismiss: { recoveredReport = nil }) {
            if let report = recoveredReport {
                RecoveredHistorySheet(
                    report: report,
                    document: documentStore?.document(forDocId: activeDocId),
                    // Drawn only where this Mac may write the text (re-review
                    // item 1); no door behind the pane fails closed.
                    mayAppend: Self.offersRewind(
                        documentStore?.posture(forDocId: activeDocId)),
                    // The door's own posture, asked fresh at the press (#74).
                    postureNow: { [weak store = documentStore, docId = activeDocId] in
                        store?.posture(forDocId: docId)
                    },
                    onDismiss: { showingRecoveredHistorySheet = false })
            }
        }
    }

    @ViewBuilder
    private var filterToolbar: some View {
        HStack(spacing: 6) {
            AdaptiveFilterRow(
                items: HistoryFilter.allCases,
                selection: $filter)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Button {
                MaughamEvent.post(.maughamOpenRewind, to: .project(for: projectURL))
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Rewind…")
            .disabled(ops.isEmpty || (ops.count == 1 && ops[0].kind == .bootstrap))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    /// The holders this document is currently holding lines under, as one
    /// stable string — the id `body`'s `.task` watches, so the counts follow a
    /// provenance that arrives late without polling for it.
    private var heldHolderKey: String {
        (documentProvenance?.pendingByDevice.keys.sorted() ?? []).joined(separator: ",")
    }

    /// The rows, composed live. Pure and cheap — a classification and a
    /// sentence per holder, no disk — so it costs a `body` pass what a stored
    /// array would have cost, minus the staleness.
    private var heldRows: [SetAsideDoor.HeldRow] {
        Self.heldLineRows(
            provenance: documentProvenance,
            startedAPiece: documentStore?
                .document(forDocId: activeDocId)?.startedAPiece ?? [],
            takenFrom: documentStore?
                .document(forDocId: activeDocId)?.keptWritingInATakenPiece ?? [],
            names: chainDeviceNames, words: heldWordCounts,
            sent: heldSentCounts)
    }

    /// The pane's verbs over its own `@State` (`HistoryPaneVerbs`), built per
    /// call and never stored: a binding writes the same storage this pane
    /// reads, and `documentProvenance` arrives as a closure, so a read after
    /// an `await` is the live answer.
    private var verbs: HistoryPaneVerbs {
        HistoryPaneVerbs(
            projectURL: projectURL, activeDocId: activeDocId,
            documentStore: documentStore,
            documentProvenance: { documentProvenance },
            checkpoints: $checkpoints,
            unreadableCheckpointFiles: $unreadableCheckpointFiles,
            ops: $ops,
            heldQuarantineRecords: $heldQuarantineRecords,
            setAsideRecordNames: $setAsideRecordNames,
            setAsideRows: $setAsideRows,
            setAsideChangesByReason: $setAsideChangesByReason,
            lostHistoryRows: $lostHistoryRows,
            chainDeviceNames: $chainDeviceNames,
            joinedChainLine: $joinedChainLine,
            retirementLine: $retirementLine,
            trustEventLines: $trustEventLines,
            heldWordCounts: $heldWordCounts,
            heldSentCounts: $heldSentCounts,
            sendToInboxError: $sendToInboxError,
            isRetryingQuarantine: $isRetryingQuarantine,
            recoveredReport: $recoveredReport,
            showingRecoveredHistorySheet: $showingRecoveredHistorySheet)
    }
}

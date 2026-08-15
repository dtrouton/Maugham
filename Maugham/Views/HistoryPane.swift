// Maugham/Views/HistoryPane.swift
import SwiftUI
import AppKit
import MaughamCore
import os

/// Diagnostic channel for a Retry attempt that leaves a record `.held`
/// (`.stillUnreadable`/`.corrupt`) — the writer sees the standing notice
/// persist; this is the WHY for anyone debugging it. Mirrors
/// `PartialRestorePicker.swift`'s `partialRestoreLog`.
private let historyQuarantineLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "HistoryPaneQuarantine")

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
    case all, checkpoints, edits, annotations, external

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all: return "All"
        case .checkpoints: return "Checkpoints"
        case .edits: return "Edits"
        case .annotations: return "Annotations"
        case .external: return "External"
        }
    }

    public var symbolName: String {
        switch self {
        case .all: return "circle"           // unused (kept-short)
        case .checkpoints: return "flag.fill"
        case .edits: return "pencil"
        case .annotations: return "bubble.left"
        case .external: return "arrow.down.left"
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
        case .external:
            if case .op(let op) = entry {
                return op.kind == .externalEdit
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

    private var entries: [HistoryEntry] {
        HistoryEntry.merge(ops: ops, checkpoints: checkpoints)
            .filter { filter.matches($0) }
    }

    /// Index of ops by op_id for HistoryRow's sourceAnnotationId lookups
    /// (used to surface the body of an annotation whose archive row
    /// otherwise only shows "paragraph deleted").
    private var opsByOpId: [String: Op] {
        var map: [String: Op] = [:]
        for op in ops { map[op.opId] = op }
        return map
    }

    /// Each op's immediate predecessor in the opId-ordered log, keyed by opId.
    /// "Rewind to before this…" opens the rewind at the PREDECESSOR — the
    /// state the row's op destroyed, not the state it produced. Posting the
    /// row's own op landed the writer AFTER it, because `derive(upTo:)` is
    /// inclusive by contract (RULING-22 disposition 2026-08-08, M4-RW-002).
    /// The first op has no entry: there is no "before" to offer.
    static func predecessorIndex(ops: [Op]) -> [String: Op] {
        var map: [String: Op] = [:]
        map.reserveCapacity(max(ops.count - 1, 0))
        for i in 1..<max(ops.count, 1) {
            map[ops[i].opId] = ops[i - 1]
        }
        return map
    }

    private var emptyTitle: String {
        switch filter {
        case .all:         return "No history yet"
        case .checkpoints: return "No checkpoints"
        case .edits:       return "No edits"
        case .annotations: return "No annotations"
        case .external:    return "No external edits"
        }
    }

    private var emptySymbol: String {
        switch filter {
        case .all:         return "clock.arrow.circlepath"
        case .checkpoints: return "flag"
        case .edits:       return "pencil"
        case .annotations: return "bubble.left.and.bubble.right"
        case .external:    return "arrow.down.doc"
        }
    }

    private var emptyHint: String {
        switch filter {
        case .all:
            return "Type, take a checkpoint, or ask Claude for feedback — your activity will show up here."
        case .checkpoints:
            return "Press ⌘⇧S to capture a named checkpoint, or ⌘S to auto-checkpoint."
        case .edits:
            return "Typing bursts appear here every 30 seconds while you work."
        case .annotations:
            return "Ask Claude to comment or suggest a change — annotations land here as a forensic record."
        case .external:
            return "External edits to the .md file (e.g. via another editor or sync) show up here."
        }
    }

    /// The notice shown when checkpoint device files can't be read — nil when
    /// everything read cleanly. Static so the copy is pinnable without a
    /// window mount (the `predecessorIndex` pattern).
    static func unreadableCheckpointNotice(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "Some checkpoints can’t be read (\(names.joined(separator: ", "))). "
             + "They are still in the file — check permissions or iCloud sync."
    }

    /// The notice's tooltip: one "name — reason" line per unreadable file, so
    /// the WHY reaches the writer ("permission denied" is fixed here;
    /// "couldn't be downloaded" is fixed by getting online).
    static func unreadableCheckpointDetail(_ files: [CheckpointLoad.UnreadableFile]) -> String? {
        guard !files.isEmpty else { return nil }
        return files.map { "\($0.name) — \($0.reason)" }.joined(separator: "\n")
    }

    /// The standing notice for set-aside (Plan B quarantine) history — nil
    /// once nothing is held (nothing was ever set aside, or Retry brought
    /// everything back). Pinnable without mounting, like the checkpoint
    /// notice above. The sentence names what happened ("set aside") rather
    /// than the internal term ("quarantine") — CLAUDE.md's writer-facing
    /// copy rule. The row's "Retry" control sits beside this text in body;
    /// read together they form the quoted UX copy the spec names.
    static func quarantineNotice(heldCount: Int) -> String? {
        guard heldCount > 0 else { return nil }
        return "Part of this document’s history is set aside (couldn’t be read when it was)."
    }

    /// The notice shown after a Retry completes. Zero orphans is
    /// unconditionally honest as "nothing was missing" — that covers both a
    /// genuinely redundant return (sync already delivered the same history)
    /// and a returned file that turned out to hold nothing new (including
    /// the zero-byte-file case), because in both the merged draft already
    /// has everything the recovered file has.
    static func recoveredHistoryNotice(orphanCount: Int) -> String {
        guard orphanCount > 0 else {
            return "Recovered history merged — nothing was missing"
        }
        let plural = orphanCount == 1 ? "" : "s"
        let verb = orphanCount == 1 ? "isn’t" : "aren’t"
        return "\(orphanCount) paragraph\(plural) from the recovered history \(verb) in your draft — View"
    }

    /// The notice for a Retry where NOTHING came back — every held record is
    /// still unreadable or still torn. The pressed button did something and
    /// said nothing before this (the review's I2): a control that looks dead
    /// is worse than a refusal, and the standing notice above it does not
    /// change, so silence reads as "the press didn't register". Names the
    /// first reason, because the reasons want opposite responses from the
    /// writer ("permission denied" is fixed here; a torn file is not fixable
    /// by pressing again). Writer-voiced — "set aside", never the internal
    /// term.
    static func stillHeldNotice(reason: String) -> String {
        "That part of this document’s history still can’t be read, so it stays "
        + "set aside (\(reason))."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterToolbar
            Divider()
            if let notice = Self.unreadableCheckpointNotice(unreadableCheckpointFiles.map(\.name)) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(Self.unreadableCheckpointDetail(unreadableCheckpointFiles) ?? "")
                    // .help is hover-only; the WHY must reach VoiceOver too.
                    .accessibilityHint(Text(
                        Self.unreadableCheckpointDetail(unreadableCheckpointFiles) ?? ""))
                Divider()
            }
            if let notice = Self.quarantineNotice(heldCount: heldQuarantineRecords.count) {
                HStack(spacing: 8) {
                    Label(notice, systemImage: "arrow.uturn.backward.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 4)
                    Button("Retry", action: retryQuarantine)
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .disabled(isRetryingQuarantine)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if let report = recoveredReport, !report.orphans.isEmpty {
                HStack(spacing: 8) {
                    Label(Self.recoveredHistoryNotice(orphanCount: report.orphans.count),
                          systemImage: "tray.and.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Spacer(minLength: 4)
                    Button("View") { showingRecoveredHistorySheet = true }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if entries.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySymbol,
                    description: Text(emptyHint))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // Built ONCE per body pass and captured by every row —
                    // never per row (tripwire 4: no per-row computation in
                    // list rows without caching).
                    let predecessors = Self.predecessorIndex(ops: ops)
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HistoryRow(
                                entry: entry,
                                expanded: expanded.contains(entry.id),
                                lookupOp: { id in opsByOpId[id] },
                                rewindTarget: {
                                    if case .op(let op) = entry {
                                        return predecessors[op.opId]
                                    }
                                    return nil
                                }(),
                                onToggle: {
                                    if expanded.contains(entry.id) {
                                        expanded.remove(entry.id)
                                    } else {
                                        expanded.insert(entry.id)
                                    }
                                },
                                onJump: { jump(entry) },
                                onRevert: {
                                    if case .checkpoint(let cp) = entry {
                                        selectedCheckpoint = cp
                                        showingRestorePicker = true
                                    }
                                },
                                projectURL: projectURL)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor(window: $window))
        .task { await reload() }
        .onChange(of: activeDocId) { _, _ in Task { await reload() } }
        // Project-scoped (ADR 0021): only this project's checkpoint reloads
        // this pane. Fixes the cross-window leak where every open window's
        // HistoryPane reloaded on ANY project's checkpoint.
        .onProjectEvent(.maughamCheckpointAdded, url: projectURL, window: window) { _ in
            Task { await reload() }
        }
        // The set-aside rows are the one thing in this pane another surface
        // changes behind its back: `EditorHost`'s auto-return sweep runs on
        // every normal document open and can leave nothing held at all. Without
        // this the standing notice went stale and its Retry re-attempted a
        // record that had already come back (the review's I2).
        .onProjectEvent(.maughamQuarantineRecordsChanged, url: projectURL, window: window) { _ in
            Task { await reload() }
        }
        .sheet(isPresented: $showingRestorePicker) {
            if let cp = selectedCheckpoint {
                PartialRestorePicker(
                    checkpoint: cp,
                    projectURL: projectURL,
                    activeDocId: activeDocId,
                    allDocIds: allDocIds,
                    device: device,
                    session: session,
                    docPaths: docPaths,
                    documentStore: documentStore,
                    onComplete: {
                        showingRestorePicker = false
                        Task { await reload() }
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

    private func reload() async {
        let loaded = await CheckpointStore(projectURL: projectURL).load()
        // Show all project-scope checkpoints regardless of active doc.
        // Checkpoints are project-wide artefacts; filtering by active doc
        // would hide checkpoints captured while a different doc was open,
        // which is exactly what the user would expect to see for a
        // multi-doc novel/screenplay project.
        checkpoints = loaded.checkpoints
        unreadableCheckpointFiles = loaded.unreadableFiles
        // Prefer the live Document if it's loaded (its mirror reflects any
        // unflushed in-memory state). Otherwise read the op log directly
        // from disk — the History pane should always show typing bursts /
        // annotations / external edits for the active doc, even when the
        // user hasn't yet opened it in the editor this session.
        if let ds = documentStore,
           let doc = ds.document(forDocId: activeDocId) {
            ops = (try? await doc.opLog()) ?? []
        } else if activeDocId != BinderSubject.noDocumentSubject {
            let opStore = OpLogStore(projectURL: projectURL)
            ops = (try? await opStore.load(docId: activeDocId)) ?? []
        } else {
            ops = []
        }
        heldQuarantineRecords = activeDocId == BinderSubject.noDocumentSubject
            ? []
            : OpLogQuarantine.records(forDocId: activeDocId, in: projectURL)
                .filter { $0.status == .held }
    }

    /// Runs `attemptReturn` for every held record, reloads, and surfaces
    /// what happened: a toast in EVERY case, plus the report sheet when the
    /// return turned up paragraphs the draft doesn't have.
    ///
    /// Each record's own `RecoveredHistoryReport` is carried through and the
    /// sweep's verdict is `RecoveredHistoryReport.aggregate` — never a report
    /// assembled here from loose orphans with `redundant` written in by hand,
    /// which is what shipped (the review's I1): the flag then said "sync had
    /// already delivered all of this" about sweeps where it had delivered none
    /// of it.
    ///
    /// A record that stays `.stillUnreadable`/`.corrupt` keeps its place in the
    /// standing notice via the next `reload()`, and — when NOTHING in the sweep
    /// came back — says so (`stillHeldNotice`) rather than leaving a pressed
    /// button looking dead.
    private func retryQuarantine() {
        guard !isRetryingQuarantine else { return }
        isRetryingQuarantine = true
        Task {
            var reports: [RecoveredHistoryReport] = []
            var failureReasons: [String] = []
            for record in heldQuarantineRecords {
                let outcome = await OpLogQuarantine.attemptReturn(
                    record: record, in: projectURL, presenter: nil)
                switch outcome {
                case .returned(let report):
                    reports.append(report)
                case .supersededBySync(let report):
                    reports.append(report)
                    // The lossy shape, and the reason `redundant` is a field
                    // rather than an inference from the orphan count: nothing
                    // moved, and the archive carries history the live log has
                    // not got. The writer hears about it through the orphan
                    // notice; this is the WHY for whoever reads the log.
                    if !report.redundant {
                        historyQuarantineLog.notice("retryQuarantine: \(record.originalName, privacy: .public) stays an archive — its place was refilled by sync, and it holds \(report.orphans.count, privacy: .public) paragraph(s) the live history does not")
                    }
                case .stillUnreadable(let reason), .corrupt(let reason):
                    failureReasons.append(reason)
                    historyQuarantineLog.error("retryQuarantine: \(record.originalName, privacy: .public) still held — \(reason, privacy: .public)")
                }
            }
            await reload()
            isRetryingQuarantine = false
            guard !reports.isEmpty else {
                if let reason = failureReasons.first {
                    MaughamEvent.postNotice(
                        Self.stillHeldNotice(reason: reason), projectURL: projectURL)
                }
                return
            }
            let sweep = RecoveredHistoryReport.aggregate(reports)
            MaughamEvent.postNotice(
                Self.recoveredHistoryNotice(orphanCount: sweep.orphans.count),
                projectURL: projectURL)
            if !sweep.orphans.isEmpty {
                recoveredReport = sweep
                showingRecoveredHistorySheet = true
            }
        }
    }

    private func jump(_ entry: HistoryEntry) {
        guard case .op(let op) = entry,
              let pid = op.changes.first?.paragraphId else { return }
        MaughamEvent.post(
            .maughamNavigateToParagraph, to: .keyWindow,
            payload: ["paragraph_id": pid])
    }
}

// MARK: - HistoryRow

@MainActor
private struct HistoryRow: View {
    let entry: HistoryEntry
    let expanded: Bool
    let lookupOp: (String) -> Op?
    /// The op "Rewind to before this…" opens at — the row op's immediate
    /// predecessor in the opId-ordered log, resolved by the parent pane.
    /// `nil` for the first op (no "before" exists) and for checkpoint rows;
    /// the deep-link button is not offered then, because offering a rewind
    /// that cannot land before the op would be the M4-RW-002 lie again.
    let rewindTarget: Op?
    let onToggle: () -> Void
    let onJump: () -> Void
    let onRevert: () -> Void
    /// Names the project scope the per-row Rewind button posts
    /// `.maughamOpenRewind` to (ADR 0021), so multi-window setups dispatch the
    /// modal only on the window on that project.
    let projectURL: URL

    /// For lifecycle ops (claudeAccept/claudeReject/claudeArchive) the body
    /// of interest is on the CREATION op (claudeComment/claudeSuggestion/
    /// claudeQuery/claudeCraftNote) pointed to by provenance.sourceAnnotationId.
    /// Resolves it from the parent HistoryPane's op index when present.
    private func resolvedBody(for op: Op) -> String? {
        if let body = op.provenance?.annotationBody, !body.isEmpty {
            return body
        }
        if let sourceId = op.provenance?.sourceAnnotationId,
           let source = lookupOp(sourceId) {
            return source.provenance?.annotationBody
        }
        return nil
    }

    /// Short paragraph-id chip for the header. Returns nil for ops without
    /// a paragraph anchor (e.g. craft_note creation, checkpoint).
    private func paragraphAnchor(for op: Op) -> String? {
        if let pid = op.changes.first?.paragraphId, !pid.isEmpty {
            return pid
        }
        if let sourceId = op.provenance?.sourceAnnotationId,
           let source = lookupOp(sourceId),
           let pid = source.changes.first?.paragraphId, !pid.isEmpty {
            return pid
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if expanded {
                expandedDetail
            } else {
                collapsedPreview
            }
            if case .checkpoint = entry {
                Button("Revert here…", action: onRevert)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .simultaneousGesture(TapGesture().onEnded { })
            } else if case .op(let op) = entry, mutatesManuscript(op.kind),
                      let before = rewindTarget {
                Button {
                    MaughamEvent.post(
                        .maughamOpenRewind, to: .project(for: projectURL),
                        payload: ["scrub_op_id": before.opId,
                                  "scrub_op_at": before.at])
                } label: {
                    Label("Rewind to before this…", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Rewind to before this point…")
                .simultaneousGesture(TapGesture().onEnded { })
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .simultaneousGesture(
            TapGesture().modifiers(.command).onEnded { _ in onJump() })
    }

    private func mutatesManuscript(_ kind: OpKind) -> Bool {
        switch kind {
        case .typingBurst, .externalEdit, .claudeAccept, .claudeAcceptRevert,
             .checkpointRestore:
            return true
        case .bootstrap, .checkpoint, .claudeComment, .claudeSuggestion,
             .claudeQuery, .claudeCraftNote, .claudeReject, .claudeArchive,
             .annotationEdit, .annotationWithdraw, .annotationReopen,
             .annotationStet, .annotationTriage,
             .taskCreate, .taskStatusChange, .taskPriorityChange,
             .taskParentChange, .taskBodyEdit, .taskArchive:
            return false
        case .unknown:
            // Newer-build op (ADR 0015): treated as inert by the Deriver, so
            // it doesn't mutate the manuscript on this build.
            return false
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Label(kindLabel, systemImage: kindIcon)
                .font(.caption)
                .foregroundStyle(kindColor)
            if case .op(let op) = entry,
               let pid = paragraphAnchor(for: op) {
                Text("¶\(pid.prefix(6))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var collapsedPreview: some View {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst:
                Text("\(op.changes.count) paragraph\(op.changes.count == 1 ? "" : "s") edited")
                    .font(.caption).foregroundStyle(.secondary)
            case .claudeComment, .claudeQuery, .claudeCraftNote, .claudeSuggestion:
                Text(op.provenance?.annotationBody ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            case .claudeAccept:
                if let body = resolvedBody(for: op) {
                    Text(body).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Accepted").font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .claudeAcceptRevert:
                // Inverse of claudeAccept: reverts a previously accepted
                // suggestion, restoring the prior paragraph text.
                // `provenance.sourceAnnotationId` points at the creation op.
                if let body = resolvedBody(for: op) {
                    Text(body).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Accepted suggestion reverted").font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .claudeReject:
                if let r = op.provenance?.userResponse {
                    Text("\"\(r)\"").italic()
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let body = resolvedBody(for: op) {
                    Text(body).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case .claudeArchive:
                // Show the original annotation body when we have it so the
                // forensic record is legible (the synthesisSource alone
                // — "paragraph deleted" — gives the cause but not the
                // content). Auto-archives from paragraph deletion get
                // both: body + cause.
                if let body = resolvedBody(for: op) {
                    let cause: String = {
                        switch op.provenance?.synthesisSource {
                        case .paragraphDeleted: return " · paragraph deleted"
                        case .rewind:           return " · removed by rewind"
                        default:                return ""
                        }
                    }()
                    Text("\(body)\(cause)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text({
                        switch op.provenance?.synthesisSource {
                        case .paragraphDeleted: return "paragraph deleted"
                        case .rewind:           return "removed by rewind"
                        default:                return "archived"
                        }
                    }() as String)
                    .font(.caption).foregroundStyle(.secondary)
                }
            case .annotationEdit:
                Text(op.provenance?.annotationBody ?? "Annotation edited")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            case .annotationWithdraw:
                Text("Annotation withdrawn")
                    .font(.caption).foregroundStyle(.secondary)
            case .annotationReopen:
                Text("Annotation reopened")
                    .font(.caption).foregroundStyle(.secondary)
            case .annotationStet:
                // Same shape as the reject arm: the writer's own words about
                // why it stands, else the note they were answering.
                if let r = op.provenance?.userResponse {
                    Text("\"\(r)\"").italic()
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let body = resolvedBody(for: op) {
                    Text(body).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Let stand").font(.caption).foregroundStyle(.secondary)
                }
            case .annotationTriage:
                Text(op.provenance?.triageMark.map { "Triaged · \($0)" } ?? "Triage cleared")
                    .font(.caption).foregroundStyle(.secondary)
            case .externalEdit:
                Text("\(op.changes.count) paragraph\(op.changes.count == 1 ? "" : "s") changed externally")
                    .font(.caption).foregroundStyle(.secondary)
            case .checkpoint, .checkpointRestore, .bootstrap:
                EmptyView()
            case .taskCreate, .taskStatusChange, .taskPriorityChange,
                 .taskParentChange, .taskBodyEdit, .taskArchive:
                if let body = op.provenance?.taskBody {
                    Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    EmptyView()
                }
            case .unknown:
                // An op written by a newer Maugham build (ADR 0015). Show a
                // neutral placeholder rather than crash; a future named kind
                // makes this switch a compile error, forcing a real label.
                Text("Newer-version entry").font(.caption).foregroundStyle(.secondary)
            }
        case .checkpoint(let cp):
            Text("\(cp.manuscriptWordCount) words · \(cp.label)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var expandedDetail: some View {
        switch entry {
        case .op(let op):
            if op.kind == .claudeAccept || op.kind == .claudeSuggestion {
                ForEach(Array(op.changes.enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 1) {
                        if let prior = change.prior {
                            Text("− \(prior)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08))
                        }
                        Text("+ \(change.next)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                    }
                }
            } else if let body = resolvedBody(for: op) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(body).font(.callout)
                    if let resp = op.provenance?.userResponse {
                        Text("Your reply: \"\(resp)\"")
                            .font(.caption).italic()
                            .foregroundStyle(.secondary)
                    }
                    if op.provenance?.synthesisSource == .paragraphDeleted {
                        Text("Auto-archived: paragraph deleted from manuscript.")
                            .font(.caption2).foregroundStyle(.orange)
                    } else if op.provenance?.synthesisSource == .rewind {
                        Text("Auto-archived: paragraph removed by rewind.")
                            .font(.caption2).foregroundStyle(.orange)
                    } else if op.provenance?.synthesisSource == .rejectConvergence {
                        // RULING-33. The paragraph moved and no gesture of the
                        // writer's moved it, so the history has to say who did
                        // and why — otherwise this reads as a second rejection
                        // they do not remember making.
                        Text("Removed a change accepted on another device, so the "
                             + "rejection and the manuscript agree.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            } else if let resp = op.provenance?.userResponse {
                Text("\"\(resp)\"").italic().font(.callout)
            } else {
                collapsedPreview
            }
        case .checkpoint(let cp):
            Text(cp.label).font(.callout)
        }
    }

    private var kindLabel: String {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst: return "Typed"
            case .claudeComment: return "Comment"
            case .claudeSuggestion: return "Suggestion"
            case .claudeAccept: return "Accepted"
            case .claudeAcceptRevert: return "Accept reverted"
            case .claudeReject:
                // The convergence repair is a reject the WRITER did not issue
                // (RULING-33) — same op kind, different actor. Labelling both
                // "Rejected" would put an act of Maugham's in the writer's
                // column, which is the same misattribution the `.rewind` /
                // `.paragraphDeleted` arms above exist to avoid.
                return op.provenance?.synthesisSource == .rejectConvergence
                    ? "Rejection applied" : "Rejected"
            case .claudeArchive: return "Archived"
            case .claudeQuery: return "Query"
            case .claudeCraftNote: return "Craft"
            case .externalEdit: return "External edit"
            case .checkpoint: return "Checkpoint"
            case .checkpointRestore:
                switch op.provenance?.synthesisSource {
                case .rewind: return "Rewound"
                case .undoRewind: return "Rewind undone"
                default: return "Reverted"
                }
            case .bootstrap: return "Initial"
            case .taskCreate: return "Task created"
            case .taskStatusChange: return "Task status"
            case .taskPriorityChange: return "Task reorder"
            case .taskParentChange: return "Task nested"
            case .taskBodyEdit: return "Task edited"
            case .taskArchive: return "Task archived"
            case .annotationEdit: return "Annotation edited"
            case .annotationWithdraw: return "Annotation withdrawn"
            case .annotationReopen: return "Annotation reopened"
            case .annotationStet: return "Let stand"
            case .annotationTriage: return "Annotation triaged"
            case .unknown: return "Newer version"
            }
        case .checkpoint:
            return "Checkpoint"
        }
    }
    private var kindIcon: String {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst: return "pencil"
            case .claudeComment: return "bubble.left"
            case .claudeSuggestion: return "wand.and.stars"
            case .claudeAccept: return "checkmark.circle"
            case .claudeAcceptRevert: return "arrow.uturn.backward.circle"
            case .claudeReject: return "xmark.circle"
            case .claudeArchive: return "archivebox"
            case .claudeQuery: return "questionmark.circle"
            case .claudeCraftNote: return "ruler"
            case .externalEdit: return "arrow.down.doc"
            case .checkpoint, .checkpointRestore: return "flag"
            case .bootstrap: return "circle.dashed"
            case .taskCreate, .taskStatusChange, .taskPriorityChange,
                 .taskParentChange, .taskBodyEdit, .taskArchive:
                return "checklist"
            case .annotationEdit: return "pencil"
            case .annotationWithdraw: return "trash"
            case .annotationReopen: return "arrow.uturn.up"
            case .annotationStet: return "checkmark.seal"
            case .annotationTriage: return "line.3.horizontal.decrease.circle"
            case .unknown: return "questionmark.square.dashed"
            }
        case .checkpoint: return "flag"
        }
    }
    private var kindColor: Color {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst, .bootstrap: return .blue
            case .claudeComment: return .blue
            case .claudeSuggestion: return .orange
            case .claudeAccept: return .green
            case .claudeAcceptRevert: return .teal
            case .claudeReject: return .red
            case .claudeArchive: return .gray
            case .claudeQuery: return .purple
            case .claudeCraftNote: return .yellow
            case .externalEdit: return .purple
            case .checkpoint, .checkpointRestore: return .green
            case .taskCreate, .taskStatusChange, .taskPriorityChange,
                 .taskParentChange, .taskBodyEdit, .taskArchive:
                return Color(red: 0.38, green: 0.76, blue: 0.45)
            case .annotationEdit, .annotationWithdraw, .annotationReopen,
                 .annotationStet, .annotationTriage: return .orange
            case .unknown: return .gray
            }
        case .checkpoint: return .green
        }
    }
}


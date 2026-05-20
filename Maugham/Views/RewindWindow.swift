import SwiftUI

/// Per-doc time-travel modal. Opens via the "Rewind…" header button in
/// HistoryPane (T13) or via the per-row "↺" button (T13). Reads the active
/// doc's op log at open-time (snapshot — no live updates during the
/// session), derives state at any past op for read-only preview, and
/// emits one terminal action via `onComplete`: Cancel, SnapshotHere(label),
/// or RestoreHere.
@MainActor
struct RewindWindow: View {
    let projectURL: URL
    let activeDocId: String
    let allDocIds: [String]
    let device: String
    let session: String
    let docPaths: [String: String]
    let documentStore: DocumentStore?
    let docTitle: String
    /// The initial scrubber position. `.now` for the header button;
    /// `.atOp(...)` for the per-row deep-link.
    let initialCursor: RewindCursor
    let onComplete: (RewindAction) -> Void

    // Snapshot of the op log captured at modal-open time. Stable for the
    // life of the modal session — MCP writes during the session don't appear.
    @State private var ops: [Op] = []
    @State private var cursor: RewindCursor = .now
    @State private var previewMode: PreviewMode = .doc
    @State private var derivedState: Deriver.DerivedState = .init(paragraphs: [:], sequence: [])
    @State private var nowState: Deriver.DerivedState = .init(paragraphs: [:], sequence: [])
    @State private var showingSnapshotPrompt: Bool = false
    @State private var showingRestoreConfirm: Bool = false
    @State private var deriveTask: Task<Void, Never>?

    enum PreviewMode: Equatable { case doc, diff }

    private static let headerDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return f
    }()

    private var rawTicks: [RewindTickLayout.RawTick] {
        ops.map { .init(opId: $0.opId, at: $0.at, kind: $0.kind) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scrubberSection
            Divider()
            previewArea.frame(maxHeight: .infinity)
            Divider()
            actionFooter
        }
        .frame(minWidth: 900, minHeight: 640)
        .task { await load() }
        .sheet(isPresented: $showingSnapshotPrompt) {
            CheckpointLabelPromptSheet(
                onConfirm: { label in
                    showingSnapshotPrompt = false
                    Task { await snapshotHere(label: label) }
                },
                onCancel: { showingSnapshotPrompt = false })
        }
        .sheet(isPresented: $showingRestoreConfirm) {
            restoreConfirmSheet
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("REWINDING")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(headerContext).font(.callout)
            }
            Spacer()
            Picker("", selection: $previewMode) {
                Text("Doc").tag(PreviewMode.doc)
                Text("Diff").tag(PreviewMode.diff)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            Button { onComplete(.cancel) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private var scrubberSection: some View {
        GeometryReader { geo in
            let width = geo.size.width - 32
            let ticks = RewindTickLayout.decimate(ticks: rawTicks, width: width)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.secondary.opacity(0.15))
                    .frame(height: 4)
                    .padding(.top, 14)
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    let frac = fraction(for: tick.at)
                    let xPos = CGFloat(frac) * width
                    let isLandmark = tick.kind == .checkpoint || tick.kind == .checkpointRestore
                    Rectangle()
                        .fill(color(for: tick.kind))
                        .frame(width: isLandmark ? 3 : 1,
                               height: isLandmark ? 12 : 8)
                        .offset(x: xPos, y: isLandmark ? 10 : 12)
                }
                let curFrac = fraction(for: cursorDate)
                Rectangle().fill(Color.purple)
                    .frame(width: 2, height: 24)
                    .offset(x: CGFloat(curFrac) * width, y: 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrub(toX: value.location.x, width: width)
                    }
            )
        }
        .frame(height: 50)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var previewArea: some View {
        ScrollView {
            if previewMode == .doc {
                Text(renderedDoc(state: derivedState))
                    .font(.system(.body, design: .serif))
                    .padding(40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                diffView
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private var diffView: some View {
        let currentSet = Set(nowState.sequence)
        let pastSet = Set(derivedState.sequence)
        let removedOnRestore = nowState.sequence.filter { !pastSet.contains($0) }
        let returnedOnRestore = derivedState.sequence.filter { !currentSet.contains($0) }
        let stillPresent = nowState.sequence.filter { pastSet.contains($0) }

        VStack(alignment: .leading, spacing: 8) {
            ForEach(stillPresent, id: \.self) { pid in
                let now = nowState.paragraphs[pid] ?? ""
                let past = derivedState.paragraphs[pid] ?? ""
                if now == past {
                    Text(now).font(.system(.body, design: .serif))
                } else {
                    VStack(alignment: .leading) {
                        Text(now).strikethrough()
                            .foregroundStyle(.red)
                            .font(.system(.body, design: .serif))
                        Text(past).underline()
                            .foregroundStyle(.green)
                            .font(.system(.body, design: .serif))
                    }
                }
            }
            ForEach(removedOnRestore, id: \.self) { pid in
                Text(nowState.paragraphs[pid] ?? "")
                    .strikethrough().foregroundStyle(.red)
                    .font(.system(.body, design: .serif))
            }
            ForEach(returnedOnRestore, id: \.self) { pid in
                Text(derivedState.paragraphs[pid] ?? "")
                    .underline().foregroundStyle(.green)
                    .font(.system(.body, design: .serif))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionFooter: some View {
        HStack(spacing: 12) {
            if case .atOp = cursor {
                Text(impactSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onComplete(.cancel) }
            Button("Snapshot here…") { showingSnapshotPrompt = true }
                .disabled(cursor == .now)
            Button("Restore here…") { showingRestoreConfirm = true }
                .buttonStyle(.borderedProminent)
                .disabled(cursor == .now)
        }
        .padding(16)
    }

    @ViewBuilder
    private var restoreConfirmSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore \(docTitle) to this point?").font(.headline)
            Text(impactSummary).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingRestoreConfirm = false }
                Button("Restore") {
                    showingRestoreConfirm = false
                    if case .atOp(let opId, _) = cursor {
                        onComplete(.restoreHere(opId: opId))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    // MARK: - Logic

    private func load() async {
        // Flush pending burst on the active document so the "Now" anchor
        // reflects in-flight typing (spec §3.1).
        if let ds = documentStore,
           let doc = ds.document(forDocId: activeDocId) {
            try? await doc.flushBurstNow()
            ops = (try? await doc.opLog()) ?? []
        } else {
            let opStore = OpLogStore(projectURL: projectURL)
            ops = (try? await opStore.load(docId: activeDocId)) ?? []
        }
        nowState = Deriver.derive(ops: ops)
        cursor = initialCursor
        await updateDerivedState()
    }

    private func updateDerivedState() async {
        let snapshot = cursor
        let newState = Deriver.derive(ops: ops, upTo: snapshot)
        if Task.isCancelled { return }
        derivedState = newState
    }

    private func scrub(toX x: CGFloat, width: CGFloat) {
        guard !ops.isEmpty, width > 0 else { return }
        let frac = max(0, min(1, x / width))
        let firstT = ops.first!.at.timeIntervalSince1970
        let lastT = ops.last!.at.timeIntervalSince1970
        let span = max(lastT - firstT, 0.001)
        let targetT = firstT + Double(frac) * span
        let nearest = ops.min(by: {
            abs($0.at.timeIntervalSince1970 - targetT)
                < abs($1.at.timeIntervalSince1970 - targetT)
        })
        if let op = nearest {
            cursor = .atOp(opId: op.opId, at: op.at)
            deriveTask?.cancel()
            deriveTask = Task { await updateDerivedState() }
        }
    }

    private func snapshotHere(label: String) async {
        guard case .atOp(let opId, _) = cursor else { return }
        let opStore = OpLogStore(projectURL: projectURL)
        var pointers: [String: String] = [:]
        for did in allDocIds {
            if did == activeDocId {
                pointers[did] = opId
            } else if let lastOp = try? await opStore.load(docId: did).last {
                pointers[did] = lastOp.opId
            }
        }
        var totalWords = derivedState.paragraphs.values
            .map { $0.split { $0.isWhitespace || $0.isNewline }.count }
            .reduce(0, +)
        for did in allDocIds where did != activeDocId {
            if let other = try? await opStore.load(docId: did) {
                let s = Deriver.derive(ops: other)
                totalWords += s.paragraphs.values
                    .map { $0.split { $0.isWhitespace || $0.isNewline }.count }
                    .reduce(0, +)
            }
        }
        let now = Date()
        let snappedAt = Date(timeIntervalSince1970:
            (now.timeIntervalSince1970 * 1000).rounded() / 1000)
        let cp = Checkpoint(
            checkpointId: ULID.generate(),
            label: label,
            labelSource: .user,
            at: snappedAt,
            device: device,
            activeDoc: activeDocId,
            docPointers: pointers,
            manuscriptWordCount: totalWords)
        try? await CheckpointStore(projectURL: projectURL).append(cp)
        onComplete(.snapshotHere(label: label))
    }

    private var cursorDate: Date {
        switch cursor {
        case .now: return ops.last?.at ?? Date()
        case .atOp(_, let at): return at
        }
    }

    private func fraction(for date: Date) -> Double {
        guard let first = ops.first?.at, let last = ops.last?.at else { return 1.0 }
        let span = max(last.timeIntervalSince1970 - first.timeIntervalSince1970, 0.001)
        return (date.timeIntervalSince1970 - first.timeIntervalSince1970) / span
    }

    private var headerContext: String {
        switch cursor {
        case .now:
            return "Now — drag the scrubber to revisit a past moment"
        case .atOp(let opId, let at):
            let idx = ops.firstIndex(where: { $0.opId == opId }) ?? -1
            let opsAgo = ops.count - 1 - idx
            return "\(Self.headerDateFmt.string(from: at)) · \(opsAgo) ops ago"
        }
    }

    private var impactSummary: String {
        let removed = Set(nowState.sequence).subtracting(Set(derivedState.sequence))
        let words = removed.compactMap { nowState.paragraphs[$0] }
            .map { $0.split { $0.isWhitespace || $0.isNewline }.count }
            .reduce(0, +)
        return "Restoring would undo \(words) words / \(removed.count) paragraph\(removed.count == 1 ? "" : "s") written after this point."
    }

    private func renderedDoc(state: Deriver.DerivedState) -> String {
        // The Materializer name in this codebase is `Materializer.materialize`
        // (not `.render`). Strip ¶id HTML-comment anchors so the preview is
        // clean prose.
        Materializer.materialize(paragraphs: state.paragraphs, sequence: state.sequence)
            .replacingOccurrences(
                of: #"<!--\s*¶[0-9a-z]{4,}\s*-->\n?"#,
                with: "",
                options: .regularExpression)
    }

    private func color(for kind: OpKind) -> Color {
        switch kind {
        case .typingBurst, .bootstrap:
            return Color(red: 0.53, green: 0.67, blue: 0.73)
        case .externalEdit:
            return Color(red: 0.77, green: 0.56, blue: 0.94)
        case .checkpoint, .checkpointRestore:
            return Color(red: 0.42, green: 0.88, blue: 0.66)
        case .claudeComment, .claudeQuery, .claudeCraftNote,
             .claudeSuggestion, .claudeAccept, .claudeReject, .claudeArchive:
            return Color(red: 1.0, green: 0.66, blue: 0.25)
        }
    }
}

import SwiftUI
import MaughamCore

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
    let scope: RewindScope
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
        .onChange(of: cursor) { _, _ in
            // Drive derive directly off cursor changes — SwiftUI guarantees
            // this fires after the @State write, so we don't depend on the
            // scrub() call site dispatching a Task itself.
            updateDerivedStateNow()
        }
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
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let ticks = RewindTickLayout.decimate(ticks: rawTicks, width: width)
                ZStack(alignment: .topLeading) {
                    // Background hit-target: full 50pt-tall rectangle so a click
                    // anywhere in the scrubber strip lands on the drag gesture
                    // (not just the 4pt-tall bar). Transparent so visually the
                    // grey bar still reads as the timeline.
                    Rectangle().fill(Color.clear)
                        .frame(width: width, height: 50)
                        .contentShape(Rectangle())
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                        .offset(y: 23)
                    ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                        let frac = fraction(for: tick.at)
                        let xPos = CGFloat(frac) * width
                        let isLandmark = tick.kind == .checkpoint || tick.kind == .checkpointRestore
                        Rectangle()
                            .fill(color(for: tick.kind))
                            .frame(width: isLandmark ? 3 : 1,
                                   height: isLandmark ? 14 : 10)
                            .offset(x: xPos, y: isLandmark ? 18 : 20)
                    }
                    let curFrac = fraction(for: cursorDate)
                    Rectangle().fill(Color.purple)
                        .frame(width: 2, height: 30)
                        .offset(x: CGFloat(curFrac) * width, y: 10)
                }
                .frame(width: width, height: 50)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrub(toX: value.location.x, width: width)
                        }
                )
            }
            .frame(height: 50)
            legend
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var legend: some View {
        HStack(spacing: 14) {
            legendChip(text: "typed", swatchColor: color(for: .typingBurst))
            legendChip(text: "checkpoint", swatchColor: color(for: .checkpoint))
            legendChip(text: "Claude annotation", swatchColor: color(for: .claudeComment))
            legendChip(text: "external edit", swatchColor: color(for: .externalEdit))
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func legendChip(text: String, swatchColor: Color) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(swatchColor)
                .frame(width: 8, height: 4)
            Text(text)
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        ScrollView {
            if previewMode == .doc {
                // Per-paragraph LazyVStack, NOT one whole-document Text:
                // SwiftUI Text silently renders BLANK past roughly ~200 KB,
                // which made every rewind cursor whose derived doc exceeded
                // that look like lost history (2026-06-10 smoke, 250-page
                // screenplay — derived states of 400-500 KB at the latest
                // cursors). Lazy rows keep per-row cost bounded at any doc
                // size; identity is positional (sequence order) so legacy
                // docs carrying duplicate ¶ids can't trip ForEach.
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(derivedState.sequence.enumerated()),
                            id: \.offset) { _, pid in
                        Text(RenderFilter.stripTaskAnchorsInline(
                            derivedState.paragraphs[pid] ?? ""))
                            .font(.system(.body, design: .serif))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(40)
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
            // RULING-37's view half: Restore is not offered when the restore
            // would change nothing — no text delta, no task window to move.
            Button("Restore here…") { showingRestoreConfirm = true }
                .buttonStyle(.borderedProminent)
                .disabled(cursor == .now || !impactPreview.changesAnything)
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
        // Use the fallback-aware deriver so legacy projects whose ops
        // predate the "always capture sequence on burst" fix still get a
        // usable nowState. Otherwise sequence comes back empty and the
        // preview / diff collapse to nothing.
        nowState = Deriver.deriveWithSequenceFallback(ops: ops)
        cursor = initialCursor
        updateDerivedStateNow()
    }

    /// Recompute derived state synchronously on MainActor. Deriver.derive is
    /// pure and O(N) on op count — even at 10k ops this completes in <100ms,
    /// fast enough to run inline on a scrub event without needing a Task.
    /// Sync also means SwiftUI sees the new derivedState in the same render
    /// cycle as the cursor change, so the preview never lags a frame.
    private func updateDerivedStateNow() {
        derivedState = Deriver.derive(ops: ops, upTo: cursor)
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
            // Setting cursor triggers .onChange(of: cursor) → updateDerivedStateNow.
            cursor = .atOp(opId: op.opId, at: op.at)
        }
    }

    private func snapshotHere(label: String) async {
        guard case .atOp(let opId, _) = cursor else { return }
        switch scope {
        case .thisDoc:
            break  // existing per-doc behaviour
        // case .project: — v2: build all-doc pointers differently
        }
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

    /// The cursor's full collateral preview (RULING-28: the confirmation
    /// states the complete set — archives, reopens, re-accepts, words — via
    /// `RewindImpact`, the same mirror the after-toast renders from).
    private var impactPreview: RewindImpact.Preview {
        guard case .atOp(let targetOpId, _) = cursor else {
            return RewindImpact.preview(ops: ops, cursorOpId: nil)
        }
        return RewindImpact.preview(ops: ops, cursorOpId: targetOpId)
    }

    private var impactSummary: String {
        RewindImpact.confirmSummary(impactPreview)
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
             .claudeSuggestion, .claudeAccept, .claudeAcceptRevert,
             .claudeReject, .claudeArchive,
             .annotationEdit, .annotationWithdraw, .annotationReopen:
            return Color(red: 1.0, green: 0.66, blue: 0.25)
        case .taskCreate, .taskStatusChange, .taskPriorityChange,
             .taskParentChange, .taskBodyEdit, .taskArchive:
            return Color(red: 0.38, green: 0.76, blue: 0.45)
        case .unknown:
            // Newer-build op kind (ADR 0015); neutral tick color.
            return .gray
        }
    }
}

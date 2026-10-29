import SwiftUI
import MaughamCore

// MARK: - The timeline

/// **History's timeline**: the empty state, or the project section above this
/// document's rows, newest first.
///
/// Owns no state. The rows' disclosure and the restore picker's checkpoint are
/// the pane's `@State`, by binding; *Rewind* and *Revert* are offered from the
/// posture asked in THIS body pass, inside the non-empty branch, so an empty
/// pane asks the drawing door nothing. The rows stay in the `LazyVStack`
/// (tripwire 4).
@MainActor
struct HistoryTimeline: View {
    let filter: HistoryFilter
    let ops: [Op]
    let checkpoints: [Checkpoint]
    let trustEventLines: [HistoryPane.TrustEventLine]
    let projectURL: URL
    let activeDocId: String
    let allDocIds: [String]
    let documentStore: DocumentStore?
    @Binding var expanded: Set<String>
    @Binding var selectedCheckpoint: Checkpoint?
    @Binding var showingRestorePicker: Bool
    let jump: (HistoryEntry) -> Void

    private var entries: [HistoryEntry] {
        HistoryEntry.merge(ops: ops, checkpoints: checkpoints)
            .filter { filter.matches($0) }
    }

    private var emptyTitle: String {
        switch filter {
        case .all:         return "No history yet"
        case .checkpoints: return "No checkpoints"
        case .edits:       return "No edits"
        case .annotations: return "No annotations"
        }
    }

    private var emptySymbol: String {
        switch filter {
        case .all:         return "clock.arrow.circlepath"
        case .checkpoints: return "flag"
        case .edits:       return "pencil"
        case .annotations: return "bubble.left.and.bubble.right"
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
        }
    }

    var body: some View {
        // Filtered ONCE per body pass: the empty test, the Revert question
        // and the rows all read this one array (tripwire 4).
        let rows = entries
        if rows.isEmpty && trustEventLines.isEmpty {
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
                let predecessors = HistoryPane.predecessorIndex(ops: ops)
                // The same for the op index a lifecycle row resolves its
                // creation op through: built here, never per lookup.
                let opsIndex = HistoryPane.opsIndex(ops)
                // What this Mac may do FROM history, asked once per body
                // pass (P3c whole-branch fix wave, C1): a reviewer reads
                // every row and is offered no rewind and no revert.
                let offersRewind = HistoryPane.offersRewind(
                    documentStore?.posture(forDocId: activeDocId))
                let offersRevert = HistoryPane.offersRevert(
                    for: rows, docIds: allDocIds,
                    mayWrite: PartialRestorePicker.mayWrite(through: documentStore))
                // The book's own entries lead the document's (ruling C).
                // They are FEW — an admission, a revocation, a claim — and
                // they are the context every entry below them is written
                // in, so they sit above rather than interleaved by date
                // into a timeline whose other rows are one document's.
                //
                // The outer `VStack` is load-bearing: a `ScrollView` does
                // not stack its children, so two views handed to it
                // directly would be drawn ON TOP of one another. The inner
                // stack stays lazy, which is where the rows are.
                VStack(spacing: 0) {
                    projectSection
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { entry in
                            HistoryRow(
                                entry: entry,
                                expanded: expanded.contains(entry.id),
                                lookupOp: { opsIndex[$0] },
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
                                offersRewind: offersRewind,
                                offersRevert: offersRevert,
                                projectURL: projectURL)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    /// History's project-scope section: what happened to this book's people,
    /// dated, above the document's own timeline (ruling C).
    ///
    /// Absent entirely when nothing has happened — which is every project that
    /// has never joined a chain, admitted anybody or been claimed, and so is
    /// most of them. A heading over an empty list would be a permanent reminder
    /// of a feature the writer is not using.
    @ViewBuilder
    private var projectSection: some View {
        if !trustEventLines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(HistoryPane.projectSectionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(trustEventLines) { line in
                    HStack(spacing: 6) {
                        Label(line.sentence, systemImage: line.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if let date = line.date {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
            }
        }
    }
}

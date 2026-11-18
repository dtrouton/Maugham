import SwiftUI
import MaughamCore

/// **What the open piece has settled** (RULING-29, -31, -34) — To resolve's
/// collapsed last section, so Reopen, Revert and a findable Deleted view
/// outlive the Annotations pane, and the done to-dos have a home.
///
/// Offered only at a `.piece` scope on the piece open in the centre: every
/// verb here is a `Document` method, and the only `Document` To resolve acts
/// through is the editor's (`ResolveVerbGate`). Nothing here is read until
/// the writer opens the section.
enum ResolveSettled {

    /// What the section holds, read off the open piece's live `Document`.
    struct Contents {
        /// Resolved notes, newest first: accepted, rejected, archived, stetted.
        let resolved: [Annotation]
        /// Notes withdrawn (deleted), restorable where their door allows.
        let deleted: [AnnotationDeriver.WithdrawnAnnotation]
        /// The piece's done to-dos.
        let done: [WriterTask]
    }

    /// Drawn only on the open piece, at a `.piece` scope.
    static func offered(scope: ResolveScope, mayAct: Bool) -> Bool {
        guard mayAct, case .piece = scope else { return false }
        return true
    }

    /// **Archive all done**, hidden — never an enabled no-op (RULING-35) —
    /// off the open piece, where the posture files no task, or with nothing
    /// done.
    static func offersArchiveAllDone(mayAct: Bool, posture: Posture, doneCount: Int) -> Bool {
        mayAct && doneCount > 0 && posture.allows(.task)
    }

    /// The open piece's settled notes and done to-dos. Called only while the
    /// section is open; `withdrawnAnnotations()` walks the op log.
    @MainActor
    static func contents(of document: Document) -> Contents {
        let settled: Set<AnnotationStatus> = [.accepted, .rejected, .archived, .stetted]
        let resolved = document.annotations(filter: AnnotationFilter(statuses: settled))
            .sorted { ($0.resolvedAt ?? $0.createdAt) > ($1.resolvedAt ?? $1.createdAt) }
        let done = document.tasks(filter: TaskFilter(
            scope: .document(docId: document.docId), statuses: [.done]))
        return Contents(resolved: resolved, deleted: document.withdrawnAnnotations(), done: done)
    }
}

/// **The Settled section's view.** A disclosure row; opened, the resolved
/// notes through the same row host as the list (Reopen, Revert), the deleted
/// notes with Restore (the old queue's Deleted view, unchanged), and the done
/// to-dos with Archive all done.
@MainActor
struct ResolveSettledSection: View {
    let document: Document
    let posture: Posture
    let ledgerText: String?
    let wiring: AnnotationRowWiring
    let noteVerbs: ResolveNoteVerbs
    let taskVerbs: ResolveTaskVerbs
    let onJumpToTask: (WriterTask) -> Void
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Settled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
            if isExpanded {
                expanded
            }
        }
    }

    @ViewBuilder
    private var expanded: some View {
        let contents = ResolveSettled.contents(of: document)
        if contents.resolved.isEmpty && contents.deleted.isEmpty && contents.done.isEmpty {
            Text("Nothing settled yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
        if !contents.resolved.isEmpty {
            let livePids = Set(document.sequence)
            ForEach(contents.resolved) { ann in
                AnnotationRowHost(
                    annotation: ann, docId: document.docId, document: document,
                    livePids: livePids, ledgerText: ledgerText, wiring: wiring)
                Divider()
            }
        }
        if !contents.deleted.isEmpty {
            // RULING-34: the writer's withdrawn notes are findable here and
            // restorable — not gone at one expired ⌘Z's mercy.
            Text("Deleted")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 10)
            ForEach(contents.deleted, id: \.id) { note in
                HStack(spacing: 8) {
                    Text(note.body)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    // A restore undoes a WITHDRAWAL, so it follows the deleter
                    // (ruling P, Ruling D), asked of the door's own judgement
                    // by key, and hidden where the door would refuse it.
                    if AnnotationRowVerbs.restoresDeleted(
                        posture: posture,
                        standing: document.restoreStanding(annotationId: note.id)) {
                        Button("Restore") { noteVerbs.reopen(document, id: note.id) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
            }
        }
        if !contents.done.isEmpty {
            HStack(spacing: 8) {
                Text("Done")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if ResolveSettled.offersArchiveAllDone(
                    mayAct: true, posture: posture, doneCount: contents.done.count) {
                    Button("Archive all done") { taskVerbs.archiveAllDone(in: .document) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10)
            ForEach(contents.done, id: \.id) { task in
                TaskRow(
                    task: task,
                    verbs: taskVerbs.offered(task),
                    onToggle: { taskVerbs.toggle(task) },
                    onJump: { onJumpToTask(task) },
                    onArchive: { taskVerbs.archive(task) },
                    onDelete: { taskVerbs.delete(task) })
                    .padding(.horizontal, 12)
                Divider()
            }
        }
    }
}

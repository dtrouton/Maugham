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
        /// The piece's archived to-dos — their one surface (shell plan 2
        /// Task 7 fix): an archived inline to-do's line is gone from the text.
        var archived: [WriterTask] = []
    }

    /// Drawn only on the open piece, at a `.piece` scope.
    static func offered(scope: ResolveScope, mayAct: Bool) -> Bool {
        guard mayAct, case .piece = scope else { return false }
        return true
    }

    /// **Archive all done**, hidden — never an enabled no-op (RULING-35) —
    /// where the posture files no task, or with nothing done. (Off the open
    /// piece there is no piece Settled section to draw it in: `offered`.)
    static func offersArchiveAllDone(posture: Posture, doneCount: Int) -> Bool {
        doneCount > 0 && posture.allows(.task)
    }

    /// **The Book's own Settled** — wherever the scope holds the Book level
    /// (the Book, a screenplay's Book). Its to-dos live on the project stream
    /// and need no `Document`, so it needs no open piece.
    static func offersBook(scope: ResolveScope) -> Bool {
        scope.includesBookLevel
    }

    /// The Book's archived to-dos, from the project stream alone.
    @MainActor
    static func bookArchived(store: ProjectStore) -> [WriterTask] {
        ResolveTaskVerbs.bookTasks(store: store).filter { $0.status == .archived }
    }

    /// The Book's done to-dos, from the project stream alone.
    @MainActor
    static func bookDone(store: ProjectStore) -> [WriterTask] {
        ResolveTaskVerbs.bookTasks(store: store).filter { $0.status == .done }
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
        let archived = document.tasks(filter: TaskFilter(
            scope: .document(docId: document.docId), statuses: [.archived]))
        return Contents(resolved: resolved, deleted: document.withdrawnAnnotations(), done: done,
                        archived: archived)
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
        if contents.resolved.isEmpty && contents.deleted.isEmpty && contents.done.isEmpty
            && contents.archived.isEmpty {
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
                    posture: posture, doneCount: contents.done.count) {
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
        ResolveArchivedTodos(archived: contents.archived, taskVerbs: taskVerbs)
    }
}

/// **Archived to-dos** (controller ruling, shell plan 2 Task 7 fix) — their
/// one surface since the Tasks pane went: each with Unarchive where
/// `ResolveTaskVerbs.offersUnarchive` holds, hidden otherwise.
@MainActor
struct ResolveArchivedTodos: View {
    let archived: [WriterTask]
    let taskVerbs: ResolveTaskVerbs

    var body: some View {
        if !archived.isEmpty {
            Text(Self.title)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 10)
            ForEach(archived, id: \.id) { task in
                HStack(spacing: 8) {
                    Text(task.body)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if ResolveTaskVerbs.offersUnarchive(task, verbs: taskVerbs.offered(task)) {
                        Button(Self.unarchiveTitle) { taskVerbs.unarchive(task) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
                .padding(.bottom, Self.whyNotUnarchived(task, verbs: taskVerbs.offered(task)) == nil ? 8 : 0)
                if let why = Self.whyNotUnarchived(task, verbs: taskVerbs.offered(task)) {
                    Text(why)
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
                Divider()
            }
        }
    }

    /// The one quiet line under an archived to-do that offers no Unarchive:
    /// why. Nil where Unarchive is offered.
    static func whyNotUnarchived(_ task: WriterTask, verbs: TaskRowVerbs) -> String? {
        if task.kind != .paneCreated { return inlineArchivedLine }
        return ResolveTaskVerbs.offersUnarchive(task, verbs: verbs) ? nil : refusedArchivedLine
    }

    static let inlineArchivedLine = "Its line left the text when it was archived."
    static let refusedArchivedLine = "Restoring it isn\u{2019}t yours to do on this Mac."

    static let title = "Archived"
    static let unarchiveTitle = "Unarchive"
}

/// **The Book's Settled section** — its done to-dos (un-tick, archive,
/// delete, Archive all done), on the project stream. Each verb is offered by
/// the stream's posture and hidden where it refuses. Nothing is read until
/// the section is opened.
@MainActor
struct ResolveBookSettledSection: View {
    let store: ProjectStore
    /// The project stream's posture (`__project__`).
    let posture: Posture
    let taskVerbs: ResolveTaskVerbs
    @Binding var isExpanded: Bool

    /// The done Book to-dos, derived once per key — the section open and the
    /// project stream's version — never per render.
    @State private var done: [WriterTask] = []
    @State private var archived: [WriterTask] = []

    private struct ReadKey: Equatable { let open: Bool; let version: Int }

    /// The Done heading: "Done" over done to-dos; nothing to say when only
    /// archived ones stand; the empty line when the Book holds neither.
    static func doneHeading(done: Int, archived: Int) -> String {
        if done > 0 { return "Done" }
        return archived > 0 ? "" : "No Book to-dos are done or archived."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Settled on the Book")
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
        .task(id: ReadKey(open: isExpanded, version: store.projectTasksVersion)) {
            done = isExpanded ? ResolveSettled.bookDone(store: store) : []
            archived = isExpanded ? ResolveSettled.bookArchived(store: store) : []
        }
    }

    @ViewBuilder
    private var expanded: some View {
        HStack(spacing: 8) {
            Text(Self.doneHeading(done: done.count, archived: archived.count))
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if ResolveSettled.offersArchiveAllDone(posture: posture, doneCount: done.count) {
                Button("Archive all done") { taskVerbs.archiveAllDoneOnTheBook() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        ForEach(done, id: \.id) { task in
            TaskRow(
                task: task,
                verbs: taskVerbs.offered(task),
                onToggle: { taskVerbs.toggle(task) },
                onJump: {},
                onArchive: { taskVerbs.archive(task) },
                onDelete: { taskVerbs.delete(task) })
                .padding(.horizontal, 12)
            Divider()
        }
        ResolveArchivedTodos(archived: archived, taskVerbs: taskVerbs)
    }
}

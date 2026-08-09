import SwiftUI

/// The trashed-items list: title + "sweep in N days" + Restore / Permanently
/// Delete context menu, per row. **No "Empty Trash" here** — that moved to
/// `TrashDisclosure`'s header row (shell-finish stage 2b Task 2), the one
/// place left that has a toolbar to put it on. This view used to carry both;
/// it shrank to just the rows so `TrashDisclosure` could wrap it verbatim
/// rather than forking a second spelling of a trash row.
struct TrashView: View {
    @Bindable var store: ProjectStore
    @State private var pendingPermanentDelete: TrashEntry?
    @State private var pendingError: String?
    /// What a restore could not give back — dropped rows, a name it had to
    /// change, a folder it could not put the file back into. Shown at the
    /// moment of the restore, because that is when it is true (RULING-42).
    @State private var restoreShortfall: String?

    var body: some View {
        List(store.trashEntries) { entry in
            row(for: entry)
        }
        .listStyle(.sidebar)
        .confirmationDialog(
            "Permanently delete this item?",
            isPresented: Binding(
                get: { pendingPermanentDelete != nil },
                set: { if !$0 { pendingPermanentDelete = nil } }),
            presenting: pendingPermanentDelete,
            actions: permanentDeleteActions,
            message: { _ in Text("This cannot be undone.") })
        // Origin's "Empty Trash?" dialog is deliberately NOT taken here: since
        // stage 2b Task 2 the one Empty Trash affordance (button + confirm)
        // lives on `TrashDisclosure`'s header below — a second spelling in the
        // rows view is the duplication that restructure removed.
        .alert("Trash error",
               isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pendingError ?? "")
        }
        .alert("Restored",
               isPresented: Binding(
                get: { restoreShortfall != nil },
                set: { if !$0 { restoreShortfall = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreShortfall ?? "")
        }
    }

    /// Extracted from the body's modifier chain: the inline closure tripped
    /// the type-checker's reasonable-time budget (the REAL SourceKit
    /// diagnostic class — see CLAUDE.md's build-flow notes).
    @ViewBuilder
    private func permanentDeleteActions(for entry: TrashEntry) -> some View {
        Button("Permanently Delete \(entry.displayTitle)", role: .destructive) {
            Task {
                do {
                    try await store.permanentlyDeleteTrashEntry(id: entry.id)
                } catch {
                    pendingError = error.localizedDescription
                }
                pendingPermanentDelete = nil
            }
        }
        Button("Cancel", role: .cancel) {
            pendingPermanentDelete = nil
        }
    }

    private func row(for entry: TrashEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayTitle)
                .font(.body)
            Text("Trashed \(daysAgo(entry.trashedAt)) · sweep in \(entry.daysRemaining) days")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Restore") {
                Task {
                    do {
                        let report = try await store.restoreTrashEntry(id: entry.id)
                        restoreShortfall = report.message
                    } catch {
                        pendingError = error.localizedDescription
                    }
                }
            }
            Button("Permanently Delete", role: .destructive) {
                pendingPermanentDelete = entry
            }
        }
    }

    private func daysAgo(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        let days = Int(elapsed / 86_400)
        if days < 1 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days) days ago"
    }
}

/// **The tree's foot** (shell-finish stage 2b Task 2). The segment strip's own
/// Trash entry died with the strip — nothing selects `.trash` any more — and
/// this is where a writer browses and restores what they deleted instead:
/// mounted below the tree, in every persona, collapsed by default, present
/// only while there is something in it.
///
/// Wraps `TrashView` UNCHANGED for its rows rather than forking a second
/// spelling of a trash row. Owns only what `TrashView` gave up: the header —
/// a label plus "Empty Trash", which has no window toolbar to live on down
/// here — and the expand/collapse flag, which the CALLER holds (not private
/// `@State` in this view) so a test can drive it directly instead of pressing
/// a `DisclosureGroup`'s AX triangle, the one interaction this codebase has no
/// proven idiom for.
struct TrashDisclosure: View {
    @Bindable var store: ProjectStore
    @Binding var isExpanded: Bool
    @State private var showingEmptyTrashConfirm = false
    @State private var pendingError: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            TrashView(store: store)
                .frame(maxHeight: 220)
        } label: {
            HStack {
                Label("Trash", systemImage: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // No `.disabled(store.trashEntries.isEmpty)` here (fix round
                // 1's Minor): both toggles mount this whole view only while
                // `!store.trashEntries.isEmpty`, so that condition is always
                // false for as long as this button exists to press — a dead
                // disable that reviewed as a leftover from `TrashView`'s old
                // toolbar button, which had no such mount gate of its own.
                Button("Empty Trash") {
                    showingEmptyTrashConfirm = true
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $showingEmptyTrashConfirm
        ) {
            Button("Empty Trash", role: .destructive) {
                Task {
                    do {
                        try await store.emptyTrash()
                    } catch {
                        pendingError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(store.trashEntries.count) items will be permanently deleted.")
        }
        .alert("Trash error",
               isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pendingError ?? "")
        }
    }
}

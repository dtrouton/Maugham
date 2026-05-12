import SwiftUI

struct TrashView: View {
    @Bindable var store: ProjectStore
    @State private var pendingPermanentDelete: TrashEntry?
    @State private var showingEmptyTrashConfirm = false
    @State private var pendingError: String?

    var body: some View {
        List(store.trashEntries) { entry in
            row(for: entry)
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Empty Trash") {
                    showingEmptyTrashConfirm = true
                }
                .disabled(store.trashEntries.isEmpty)
            }
        }
        .confirmationDialog(
            "Permanently delete this item?",
            isPresented: Binding(
                get: { pendingPermanentDelete != nil },
                set: { if !$0 { pendingPermanentDelete = nil } }),
            presenting: pendingPermanentDelete
        ) { entry in
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
        } message: { _ in
            Text("This cannot be undone.")
        }
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
                        try await store.restoreTrashEntry(id: entry.id)
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

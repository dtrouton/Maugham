import SwiftUI

/// The trashed-items list: title + "sweep in N days" + Restore / Permanently
/// Delete context menu, per row. **No "Empty Trash" here** — that moved to
/// `TrashDisclosure`'s header row (shell-finish stage 2b Task 2), the one
/// place left that has a toolbar to put it on. This view used to carry both;
/// it shrank to just the rows so `TrashDisclosure` could wrap it verbatim
/// rather than forking a second spelling of a trash row.
struct TrashView: View {
    @Bindable var store: ProjectStore
    /// **What a restore has to say, reported UPWARDS** (stage 2b final review's
    /// I1). RULING-42 says a restore that gives back less than was deleted must
    /// name the shortfall at the moment of the restore; this view cannot be the
    /// one that says it, because the restore that most needs saying is the one
    /// that empties the trash — `restoreTrashEntry` refreshes `trashEntries`
    /// before it returns, both toggles mount the disclosure only while that
    /// array is non-empty, and an alert whose host unmounts in the same pass
    /// never presents. So the message goes to `ProjectWindow.restoreOutcome`,
    /// the sink ⌘⌥Z already uses, which is mounted unconditionally: one sink,
    /// both restore paths.
    ///
    /// Defaulted so a mount that is not about restore outcomes keeps compiling.
    var onRestoreOutcome: (String) -> Void = { _ in }
    @State private var pendingPermanentDelete: TrashEntry?
    /// **Permanent-delete failures only, and that is not an oversight.**
    /// `permanentlyDeleteTrashEntry` throws BEFORE it re-lists, so the entry —
    /// and this view with it — is still there to carry the alert. The restore
    /// path is the one that can pull its own host down, so its error goes
    /// upwards with its report.
    @State private var pendingError: String?

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
        // No "Restored" alert here any more — see `onRestoreOutcome`. It was
        // mounted on a list that stops existing the moment the restored entry
        // was the trash's last, which is exactly the restore RULING-42 is about.
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
                // The closure is captured before the `await`: this row can be
                // gone by the time the store answers, so what reports the
                // outcome must not be reaching into this view's own state.
                let report = onRestoreOutcome
                Task { await Self.restore(entry: entry, store: store, report: report) }
            }
            Button("Permanently Delete", role: .destructive) {
                pendingPermanentDelete = entry
            }
        }
    }

    /// **What the row's Restore does**, as a function a test can call.
    ///
    /// A `static` taking the reporter rather than a closure inside the context
    /// menu, for `BinderTreeSections.addLink`'s reason one directory over: a
    /// `contextMenu`'s buttons are not reachable from a headless test, so a
    /// restore that dropped its report on the floor would be invisible to the
    /// suite — which is exactly how the shortfall came to be shown from a view
    /// that unmounts before it can show anything.
    ///
    /// **Both outcomes go to the same reporter.** A refusal is as much a thing
    /// the writer needs said at the moment of the restore as a shortfall is
    /// (RULING-40 beside RULING-42), and the throwing path can pull this row's
    /// host down just as the succeeding one does.
    static func restore(entry: TrashEntry, store: ProjectStore,
                        report: @escaping (String) -> Void) async {
        do {
            let outcome = try await store.restoreTrashEntry(id: entry.id)
            if let message = outcome.message { report(message) }
        } catch {
            report(error.localizedDescription)
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
    /// Passed straight through to the rows — see `TrashView.onRestoreOutcome`.
    /// This view cannot host that alert either: it unmounts with the rows.
    var onRestoreOutcome: (String) -> Void = { _ in }
    @State private var showingEmptyTrashConfirm = false
    @State private var pendingError: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            TrashView(store: store, onRestoreOutcome: onRestoreOutcome)
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

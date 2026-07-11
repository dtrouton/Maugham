import SwiftUI
import MaughamCore

/// Searchable list of palette cards that can receive a promoted inbox capture —
/// drives the inbox "Promote to Palette Card…" action. Mirrors
/// `PromoteTargetPickerSheet`'s shape. When the entry carried a `paletteSubject`
/// that matches an existing card title, that card is marked and sorted to the
/// top (preselect); when the subject matches no card, a "New Card '<subject>'…"
/// row mints one before promoting.
struct PalettePickerSheet: View {
    @Bindable var store: ProjectStore
    /// The capture's aimed subject (`InboxEntry.paletteSubject`), if any.
    let subject: String?
    /// Promote into the card with this id.
    let onPickCard: (String) -> Void
    /// Mint a card titled `<subject>` (kind `.other`), then promote into it.
    let onCreateCard: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Search cards…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List {
                    if let newTitle = newCardTitle {
                        Button {
                            onCreateCard(newTitle)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.secondary)
                                Text("New Card “\(newTitle)”…")
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(filteredCards()) { item in
                        Button {
                            onPickCard(item.id)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "paintpalette")
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                Spacer()
                                if isSubjectMatch(item) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.sidebar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationTitle("Promote to Palette Card…")
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    /// Cards matching the query, subject-matching card floated to the top.
    private func filteredCards() -> [ResearchItem] {
        let all = store.paletteCardItems()
        let matched: [ResearchItem]
        if query.isEmpty {
            matched = all
        } else {
            let lower = query.lowercased()
            matched = all.filter { $0.title.lowercased().contains(lower) }
        }
        return matched.sorted { a, b in
            isSubjectMatch(a) && !isSubjectMatch(b)
        }
    }

    private func isSubjectMatch(_ item: ResearchItem) -> Bool {
        guard let subject, !subject.isEmpty else { return false }
        return item.title.caseInsensitiveCompare(subject) == .orderedSame
    }

    /// The subject to offer as a new card: present, non-empty, and matching no
    /// existing card title (case-insensitive). nil otherwise (no orphan row).
    private var newCardTitle: String? {
        guard let subject, !subject.isEmpty else { return nil }
        let exists = store.paletteCardItems().contains {
            $0.title.caseInsensitiveCompare(subject) == .orderedSame
        }
        return exists ? nil : subject
    }
}

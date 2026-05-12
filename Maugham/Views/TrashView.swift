import SwiftUI

struct TrashView: View {
    @Bindable var store: ProjectStore

    var body: some View {
        List(store.trashEntries) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.body)
                Text("Trashed \(daysAgo(entry.trashedAt)) · sweep in \(entry.daysRemaining) days")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.sidebar)
    }

    private func daysAgo(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        let days = Int(elapsed / 86_400)
        if days < 1 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days) days ago"
    }
}

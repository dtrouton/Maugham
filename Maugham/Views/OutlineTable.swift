import SwiftUI
import MaughamCore

struct OutlineTable: View {
    let items: [StructureItem]
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?

    var body: some View {
        Table(items, selection: $selectedItemId) {
            TableColumn("Title") { item in
                Text(item.title)
            }
            TableColumn("Status") { item in
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor(item.status))
                        .frame(width: 6, height: 6)
                    Text(item.status ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TableColumn("Synopsis") { item in
                Text(item.synopsis ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            TableColumn("Words") { item in
                if let count = store.cachedWordCount(for: item.id) {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "revising": return .orange
        case "final":    return .green
        default:         return .secondary
        }
    }
}

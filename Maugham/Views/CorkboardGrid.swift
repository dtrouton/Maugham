import SwiftUI

struct CorkboardGrid: View {
    let items: [StructureItem]
    @Bindable var store: ProjectStore
    @Binding var selectedItemId: String?

    private let columns = [
        GridItem(.adaptive(minimum: 180), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    card(for: item)
                }
            }
            .padding(12)
        }
    }

    private func card(for item: StructureItem) -> some View {
        Button {
            selectedItemId = item.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Circle()
                        .fill(statusColor(item.status))
                        .frame(width: 8, height: 8)
                }
                if let synopsis = item.synopsis, !synopsis.isEmpty {
                    Text(synopsis)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No synopsis")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 4)
                HStack {
                    Spacer()
                    if let count = store.cachedWordCount(for: item.id) {
                        Text("\(count) words")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(12)
            .frame(minHeight: 140, maxHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selectedItemId == item.id ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: selectedItemId == item.id ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "revising": return .orange
        case "final":    return .green
        default:         return .secondary
        }
    }
}

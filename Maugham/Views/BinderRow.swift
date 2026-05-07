import SwiftUI

struct BinderRow: View {
    let item: StructureItem
    @Binding var renamingItemId: String?
    let onRename: (String, String) -> Void  // (id, newTitle)

    @State private var draftTitle: String = ""

    var body: some View {
        HStack(spacing: 6) {
            statusDot
            if renamingItemId == item.id {
                TextField("", text: $draftTitle, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .onAppear { draftTitle = item.title }
                    .onExitCommand { renamingItemId = nil }
            } else {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusDot: some View {
        if item.type == .document {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
        } else {
            Image(systemName: "folder")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch item.status {
        case "revising": return .orange
        case "final":    return .green
        default:         return .secondary
        }
    }

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != item.title {
            onRename(item.id, trimmed)
        }
        renamingItemId = nil
    }
}

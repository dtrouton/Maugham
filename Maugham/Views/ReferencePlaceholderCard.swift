import SwiftUI

/// Editor-pane placeholder shown when a project reference is selected.
struct ReferencePlaceholderCard: View {
    let piece: StructureItem
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(piece.title).font(.title2)
            Text("Linked project")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open in New Window", action: onOpen)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import SwiftUI
import AppKit

struct ReferencePieceInspector: View {
    @Bindable var store: ProjectStore
    let pieceId: String
    @State private var resolution: ReferenceResolution?

    var body: some View {
        if let piece = store.manifest.structure.first(where: { $0.id == pieceId }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(piece.title).font(.headline).textSelection(.enabled)
                    Text("Linked project").font(.caption).foregroundStyle(.secondary)
                    statusRow(piece: piece)
                    if let pathStr = piece.linkedProjectPath {
                        Text(pathStr)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .truncationMode(.middle)
                            .lineLimit(1)
                    }
                    actionButtons(piece: piece)
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .task(id: pieceId) {
                resolution = store.resolveReference(piece)
            }
        }
    }

    @ViewBuilder private func statusRow(piece: StructureItem) -> some View {
        HStack {
            switch resolution {
            case .resolved, .resolvedViaPathFallback:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Resolved").font(.callout)
            case .unresolved:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Unresolved").font(.callout)
            case .none:
                ProgressView()
            }
        }
    }

    @ViewBuilder private func actionButtons(piece: StructureItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Open in New Window") {
                openInWindow()
            }
            .buttonStyle(.borderedProminent)
            .disabled({
                if case .unresolved = resolution { return true } else { return false }
            }())

            Button("Reveal in Finder") {
                guard let pathStr = piece.linkedProjectPath else { return }
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: pathStr)])
            }

            Button("Re-link\u{2026}") {
                relink(piece: piece)
            }

            Button("Remove", role: .destructive) {
                Task { try? await store.deleteStructureItem(id: piece.id) }
            }
        }
    }

    private func openInWindow() {
        let url: URL
        switch resolution {
        case .resolved(let u): url = u
        case .resolvedViaPathFallback(let u): url = u
        default: return
        }
        NotificationCenter.default.post(
            name: .maughamOpenProject,
            object: nil,
            userInfo: ["url": url])
    }

    private func relink(piece: StructureItem) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let newURL = panel.url else { return }
            Task {
                try? await store.relinkReference(pieceId: piece.id, newURL: newURL)
                if let p = store.manifest.structure.first(where: { $0.id == piece.id }) {
                    resolution = store.resolveReference(p)
                }
            }
        }
    }
}

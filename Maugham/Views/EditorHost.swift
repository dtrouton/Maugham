import SwiftUI
import Foundation

/// Hosts the EditorSurface for a single selected document.
/// Picks the WritingMode by file extension. Reads the file on appear and
/// writes back on edit. When `selectedItemId` is nil, shows a placeholder.
struct EditorHost: View {
    @Bindable var store: ProjectStore
    let selectedItemId: String?
    /// Called whenever the document text changes (typing, paste, etc.).
    /// Lets the host (ProjectWindow) recompute live metrics for the inspector
    /// and goal indicator without re-reading from disk.
    var onTextChange: ((String) -> Void)? = nil
    @Environment(UserPreferences.self) private var userPreferences

    @State private var documentText: String = ""
    @State private var loadedItemId: String?

    var body: some View {
        Group {
            if let item = currentItem, item.type == .document, let path = item.path {
                EditorSurface(
                    text: Binding(
                        get: { documentText },
                        set: { newValue in
                            documentText = newValue
                            saveDocument(path: path, text: newValue)
                            onTextChange?(newValue)
                        }
                    ),
                    theme: userPreferences.theme,
                    typography: ProjectStore.effectiveTypography(
                        override: store.manifest.typography,
                        userDefault: userPreferences.typography),
                    mode: WritingModeFactory.mode(for: path),
                    typewriterScroll: userPreferences.typewriterScroll,
                    sentenceFocus: userPreferences.sentenceFocus,
                    paragraphFocus: userPreferences.paragraphFocus
                )
                .id(path)  // Force re-creation when switching documents
            } else if currentItem?.type == .group {
                placeholder("Select a document inside this group to edit.")
            } else {
                placeholder("Select a document.")
            }
        }
        .onChange(of: selectedItemId) { _, _ in loadDocumentIfNeeded() }
        .task { loadDocumentIfNeeded() }
    }

    private var currentItem: StructureItem? {
        guard let id = selectedItemId else { return nil }
        return findItem(id: id, in: store.manifest.structure)
    }

    private func loadDocumentIfNeeded() {
        guard let item = currentItem,
              item.type == .document,
              let path = item.path,
              loadedItemId != item.id else { return }
        let url = store.url.appendingPathComponent(path)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            documentText = text
        } else {
            documentText = ""
        }
        loadedItemId = item.id
        onTextChange?(documentText)
    }

    private func saveDocument(path: String, text: String) {
        let url = store.url.appendingPathComponent(path)
        try? text.data(using: .utf8)?.write(to: url, options: [.atomic])
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func findItem(id: String, in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let nested = findItem(id: id, in: children) {
                return nested
            }
        }
        return nil
    }
}

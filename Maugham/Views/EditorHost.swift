import SwiftUI
import Foundation

/// Hosts the EditorSurface for a single selected document.
/// Picks the WritingMode by file extension. Routes reads/writes through
/// the project's DocumentStore. The 750ms autosave debounce lives in
/// DocumentStore; EditorHost just calls scheduleSave on each keystroke.
struct EditorHost: View {
    @Bindable var store: ProjectStore
    @Bindable var documentStore: DocumentStore
    let selectedItemId: String?
    /// Called whenever the document text changes. ProjectWindow uses this
    /// to recompute live metrics for the inspector and goal indicator.
    var onTextChange: ((String) -> Void)? = nil
    @Environment(UserPreferences.self) private var userPreferences

    @State private var documentText: String = ""
    @State private var loadedItemId: String?

    var body: some View {
        Group {
            if let item = currentItem, item.type == .document, let path = item.path,
               loadedItemId == item.id {
                // Only render the editor surface AFTER the document text has
                // been loaded (loadedItemId == item.id). Otherwise, on chapter
                // switch, the surface would briefly be created with the old
                // chapter's text and the cursor restoration would clamp
                // against the wrong content length.
                EditorSurface(
                    text: Binding(
                        get: { documentText },
                        set: { newValue in
                            documentText = newValue
                            documentStore.currentDocumentText = newValue
                            documentStore.scheduleSave(
                                for: path, text: newValue)
                            // Update project word-count cache and idle
                            // session tracker.
                            let words = WritingModeFactory.mode(for: path)
                                .metrics(newValue).wordCount
                            store.recordWordCount(
                                forDocumentId: item.id, wordCount: words)
                            documentStore.recordSessionActivity(
                                documentId: item.id,
                                projectWordCount: store.projectWordCount)
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
                    paragraphFocus: userPreferences.paragraphFocus,
                    initialCursorLocation: documentStore.cursor(for: path),
                    onCursorChanged: { position in
                        documentStore.setCursor(position, for: path)
                    }
                )
                .id(path)
            } else if currentItem?.type == .group {
                placeholder("Select a document inside this group to edit.")
            } else if currentItem?.type == .document {
                placeholder("Loading…")
            } else {
                placeholder("Select a document.")
            }
        }
        .onChange(of: selectedItemId) { _, _ in
            Task { await loadDocumentIfNeeded() }
        }
        .onChange(of: documentStore.lastWrittenText) { _, newValue in
            // External "Use cloud" resolution updates lastWrittenText to the
            // external content; rebind the editor to match.
            if let item = currentItem,
               item.id == loadedItemId,
               documentText != newValue {
                documentText = newValue
                documentStore.currentDocumentText = newValue
                onTextChange?(newValue)
            }
        }
        .task { await loadDocumentIfNeeded() }
    }

    private var currentItem: StructureItem? {
        guard let id = selectedItemId else { return nil }
        return findItem(id: id, in: store.manifest.structure)
    }

    private func loadDocumentIfNeeded() async {
        guard let item = currentItem,
              item.type == .document,
              let path = item.path,
              loadedItemId != item.id else { return }
        do {
            let text = try await documentStore.openDocument(at: path)
            documentText = text
            documentStore.currentDocumentText = text
            loadedItemId = item.id
            onTextChange?(documentText)
        } catch {
            documentText = ""
            documentStore.currentDocumentText = ""
            loadedItemId = item.id
        }
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

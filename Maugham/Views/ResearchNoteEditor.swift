import SwiftUI
import MaughamCore
import AppKit

/// An editor surface for a research note (.document kind). Research notes
/// are not `Document` actors (no op-log, no paragraph IDs); they autosave via
/// `DocumentStore.scheduleFileSave` on the same 750ms cadence. Selecting a
/// different research item simply unmounts this view and remounts with the
/// new path, flushing the pending save.
struct ResearchNoteEditor: View {
    @Bindable var store: ProjectStore
    @Bindable var documentStore: DocumentStore
    let path: String
    let itemId: String
    let previewVisible: Bool
    @Environment(UserPreferences.self) private var userPreferences

    @State private var documentText: String = ""
    @State private var loadedPath: String?
    @State private var researchCursor: Int? = nil

    var body: some View {
        HSplitView {
            editorContent
            if previewVisible {
                ResearchNotePreviewPane(
                    notePath: path,
                    projectURL: store.url,
                    noteText: documentText)
            }
        }
        .task(id: path) { await loadDocument() }
    }

    @ViewBuilder
    private var editorContent: some View {
        Group {
            if loadedPath == path {
                EditorSurface(
                    text: Binding(
                        get: { documentText },
                        set: { newValue in
                            documentText = newValue
                            documentStore.scheduleFileSave(for: path, text: newValue)
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
                    initialCursorLocation: researchCursor,
                    onCursorChanged: { position in
                        researchCursor = position
                    },
                    showElementGutter: false,
                    imagePasteHandler: makeImagePasteHandler()
                )
                .id(path)
            } else {
                VStack {
                    Text("Loading…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func makeImagePasteHandler() -> ((NSImage) -> String?) {
        let projectURL = store.url
        let notePath = path
        return { image in
            do {
                return try ImagePasteHandler.saveAndReference(
                    image: image,
                    forNoteAt: notePath,
                    in: projectURL)
            } catch {
                print("Image paste failed:", error)
                return nil
            }
        }
    }

    private func loadDocument() async {
        guard loadedPath != path else { return }
        // Flush any pending file save before switching research notes.
        try? await documentStore.flushPendingSave()
        let url = store.url.appendingPathComponent(path)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        documentText = text
        researchCursor = nil
        loadedPath = path
    }
}

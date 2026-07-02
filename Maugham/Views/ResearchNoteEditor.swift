import SwiftUI
import MaughamCore
import AppKit
import os

/// Subsystem from the running bundle id so dev/stable logs separate without
/// hardcoding "com.maugham" (tripwire 13 spirit).
private let _researchNoteEditorLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "ResearchNoteEditor")

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
    /// Real EditorControl populated from userPreferences + project typography
    /// (ADR 0017). Research notes have no review posture — isReviewMode and
    /// lockEditing stay false. The coordinator observes this model so the
    /// appearance is correct even after the updateNSView pushes are removed.
    @State private var editorControl = EditorControl()

    private var effectiveTypography: TypographySettings {
        ProjectStore.effectiveTypography(
            override: store.manifest.typography,
            userDefault: userPreferences.typography)
    }

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
        // Mirror appearance into editorControl (ADR 0017). Review posture
        // (isReviewMode / lockEditing) stays false — research notes have none.
        .onChange(of: userPreferences.theme) { _, t in editorControl.theme = t }
        .onChange(of: effectiveTypography) { _, t in editorControl.typography = t }
        .onChange(of: userPreferences.typewriterScroll) { _, v in editorControl.typewriterScroll = v }
        .onChange(of: userPreferences.sentenceFocus) { _, v in editorControl.sentenceFocus = v }
        .onChange(of: userPreferences.paragraphFocus) { _, v in editorControl.paragraphFocus = v }
        .onAppear {
            // Seed all fields from current sources; onChange only fires on
            // transitions, not on first render.
            editorControl.theme = userPreferences.theme
            editorControl.typography = effectiveTypography
            editorControl.typewriterScroll = userPreferences.typewriterScroll
            editorControl.sentenceFocus = userPreferences.sentenceFocus
            editorControl.paragraphFocus = userPreferences.paragraphFocus
        }
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
                    typography: effectiveTypography,
                    mode: WritingModeFactory.mode(for: path),
                    typewriterScroll: userPreferences.typewriterScroll,
                    sentenceFocus: userPreferences.sentenceFocus,
                    paragraphFocus: userPreferences.paragraphFocus,
                    control: editorControl,
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
                _researchNoteEditorLog.error("Image paste failed: \(error, privacy: .public)")
                return nil
            }
        }
    }

    private func loadDocument() async {
        guard loadedPath != path else { return }
        // Flush any pending file save before switching research notes.
        try? await documentStore.flushPendingSave()
        let url = store.url.appendingPathComponent(path)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""  // adr-0018-ok: research-note read, not manuscript
        documentText = text
        researchCursor = nil
        loadedPath = path
    }
}

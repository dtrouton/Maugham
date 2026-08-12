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
    /// **Review's locked posture, threaded from `ResearchSubjectCentre.readOnly`**
    /// (shell-finish stage 3b Task 6) — forwarded straight into
    /// `EditorControl.lockEditing`. Research notes still have no `isReviewMode`
    /// toggle (there is no ⌘⌥⇧R here), but `lockEditing` is no longer always
    /// false: Denver's ruling is that Review adjudicates and does not edit
    /// research from its own columns, and `EditorEditPolicy.allowsTextMutation`
    /// already treats `lockEditing` as the hard floor selection/scroll survive
    /// but typing does not, which is the "reference view" shape this posture
    /// wants rather than an unmounted editor.
    let lockEditing: Bool
    @Environment(UserPreferences.self) private var userPreferences

    @State private var documentText: String = ""
    @State private var loadedPath: String?
    /// Why this note's file could not be read, when it could not. Non-nil
    /// keeps the editor unmounted: a blank editor over an unreadable file is
    /// one keystroke from replacing it (RULING-7).
    @State private var loadFailure: String?
    @State private var researchCursor: Int? = nil
    /// Real EditorControl populated from userPreferences + project typography
    /// (ADR 0017). Research notes have no `isReviewMode` toggle, so that field
    /// stays false; `lockEditing` mirrors the `lockEditing` parameter above.
    /// The coordinator observes this model so the appearance (and the
    /// membrane) is correct even after the updateNSView pushes are removed.
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
        // Mirror appearance into editorControl (ADR 0017). isReviewMode stays
        // false — research notes have no ⌘⌥⇧R toggle — but lockEditing now
        // carries Review's posture, mirrored below like every other field here.
        .onChange(of: userPreferences.theme) { _, t in editorControl.theme = t }
        .onChange(of: effectiveTypography) { _, t in editorControl.typography = t }
        .onChange(of: userPreferences.typewriterScroll) { _, v in editorControl.typewriterScroll = v }
        .onChange(of: userPreferences.sentenceFocus) { _, v in editorControl.sentenceFocus = v }
        .onChange(of: userPreferences.paragraphFocus) { _, v in editorControl.paragraphFocus = v }
        .onChange(of: lockEditing) { _, v in editorControl.lockEditing = v }
        .onAppear {
            // Seed all fields from current sources; onChange only fires on
            // transitions, not on first render.
            editorControl.theme = userPreferences.theme
            editorControl.typography = effectiveTypography
            editorControl.typewriterScroll = userPreferences.typewriterScroll
            editorControl.sentenceFocus = userPreferences.sentenceFocus
            editorControl.paragraphFocus = userPreferences.paragraphFocus
            editorControl.lockEditing = lockEditing
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        Group {
            if let loadFailure {
                // No editor at all — mounting one would put a blank surface
                // over bytes we could not read, and its binding setter saves
                // on the first keystroke (RULING-7).
                ContentUnavailableView {
                    Label("This note can’t be read", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Maugham couldn’t read \(path). It has not been changed.\n\n\(loadFailure)")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadedPath == path {
                EditorSurface(
                    text: Binding(
                        get: { documentText },
                        set: { newValue in
                            documentText = newValue
                            documentStore.scheduleFileSave(for: path, text: newValue)
                        }
                    ),
                    configuration: EditorSurfaceConfiguration(
                        presentation: .init(
                            theme: userPreferences.theme,
                            typography: effectiveTypography,
                            mode: WritingModeFactory.mode(for: path),
                            typewriterScroll: userPreferences.typewriterScroll,
                            sentenceFocus: userPreferences.sentenceFocus,
                            paragraphFocus: userPreferences.paragraphFocus,
                            showElementGutter: false),
                        control: editorControl,
                        callbacks: .init(
                            initialCursorLocation: researchCursor,
                            onCursorChanged: { position in
                                researchCursor = position
                            }),
                        paragraphProviders: .init(
                            // **Gated on the lock, not just unconditionally
                            // wired** (shell-finish stage 3b Task 6 review
                            // finding). `EditorSurface.paste(_:)` calls this
                            // handler SYNCHRONOUSLY and BEFORE `insertText` —
                            // `ImagePasteHandler.saveAndReference` writes the
                            // PNG to `<slug>_assets/` on disk first, and only
                            // then does the (locked) `shouldChangeTextIn`
                            // refuse the markdown ref. A locked editor with an
                            // active handler wrote an orphaned file straight
                            // through the lock — the write isn't text
                            // mutation, so nothing here ever gated it. Nil
                            // also flips `readablePasteboardTypes`'
                            // `coordinator?.imagePasteHandler != nil` check,
                            // so Paste's image affordance itself goes away in
                            // Review rather than accepting a paste that then
                            // silently drops the ref.
                            imagePasteHandler: lockEditing ? nil : makeImagePasteHandler()))
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
        switch ResearchNoteLoad.read(url) {
        case .text(let text):
            documentText = text
            loadFailure = nil
        case .unreadable(let reason):
            documentText = ""
            loadFailure = reason
        }
        researchCursor = nil
        loadedPath = path
    }
}

/// Reading a research note's file for editing. A read that FAILS is not an
/// empty note (RULING-7: unreadable is never presented as empty) — and the
/// distinction is load-bearing here rather than cosmetic, because the editor's
/// binding setter schedules an atomic whole-file save on the first keystroke,
/// so a note shown as blank is one character away from being replaced by that
/// blank. Research notes have no op log to recover from.
enum ResearchNoteLoad: Equatable {
    case text(String)
    case unreadable(String)

    /// A file that is not there reads as empty, as it always has: there is
    /// nothing at risk, and a note's file is written the moment it is created.
    /// A file that IS there and cannot be decoded is reported as what it is.
    static func read(_ url: URL) -> ResearchNoteLoad {
        do {
            return .text(try String(contentsOf: url, encoding: .utf8))  // adr-0018-ok: research-note read, not manuscript
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else { return .text("") }
            return .unreadable(error.localizedDescription)
        }
    }
}

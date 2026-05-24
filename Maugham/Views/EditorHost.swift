import SwiftUI
import Foundation

/// Hosts the EditorSurface for a single selected document.
/// Picks the WritingMode by file extension. As of Stage 2 of the
/// document-first-class refactor (T10), the editor binds to a per-document
/// `Document` actor that owns its own op log, pending buffer, burst
/// scheduler, autosave, and conflict detection. After T11 those properties
/// no longer exist on DocumentStore; this view binds directly to the
/// owning Document.
///
/// The binding shape is `Binding(get: { doc.displayText }, set: { doc.setFullText($0) })`.
/// Document.setFullText writes `displayText` exactly once at the end, which
/// is what keeps the milestone-1e binding-loop race closed (harness test 8).
struct EditorHost: View {
    @Bindable var store: ProjectStore
    @Bindable var documentStore: DocumentStore
    let selectedItemId: String?
    /// Called whenever the document text changes. ProjectWindow uses this
    /// to recompute live metrics for the inspector and goal indicator.
    var onTextChange: ((String) -> Void)? = nil
    /// Called when the cursor's screenplay element changes. Delivers the gutter
    /// abbreviation ("CHAR", "SCENE", "DLG", etc.) or nil in prose mode.
    /// Default is a no-op; only the manuscript call site in ProjectWindow
    /// supplies this. The research-note call site omits it.
    var onElementChanged: (String?) -> Void = { _ in }
    var wikiLinkResolver: ((String) -> Bool)? = nil
    var wikiLinkClickResolver: ((String) -> String?)? = nil
    @Environment(UserPreferences.self) private var userPreferences

    /// The currently-bound Document. Owns the editor's text state and the
    /// op-log machinery for the open manuscript.
    @State private var document: Document?
    /// item.id of the currently-loaded document. Distinct from the registry
    /// key because the registry is path-keyed but selection state is item-id
    /// keyed.
    @State private var loadedItemId: String?
    /// Manuscript-relative path of the currently-loaded document. Tracked
    /// alongside `loadedItemId` so `loadDocumentIfNeeded` can unregister the
    /// previously-bound Document from the DocumentStore registry when the
    /// editor switches away.
    @State private var priorLoadedPath: String?

    /// Session id stable for the lifetime of this app launch. Stamped onto
    /// every `typing_burst` Op so multi-window edits can be merged across
    /// instances. Computed once via a lazy static.
    private static let sessionId: String = UUID().uuidString

    /// Device id — best-effort stable across launches. `hostName` is fine
    /// for single-user / single-Mac use; multi-device sync via iCloud will
    /// rely on the same value per machine.
    private static let deviceId: String = {
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? "unknown-host" : name
    }()

    var body: some View {
        Group {
            if let item = currentItem, item.type == .document, let path = item.path,
               let doc = document, loadedItemId == item.id {
                EditorSurface(
                    // The setter writes via Document.setFullText, then routes the
                    // project-level side-effects through DocumentStore. See
                    // recordEditorTextWrite's doc-comment for why both steps are
                    // load-bearing.
                    text: Binding(
                        get: { doc.displayText },
                        set: { newText in
                            doc.setFullText(newText)
                            documentStore.recordEditorTextWrite(
                                documentId: doc.docId,
                                newText: newText,
                                mode: WritingModeFactory.mode(for: path),
                                store: store)
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
                    initialCursorLocation: doc.cursorLocation,
                    onCursorChanged: { doc.cursorLocation = $0 },
                    onElementChanged: onElementChanged,
                    wikiLinkResolver: wikiLinkResolver,
                    wikiLinkClickResolver: wikiLinkClickResolver,
                    showElementGutter: store.manifest.showElementGutter ?? true,
                    paragraphRangeProvider: { paragraphId in
                        doc.displayRange(forParagraphId: paragraphId)
                    },
                    paragraphLocator: { location in
                        guard let pid = doc.paragraphId(at: location),
                              let range = doc.displayRange(forParagraphId: pid)
                        else { return nil }
                        return (paragraphId: pid,
                                offsetWithinParagraph: location - range.location)
                    },
                    checkboxToggleHandler: { paragraphId, offset, kind in
                        // Mirror wiki-link click wiring: the flip goes through
                        // Document.setParagraph, the standard mutation path.
                        // Tripwire #7: this is NOT applyExternalText.
                        guard let para = doc.paragraph(id: paragraphId) else { return }
                        let flipped: String
                        switch kind {
                        case .markdown:
                            flipped = MarkdownCheckboxScanner.flipBracket(
                                in: para, atUTF16Offset: offset)
                        case .fountain:
                            flipped = FountainBoneyardScanner.flipTodoDone(
                                in: para, atUTF16Offset: offset)
                        }
                        guard flipped != para else { return }
                        doc.setParagraph(id: paragraphId, text: flipped)
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
        .onChange(of: document?.displayText) { _, newValue in
            // Mirror text changes out to ProjectWindow for inspector metrics
            // + goal-indicator updates. Op-log recording, paragraph diffing,
            // and autosave all happen inside Document.setFullText now.
            if let text = newValue { onTextChange?(text) }
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
        // Tear down any prior document before loading the new one. close()
        // flushes the pending typing-burst + pending autosave (T6) so a
        // fast-fingered doc switch never drops unflushed paragraph changes.
        if let prior = document, let priorPath = priorLoadedPath {
            await prior.close()
            documentStore.unregister(path: priorPath)
        }
        do {
            let doc = try await Document.load(
                url: store.url.appendingPathComponent(path),
                device: Self.deviceId,
                session: Self.sessionId,
                presenter: documentStore.presenter)
            documentStore.register(document: doc, for: path)
            document = doc
            loadedItemId = item.id
            priorLoadedPath = path
            onTextChange?(doc.displayText)
        } catch {
            document = nil
            loadedItemId = item.id
            priorLoadedPath = nil
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

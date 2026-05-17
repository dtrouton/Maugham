import SwiftUI
import Foundation

/// Hosts the EditorSurface for a single selected document.
/// Picks the WritingMode by file extension. Routes reads/writes through
/// the project's DocumentStore. The 750ms autosave debounce lives in
/// DocumentStore; EditorHost just calls scheduleSave on each keystroke.
///
/// Op-log integration (milestone document-operation-log, T18):
/// On document load, the stored markdown (ID-tagged) is stripped via
/// `RenderFilter.stripComments` for display. On each text change we
/// re-attach IDs via `RenderFilter.restoreComments`, diff paragraphs
/// against the prior stored form, emit `recordParagraphChange` per
/// changed paragraph, and schedule the ID-tagged form for autosave.
/// On document switch the previous doc's pending typing-burst is
/// flushed before binding the op-log context to the new doc.
struct EditorHost: View {
    @Bindable var store: ProjectStore
    @Bindable var documentStore: DocumentStore
    let selectedItemId: String?
    /// Called whenever the document text changes. ProjectWindow uses this
    /// to recompute live metrics for the inspector and goal indicator.
    var onTextChange: ((String) -> Void)? = nil
    var wikiLinkResolver: ((String) -> Bool)? = nil
    var wikiLinkClickResolver: ((String) -> String?)? = nil
    @Environment(UserPreferences.self) private var userPreferences

    /// Display-form text (no `<!-- ¶id -->` comments) shown in the editor.
    @State private var documentText: String = ""
    /// Most recent stored-form markdown (with `<!-- ¶id -->` comments).
    /// Updated on load and after every save. Used as the prior side for
    /// `RenderFilter.restoreComments` and paragraph-change diffing.
    @State private var priorStoredMarkdown: String = ""
    @State private var loadedItemId: String?

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
                            // Re-attach `<!-- ¶id -->` markers by matching
                            // the edited display form against the prior
                            // stored form. New paragraphs receive freshly
                            // minted IDs; reordered ones keep theirs;
                            // similar ones (shingle ≥ 0.6) are recognized
                            // as edits, not insertions.
                            let newStored = RenderFilter.restoreComments(
                                stored: priorStoredMarkdown,
                                displayEdited: newValue)
                            // Diff paragraphs by id and emit one
                            // recordParagraphChange per changed/inserted
                            // paragraph. The PendingBuffer dedupes by
                            // paragraph id, so repeated keystrokes inside
                            // the same paragraph collapse to one entry
                            // (prior captured the first time it appeared).
                            let priorParsed = ParagraphParser.parse(
                                priorStoredMarkdown)
                            let nextParsed = ParagraphParser.parse(newStored)
                            var priorById: [String: String] = [:]
                            for p in priorParsed {
                                if let id = p.id { priorById[id] = p.text }
                            }
                            for p in nextParsed {
                                guard let id = p.id else { continue }
                                let prior = priorById[id]
                                if prior != p.text {
                                    documentStore.recordParagraphChange(
                                        paragraphId: id,
                                        prior: prior,
                                        next: p.text)
                                }
                            }
                            // The bytes that hit disk are the ID-tagged
                            // form. Conflict detection compares
                            // currentDocumentText against disk bytes, so
                            // it must also operate on the stored form.
                            priorStoredMarkdown = newStored
                            documentStore.currentDocumentText = newStored
                            documentStore.scheduleSave(
                                for: path, text: newStored)
                            // Update project word-count cache and idle
                            // session tracker. Word counts are computed
                            // against the display form (what the user
                            // actually wrote, no syntactic noise).
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
                    },
                    wikiLinkResolver: wikiLinkResolver,
                    wikiLinkClickResolver: wikiLinkClickResolver,
                    showElementGutter: store.manifest.showElementGutter ?? true
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
            // external content; rebind the editor to match. The external
            // bytes are in stored form (with `<!-- ¶id -->` comments) — so
            // we strip for display and update priorStoredMarkdown so the
            // next save round-trips cleanly without minting fresh IDs for
            // every paragraph.
            if let item = currentItem,
               item.id == loadedItemId,
               documentText != newValue {
                let displayed = RenderFilter.stripComments(newValue)
                documentText = displayed
                priorStoredMarkdown = newValue
                documentStore.currentDocumentText = newValue
                onTextChange?(displayed)
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
        // T17 invariant: flush the previously-bound doc's pending
        // typing-burst BEFORE re-pointing the op-log context at the new
        // doc. openDocument also flushes the pending save, but the burst
        // is a separate concern living in the BurstScheduler — without
        // this flush a fast-fingered doc switch would silently drop
        // unflushed paragraph changes.
        try? await documentStore.flushBurstNow()
        do {
            let stored = try await documentStore.openDocument(at: path)
            let displayed = RenderFilter.stripComments(stored)
            priorStoredMarkdown = stored
            documentText = displayed
            // Conflict detection compares this against on-disk bytes,
            // which are the ID-tagged form. Match.
            documentStore.currentDocumentText = stored
            loadedItemId = item.id
            documentStore.beginOpLogContext(
                docId: item.id,
                device: Self.deviceId,
                session: Self.sessionId)
            onTextChange?(displayed)
        } catch {
            priorStoredMarkdown = ""
            documentText = ""
            documentStore.currentDocumentText = ""
            loadedItemId = item.id
            documentStore.beginOpLogContext(
                docId: item.id,
                device: Self.deviceId,
                session: Self.sessionId)
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

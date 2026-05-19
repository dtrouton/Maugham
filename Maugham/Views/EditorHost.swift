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
                    // Pass-through binding. Heavy work (RenderFilter, op-log
                    // recording, autosave scheduling) lives in
                    // `.onChange(of: documentText)` below — NOT inside a
                    // custom Binding(get:, set:). The previous shape did the
                    // heavy work synchronously inside the binding setter,
                    // which interleaved several @Observable writes
                    // (currentDocumentText, recordWordCount, etc.) with
                    // SwiftUI's body re-eval pass. SwiftUI ended up reading
                    // documentText from a stale view-tree snapshot during
                    // one of those re-evals and firing updateNSView with
                    // text=N-1 while textView was already at N; the resulting
                    // applyExternalText clobbered textView back to N-1, the
                    // cursor clamped to N-1, and the user lost one cursor
                    // position per keystroke. Routing through $documentText
                    // lets SwiftUI's state propagation settle before any
                    // downstream work runs, so updateNSView always sees a
                    // consistent (textView, text) pair.
                    text: $documentText,
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
        .onChange(of: documentText) { _, newValue in
            // Heavy work that used to live in a custom Binding setter. Running
            // here, AFTER SwiftUI has finished propagating the documentText
            // write through the view tree, prevents the "updateNSView reads
            // stale documentText" race that produced backward cursor jumps
            // mid-typing.
            //
            // Guard 1: only run when a document is fully loaded — otherwise
            // the initial documentText assignment from loadDocumentIfNeeded
            // would trigger a spurious autosave of unchanged content.
            //
            // Guard 2: skip if the restoreComments round-trip produces the
            // same stored form we already have (newStored == priorStoredMarkdown).
            // This makes initial load + external re-sync echoes inert without
            // a separate flag.
            guard let item = currentItem,
                  item.id == loadedItemId,
                  let path = item.path else { return }
            let newStored = RenderFilter.restoreComments(
                stored: priorStoredMarkdown, displayEdited: newValue)
            guard newStored != priorStoredMarkdown else {
                // Display changed but stored form is identical — load echo
                // or whitespace-only change the parser trims. Don't fire
                // downstream effects.
                return
            }
            // Diff paragraphs by id and emit one recordParagraphChange per
            // changed paragraph. PendingBuffer dedupes by paragraph_id, so
            // repeated keystrokes inside the same paragraph collapse to one
            // entry (prior captured the first time it appeared).
            let priorParsed = ParagraphParser.parse(priorStoredMarkdown)
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
                        paragraphId: id, prior: prior, next: p.text)
                }
            }
            // Update the bookkeeping that the .onChange(of: lastWrittenText)
            // gate and DocumentStore's conflict detection rely on.
            priorStoredMarkdown = newStored
            documentStore.currentDocumentText = newStored
            documentStore.scheduleSave(for: path, text: newStored)
            // Word count + idle session tracker.
            let words = WritingModeFactory.mode(for: path)
                .metrics(newValue).wordCount
            store.recordWordCount(
                forDocumentId: item.id, wordCount: words)
            documentStore.recordSessionActivity(
                documentId: item.id,
                projectWordCount: store.projectWordCount)
            onTextChange?(newValue)
        }
        .onChange(of: documentStore.lastWrittenText) { _, newValue in
            // Re-sync the editor view only when this update is genuinely
            // external — Use-cloud resolution, iCloud sync from another
            // Mac, or a silent reload after no local edits. After our own
            // save, lastWrittenText echoes priorStoredMarkdown; re-syncing
            // would strip whitespace via stripComments(restoreComments(...))
            // and clobber any trailing space the user just typed, dragging
            // the cursor backward by one. The previous gate compared
            // documentText (display form) against newValue (stored form) —
            // those representations are always different, so the body ran
            // on every autosave, not just on external resolutions.
            if let item = currentItem,
               item.id == loadedItemId,
               priorStoredMarkdown != newValue {
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

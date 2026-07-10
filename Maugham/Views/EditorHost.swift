import SwiftUI
import MaughamCore
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
    /// Called with precomputed `EditorMetrics` for the inspector + goal
    /// indicator. The EditorCoordinator computes these from the keystroke's
    /// own parse (zero extra parsing) and delivers them on its own debounced
    /// trailing edge while typing, immediately on attach. This replaces the
    /// old per-keystroke text mirror + EditorHost-side debounce (spec §7).
    var onMetricsChanged: ((EditorMetrics) -> Void)? = nil
    /// Called when the cursor's screenplay element changes. Delivers the gutter
    /// abbreviation ("CHAR", "SCENE", "DLG", etc.) or nil in prose mode.
    /// Default is a no-op; only the manuscript call site in ProjectWindow
    /// supplies this. The research-note call site omits it.
    var onElementChanged: (String?) -> Void = { _ in }
    var wikiLinkResolver: ((String) -> Bool)? = nil
    var wikiLinkClickResolver: ((String) -> String?)? = nil
    /// Control-plane model owned by ProjectWindow, threaded ONE-WAY to the
    /// EditorSurface/coordinator (ADR 0017).
    var control: EditorControl
    @Environment(UserPreferences.self) private var userPreferences
    /// The window's undo manager — the one ⌘Z reaches. Passed into every
    /// accept/revert so the Document registers its undo action against it
    /// (and clears the stale native typing-undo stack that a buffer replace
    /// would otherwise leave dangling — the ⌘Z EXC_BAD_ACCESS class).
    @Environment(\.undoManager) private var undoManager

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
    private static let deviceId: String = MacDeviceID.current

    var body: some View {
        // Snapshot the environment undo manager before the EditorSurface init
        // list — @Environment values can't be captured directly by the
        // escaping accept closures built there.
        let um = undoManager
        return Group {
            // `priorLoadedPath == path` gates out the husk window: a rename of
            // the OPEN document keeps its item id but moves its file, and the
            // typed mover (DocumentStore.relocate/relocateUserContent) closes
            // the open Document before the move (tripwire 14). Until
            // loadDocumentIfNeeded re-loads from the new path, `document` is a
            // closed husk whose setFullText rejects mutations — binding it
            // would silently eat keystrokes. Show "Loading…" instead.
            if let item = currentItem, item.type == .document, let path = item.path,
               let doc = document, loadedItemId == item.id, priorLoadedPath == path {
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
                    control: control,
                    initialCursorLocation: doc.cursorLocation,
                    onCursorChanged: { offset in
                        doc.cursorLocation = offset
                        // Stash the latest cursor position so Document's V2
                        // task-anchor alignment in setFullText can read it
                        // as the pre-edit cursor input.
                        doc.recordCursorAt(offset)
                    },
                    onPostEditCursor: { doc.recordPostEditCursor($0) },
                    onElementChanged: onElementChanged,
                    onMetricsChanged: onMetricsChanged,
                    wikiLinkResolver: wikiLinkResolver,
                    wikiLinkClickResolver: wikiLinkClickResolver,
                    showElementGutter: store.manifest.showElementGutter ?? true,
                    // Scope this window's script posts to its project so another
                    // window's screenplay re-parse can't relayout this editor or
                    // clobber its scene navigator (Channel A, ADR 0017 addendum).
                    scriptOriginProjectId: ProjectIdentifier.id(for: store.url),
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
                        // ⌘Z: a checkbox flip is text-is-state (no task op), so
                        // undo is a guarded flip-back. `InlineToggleUndo` sets the
                        // undo-coherent flag so the buffer replace this
                        // setParagraph drives doesn't wipe the fresh registration.
                        InlineToggleUndo.perform(
                            on: doc, paragraphId: paragraphId,
                            prior: para, flipped: flipped, undoManager: um)
                    },
                    paragraphRangeAtLocation: { location in
                        doc.paragraphRange(at: location)
                    },
                    createAnnotationHandler: { kind, paragraphId, span, body, suggestedText in
                        // Annotation creation is an op-log append, not a text
                        // mutation — it doesn't write the editor binding, so the
                        // applyExternalText tripwires (6/7) don't apply. The
                        // AnnotationsPane re-renders automatically off the
                        // Document's `annotationsVersion` bump (invalidated
                        // inside addAnnotation). The handler is async so the
                        // coordinator can await this append, then re-pull the
                        // annotation set and refresh the crafted marks — so a
                        // just-created annotation renders immediately in review
                        // mode without a toggle.
                        try? await doc.addReviewerAnnotation(
                            kind: kind,
                            paragraphId: paragraphId,
                            span: span,
                            body: body,
                            suggestedText: suggestedText,
                            authorName: userPreferences.collaboratorDisplayName)
                    },
                    reviewParagraphTextProvider: { pid in
                        doc.paragraph(id: pid).map {
                            RenderFilter.stripTaskAnchorsInline($0)
                        }
                    },
                    reviewParagraphRangeProvider: { pid in
                        doc.displayRange(forParagraphId: pid)
                    },
                    // Pull-on-entry: the coordinator invokes this ONLY when
                    // entering review (membrane toggle OR fresh launch), so it
                    // derives the current open annotations on demand without the
                    // lagged `reviewAnnotations` push. NOT gated on isReviewMode —
                    // gating would defeat the purpose (the first toggle's entry
                    // happens while isReviewMode is still flipping). It's never
                    // called during authoring, so no per-keystroke derivation.
                    reviewAnnotationsProvider: {
                        doc.annotations(
                            filter: AnnotationFilter(statuses: [.open]))
                    },
                    // Local reviewer name — gates Edit/Delete on margin cards.
                    reviewLocalAuthorName: { userPreferences.collaboratorDisplayName },
                    // Interactive margin-card actions (Part 1). Each is an op-log
                    // append routed through Document — NOT a text-binding write, so
                    // the applyExternalText tripwires (6/7) don't apply. The
                    // coordinator refreshes its marks from the provider after each.
                    reviewAcceptHandler: { id in
                        try? await doc.acceptAnnotation(id: id, undoManager: um)
                    },
                    reviewRejectHandler: { id in
                        // The card has no reasoning field; the reason-capture sheet
                        // stays in the AnnotationsPane. A card-reject records no
                        // reason (a follow-up could surface the sheet from here).
                        try? await doc.rejectAnnotation(id: id, undoManager: um)
                    },
                    reviewArchiveHandler: { id in
                        try? await doc.archiveAnnotation(id: id, undoManager: um)
                    },
                    reviewReplyHandler: { id, reply in
                        try? await doc.acceptAnnotation(id: id, userResponse: reply, undoManager: um)
                    },
                    reviewEditHandler: { id, newBody, newSuggested in
                        try? await doc.editReviewerAnnotation(
                            id: id,
                            newBody: newBody,
                            newSuggestedText: newSuggested,
                            authorName: userPreferences.collaboratorDisplayName,
                            undoManager: um)
                    },
                    reviewWithdrawHandler: { id in
                        try? await doc.withdrawReviewerAnnotation(
                            id: id,
                            authorName: userPreferences.collaboratorDisplayName,
                            undoManager: um)
                    },
                    consumeUndoCoherentApplyFlag: { doc.consumeUndoCoherentApplyFlag() }
                )
                .id(path)
                // Crafted review render (Component F): the open-annotation set now
                // flows through the control model (ADR 0017), not a per-prop push.
                // EditorHost mirrors the Document's open set into
                // `control.reviewAnnotations` whenever it changes; the coordinator
                // observes the model and reconciles via `applyControl` →
                // `setReviewAnnotations`. Reading `doc.annotationsVersion` /
                // `control.isReviewMode` in these closures is safe (unlike reading
                // `displayText`): it never feeds the text binding, so the
                // cursor-race triad (tripwires 6/7) stays closed. An AnnotationsPane
                // edit bumps `annotationsVersion` on the SAME registered Document
                // instance, so the first `.onChange` carries it through.
                .onChange(of: doc.annotationsVersion) { _, _ in
                    control.reviewAnnotations = control.isReviewMode
                        ? doc.annotations(filter: AnnotationFilter(statuses: [.open]))
                        : []
                }
                .onChange(of: control.isReviewMode) { _, nowReview in
                    control.reviewAnnotations = nowReview
                        ? doc.annotations(filter: AnnotationFilter(statuses: [.open]))
                        : []
                }
                .onAppear {
                    control.reviewAnnotations = control.isReviewMode
                        ? doc.annotations(filter: AnnotationFilter(statuses: [.open]))
                        : []
                }
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
        // Re-load when the SELECTED item's file moves under us (rename of the
        // open doc — near-inevitable for a brand-new chapter, whose creation
        // drops the binder row straight into rename mode — or a sibling
        // reorder renumbering paths). The typed mover closed the open
        // Document at the old path; without this trigger the editor stayed
        // bound to that closed husk and every keystroke was silently dropped
        // ("can't type until I switch away and back"). Reads only manifest
        // state — no editor observable state (tripwire 6 stays closed).
        .onChange(of: currentItem?.path) { _, _ in
            Task { await loadDocumentIfNeeded() }
        }
        .onDisappear {
            // EditorHost's `.onDisappear` fires only on document-abandonment
            // paths: leaving the manuscript/scenes/find segment (a fresh
            // EditorHost re-mounts and reloads on return) and window close
            // (SwiftUI never dismantles the zombie scene — GraphHost.sharedGraph
            // retains it — but `.onDisappear` still fires). In BOTH the Document
            // is being abandoned, so scorch it here rather than leaking its
            // paragraphs + op-log mirror into the retained scene graph.
            //
            // EditorHost is the sole owner of Document.close(): DocumentStore.close()
            // (called by ProjectWindow) flushes the session/UI-state/presenter but
            // does NOT close registered Documents. `Document.close()` is idempotent
            // anyway (flushBurstNow no-ops on empty pending, autosave flush no-ops,
            // pending.clear is idempotent), so this can't race the doc-switch close
            // in `loadDocumentIfNeeded`. `Task { … }` captures `doc` by value, so
            // nil-ing @State immediately is safe.
            //
            // No isLive guard (EditorHost holds no window ref, and tripwire 6
            // forbids adding observable state): instead we also nil loadedItemId
            // and priorLoadedPath, so if this fires spuriously and the view
            // re-appears, `.task`/`.onChange(of: selectedItemId)` see
            // loadedItemId != item.id and reload — no stuck "Loading…".
            if let doc = document, let path = priorLoadedPath {
                Task { await doc.close() }
                documentStore.unregister(path: path)
            }
            document = nil
            loadedItemId = nil
            priorLoadedPath = nil
        }
        // The inspector/goal-indicator metrics mirror now lives entirely in the
        // EditorCoordinator (spec §7): it delivers precomputed `EditorMetrics`
        // via `onMetricsChanged` on its own debounced trailing edge while typing
        // and immediately on attach. The former `.onChange(of: displayText)`
        // mirror + `metricsMirrorTask` here is deleted — re-introducing any
        // read of `document.displayText` into this view's body would reopen the
        // parallel-observable-state cursor races (tripwires 6 and 7).
        .task { await loadDocumentIfNeeded() }
    }

    private var currentItem: StructureItem? {
        guard let id = selectedItemId else { return nil }
        return TreeWalk.find(id: id, in: store.manifest.structure)
    }

    /// Whether the bound document must be (re)loaded for the given item.
    /// True when nothing (or a different item) is loaded — the original
    /// selection-change case — AND when the SAME item's on-disk path changed
    /// (rename/tidy moved the file; the typed mover closed the open Document,
    /// so the husk must be replaced by a fresh load from the new path). Also
    /// true when a prior load failed (`loadedPath` nil), so the next trigger
    /// retries instead of sticking on "Loading…". Static + pure for
    /// `EditorHostReloadPredicateTests`.
    static func needsReload(
        itemId: String, path: String,
        loadedItemId: String?, loadedPath: String?
    ) -> Bool {
        loadedItemId != itemId || loadedPath != path
    }

    private func loadDocumentIfNeeded() async {
        guard let item = currentItem,
              item.type == .document,
              let path = item.path,
              Self.needsReload(
                  itemId: item.id, path: path,
                  loadedItemId: loadedItemId, loadedPath: priorLoadedPath)
        else { return }
        // The outgoing doc's pending metrics mirror is cancelled inside the
        // coordinator's own teardown/attach now (a doc switch makes a fresh
        // EditorSurface via `.id(path)`, whose coordinator's `attach` cancels
        // any stranded debounced metrics post and delivers the new doc's
        // metrics immediately). No EditorHost-side cancel is needed.
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
            // Metrics for the freshly-loaded doc are delivered by the new
            // EditorSurface's coordinator `attach` (immediate, non-debounced) —
            // no EditorHost-side mirror call.
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

}

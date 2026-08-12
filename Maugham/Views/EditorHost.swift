import SwiftUI
import MaughamCore
import Foundation

/// Which load of `EditorHost`'s `Document` is the current one.
///
/// A reference type so `EditorHost` can claim a generation and read it back
/// after a suspension without a `@State` write invalidating the body on every
/// document switch. See `EditorHost.loads`.
@MainActor
final class EditorHostLoadGeneration {
    private var current = 0
    /// Claim the next generation, superseding every load already in flight.
    func claim() -> Int {
        current += 1
        return current
    }
    /// Whether the load that claimed `generation` is still the wanted one.
    func isCurrent(_ generation: Int) -> Bool { generation == current }
    /// Supersede every in-flight load without starting one — the teardown case,
    /// where a bind would leave a registered `Document` nothing is left to close.
    func abandon() { current += 1 }
}

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
    /// Which load this host most recently STARTED (whole-branch review, M1A).
    ///
    /// **Not observable state, and deliberately not `@State` of its own**
    /// (tripwire 6): a plain box, mutated without invalidating the body, holding
    /// one `Int`. `loadDocumentIfNeeded` is reached from two `.onChange`s firing
    /// unstructured `Task`s that nothing cancels and from a `.task` that is
    /// cancelled, and nothing between `Document.load`'s suspension and the
    /// assignments below asked whether the load was still the wanted one. A
    /// superseded load then overwrote `document`/`loadedItemId`/`priorLoadedPath`
    /// with the document the writer had already clicked away from: the body's
    /// `loadedItemId == item.id` guard keeps that off the binding (so no
    /// keystroke is lost — this is where it differs from the statement pane's
    /// C1), but the pane sticks on "Loading…" until the writer clicks elsewhere,
    /// and the correct `Document` is left registered and never closed.
    ///
    /// A generation rather than a named destination because the destination
    /// alone does not settle it: both `.onChange`s fire on one selection change,
    /// so two loads of the SAME path are in flight and a destination check would
    /// let both bind, leaving two `Document`s on one path each with its own
    /// `PendingBuffer`. Only "a newer load has started since mine" refuses that,
    /// and it is correct whichever of the two returns first.
    @State private var loads = EditorHostLoadGeneration()

    /// The load failure the writer is shown instead of an eternal "Loading…"
    /// (RULING-7 + RULING-54): a document that REFUSES to open — an unreadable
    /// op-log file, an unlistable ops directory — says why, in the load
    /// error's own words, right where the manuscript would have been.
    @State private var loadError: String? = nil

    /// The derived translated surface shown in read-only translation review
    /// (Task 11), or nil when the editor shows the source manuscript. This is
    /// DELIBERATE one-way threaded state (tripwire 6): it is recomputed ONLY on
    /// explicit events — `control.translationLanguage` changing, or an
    /// `annotationsVersion` tick while in the posture — never observed off
    /// `displayText`. When non-nil it becomes the EditorSurface's `text` value,
    /// so the buffer swap flows through the single `applyExternalText` site in
    /// `EditorSurface.updateNSView`; the editor membrane (flipped in the
    /// coordinator off `control.translationLanguage`) blocks every edit, so the
    /// surface is read-only and produces zero ops.
    @State private var translatedSurfaceText: String? = nil

    /// This view's hosting NSWindow, resolved via `WindowAccessor` so the
    /// project-scoped `maughamTranslationDidUpdate` observer can apply the
    /// ADR 0021 liveness/scope filter (a closed window must not act).
    @State private var window: NSWindow? = nil

    /// The standing banner over a read-only partial open (recovery spec §4),
    /// or nil for every ordinary document. Minted at the ONE bind site in
    /// `loadDocumentIfNeeded` from the doc's own `readOnlyRecovery` state, so a
    /// normal load leaves it nil and this view renders exactly as before.
    ///
    /// Not parallel text state (tripwire 6): it holds the unreadable FILE NAMES
    /// and a readability poll, never the manuscript's text, and nothing it owns
    /// feeds the editor binding. Its single output is `offersReopen`, which the
    /// banner renders as a button — the reload happens only when the writer
    /// presses it (`retryFullLoad`), never on the watcher's own authority.
    @State private var recoveryBannerModel: RecoveryBannerModel? = nil

    /// The refusal ladder shown where the manuscript would be (recovery spec
    /// §3), or nil for every document that opened. Minted at the ONE catch site
    /// in `loadDocumentIfNeeded`, from the classified cause, and torn down
    /// everywhere the host binds a document or retries.
    ///
    /// **Held, not built in `body`.** The model owns a readability watch; a
    /// `RecoveryPaneModel(...)` written inline in the view would start a fresh
    /// poller on every render pass. It is re-created only when a refusal is
    /// classified, which is exactly "keyed to the cause".
    ///
    /// **And it is the only state the cause lives in** (tripwire 6's shape): a
    /// second `@State` holding the `RecoveryCause` beside it would be two things
    /// to keep in sync for no read that `recoveryPaneModel?.cause` doesn't
    /// already serve. Nothing here feeds the editor binding — the model's whole
    /// output is the pane's copy and its two buttons.
    @State private var recoveryPaneModel: RecoveryPaneModel? = nil

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
                    // load-bearing. This Binding is the fragile data-plane seam
                    // (tripwires 2/3/6/7) — it stays inline here, NOT packaged into
                    // the configuration.
                    text: Binding(
                        // In translation review the surface shows the derived
                        // translated buffer, not the source manuscript.
                        get: { translatedSurfaceText ?? doc.displayText },
                        set: { newText in
                            // Defense in depth: the coordinator membrane already
                            // blocks every mutation in translation review, so no
                            // set should reach here — but if one did, it must
                            // NEVER write the translated buffer back onto the
                            // source op log.
                            guard translatedSurfaceText == nil else { return }
                            doc.setFullText(newText)
                            documentStore.recordEditorTextWrite(
                                documentId: doc.docId,
                                newText: newText,
                                mode: WritingModeFactory.mode(for: path),
                                store: store)
                        }
                    ),
                    configuration: makeSurfaceConfiguration(doc: doc, path: path, um: um)
                )
                // Recovery spec §4: the read-only partial view's standing
                // banner, in `ViewOnlyShareNotice`'s position over the writing
                // column. Inside `.id(path)` on purpose, so a document switch
                // tears the banner down and its `.onDisappear` cancels the
                // readability watch. Nothing renders for an ordinary document.
                .safeAreaInset(edge: .top) { recoveryBannerInset(doc: doc) }
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
                    // While in translation review, a source-side edit (which
                    // flips paragraphs stale) must re-derive the surface. Note
                    // this fires on annotation-set changes only; a fresh
                    // translation WRITE (write_translation) does not bump
                    // annotationsVersion — that refresh arrives via the
                    // maughamTranslationDidUpdate observer below.
                    if control.translationLanguage != nil {
                        recomputeTranslatedSurface(doc: doc)
                    }
                }
                // A retranslation landed via write_translation for THIS doc:
                // re-derive so the read-only surface + badges refresh live
                // instead of freezing until the writer exits and re-enters.
                // Project-scoped (ADR 0021); the liveness/scope filter lives in
                // MaughamEvent.shouldDeliver. Guarded on being in-mode and the
                // event naming the loaded doc.
                .onProjectEvent(
                    .maughamTranslationDidUpdate, url: store.url, window: window
                ) { note in
                    guard control.translationLanguage != nil,
                          note.userInfo?["document_id"] as? String == doc.docId
                    else { return }
                    recomputeTranslatedSurface(doc: doc)
                }
                .onChange(of: control.isReviewMode) { _, nowReview in
                    control.reviewAnnotations = nowReview
                        ? doc.annotations(filter: AnnotationFilter(statuses: [.open]))
                        : []
                }
                // Dedicated one-way recompute: entering translation review
                // (language becomes non-nil) derives the surface once; exiting
                // (nil) drops it so `text` reverts to `doc.displayText` and the
                // existing applyExternalText site swaps the source buffer back in.
                .onChange(of: control.translationLanguage) { _, _ in
                    recomputeTranslatedSurface(doc: doc)
                }
                .onAppear {
                    control.reviewAnnotations = control.isReviewMode
                        ? doc.annotations(filter: AnnotationFilter(statuses: [.open]))
                        : []
                    // A re-mount while a language is selected must restore the
                    // translated surface.
                    recomputeTranslatedSurface(doc: doc)
                }
            } else if currentItem?.type == .group {
                placeholder("Select a document inside this group to edit.")
            } else if currentItem?.type == .document {
                recoveryOrPlaceholder
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
            recoveryBannerModel = nil
            // Stopped here as well as in the pane's own `.onDisappear`:
            // nested `.onDisappear` ordering is unreliable on window close,
            // and a poller that outlives its host holds an action that would
            // reload a document nobody is looking at. Dropping the model then
            // keeps a returning host from re-showing a refusal it has not
            // re-derived.
            recoveryPaneModel?.stopWatching()
            recoveryPaneModel = nil
            loadedItemId = nil
            priorLoadedPath = nil
            // And nothing in flight may bind into a host that has gone: it
            // would register a Document this teardown has already passed.
            loads.abandon()
        }
        // The inspector/goal-indicator metrics mirror now lives entirely in the
        // EditorCoordinator (spec §7): it delivers precomputed `EditorMetrics`
        // via `onMetricsChanged` on its own debounced trailing edge while typing
        // and immediately on attach. The former `.onChange(of: displayText)`
        // mirror + `metricsMirrorTask` here is deleted — re-introducing any
        // read of `document.displayText` into this view's body would reopen the
        // parallel-observable-state cursor races (tripwires 6 and 7).
        .task { await loadDocumentIfNeeded() }
        .background(WindowAccessor(window: $window))
        // The second trigger (the BinderRow.claimFocus double-trigger shape):
        // a load can complete before WindowAccessor resolves the window, and
        // a post made then is dropped by the liveness guard — deliver again
        // when the window arrives. `consumePendingRecoveryFailure` is
        // consume-once, so at most one of the two triggers posts.
        .onChange(of: window) { _, _ in deliverPendingRecoveryNoticeIfPossible() }
    }

    /// RULING-54 (M9-OL-010): post the crash-recovery notice exactly once,
    /// and only when a window exists to render it. Without a window the stamp
    /// stays on the document for the next trigger.
    private func deliverPendingRecoveryNoticeIfPossible() {
        guard window != nil, let doc = document,
              let failure = doc.consumePendingRecoveryFailure() else { return }
        MaughamEvent.postNotice(
            "Maugham couldn’t recover unsaved keystrokes from your last session "
            + "(\(failure.name): \(failure.reason)). Everything you saved is intact; "
            + "a record was kept in the project’s quarantine folder.",
            projectURL: store.url)
    }

    /// What a document that did not open shows: the recovery ladder when the
    /// refusal was one this ladder owns (spec §3), and otherwise the bare
    /// message the load path has always shown — an unclassified error keeps
    /// today's rendering rather than being dressed up in a pane that offers
    /// rungs it cannot climb.
    ///
    /// Extracted from `body` for the same reason `recoveryBannerInset` is: the
    /// type-check budget (`ProjectWindow.body`'s ceiling, CLAUDE.md).
    @ViewBuilder
    private var recoveryOrPlaceholder: some View {
        if let paneModel = recoveryPaneModel {
            // Keyed on the MODEL's identity, not the view's position. One
            // refusal can follow another (the writer clicks a second broken
            // document), and a swapped-in model at a stable identity restarts
            // nothing: `DocumentRecoveryPane`'s `.task` begins the watch on
            // appear, and its `.onDisappear` stops it — neither fires for an
            // update. The new cause would be shown with no watch behind it
            // while the old cause's poller ran on, holding a callback that
            // reloads a document the writer has left.
            DocumentRecoveryPane(model: paneModel)
                .id(ObjectIdentifier(paneModel))
        } else {
            placeholder(loadError ?? "Loading…")
        }
    }

    /// The recovery banner, or nothing at all. Extracted from `body` for the
    /// same reason every other wall here is (the type-checker budget), and
    /// gated twice — on the doc's own posture and on a minted model — so an
    /// ordinary document's render path is untouched.
    @ViewBuilder
    private func recoveryBannerInset(doc: Document) -> some View {
        if doc.isReadOnlyRecovery, let bannerModel = recoveryBannerModel {
            // Neither action is identity-guarded, and neither needs to be: both
            // are built fresh on every render pass, from the `doc` the body is
            // currently rendering, so a superseded one cannot exist to fire.
            // (The PANE's three actions are the opposite case — minted once
            // with the model, one of them fired by a poller — which is what the
            // recoveryActionIsCurrent guard exists for.)
            RecoveryBanner(
                model: bannerModel,
                onReopen: { Task { await retryFullLoad() } },
                onSetAside: { Task { await quarantineAndContinue() } })
        }
    }

    /// Close whatever is bound (recovery or stale) and run the normal load
    /// again. Reached from `RecoveryBanner`'s Reopen — the writer's own press,
    /// which is the only thing allowed to swap the view under them.
    ///
    /// No `documentStore.unregister` here, and that is not an omission: a
    /// read-only recovery doc is never registered (spec §4), so there is no
    /// registry entry of its own to withdraw.
    private func retryFullLoad() async {
        if let doc = document { await doc.close() }
        document = nil
        recoveryBannerModel = nil
        // Reached from the pane's own auto-open as well as the banner's
        // Reopen, so the ladder must come down here too: if the retry refuses
        // again, the catch below mints a fresh model for the fresh cause, and
        // a stale one left standing would keep polling beside it. Stopped
        // explicitly rather than relying on the watch having returned by
        // itself — it has, when the auto-open is what called this, but the
        // banner's Reopen reaches here with the watch still running.
        recoveryPaneModel?.stopWatching()
        recoveryPaneModel = nil
        loadedItemId = nil
        priorLoadedPath = nil
        await loadDocumentIfNeeded()
    }

    /// Rung 1 (spec §4): bind a read-only partial Document. NEVER registered —
    /// DocumentStore's registry is how MCP resolves open docs, and a
    /// registered partial view would hand Claude the partial state §6 forbids.
    ///
    /// It claims a load generation like every other bind here: the writer's
    /// press can land while a normal load is in flight, and two Documents on
    /// one path would each carry their own `PendingBuffer`.
    private func openReadOnly() async {
        guard let item = currentItem, let path = item.path else { return }
        let generation = loads.claim()
        do {
            let doc = try await Document.load(
                url: store.url.appendingPathComponent(path),
                device: Self.deviceId, session: Self.sessionId,
                presenter: documentStore.presenter,
                recovery: .readOnlyPartial)
            guard loads.isCurrent(generation) else {
                await doc.close()
                return
            }
            document = doc
            loadedItemId = item.id
            priorLoadedPath = path
            loadError = nil
            // Symmetry with every other teardown: stop the watch before
            // dropping the model. The pane is about to leave the screen, but
            // its `.onDisappear` cannot run until a render pass this bind
            // precedes, and a poller left running would auto-open editable
            // over the read-only view the writer just asked for.
            recoveryPaneModel?.stopWatching()
            recoveryPaneModel = nil
            recoveryBannerModel = RecoveryBannerModel(
                unreadableFiles: doc.readOnlyRecovery?.unreadableFiles ?? [],
                opsDirectory: store.url.appendingPathComponent(".maugham/ops"))
        } catch {
            guard loads.isCurrent(generation) else { return }
            // The partial view refused too (it can: `nothingUnreadable`, or a
            // directory nothing can enumerate). The pane STAYS — its other
            // rung, Restore from Backup, is still the right offer — so the
            // refusal is told as a notice rather than into a `loadError` the
            // pane is covering (RULING-5: never a silent refusal).
            loadError = error.localizedDescription
            MaughamEvent.postNotice(
                "Maugham couldn’t open a read-only view of this document "
                + "(\(error.localizedDescription)).",
                projectURL: store.url)
        }
    }

    /// Rung 3 (spec §5): set the unreadable op-log file(s) aside and open the
    /// document EDITABLE without them. The writer keeps writing; the bytes are
    /// moved, never deleted, and Plan B's return path brings them back — merged,
    /// never overwriting — the moment they read again.
    ///
    /// **Reached from both surfaces**, which is why the decision lives here
    /// rather than in either of them: from the refusal pane, where no `Document`
    /// exists at all, and from the read-only banner, where one does and the
    /// writer has just been stopped from typing. The two differ only in what
    /// they know, and the difference is the first block below.
    ///
    /// It ends in `retryFullLoad()` — the one path that closes what is bound and
    /// runs the ordinary load — so a successful set-aside arrives as an ordinary
    /// editable document, and a still-refusing one arrives as a freshly
    /// classified refusal rather than a stale pane.
    private func quarantineAndContinue() async {
        guard let item = currentItem, let path = item.path else { return }
        let docURL = store.url.appendingPathComponent(path)
        let opsDir = store.url.appendingPathComponent(".maugham/ops", isDirectory: true)

        // What to move, and the reason each move records. The BANNER is looking
        // at an open partial view, which names EVERY file that failed — a
        // partial open can be blocked by more than one, and setting one aside
        // while leaving its neighbour would refuse the load again for the same
        // reason. The PANE is looking at a refusal, whose cause names the one
        // file the strict load died on. `.icloudNotDownloaded` and
        // `.unlistableOpsDirectory` are absent by construction: neither offers
        // this rung (`RecoveryPaneModel.offersSetAside`), and the `case` below
        // is what makes that a shape rather than a promise.
        var targets: [(url: URL, reason: String)] = []
        if let doc = document, doc.isReadOnlyRecovery,
           let unreadable = doc.readOnlyRecovery?.unreadableFiles {
            targets = unreadable.map {
                (url: opsDir.appendingPathComponent($0.name), reason: $0.reason)
            }
        } else if case .unreadableFile(_, let fileURL, let reason)? = recoveryPaneModel?.cause {
            targets = [(url: fileURL, reason: reason)]
        }
        guard !targets.isEmpty else { return }

        // The id the record is filed under — and the id the return path will
        // look it up by, so it has to be the same one the op log itself is
        // written against. An open doc knows its own. A refusal has no
        // `Document` at all, so it is resolved from the path through
        // `resolveDocId`, the function `Document.load` itself calls — never a
        // second parser (tripwire 19's shape: one implementation, not a
        // stricter local copy).
        let docId: String
        if let doc = document {
            docId = doc.docId
        } else {
            do {
                docId = try resolveDocId(for: docURL)
            } catch {
                loadError = error.localizedDescription
                MaughamEvent.postNotice(
                    "Maugham couldn’t work out which document this history "
                    + "belongs to, so it set nothing aside "
                    + "(\(error.localizedDescription)).",
                    projectURL: store.url)
                return
            }
        }

        for target in targets {
            do {
                try OpLogQuarantine.quarantine(
                    fileURL: target.url, docId: docId,
                    reason: target.reason, in: store.url)
            } catch {
                // A throw part-way through leaves some files moved and this one
                // where it was — which is a COHERENT state, not a half-done
                // one: each move is a complete, recorded, reversible act of its
                // own, and nothing here has touched the document. So we stop
                // rather than push past the failure, and say which file and
                // why. No reload is attempted: what the writer is looking at
                // stays put, and their next attempt reclassifies against
                // whatever STILL blocks the load — which is exactly the files
                // that did not move.
                loadError = error.localizedDescription
                MaughamEvent.postNotice(
                    "Maugham couldn’t set “\(target.url.lastPathComponent)” aside "
                    + "(\(Self.explainSetAsideFailure(error))). Nothing was lost — "
                    + "any files it did move are kept in the project’s "
                    + "conflicts folder.",
                    projectURL: store.url)
                return
            }
        }
        await retryFullLoad()
    }

    /// Why a set-aside failed, in a sentence. `QuarantineError` is a plain
    /// enum, so its `localizedDescription` is the unhelpful "The operation
    /// couldn’t be completed" — and its one case is one the writer can act on
    /// (by waiting), so it gets its own words. Every other error is a real
    /// filesystem failure whose own description is the better one.
    ///
    /// Reachable from the BANNER only: the pane never offers this rung for a
    /// stub (`RecoveryPaneModel.offersSetAside`), but a partial open names
    /// every file that failed, and one of those can be a file iCloud is still
    /// bringing down.
    private static func explainSetAsideFailure(_ error: Error) -> String {
        guard let quarantineError = error as? QuarantineError else {
            return error.localizedDescription
        }
        switch quarantineError {
        case .datalessStub:
            return "iCloud is still downloading it — it isn’t broken, and "
                 + "moving it now would fight that download"
        }
    }

    /// Build the EditorSurface configuration wall in a dedicated function so the
    /// `body` type-checker load drops (the extracted-ViewModifier / ProjectWindow
    /// pattern). Pure packaging (hardening Task 2): every closure below is the
    /// same one that used to sit inline in the ~40-param init — same captures
    /// (`doc`/`path`/`um` threaded in, the rest via `self`), same types, same
    /// wiring. The text Binding and its undo-coherent flag are the only
    /// tripwire-sensitive pieces; the Binding stays inline at the call site and
    /// the flag is packaged 1:1 as `consumeUndoCoherentApplyFlag`.
    private func makeSurfaceConfiguration(
        doc: Document, path: String, um: UndoManager?
    ) -> EditorSurfaceConfiguration {
        EditorSurfaceConfiguration(
            presentation: .init(
                theme: userPreferences.theme,
                typography: ProjectStore.effectiveTypography(
                    override: store.manifest.typography,
                    userDefault: userPreferences.typography),
                mode: WritingModeFactory.mode(for: path),
                typewriterScroll: userPreferences.typewriterScroll,
                sentenceFocus: userPreferences.sentenceFocus,
                paragraphFocus: userPreferences.paragraphFocus,
                showElementGutter: store.manifest.showElementGutter ?? true),
            control: control,
            // Recovery spec §4: a read-only partial open refuses typing at the
            // AppKit level (Task 4) and answers the attempt by emphasising the
            // banner. Both are `false`/`nil` for an ordinary document, which is
            // the configuration this call site has always produced.
            readOnlyRecovery: doc.isReadOnlyRecovery,
            callbacks: .init(
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
                onTypingRefused: doc.isReadOnlyRecovery
                    ? { recoveryBannerModel?.noteTypingRefused() }
                    : nil),
            paragraphProviders: .init(
                wikiLinkResolver: wikiLinkResolver,
                wikiLinkClickResolver: wikiLinkClickResolver,
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
                }),
            reviewProviders: .init(
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
                reviewLocalAuthorName: { userPreferences.collaboratorDisplayName }),
            // Interactive margin-card actions (Part 1). Each is an op-log
            // append routed through Document — NOT a text-binding write, so
            // the applyExternalText tripwires (6/7) don't apply. The
            // coordinator refreshes its marks from the provider after each.
            annotationActions: .init(
                reviewAcceptHandler: { id in
                    do {
                        try await doc.acceptAnnotation(id: id, undoManager: um)
                    } catch let error as AnnotationAcceptError
                        where error == .suggestionAnchorLost {
                        // RULING-5's told-why half on the margin-card surface —
                        // a try? here was the branch review's silent-refusal
                        // catch. Same words as the pane's alert.
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = "This suggestion can no longer be applied"
                            alert.informativeText = "The passage it would replace is no longer in the paragraph, so applying it could put the replacement in the wrong place. The suggestion stays open — ask Claude for a fresh one against the current text."
                            alert.alertStyle = .informational
                            alert.runModal()
                        }
                    } catch {
                        documentLog.error("margin-card accept failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
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
                }),
            consumeUndoCoherentApplyFlag: { doc.consumeUndoCoherentApplyFlag() })
    }

    /// Re-derive the read-only translation surface for the live document, or
    /// clear it when no language is selected (Task 11). Pulls the persisted
    /// translation records for `control.translationLanguage`, derives against the
    /// live doc's authoritative `sequence`/`paragraphs`, and joins the entries in
    /// order as `translatedText ?? sourceText` with the pinned `"\n\n"` separator
    /// (the same render `ProjectStoreASTSource` uses for publish). Called only on
    /// explicit events (language change, annotationsVersion tick while in mode,
    /// re-mount) — never off `displayText` — so it stays one-way threaded state,
    /// not parallel observable state feeding the binding (tripwire 6).
    private func recomputeTranslatedSurface(doc: Document) {
        guard let language = control.translationLanguage else {
            translatedSurfaceText = nil
            control.translationBadges = .empty
            return
        }
        let records = TranslationStore.loadMerged(
            forDocId: doc.docId, language: language, in: store.url)
        let derived = TranslationDeriver.derive(
            records: records, sequence: doc.sequence,
            paragraphs: doc.paragraphs, language: language)
        // The badge overlay measures ¶ ranges by accumulating each entry's OWN
        // text (TranslationBadgeLayout.ranges) rather than re-splitting a
        // joined string, so hand it the same per-block text the buffer swap
        // joins — same bytes as `translatedSurfaceText` below, just chunked
        // per paragraph (Task 12 fix round 1).
        //
        let badgeEntries = Self.reviewBadgeEntries(from: derived.entries)
        translatedSurfaceText = badgeEntries.map(\.text).joined(separator: "\n\n")
        control.translationBadges = EditorControl.TranslationBadgeModel(
            entries: badgeEntries, orphans: derived.orphans)
    }

    /// Build the per-paragraph review entries from a derived translation. This
    /// is the ONE place the review plane's text is constructed — the surface
    /// buffer (`translatedSurfaceText`), the badge ranges, and the ⌘⌥L pane all
    /// derive from these entry texts, so stripping inline task anchors here
    /// keeps them byte-consistent and anchor-free. A `missing` paragraph falls
    /// back to its source text, which can carry `<!--t-XXXX-->` anchors; without
    /// this strip they'd render raw in the read-only surface. Pure + static so
    /// `EditorHostTranslationSurfaceTests` can pin the anchor-free rendering
    /// without an AppKit surface (mirrors `TranslationBadgeLayout.ranges`).
    static func reviewBadgeEntries(
        from entries: [TranslatedDocument.Entry]
    ) -> [TranslationBadgeLayout.Entry] {
        entries.map {
            TranslationBadgeLayout.Entry(
                paragraphId: $0.paragraphId,
                text: RenderFilter.stripTaskAnchorsInline($0.translatedText ?? $0.sourceText),
                status: $0.status)
        }
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

    /// Whether a recovery action minted against `minted` may still act.
    ///
    /// The refusal pane's two actions are minted ONCE, when a cause is
    /// classified, and one of them is fired by a poller rather than by a press:
    /// the iCloud rung opens the document by itself the moment the file lands.
    /// A `View` is a struct, so those closures carry the value of
    /// `selectedItemId` — a `let` — from the moment they were built, and the
    /// writer is free to select another document while the poll runs. Firing
    /// stale, the action would close the document the writer is now in and
    /// re-bind the one they left, with the binder still highlighting the other:
    /// no words lost (the close flushes), but the wrong manuscript silently on
    /// screen, which is the race class tripwires 2/3/6/7 exist for.
    ///
    /// `recoveryPaneModel` is `@State`, so a read through it inside the closure
    /// sees LIVE storage rather than the captured copy — the one channel by
    /// which these closures can learn that the world moved. Identity, not the
    /// cause: a second refusal for the same reason on a different document is
    /// still a different pane.
    ///
    /// Static + pure so `EditorHostRecoveryActionGuardTests` can pin the rule
    /// without a window (the `needsReload` precedent).
    static func recoveryActionIsCurrent(
        minted: RecoveryPaneModel?, current: RecoveryPaneModel?
    ) -> Bool {
        guard let minted else { return false }
        return minted === current
    }

    /// Maps the outcomes of an auto-return sweep (Task 6) to the notice text
    /// to post, or nil when nothing should be said. Silence is deliberate for
    /// `.stillUnreadable`/`.corrupt` — the writer never asked for this
    /// attempt, so the standing History-pane notice (`HistoryPane.quarantineNotice`)
    /// is the only surface a held record needs. `.returned`/`.supersededBySync`
    /// share one sentence, orphan counts summed across every record the sweep
    /// touched, via the SAME copy `HistoryPane`'s explicit Retry button uses
    /// (`recoveredHistoryNotice(orphanCount:)`) — one sentence, one place it's
    /// worded.
    ///
    /// Static + pure so a unit test can pin the mapping without mounting a
    /// window — the `needsReload`/`recoveryActionIsCurrent` precedent above.
    static func autoReturnNotice(outcomes: [ReturnOutcome]) -> String? {
        var orphanCount = 0
        var anyReturned = false
        for outcome in outcomes {
            switch outcome {
            case .returned(let report), .supersededBySync(let report):
                anyReturned = true
                orphanCount += report.orphans.count
            case .stillUnreadable, .corrupt:
                break
            }
        }
        guard anyReturned else { return nil }
        return HistoryPane.recoveredHistoryNotice(orphanCount: orphanCount)
    }

    private func loadDocumentIfNeeded() async {
        guard let item = currentItem,
              item.type == .document,
              let path = item.path,
              Self.needsReload(
                  itemId: item.id, path: path,
                  loadedItemId: loadedItemId, loadedPath: priorLoadedPath)
        else { return }
        // Claimed BEFORE the first suspension: everything from here on may be
        // superseded, and only the newest claim may write the markers below.
        let generation = loads.claim()
        // A refusal belongs to the selection that raised it, and this host
        // KEEPS ITS IDENTITY across a document switch (ProjectWindow's
        // `manuscriptEditor` layers rather than branches, so nothing unmounts).
        // Left standing, the previous document's pane stays on screen for the
        // whole of this load with its poller running — and that poller holds an
        // action minted against the previous selection. Stopped and dropped
        // HERE rather than left to the view's `.onDisappear`, which cannot run
        // until a render pass this suspension precedes.
        recoveryPaneModel?.stopWatching()
        recoveryPaneModel = nil
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
            // Superseded while we were in file I/O — the writer clicked on, or
            // this view went away. Never register it and never write the
            // markers; close it, or it deallocates with a pending buffer and
            // the load that IS wanted is the one left looking stale.
            guard loads.isCurrent(generation) else {
                await doc.close()
                return
            }
            documentStore.register(document: doc, for: path)
            document = doc
            loadedItemId = item.id
            priorLoadedPath = path
            loadError = nil
            // A document that opened has no refusal to show: the ladder goes
            // away with the failure that raised it. This is the belt — the
            // stop-and-drop before the load's first suspension (defence 1)
            // has already cleared it, and this ALSO clears whatever a
            // re-entrant refusal minted while we were in file I/O.
            recoveryPaneModel = nil
            // Recovery spec §4: mint the banner only for a doc that came back
            // read-only. `Document.load`'s ordinary path leaves
            // `readOnlyRecovery` nil, so this is nil for every normal load and
            // the render path above is unchanged.
            recoveryBannerModel = doc.readOnlyRecovery.map {
                RecoveryBannerModel(
                    unreadableFiles: $0.unreadableFiles,
                    opsDirectory: store.url.appendingPathComponent(".maugham/ops"))
            }
            // RULING-54 (M9-OL-010): the crash-recovery failure is stamped on
            // the doc by `Document.load` and delivered HERE, where a window
            // can exist — a load-time post from a windowless context was
            // dropped by the liveness guard and then destroyed on close.
            deliverPendingRecoveryNoticeIfPossible()
            // Plan B (spec §5's return path), Task 6: a document that just
            // bound normally tries its own held quarantine records without
            // being asked. Guarded on `!doc.isReadOnlyRecovery` — a recovery
            // bind is read-only by definition (spec §4) and must never touch
            // quarantine bookkeeping.
            if !doc.isReadOnlyRecovery {
                let autoReturnDocId = doc.docId
                let autoReturnProjectURL = store.url
                // `docId`/`projectURL` are captured as VALUES here, not
                // `doc`/`store` themselves: if the writer switches documents
                // mid-return the attempt still completes harmlessly — it is
                // scoped to the filesystem, not to this view's live binding —
                // and the notice it may post is project-scoped rather than
                // doc-scoped, so nothing here needs a
                // `recoveryActionIsCurrent`-style staleness guard.
                Task {
                    let held = OpLogQuarantine.records(
                        forDocId: autoReturnDocId, in: autoReturnProjectURL
                    ).filter { $0.status == .held }
                    guard !held.isEmpty else { return }
                    var outcomes: [ReturnOutcome] = []
                    for record in held {
                        // `presenter: nil` is deliberate, not an omission:
                        // handing this call the VIEW's own presenter would
                        // exclude the project's `ProjectFolderPresenter` from
                        // the coordinated move, and it is THAT presenter's
                        // `presentedItemDidChange` (`handleExternalLogChange`,
                        // ADR 0012) that lets the still-open Document notice
                        // the returned ops land and merge them in. `nil`
                        // keeps the project's presenter eligible.
                        outcomes.append(await OpLogQuarantine.attemptReturn(
                            record: record, in: autoReturnProjectURL,
                            presenter: nil))
                    }
                    // Known interaction (carried from Task 4/5's review):
                    // `quarantineAndContinue` ends in `retryFullLoad`, so this
                    // very hook fires again on the fresh bind and immediately
                    // re-probes the file just set aside. For a persistent
                    // cause that lands a harmless `.stillUnreadable` (silent,
                    // below); for a cause that healed in the gap it is a
                    // fast, welcome return. Accepted — no debounce.
                    if let notice = Self.autoReturnNotice(outcomes: outcomes) {
                        MaughamEvent.postNotice(notice, projectURL: autoReturnProjectURL)
                    }
                }
            }
            // Metrics for the freshly-loaded doc are delivered by the new
            // EditorSurface's coordinator `attach` (immediate, non-debounced) —
            // no EditorHost-side mirror call.
        } catch {
            // A superseded failure must not overwrite the markers either: doing
            // so unbinds a document that loaded perfectly well and leaves the
            // editor on "Loading…" for a file that is open.
            guard loads.isCurrent(generation) else { return }
            document = nil
            recoveryBannerModel = nil
            loadedItemId = item.id
            priorLoadedPath = nil
            // RULING-7 + RULING-54: the refusal is SHOWN — in the pane where
            // the manuscript would be, and as a project notice — never an
            // eternal "Loading…" placeholder over a real error.
            loadError = error.localizedDescription
            MaughamEvent.postNotice(error.localizedDescription, projectURL: store.url)
            // Recovery spec §3: classify the refusal, and mint the ladder's
            // model HERE — the one place a cause is known — so the pane's
            // readability watch is started once per refusal rather than once
            // per render. `classify` returns nil for errors this ladder does
            // not own, and then `recoveryOrPlaceholder` shows the bare message
            // exactly as before.
            let cause = RecoveryCause.classify(loadError: error, projectURL: store.url)
            recoveryPaneModel = cause.map { cause in
                // `minted` is WEAK and assigned after the init: the model holds
                // these closures, so a strong capture of it here is a cycle
                // that keeps a poller alive for the life of the process.
                weak var minted: RecoveryPaneModel?
                let model = RecoveryPaneModel(
                    cause: cause,
                    projectURL: store.url,
                    onOpenEditable: { Task {
                        guard Self.recoveryActionIsCurrent(
                            minted: minted, current: recoveryPaneModel) else { return }
                        await retryFullLoad()
                    } },
                    onOpenReadOnly: { Task {
                        guard Self.recoveryActionIsCurrent(
                            minted: minted, current: recoveryPaneModel) else { return }
                        await openReadOnly()
                    } },
                    // Guarded like its two siblings, and with the most to lose
                    // of the three: this one MOVES A FILE. Fired from a pane the
                    // writer has left behind, it would set aside part of one
                    // document's history while they are inside another.
                    onSetAside: { Task {
                        guard Self.recoveryActionIsCurrent(
                            minted: minted, current: recoveryPaneModel) else { return }
                        await quarantineAndContinue()
                    } })
                minted = model
                return model
            }
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

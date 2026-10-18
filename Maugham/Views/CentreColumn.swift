import SwiftUI
import MaughamCore
import AppKit

/// **The window's centre column**: the switch over
/// `ProjectWindow.centreRoute(…)` and every surface it mounts — the palette
/// wall, a research subject, the canvas, a Collection's reference
/// placeholder, and the manuscript editor with altitude and one cover over it.
/// It owns exactly one piece of state: the review board's open-notes counts,
/// which nothing outside this column reads.
///
/// **Everything else is the window's, handed down.** Each `@State` this column
/// WRITES arrives as a `Binding` (tripwire 2: a copy would be a second value
/// that drifts from the first), each value it only READS arrives as a value,
/// and each of the window's verbs arrives as a closure — so the one writer of
/// `ActivePassMemory` and the one round deferral stay `ProjectWindow`'s. The
/// persona, the column visibility and the subject stay owned by the window.
///
/// **Mounted ONCE**, as the content column's root (`ProjectWindow
/// .contentColumn`), so `EditorHost` and the canvas keep their identities
/// across every route change.
///
/// `canvasModel` is a `let`, and nothing here reads its `.scene`: a reader
/// keyed on it would re-run this body per drag frame (tripwire 30).
struct CentreColumn: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let canvasModel: CanvasModel
    let editorControl: EditorControl
    @Bindable var publishCentre: PublishCentreModel
    let designer: DesignerOrchestrator
    let declaredWorld: DeclaredWorldStore?
    let window: NSWindow?

    // The route's inputs this column only reads.
    let persona: Persona
    let researchPreviewVisible: Bool

    // The window's state this column writes — bindings, never copies.
    @Binding var selectedSubject: BinderSubject?
    @Binding var showsPaletteWall: Bool
    @Binding var selectedPaletteCardId: String?
    @Binding var outlineLayout: OutlineLayout
    @Binding var showInspector: Bool
    @Binding var detailSegment: DetailSegment
    @Binding var annotationScopeRequest: AnnotationScope
    @Binding var metrics: EditorMetrics
    @Binding var currentElement: String?

    // The window's verbs.
    /// `ProjectWindow.recordActivePass(forPiece:passId:)` — the ONE writer of
    /// `UIState.activePassMemory`, which the run reads to sign its notes.
    let recordActivePass: (_ piece: String, _ passId: String) -> Void
    /// `ProjectWindow.runRoundWhenPieceOpens(pieceId:)` — the bounded wait for
    /// a piece to open before a chip's round runs.
    let runRoundWhenPieceOpens: (_ pieceId: String) -> Void
    /// The drawing door's posture for one document.
    let posture: (_ docId: String) -> Posture

    /// **The board's open-notes column, computed OFF the body path** — piece id
    /// → how many notes it still has open, and the pieces whose op logs could
    /// not be read. State because the count is a project-wide walk over every
    /// document: inside `body` it would run on every redraw of a board that can
    /// hold hundreds of rows. `refreshOpenNotes()` is the one writer, run from
    /// the board's `.task` and `.maughamAnnotationsChanged` — never from a body.
    @State private var openNotesCounts: [String: OpenNotesSummary] = [:]
    @State private var openNotesUnreadable: Set<String> = []

    var body: some View {
        editorPane(store: store, documentStore: documentStore)
    }

    /// **The canvas is ONE branch here, and every other branch is written so as
    /// not to become a second one.**
    ///
    /// `CanvasView`'s camera, scrap layouts, thumbnail cache, in-progress edit
    /// and accessibility elements are `@State` on the view. Two ViewBuilder
    /// branches are two `_ConditionalContent` arms, so a second arm mounting the
    /// board gives it a second identity and SwiftUI tears the first down when
    /// the condition moves: camera back to origin, layouts re-measured,
    /// thumbnails emptied, `canvas.md` re-read (measured, 2026-08-02). That is
    /// why research answers `.besideTheCanvas` in Plan rather than taking the
    /// centre, and why the mount is censused in `RegionBindingTests`.
    @ViewBuilder
    private func editorPane(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        // **One exhaustive answer, one switch.** `centreRoute` composes every
        // decision: the palette wall above everything (`PaletteWallModifier`
        // closes it on a subject change; this is the belt to its braces), a
        // research subject that takes the centre (never in Plan, so the board
        // keeps its identity), the canvas, the Collection reference, then the
        // editor with altitude and one cover. The canvas is the third branch and
        // its only mount.
        switch ProjectWindow.centreRoute(persona: persona,
                                         subject: selectedSubject,
                                         projectType: store.manifest.type,
                                         structure: store.manifest.structure,
                                         showsPaletteWall: showsPaletteWall,
                                         preview: publishCentre.preview,
                                         proposal: publishCentre.selectedProposal,
                                         round: publishCentre.selectedRound) {
        case .paletteWall:
            PaletteWallCentre(store: store, selectedPaletteCardId: $selectedPaletteCardId,
                              onClose: { showsPaletteWall = false }, persona: persona)
        case .research(let id):
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: id, previewVisible: researchPreviewVisible,
                                  readOnly: !persona.editsResearchInTheCentre)
        case .canvas:
            canvasCentre(store: store, documentStore: documentStore)
        case .reference(let piece):
            ReferencePlaceholderCard(piece: piece) {
                openReferenceInWindow(piece: piece, store: store)
            }
        case .editor(let altitude, let cover):
            manuscriptEditor(store: store, documentStore: documentStore,
                             altitude: altitude, cover: cover)
        }
    }

    private func openReferenceInWindow(piece: StructureItem, store: ProjectStore) {
        let resolution = store.resolveReference(piece)
        let url: URL
        switch resolution {
        case .resolved(let u): url = u
        case .resolvedViaPathFallback(let u): url = u
        case .unresolved: return
        }
        MaughamEvent.post(.maughamOpenProject, to: .allWindows, payload: ["url": url])
    }

    /// **The manuscript editor, and the one surface drawn over it.** The editor
    /// mounts on whatever document the tree names (a screenplay's `.fountain`
    /// included), with `CentreRoute`'s layers over it: the project at altitude,
    /// then one cover — Publish's no-book notice, Review's passes board, or one
    /// of Publish's surfaces (round report, design gate, compiled book).
    ///
    /// **The host is the ZStack's FIRST child and present whatever covers it**
    /// (tripwire 6), and altitude is the SECOND, present whenever the subject
    /// names no document. `centreRoute` names the cover; this body draws it with
    /// ONE switch. Neither may become a branch of `editorPane`: two ViewBuilder
    /// branches are two view identities, so every project ↔ chapter hop would
    /// unmount `EditorHost`, whose `.onDisappear` is `doc.close()` +
    /// `documentStore.unregister(path:)` + `loads.abandon()`, not a cleanup.
    /// `ProjectAltitudeCentreTests` counts the host's lifetimes over the round
    /// trip, and drives the rejected shape as its control.
    ///
    /// Altitude and every cover but the notice are opaque and fill the column on
    /// purpose: the host's "Select a document." placeholder is still mounted
    /// underneath them.
    private func manuscriptEditor(
        store: ProjectStore, documentStore: DocumentStore,
        altitude: Bool, cover: CentreCover?
    ) -> some View {
        ZStack {
            EditorHost(
                store: store,
                documentStore: documentStore,
                selectedItemId: selectedSubject?.itemID,
                onMetricsChanged: { metrics = $0 },
                onElementChanged: { currentElement = $0 },
                wikiLinkResolver: { title in
                    store.resolveDocumentId(forTitle: title) != nil
                },
                wikiLinkClickResolver: { title in
                    store.resolveDocumentId(forTitle: title)
                },
                // Posture flows entirely through the EditorControl model (ADR
                // 0017): an author's manual ⌘⌥⇧R drives the render; a document
                // whose posture refuses the text is FORCED into review render AND
                // hard-locked (lockEditing) via `ProjectWindow.editorMembrane`
                // mirrored into the control.
                control: editorControl,
                // A note written from the margin carries the pass this piece is
                // being reviewed through. Read off `documentStore.uiState`, never a
                // per-window copy: a second window on the project records a pass
                // through `updateUIState` that a copy never hears about, and this
                // is a STAMP — a durable write into the op log. The queue pane and
                // the MCP tools (`activeReviewPassId`) read `uiState` too, so this
                // is a third reader of one value rather than a second value. The
                // validity check is `validatedActivePass`'s and is never re-spelled.
                activeReviewPassId: { docId in
                    documentStore.uiState.activePassMemory.validatedActivePass(
                        forPiece: docId,
                        in: store.manifest.effectiveReviewPasses)
                }
            )
            // **The project at altitude** — opaque, because the host's "Select a
            // document." placeholder is still mounted underneath. Its own layer,
            // ALWAYS at this position whatever covers it, so a cover coming or
            // going never remounts it: `OutlineTable` holds the writers it read
            // from the registry, its scroll position and its column widths.
            if altitude {
                ProjectAltitudePane(
                    store: store,
                    layout: $outlineLayout,
                    selectedSubject: $selectedSubject,
                    title: store.manifest.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            // **The one cover, ONE switch.** Which surface is on top is
            // `centreRoute`'s answer, never a layer order — and a case of this
            // switch, never a branch of `editorPane`, for the identity reason
            // above.
            switch cover {
            // In Publish with no book, the notice says WHICH kind of nothing it
            // is (Denver's 2026-08-12 rulings 2 and 3), standing over the
            // corkboard — it takes no clicks — rather than replacing it.
            case .notice(let notice):
                PublishCentreNoticeBanner(notice: notice)
            // **Review's passes board** — the project level of Review, over
            // altitude. A chapter subject reaches neither:
            // `reviewCentreShowsBoard` composes `subjectShowsAltitude`.
            case .reviewBoard:
                // Values, not the store (tripwire 4): the board reads
                // `manifest` here, at the one mount, and nothing on its body
                // path can reach a document or the disk.
                ReviewBoardPane(
                    title: store.manifest.title,
                    structure: store.manifest.structure,
                    passes: store.manifest.effectiveReviewPasses,
                    // Values again: a walk over every document, computed in
                    // `refreshOpenNotes` and merely READ here.
                    openNotes: openNotesCounts,
                    unreadableDocIds: openNotesUnreadable,
                    // **A count click widens the QUEUE and moves nothing else.**
                    // The right column goes to the notes, in project scope, pointed
                    // at the piece; the subject and persona are not written here
                    // (the ejection trap). The chip click is the one that travels,
                    // because opening a chapter is what a chip MEANS.
                    onOpenNotes: { pieceId in
                        showInspector = true
                        detailSegment = .annotations
                        annotationScopeRequest = .project(focusPiece: pieceId)
                    },
                    // **A chip click is a SUBJECT write and nothing else.** Moving
                    // the persona here would be the board deciding which persona is
                    // showing — the ejection trap `TripwireGrepTests`' persona-
                    // decision census names. Opening the chapter drops the subject
                    // below `reviewCentreShowsBoard`, uncovering the host that was
                    // mounted underneath all along; no arm is torn down.
                    onNavigate: { pieceId, passId in
                        selectedSubject = .item(pieceId)
                        recordActivePass(pieceId, passId)
                    },
                    // The board's write, at the board's HOST — the same place
                    // and the same shape as the pass ladder's, which lands at
                    // `InspectorView` and `PieceInspector` rather than inside
                    // `PassLadder` (`PersonaPaneRegistryTests`' census).
                    onSetState: { pieceId, passId, state in
                        Task { try? await store.setPassState(id: pieceId, passId: passId, state) }
                    },
                    // **A chip's round is three acts, and the third one waits.** The
                    // lane is recorded through the window's ONE `ActivePassMemory`
                    // writer (the run reads it to sign and file its notes), then the
                    // subject travels, as `onNavigate` does. Then it WAITS:
                    // `runRequested` refuses in silence while the document is not
                    // open, and the open is async (`RunWhenDocumentOpens`' doc).
                    onRunRound: { pieceId, passId in
                        recordActivePass(pieceId, passId)
                        selectedSubject = .item(pieceId)
                        runRoundWhenPieceOpens(pieceId)
                    },
                    // **Each chip asks its own piece**: the drawing door, per row,
                    // so a demotion re-renders the board with no reopen.
                    posture: posture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    // The counts are read HERE and never in the board's body:
                    // one project-wide walk when the board appears, and one per
                    // announced annotation change. `.task` is cancelled and
                    // re-run on identity, so a board uncovered by a subject hop
                    // recounts on arrival.
                    .task { refreshOpenNotes(store: store) }
                    .onProjectEvent(.maughamAnnotationsChanged,
                                    url: store.url, window: window) { _ in
                        refreshOpenNotes(store: store)
                    }
            // **Publish's surfaces**, in `publishCentre`'s order: the round
            // report (which alone also draws over a chapter), the design gate,
            // the compiled book. The gate and the book are project-level by
            // construction — `publishCentre` composes `subjectShowsAltitude`.
            case .translationRound(let round):
                TranslationRoundReportHost(
                    round: round, store: store, documentStore: documentStore,
                    projectURL: store.url, window: window,
                    // The nine verbs, wired to this window.
                    actions: TranslationRoundActions.production(
                        store: store, documentStore: documentStore,
                        projectURL: store.url, world: declaredWorld),
                    onClose: { publishCentre.clearRound() },
                    // Through `PublishCentreModel.publishSelection`, never
                    // straight in: a verb answers from a `Task` that outlives
                    // the press.
                    onRoundChanged: { updated in
                        publishCentre.adoptVerbAnswer(updated)
                    },
                    // **A row as a way back into the manuscript.** The row knows its
                    // paragraph; the round knows the chapter and edition; which
                    // chapter is OPEN is the window's answer, so the post carries all
                    // three and `TranslationReviewModifier` plans what to do.
                    onReveal: { paragraphId in
                        // The report gives way to the manuscript it points into —
                        // explicitly, since the arm draws over a chapter too and a
                        // same-chapter reveal makes no subject change.
                        publishCentre.clearRound()
                        TranslationReveal.post(.init(
                            docId: round.docId, language: round.language,
                            paragraphId: paragraphId))
                    })
            case .designGate(let proposal):
                DesignGateView(proposal: proposal, projectURL: store.url,
                               // The verdict's four verbs, wired to the window's own job
                               // manager and warm designer.
                               actions: designGateActions(projectURL: store.url),
                               hasOpenProposalRound: designer.hasOpenProposalRound,
                               // Deselecting is the whole of Back: the arm is a pure
                               // function of this one piece of window state.
                               onClose: { publishCentre.clearProposal() },
                               // …and the same state is how a verb's result reaches the
                               // surface: the gate holds the proposal as a VALUE and
                               // `approve` marks it approved on disk last, so without this
                               // write the gate would offer Approve over a live design.
                               // **Through the model's `publishSelection`, never straight
                               // in**: a verb answers from a `Task` that outlives the press.
                               onProposalChanged: { updated in
                                   publishCentre.adoptVerbAnswer(updated)
                               })
            case .books(let publications):
                PublishPreviewCentre(
                    publications: publications,
                    projectURL: store.url,
                    title: store.manifest.title,
                    selectedPublicationID: $publishCentre.selectedPublicationID)
            case .none:
                EmptyView()
            }
        }
    }

    /// **The gate's four verbs, wired to this window.** Closures rather than a
    /// store handed down (`DepartmentPane`'s rule): the gate reads no disk on a
    /// body path (tripwire 4), and each reaches something the window owns — the
    /// project's shared `CompileJobManager` (which `approve`/`revert` refuse
    /// against while a compile reads the publish tree) and the warm designer.
    ///
    /// **The job manager is resolved INSIDE each closure**, never here: this is
    /// called on a body path, and `PublishingStores.sharedFor` constructs four
    /// stores on its first call for a project.
    ///
    /// **Request Changes calls `DepartmentDesignRow.sendChanges`**, which the
    /// desk calls too — one spelling of the verb and its three refusals.
    private func designGateActions(projectURL: URL) -> DesignGateActions {
        DesignGateActions(
            approve: { proposal in
                await DesignGatePromotion.approve(
                    proposal, projectURL: projectURL,
                    jobManager: Self.compileJobs(for: projectURL))
            },
            revert: { proposal in
                await DesignGatePromotion.revert(
                    proposal, projectURL: projectURL,
                    jobManager: Self.compileJobs(for: projectURL))
            },
            finalize: { proposal in
                DesignGatePromotion.finalize(proposal, projectURL: projectURL)
            },
            requestChanges: { [designer] words in
                DepartmentDesignRow.sendChanges(words, to: designer)
            })
    }

    /// The project's ONE compile-job manager — the same instance every compile of
    /// this book contends on, which is the only thing that makes "a compile is
    /// running" answerable at all.
    private static func compileJobs(for projectURL: URL) -> CompileJobManager {
        PublishingStores.sharedFor(
            projectID: ProjectIdentifier.id(for: projectURL),
            projectURL: projectURL).jobManager
    }

    /// **Recount the board's open notes** — the one writer of
    /// `openNotesCounts`/`openNotesUnreadable`. ONE walk, not two:
    /// `listAnnotationsAcrossProject`'s cache KEY stats every closed document's
    /// op-log files, so the snapshot is read once and `openNotesSummaries(in:)`
    /// derives the counts from it. Called from the board's `.task` and from
    /// `.maughamAnnotationsChanged` — never from a `body`.
    private func refreshOpenNotes(store: ProjectStore) {
        let snapshot = store.listAnnotationsAcrossProject()
        openNotesCounts = store.openNotesSummaries(in: snapshot)
        openNotesUnreadable = Set(snapshot.unreadableDocIds)
    }

    /// **The one place the canvas is mounted in production.** Every route to the
    /// board reaches the SAME view identity through `centreRoute`'s `.canvas`
    /// case. A second mount would cost the writer's camera, layouts and
    /// thumbnails with nothing red, so the mount count is censused in
    /// `RegionBindingTests`. The token that census counts is deliberately not
    /// spelled in this comment.
    private func canvasCentre(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        CanvasView(model: canvasModel, projectRoot: store.url,
                   paletteSwatchHexes: { store.paletteSwatchHexes() },
                   // Spec §4: selecting in the tree changes what the canvas shows.
                   // Resolved HERE because telling a chapter from a group (or a live
                   // research id from a deleted one) needs the manifest, which the
                   // canvas does not hold — and this body re-evaluates per manifest
                   // change, the canvas's per drag frame.
                   subject: CanvasSubject.resolve(selectedSubject,
                                                  in: store.manifest.structure,
                                                  research: store.manifest.research),
                   // Spec §4.1: Escape is the keyboard spelling of the project row, so
                   // it writes the value that row's own `.tag` carries into the same
                   // `@State` on the same synchronous path — which makes the persisted
                   // UI state, the tree's highlight and the canvas's subject agree by
                   // construction. The canvas gets the ANSWER (`CanvasSubject`) and
                   // never the question.
                   selectTheProjectRow: { selectedSubject = .project },
                   itemIndex: ProjectWindow.canvasItemIndex(in: store),
                   // Spec §4.2: on a dimmed board a region bound to another document
                   // draws that document's name. Resolved HERE for `itemIndex`'s
                   // reason; the canvas gets the ANSWER, never the manifest.
                   pieceTitles: ProjectWindow.canvasPieceTitles(in: store),
                   // The canvas's asset well: a photograph from the Finder or a
                   // browser is ingested into `canvas_assets/` here and nowhere else,
                   // so every route is a caller of the one pair.
                   assetIngest: CanvasAssetIngest(
                    file: { try await store.ingestCanvasAsset(fileURL: $0) },
                    image: { try await store.ingestCanvasAsset(image: $0) }),
                   // An inbox row dragged onto the canvas (spec §8A.4) — the store's
                   // third promote sibling. The only production site that hands the
                   // canvas a way to reach it; without it the drag springs back silently.
                   captureDrop: CanvasCaptureDrop(send: { entryID, point in
                       try await documentStore.inboxStore.sendToCanvas(
                           entryID: entryID, projectStore: store,
                           placement: .dropped(at: point))
                   }))
        // Issue #44: a layout file this build refused says why, over the canvas
        // and outside its layer stack; not chrome, so ⌘\ keeps it.
        .safeAreaInset(edge: .top) {
            if let refusal = canvasModel.sidecarRefusal {
                CanvasReadOnlyNotice(refusal: refusal,
                                     startFreshLayout: { try canvasModel.startFreshLayout() })
            }
        }
    }
}

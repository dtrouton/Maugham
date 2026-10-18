import SwiftUI
import MaughamCore
import AppKit

/// **The window's centre column** (foundations plan 4, Task 4): the switch
/// over `ProjectWindow.centreRoute(…)` and every surface it mounts — the
/// palette wall, a research subject, the canvas, a Collection's reference
/// placeholder, and the manuscript editor with altitude and one cover over it.
///
/// It was four builders inside `ProjectWindow`, reading the window's `@State`
/// directly. It is a view of its own so the centre's code can be read without
/// the other three thousand lines, and it owns exactly one piece of state: the
/// review board's open-notes counts, which nothing outside this column reads.
///
/// **Everything else is the window's, handed down.** Each `@State` this column
/// WRITES arrives as a `Binding` (tripwire 2: a copy would be a second value
/// that drifts from the first), each value it only READS arrives as a value,
/// and each of the window's verbs arrives as a closure — so the one writer of
/// `ActivePassMemory` and the one round deferral stay `ProjectWindow`'s. The
/// persona, the column visibility and the subject stay owned by the window.
///
/// **Mounted ONCE, where `contentColumn` used to call `editorPane`** — the
/// content column's root, beneath the same overlays and insets. SwiftUI sees
/// one `CentreColumn` node at that position in every state, and beneath it
/// the same `switch` it used to see inline, so `EditorHost` and the canvas
/// keep their identities across every route change exactly as before.
///
/// `canvasModel` is a `let`, and nothing here reads its `.scene`: the scene is
/// the canvas's to draw, and a reader keyed on it would re-run this body per
/// drag frame (tripwire 30).
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
    /// The drawing door's posture for one document (P3c Task 6).
    let posture: (_ docId: String) -> Posture

    /// **The board's open-notes column, computed OFF the body path** (M3 P2
    /// Task 9) — piece id → how many notes it still has open, and the pieces
    /// whose op logs could not be read.
    ///
    /// Held as state precisely because the count is a project-wide walk over
    /// every document, open or closed: asking for it inside `body` would put
    /// that walk on every redraw of a board that can hold hundreds of rows,
    /// which is why P1 deferred this column rather than counting on the row.
    /// `refreshOpenNotes()` is the one writer, and it runs from the board's own
    /// `.task` and from `.maughamAnnotationsChanged` — never from a body. It
    /// lived on the window until this column became a view; nothing outside
    /// the column reads it.
    @State private var openNotesCounts: [String: OpenNotesSummary] = [:]
    @State private var openNotesUnreadable: Set<String> = []

    var body: some View {
        editorPane(store: store, documentStore: documentStore)
    }

    /// **The canvas is ONE branch here, and every other branch is written so as
    /// not to become a second one.**
    ///
    /// `CanvasView`'s camera, scrap layouts, thumbnail cache, in-progress scrap
    /// edit and accessibility elements are all `@State` on the view —
    /// `CanvasModel`'s own doc comment says so from the other side ("what
    /// deliberately does not live here: camera, layouts…"). Two branches of a
    /// ViewBuilder conditional are two distinct `_ConditionalContent` arms, so a
    /// second arm that also mounts the board gives it a second identity and
    /// SwiftUI tears the first one down whenever the condition moves: camera
    /// back to origin at zoom 1, every layout re-measured, thumbnails emptied,
    /// `.onAppear` re-reading `canvas.md` and the sidecar.
    ///
    /// **Measured, not deduced** (macOS 26.5, 2026-08-02, on the `.canvas` ↔
    /// `.tree` segment flip that made the point before the strip died): with an
    /// arm apiece a camera at pan (−680, −420) / zoom 1.5 came back at pan
    /// `.zero` / zoom 1, the `CanvasEventNSView` was a different object and
    /// `load()` had run twice. That flip no longer exists — Plan has one left
    /// column — but the shape it taught is why the research arm above answers
    /// `.besideTheCanvas` in Plan rather than taking the centre, and why the
    /// mount is censused in `RegionBindingTests` rather than trusted.
    @ViewBuilder
    private func editorPane(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        // **One exhaustive answer, one switch** (foundations plan 4, Task 3).
        // `centreRoute` composes every decision this pane used to ask in turn —
        // the palette wall above everything (stage 2b Task 5; `PaletteWallModifier`
        // closes the wall on a subject change, this is the belt to its braces),
        // a research subject that takes the centre (in Plan it resolves to
        // `.besideTheCanvas` and never reaches here, so the board keeps its
        // identity), the canvas, the Collection reference, then the editor with
        // altitude and one cover. The cases are in the old chain's order, so the canvas
        // is still the third branch and still its only mount.
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

    /// **The manuscript editor, and the one surface drawn over it.**
    ///
    /// It was `existingEditorSwitch` — a `switch` over `BinderSegment` — until
    /// shell-finish stage 2b Task 7 took the enum. What is left mounts the
    /// editor on whatever document the tree names (a screenplay's `.fountain`
    /// included), with `CentreRoute`'s layers over it: the project at altitude
    /// (stage 3a Task 2), then one cover — Publish's no-book notice, Review's
    /// passes board (M3 P1 Task 6), or one of Publish's surfaces: the round
    /// report, the design gate, the compiled book (stage 3b Task 5, P4).
    ///
    /// **The host is the ZStack's FIRST child and present whatever covers it**
    /// (tripwire 6), and altitude is the SECOND, present whenever the subject
    /// names no document, whatever covers it. Until foundations plan 4 Task 3
    /// the covers were independent `if` layers here and the writer saw
    /// whichever came last; now `centreRoute` names the one on top and this
    /// body draws it with ONE switch. Neither shape would have survived as a branch of `editorPane`:
    /// two ViewBuilder branches are two view identities, so every project ↔
    /// chapter hop would unmount `EditorHost`, whose `.onDisappear` is
    /// `doc.close()` + `documentStore.unregister(path:)` + `loads.abandon()`,
    /// not a cleanup. Here the layers over it are the only things that come and go.
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
                // whose posture refuses the text is FORCED into review render
                // AND hard-locked (lockEditing) via `editorMembrane` mirrored
                // into the control (P3c Task 3).
                control: editorControl,
                // M3 P2 Task 8: a note written from the margin carries the pass
                // this piece is being reviewed through.
                //
                // Read off `uiState`, not this window's `@State` mirror of it,
                // even though the mirror is right here. The mirror exists for
                // the `outlineLayout` pattern's reason — immediate local
                // feedback — and is per WINDOW: a second window on the same
                // project records a pass through `updateUIState` and this
                // one's copy never hears about it. That is harmless for a
                // control's appearance and not harmless for a STAMP, which is
                // a durable write into the op log. The queue pane and the MCP
                // tools (`activeReviewPassId`) already read `uiState`, so this
                // is the third reader of one value rather than a second value.
                // The validity check against the project's live pass list is
                // `validatedActivePass`'s and is never re-spelled here.
                activeReviewPassId: { docId in
                    documentStore.uiState.activePassMemory.validatedActivePass(
                        forPiece: docId,
                        in: store.manifest.effectiveReviewPasses)
                }
            )
            // **The project at altitude** (stage 3a Task 2) — opaque, because
            // the host's "Select a document." placeholder is still mounted
            // underneath. Its own layer, ALWAYS at this position whatever covers
            // it, so a cover coming or going never remounts it: `OutlineTable`
            // holds the writers it read from the registry, its scroll position
            // and its column widths.
            if altitude {
                ProjectAltitudePane(
                    store: store,
                    layout: $outlineLayout,
                    selectedSubject: $selectedSubject,
                    title: store.manifest.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            // **The one cover, ONE switch** (foundations plan 4, Task 3). Which
            // surface is on top is `centreRoute`'s answer, never a layer
            // order. Every cover is a case of this switch rather than a branch
            // of `editorPane` for stage 3a's reason: two ViewBuilder branches
            // are two view identities, and `EditorHost.onDisappear` is
            // `doc.close()` + `unregister(path:)` + `loads.abandon()`.
            switch cover {
            // In Publish with no book, the notice says WHICH kind of nothing it
            // is (Denver's 2026-08-12 rulings 2 and 3), standing over the
            // corkboard — it takes no clicks — rather than replacing it.
            case .notice(let notice):
                PublishCentreNoticeBanner(notice: notice)
            // **Review's passes board** (M3 P1 Task 6) — the project level of
            // Review, over altitude. A chapter subject reaches neither:
            // `reviewCentreShowsBoard` composes `subjectShowsAltitude`.
            case .reviewBoard:
                // Values, not the store (tripwire 4): the board reads
                // `manifest` here, at the one mount, and nothing on its body
                // path can reach a document or the disk.
                ReviewBoardPane(
                    title: store.manifest.title,
                    structure: store.manifest.structure,
                    passes: store.manifest.effectiveReviewPasses,
                    // Values again, and these two are the reason the window
                    // holds them at all: they are a walk over every document in
                    // the project, so they are computed in `refreshOpenNotes`
                    // below and merely READ here (M3 P2 Task 9).
                    openNotes: openNotesCounts,
                    unreadableDocIds: openNotesUnreadable,
                    // **A count click widens the QUEUE and moves nothing
                    // else.** The right column takes the writer to the notes —
                    // in project scope, pointed at the piece they clicked — and
                    // the centre stays exactly where it was: the board is what
                    // Review shows, so the subject is not written here and
                    // neither is the persona (the ejection trap; the chip
                    // click above is the one that travels, because opening a
                    // chapter is what a chip MEANS).
                    onOpenNotes: { pieceId in
                        showInspector = true
                        detailSegment = .annotations
                        annotationScopeRequest = .project(focusPiece: pieceId)
                    },
                    // **A chip click is a SUBJECT write and nothing else**
                    // (Task 8). The window is already in Review — the board is
                    // what Review shows — so moving the persona here would be
                    // the board deciding which persona is showing, which is
                    // the ejection trap `TripwireGrepTests`' persona-decision
                    // census names. Opening the chapter drops the subject
                    // below `reviewCentreShowsBoard`, so the board uncovers
                    // the host that was mounted underneath it all along; no
                    // arm is torn down.
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
                    // **A chip's round is three acts, and the third one waits**
                    // (M4 P2 Task 4). The lane is recorded through the window's
                    // ONE `ActivePassMemory` writer — the same private method
                    // the chip click and the cockpit's picker use, because the
                    // run reads that value to sign and file its notes — then
                    // the subject travels to the piece, exactly as `onNavigate`
                    // above does.
                    //
                    // And then it WAITS. `runRequested` refuses in silence
                    // while the document is not open, and the open is async: a
                    // run fired on this turn would do nothing at all, with no
                    // error anywhere (`RunWhenDocumentOpens`' doc, and the
                    // falsification test it names).
                    onRunRound: { pieceId, passId in
                        recordActivePass(pieceId, passId)
                        selectedSubject = .item(pieceId)
                        runRoundWhenPieceOpens(pieceId)
                    },
                    // **Each chip asks its own piece** (P3c Task 6): the
                    // drawing door, per row, so a demotion re-renders the
                    // board with no reopen.
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
            // **Publish's surfaces** (stage 3b Task 5, P4 Task 5, translation
            // pipeline P4 Task 3), in `publishCentre`'s order: the round report
            // (which alone also draws over a chapter), the design gate, the
            // compiled book. The gate and the book are project-level by
            // construction — `publishCentre` composes `subjectShowsAltitude`.
            case .translationRound(let round):
                TranslationRoundReportHost(
                    round: round, store: store, documentStore: documentStore,
                    projectURL: store.url, window: window,
                    // The nine verbs, wired to this window (P4 Task 4).
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
                    // **A row as a way back into the manuscript** (P4 Task 5).
                    // The row knows its own paragraph; the round knows the
                    // chapter and the edition it belongs to; which chapter is
                    // OPEN is the window's answer, so the post carries all three
                    // and `TranslationReviewModifier` plans what to do with them.
                    onReveal: { paragraphId in
                        // The report gives way to the manuscript it points
                        // into. It used to be dismissed by the subject change a
                        // cross-chapter reveal makes; now that the arm draws
                        // over a chapter too, the dismissal is explicit and
                        // covers the same-chapter reveal as well.
                        publishCentre.clearRound()
                        TranslationReveal.post(.init(
                            docId: round.docId, language: round.language,
                            paragraphId: paragraphId))
                    })
            case .designGate(let proposal):
                DesignGateView(proposal: proposal, projectURL: store.url,
                               // The verdict's four verbs (P4 Task 6), wired to
                               // the window's own job manager and warm designer.
                               actions: designGateActions(projectURL: store.url),
                               hasOpenProposalRound: designer.hasOpenProposalRound,
                               // Deselecting is the whole of Back: the arm is a
                               // pure function of this one piece of window
                               // state, so dropping it hands the column back to
                               // whatever the book's own rule answers.
                               onClose: { publishCentre.clearProposal() },
                               // …and the same piece of state is how a verb's
                               // result reaches the surface. The gate holds the
                               // proposal as a VALUE and `approve` marks it
                               // approved on disk as its last step, so without
                               // this write the gate would go on offering
                               // Approve over a design already live.
                               //
                               // **Through the model's `publishSelection`,
                               // never straight in**: a verb answers from a
                               // `Task` that outlives the press, and the writer
                               // is free to press Back or Show another round
                               // while it runs.
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

    /// **The gate's four verbs, wired to this window** (P4 Task 6).
    ///
    /// Closures rather than a store handed down, `DepartmentPane`'s rule: the
    /// gate reads no disk on a body path (tripwire 4), and every one of these
    /// reaches something that belongs to the window — the project's shared
    /// `CompileJobManager` (which is what `approve`/`revert` refuse against while
    /// a compile is reading the publish tree) and the warm designer session.
    ///
    /// **The job manager is resolved INSIDE each closure**, never here: this
    /// function is called from the centre column's switch, which is a body path,
    /// and `PublishingStores.sharedFor` constructs four stores on its first call
    /// for a project. Inside the closure it is paid once per press.
    ///
    /// **Request Changes calls `DepartmentDesignRow.sendChanges`, which is also
    /// what the desk calls** — one spelling of the orchestrator call and of the
    /// three refusals it can earn, since the two surfaces are the same verb
    /// reached from two columns.
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

    /// **Recount the board's open notes** (M3 P2 Task 9) — the one writer of
    /// `openNotesCounts`/`openNotesUnreadable`.
    ///
    /// ONE walk, not two: `listAnnotationsAcrossProject` is cached, but its
    /// cache KEY stats every closed document's op-log files, so asking twice
    /// for the two halves of one refresh pays the aggregation's real cost
    /// twice. The snapshot is read here and `openNotesSummaries(in:)` derives
    /// the counts from it.
    ///
    /// Called from the board's `.task` and from `.maughamAnnotationsChanged` —
    /// never from a `body`. A false alarm (an announcement about a document
    /// with no notes) costs one cached read; a call per body would cost a walk
    /// per redraw, which is why P1 deferred this column in the first place.
    private func refreshOpenNotes(store: ProjectStore) {
        let snapshot = store.listAnnotationsAcrossProject()
        openNotesCounts = store.openNotesSummaries(in: snapshot)
        openNotesUnreadable = Set(snapshot.unreadableDocIds)
    }

    /// **The one place the canvas is mounted in production.**
    ///
    /// Named and extracted so that every route to the board reaches the SAME
    /// view identity through `editorRoute` (see `editorPane`) rather than an arm
    /// apiece. A second mount would give some other condition a canvas of its
    /// own, and the cost of that is the writer's camera, layouts and thumbnails
    /// with nothing red anywhere — so the mount count is censused in
    /// `RegionBindingTests`, beside the inspector arm's. The token that census
    /// counts is deliberately not spelled in this comment.
    private func canvasCentre(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        CanvasView(model: canvasModel, projectRoot: store.url,
                   paletteSwatchHexes: { store.paletteSwatchHexes() },
                   // Spec §4: selecting in the tree changes what the canvas
                   // shows. Resolved HERE because telling a chapter from a
                   // group needs `manifest.structure`, which the canvas does
                   // not hold and should not start holding — the same reason
                   // `itemIndex` below is built on this body path rather than
                   // on the canvas's, which re-evaluates per drag frame.
                   // The research tree rides beside the structure for the same
                   // reason (stage 3b): §4's research subject lights its own
                   // card, and telling a live research id from one whose note
                   // the writer deleted needs the manifest's other tree.
                   subject: CanvasSubject.resolve(selectedSubject,
                                                  in: store.manifest.structure,
                                                  research: store.manifest.research),
                   // Spec §4.1: Escape is the keyboard spelling of the project
                   // row, so it writes the value that row's own `.tag` carries
                   // (`BinderView.projectRow`) into the same `@State` on the
                   // same synchronous path. Not a state that resembles the
                   // row's — the same one, which is what makes the persisted UI
                   // state, the tree's highlight and the canvas's subject agree
                   // by construction. The canvas is handed this ask rather than
                   // a binding: it gets the ANSWER (`CanvasSubject`) and never
                   // the question.
                   selectTheProjectRow: { selectedSubject = .project },
                   itemIndex: ProjectWindow.canvasItemIndex(in: store),
                   // Spec §4.2: on a dimmed board a region bound to another
                   // document draws that document's name, so the writer can tell
                   // the rectangle a sweep will bind from the one where it will
                   // silently do nothing. Resolved HERE for `itemIndex`'s reason
                   // — the walk belongs on this body, which re-evaluates per
                   // manifest change, not on the canvas's, which re-evaluates per
                   // drag frame — and the canvas gets the ANSWER, never the
                   // manifest.
                   pieceTitles: ProjectWindow.canvasPieceTitles(in: store),
                   // The canvas's asset well (1C-d Task 11): a photograph
                   // dropped from the Finder or a browser is ingested into
                   // `canvas_assets/` here and nowhere else, so every route
                   // is a caller of the one pair rather than a storage
                   // decision of its own.
                   assetIngest: CanvasAssetIngest(
                    file: { try await store.ingestCanvasAsset(fileURL: $0) },
                    image: { try await store.ingestCanvasAsset(image: $0) }),
                   // An inbox row dragged onto the canvas (1C-d Task 12, spec
                   // §8A.4). The whole act is the store's third promote
                   // sibling; this is the only production site that hands the
                   // canvas a way to reach it, so its absence would be a drag
                   // that springs back with nothing said.
                   captureDrop: CanvasCaptureDrop(send: { entryID, point in
                       try await documentStore.inboxStore.sendToCanvas(
                           entryID: entryID, projectStore: store,
                           placement: .dropped(at: point))
                   }))
    }
}

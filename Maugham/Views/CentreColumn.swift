import SwiftUI
import MaughamCore
import AppKit

/// **The window's centre column**: the switch over
/// `ProjectWindow.centreRoute(…)` and every surface it mounts — the palette
/// wall, a research subject, a figure, the canvas, a Collection's reference
/// placeholder, the manuscript editor with the Book's view and one cover over
/// it, and the Inbox.
/// It owns exactly one piece of state: the review board's open-notes counts,
/// which nothing outside this column reads.
///
/// **Everything else is the window's, handed down.** Each `@State` this column
/// WRITES arrives as a `Binding` (tripwire 2: a copy would be a second value
/// that drifts from the first), each value it only READS arrives as a value,
/// and each of the window's verbs arrives as a closure — so the one writer of
/// `ActivePassMemory` and the one round deferral stay `ProjectWindow`'s. The
/// subject, the column visibility and the Book's view stay owned by the window.
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
    /// The window's reference index (report plan 8a Task 2), handed to the
    /// manuscript editor; read nowhere here.
    let referenceIndex: ReferenceIndexHost
    /// The window's figure rows (report plan 8a), read by the figure route.
    let figureListing: FigureListingModel
    /// The window's table-grid presence (report plan 7c Task 9), handed to
    /// the manuscript editor's grid opening and the figure route's grid.
    let figureGridPresence: FigureGridPresence
    /// The project's figure windows (plan 7d Task 9), handed to the same
    /// opening and the figure route's grid (one grid per host).
    let figureWindows: FigureWindows?
    @Bindable var publishCentre: PublishCentreModel
    let designer: DesignerOrchestrator
    let declaredWorld: DeclaredWorldStore?
    /// The bible a statement in the centre draws its readings from.
    let bible: BibleStore?
    let window: NSWindow?

    // Inputs this column only reads. `isLocked` is the window's Lock
    // (`WindowLock`): research, palette cards and figures read, never edit.
    let isLocked: Bool
    let researchPreviewVisible: Bool
    /// The tree's find overlay is up: Esc is its own, before the centre
    /// item's cover (`CentreItemEscape`).
    let treeFindActive: Bool

    // The window's state this column writes — bindings, never copies.
    /// The window's subject: the route's one input about what is open.
    @Binding var subject: WindowSubject
    /// A statement or a piece's History open in the centre — the
    /// `.centreItem` cover (shell plan 3 Task 5). The cover's Close writes
    /// nil; the window clears it when `open` moves.
    @Binding var centreItem: CentreItem?
    @Binding var bookView: BookView
    @Binding var selectedPaletteCardId: String?
    @Binding var showInspector: Bool
    @Binding var detailSegment: DetailSegment
    /// To resolve's next ask (shell plan 2 Task 7) — the board's open-notes
    /// click focuses the clicked piece's group.
    @Binding var resolveRequest: ResolveRequest?
    @Binding var metrics: EditorMetrics
    @Binding var currentElement: String?

    // The window's verbs.
    /// The wall's own Close — `PaletteWallState.closingWall`, the window's.
    let closePaletteWall: () -> Void
    /// `ProjectWindow.recordActivePass(forPiece:passId:)` — the ONE writer of
    /// `UIState.activePassMemory`, which the run reads to sign its notes.
    let recordActivePass: (_ piece: String, _ passId: String) -> Void
    /// `ProjectWindow.runRoundWhenPieceOpens(pieceId:)` — the bounded wait for
    /// a piece to open before a chip's round runs.
    let runRoundWhenPieceOpens: (_ pieceId: String) -> Void
    /// The drawing door's posture for one document.
    let posture: (_ docId: String) -> Posture
    /// The tree's Tab from the binder (`CanvasView.keyboardRequest`) and the
    /// canvas's ⇧Tab back (`CanvasView.returnKeyboardToTree`; nil where no
    /// visible binder answers it).
    let canvasKeyboardRequest: Int
    let returnKeyboardToTree: (() -> Void)?

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
    /// why a click on research or a piece while the canvas is open moves the
    /// subject's `beside` or `faces` and never its `open`, and why the mount is
    /// censused in `RegionBindingTests`.
    @ViewBuilder
    private func editorPane(
        store: ProjectStore, documentStore: DocumentStore
    ) -> some View {
        // **One exhaustive answer, one switch.** `centreRoute` composes every
        // decision from the subject: the palette wall, a research item or a
        // figure in `open`, the canvas, the Collection reference, the editor
        // with the Book's view and one cover, then the Inbox. The canvas is the
        // fourth branch and its only mount; the Inbox is last so adding it moved
        // no branch.
        switch ProjectWindow.centreRoute(subject: subject,
                                         bookView: bookView,
                                         projectType: store.manifest.type,
                                         structure: store.manifest.structure,
                                         preview: publishCentre.preview,
                                         proposal: publishCentre.selectedProposal,
                                         round: publishCentre.selectedRound,
                                         problems: publishCentre.selectedProblems,
                                         centreItem: centreItem) {
        case .paletteWall:
            PaletteWallCentre(store: store, selectedPaletteCardId: $selectedPaletteCardId,
                              onClose: closePaletteWall, isLocked: isLocked)
        case .research(let id):
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: id, previewVisible: researchPreviewVisible,
                                  readOnly: WindowLock.refusesEdits(isLocked: isLocked),
                                  shareIsReadOnly: editorControl.shareIsReadOnly,
                                  typography: editorControl.typography,
                                  presence: figureGridPresence, window: window)
        case .figure(let id):
            FigureSubjectSurface(
                figureID: id, store: store, documentStore: documentStore, figureWindows: figureWindows,
                presence: figureGridPresence, listing: figureListing, control: editorControl,
                isLocked: isLocked, window: window)
        case .canvas:
            canvasCentre(store: store, documentStore: documentStore)
        case .reference(let piece):
            ReferencePlaceholderCard(piece: piece) {
                openReferenceInWindow(piece: piece, store: store)
            }
        case .editor(let altitude, let cover):
            manuscriptEditor(store: store, documentStore: documentStore,
                             altitude: altitude, cover: cover)
        case .inbox:
            // The captures, as the centre. The fast "Promote to Research for
            // [title]" path targets the piece the faces are on.
            InboxPane(store: documentStore.inboxStore, projectStore: store,
                      activeDocumentId: subject.faces.itemID,
                      canTranscribe: InboxPane.localTranscriptionAvailable,
                      retranscribe: { entry in Task { await documentStore.retranscribe(entry) } })
        }
    }

    /// **A card, a row or a chip pointing the window at a piece**:
    /// `ClickRule.navigate`, so a piece clicked while the Book is open opens it.
    private func navigate(to target: BinderSubject?, store: ProjectStore) {
        let next = ClickRule.navigate(to: target, current: subject,
                                      structure: store.manifest.structure,
                                      projectType: store.manifest.type)
        if next != subject { subject = next }
    }

    /// The Book's views' selection: the faces, written through `navigate`.
    private func facesNavigation(store: ProjectStore) -> Binding<BinderSubject?> {
        Binding(get: { subject.faces }, set: { navigate(to: $0, store: store) })
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
    /// mounts on whatever document the subject's `open` names (a screenplay's
    /// `.fountain` included), with `CentreRoute`'s layers over it: the Book (or
    /// a Part) in its view — Cards, Outline or Status — then one cover: an
    /// edition's (no-book notice, round report, problems, design gate, book),
    /// else a statement or a piece's History open in the centre.
    ///
    /// **The host is the ZStack's FIRST child and present whatever covers it**
    /// (tripwire 6), and altitude is the SECOND, present whenever `open`
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
        altitude: BookView?, cover: CentreCover?
    ) -> some View {
        ZStack {
            EditorHost(
                store: store,
                documentStore: documentStore,
                // What is OPEN, never what the faces are on: under an edition
                // the faces may sit on a piece the centre does not show.
                selectedItemId: subject.open.itemID,
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
                referenceIndex: referenceIndex,
                figureGridPresence: figureGridPresence,
                figureWindows: figureWindows,
                figureListing: figureListing,
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
            // **The Book in its view** — opaque, because the host's "Select a
            // document." placeholder is still mounted underneath. Its own layer,
            // ALWAYS at this position whatever covers it, so a cover coming or
            // going never remounts it: `OutlineTable` holds the writers it read
            // from the registry, its scroll position and its column widths. Which
            // view (Cards, Outline, Status) is the route's associated value.
            if let altitude {
                let scope = ProjectWindow.altitudeScope(
                    open: subject.open, structure: store.manifest.structure,
                    bookTitle: store.manifest.title)
                ProjectAltitudePane(
                    store: store,
                    view: altitude,
                    bookView: $bookView,
                    selectedSubject: facesNavigation(store: store),
                    title: scope.title,
                    structure: scope.structure,
                    offersStatus: subject.open.isEdition == false) {
                    statusBoard(store: store, structure: scope.structure)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            // **The one cover, ONE switch.** Which surface is on top is
            // `centreRoute`'s answer, never a layer order — and a case of this
            // switch, never a branch of `editorPane`, for the identity reason
            // above.
            switch cover {
            // An edition with no book: the notice says WHICH kind of nothing it
            // is (Denver's 2026-08-12 rulings 2 and 3), standing over the Book's
            // view — it takes no clicks — rather than replacing it.
            case .notice(let notice):
                PublishCentreNoticeBanner(notice: notice)
            // **An edition's surfaces**, in `publishCentre`'s order: the publish
            // problems, the round report, the design gate, the compiled book —
            // each only while `open` is an edition.
            case .publishProblems(let problems):
                PublishProblemsView(
                    rows: PublishProblems.rows(
                        problems,
                        titles: PublishProblems.titles(in: store.manifest.structure)),
                    onClose: { publishCentre.clearProblems() },
                    // **The round report's `onReveal` sequence**: the list gives
                    // way to the manuscript it points into — explicitly, since
                    // the arm draws over a chapter too — then the reveal
                    // selects, waits and scrolls, in the source (no language)
                    // or in the edition whose body held the problem (R-S14).
                    // A problem with no paragraph opens its piece.
                    onReveal: { row in
                        publishCentre.clearProblems()
                        switch PublishProblems.reveal(row) {
                        case .paragraph(let reveal):
                            TranslationReveal.post(reveal)
                        case .piece(let piece):
                            ManuscriptNavigation.go(
                                to: PublishProblems.destination(
                                    revealing: piece, current: subject,
                                    structure: store.manifest.structure,
                                    projectType: store.manifest.type),
                                subject: $subject, centreItem: $centreItem)
                        }
                    })
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
            // **A statement or a piece's History in the centre**, over the
            // host and the Book's view like every cover, so neither remounts
            // when it comes or goes. Close clears the window's item.
            case .centreItem(let item):
                CentreItemCover(store: store, documentStore: documentStore, item: item,
                                bible: bible, world: declaredWorld,
                                window: window, findIsUp: treeFindActive,
                                onClose: { closeCentreItem() })
            case .none:
                EmptyView()
            }
        }
        // **The keys under a cover** (review C1): while altitude or an opaque
        // cover hides the host, its text view never holds the keys; the centre
        // item's cover claims them for its own editor (or itself).
        .background(CentreKeys(isCovered: { editorIsCovered(store: store) },
                               claim: CentreItemCover.claim(for: cover)))
    }

    /// **Whether the editor is covered now** — the route asked again, live,
    /// at focus time (a navigation clears the centre item and lands its caret
    /// in one turn, before a redraw). The same call `editorPane` switches on.
    private func editorIsCovered(store: ProjectStore) -> Bool {
        let route = ProjectWindow.centreRoute(subject: subject,
                                              bookView: bookView,
                                              projectType: store.manifest.type,
                                              structure: store.manifest.structure,
                                              preview: publishCentre.preview,
                                              proposal: publishCentre.selectedProposal,
                                              round: publishCentre.selectedRound,
                                              problems: publishCentre.selectedProblems,
                                              centreItem: centreItem)
        guard case .editor(let altitude, let cover) = route else { return false }
        return ProjectWindow.coverHidesTheEditor(cover: cover, altitude: altitude)
    }

    /// **Close** (the cover's button, or Esc): the item goes, and the keys go
    /// back to the manuscript editor if the centre now shows it.
    private func closeCentreItem() {
        centreItem = nil
        CentreKeys.returnKeysToTheManuscript(in: window)
    }

    /// **The Book's Status view: the passes board** — over the Book's pieces,
    /// or a Part's own. Its one mount; `ProjectAltitudePane` places it.
    @ViewBuilder
    private func statusBoard(store: ProjectStore, structure: [StructureItem]) -> some View {
        // Values, not the store (tripwire 4): the board reads `manifest` here,
        // at the one mount, and nothing on its body path can reach a document
        // or the disk.
        ReviewBoardPane(
            title: store.manifest.title,
            structure: structure,
            passes: store.manifest.effectiveReviewPasses,
            // Values again: a walk over every document, computed in
            // `refreshOpenNotes` and merely READ here.
            openNotes: openNotesCounts,
            unreadableDocIds: openNotesUnreadable,
            // **A count click points To resolve at the piece and moves
            // nothing else.** The right column goes to To resolve — the Book's
            // list, grouped by piece — with the clicked piece's group focused;
            // the subject is not written here. The chip click is the one that
            // travels, because opening a chapter is what a chip MEANS.
            onOpenNotes: { pieceId in
                showInspector = true
                detailSegment = .resolve
                resolveRequest = .focus(groupOwnerId: pieceId)
            },
            // **A chip click is a SUBJECT write and nothing else**, through the
            // click rule: a piece clicked while the Book is open opens it, which
            // takes `open` off the Book and uncovers the host that was mounted
            // underneath all along; no arm is torn down.
            onNavigate: { pieceId, passId in
                navigate(to: .item(pieceId), store: store)
                recordActivePass(pieceId, passId)
            },
            // The board's write, at the board's HOST — the same place and the
            // same shape as the pass ladder's, which lands at `InspectorView` and
            // `PieceInspector` rather than inside `PassLadder`
            // (`PassStateWriterCensusTests`).
            onSetState: { pieceId, passId, state in
                Task { try? await store.setPassState(id: pieceId, passId: passId, state) }
            },
            // **A chip's round is three acts, and the third one waits.** The lane
            // is recorded through the window's ONE `ActivePassMemory` writer (the
            // run reads it to sign and file its notes), then the subject travels,
            // as `onNavigate` does. Then it WAITS: `runRequested` refuses in
            // silence while the document is not open, and the open is async
            // (`RunWhenDocumentOpens`' doc).
            onRunRound: { pieceId, passId in
                recordActivePass(pieceId, passId)
                navigate(to: .item(pieceId), store: store)
                runRoundWhenPieceOpens(pieceId)
            },
            // **Each chip asks its own piece**: the drawing door, per row, so a
            // demotion re-renders the board with no reopen.
            posture: posture)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The counts are read HERE and never in the board's body: one
            // project-wide walk when the board appears, and one per announced
            // annotation change. `.task` is cancelled and re-run on identity, so
            // a board uncovered by a view switch recounts on arrival.
            .task { refreshOpenNotes(store: store) }
            .onProjectEvent(.maughamAnnotationsChanged,
                            url: store.url, window: window) { _ in
                refreshOpenNotes(store: store)
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
        openNotesUnreadable = store.openNotesUnreadable(in: snapshot)
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
                   // The part clicked last — the faces or what is opened beside
                   // (`WindowSubject.besideIsLatest`): a click on a piece moves the
                   // faces while the canvas keeps the centre, and lights its region
                   // even with a note still beside.
                   subject: CanvasSubject.resolve(subject.lastClicked,
                                                  in: store.manifest.structure,
                                                  research: store.manifest.research),
                   // Spec §4.1: Escape is the keyboard spelling of the project row, so
                   // it writes the value that row's own `.tag` carries into the same
                   // `@State` on the same synchronous path — which makes the persisted
                   // UI state, the tree's highlight and the canvas's subject agree by
                   // construction. The canvas gets the ANSWER (`CanvasSubject`) and
                   // never the question.
                   // Not through the click rule, which would open the Book over
                   // the canvas: the faces go to the Book and the canvas stays.
                   selectTheProjectRow: {
                       subject.faces = .project
                       subject.beside = nil
                   },
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
                   captureDrop: CanvasCaptureDrop(send: { entryID, point, piece in
                       try await documentStore.inboxStore.sendToCanvas(
                           entryID: entryID, projectStore: store,
                           placement: .dropped(at: point, wrappingInPiece: piece))
                   }),
                   // Spec §1: Tab in Plan's binder gives the canvas the keyboard,
                   // and ⇧Tab gives it back.
                   keyboardRequest: canvasKeyboardRequest,
                   returnKeyboardToTree: returnKeyboardToTree)
        // Issue #44: a layout file this build refused says why, over the canvas
        // and outside its layer stack; not chrome, so ⌘\ keeps it.
        .safeAreaInset(edge: .top) {
            if let refusal = canvasModel.sidecarRefusal {
                CanvasReadOnlyNotice(refusal: refusal,
                                     startFreshLayout: { try canvasModel.startFreshLayout() },
                                     tryAgain: { canvasModel.retryUnreadable() })
            }
        }
    }
}

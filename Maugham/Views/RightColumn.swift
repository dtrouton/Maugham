import SwiftUI
import MaughamCore
import AppKit

/// **The window's right-hand column**: the resize handle on its leading edge
/// and its drag, then `pane` — the three positions' control
/// (`RightColumnControl`) over the one arm `RightColumnContent.of` names: To
/// resolve (or, interim, the translation review or the Department desk),
/// Brief, and the pulled-up thing (`PulledUpView`, which also draws the
/// centre's own details) — plus the one width applied to both the content's
/// frame and the split item, and the hidden arm when the column is closed. It
/// owns exactly one piece of state: the drag's starting width.
///
/// **Everything else is the window's, handed down** — `CentreColumn`'s shape.
/// Each `@State` this column WRITES arrives as a `Binding` (tripwire 2: a copy
/// would be a second value that drifts from the first), each value it only
/// READS arrives as a value, and each of the window's verbs arrives as a
/// closure — so the one writer of `ActivePassMemory`, Project Settings' one
/// presentation and Open's routing stay `ProjectWindow`'s.
///
/// **One width, as a VALUE.** `width` is the effective width the window bound
/// once (`ProjectWindow.detailColumn`), and it is the only width this column
/// lays out with; `detailColumnWidth` is the writer's persisted wish, which the
/// handle alone writes and the window alone reads into that sum.
///
/// **Mounted ONCE, as the detail column's root**, so the handle and the pane
/// keep their identities across every position and subject change.
///
/// `canvasModel` is a `let`, and nothing here reads its `.scene`: the region
/// inspector resolves the selection one leaf down (tripwire 30).
struct RightColumn: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let projectRoot: URL
    let canvasModel: CanvasModel
    let editorControl: EditorControl
    /// The window's figure rows, read by the figure arm and its inspector.
    let figureListing: FigureListingModel
    /// The window's table-grid presence and the project's figure windows,
    /// for the figure grid beside the canvas (report plan 8a Task 6).
    let figureGridPresence: FigureGridPresence
    let figureWindows: FigureWindows?
    /// The project window, whose Format ▸ Table posts reach that grid.
    let window: NSWindow?
    let publishCentre: PublishCentreModel
    /// The project's services, injected into the panes' environment at
    /// `pane`.
    let roster: AgentRoster
    let bible: BibleStore?
    let declaredWorld: DeclaredWorldStore?

    // The window's state this column only reads.
    /// The window's Lock (`WindowLock`): research and figures read, never edit.
    let isLocked: Bool
    /// The window's subject. This column is about its `faces` (the document
    /// the panes follow) and shows what is opened `beside`, whose Open in
    /// Centre and close controls write it — a `Binding`, never a copy.
    @Binding var subject: WindowSubject
    let isNoChromeOn: Bool
    let showInspector: Bool
    /// The EFFECTIVE width, bound once by the window — see the type comment.
    let width: Double
    /// The window content's measured width, for the drag's ceiling.
    let containerWidth: Double?

    // The window's state this column writes — bindings, never copies.
    /// The writer's persisted wish; written by the handle's drag alone.
    @Binding var detailColumnWidth: Double
    @Binding var selectedSubject: BinderSubject?
    /// Which of the three positions shows (`ProjectWindow.rightColumnPosition`).
    @Binding var position: RightColumnPosition
    /// To resolve's next ask — a filter or a piece to focus (shell plan 2
    /// Task 7); `ResolvePane` applies it once and sets it back to nil.
    @Binding var resolveRequest: ResolveRequest?
    /// The window's parsed screenplay, for To resolve's scene grouping.
    let lastParsedScript: FountainScript?
    @Binding var compilerModel: CompilerModelChoice

    // The window's verbs.
    /// `ProjectWindow.recordActivePass(forPiece:passId:)` — the ONE writer of
    /// `UIState.activePassMemory`, which the run reads to sign its notes.
    let recordActivePass: (_ piece: String, _ passId: String) -> Void
    /// `ProjectWindow.openProjectSettings()`.
    let openProjectSettings: () -> Void
    /// `ProjectWindow.openPromotedArtifact(_:)` — Open on a promoted card.
    let openPromotedArtifact: (_ itemId: String) -> Void
    /// `ProjectWindow.showStrain` — a solid mark's click in Brief.
    var showStrain: (ResolveRequest) -> Void = { _ in }
    /// `ProjectWindow.openBrief` — the faces move to the subject and Brief
    /// shows it (a filed line's link, a Part's or the Book's piece).
    var openBrief: (BinderSubject) -> Void = { _ in }
    /// Whether the tree's Figures section draws a figure
    /// (`BinderTreeSectionsState.drawsFigure`), for To resolve's figure click.
    var drawsFigure: (String) -> Bool = { _ in false }
    /// `BinderTreeSectionsState.revealFigure`, before a figure travel lands.
    var revealFigure: (String) -> Void = { _ in }
    /// The window's tree, whose cards pace the figure inspector's pin reads.
    var figureTree: BinderTreeSectionsState? = nil
    /// The window's centre item: a pulled-up statement the cover holds reads
    /// a placeholder (`PulledUpView`).
    var centreItem: CentreItem? = nil
    /// `ProjectWindow.openInCentre` — Open in Centre on a pulled-up statement
    /// or History.
    var openInCentre: (CentreItem) -> Void = { _ in }
    /// The palette wall's selected card (`ProjectWindow.selectedPaletteCardId`):
    /// pulled up while the wall shows it, a card reads beside, never edits.
    var paletteWallCard: String? = nil

    /// The drag's starting width, so the gesture reads its own translation
    /// rather than accumulating.
    @State private var detailDragStartWidth: Double?

    /// **One width, held.** The right column is pinned to the writer's own
    /// width and resized by the handle below — it does NOT declare a range.
    /// `navigationSplitViewColumnWidth(min:ideal:max:)` declares a range, and
    /// AppKit re-resolves inside it whenever something re-proposes — a wider
    /// pane pushes it to `max`, a `columnVisibility` transition drops it on
    /// `min` (both measured in `DetailColumnWidthTests`).
    ///
    /// **The single-argument spelling is necessary and, since macOS 27, not
    /// sufficient — so the width is applied TWICE, to the content's frame as
    /// well as to the column.** On macOS 27 the column resolves to `max(w, the
    /// pane's own minimum)` (see
    /// `docs/superpowers/notes/2026-09-19-split-view-tie-break-spike.md`);
    /// framing the content leaves the pane no minimum to contribute, so the
    /// guarantee stops depending on how Apple breaks a tie. It is the pane's
    /// FLOOR that wins, never its ideal.
    ///
    /// `test_theFixedColumnWinsAgainstAnUnbreakablePane` keeps the guarantee,
    /// `test_plantedOffender_anUnframedPaneTakesTheColumn` keeps the mechanism
    /// measurable, and `test_theRightColumnFramesItsContentToTheWidthItDeclares`
    /// ties this file to them — without it, fixing only the harness turns every
    /// mounted test green while this file ships the broken spelling. Provoking
    /// any of this wants a `.fixedSize()` in the harness.
    ///
    /// A fixed column's own divider is inert, so the column brings its own
    /// handle. What is applied is the **effective** width; see
    /// `effectiveDetailColumnWidth` for why the reduction never reaches the
    /// stored value.
    @ViewBuilder
    var body: some View {
        if showInspector {
            // **Bound once, applied twice** — to the content's frame and to the
            // column. `width` is the ONE effective width the window bound
            // (`ProjectWindow.detailColumn`); `DetailColumnWidthTests` counts the
            // window's binding and expects exactly one.
            HStack(spacing: 0) {
                detailResizeHandle(documentStore: documentStore)
                pane
            }
            // **The frame is what holds the column on macOS 27**, not the
            // modifier below it (see the doc comment above).
            //
            // `.clipped()` is NOT what holds it — every test here is green without
            // it (the spike note). It is here so that a pane whose content cannot
            // break DRAWS inside its column instead of over the prose. Nothing
            // guards it; this comment is why it stays.
            //
            // **Leading, not centred** (#122). A centred frame put the overflow
            // of a too-wide pane on BOTH sides, so the clip cut the pane's
            // leading edge and pushed the resize handle out of reach. Leading
            // keeps the handle and the pane's start where they belong and spends
            // any overflow on the trailing edge alone. This is the safety net;
            // the rule is that every pane fits (`RightColumnPaneWidthTests`).
            .frame(width: width, alignment: .leading)
            .clipped()
            .navigationSplitViewColumnWidth(width)
        } else {
            ProjectWindow.hiddenDetailColumn
        }
    }

    /// **The panes' document is the FACES', never what is open** — with the
    /// canvas or an edition in the centre, the faces are on the piece the
    /// writer last clicked, and that is what To resolve and Brief are about.
    static func panesDocId(of subject: WindowSubject) -> String {
        BinderSubject.activeDocId(for: subject.faces)
    }

    /// The structure item the panes follow — the faces', `nil` for the Book.
    static func panesItemID(of subject: WindowSubject) -> String? {
        subject.faces.itemID
    }

    /// The resize handle's gutter. A pane gets the column's width less this,
    /// so the narrowest a pane is ever drawn is
    /// `UIState.detailColumnWidthRange.lowerBound - resizeHandleWidth`.
    static let resizeHandleWidth: CGFloat = 8

    /// The right column's own resize affordance, on its leading edge.
    ///
    /// **A gutter in the layout rather than an overlay over the pane**: a
    /// `contentShape`d strip laid *over* the pane silently swallows every click
    /// in the leftmost 8pt of the column, for the whole height of the window.
    /// Deliberately not drawn — the split view's divider is still the seam a
    /// writer aims at; the resize cursor on hover says this is here.
    ///
    /// Live during the gesture and persisted only at its end — a `UIState` write
    /// per drag frame is 60 a second through the manuscript's own debounce.
    ///
    /// **Nothing else writes this width.** A fixed column has no geometry of its
    /// own to report (the window's measured width is never persisted), which
    /// makes `test_aPaneSwitchDoesNotWriteTheWidth` structurally true rather
    /// than a debounce racing a subject change.
    private func detailResizeHandle(documentStore: DocumentStore) -> some View {
        Color.clear
            .frame(width: Self.resizeHandleWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = detailDragStartWidth ?? detailColumnWidth
                        detailDragStartWidth = start
                        // Every rule this drag obeys — the leading edge's sign,
                        // the column's range, and what this window can afford —
                        // lives in the pure function, where a test can reach it.
                        detailColumnWidth = ProjectWindow.draggedDetailColumnWidth(
                            startWidth: start,
                            translation: value.translation.width,
                            containerWidth: containerWidth)
                    }
                    .onEnded { _ in
                        detailDragStartWidth = nil
                        let width = detailColumnWidth
                        documentStore.updateUIState { $0.detailColumnWidth = width }
                    })
    }

    /// **The control over the one arm the table names** — everything this
    /// column draws beside its handle. Not `private`: the width and height
    /// censuses measure it at a pane's width, without the split item's frame.
    var pane: some View {
        VStack(spacing: 0) {
            RightColumnControl(
                store: store, position: $position, subject: subject,
                diagnostics: roster.compiler.diagnostics,
                width: CGFloat(width) - Self.resizeHandleWidth)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // **The project's services reach the panes through the environment**
        // — the window's roster (the session's, or the unconfigured
        // placeholder before load) and the session's bible and declared world.
        .environment(roster)
        .environment(bible)
        .environment(declaredWorld)
        // Populate the inbox from window open, so the tree's Inbox row is
        // drawn for a project whose captures synced in while it was shut.
        // Presenter changes (`DocumentStore`'s `.inbox` arm) keep it fresh.
        // (The pane picker ran this; it moved here with the column.)
        .task { await documentStore.inboxStore.refresh() }
        // Entering translation review shows it: the review is To resolve's
        // own answer while it is on. Leaving moves nothing.
        .onChange(of: editorControl.translationLanguage) { _, lang in
            if lang != nil { position = .resolve }
        }
    }

    /// What the column shows now — the table's one answer.
    private var shown: RightColumnContent {
        RightColumnContent.of(position: position, subject: subject,
                              translationLanguage: editorControl.translationLanguage,
                              structure: store.manifest.structure,
                              projectType: store.manifest.type)
    }

    /// **One `switch` over `RightColumnContent`, exhaustive, no `default`**:
    /// a new answer cannot compile without an arm here.
    @ViewBuilder
    private var content: some View {
        switch shown {
        case .resolve:
            resolvePane
        case .translationReview:
            translationPane
        case .desk:
            RightColumnDesk(store: store, documentStore: documentStore,
                            subject: selectedSubject, publishCentre: publishCentre)
        case .brief(let scope):
            BriefPane(
                store: store, documentStore: documentStore, scope: scope,
                diagnostics: roster.compiler.diagnostics, bible: bible, world: declaredWorld,
                centreItem: centreItem,
                onOpenInCentre: openInCentre,
                onPullUp: { subject = ClickRule.pullUp($0, current: subject) },
                onShowStrain: showStrain,
                onOpenBrief: openBrief,
                // The desk is To resolve's answer while an edition is the
                // faces — and an edition's Brief shows only then.
                onOpenDesk: { _ in position = .resolve })
        case .pulledUp, .centreDetails, .nothingPulledUp:
            // One mount for the three: the view asks the subject which.
            PulledUpView(
                store: store, documentStore: documentStore, subject: $subject,
                centreItem: centreItem, canvasModel: canvasModel,
                editorControl: editorControl, figureListing: figureListing,
                figureGridPresence: figureGridPresence, figureWindows: figureWindows,
                window: window, isLocked: isLocked, figureTree: figureTree,
                bible: bible, world: declaredWorld,
                onOpenInCentre: openInCentre,
                paletteWallCard: paletteWallCard,
                // Show notes: To resolve, which the figure — already the
                // faces — scopes to its own notes.
                onShowNotes: { _ in position = .resolve },
                canvasDetails: { AnyView(canvasInspector(store: store)) })
        }
    }

    /// **To resolve** — the faces' notes, the check's findings and the
    /// to-dos, in one list. It reads an unopened piece without loading it and
    /// acts only on the open one.
    private var resolvePane: some View {
        ResolvePane(
            store: store,
            documentStore: documentStore,
            subject: subject,
            script: lastParsedScript,
            // The roster's compiler and its own store, the pair the head
            // reads the check and the round from.
            diagnostics: roster.compiler.diagnostics,
            orchestrator: roster.compiler,
            // The letter's Add to intent and a finding's Answer drop the
            // derivation cache.
            world: declaredWorld,
            compilerModel: compilerModel,
            onCompilerModelChange: { newValue in
                compilerModel = newValue
                // Every service that spawns a session runs on this one
                // setting; the roster names them. Lazily retired, so a change
                // made mid-round never kills the round in flight.
                roster.updateModel(newValue)
                documentStore.updateUIState { $0.compilerModel = newValue }
            },
            // The pass-order nudge's Mark done / Skip — the same write as the
            // board's chip verb: `PassStateWriterCensusTests.passStateWritingFiles`
            // is file-scoped, so a call in any `Resolve/` file would be one
            // more writer.
            onSetPassState: { pieceId, passId, state in
                setPassState(pieceId, passId, state)
            },
            // The round cockpit's pass picker lands on the ONE writer of
            // `UIState.activePassMemory`.
            onSetActivePass: { piece, passId in recordActivePass(piece, passId) },
            request: $resolveRequest,
            onOpenProjectSettings: openProjectSettings,
            onTravel: { subject in
                // Travelling to a figure is the window's SUBJECT write and
                // nothing else (`ManuscriptNavigation`'s ruling).
                selectedSubject = subject
            },
            drawsFigure: drawsFigure,
            revealFigure: revealFigure,
            revealFigureCell: { [figureWindows] id, cell, pending in
                figureWindows?.reveal(id, cell: cell, pending: pending) ?? false
            },
            // A filed line names a Brief: the faces move there.
            onOpenBrief: openBrief)
    }

    /// **The one write of a piece's pass state from this column** — the pass
    /// ladder's in To resolve's head, and the pass-order nudge's.
    ///
    /// **The task holds the store until the write lands** (P3b carry C15): a
    /// position change, a subject move and the window closing all take this
    /// column down, and any of them can land in the same turn as the click —
    /// a weak capture here is a pass state the writer chose and Maugham
    /// dropped, with nothing red anywhere.
    func setPassState(_ pieceId: String, _ passId: String, _ state: PassState?) {
        Task { try? await store.setPassState(id: pieceId, passId: passId, state) }
    }

    /// **The translation review** (interim until plan 4) — To resolve's answer
    /// while review is on over the faces' open piece. Before the piece's
    /// `Document` is registered there is nothing to review yet, and To
    /// resolve itself shows.
    @ViewBuilder
    private var translationPane: some View {
        if let doc = documentStore.document(forDocId: Self.panesDocId(of: subject)) {
            TranslationReviewPane(
                document: doc, control: editorControl, store: store,
                // The two spot-checks (P4 Task 6): the window's runner, its
                // documents, the project, the compiler's model setting, and
                // the craft-intent cache a Keep mine has to invalidate.
                coldCall: roster.coldCall, documentStore: documentStore, projectURL: store.url,
                model: compilerModel.claudeModel, world: declaredWorld)
        } else {
            resolvePane
        }
    }

    /// The canvas's inspector arm — the selected region, or an empty state.
    ///
    /// **One expression, and it reads NOTHING off `canvasModel`.** Both halves
    /// matter. `ProjectWindow.body` has a zero expression budget (the Release
    /// type-check ceiling), so the arm that mounts this is a call and not an
    /// inline body. And `CanvasModel` is `@Observable` with the whole scene in
    /// one stored property that every drag and coast frame writes, so resolving
    /// `selectedRegion` *here* would make this column's body a dependency of the
    /// drag loop, re-evaluated at 60–120 Hz. `RegionInspectorPane` does the
    /// resolving, one leaf down.
    private func canvasInspector(store: ProjectStore) -> some View {
        RegionInspectorPane(
            model: canvasModel,
            pieces: ProjectWindow.pieceChoices(in: store),
            // Deferred — walked only when a promoted card is selected.
            artifactTitle: { ProjectWindow.artifactTitle($0, in: store) },
            // Only asked when an association names a piece `pieceChoices` does
            // not hold. **The whole structure, not the routable subset** — it
            // tells a piece that is GONE from one that keeps no research of its
            // own. **It reads the canvas's own table** (`CanvasPieceTitles`), so
            // "does this piece still exist" has one answer for the canvas and the
            // inspector (`ScrapInspector.unoffered` is a function of it). Deferred,
            // and asked only on the miss.
            pieceTitle: { ProjectWindow.canvasPieceTitles(in: store).title(of: $0) },
            onOpenResearchItem: openPromotedArtifact,
            // A region's member list names item nodes too, so the pane resolves a
            // title through the same index the canvas draws from.
            itemIndex: ProjectWindow.canvasItemIndex(in: store))
    }
}

/// **Publish's desk in the To resolve position** (interim until plan 4):
/// `DepartmentPaneHost`, mounted unchanged, while an edition is the faces.
///
/// **The services come from the environment** the column injects: the desk
/// reaches the translator, the run log, the designer and the pipeline through
/// the window's roster. An optional read, so a probe that injects none gets a
/// desk that reads without acting.
struct RightColumnDesk: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    /// The tree's own subject, unconverted: the run target has to tell a
    /// group from a chapter and a research note from both.
    let subject: BinderSubject?
    /// The desk's Shows — the design gate's, a round's and the publish
    /// problems' — reach the CENTRE column through this model. Each Show
    /// clears the others (`PublishCentreModel.show`): one centre, one
    /// selection.
    let publishCentre: PublishCentreModel

    @Environment(AgentRoster.self) private var roster: AgentRoster?
    private var designer: DesignerOrchestrator? { roster?.designer }

    var body: some View {
        DepartmentPaneHost(store: store, documentStore: documentStore,
                           projectURL: store.url,
                           subject: subject,
                           translator: roster?.translator,
                           runLog: roster?.translationRuns,
                           designer: designer,
                           pipeline: roster?.pipeline,
                           onShowProposal: { publishCentre.show(proposal: $0) },
                           onShowRound: { publishCentre.show(round: $0) },
                           onShowProblems: { publishCentre.show(problems: $0) },
                           onCompileSettled: { publishCentre.refreshProblems($0) })
    }
}

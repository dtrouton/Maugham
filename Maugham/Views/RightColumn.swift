import SwiftUI
import MaughamCore
import AppKit

/// **The window's right-hand column**: the resize handle on its leading edge
/// and its drag, then `pane` — the three positions' control
/// (`RightColumnControl`) over the one arm `RightColumnContent.of` names: To
/// resolve (scoped to the reading language where there is one),
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
    /// The window's read-through gate: a research item or figure whose piece
    /// is in read-through reads, never edits.
    let readThrough: ReadThroughGate
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
    /// To resolve's shown selection, published to the window for View ▸
    /// Margin's ticks (`ResolvePane.onSelectionShown`).
    let onResolveSelectionShown: (ResolveShownSelection) -> Void
    /// The window's parsed screenplay and its piece, for To resolve's scene
    /// grouping (`WindowScript`).
    let windowScript: WindowScript?
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
    /// `ProjectWindow.pullUpItem` — Brief's pull-up links, through the one
    /// pull-up act (the position moves even when the item is already beside).
    var pullUp: (PulledUp) -> Void = { _ in }
    /// ⌘⌥I's or ⌘⌥N's request: Brief takes it through the environment
    /// (`EnvironmentValues.briefFocus`), and the field consumes it.
    var briefFocus: Binding<BriefField?> = .constant(nil)
    /// Whether the tree's Figures section draws a figure
    /// (`BinderTreeSectionsState.drawsFigure`), for To resolve's figure click.
    var drawsFigure: (String) -> Bool = { _ in false }
    /// `BinderTreeSectionsState.revealFigure`, before a figure travel lands.
    var revealFigure: (String) -> Void = { _ in }
    /// The window's tree, whose cards pace the figure inspector's pin reads;
    /// Brief's Details opens its row sheets and asks its fold index.
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
    /// The window's pulled-up memory: Back, and the centre's details over
    /// what is pulled up (`PulledUpView`).
    var pulledUpMemory: PulledUpMemory? = nil

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
                width: CGFloat(width) - Self.resizeHandleWidth,
                closedCanvasWrites: figureTree?.closedCanvasWrites ?? 0,
                canvasModel: canvasModel,
                // The pane's own scope, so the dot is asked where the list is
                // (closing review I1).
                readIn: readingLanguage,
                sourceLanguage: publishCentre.sourceLanguage)
            Divider()
            // One stack, framed once: `content` is several views (the subject
            // line, then the pane), and a frame on it would frame each —
            // the line and the pane splitting the column's height.
            VStack(spacing: 0) { content }
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
        // Reading in a language shows To resolve, which is then that
        // language's list for the piece (shell p4 Task 9). Back to Source
        // moves nothing.
        .onChange(of: editorControl.translationLanguage) { _, lang in
            if lang != nil { position = .resolve }
        }
    }

    /// View ▸ ⌘⌥0's title: what a press does to the column. Pure.
    static func toggleTitle(shown: Bool) -> String {
        shown ? "Hide Right Column" : "Show Right Column"
    }

    /// **The language the faces are read in** (`ReadingLanguage.of`) — one
    /// answer for To resolve's list, its control's dot and Brief's line.
    private var readingLanguage: String? {
        ReadingLanguage.of(subject: subject, switched: editorControl.translationLanguage,
                           sourceLanguage: publishCentre.sourceLanguage)
    }

    /// What the column shows now — the table's one answer.
    private var shown: RightColumnContent {
        RightColumnContent.of(position: position, subject: subject,
                              structure: store.manifest.structure,
                              projectType: store.manifest.type)
    }

    /// **One `switch` over `RightColumnContent`, exhaustive, no `default`**:
    /// a new answer cannot compile without an arm here.
    @ViewBuilder
    private var content: some View {
        switch shown {
        case .resolve:
            subjectLine
            resolvePane
        case .brief(let scope):
            subjectLine(brief: scope)
            BriefPane(
                store: store, documentStore: documentStore, scope: scope,
                diagnostics: roster.compiler.diagnostics, bible: bible, world: declaredWorld,
                centreItem: centreItem,
                onOpenInCentre: openInCentre,
                onPullUp: pullUp,
                onShowStrain: showStrain,
                onOpenBrief: openBrief,
                tree: figureTree)
                .environment(\.briefFocus, briefFocus)
        case .pulledUp, .centreDetails, .nothingPulledUp:
            // One mount for the three: the view asks the subject which.
            PulledUpView(
                store: store, documentStore: documentStore, subject: $subject,
                centreItem: centreItem, canvasModel: canvasModel,
                editorControl: editorControl, figureListing: figureListing,
                figureGridPresence: figureGridPresence, figureWindows: figureWindows,
                window: window, readThrough: readThrough, figureTree: figureTree,
                bible: bible, world: declaredWorld,
                onOpenInCentre: openInCentre,
                paletteWallCard: paletteWallCard,
                memory: pulledUpMemory,
                // Show notes: To resolve, which the figure — already the
                // faces — scopes to its own notes.
                onShowNotes: { _ in position = .resolve },
                canvasDetails: { AnyView(canvasInspector(store: store)) })
        }
    }

    /// **Which piece the faces are about, named** (appraisal 2): one quiet
    /// line at the top of To resolve and of Brief, from the faces the panes
    /// already render from (`RightColumnSubjectLine.title`). Nothing where
    /// the faces name nothing (the canvas, the Inbox, research).
    @ViewBuilder
    private var subjectLine: some View { subjectLine(brief: nil) }

    /// Brief's: over a piece read in a language it says the Brief is the
    /// Source's (`RightColumnSubjectLine.briefTitle`, closing review M5).
    @ViewBuilder
    private func subjectLine(brief: BriefScope?) -> some View {
        if let title = RightColumnSubjectLine.title(
            of: subject.faces, structure: store.manifest.structure,
            bookTitle: store.manifest.title, figures: store.manifest.figures ?? []) {
            RightColumnSubjectLine(title: brief.map {
                RightColumnSubjectLine.briefTitle(title, scope: $0, readIn: readingLanguage)
            } ?? title)
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
            script: windowScript,
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
            onSelectionShown: onResolveSelectionShown,
            // The tree's changed figures, listed with its figure verbs.
            figureTree: figureTree,
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
            onOpenBrief: openBrief,
            // An edition's questions: the window's presence read, off the
            // main actor (shell p4 Task 6 fix round).
            presenceReading: figureTree?.bookReading,
            // An edition's list: the Source, the compile's problems, and the
            // covers its rows open (shell p4 Task 6).
            publishCentre: publishCentre,
            // The language the faces are read in — one answer, the one ⌘⌥K
            // reads (`EditionWiring(readingLanguage:)`): a piece read in a
            // language lists that language's (shell p4 Task 9).
            readIn: readingLanguage,
            // The translated surface the editor shows, the caret's
            // paragraph's spot-checks and cells (shell p4 Task 9).
            editorControl: editorControl,
            // Whether a piece's SOURCE has something open — the tree's dot,
            // which a piece read in a language's empty list must agree with.
            presenceMarks: figureTree?.presence)
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

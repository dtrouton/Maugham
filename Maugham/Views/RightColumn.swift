import SwiftUI
import MaughamCore
import AppKit

/// **The window's right-hand column**: the resize handle on its leading edge
/// and its drag, the study arm (a studied reference, in place of the pane
/// picker and the pane), and the inspector arm — `DetailPaneToggle` with the
/// research subject, the canvas's region inspector, a Collection's piece
/// inspector and `InspectorView` beneath it — plus the one width applied to
/// both the content's frame and the split item, and the hidden arm when the
/// column is closed. It owns exactly one piece of state: the drag's starting
/// width.
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
/// keep their identities across every study, pane and subject change.
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
    /// What pin is being studied — the window's model, which the References
    /// pane writes and the study arm below is a function of.
    let assistant: AssistantColumnModel
    /// The project's services, injected into the panes' environment at
    /// `inspectorPane`.
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
    let metrics: EditorMetrics
    /// The EFFECTIVE width, bound once by the window — see the type comment.
    let width: Double
    /// The window content's measured width, for the drag's ceiling.
    let containerWidth: Double?

    // The window's state this column writes — bindings, never copies.
    /// The writer's persisted wish; written by the handle's drag alone.
    @Binding var detailColumnWidth: Double
    @Binding var selectedSubject: BinderSubject?
    @Binding var detailSegment: DetailSegment
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
    /// The drawing door's posture for one document.
    let posture: (_ docId: String?) -> Posture
    /// Whether the tree's Figures section draws a figure
    /// (`BinderTreeSectionsState.drawsFigure`), for To resolve's figure click.
    var drawsFigure: (String) -> Bool = { _ in false }
    /// `BinderTreeSectionsState.revealFigure`, before a figure travel lands.
    var revealFigure: (String) -> Void = { _ in }
    /// The window's tree, whose cards pace the figure inspector's pin reads.
    var figureTree: BinderTreeSectionsState? = nil

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
                // **A studied reference takes this column, in place of the pane
                // picker and the pane** (spec §3.2) — at the column's own width, so
                // the prose keeps its measure (Denver ruled out a fourth column).
                //
                // **The census this arm carries**: delete the branch and
                // `AssistantColumnTests` stays green while clicking a pin puts
                // nothing on screen; `StudyColumnMountTests` measures the arm.
                //
                // **One `HStack` with the branch inside it**, so the handle keeps its
                // identity across the swap and the width is applied in one place.
                // `showInspector` is a tautology HERE and passed anyway: the predicate's
                // second caller, `AssistantColumnEscape.isColumnPresented`, is asked
                // with no view in hand and is how ⌘⌥I takes the study's Escape claim
                // with it. Simplifying it away would let the two callers ask different
                // questions.
                if AssistantColumn.isPresented(studied: assistant.studied,
                                               isNoChromeOn: isNoChromeOn,
                                               showInspector: showInspector) {
                    AssistantColumn(store: store, projectRoot: projectRoot,
                                    assistant: assistant)
                } else {
                    inspectorPane(store: store, documentStore: documentStore)
                }
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

    @ViewBuilder
    private func inspectorPane(store: ProjectStore, documentStore: DocumentStore) -> some View {
        DetailPaneToggle(
            store: store,
            segment: $detailSegment,
            selectedSubject: $selectedSubject,
            activeManuscriptItemId: Self.panesItemID(of: subject),
            subject: subject,
            projectURL: store.url,
            activeDocId: Self.panesDocId(of: subject),
            allDocIds: ProjectWindow.documentIds(in: store.manifest.structure),
            device: _checkpointDeviceId,
            session: _checkpointSessionId,
            docPaths: ProjectWindow.documentPaths(in: store.manifest.structure),
            documentStore: documentStore,
            editorControl: editorControl,
            // The desk's Shows — the design gate's, a round's and the publish
            // problems' — the only things on that pane that reach the CENTRE
            // column. Each Show clears the others (`PublishCentreModel.show`):
            // one centre, one selection.
            onShowDesignProposal: { publishCentre.show(proposal: $0) },
            onShowTranslationRound: { publishCentre.show(round: $0) },
            onShowPublishProblems: { publishCentre.show(problems: $0) },
            onPublishProblemsSettled: { publishCentre.refreshProblems($0) },
            compilerModel: compilerModel,
            onCompilerModelChange: { newValue in
                compilerModel = newValue
                // Every service that spawns a session runs on this one setting;
                // the roster names them. Lazily retired, so a change made
                // mid-round never kills the round in flight.
                roster.updateModel(newValue)
                documentStore.updateUIState { $0.compilerModel = newValue }
            },
            assistant: assistant,
            resolveRequest: $resolveRequest,
            script: lastParsedScript,
            // The round cockpit's pass picker lands on the ONE writer of
            // `UIState.activePassMemory`; a queue writing the memory itself
            // would be a second spelling of the value the RUN reads to mint
            // its lane.
            onSetActivePass: { piece, passId in
                recordActivePass(piece, passId)
            },
            // The pass-order nudge's Mark done / Skip — the same write as the
            // board's chip verb: `PassStateWriterCensusTests.passStateWritingFiles`
            // is file-scoped, so a call in any `Resolve/` file would be one
            // more writer.
            onSetPassState: { pieceId, passId, state in
                Task { try? await store.setPassState(id: pieceId, passId: passId, state) }
            },
            // The check header's "Define a first reader…" — the same
            // hand-off `InspectorView`'s "Project Settings…" gets.
            onOpenProjectSettings: openProjectSettings,
            drawsFigure: drawsFigure,
            revealFigure: revealFigure,
            revealFigureCell: { [figureWindows] id, cell, pending in
                figureWindows?.reveal(id, cell: cell, pending: pending) ?? false
            }
        ) {
            researchOrSubject(store: store)
        }
        // **The project's services reach the panes through the environment**
        // — the window's roster (the session's, or the unconfigured
        // placeholder before load) and the session's bible and declared world.
        // The toggle reads every service off the roster, so a pane needing one
        // more never edits this call.
        .environment(roster)
        .environment(bible)
        .environment(declaredWorld)
        // Entering translation review surfaces the Translation segment. Exiting
        // leaves the segment in place (it shows a "not in review" empty state)
        // rather than yanking the pane out from under the writer.
        .onChange(of: editorControl.translationLanguage) { _, lang in
            if lang != nil { detailSegment = .translation }
        }
    }

    /// **The right column's outermost question: is the window about a figure
    /// (its inspector, `figureSubject`) or a research item?** It sits ABOVE `inspectorRoute` — above the canvas too — because
    /// wherever the canvas keeps the centre, a research click that did not
    /// reach this column would change nothing anywhere. `inspectorRoute` and
    /// `canvasCollapse` are left alone: the ⌘\ collapse must not answer
    /// differently because a row is selected.
    ///
    /// **Being the outermost question is not being on screen.** This closure is
    /// `DetailPaneToggle`'s `inspectorContent`, rendered only by its
    /// `.inspector` arm, and the writer may be on another pane. The reveal is a rule of its
    /// own (`ResearchRevealModifier` / `ProjectWindow.revealResearchColumn`): a
    /// `@ViewBuilder` cannot move the segment it is rendered under.
    ///
    /// A method rather than inline in `DetailPaneToggle`'s trailing builder,
    /// already the heaviest expression in this file.
    ///
    /// **What is beside is asked first** (shell p1 Task 4): it shows whatever
    /// the centre is — a figure or a research item open in the centre
    /// included — under `BesideHeader`'s Open in Centre and close. Only with
    /// nothing beside does the column inspect what the centre shows.
    @ViewBuilder
    private func researchOrSubject(store: ProjectStore) -> some View {
        let placement = ProjectWindow.researchSubjectPlacement(subject: subject)
        let figurePlacement = ProjectWindow.figureSubjectPlacement(subject: subject)
        if let figureID = figurePlacement.besideFigureID {
            besideView(title: figureListing.row(forFigureId: figureID)?.name ?? "", store: store) {
                figureSubject(figureID, store: store)
            }
        } else if placement.previewsInTheRightColumn, let id = placement.inspectedItemID {
            besideView(title: TreeWalk.find(id: id, in: store.manifest.research)?.title ?? "",
                       store: store) {
                researchInspector(id, showsPreview: true, store: store)
            }
        } else if let figureID = figurePlacement.centreFigureID {
            figureSubject(figureID, store: store)
        } else if let id = placement.inspectedItemID {
            researchInspector(id, showsPreview: false, store: store)
        } else {
            switch ProjectWindow.inspectorRoute(subject: subject,
                                                projectType: store.manifest.type) {
            case .canvas:
                canvasInspector(store: store)
            case .collectionPiece:
                collectionInspector(store: store)
            case .document:
                InspectorView(
                    store: store,
                    selectedItemId: subject.faces.itemID,
                    metrics: metrics,
                    onOpenProjectSettings: openProjectSettings,
                    posture: posture(subject.faces.itemID))
            }
        }
    }

    /// A research item's inspector, previewing it above when it is beside.
    private func researchInspector(_ id: String, showsPreview: Bool,
                                   store: ProjectStore) -> some View {
        ResearchSubjectInspector(
            store: store, itemID: id,
            showsPreview: showsPreview, figureTree: figureTree,
            figureWritesRefused: FigureActions.windowRefusesWrites(control: editorControl, isLocked: isLocked),
            documentStore: documentStore, readOnly: WindowLock.refusesEdits(isLocked: isLocked),
            shareIsReadOnly: editorControl.shareIsReadOnly, typography: editorControl.typography,
            window: window, presence: figureGridPresence)
    }

    /// **The beside view**: what the writer pulled up, under a header that
    /// carries its two controls — Open in Centre (the click rule's
    /// `.openInCentre`, `ProjectWindow.openingBesideInCentre`) and close
    /// (`ProjectWindow.closingBeside`). Both are always drawn here, because
    /// both always apply to something beside; nothing beside, no header.
    private func besideView<Content: View>(title: String, store: ProjectStore,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            BesideHeader(
                title: title,
                openInCentre: {
                    subject = ProjectWindow.openingBesideInCentre(
                        subject, structure: store.manifest.structure,
                        projectType: store.manifest.type)
                },
                close: { subject = ProjectWindow.closingBeside(subject) })
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// **A figure subject's arm** (report plan 8a Task 7): its inspector. A
    /// figure opened beside shows itself above, in this column, with its
    /// inspector beneath, each taking half; a figure in the centre leaves the
    /// inspector the column.
    @ViewBuilder
    private func figureSubject(_ figureID: String, store: ProjectStore) -> some View {
        let inspector = FigureInspector(
            figureId: figureID, store: store, documentStore: documentStore, listing: figureListing,
            figureWindows: figureWindows, figureTree: figureTree, control: editorControl, isLocked: isLocked,
            window: window, select: { selectedSubject = $0 },
            // Show notes: To resolve, which the figure — already the faces —
            // scopes to its own notes (shell plan 2 Task 7).
            showNotes: { _ in
                detailSegment = .resolve
            })
            .id(figureID)
        if ProjectWindow.figureSubjectPlacement(subject: subject).besideFigureID != nil {
            VStack(spacing: 0) {
                FigureSubjectSurface(
                    figureID: figureID, store: store, documentStore: documentStore, figureWindows: figureWindows,
                    presence: figureGridPresence, listing: figureListing, control: editorControl,
                    isLocked: isLocked, window: window)
                    .frame(maxHeight: .infinity)
                Divider()
                inspector.frame(maxHeight: .infinity)
            }
        } else {
            inspector
        }
    }

    @ViewBuilder
    private func collectionInspector(store: ProjectStore) -> some View {
        if let id = subject.faces.itemID,
           let piece = store.manifest.structure.first(where: { $0.id == id }) {
            switch piece.pieceKind {
            case .reference:
                ReferencePieceInspector(store: store, pieceId: id)
            case .loose, .none:
                PieceInspector(store: store, pieceId: id,
                               format: Self.pieceInspectorFormat(path: piece.path),
                               posture: posture(id))
            }
        } else {
            ContentUnavailableView("Select a piece", systemImage: "doc.text")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The format a loose piece is inspected as: `DocumentFormat.ofManuscript`
    /// of its path (prose for a path-less piece).
    static func pieceInspectorFormat(path: String?) -> DocumentFormat {
        DocumentFormat.ofManuscript(path: path)
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

/// **The beside view's header** (shell p1 Task 4): the pulled-up item's title,
/// truncated in the middle with the whole of it in its tooltip, then two plain
/// visible buttons — **Open in Centre** and close. A view of its own so the
/// labels the buttons, their help and a test read are one spelling.
struct BesideHeader: View {
    let title: String
    let openInCentre: () -> Void
    let close: () -> Void

    static let openInCentreLabel = "Open in Centre"
    static let closeLabel = "Close"

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(Self.openInCentreLabel, action: openInCentre)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .lineLimit(1)
                .fixedSize()
                .help("Open \(title) in the centre")
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Self.closeLabel)
            .accessibilityLabel(Self.closeLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

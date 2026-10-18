import SwiftUI
import MaughamCore
import AppKit

/// **The window's right-hand column** (foundations plan 4, Task 5): the resize
/// handle on its leading edge and the drag that moves it, the study arm (a
/// studied reference, in place of the pane picker and the pane), and the
/// inspector arm — `DetailPaneToggle` with the research subject, the canvas's
/// region inspector, a Collection's piece inspector and `InspectorView` beneath
/// it — plus the one width applied to both the content's frame and the split
/// item, and the hidden arm when the column is closed.
///
/// It was five builders inside `ProjectWindow`, reading the window's `@State`
/// directly. It is a view of its own so the column's code can be read without
/// the rest of the window, and it owns exactly one piece of state: the drag's
/// starting width, which nothing outside the handle reads.
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
/// **Mounted ONCE, as the detail column's root** — where the `if showInspector`
/// branch used to sit inline. SwiftUI sees one `RightColumn` node at that
/// position in every state, and beneath it the same conditional it used to see,
/// so the handle and the pane keep their identities across every study, pane
/// and persona change exactly as before.
///
/// `canvasModel` is a `let`, and nothing here reads its `.scene`: the region
/// inspector resolves the selection one leaf down (tripwire 30).
struct RightColumn: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let projectRoot: URL
    let canvasModel: CanvasModel
    let editorControl: EditorControl
    let publishCentre: PublishCentreModel
    /// What pin is being studied — the window's model, which the References
    /// pane writes and the study arm below is a function of.
    let assistant: AssistantColumnModel
    /// The project's services, injected into the panes' environment at
    /// `inspectorPane` (foundations plan 3, Task 5).
    let roster: AgentRoster
    let bible: BibleStore?
    let declaredWorld: DeclaredWorldStore?

    // The window's state this column only reads.
    let persona: Persona
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
    @Binding var annotationScopeRequest: AnnotationScope
    @Binding var compilerModel: CompilerModelChoice

    // The window's verbs.
    /// `ProjectWindow.recordActivePass(forPiece:passId:)` — the ONE writer of
    /// `UIState.activePassMemory`, which the run reads to sign its notes.
    let recordActivePass: (_ piece: String, _ passId: String) -> Void
    /// `ProjectWindow.openProjectSettings()`.
    let openProjectSettings: () -> Void
    /// `ProjectWindow.openPromotedArtifact(_:)` — Open on a promoted card.
    let openPromotedArtifact: (_ itemId: String) -> Void
    /// The drawing door's posture for one document (P3c Task 6).
    let posture: (_ docId: String?) -> Posture

    /// The drag's starting width, so the gesture reads its own translation
    /// rather than accumulating.
    @State private var detailDragStartWidth: Double?

    /// **One width, held.** The right column is pinned to the writer's own
    /// `detailColumnWidth` and resized by the handle below — it does NOT declare
    /// a range, and the difference is the whole of Task 1.
    ///
    /// `navigationSplitViewColumnWidth(min:ideal:max:)` does not hold a width;
    /// it declares a range, and AppKit re-resolves a position inside that range
    /// whenever something re-proposes. Two things do, both measured in
    /// `DetailColumnWidthTests` against a real mounted `NavigationSplitView`:
    ///
    /// - **a pane whose content wants to be wider** pushes the column out to the
    ///   range's `max` — so every ⌘⌥-letter switch between panes of different
    ///   intrinsic width moved the divider under the writer;
    /// - **a `columnVisibility` transition** (`⌘\` on the canvas sets
    ///   `.doubleColumn`, `PersonaModifier` hands back `.all`) drops the column
    ///   on the range's `min` — 240 out of a dragged 329, measured.
    ///
    /// **The single-argument spelling is necessary and, since macOS 27, not
    /// sufficient — so the width is applied TWICE, to the content's frame as
    /// well as to the column.**
    ///
    /// `navigationSplitViewColumnWidth(w)` gives the split item a min AND a max
    /// of `w`, and a pane whose content is genuinely unbreakable contributes a
    /// minimum of its own. Until macOS 27 AppKit resolved that conflict by
    /// breaking the item's `NSSplitViewItem.MaxSize` in the column's favour —
    /// undocumented tie-breaking we did not control, logged as a
    /// `Conflicting constraints detected` line, and the sole reason the width
    /// came out right. On macOS 27 it goes the other way: **the column resolves
    /// to `max(w, the pane's own minimum)`**, measured exactly, in every cell of
    /// `docs/superpowers/notes/2026-09-19-split-view-tie-break-spike.md`.
    ///
    /// `.frame(width: width)` on the content is what replaces the tie-break: a
    /// framed pane has no minimum left to contribute, so nothing outranks the
    /// column and the guarantee stops depending on how Apple breaks a tie. Note
    /// what does NOT move it — a pane with a large IDEAL and a small minimum
    /// (`SetAsideRecordsDisclosure`'s shape) never moved the column on either
    /// OS; it is the pane's FLOOR that wins, never its preference.
    ///
    /// `test_theFixedColumnWinsAgainstAnUnbreakablePane` keeps the guarantee,
    /// `test_plantedOffender_anUnframedPaneTakesTheColumn` keeps the mechanism
    /// measurable, and `test_theRightColumnFramesItsContentToTheWidthItDeclares`
    /// is what ties this file to them — without it, giving the test harness the
    /// fix turns every mounted test green while this method ships the broken
    /// spelling, which is a thing that actually happened during the fix.
    /// Real Inspector and Outline content wraps or scrolls, so provoking any of
    /// this wants a `.fixedSize()` in the harness.
    ///
    /// The cost of the fixed column is that the split view's own divider goes
    /// inert — a fixed column is not draggable — so the column brings its own
    /// handle. (The assistant column used to ship the same shape one directory
    /// over; it has no width of its own any more — it takes THIS one.)
    ///
    /// What is applied is the **effective** width, not the stored one; see
    /// `effectiveDetailColumnWidth` for the window-affordability sum and why the
    /// reduction never reaches the stored value.
    @ViewBuilder
    var body: some View {
        if showInspector {
            // **Bound once, applied twice** — to the content's frame and to the
            // column. `width` is the ONE effective width the window bound
            // (`ProjectWindow.detailColumn`); two computations would lay out
            // identically today and are one edit away from two different
            // widths, so `DetailColumnWidthTests` counts the window's binding
            // and expects exactly one.
            HStack(spacing: 0) {
                detailResizeHandle(documentStore: documentStore)
                // **A studied reference takes this column, in place of the pane
                // picker and the pane** (spec §3.2, 2026-08-25) — at the
                // column's own width, so the prose keeps the measure it had.
                // Denver ruled against the fourth column it used to be, having
                // written beside one.
                //
                // **The census this arm carries**: delete the branch and every
                // token in `AssistantColumn.swift` is still present,
                // `AssistantColumnTests` is still green — its predicate, Escape
                // and resolution tests are all about values — and clicking a pin
                // puts nothing on screen. `StudyColumnMountTests` is what
                // measures the arm rather than the predicate.
                //
                // **One `HStack` with the branch inside it**, not two branches
                // each applying the width: the handle keeps its identity across
                // the swap, and the width is applied in exactly one place, which
                // is what `DetailColumnWidthTests` is about.
                // `showInspector` is a tautology HERE — this whole arm is inside
                // `if showInspector` — and it is passed anyway because the
                // predicate has a second caller for whom it decides everything:
                // `AssistantColumnEscape.isColumnPresented`, which is asked with
                // no view in hand and is how ⌘⌥I takes the study's Escape claim
                // with it. Simplifying it away here would leave that caller
                // asking a different question from the one this column answers,
                // which is the shape of the C1 the Task-5 review closed.
                if AssistantColumn.isPresented(studied: assistant.studied,
                                               persona: persona,
                                               isNoChromeOn: isNoChromeOn,
                                               showInspector: showInspector) {
                    AssistantColumn(store: store, projectRoot: projectRoot,
                                    assistant: assistant)
                } else {
                    inspectorPane(store: store, documentStore: documentStore)
                }
            }
            // **The frame is what holds the column on macOS 27**, not the
            // modifier below it. See this method's doc comment: the modifier
            // gives the split item a min AND a max of `width`, and 27 resolves
            // the item's max against the CONTENT's minimum in the content's
            // favour. Framing the content to the column's own width leaves it
            // no minimum to contribute, so there is nothing left to lose.
            //
            // `.clipped()` is NOT what holds it — measured across 48 cells in
            // `docs/superpowers/notes/2026-09-19-split-view-tie-break-spike.md`,
            // every test here is green without it. It is here so that a pane
            // whose content genuinely cannot break DRAWS inside its column
            // instead of over the prose. Nothing guards it; this comment is
            // why it stays.
            .frame(width: width)
            .clipped()
            .navigationSplitViewColumnWidth(width)
        } else {
            ProjectWindow.hiddenDetailColumn
        }
    }

    /// The right column's own resize affordance, on its leading edge.
    ///
    /// **A gutter in the layout rather than an overlay over the pane**, for a
    /// measured reason: a `contentShape`d strip laid *over* the pane swallows
    /// every click in the leftmost 8pt of every row, list and control in the
    /// column, for the whole height of the window, and it does it silently.
    /// Eight points of
    /// layout is the cheaper mistake. It is deliberately not drawn — the split
    /// view's own divider is still there and is still the seam a writer aims at;
    /// this sits just inside it, and the resize cursor on hover is what says so.
    ///
    /// Live during the gesture and persisted only at its end — a `UIState` write
    /// per drag frame is 60 a second through the manuscript's own debounce.
    ///
    /// **Nothing else writes this width.** There is no geometry observation
    /// feeding the COLUMN's width back, because a fixed column has no geometry
    /// of its own to report — it is exactly as wide as it was asked to be. (The
    /// window's width is measured, but that is the container's geometry and it
    /// is never persisted.) That is what makes
    /// `test_aPersonaSwitchDoesNotWriteTheWidth` structurally true rather than a
    /// debounce racing a persona change.
    private func detailResizeHandle(documentStore: DocumentStore) -> some View {
        Color.clear
            .frame(width: 8)
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
            activeManuscriptItemId: selectedSubject?.itemID,
            persona: persona,
            projectURL: store.url,
            activeDocId: BinderSubject.activeDocId(for: selectedSubject),
            allDocIds: ProjectWindow.documentIds(in: store.manifest.structure),
            device: _checkpointDeviceId,
            session: _checkpointSessionId,
            docPaths: ProjectWindow.documentPaths(in: store.manifest.structure),
            documentStore: documentStore,
            editorControl: editorControl,
            // The desk's two Shows — the design gate's (P4 Task 5) and,
            // as of translation pipeline P4, a round's. They are the only
            // things on that pane that reach the CENTRE column, and each is
            // one write of the window state its own arm is a function of.
            // Each Show clears the other (`PublishCentreModel.show`): one
            // centre, one selection.
            onShowDesignProposal: { publishCentre.show(proposal: $0) },
            onShowTranslationRound: { publishCentre.show(round: $0) },
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
            annotationScope: $annotationScopeRequest,
            // The round cockpit's pass picker (M4 P2 Task 3) lands on the ONE
            // writer of `UIState.activePassMemory` — the same private method
            // the board's chip click uses. A queue that wrote the memory
            // itself would be a second spelling of the value the RUN reads to
            // mint its lane.
            onSetActivePass: { piece, passId in
                recordActivePass(piece, passId)
            },
            // The pass-order nudge's Mark done / Skip buttons (pass-order
            // nudge gains its verbs) — the same write, at the same host, as
            // the board's chip verb a few lines above: `PersonaPaneRegistryTests
            // .passStateWritingFiles`' census is file-scoped, so a second call
            // site in THIS file costs the census nothing, while a call in
            // `AnnotationsPane.swift` would have made it a fourth writer.
            onSetPassState: { pieceId, passId, state in
                Task { try? await store.setPassState(id: pieceId, passId: passId, state) }
            },
            // The Diagnostics header's "Define a first reader…" (two loops P2
            // Task 6) — the same one-line hand-off `InspectorView`'s "Project
            // Settings…" already gets from this file.
            onOpenProjectSettings: openProjectSettings
        ) {
            researchOrSubject(store: store)
        }
        // **The project's services reach the panes through the environment**
        // (foundations plan 3, Task 5) — the same roster the accessors above
        // return (the session's, or the unconfigured placeholder before load,
        // so the toggle always has one), and the session's bible and declared
        // world. The toggle reads its compiler, diagnostics, translator,
        // translation runs, designer, pipeline and cold-call runner off the
        // roster, so a pane needing one more service never edits this call.
        .environment(roster)
        .environment(bible)
        .environment(declaredWorld)
        // Entering translation review surfaces the Translation segment so the
        // source text + translator queries are one glance away. Exiting leaves
        // the segment in place (it shows a "not in review" empty state) rather
        // than yanking the pane out from under the writer.
        .onChange(of: editorControl.translationLanguage) { _, lang in
            if lang != nil { detailSegment = .translation }
        }
    }

    /// **The right column's outermost question: is the window about a research
    /// item?**
    ///
    /// It sits ABOVE `inspectorRoute` — including above the canvas — because
    /// that is the whole of Plan's half of the contract: the canvas keeps the
    /// centre, so a research click that did not reach this column would change
    /// nothing anywhere and the tree's Research section would be a list that
    /// does not do anything. `inspectorRoute` and `canvasCollapse` are
    /// deliberately left alone: the ⌘\ collapse is a question about the SEGMENT
    /// and must not start answering differently because a row is selected.
    ///
    /// **Being the column's outermost question is not the same as being on
    /// screen, and that gap was the stage 2b final review's Critical.** This
    /// closure is `DetailPaneToggle`'s `inspectorContent`, which its `.inspector`
    /// arm alone renders — and Plan opens on `.inbox`. So the reveal is a rule of
    /// its own (`ResearchRevealModifier` /
    /// `ProjectWindow.revealResearchColumn`), and this method deliberately does
    /// not try to be it: a `@ViewBuilder` cannot move the segment it is being
    /// rendered under.
    ///
    /// A method rather than more `ProjectWindow.body`: the inspector closure is
    /// inside `DetailPaneToggle`'s trailing builder, which is already the
    /// heaviest expression in this file.
    @ViewBuilder
    private func researchOrSubject(store: ProjectStore) -> some View {
        let placement = ProjectWindow.researchSubjectPlacement(
            persona: persona, subject: selectedSubject)
        if let id = placement.inspectedItemID {
            ResearchSubjectInspector(
                store: store, itemID: id,
                showsPreview: placement.previewsInTheRightColumn)
        } else {
            switch ProjectWindow.inspectorRoute(persona: persona,
                                                projectType: store.manifest.type) {
            case .canvas:
                canvasInspector(store: store)
            case .collectionPiece:
                collectionInspector(store: store)
            case .document:
                InspectorView(
                    store: store,
                    selectedItemId: selectedSubject?.itemID,
                    metrics: metrics,
                    onOpenProjectSettings: openProjectSettings,
                    posture: posture(selectedSubject?.itemID))
            }
        }
    }

    @ViewBuilder
    private func collectionInspector(store: ProjectStore) -> some View {
        if let id = selectedSubject?.itemID,
           let piece = store.manifest.structure.first(where: { $0.id == id }) {
            switch piece.pieceKind {
            case .reference:
                ReferencePieceInspector(store: store, pieceId: id)
            case .loose, .none:
                if let path = piece.path, path.hasSuffix(".fountain") {
                    PieceInspector(store: store, pieceId: id, kind: .screenplay,
                                   posture: posture(id))
                } else {
                    PieceInspector(store: store, pieceId: id, kind: .prose,
                                   posture: posture(id))
                }
            }
        } else {
            ContentUnavailableView("Select a piece", systemImage: "doc.text")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The canvas's inspector arm — the selected region, or an empty state.
    ///
    /// **One expression, and it reads NOTHING off `canvasModel`.** Both halves
    /// matter. `ProjectWindow.body` has a zero expression budget (the Release
    /// type-check ceiling), so the arm above is a call and not a body. And
    /// `CanvasModel` is `@Observable` with the whole scene in one stored
    /// property, which every drag frame and every coast frame writes — so
    /// resolving `selectedRegion` *here* would register this window's body as a
    /// dependency of the drag loop and re-evaluate all of it at 60–120 Hz.
    /// `RegionInspectorPane` does the resolving, one leaf down.
    private func canvasInspector(store: ProjectStore) -> some View {
        RegionInspectorPane(
            model: canvasModel,
            pieces: ProjectWindow.pieceChoices(in: store),
            // Deferred — walked only when a promoted card is selected.
            artifactTitle: { ProjectWindow.artifactTitle($0, in: store) },
            // Only asked when an association names a piece `pieceChoices` does
            // not hold. **The whole structure, not the routable subset** — this is
            // what tells an association whose piece is GONE from one whose piece
            // is in the writer's binder and simply keeps no research of its own,
            // which the inspectors called "Missing piece · ref-1" while the
            // refusal named it.
            //
            // **It reads the canvas's own table since §4.2, and that is the
            // point.** This was a `TreeWalk.collect` of its own; the canvas now
            // needs the same lookup to draw a dimmed region's borrowed name, and
            // two walks of one tree are two answers to "does this piece still
            // exist" with nothing keeping them together. `ScrapInspector
            // .unoffered` is a function of exactly this lookup, so sharing the
            // table is sharing the resolution — which is the only half worth
            // sharing: `PieceAssociation.label` is a Form row's voice and says
            // things about promotion ROUTING that are true in the pane and
            // false-by-irrelevance on a chrome bar (see `CanvasPieceTitles`).
            //
            // Still deferred, and it costs what it always cost: `TreeWalk.collect`
            // walks the whole structure whether it filters to one id or to all of
            // them, so this is the same walk with a dictionary built on the end of
            // it, asked only on the miss. What changed is that there is one
            // SPELLING of "which pieces exist and what are they called" rather
            // than two.
            pieceTitle: { ProjectWindow.canvasPieceTitles(in: store).title(of: $0) },
            onOpenResearchItem: openPromotedArtifact,
            // A region's member list names item nodes too — a Claude region holds
            // the page its scraps were read off — so the pane resolves a title
            // through the same index the canvas draws from (1C-d).
            itemIndex: ProjectWindow.canvasItemIndex(in: store))
    }
}

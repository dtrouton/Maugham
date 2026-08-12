import SwiftUI
import MaughamCore

// MARK: - Where a research subject lands

extension ProjectWindow {

    /// **What the window does about a subject that names a research item**
    /// (shell-finish stage-2a Task 5, spec §4).
    ///
    /// Task 4 gave every persona's tree a Research and a Palette section, so
    /// every tree can now make a research item the window's subject. This is
    /// the answer to *"and then what?"* — and it is ONE value read by BOTH
    /// columns, rather than a rule in the centre and a second one in the right
    /// column that can come to disagree about whether the subject is in force.
    ///
    /// The two columns differ, and the difference is the whole type:
    ///
    /// - `takesTheCentre` — the item is the centre column, and the right column
    ///   inspects it. Author and Review, whose left column is the manuscript
    ///   home and nothing else.
    /// - `besideTheCanvas` — Plan. The canvas STAYS MOUNTED
    ///   (`Persona.centresTheCanvas`) and the right column previews the
    ///   item instead. `CanvasTreeSegmentMountTests` measured what a second
    ///   centre-column branch costs: the camera back to origin at zoom 1, every
    ///   scrap layout re-measured, the thumbnail cache emptied — on every
    ///   research click.
    /// - `nothingMoves` — neither column has anything to do about it. Two
    ///   populations reach it: a subject that is not research at all, and — as
    ///   of shell-finish stage 3b Task 5 — a research subject in **Publish**,
    ///   which is spec §4's "—" row. Publish has no rendering for a note or a
    ///   card, and the centre it does have is the compiled book; so the subject
    ///   falls through to the manuscript arm, which shows the book if there is
    ///   one and the project at altitude if there is not ("Review/Publish
    ///   degrade gracefully… the centre never renders nothing").
    ///
    /// A third case, `.segmentStands`, guarded against a left column that was
    /// not the tree: a research item taking a column while nothing on screen
    /// could point the window anywhere else is a room with no door, which is the
    /// Critical stage 2a's final review found. Shell-finish stage 2b Task 7
    /// made the tree the whole left column in every persona, so the trap is not
    /// expressible and the guard went with the enum it was asked of. Its
    /// successor question is about the find OVERLAY — with the panel over the
    /// column there is no row to click — and the answer is asserted rather than
    /// assumed: `treeFindActive` is window `@State` no relaunch restores and
    /// Escape puts the tree back
    /// (`ProjectSubjectReachabilityTests.test_theFindOverlayIsNotATrapBecauseTheTreeComesBack`),
    /// which are exactly the two properties that Critical lacked. So the overlay
    /// is deliberately NOT a term here.
    enum ResearchSubjectPlacement: Equatable {
        case takesTheCentre(String)
        case besideTheCanvas(String)
        /// The subject names no research item. It was `.segmentStands` while
        /// there were segments for one to stand.
        case nothingMoves

        /// The item the CENTRE column shows, or `nil` when the centre is not
        /// the research subject's to take.
        var centreItemID: String? {
            if case .takesTheCentre(let id) = self { return id }
            return nil
        }

        /// The item the RIGHT column shows, or `nil`.
        var inspectedItemID: String? {
            switch self {
            case .takesTheCentre(let id), .besideTheCanvas(let id): return id
            case .nothingMoves: return nil
            }
        }

        /// Whether the right column also PREVIEWS the item's content rather
        /// than only inspecting it — true exactly when the centre column is not
        /// showing the item, because otherwise the writer has no way to read
        /// what they just selected.
        var previewsInTheRightColumn: Bool {
            if case .besideTheCanvas = self { return true }
            return false
        }
    }

    /// Pure, named and exhaustive over its inputs, for `inspectorRoute`'s
    /// reason: the two routing bugs that shape says out loud were both a rule
    /// spelled inside a `@ViewBuilder` where no test could be exhaustive over
    /// it.
    ///
    /// **Two guards stood in front of this and both are gone**, each in the task
    /// that made it unable to decide anything.
    ///
    /// `keepsItsOwnResearchSelection` went in stage 2b Task 6 — it asked whether
    /// the centre was already about a research item, and the trap guard beside
    /// it was strictly wider, so it never decided a case the other did not
    /// decide the same way.
    ///
    /// The trap guard itself went in Task 7 with the enum it was asked of: it
    /// refused every left column that was not the tree, and every left column is
    /// the tree now. See `ResearchSubjectPlacement` for the successor question —
    /// the find overlay — and why the answer is asserted rather than made a term
    /// here.
    static func researchSubjectPlacement(
        persona: Persona, subject: BinderSubject?
    ) -> ResearchSubjectPlacement {
        guard let id = subject?.researchID else { return .nothingMoves }
        // **Publish acts on it in neither column** (stage 3b Task 5, spec §4's
        // "—" row). Asked FIRST because the two questions below it are both
        // about which column takes the item, and Publish's answer is that
        // neither does: its centre is the book, and a note previewed beside a
        // book is a reference view Publish does not have. Asked through
        // `previewsThePublishedBook` rather than by name — the ONE spelling.
        guard !persona.previewsThePublishedBook else { return .nothingMoves }
        // **The persona decides which column.** Plan keeps the board in the
        // centre and previews beside it; everyone else hands the centre over.
        return persona.centresTheCanvas ? .besideTheCanvas(id) : .takesTheCentre(id)
    }

    /// **Showing the column the placement chose** (stage 2b final review's
    /// Critical).
    ///
    /// `besideTheCanvas` says the right column previews the item. It does not
    /// make that column VISIBLE, and in Plan it is not: `Persona.panes` opens
    /// Plan on `.inbox`, and `ResearchSubjectInspector` is mounted by
    /// `DetailPaneToggle`'s `.inspector` arm alone. So every correct piece of
    /// the routing — the tree writes the subject, the placement sends it beside
    /// the board, the right column knows what to draw — composed into a research
    /// row that put nothing anywhere: the board does not dim, the pane does not
    /// change, and the writer's click is silently nothing. Three tasks' choices,
    /// each right on its own.
    ///
    /// **What it does NOT do is decide anything about the columns.** Where the
    /// centre takes the item (Author, Review, Publish) this writes nothing at
    /// all, so a writer's pane choice in those personas is never moved by a
    /// research click — the guard is the placement's own answer, asked rather
    /// than a second `centresTheCanvas` test.
    ///
    /// `inout` and static so the whole rule is drivable without a window, and so
    /// the three sites that reveal — the subject observer
    /// (`ResearchRevealModifier`) and the two forced entries (`openResearchItem`,
    /// `handleShowLatestMCPNote`) — cannot come to disagree about what revealing
    /// means.
    static func revealResearchColumn(persona: Persona,
                                     subject: BinderSubject?,
                                     showInspector: inout Bool,
                                     detailSegment: inout DetailSegment) {
        guard researchSubjectPlacement(persona: persona, subject: subject)
            .previewsInTheRightColumn else { return }
        showInspector = true
        detailSegment = .inspector
    }

    /// Whether the window's subject resolves to a manuscript document — the only
    /// selection kind for which the `EditorCoordinator` delivers metrics, so
    /// anything else zeroes them.
    ///
    /// Static and taking the structure so the rule is assertable without a
    /// mounted window; the instance path is the one caller.
    static func selectionIsDocument(_ subject: BinderSubject?,
                                    in structure: [StructureItem]) -> Bool {
        guard let id = subject?.itemID,
              let item = TreeWalk.find(id: id, in: structure)
        else { return false }
        return item.type == .document && item.path != nil
    }
}

// MARK: - Which surface the centre shows

extension ProjectWindow {

    /// **Which editor a research item opens in.**
    ///
    /// Extracted from the old research segment's centre-column arm, where it
    /// lived as three nested `if`s, so that arm and the subject arm could not
    /// answer differently. The arm is gone (stage 2b Task 7) and the rule is
    /// what was worth keeping: `ResearchSubjectCentre` and
    /// `ResearchSubjectInspector` are its two callers, and having one of them
    /// not call it is the drift it was built against.
    enum ResearchCentreRoute: Equatable {
        /// A palette card, by id — `PaletteCardEditor`. **Never
        /// `ResearchNoteEditor`**, whose stale open text clobbers the card model
        /// on the next re-render (a lost update).
        case paletteCard(String)
        /// A text note — `ResearchNoteEditor`. The path is carried so the view
        /// does not have to unwrap what this function already checked.
        case note(item: ResearchItem, path: String)
        /// Everything the writer cannot edit here — a PDF, an image, audio, a
        /// link, a group — via `ResearchPreview`.
        case preview(ResearchItem)
        /// The id names nothing. The subject sweep lands a dangling id on
        /// `.project` before it reaches here (stage-2a Task 2), so this is the
        /// render-race window in which the subject and the manifest have
        /// arrived in different passes.
        case missing
    }

    /// **The four cases, rather than the three a plan can carry.** Collapsing
    /// `.preview` into `.note` would leave the palette-vs-note decision here and
    /// the note-vs-preview decision inside the view, which is the split this
    /// function exists to close.
    static func researchCentreRoute(id: String?,
                                    in research: [ResearchItem]) -> ResearchCentreRoute {
        guard let id, let item = TreeWalk.find(id: id, in: research) else { return .missing }
        guard item.kind == .document, let path = item.path else { return .preview(item) }
        // **A path prefix ending in the SEPARATOR**, not a name test and not a
        // bare `hasPrefix`: a research group called "Palette research" gives its
        // notes paths that start with the palette folder's characters and are
        // not inside it, and routing one of those here shows "Card unavailable"
        // over a note the writer can see in their tree
        // (`test_aNoteBesideThePaletteFolderIsStillANote`).
        if path.hasPrefix(ProjectStore.paletteFolderPath + "/") {
            return .paletteCard(item.id)
        }
        return .note(item: item, path: path)
    }
}

/// **The centre column for a research subject** — the one mount of the three
/// research editors, reached from both `editorPane`'s subject arm and
/// `existingEditorSwitch`'s `.research` segment arm.
///
/// A view rather than a `@ViewBuilder` method on `ProjectWindow` for two
/// reasons: `ProjectWindow.body` has no expression budget to spare (the Release
/// type-check ceiling), and a test can mount exactly what the window mounts.
struct ResearchSubjectCentre: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    /// Optional because the render-race window above is real: nothing selected
    /// is `.missing`, which is the empty state.
    let itemID: String?
    let previewVisible: Bool
    /// **Threaded from the mount off `Persona.editsResearchInTheCentre`**
    /// (shell-finish stage 3b Task 6) — never re-derived here, so this view
    /// cannot answer a different question than the persona did. True only in
    /// Review: the `.paletteCard` arm mounts `PaletteCardReadView` instead of
    /// `PaletteCardEditor`, and the `.note` arm locks `ResearchNoteEditor`
    /// rather than leaving it editable. `.preview` and `.missing` are
    /// unaffected — both were already read-only.
    let readOnly: Bool

    var body: some View {
        switch ProjectWindow.researchCentreRoute(id: itemID, in: store.manifest.research) {
        case .paletteCard(let cardID):
            if readOnly {
                PaletteCardReadHost(store: store, cardId: cardID)
            } else {
                PaletteCardEditor(store: store, cardId: cardID)
            }
        case .note(let item, let path):
            ResearchNoteEditor(
                store: store,
                documentStore: documentStore,
                path: path,
                itemId: item.id,
                previewVisible: previewVisible,
                lockEditing: readOnly)
        case .preview(let item):
            ResearchPreview(projectURL: store.url, item: item)
        case .missing:
            ContentUnavailableView(
                "Select an item to preview",
                systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// **The right column for a research subject.**
///
/// `showsPreview` is `ResearchSubjectPlacement.previewsInTheRightColumn` and is
/// never re-derived here: where the canvas keeps the centre the writer has no
/// other way to read the item, so the preview goes above the panel; where the
/// centre already holds the item, a second copy of it in a 300pt column is
/// noise.
///
/// The two halves are given no heights of their own. Both grow, so they split
/// the column between them — a number here would be a guess about a column the
/// writer can drag.
///
/// **The preview half goes through `researchCentreRoute`, like the centre half**
/// (final-review finding I3). It mounted `ResearchPreview` for everything, so in
/// Plan — the one placement where this column is the writer's only view of the
/// item — a palette card previewed as the raw markdown of its source, which is
/// the very rendering `researchCentreRoute` was extracted to stop the window
/// showing. The function exists so the two columns cannot answer differently;
/// having one of them not call it is the drift it was built against.
struct ResearchSubjectInspector: View {
    let store: ProjectStore
    /// Optional for `ResearchSubjectCentre.itemID`'s reason — nothing selected
    /// is the empty state.
    let itemID: String?
    let showsPreview: Bool

    var body: some View {
        if let itemID, let item = TreeWalk.find(id: itemID, in: store.manifest.research) {
            if showsPreview {
                VStack(spacing: 0) {
                    preview(of: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    InspectorResearchPanel(store: store, item: item)
                }
            } else {
                InspectorResearchPanel(store: store, item: item)
            }
        } else {
            ContentUnavailableView(
                "Select an item",
                systemImage: "info.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// **A card as a card; everything else as itself.**
    ///
    /// `.note` and `.preview` both reach `ResearchPreview`, which is the read-only
    /// rendering this column has always shown and the right one for a preview:
    /// the writer is looking at the item beside a canvas, not editing it.
    ///
    /// `.paletteCard` reaches `PaletteCardEditor`, and that choice is the one
    /// worth defending. There is no read-only card rendering to reuse —
    /// `PaletteCardTile` takes a loaded `PaletteCard` and a pre-loaded
    /// thumbnail, neither of which this column has, and giving it a loader of
    /// its own would be per-render I/O in a column that re-renders with the
    /// window (tripwire 4). `PaletteCardEditor` owns that load (`.task(id:
    /// cardId)`) and its debounced save, and it is the app's one card surface.
    /// It is never mounted twice for one card: this half is shown only where the
    /// placement is `.besideTheCanvas`, and there the centre column is the
    /// canvas.
    @ViewBuilder
    private func preview(of item: ResearchItem) -> some View {
        switch ProjectWindow.researchCentreRoute(id: item.id,
                                                 in: store.manifest.research) {
        case .paletteCard(let cardID):
            PaletteCardEditor(store: store, cardId: cardID)
        case .note(let item, _), .preview(let item):
            ResearchPreview(projectURL: store.url, item: item)
        case .missing:
            // Unreachable — the caller found this item in the same manifest the
            // route reads, so the route cannot fail to find it. Kept because the
            // switch is exhaustive and the compiler asks, and pointed at the
            // same empty state the body's own `else` shows.
            ContentUnavailableView("Select an item", systemImage: "info.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

import SwiftUI
import AppKit
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
    /// - `takesTheCentre` — the item is the subject's `open`: the centre column
    ///   shows it, and the right column inspects it.
    /// - `beside` — the item is the subject's `beside` (a click): the centre is
    ///   left alone and the right column previews the item under its Open in
    ///   Centre and close controls (`BesideHeader`), **whatever the centre is**
    ///   — a research item open in the centre included, which the case carries
    ///   as `centre`. The canvas STAYS MOUNTED; `CanvasTreeSegmentMountTests`
    ///   measured what a second centre-column branch costs (the camera back to
    ///   origin, every scrap layout re-measured, the thumbnail cache emptied).
    /// - `nothingMoves` — the subject names no research item in either place.
    ///
    /// A third case, `.segmentStands`, guarded against a left column that was
    /// not the tree: a research item taking a column while nothing on screen
    /// could point the window anywhere else is a room with no door, which is the
    /// Critical stage 2a's final review found. Shell-finish stage 2b Task 7
    /// made the tree the whole left column in every persona, so the trap is not
    /// expressible and the guard went with the enum it was asked of. Its
    /// successor question is about the find OVERLAY — with the panel over the
    /// column there is no row to click — and the answer is asserted rather than
    /// assumed: `treeFindActive` is window `@State` no relaunch restores,
    /// Escape puts the tree back, and ⌘⌥O reaches the project row with the
    /// overlay up (`AltitudeKeyspaceTests.test_cmdOptOStillActsWhileFindCoversTheColumn`),
    /// which are exactly the properties that Critical lacked. So the overlay
    /// is deliberately NOT a term here.
    enum ResearchSubjectPlacement: Equatable {
        case takesTheCentre(String)
        /// The item beside, and the research item the centre shows, if any.
        case beside(String, centre: String? = nil)
        /// The subject names no research item. It was `.segmentStands` while
        /// there were segments for one to stand.
        case nothingMoves

        /// The item the CENTRE column shows, or `nil` when the centre is not
        /// the research subject's to take.
        var centreItemID: String? {
            switch self {
            case .takesTheCentre(let id): return id
            case .beside(_, let centre): return centre
            case .nothingMoves: return nil
            }
        }

        /// The item the RIGHT column shows, or `nil`.
        var inspectedItemID: String? {
            switch self {
            case .takesTheCentre(let id), .beside(let id, _): return id
            case .nothingMoves: return nil
            }
        }

        /// Whether the right column also PREVIEWS the item's content rather
        /// than only inspecting it — true exactly when the item is beside,
        /// which is never what the centre shows, because otherwise the writer
        /// has no way to read what they just pulled up.
        var previewsInTheRightColumn: Bool {
            if case .beside = self { return true }
            return false
        }
    }

    /// Pure, named and exhaustive over its inputs, for `inspectorRoute`'s
    /// reason: the two routing bugs that shape says out loud were both a rule
    /// spelled inside a `@ViewBuilder` where no test could be exhaustive over
    /// it.
    ///
    /// **Asked of the subject's two places.** A research item in `beside` (a
    /// click) previews in the right column whatever the centre is — the canvas
    /// keeps its one mount, the editor its document, and a research item open
    /// in the centre stays there (`centre`). A research item in `open` (a
    /// double-click, Open in Centre) takes the centre and, with nothing else
    /// beside, the right column inspects it. The same item in both places is
    /// the centre's: one card or grid is never mounted twice.
    static func researchSubjectPlacement(subject: WindowSubject) -> ResearchSubjectPlacement {
        let centre = subject.open.researchID
        if let id = subject.beside?.researchID, id != centre {
            return .beside(id, centre: centre)
        }
        if let centre { return .takesTheCentre(centre) }
        return .nothingMoves
    }

    /// **Open in Centre** — the beside view's control: the click rule's
    /// `.openInCentre` on what is beside, so the thing beside becomes `open`
    /// and the faces, and leaves `beside`. Nothing beside moves nothing.
    static func openingBesideInCentre(_ subject: WindowSubject,
                                      structure: [StructureItem],
                                      projectType: ProjectType) -> WindowSubject {
        guard let beside = subject.beside else { return subject }
        return ClickRule.resolve(beside, gesture: .openInCentre, current: subject,
                                 structure: structure, projectType: projectType)
    }

    /// **Close** — the beside view's other control: what is beside is put
    /// away, and nothing else moves.
    static func closingBeside(_ subject: WindowSubject) -> WindowSubject {
        var next = subject
        next.beside = nil
        return next
    }

    /// **Showing the column the placement chose** (stage 2b final review's
    /// Critical) — for a research item or a figure alike.
    ///
    /// `beside` says the right column previews the item. It does not
    /// make that column VISIBLE: `ResearchSubjectInspector` is mounted by
    /// `DetailPaneToggle`'s `.inspector` arm alone. Without this a research row
    /// would write a subject that reaches no surface at all.
    ///
    /// **What it does NOT do is decide anything about the columns.** Where the
    /// centre takes the item this writes nothing, so a writer's pane choice is
    /// never moved by an item they can already see; the guard is the
    /// placement's own answer, asked rather than restated.
    ///
    /// `inout` and static so the whole rule is drivable without a window, and so
    /// the three sites that reveal — the subject observer
    /// (`ResearchRevealModifier`) and the two forced entries (`openResearchItem`,
    /// `handleShowLatestMCPNote`) — cannot come to disagree about what revealing
    /// means.
    static func revealResearchColumn(subject: WindowSubject,
                                     showInspector: inout Bool,
                                     detailSegment: inout DetailSegment) {
        guard researchSubjectPlacement(subject: subject).previewsInTheRightColumn
            || figureSubjectPlacement(subject: subject).besideFigureID != nil
        else { return }
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
        /// A table (a CSV) — the table grid (`ResearchTableGrid`, report plan
        /// 8b Task 7), saving back to its file.
        case table(item: ResearchItem, path: String)
        /// Everything the writer cannot edit here — a PDF, an image, audio, a
        /// link, a group — via `ResearchPreview`.
        case preview(ResearchItem)
        /// The id names nothing. The subject sweep lands a dangling id on
        /// `.project` before it reaches here (stage-2a Task 2), so this is the
        /// render-race window in which the subject and the manifest have
        /// arrived in different passes.
        case missing
    }

    /// **Every case, rather than the three a plan can carry.** Collapsing
    /// `.preview` into `.note` would leave the palette-vs-note decision here and
    /// the note-vs-preview decision inside the view, which is the split this
    /// function exists to close.
    static func researchCentreRoute(id: String?,
                                    in manifest: ProjectManifest) -> ResearchCentreRoute {
        guard let id, let item = TreeWalk.find(id: id, in: manifest.research) else { return .missing }
        // A table outside a research root is not opened in the grid: it falls
        // to the preview, as a note outside one does.
        if let path = ResearchTextRole.tablePath(of: item, structure: manifest.structure) {
            return .table(item: item, path: path)
        }
        // Note or card is asked of the one predicate the note door asks too.
        switch ResearchTextRole.of(item, structure: manifest.structure, research: manifest.research) {
        case .paletteCard: return .paletteCard(item.id)
        case .note(let path): return .note(item: item, path: path)
        case nil: return .preview(item)
        }
    }
}

/// **The centre column for a research subject** — the one mount of the three
/// research editors, reached from `CentreColumn`'s `.research` route
/// (`ProjectWindow.centreRoute`).
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
    /// unaffected — both were already read-only. The `.table` arm's grid reads
    /// the table and refuses its edits.
    let readOnly: Bool
    /// The share is view-only: a Research table's grid reads, never writes.
    var shareIsReadOnly: Bool = false
    /// The grid's typography and the window's Format ▸ Table presence.
    var typography: TypographySettings = .defaults
    var presence: FigureGridPresence? = nil
    var window: NSWindow? = nil

    var body: some View {
        switch ProjectWindow.researchCentreRoute(id: itemID, in: store.manifest) {
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
                lockEditing: readOnly,
                shareIsReadOnly: shareIsReadOnly)
        case .table(let item, _):
            ResearchTableGrid(
                itemId: item.id, title: item.title, store: store, documentStore: documentStore,
                typography: typography, readOnly: readOnly, shareIsReadOnly: shareIsReadOnly,
                presence: presence, window: window)
                .id(item.id)
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
    /// For the panel's verb toward Figures (`InspectorResearchPanel.figureTree`).
    var figureTree: BinderTreeSectionsState? = nil
    var figureWritesRefused: Bool = false
    /// What a Research table's grid needs beside the canvas (Plan): the
    /// window's `DocumentStore` (nil previews the table as text), the
    /// persona's and share's answers, the typography.
    var documentStore: DocumentStore? = nil
    var readOnly: Bool = false
    var shareIsReadOnly: Bool = false
    var typography: TypographySettings = .defaults
    /// The project window, whose close writes the grid's last edit, and its
    /// Format ▸ Table presence, armed while the grid has the keys.
    var window: NSWindow? = nil
    var presence: FigureGridPresence? = nil

    var body: some View {
        if let itemID, let item = TreeWalk.find(id: itemID, in: store.manifest.research) {
            if showsPreview {
                VStack(spacing: 0) {
                    preview(of: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    InspectorResearchPanel(store: store, item: item, figureTree: figureTree,
                                           figureWritesRefused: figureWritesRefused,
                                           documentStore: documentStore, shareIsReadOnly: shareIsReadOnly,
                                           reviewing: readOnly)
                }
            } else {
                InspectorResearchPanel(store: store, item: item, figureTree: figureTree,
                                           figureWritesRefused: figureWritesRefused,
                                           documentStore: documentStore, shareIsReadOnly: shareIsReadOnly,
                                           reviewing: readOnly)
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
    /// placement is `.beside`, which is never the item the centre shows.
    ///
    /// `.table` reaches the same grid the centre mounts (`ResearchTableGrid`,
    /// report plan 8b Task 7) — never twice, for the card's reason.
    @ViewBuilder
    private func preview(of item: ResearchItem) -> some View {
        switch ProjectWindow.researchCentreRoute(id: item.id,
                                                 in: store.manifest) {
        case .paletteCard(let cardID):
            PaletteCardEditor(store: store, cardId: cardID)
        case .table(let item, _):
            if let documentStore {
                ResearchTableGrid(
                    itemId: item.id, title: item.title, store: store, documentStore: documentStore,
                    typography: typography, readOnly: readOnly, shareIsReadOnly: shareIsReadOnly,
                    presence: presence, window: window)
                    .id(item.id)
            } else {
                ResearchPreview(projectURL: store.url, item: item)
            }
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

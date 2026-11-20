import SwiftUI
import AppKit
import MaughamCore

/// **The pulled-up thing, drawn** (shell plan 3 Task 7) — the right column's
/// third position: the one item the writer pulled up beside the centre, under
/// `BesideHeader` (its title, middle-truncated; **Open in Centre**; close).
///
/// **Every arm is a surface the app already ships**, never a second one:
/// - a research item is `ResearchSubjectInspector` with its preview half —
///   a note as `ResearchNoteEditor`, a SECOND editor (`editsNotes`), a palette
///   card as `PaletteCardEditor`/`PaletteCardReadHost` (`PaletteCardSurface`),
///   a table as its grid, anything else as `ResearchPreview` — above
///   `InspectorResearchPanel` (citation, versions);
/// - a figure is `FigureSubjectSurface` over `FigureInspector` (its uses);
/// - a canvas card is READ-ONLY here (`PulledUp.isEditableBeside`): the
///   scrap's words read from the canvas's model or sidecar and drawn as text,
///   never an editor on the canvas's shared text storage (tripwires 26–28);
///   a picture is `ImagePreview`. Open in Centre opens the canvas and selects
///   the card (`CanvasModel.revealAndSelect`);
/// - a statement is `StatementPane` — another `StatementEditorHost`, ordered
///   by the load-level gate — unless the centre's cover holds it
///   (`ProjectWindow.statementIsInTheCentre`), when this draws the placeholder
///   over the reading view and never a second editor;
/// - History is `HistoryPane`, for a piece open or not.
///
/// **Lock and posture apply exactly as in the centre**: research and figures
/// ask `PulledUp.refusesEdits(isLocked:)` / take `isLocked`; a statement asks
/// its own posture inside `StatementPane`. Hidden, never disabled.
///
/// **With nothing pulled up** it shows the details of what the centre holds
/// (`RightColumnContent.centreDetails`): the canvas's selected card or region,
/// a figure's inspector, a research item's panel, a Collection reference
/// piece; else "Nothing pulled up". **With the canvas the centre**, its
/// selection's details cover what is pulled up while there is a selection
/// (`CanvasDetailsCover`); what is pulled up stays pulled up.
struct PulledUpView: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    @Binding var subject: WindowSubject
    /// The window's centre item: a statement in the cover is never bound here.
    let centreItem: CentreItem?
    let canvasModel: CanvasModel
    let editorControl: EditorControl
    let figureListing: FigureListingModel
    let figureGridPresence: FigureGridPresence
    let figureWindows: FigureWindows?
    let window: NSWindow?
    let isLocked: Bool
    let figureTree: BinderTreeSectionsState?
    let bible: BibleStore?
    let world: DeclaredWorldStore?
    /// `ProjectWindow.openInCentre`: a statement or History as the centre's cover.
    let onOpenInCentre: (CentreItem) -> Void
    /// The card the palette wall shows while it has the centre
    /// (`ProjectWindow.selectedPaletteCardId`, window state the subject does
    /// not carry) — so a card on the wall is never edited beside it too.
    var paletteWallCard: String? = nil
    /// A figure inspector's "Show notes" (To resolve, scoped to the figure).
    var onShowNotes: (String) -> Void = { _ in }
    /// The canvas's details (the selected region or card), drawn by the
    /// host — `RightColumn.canvasInspector`, the one `RegionInspectorPane`
    /// mount. Nil shows "Nothing pulled up" where the canvas has the centre,
    /// and nothing covers what is pulled up.
    var canvasDetails: (() -> AnyView)? = nil

    /// A pulled-up canvas card, read off the body path.
    @State private var card: CanvasCardRead?

    // MARK: - The decisions, pure

    /// What a pulled-up canvas card reads as.
    enum CanvasCardRead: Equatable {
        case scrap(text: String)
        case photo(path: String)
        /// No longer on the canvas.
        case missing
    }

    /// What the view draws for a pulled-up thing.
    enum Face: Equatable {
        /// `ResearchSubjectInspector`; its preview half only when the centre
        /// does not show the same item (the placement's rule).
        case research(id: String, readOnly: Bool, preview: Bool)
        case figure(id: String, surface: Bool)
        case canvasScrap(text: String)
        case canvasPhoto(path: String)
        /// A canvas card not read yet: nothing, for the one frame.
        case readingCard
        case missingCard
        /// `StatementPane`, its own host.
        case statement(Statement.Kind)
        /// The centre's cover holds it: the placeholder over the reading view.
        case statementInTheCentre(Statement.Kind)
        case history(docId: String)
        /// The centre's cover shows it.
        case historyInTheCentre(docId: String)
    }

    /// What the centre is showing, as far as the pulled-up thing is
    /// concerned: the window's subject and centre item, plus the two
    /// selections the subject does not carry.
    struct Centre: Equatable {
        var subject: WindowSubject
        var centreItem: CentreItem? = nil
        /// The palette wall's selected card (`ProjectWindow.selectedPaletteCardId`).
        var paletteWallCard: String? = nil
    }

    /// **Whether the centre already shows the pulled-up thing** — THE rule,
    /// spelled once: never a second editor on the item the centre shows. A
    /// research item open in the centre (the placement's own answer), a card
    /// selected on the palette wall, a figure in the centre, a statement or
    /// History in the centre's cover. A canvas card is never "shown by the
    /// centre" here: beside it is read-only words in every case, following the
    /// canvas's own typing (`liveCard`), so there is no second editor to
    /// refuse and nothing for the answer to change.
    /// Where it does, the pulled-up view draws the read-only form or the
    /// "open in the centre" line.
    static func centreShows(_ pulled: PulledUp, centre: Centre) -> Bool {
        var subject = centre.subject
        subject.beside = pulled
        switch pulled {
        case .research(let id):
            if ProjectWindow.showsPaletteWallCentre(subject: subject), centre.paletteWallCard == id {
                return true
            }
            return !ProjectWindow.researchSubjectPlacement(subject: subject).previewsInTheRightColumn
        case .figure:
            return ProjectWindow.figureSubjectPlacement(subject: subject).besideFigureID == nil
        case .canvasScrap, .canvasPhoto:
            return false
        case .lessons, .firstReader, .visualLanguage, .history:
            return pulled.centreItem != nil && pulled.centreItem == centre.centreItem
        }
    }

    static func face(of pulled: PulledUp, centre: Centre, isLocked: Bool,
                     card: CanvasCardRead?) -> Face {
        let inTheCentre = centreShows(pulled, centre: centre)
        var subject = centre.subject
        subject.beside = pulled
        switch pulled {
        case .research(let id):
            // The item itself only where the placement previews it beside;
            // read-only wherever the centre shows it.
            return .research(id: id,
                             readOnly: inTheCentre || pulled.refusesEdits(isLocked: isLocked),
                             preview: ProjectWindow.researchSubjectPlacement(subject: subject)
                                .previewsInTheRightColumn)
        case .figure(let id):
            return .figure(id: id, surface: !inTheCentre)
        case .canvasScrap, .canvasPhoto:
            // Read-only beside in every case (`PulledUp.isEditableBeside`).
            switch card {
            case .scrap(let text)?: return .canvasScrap(text: text)
            case .photo(let path)?: return .canvasPhoto(path: path)
            case .missing?: return .missingCard
            case nil: return .readingCard
            }
        case .lessons, .firstReader, .visualLanguage:
            guard let statement = pulled.statement else {
                preconditionFailure("every statement case names its statement")
            }
            return inTheCentre ? .statementInTheCentre(statement.kind) : .statement(statement.kind)
        case .history(let docId):
            return inTheCentre ? .historyInTheCentre(docId: docId) : .history(docId: docId)
        }
    }

    /// **The scrap the writer is typing on the canvas, as they type it.**
    /// While the canvas is attached its model folds every keystroke into
    /// `scraps` (tripwire 28), observably, so the copy beside reads it there
    /// — never an editor on the shared storage. A closed canvas's words are
    /// the `.task`'s read of the sidecar.
    @MainActor
    static func liveCard(_ read: CanvasCardRead?, pulled: PulledUp, model: CanvasModel) -> CanvasCardRead? {
        guard case .canvasScrap(let nodeId) = pulled, model.isAttached, case .scrap? = read,
              let text = model.scraps[CanvasNodeID(nodeId)] else { return read }
        return .scrap(text: text)
    }

    /// What Open in Centre does.
    enum Opening: Equatable {
        /// The click rule's open-in-centre (a research item, a figure).
        case subject(WindowSubject)
        /// The canvas opens, and selects this card when it names one.
        case canvas(WindowSubject, node: CanvasNodeID?)
        /// The centre's cover (`ProjectWindow.openInCentre`).
        case centreItem(CentreItem)
    }

    /// `subject` is the window's, with `pulled` beside.
    static func opening(_ pulled: PulledUp, subject: WindowSubject,
                        structure: [StructureItem], projectType: ProjectType,
                        photoNode: (String) -> CanvasNodeID?) -> Opening {
        if let item = pulled.centreItem { return .centreItem(item) }
        var current = subject
        current.beside = pulled
        let next = ProjectWindow.openingBesideInCentre(current, structure: structure,
                                                       projectType: projectType)
        switch pulled {
        case .canvasScrap(let nodeId): return .canvas(next, node: CanvasNodeID(nodeId))
        case .canvasPhoto(let path): return .canvas(next, node: photoNode(path))
        case .research, .figure, .lessons, .firstReader, .visualLanguage, .history:
            return .subject(next)
        }
    }

    /// A pulled-up canvas card against a scene; nil for every other kind.
    static func read(_ pulled: PulledUp, scene: CanvasScene,
                     scraps: [CanvasNodeID: String]) -> CanvasCardRead? {
        switch pulled {
        case .canvasScrap(let nodeId):
            let id = CanvasNodeID(nodeId)
            guard scene.node(id) != nil else { return .missing }
            return .scrap(text: scraps[id] ?? "")
        case .canvasPhoto(let path):
            return photoNode(path, in: scene) == nil ? .missing : .photo(path: path)
        case .research, .figure, .lessons, .firstReader, .visualLanguage, .history:
            return nil
        }
    }

    /// Whether a pulled-up canvas card is still on the canvas (true for every
    /// other kind) — `WindowSubject.validated`'s answer.
    static func cardIsOnTheCanvas(_ pulled: PulledUp, scene: CanvasScene) -> Bool {
        read(pulled, scene: scene, scraps: [:]) != .missing
    }

    /// **The centre's own research details under Lock** (its citation, tags
    /// and versions, drawn here while nothing is pulled up): read-only exactly
    /// where the same item pulled up would be — Lock's one answer.
    static func centreResearchIsReadOnly(_ id: String, isLocked: Bool) -> Bool {
        PulledUp.research(id).refusesEdits(isLocked: isLocked)
    }

    /// The node holding a canvas-owned picture, the lowest id when several do.
    static func photoNode(_ path: String, in scene: CanvasScene) -> CanvasNodeID? {
        scene.unorderedNodes
            .filter { $0.kind == .item(.owned(path: path)) }
            .map(\.id)
            .min { $0.raw < $1.raw }
    }

    /// The header's title for a pulled-up thing.
    @MainActor
    static func title(of pulled: PulledUp, store: ProjectStore) -> String {
        switch pulled {
        case .research(let id):
            return TreeWalk.find(id: id, in: store.manifest.research)?.title ?? ""
        case .figure(let id):
            return (store.manifest.figures ?? []).first { $0.id == id }?.name ?? ""
        case .canvasScrap: return canvasCardTitle
        case .canvasPhoto: return CanvasItemFacts.ownedTitle
        case .lessons: return BriefBookView.lessonsTitle
        case .firstReader: return BriefBookView.firstReaderTitle
        case .visualLanguage: return BriefBookView.visualLanguageTitle
        case .history(let docId):
            return CentreItemCover.title(of: .history(docId: docId), structure: store.manifest.structure)
        }
    }

    static let canvasCardTitle = "Canvas card"
    static let missingCardLine = "This card is no longer on the canvas."
    static let readOnlyCardLine = "Read-only here. Open in Centre to edit it on the canvas."
    static let historyInTheCentreLine = "Open in the centre"
    static let nothingPulledUpTitle = "Nothing pulled up"

    // MARK: - The view

    var body: some View {
        Group {
            if let pulled = subject.beside, let canvasDetails {
                // The selection is read one leaf down, never here.
                CanvasDetailsCover(model: canvasModel,
                                   canvasIsTheCentre: subject.open == .canvas,
                                   details: canvasDetails) { pulledUpFace(pulled) }
            } else if let pulled = subject.beside {
                pulledUpFace(pulled)
            } else {
                centreDetails
            }
        }
        // A canvas card is read off the body path, again on every structural
        // change of the canvas (never the per-frame counter, tripwire 30).
        .task(id: cardReadKey) {
            guard let pulled = cardReadKey?.card else { card = nil; return }
            let read = CanvasClaudeWrite.readScene(store: store, projectRoot: store.url)
            card = Self.read(pulled, scene: read.scene, scraps: read.scraps)
        }
    }

    /// The pulled-up thing under its header.
    private func pulledUpFace(_ pulled: PulledUp) -> some View {
        VStack(spacing: 0) {
            BesideHeader(
                title: Self.title(of: pulled, store: store),
                openInCentre: { openInCentre(pulled) },
                close: { subject = ProjectWindow.closingBeside(subject) })
            Divider()
            content(pulled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private struct CardReadKey: Equatable {
        let card: PulledUp
        let revision: Int
    }

    /// Only a canvas card reads the canvas, and only it observes the revision.
    private var cardReadKey: CardReadKey? {
        switch subject.beside {
        case let pulled? where pulled.isACanvasCard:
            return CardReadKey(card: pulled, revision: canvasModel.sceneRevision)
        default:
            return nil
        }
    }

    private func openInCentre(_ pulled: PulledUp) {
        let opening = Self.opening(
            pulled, subject: subject, structure: store.manifest.structure,
            projectType: store.manifest.type,
            photoNode: { [canvasModel] path in Self.photoNode(path, in: canvasModel.scene) })
        switch opening {
        case .subject(let next):
            subject = next
        case .canvas(let next, let node):
            subject = next
            if let node { canvasModel.revealAndSelect(node) }
        case .centreItem(let item):
            // The cover takes it, and it leaves the pulled-up position in the
            // same update (`ProjectWindow.openingInCentre`), as every kind does.
            onOpenInCentre(item)
        }
    }

    @ViewBuilder
    private func content(_ pulled: PulledUp) -> some View {
        let card = Self.liveCard(card, pulled: pulled, model: canvasModel)
        let centre = Centre(subject: subject, centreItem: centreItem, paletteWallCard: paletteWallCard)
        switch Self.face(of: pulled, centre: centre, isLocked: isLocked, card: card) {
        case .research(let id, let readOnly, let preview):
            researchInspector(id, showsPreview: preview, readOnly: readOnly)
        case .figure(let id, let surface):
            if surface {
                VStack(spacing: 0) {
                    FigureSubjectSurface(
                        figureID: id, store: store, documentStore: documentStore,
                        figureWindows: figureWindows, presence: figureGridPresence,
                        listing: figureListing, control: editorControl,
                        isLocked: isLocked, window: window)
                        .frame(maxHeight: .infinity)
                    Divider()
                    figureInspector(id).frame(maxHeight: .infinity)
                }
            } else {
                figureInspector(id)
            }
        case .canvasScrap(let text):
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    quiet(Self.readOnlyCardLine)
                }
                .padding(16)
            }
        case .canvasPhoto(let path):
            if let url = try? SafeRelativePath.resolve(path, under: store.url) {
                ImagePreview(fileURL: url)
            }
        case .readingCard:
            Color.clear
        case .missingCard:
            VStack(spacing: 0) {
                ContentUnavailableView {
                    Label(Self.missingCardLine, systemImage: CanvasItemKind.missingGlyph)
                } actions: {
                    Button(BesideHeader.closeLabel) {
                        subject = ProjectWindow.closingBeside(subject)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .statement(let kind):
            StatementPane(store: store, documentStore: documentStore, kind: kind,
                          subject: .project, bible: bible, world: world)
                // One statement per mount: another one pulled up is another
                // host, never this one rebound in place.
                .id(pulled)
        case .statementInTheCentre(let kind):
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    quiet(GoingForView.inTheCentreLine)
                    ForEach(Array(GoingForView.paragraphs(of: liveEssay(kind) ?? "", marks: [])
                                    .enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
        case .history(let docId):
            HistoryPane(
                projectURL: store.url,
                activeDocId: docId,
                allDocIds: ProjectWindow.documentIds(in: store.manifest.structure),
                device: _checkpointDeviceId,
                session: _checkpointSessionId,
                docPaths: ProjectWindow.documentPaths(in: store.manifest.structure),
                documentStore: documentStore)
                .id(docId)
        case .historyInTheCentre:
            VStack(alignment: .leading) {
                quiet(Self.historyInTheCentreLine)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The statement as the centre's cover is writing it — read from the live
    /// `Document` the cover holds, so the reading view follows the typing
    /// with no re-read (`GoingForView`'s shape).
    private func liveEssay(_ kind: Statement.Kind) -> String? {
        _ = store.statementTextRevision
        guard let id = store.statement(kind: kind, scope: .project)?.id,
              let live = store.openStatementDocument(id: id) else { return nil }
        return StatementEssay.half(of: live.displayText)
    }

    private func quiet(_ line: String) -> some View {
        Text(line)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func researchInspector(_ id: String, showsPreview: Bool, readOnly: Bool) -> some View {
        ResearchSubjectInspector(
            store: store, itemID: id,
            showsPreview: showsPreview, figureTree: figureTree,
            figureWritesRefused: FigureActions.windowRefusesWrites(control: editorControl, isLocked: isLocked),
            documentStore: documentStore, readOnly: readOnly,
            shareIsReadOnly: editorControl.shareIsReadOnly, typography: editorControl.typography,
            window: window, presence: figureGridPresence,
            editsNotes: true)
    }

    private func figureInspector(_ id: String) -> some View {
        FigureInspector(
            figureId: id, store: store, documentStore: documentStore, listing: figureListing,
            figureWindows: figureWindows, figureTree: figureTree, control: editorControl,
            isLocked: isLocked, window: window,
            select: { target in
                subject = ManuscriptNavigation.travel(
                    to: target, current: subject, structure: store.manifest.structure,
                    projectType: store.manifest.type)
            },
            showNotes: onShowNotes)
            .id(id)
    }

    // MARK: - With nothing pulled up: the centre's details

    @ViewBuilder
    private var centreDetails: some View {
        switch RightColumnContent.centreDetails(subject, structure: store.manifest.structure,
                                                projectType: store.manifest.type) {
        case .canvas?:
            // The host's region inspector — `RegionInspectorPane` keeps its
            // one mount (`RightColumn.canvasInspector`, tripwire 30's census).
            if let canvasDetails { canvasDetails() } else { nothingPulledUp }
        case .figure(let id)?:
            figureInspector(id)
        case .research(let id)?:
            researchInspector(id, showsPreview: false,
                              readOnly: Self.centreResearchIsReadOnly(id, isLocked: isLocked))
        case .referencePiece(let id)?:
            ReferencePieceInspector(store: store, pieceId: id)
        case nil:
            nothingPulledUp
        }
    }

    private var nothingPulledUp: some View {
        VStack(spacing: 0) {
            ContentUnavailableView(Self.nothingPulledUpTitle, systemImage: "pin")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension PulledUp {
    /// A scrap or a picture the canvas holds.
    var isACanvasCard: Bool {
        switch self {
        case .canvasScrap, .canvasPhoto: return true
        case .research, .figure, .lessons, .firstReader, .visualLanguage, .history: return false
        }
    }
}

/// **The pulled-up view's header** (shell p1 Task 4; moved here in shell p3
/// Task 7): the pulled-up item's title, truncated in the middle with the
/// whole of it in its tooltip, then two plain visible buttons — **Open in
/// Centre** and close. A view of its own so the labels the buttons, their
/// help and a test read are one spelling.
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

/// **The canvas's details over the pulled-up thing** (owner, 2026-11-20):
/// `RightColumnContent.canvasDetailsCover` decides; this leaf only supplies
/// the one value the column must not read.
///
/// **It reads `model.selection` and nothing else.** The selection is its own
/// stored property, written on a click, a drop, a key or a delete — never per
/// drag frame — so this leaf is not a dependency of the drag loop the way a
/// read of `scene` would make it (tripwire 30). A selection an undo left
/// dangling is cleared by the model itself (`clearSelectionIfItNoLongerResolves`),
/// so "non-nil" is "names something on the canvas".
struct CanvasDetailsCover<PulledUpFace: View>: View {
    let model: CanvasModel
    let canvasIsTheCentre: Bool
    /// `RightColumn.canvasInspector`, the one `RegionInspectorPane` mount.
    let details: () -> AnyView
    @ViewBuilder let pulledUp: () -> PulledUpFace

    var body: some View {
        if RightColumnContent.canvasDetailsCover(canvasIsTheCentre: canvasIsTheCentre,
                                                 somethingIsPulledUp: true,
                                                 canvasHasASelection: model.selection != nil) {
            details()
        } else {
            pulledUp()
        }
    }
}

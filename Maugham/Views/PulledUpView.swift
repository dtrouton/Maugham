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
/// piece; else "Nothing pulled up".
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
    /// A figure inspector's "Show notes" (To resolve, scoped to the figure).
    var onShowNotes: (String) -> Void = { _ in }
    /// The canvas's details (the selected region or card), drawn by the
    /// host — `RightColumn.canvasInspector`, the one `RegionInspectorPane`
    /// mount. Nil shows "Nothing pulled up" where the canvas has the centre.
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

    static func face(of pulled: PulledUp, subject: WindowSubject, isLocked: Bool,
                     centreItem: CentreItem?, card: CanvasCardRead?) -> Face {
        switch pulled {
        case .research(let id):
            return .research(id: id, readOnly: pulled.refusesEdits(isLocked: isLocked),
                             preview: subject.open.researchID != id)
        case .figure(let id):
            return .figure(id: id, surface: subject.open.figureID != id)
        case .canvasScrap, .canvasPhoto:
            switch card {
            case .scrap(let text)?: return .canvasScrap(text: text)
            case .photo(let path)?: return .canvasPhoto(path: path)
            case .missing?: return .missingCard
            case nil: return .readingCard
            }
        case .lessons, .firstReader, .visualLanguage:
            guard let statement = pulled.statement else { return .missingCard }
            return ProjectWindow.statementIsInTheCentre(kind: statement.kind, scope: statement.scope,
                                                        centreItem: centreItem)
                ? .statementInTheCentre(statement.kind) : .statement(statement.kind)
        case .history(let docId):
            return centreItem == .history(docId: docId)
                ? .historyInTheCentre(docId: docId) : .history(docId: docId)
        }
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
            if let pulled = subject.beside {
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
            // The cover takes it; what is pulled up stays and reads the
            // placeholder while the cover holds it (`openingInCentre`).
            onOpenInCentre(item)
        }
    }

    @ViewBuilder
    private func content(_ pulled: PulledUp) -> some View {
        switch Self.face(of: pulled, subject: subject, isLocked: isLocked,
                         centreItem: centreItem, card: card) {
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
                              readOnly: PulledUp.research(id).refusesEdits(isLocked: isLocked))
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

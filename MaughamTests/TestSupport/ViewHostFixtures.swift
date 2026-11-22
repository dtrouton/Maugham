import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

// **One builder per view host** (shell p4 Task 1). Each fixture below passes
// exactly the arguments, and applies exactly the `.environment(\.…)` keys, of
// the host's one production site, so a mounted test meets the view the writer
// meets. The whole-branch review's C1 was a dead feature hidden by tests that
// built `PulledUpView` without the `canvasDetails` production always passes.
//
// `HostBuilderCensusTests` keeps it so: no test outside `TestSupport/` builds
// one of these hosts by hand, and each fixture's argument labels and
// environment keys equal its production site's. A new production argument
// fails the census until the fixture passes it.
//
// **Defaults** stand only for what production itself varies (a subject, a
// width, a store, a per-window model that is always live — a `nil` parameter
// there means a fresh live model, never a `nil` handed to the view): an
// argument production always passes is always passed here, never left to the
// view's own default (a `nil` memory, a `nil` canvasDetails).

/// `PulledUpView` as `RightColumn.content` builds it.
@MainActor
enum PulledUpFixture {

    /// A stand-in for `RightColumn.canvasInspector` (the one
    /// `RegionInspectorPane` mount), for a test that reads only whether the
    /// canvas's details drew.
    static let canvasDetailsMarker = "The canvas's details, drawn by the host"

    /// The marker as the `canvasDetails` closure.
    static func markerDetails() -> AnyView { AnyView(Text(canvasDetailsMarker)) }

    static func view(
        store: ProjectStore, documentStore: DocumentStore,
        subject: Binding<WindowSubject>,
        centreItem: CentreItem? = nil,
        canvasModel: CanvasModel? = nil,
        editorControl: EditorControl? = nil,
        figureListing: FigureListingModel? = nil,
        figureGridPresence: FigureGridPresence? = nil,
        figureWindows: FigureWindows? = nil, window: NSWindow? = nil,
        readThrough: ReadThroughGate = .writing,
        figureTree: BinderTreeSectionsState,
        bible: BibleStore? = nil, world: DeclaredWorldStore? = nil,
        onOpenInCentre: @escaping (CentreItem) -> Void,
        paletteWallCard: String? = nil,
        memory: PulledUpMemory,
        onShowNotes: @escaping (String) -> Void,
        canvasDetails: @escaping () -> AnyView
    ) -> PulledUpView {
        PulledUpView(
            store: store, documentStore: documentStore, subject: subject,
            centreItem: centreItem, canvasModel: canvasModel ?? CanvasModel(),
            editorControl: editorControl ?? EditorControl(),
            figureListing: figureListing ?? FigureListingModel(),
            figureGridPresence: figureGridPresence ?? FigureGridPresence(),
            figureWindows: figureWindows,
            window: window, readThrough: readThrough, figureTree: figureTree,
            bible: bible, world: world,
            onOpenInCentre: onOpenInCentre,
            paletteWallCard: paletteWallCard,
            memory: memory,
            onShowNotes: onShowNotes,
            canvasDetails: canvasDetails)
    }
}

/// `RightColumnControl` as `RightColumn.pane` builds it.
@MainActor
enum RightColumnControlFixture {

    static func control(
        store: ProjectStore, position: Binding<RightColumnPosition>,
        subject: WindowSubject, diagnostics: DiagnosticsStore? = nil,
        width: CGFloat, closedCanvasWrites: Int = 0,
        canvasModel: CanvasModel, readIn: String? = nil, sourceLanguage: String = "en"
    ) -> RightColumnControl {
        RightColumnControl(
            store: store, position: position, subject: subject,
            diagnostics: diagnostics,
            width: width,
            closedCanvasWrites: closedCanvasWrites,
            canvasModel: canvasModel,
            readIn: readIn,
            sourceLanguage: sourceLanguage)
    }
}

/// The three tree hosts and the piece fold, as `BinderPaneToggle`,
/// `CollectionBinderPaneToggle`, `BinderView` and `CollectionPiecesPane`
/// build them, under the environment `ProjectWindow`'s tree column sets
/// (`windowCanvas`) and, for the fold, the one its host sets
/// (`rowThumbnailRoot`).
///
/// The `…View` builders return the bare host, for a test that asks one of
/// its methods without mounting it; the others are what a test mounts.
@MainActor
enum TreeHostFixture {

    // MARK: - BinderView (`BinderPaneToggle.binderTree`)

    static func binderView(
        store: ProjectStore, subject: Binding<WindowSubject>,
        treeState: BinderTreeSectionsState,
        canvasKeyboard: TreeCanvasKeyboard = TreeCanvasKeyboard()
    ) -> BinderView {
        BinderView(store: store, subject: subject,
                   treeState: treeState,
                   canvasKeyboard: canvasKeyboard)
    }

    static func binder(
        store: ProjectStore, subject: Binding<WindowSubject>,
        treeState: BinderTreeSectionsState,
        canvasKeyboard: TreeCanvasKeyboard = TreeCanvasKeyboard(),
        windowCanvas: CanvasModel? = nil
    ) -> some View {
        binderView(store: store, subject: subject, treeState: treeState,
                   canvasKeyboard: canvasKeyboard)
            .environment(\.windowCanvas, windowCanvas ?? CanvasModel())
    }

    // MARK: - CollectionPiecesPane (`CollectionBinderPaneToggle.piecesTree`)

    static func collectionView(
        store: ProjectStore, subject: Binding<WindowSubject>,
        renamingItemId: Binding<String?>,
        treeState: BinderTreeSectionsState
    ) -> CollectionPiecesPane {
        CollectionPiecesPane(
            store: store,
            subject: subject,
            renamingItemId: renamingItemId,
            treeState: treeState)
    }

    static func collection(
        store: ProjectStore, subject: Binding<WindowSubject>,
        renamingItemId: Binding<String?>,
        treeState: BinderTreeSectionsState,
        windowCanvas: CanvasModel? = nil
    ) -> some View {
        collectionView(store: store, subject: subject,
                       renamingItemId: renamingItemId, treeState: treeState)
            .environment(\.windowCanvas, windowCanvas ?? CanvasModel())
    }

    // MARK: - SceneNavigatorPane (`BinderPaneToggle.sceneNavigator`)

    /// The screenplay's one document, derived as production derives it.
    static func sceneDocumentID(in store: ProjectStore) -> String? {
        TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document })?.id
    }

    static func scenes(
        store: ProjectStore, script: FountainScript?,
        subject: Binding<WindowSubject>,
        treeState: BinderTreeSectionsState,
        onSelect: @escaping (Int) -> Void,
        windowCanvas: CanvasModel? = nil
    ) -> some View {
        SceneNavigatorPane(
            store: store,
            script: script,
            projectTitle: store.manifest.title,
            subject: subject,
            documentID: sceneDocumentID(in: store),
            treeState: treeState,
            onSelect: onSelect)
            .environment(\.windowCanvas, windowCanvas ?? CanvasModel())
    }

    // MARK: - BinderPieceFold (`BinderView.documentEntry`, `CollectionPiecesPane.pieceEntry`)

    static func foldView(
        store: ProjectStore, state: BinderTreeSectionsState,
        subject: Binding<WindowSubject>,
        documentId: String, layout: PieceFoldLayout
    ) -> BinderPieceFold {
        BinderPieceFold(store: store, state: state,
                        subject: subject,
                        documentId: documentId, layout: layout)
    }

    static func fold(
        store: ProjectStore, state: BinderTreeSectionsState,
        subject: Binding<WindowSubject>,
        documentId: String, layout: PieceFoldLayout,
        windowCanvas: CanvasModel? = nil
    ) -> some View {
        foldView(store: store, state: state, subject: subject,
                 documentId: documentId, layout: layout)
            .environment(\.rowThumbnailRoot, store.url)
            .environment(\.windowCanvas, windowCanvas ?? CanvasModel())
    }
}

/// `CentreTopLines` as `ProjectWindow.contentColumn` applies it, over
/// `content` — the lines the window stands over the centre column.
@MainActor
enum CentreTopLinesFixture {

    static func lines(
        over content: some View,
        intentLine: String?, intentMayTrailDraft: Bool = false,
        standingLine: PostureStandingLine.Line?, documentStore: DocumentStore,
        shareIsReadOnly: Bool
    ) -> some View {
        content.modifier(CentreTopLines(
            intentLine: intentLine, intentMayTrailDraft: intentMayTrailDraft,
            standingLine: standingLine, documentStore: documentStore,
            shareIsReadOnly: shareIsReadOnly))
    }
}

/// `ResearchSubjectCentre` as `CentreColumn`'s `.research` arm builds it:
/// `readOnly` is the window's gate asked of THIS item
/// (`ReadThroughGate.refusesEdits(.research(id))`), the share, typography and
/// presence off the window's control plane.
@MainActor
enum ResearchCentreFixture {
    static func centre(
        store: ProjectStore, documentStore: DocumentStore, itemID: String,
        readThrough: ReadThroughGate, editorControl: EditorControl? = nil,
        presence: FigureGridPresence? = nil, window: NSWindow? = nil
    ) -> ResearchSubjectCentre {
        let control = editorControl ?? EditorControl()
        return ResearchSubjectCentre(store: store, documentStore: documentStore,
                                     itemID: itemID, previewVisible: false,
                                     readOnly: readThrough.refusesEdits(.research(itemID)),
                                     shareIsReadOnly: control.shareIsReadOnly,
                                     typography: control.typography,
                                     presence: presence ?? FigureGridPresence(), window: window)
    }
}

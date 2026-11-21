import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

/// **The right column as `ProjectWindow.detailColumn` builds it**, for the
/// suites that mount a pane the way the writer meets it: the real
/// `RightColumn` over real stores, on a position and a subject the test
/// holds. One builder, so a new `RightColumn` parameter is added in one place
/// and every mounted suite follows.
@MainActor
enum RightColumnFixture {

    /// What a test drives and reads: the position and the subject, held
    /// outside the views (as the window's `@State` is).
    @Observable
    @MainActor
    final class Probe {
        var position: RightColumnPosition
        var subject: WindowSubject
        var resolveRequest: ResolveRequest?
        var strains: [ResolveRequest] = []
        var briefsOpened: [BinderSubject] = []
        var centreItemsOpened: [CentreItem] = []
        /// ⌘⌥I's or ⌘⌥N's request, as the window's `briefFocus`.
        var briefFocus: BriefField?
        /// The palette wall's selected card (`selectedPaletteCardId`).
        var paletteWallCard: String?
        /// The window's tree state and pulled-up memory — one each per
        /// window, as `ProjectWindow` holds them in `@State`.
        let figureTree = BinderTreeSectionsState()
        let memory = PulledUpMemory()

        init(position: RightColumnPosition = .resolve, subject: WindowSubject = .book) {
            self.position = position
            self.subject = subject
        }

        /// A binder selection as the window's subject: the row is opened and
        /// faced, `nil` (nothing selected) is the Book. What is pulled up
        /// stays.
        var selection: BinderSubject? {
            get { subject.faces }
            set {
                let target = newValue ?? .project
                var next = subject
                next.open = target
                next.faces = target
                subject = next
            }
        }
    }

    /// The column, on bindings the caller holds. `canvasModel`, the figure
    /// models and the roster default to fresh, unconfigured ones — a probe
    /// that surfaces no compiler gets To resolve with no head, as a window
    /// before its project loads does. The window's tree state, pulled-up
    /// memory and Brief focus are the caller's: production always passes
    /// them, so they have no default here (shell p4 Task 1).
    static func column(
        store: ProjectStore, documentStore: DocumentStore,
        subject: Binding<WindowSubject>, position: Binding<RightColumnPosition>,
        figureTree: BinderTreeSectionsState, memory: PulledUpMemory,
        briefFocus: Binding<BriefField?>,
        paletteWallCard: String? = nil,
        resolveRequest: Binding<ResolveRequest?> = .constant(nil),
        editorControl: EditorControl? = nil,
        roster: AgentRoster? = nil,
        bible: BibleStore? = nil, world: DeclaredWorldStore? = nil,
        canvasModel: CanvasModel? = nil,
        width: Double = UIState.defaultDetailColumnWidth,
        isLocked: Bool = false, centreItem: CentreItem? = nil,
        script: FountainScript? = nil,
        compilerModel: Binding<CompilerModelChoice> = .constant(.standard),
        recordActivePass: @escaping (String, String) -> Void = { _, _ in },
        openProjectSettings: @escaping () -> Void = {},
        showStrain: @escaping (ResolveRequest) -> Void = { _ in },
        openBrief: @escaping (BinderSubject) -> Void = { _ in },
        openInCentre: @escaping (CentreItem) -> Void = { _ in },
        resolveHint: Binding<RightColumn.AskedHint?> = .constant(nil)
    ) -> RightColumn {
        RightColumn(
            store: store, documentStore: documentStore, projectRoot: store.url,
            canvasModel: canvasModel ?? CanvasModel(),
            editorControl: editorControl ?? EditorControl(),
            figureListing: FigureListingModel(),
            figureGridPresence: FigureGridPresence(), figureWindows: nil, window: nil,
            publishCentre: PublishCentreModel(),
            roster: roster ?? AgentRoster(), bible: bible, declaredWorld: world,
            isLocked: isLocked,
            subject: subject,
            isNoChromeOn: false, showInspector: true,
            width: width, containerWidth: nil,
            detailColumnWidth: .constant(width),
            // The right column's view of the subject, as the window's
            // `facesNavigation`: the faces, written through the click rule's
            // navigation.
            selectedSubject: Binding(
                get: { subject.wrappedValue.faces },
                set: { target in
                    subject.wrappedValue = ClickRule.navigate(
                        to: target, current: subject.wrappedValue,
                        structure: store.manifest.structure, projectType: store.manifest.type)
                }),
            position: position,
            resolveRequest: resolveRequest,
            lastParsedScript: script,
            compilerModel: compilerModel,
            recordActivePass: recordActivePass,
            openProjectSettings: openProjectSettings,
            openPromotedArtifact: { _ in },
            showStrain: showStrain,
            openBrief: openBrief,
            // The window's one pull-up act, as `ProjectWindow.pullUpItem`.
            pullUp: { item in
                ProjectWindow.pullUp(item, subject: subject, showInspector: .constant(true),
                                     position: position, memory: memory)
            },
            resolveHint: resolveHint,
            briefFocus: briefFocus,
            drawsFigure: { [figureTree] in
                figureTree.drawsFigure($0, projectType: store.manifest.type)
            },
            revealFigure: { [figureTree] in figureTree.revealFigure($0) },
            figureTree: figureTree,
            centreItem: centreItem,
            openInCentre: openInCentre,
            paletteWallCard: paletteWallCard,
            pulledUpMemory: memory)
    }

    /// The column on a probe.
    static func column(
        store: ProjectStore, documentStore: DocumentStore, probe: Probe,
        editorControl: EditorControl? = nil,
        roster: AgentRoster? = nil,
        bible: BibleStore? = nil, world: DeclaredWorldStore? = nil,
        canvasModel: CanvasModel? = nil,
        width: Double = UIState.defaultDetailColumnWidth,
        isLocked: Bool = false, centreItem: CentreItem? = nil,
        script: FountainScript? = nil,
        compilerModel: Binding<CompilerModelChoice> = .constant(.standard),
        recordActivePass: @escaping (String, String) -> Void = { _, _ in },
        openProjectSettings: @escaping () -> Void = {}
    ) -> RightColumn {
        column(
            store: store, documentStore: documentStore,
            subject: Binding(get: { probe.subject }, set: { probe.subject = $0 }),
            position: Binding(get: { probe.position }, set: { probe.position = $0 }),
            figureTree: probe.figureTree, memory: probe.memory,
            briefFocus: Binding(get: { probe.briefFocus }, set: { probe.briefFocus = $0 }),
            paletteWallCard: probe.paletteWallCard,
            resolveRequest: Binding(get: { probe.resolveRequest },
                                    set: { probe.resolveRequest = $0 }),
            editorControl: editorControl, roster: roster, bible: bible, world: world,
            canvasModel: canvasModel, width: width, isLocked: isLocked, centreItem: centreItem,
            script: script, compilerModel: compilerModel,
            recordActivePass: recordActivePass, openProjectSettings: openProjectSettings,
            showStrain: { probe.strains.append($0) },
            openBrief: { probe.briefsOpened.append($0) },
            openInCentre: { probe.centreItemsOpened.append($0) })
    }

    /// **The pane alone** — the control over the arm — as the width and
    /// height censuses measure it (without the split item's fixed frame).
    ///
    /// A view of its own, so `RightColumn.pane` is evaluated inside a `body`:
    /// evaluated once outside one, its `switch` would be read off the probe at
    /// mount and never again, and a test that moved the position or the
    /// subject would be measuring the arm it started on.
    struct Pane: View {
        let column: () -> RightColumn
        var body: some View { column().pane }
    }

    static func pane(
        store: ProjectStore, documentStore: DocumentStore, probe: Probe,
        editorControl: EditorControl? = nil,
        roster: AgentRoster? = nil,
        bible: BibleStore? = nil, world: DeclaredWorldStore? = nil,
        canvasModel: CanvasModel? = nil,
        width: Double = UIState.defaultDetailColumnWidth,
        centreItem: CentreItem? = nil,
        script: FountainScript? = nil,
        compilerModel: Binding<CompilerModelChoice> = .constant(.standard),
        recordActivePass: @escaping (String, String) -> Void = { _, _ in },
        openProjectSettings: @escaping () -> Void = {}
    ) -> Pane {
        // The models a column holds are made once, here, not per body pass.
        let control = editorControl ?? EditorControl()
        let services = roster ?? AgentRoster()
        let canvas = canvasModel ?? CanvasModel()
        return Pane {
            column(store: store, documentStore: documentStore, probe: probe,
                   editorControl: control, roster: services, bible: bible, world: world,
                   canvasModel: canvas, width: width, centreItem: centreItem,
                   script: script, compilerModel: compilerModel,
                   recordActivePass: recordActivePass,
                   openProjectSettings: openProjectSettings)
        }
    }

    // MARK: - Every arm the column can show

    /// One state of the column for a census to walk.
    struct Arm {
        let name: String
        let position: RightColumnPosition
        let subject: WindowSubject
        /// Translation review on, in this language.
        var translationLanguage: String? = nil
    }

    /// **The name of the arm a content answer is** — an exhaustive `switch`
    /// with no `default`, so a new `RightColumnContent`, `BriefScope`,
    /// `PulledUp` or `CentreDetails` case cannot compile until a census that
    /// walks `arms` has been asked whether it covers it (`armKinds`).
    static func kind(of content: RightColumnContent) -> String {
        switch content {
        case .resolve: return "resolve"
        case .translationReview: return "translationReview"
        case .desk: return "desk"
        case .brief(let scope):
            switch scope {
            case .piece: return "brief.piece"
            case .part: return "brief.part"
            case .book: return "brief.book"
            case .edition: return "brief.edition"
            case .elsewhere: return "brief.elsewhere"
            case .outside: return "brief.outside"
            }
        case .pulledUp(let pulled):
            switch pulled {
            case .research: return "pulledUp.research"
            case .figure: return "pulledUp.figure"
            case .canvasScrap: return "pulledUp.canvasScrap"
            case .canvasPhoto: return "pulledUp.canvasPhoto"
            case .canvasRegion: return "pulledUp.canvasRegion"
            case .lessons: return "pulledUp.lessons"
            case .firstReader: return "pulledUp.firstReader"
            case .visualLanguage: return "pulledUp.visualLanguage"
            case .history: return "pulledUp.history"
            }
        case .centreDetails(let details):
            switch details {
            case .canvas: return "details.canvas"
            case .figure: return "details.figure"
            case .research: return "details.research"
            case .referencePiece: return "details.referencePiece"
            }
        case .nothingPulledUp: return "nothingPulledUp"
        }
    }

    /// Every kind `kind(of:)` can answer. Hand-kept beside the switch above:
    /// the compiler forces the switch, and `test_theCensusWalksEveryArm`
    /// compares what a census walked against this list.
    static let armKinds: Set<String> = [
        "resolve", "translationReview", "desk",
        "brief.piece", "brief.part", "brief.book", "brief.edition", "brief.elsewhere", "brief.outside",
        "pulledUp.research", "pulledUp.figure", "pulledUp.canvasScrap", "pulledUp.canvasPhoto",
        "pulledUp.canvasRegion",
        "pulledUp.lessons", "pulledUp.firstReader", "pulledUp.visualLanguage", "pulledUp.history",
        "details.canvas", "details.figure", "details.research", "details.referencePiece",
        "nothingPulledUp",
    ]

    /// The kinds a NOVEL cannot reach: a piece that lives in another project,
    /// and its details, are a Collection's reference piece
    /// (`ReferencePieceInspector`, measured by its own suite).
    static let armKindsOnlyACollectionHas: Set<String> = ["brief.elsewhere", "details.referencePiece"]

    /// **Every arm a novel's window can show**, over a piece (`docId`), a
    /// Part (`partId`) holding it or another piece, and a research note
    /// (`noteId`). A figure and a canvas card are named by ids nothing holds:
    /// the arm then draws its missing state, which is the state a census of
    /// width and height most needs (it is the one nobody looks at).
    static func arms(docId: String, partId: String, noteId: String) -> [Arm] {
        let piece = WindowSubject(open: .item(docId), faces: .item(docId))
        func pulling(_ pulled: PulledUp) -> WindowSubject {
            var subject = piece
            subject.beside = pulled
            return subject
        }
        return [
            Arm(name: "To resolve", position: .resolve, subject: piece),
            Arm(name: "To resolve, the Book", position: .resolve, subject: .book),
            Arm(name: "translation review", position: .resolve, subject: piece,
                translationLanguage: "es"),
            Arm(name: "the desk", position: .resolve,
                subject: WindowSubject(open: .edition(language: "es"), faces: .edition(language: "es"))),
            Arm(name: "Brief, a piece", position: .brief, subject: piece),
            Arm(name: "Brief, a Part", position: .brief,
                subject: WindowSubject(open: .item(partId), faces: .item(partId))),
            Arm(name: "Brief, the Book", position: .brief, subject: .book),
            Arm(name: "Brief, an edition", position: .brief,
                subject: WindowSubject(open: .edition(language: "es"), faces: .edition(language: "es"))),
            Arm(name: "Brief, outside", position: .brief,
                subject: WindowSubject(open: .canvas, faces: .canvas)),
            Arm(name: "a research note pulled up", position: .pulledUp,
                subject: pulling(.research(noteId))),
            Arm(name: "a figure pulled up", position: .pulledUp, subject: pulling(.figure("fig-gone"))),
            Arm(name: "a canvas card pulled up", position: .pulledUp,
                subject: pulling(.canvasScrap(nodeId: "gone"))),
            Arm(name: "a canvas picture pulled up", position: .pulledUp,
                subject: pulling(.canvasPhoto(path: "canvas_assets/gone.png"))),
            Arm(name: "a canvas region pulled up", position: .pulledUp,
                subject: pulling(.canvasRegion(id: "gone"))),
            Arm(name: "What I've Learned pulled up", position: .pulledUp, subject: pulling(.lessons)),
            Arm(name: "First Reader pulled up", position: .pulledUp, subject: pulling(.firstReader)),
            Arm(name: "Visual Language pulled up", position: .pulledUp,
                subject: pulling(.visualLanguage)),
            Arm(name: "History pulled up", position: .pulledUp, subject: pulling(.history(docId: docId))),
            Arm(name: "the canvas's details", position: .pulledUp,
                subject: WindowSubject(open: .canvas, faces: .canvas)),
            Arm(name: "a figure's details", position: .pulledUp,
                subject: WindowSubject(open: .figure("fig-gone"), faces: .figure("fig-gone"))),
            Arm(name: "a research item's details", position: .pulledUp,
                subject: WindowSubject(open: .research(noteId), faces: .research(noteId))),
            Arm(name: "a figure's details above a note pulled up", position: .pulledUp,
                subject: WindowSubject(open: .figure("fig-gone"), faces: .figure("fig-gone"),
                                       beside: .research(noteId))),
            Arm(name: "nothing pulled up", position: .pulledUp, subject: piece),
        ]
    }

    /// The kinds `arms` reaches in `store`'s project.
    static func kinds(of arms: [Arm], in store: ProjectStore) -> Set<String> {
        Set(arms.map {
            kind(of: RightColumnContent.of(
                position: $0.position, subject: $0.subject,
                translationLanguage: $0.translationLanguage,
                structure: store.manifest.structure, projectType: store.manifest.type))
        })
    }
}

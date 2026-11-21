import XCTest
import MaughamCore
@testable import Maugham

/// **The centre column has ONE exhaustive route, asked of the window's
/// subject** (shell p1 Task 2; foundations plan 4, Task 3 before it).
///
/// What the centre shows is `WindowSubject.open`'s answer, and nothing else's:
/// every kind of subject `open` can be (`SubjectSamples.everyOpen`, kept whole
/// by its own census), every Book view, and every publish state. The faces
/// moving to a piece while the canvas or an edition holds the centre changes
/// nothing here.
///
/// The expected table below is written out by hand on purpose. Built from the
/// same statics `centreRoute` composes, it could only ever agree with them.
@MainActor
final class CentreRouteTests: XCTestCase {

    // MARK: - Fixtures

    static let structure = SubjectSamples.structure

    static let book = PublishPreviewCentreTests.aBook
    static let proposal = PublishCentreModelTests.proposal()
    static let round = PublishCentreModelTests.round()

    /// Every publish state the window can hold: the three resolutions, and the
    /// desk's two Shows (alone and — though the model clears one with the
    /// other — together, so the ORDER is pinned and not the invariant).
    enum PublishState: CaseIterable, CustomStringConvertible {
        case nothingCompiled, unreadable, compiled, proposal, round, proposalAndRound
        @MainActor var preview: PublishPreviewResolution {
            switch self {
            case .nothingCompiled: return .nothingCompiled
            case .unreadable: return PublishPreviewCentreTests.unreadable
            default: return .ready(newestFirst: [CentreRouteTests.book])
            }
        }
        @MainActor var proposal: DesignProposalStore.Proposal? {
            self == .proposal || self == .proposalAndRound ? CentreRouteTests.proposal : nil
        }
        @MainActor var round: TranslationRound? {
            self == .round || self == .proposalAndRound ? CentreRouteTests.round : nil
        }
        var description: String { "\(self)" as String }
    }

    @MainActor
    static func route(_ subject: WindowSubject, _ bookView: BookView = .outline,
                      _ publish: PublishState = .compiled,
                      projectType: ProjectType = .novel,
                      structure: [StructureItem]? = nil) -> CentreRoute {
        ProjectWindow.centreRoute(
            subject: subject, bookView: bookView, projectType: projectType,
            structure: structure ?? CentreRouteTests.structure,
            preview: publish.preview, proposal: publish.proposal, round: publish.round)
    }

    // MARK: - The table

    /// **Where each kind of `open` sends the centre**, written per kind:
    ///
    /// - the palette is the wall; a research item and a figure take the centre;
    ///   the Inbox is the captures; the canvas is the canvas;
    /// - a piece is the bare editor;
    /// - the Book and a Part are the editor with the Book's view over it, as
    ///   chosen — Status included, which is a view and never a cover;
    /// - an edition is the editor with its book's cover over the Book's Cards or
    ///   Outline (never Status): a round, then a proposal, then the book, then
    ///   a notice saying which nothing it is.
    static func expected(_ open: BinderSubject, _ bookView: BookView,
                         _ publish: PublishState) -> CentreRoute {
        switch SubjectSamples.kind(of: open) {
        case "palette": return .paletteWall
        case "research": return .research(id: SubjectSamples.researchID)
        case "figure": return .figure(id: SubjectSamples.figureID)
        case "inbox": return .inbox
        case "canvas": return .canvas
        case "piece": return .editor(altitude: nil, cover: nil)
        case "project", "part": return .editor(altitude: bookView, cover: nil)
        case "edition":
            let altitude: BookView = bookView == .status ? .cards : bookView
            if publish.round != nil {
                return .editor(altitude: altitude, cover: .translationRound(round))
            }
            if let proposal = publish.proposal {
                return .editor(altitude: altitude, cover: .designGate(proposal))
            }
            switch publish {
            case .nothingCompiled:
                return .editor(altitude: altitude, cover: .notice(.neverCompiled))
            case .unreadable:
                return .editor(altitude: altitude, cover: .notice(.unreadableCatalog(
                    reason: PublishPreviewCentreTests.unreadableReason)))
            default:
                return .editor(altitude: altitude, cover: .books([book]))
            }
        default:
            XCTFail("no row for \(open)")
            return .canvas
        }
    }

    func test_everyCombinationRoutesWhereTheTableSays() {
        for open in SubjectSamples.everyOpen {
            for bookView in BookView.allCases {
                for publish in PublishState.allCases {
                    XCTAssertEqual(
                        Self.route(SubjectSamples.opened(open), bookView, publish),
                        Self.expected(open, bookView, publish),
                        "\(open), \(bookView), \(publish)")
                }
            }
        }
    }

    /// **The samples' census**: every kind of subject has a sample, so no
    /// routing loop over `SubjectSamples.everyOpen` quietly skips one.
    func test_theSamplesCoverEveryKindOfSubject() {
        XCTAssertEqual(Set(SubjectSamples.everyOpen.map(SubjectSamples.kind(of:))),
                       SubjectSamples.everyKind)
    }

    // MARK: - The five shell-p1 behaviours

    func test_theInboxSubjectRoutesToTheInbox() {
        for publish in PublishState.allCases {
            XCTAssertEqual(Self.route(SubjectSamples.opened(.inbox), .status, publish), .inbox)
        }
        // With the faces on a piece too — the Inbox is what is open.
        XCTAssertEqual(Self.route(WindowSubject(open: .inbox,
                                                faces: .item(SubjectSamples.pieceID))),
                       .inbox)
    }

    /// **A Part is a small Book over its own chapters**: the same pane, in the
    /// chosen view, over the Part's pieces and under the Part's title.
    func test_aPartShowsTheAltitudeOverItsOwnChapters() {
        let part = SubjectSamples.opened(.item(SubjectSamples.partID))
        for view in BookView.allCases {
            XCTAssertEqual(Self.route(part, view), .editor(altitude: view, cover: nil))
        }
        let scope = ProjectWindow.altitudeScope(
            open: part.open, structure: Self.structure, bookTitle: "The Book")
        XCTAssertEqual(scope.title, "Part One")
        XCTAssertEqual(scope.structure.map(\.id), [SubjectSamples.pieceID],
                       "only the Part's own chapters")
        let book = ProjectWindow.altitudeScope(
            open: .project, structure: Self.structure, bookTitle: "The Book")
        XCTAssertEqual(book.title, "The Book")
        XCTAssertEqual(book.structure, Self.structure, "the Book lays out every piece")
    }

    /// **Status is a view and never a cover**, wherever the board shows.
    func test_statusIsAViewAndNeverACover() {
        for open in [BinderSubject.project, .item(SubjectSamples.partID)] {
            for publish in PublishState.allCases {
                XCTAssertEqual(Self.route(SubjectSamples.opened(open), .status, publish),
                               .editor(altitude: .status, cover: nil),
                               "\(open), \(publish)")
            }
            XCTAssertTrue(ProjectWindow.reviewCentreShowsBoard(
                subject: SubjectSamples.opened(open), bookView: .status,
                structure: Self.structure))
        }
        // And nowhere else: not a piece, not an edition, not under any other view.
        for open in SubjectSamples.everyOpen {
            for view in BookView.allCases {
                let shows = ProjectWindow.reviewCentreShowsBoard(
                    subject: SubjectSamples.opened(open), bookView: view,
                    structure: Self.structure)
                let kind = SubjectSamples.kind(of: open)
                XCTAssertEqual(shows, view == .status && (kind == "project" || kind == "part"),
                               "\(open), \(view)")
            }
        }
    }

    /// **An edition shows its book whatever the faces are on** — a click on a
    /// piece moves the faces and never `open`.
    func test_anEditionShowsItsBookWhateverTheFacesAreOn() {
        let edition = BinderSubject.edition(language: "es")
        let clicked = ClickRule.resolve(.item(SubjectSamples.pieceID), gesture: .click,
                                        current: SubjectSamples.opened(edition),
                                        structure: Self.structure, projectType: .novel)
        XCTAssertEqual(clicked.open, edition, "premise: the click moved only the faces")
        for faces in SubjectSamples.everyOpen {
            let subject = WindowSubject(open: edition, faces: faces)
            XCTAssertEqual(Self.route(subject, .outline, .compiled),
                           .editor(altitude: .outline, cover: .books([Self.book])),
                           "faces on \(faces)")
        }
        // Every language shows the same book: the preview carries none yet.
        XCTAssertEqual(Self.route(SubjectSamples.opened(.edition(language: "sr"))),
                       Self.route(SubjectSamples.opened(edition)))
    }

    func test_theCanvasStaysTheCentreWhenTheFacesMoveToAPiece() {
        let clicked = ClickRule.resolve(.item(SubjectSamples.pieceID), gesture: .click,
                                        current: SubjectSamples.opened(.canvas),
                                        structure: Self.structure, projectType: .novel)
        XCTAssertEqual(clicked, WindowSubject(open: .canvas,
                                              faces: .item(SubjectSamples.pieceID)))
        for type in ProjectType.allCases {
            for publish in PublishState.allCases {
                XCTAssertEqual(Self.route(clicked, .outline, publish, projectType: type),
                               .canvas, "\(type), \(publish)")
            }
        }
        // Reference material beside leaves it too.
        var beside = clicked
        beside.beside = .research(SubjectSamples.researchID)
        XCTAssertEqual(Self.route(beside), .canvas)
    }

    // MARK: - What used to be decided by z-order, now a fact

    /// **The board and an edition's surface are never both offered**, over
    /// every subject, view and publish state.
    func test_theBoardAndThePublishSurfaceAreNeverBothOffered() {
        for subject in SubjectSamples.everySubject {
            for view in BookView.allCases {
                for publish in PublishState.allCases {
                    let board = ProjectWindow.reviewCentreShowsBoard(
                        subject: subject, bookView: view, structure: Self.structure)
                    let book = ProjectWindow.publishCentre(
                        subject: subject, preview: publish.preview,
                        proposal: publish.proposal, round: publish.round)
                    XCTAssertFalse(board && book != nil,
                                   "\(subject.open), \(view), \(publish)")
                }
            }
        }
    }

    /// **Every cover stands on the Book's view**: every cover is an edition's,
    /// and an edition always has the Book beneath it — so the notice explains a
    /// Book that is really there, and a cover coming or going never decides
    /// whether that layer is mounted.
    func test_everyCoverStandsOnTheBooksView() {
        for subject in SubjectSamples.everySubject {
            for view in BookView.allCases {
                for publish in PublishState.allCases {
                    guard case .editor(let altitude, let cover?) =
                            Self.route(subject, view, publish) else { continue }
                    XCTAssertNotNil(altitude, "\(subject.open), \(publish): \(cover) "
                                    + "with no Book under it")
                }
            }
        }
    }

    /// **The altitude layer is the rule's answer whatever covers it** — the
    /// fact the layer's identity rests on.
    func test_theAltitudeLayerIsTheRulesAnswerWhateverCoversIt() {
        for subject in SubjectSamples.everySubject {
            for view in BookView.allCases {
                for publish in PublishState.allCases {
                    guard case .editor(let altitude, _) = Self.route(subject, view, publish)
                    else { continue }
                    XCTAssertEqual(altitude, ProjectWindow.altitudeView(
                        subject: subject, bookView: view, editionView: .book,
                        structure: Self.structure),
                        "\(subject.open), \(view), \(publish)")
                }
            }
        }
    }

    /// **Where two surfaces were both offered, the route names the one on top**
    /// — with the premise that the one beneath really was offered.
    func test_theSurfaceThatWasOnTopIsTheOneTheRouteNames() {
        let edition = SubjectSamples.opened(.edition(language: "es"))
        XCTAssertEqual(Self.route(edition, .cards, .compiled),
                       .editor(altitude: .cards, cover: .books([Self.book])),
                       "the book over the Book's view")
        XCTAssertEqual(Self.route(edition, .cards, .proposal),
                       .editor(altitude: .cards, cover: .designGate(Self.proposal)),
                       "the gate outranks the book")
        XCTAssertEqual(Self.route(edition, .cards, .proposalAndRound),
                       .editor(altitude: .cards, cover: .translationRound(Self.round)),
                       "the round outranks the gate")
        let problems = [TectonicLogParser.Diagnostic(
            level: .error, file: nil, line: nil, message: "Undefined control sequence",
            contextLines: [], pieceID: nil, paragraphID: nil)]
        XCTAssertEqual(ProjectWindow.centreRoute(
            subject: edition, bookView: .cards, projectType: .novel,
            structure: Self.structure, preview: .nothingCompiled,
            proposal: Self.proposal, round: Self.round, problems: problems),
                       .editor(altitude: .cards, cover: .publishProblems(problems)),
                       "the problems outrank the round")
        // An edition's surfaces are an edition's: the same desk state over the
        // Book shows the Book.
        XCTAssertEqual(Self.route(SubjectSamples.opened(.project), .cards, .proposalAndRound),
                       .editor(altitude: .cards, cover: nil))
        // Research in `open` is above the editor arm; beside, it moves nothing.
        var withBeside = SubjectSamples.opened(.item(SubjectSamples.pieceID))
        withBeside.beside = .research(SubjectSamples.researchID)
        XCTAssertEqual(Self.route(withBeside), .editor(altitude: nil, cover: nil),
                       "research beside leaves the piece in the centre")
    }

    /// **A centre item is the last cover** (shell plan 3 Task 5): the
    /// publish problems, a round, the design gate, the book and a notice
    /// each outrank it, and it stands only where no publish cover does —
    /// never over the canvas, the wall, research, a figure, the Inbox or a
    /// reference piece, which are branches of their own. In use the two never
    /// meet (a publish cover needs an edition open, and any change of `open`
    /// clears the item), so the order only decides that an item can never hide
    /// a problem the writer asked to see.
    func test_aCentreItemIsTheLastCover() {
        let item = CentreItem.statement(kind: .intent, scope: .project)
        let problems = [TectonicLogParser.Diagnostic(
            level: .error, file: nil, line: nil, message: "Undefined control sequence",
            contextLines: [], pieceID: nil, paragraphID: nil)]
        for subject in SubjectSamples.everySubject {
            for publish in PublishState.allCases {
                for shown in [nil, problems] {
                    func route(_ centreItem: CentreItem?) -> CentreRoute {
                        ProjectWindow.centreRoute(
                            subject: subject, bookView: .outline, projectType: .novel,
                            structure: Self.structure, preview: publish.preview,
                            proposal: publish.proposal, round: publish.round, problems: shown,
                            centreItem: centreItem)
                    }
                    let without = route(nil)
                    if case .editor(let altitude, nil) = without {
                        XCTAssertEqual(route(item), .editor(altitude: altitude, cover: .centreItem(item)),
                                       "\(subject.open), \(publish): the item covers the bare editor")
                    } else {
                        XCTAssertEqual(route(item), without,
                                       "\(subject.open), \(publish), problems \(shown != nil): "
                                       + "what stood without the item stands with it")
                    }
                }
            }
        }
    }

    // MARK: - The Collection reference arm

    /// **A reference piece keeps its own arm, resolved or not**, and the arm
    /// sits ABOVE the editor — an unresolved one has no path, so the altitude
    /// rule alone would have claimed it (`ProjectAltitudeCentreTests`).
    func test_aCollectionReferencePieceTakesItsOwnArmAboveTheEditor() {
        let resolved = StructureItem(id: "piece-ref", title: "Linked", type: .document,
                                     path: "pieces/ref/.maugham-link.json",
                                     pieceKind: .reference)
        let unresolved = StructureItem(id: "piece-lost", title: "Elsewhere",
                                       type: .document, path: nil, pieceKind: .reference)
        for piece in [resolved, unresolved] {
            XCTAssertEqual(
                Self.route(SubjectSamples.opened(.item(piece.id)), projectType: .collection,
                           structure: [piece]),
                .reference(piece: piece), piece.title)
            XCTAssertEqual(
                Self.route(WindowSubject(open: .canvas, faces: .item(piece.id)),
                           projectType: .collection, structure: [piece]),
                .canvas, "the canvas outranks the reference arm the faces are on")
            XCTAssertEqual(
                Self.route(SubjectSamples.opened(.item(piece.id)), .cards,
                           projectType: .novel, structure: [piece]),
                .editor(altitude: piece.path == nil ? .cards : nil, cover: nil),
                "only a COLLECTION's reference piece takes the arm")
        }
    }

    // MARK: - The shape, in production

    /// **`centreRoute` composes the window's decisions and restates none.**
    func test_theRouteComposesTheExistingDecisions() throws {
        XCTAssertEqual(CentreRouteSource.compositionFaults(in: try CentreRouteSource.rule()), [])
    }

    /// **`editorPane` is one switch over the route, and `manuscriptEditor`'s
    /// stack is the host FIRST, the Book's view SECOND, and one switch over the
    /// cover** — every cover in its own arm and none layered beside the switch.
    func test_theCentreIsRenderedByOneSwitchPerLevel() throws {
        XCTAssertEqual(CentreRouteSource.paneFaults(in: try CentreRouteSource.pane()), [])
        XCTAssertEqual(CentreRouteSource.stackFaults(in: try CentreRouteSource.editorArm()), [])
    }

    /// **The planted controls**: each census above fires on the shape it bans.
    func test_theShapeCensusesFireOnPlantedOffenders() {
        // A route that re-derives the document question instead of asking it.
        let restating = """
        static func centreRoute() -> CentreRoute {
            showsPaletteWallCentre(); researchSubjectPlacement(); figureSubjectPlacement()
            editorRoute(); publishCentre()
            return .editor(altitude: selectionIsDocument(subject, in: structure) ? nil : bookView, cover: nil)
        }
        """
        XCTAssertEqual(CentreRouteSource.compositionFaults(in: restating),
                       ["does not ask altitudeView(",
                        "restates selectionIsDocument("])
        // A route that still asks the persona.
        let persona = """
        static func centreRoute() -> CentreRoute {
            showsPaletteWallCentre(); researchSubjectPlacement(); figureSubjectPlacement()
            editorRoute(); publishCentre(); altitudeView()
            if persona.centresTheCanvas { return .canvas }
        }
        """
        XCTAssertEqual(CentreRouteSource.compositionFaults(in: persona),
                       ["restates centresTheCanvas", "restates persona"])

        // A switch whose subject runs over several lines, as production's does,
        // is still read arm by arm.
        let multiLine = """
        private func editorPane() -> some View {
            switch ProjectWindow.centreRoute(subject: subject,
                                             bookView: bookView) {
            case .canvas: canvasCentre(store: store)
            case .editor(let altitude, let cover): manuscriptEditor(altitude: altitude, cover: cover)
            case .inbox: InboxPane()
            }
        }
        """
        XCTAssertEqual(CentreRouteSource.paneFaults(in: multiLine), [])
        XCTAssertEqual(CentreRouteSource.switchArms(
            in: multiLine, over: "switch ProjectWindow.centreRoute(")?.arms.keys.sorted(),
                       ["canvas", "editor", "inbox"])

        // The old chain: gates asked inside the pane.
        let chain = """
        private func editorPane() -> some View {
            if Self.showsPaletteWallCentre(subject: s) { PaletteWallCentre() }
            else { manuscriptEditor() }
        }
        """
        XCTAssertEqual(CentreRouteSource.paneFaults(in: chain),
                       ["does not ask ProjectWindow.centreRoute(",
                        "has no switch over the route",
                        "asks Self.showsPaletteWallCentre( itself"])

        // The same chain from `CentreColumn`, spelled through the window's type.
        let chainFromTheColumn = """
        private func editorPane() -> some View {
            switch ProjectWindow.centreRoute(subject: s) {
            case .canvas: canvasCentre(store: store)
            case .editor(let altitude, let cover):
                if ProjectWindow.reviewCentreShowsBoard(subject: s) { ReviewBoardPane() }
                manuscriptEditor(altitude: altitude, cover: cover)
            case .inbox: InboxPane()
            }
        }
        """
        XCTAssertEqual(CentreRouteSource.paneFaults(in: chainFromTheColumn),
                       ["asks ProjectWindow.reviewCentreShowsBoard( itself"])

        // The compliant stack, as production spells it: no fault.
        let compliant = """
        private func manuscriptEditor() -> some View {
            ZStack {
                EditorHost()
                if let altitude {
                    ProjectAltitudePane(view: altitude) { statusBoard() }
                    .background(Color.white)
                }
                switch cover {
                case .notice(let notice): EditionNoticeCover()
                case .books(let publications): PublishPreviewCentre()
                case .designGate(let proposal): DesignGateView()
                case .translationRound(let round): TranslationRoundReportHost()
                case .publishProblems(let problems): PublishProblemsView()
                case .centreItem(let item): CentreItemCover()
                case .none: EmptyView()
                }
            }
        }
        """
        XCTAssertEqual(CentreRouteSource.stackFaults(in: compliant), [])

        // The old stack: the board as a cover, a cover layered beside the
        // switch, and the notice moved into another arm.
        let layered = """
        private func manuscriptEditor() -> some View {
            ZStack {
                EditorHost()
                if let altitude {
                    ProjectAltitudePane(view: altitude) { statusBoard() }
                    .background(Color.white)
                }
                if Self.reviewCentreShowsBoard(subject: s) { EmptyView() }
                switch cover {
                case .notice(let notice): EmptyView()
                case .reviewBoard: ReviewBoardPane()
                case .books(let publications):
                    PublishPreviewCentre()
                    EditionNoticeCover()
                case .designGate(let proposal): DesignGateView()
                case .translationRound(let round): TranslationRoundReportHost()
                case .publishProblems(let problems): PublishProblemsView()
                case .centreItem(let item): CentreItemCover()
                case .none: EmptyView()
                }
            }
        }
        """
        XCTAssertEqual(CentreRouteSource.stackFaults(in: layered),
                       ["asks Self.reviewCentreShowsBoard( itself",
                        "the board is a cover: ReviewBoardPane( is mounted in the stack",
                        "EditionNoticeCover( is not mounted in the `.notice` arm",
                        "EditionNoticeCover( is mounted outside the `.notice` arm"])

        // Altitude moved into the cover switch: its identity would follow the
        // cover, which is the remount this layer exists to avoid.
        let altitudeInside = """
        private func manuscriptEditor() -> some View {
            ZStack {
                EditorHost()
                switch cover {
                case .notice(let notice):
                    ProjectAltitudePane().background(Color.white)
                    EditionNoticeCover()
                case .books(let publications): PublishPreviewCentre()
                case .designGate(let proposal): DesignGateView()
                case .translationRound(let round): TranslationRoundReportHost()
                case .publishProblems(let problems): PublishProblemsView()
                case .centreItem(let item): CentreItemCover()
                case .none: ProjectAltitudePane()
                }
            }
        }
        """
        XCTAssertEqual(CentreRouteSource.stackFaults(in: altitudeInside),
                       ["the altitude layer is not gated on `if let altitude` between "
                        + "EditorHost( and the cover switch",
                        "ProjectAltitudePane( is mounted outside the altitude layer"])

        // The host inside the switch: its identity would follow the cover.
        let hostInside = """
        private func manuscriptEditor() -> some View {
            ZStack {
                switch cover {
                case .none: EditorHost()
                }
            }
        }
        """
        XCTAssertTrue(CentreRouteSource.stackFaults(in: hostInside)
            .contains("EditorHost( is not mounted before the cover switch"))
    }

    /// **The window hands the centre column the window's own verbs** — read
    /// off the one `CentreColumn(` call, because the column's closures are
    /// only as good as what the window passes for them.
    func test_theWindowHandsTheCentreColumnItsOwnVerbs() throws {
        XCTAssertTrue(
            try CentreRouteSource.windowArgument("recordActivePass")?
                .contains("recordActivePass(forPiece:") == true,
            "the one `ActivePassMemory` writer")
        XCTAssertTrue(
            try CentreRouteSource.windowArgument("runRoundWhenPieceOpens")?
                .contains("runRoundWhenPieceOpens(pieceId:") == true,
            "the one bounded round deferral")
        XCTAssertTrue(
            try CentreRouteSource.windowArgument("posture")?
                .contains("postureDrawn(forDocId:") == true,
            "the drawing door's posture")
    }

    /// The planted control for `windowArgument`: it finds an argument of the
    /// window's `CentreColumn(` call, in a file the window's extension lives
    /// in, and finds nothing that is not inside that call.
    func test_theWindowArgumentReadIsBoundedToTheMount() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/ProjectWindow.swift": """
            struct ProjectWindow: View {
                var body: some View { Text("x") }
            }
            """,
            "Maugham/Views/ProjectWindow+Columns.swift": """
            extension ProjectWindow {
                func contentColumn() -> some View {
                    CentreColumn(
                        store: store,
                        recordActivePass: { recordActivePass(forPiece: $0, passId: $1) })
                        .frame(maxWidth: .infinity)
                }
                func elsewhere() { posture: { postureDrawn(forDocId: $0) } }
            }
            """,
        ])
        XCTAssertEqual(
            try CentreRouteSource.windowArgument("recordActivePass", base: base)?
                .trimmingCharacters(in: .whitespaces),
            "recordActivePass: { recordActivePass(forPiece: $0, passId: $1) })")
        XCTAssertNil(try CentreRouteSource.windowArgument("posture", base: base),
                     "an argument-shaped line after the call closes is not the mount's")
        XCTAssertNil(try CentreRouteSource.windowArgument("frame", base: base))
    }
}

// MARK: - Reading the centre's source

/// The source reads behind the centre column's censuses — shared by this suite,
/// `ProjectAltitudeCentreTests`, `ReviewBoardRoutingTests`,
/// `PublishPreviewCentreTests` and `DesignGateTests`, which used to read
/// `manuscriptEditor`'s LAYER ORDER and now read which arm of its one switch
/// mounts each surface. Every read is bounded to its declaration, found by
/// symbol (`SourceTree.declaration`), and works over code lines only.
enum CentreRouteSource {

    static func rule(base: URL = SourceTree.repoRoot) throws -> String {
        try SourceTree.declaration(named: "static func centreRoute(", under: "Maugham", base: base)
    }

    static func pane(base: URL = SourceTree.repoRoot) throws -> String {
        try SourceTree.declaration(named: "func editorPane(", under: "Maugham", base: base)
    }

    static func editorArm(base: URL = SourceTree.repoRoot) throws -> String {
        try SourceTree.declaration(named: "func manuscriptEditor(", under: "Maugham", base: base)
    }

    /// **What the window hands `CentreColumn` for one argument** (foundations
    /// plan 4 Task 4): the code line of `label:` inside the window's one
    /// `CentreColumn(` call, or nil when the window has no such argument. The
    /// hop a wiring census needs now that the centre's closures call a verb
    /// the WINDOW owns — `recordActivePass`, the round deferral — through a
    /// closure the column was handed.
    static func windowArgument(_ label: String, of mountCall: String = "CentreColumn(",
                               base: URL = SourceTree.repoRoot) throws -> String? {
        let code = SourceScan.codeLines(
            of: try SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"], base: base))
        guard let mount = code.firstIndex(where: { $0.contains(mountCall) }) else { return nil }
        var depth = 0
        for line in code[mount...] {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("\(label):") { return line }
            depth += line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
            if depth <= 0 { return nil }
        }
        return nil
    }

    /// Each cover case, and the surface its arm must mount.
    static let covers: [(cover: String, view: String)] = [
        // The notice arm mounts the edition's bar over the banner (shell p4
        // Task 5); the banner itself is mounted inside it.
        ("notice", "EditionNoticeCover("),
        ("books", "PublishPreviewCentre("),
        ("designGate", "DesignGateView("),
        ("translationRound", "TranslationRoundReportHost("),
        ("publishProblems", "PublishProblemsView("),
        ("centreItem", "CentreItemCover("),
    ]

    /// The routing rules a builder must not ask for itself — each in both
    /// spellings, since the builders live in `CentreColumn` (foundations plan
    /// 4 Task 4), where the rules are `ProjectWindow.`'s rather than `Self.`'s.
    static let gates: [String] = [
        "showsPaletteWallCentre(", "researchSubjectPlacement(", "figureSubjectPlacement(",
        "editorRoute(", "publishCentre(", "reviewCentreShowsBoard(", "subjectShowsAltitude(",
        "altitudeView(",
    ].flatMap { ["Self.\($0)", "ProjectWindow.\($0)"] }

    /// How the pane asks the route: from `CentreColumn`, the window's static.
    static let routeAsk = "ProjectWindow.centreRoute("

    /// One `switch` in `code`, split into its arms: each `case .name` with the
    /// code lines until the next case, plus every code line OUTSIDE the switch.
    struct Switch {
        let line: Int
        let arms: [String: [String]]
        let outside: [String]
        func arm(_ name: String) -> String { (arms[name] ?? []).joined(separator: "\n") }
    }

    static func switchArms(in text: String, over token: String) -> Switch? {
        let code = SourceScan.codeLines(of: text)
        guard let start = code.firstIndex(where: { $0.contains(token) }) else { return nil }
        // The subject may run over several lines (`switch f(a,\n b) {`), so
        // the body starts at the first `{` and ends where it closes.
        var depth = 0, opened = false, end = code.count - 1
        var arms: [String: [String]] = [:]
        var current: String?
        for index in start..<code.count {
            let line = code[index]
            if opened, depth == 1 {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("case .") {
                    current = String(trimmed.dropFirst("case .".count)
                        .prefix(while: { $0.isLetter || $0.isNumber }))
                } else if trimmed.hasPrefix("default") {
                    current = "default"
                }
            }
            if opened, let current { arms[current, default: []].append(line) }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if depth > 0 { opened = true }
            if opened, depth <= 0 { end = index; break }
        }
        let outside = Array(code[..<start]) + Array(code[(end + 1)...])
        return Switch(line: start, arms: arms, outside: outside)
    }

    /// What is wrong with `centreRoute`'s body: a named rule it does not ask,
    /// or a primitive beneath one it restates.
    static func compositionFaults(in rule: String) -> [String] {
        let code = SourceScan.codeLines(of: rule).joined(separator: "\n")
        var faults: [String] = []
        for asked in ["showsPaletteWallCentre(", "researchSubjectPlacement(",
                      "figureSubjectPlacement(", "editorRoute(", "publishCentre(",
                      "altitudeView("]
        where !code.contains(asked) {
            faults.append("does not ask \(asked)")
        }
        for primitive in ["selectionIsDocument(", "centresTheCanvas", "previewsThePublishedBook",
                          "showsTheReviewBoard", "showsManuscriptDocuments", "persona",
                          "TreeWalk."]
        where code.contains(primitive) {
            faults.append("restates \(primitive)")
        }
        return faults
    }

    /// What is wrong with `editorPane`: it must ask the route and switch over
    /// it, with the canvas mounted in the `.canvas` arm and the editor in the
    /// `.editor` arm, and ask no routing rule of its own.
    static func paneFaults(in pane: String) -> [String] {
        var faults: [String] = []
        let code = SourceScan.codeLines(of: pane).joined(separator: "\n")
        if !code.contains(routeAsk) { faults.append("does not ask \(routeAsk)") }
        if let route = switchArms(in: pane, over: "switch \(routeAsk)") {
            if !route.arm("canvas").contains("canvasCentre(") {
                faults.append("the canvas is not mounted in the `.canvas` arm")
            }
            if !route.arm("editor").contains("manuscriptEditor(") {
                faults.append("the editor is not mounted in the `.editor` arm")
            }
        } else {
            faults.append("has no switch over the route")
        }
        for gate in gates where code.contains(gate) { faults.append("asks \(gate) itself") }
        return faults
    }

    /// What is wrong with `manuscriptEditor`: `EditorHost` first and outside
    /// the one switch over the cover; then the altitude layer, gated on
    /// `if let altitude`, opaque, and mounted nowhere else; then each cover in
    /// its own arm and nowhere else; the board nowhere in the stack (it is the
    /// Book's Status view, placed by `ProjectAltitudePane`); and no routing rule
    /// asked here.
    static func stackFaults(in arm: String) -> [String] {
        var faults: [String] = []
        let code = SourceScan.codeLines(of: arm)
        let joined = code.joined(separator: "\n")
        for gate in gates where joined.contains(gate) { faults.append("asks \(gate) itself") }
        guard joined.contains("ZStack") else { return faults + ["has no ZStack"] }
        guard let cover = switchArms(in: arm, over: "switch cover") else {
            return faults + ["has no switch over the cover"]
        }
        func count(_ token: String, in lines: [String]) -> Int {
            lines.reduce(0) { $0 + $1.components(separatedBy: token).count - 1 }
        }
        let host = code.firstIndex(where: { $0.contains("EditorHost(") })
        if host == nil || host! > cover.line
            || cover.arms.values.joined().contains(where: { $0.contains("EditorHost(") }) {
            faults.append("EditorHost( is not mounted before the cover switch")
        }
        if joined.contains("ReviewBoardPane(") {
            faults.append("the board is a cover: ReviewBoardPane( is mounted in the stack")
        }
        // The altitude layer: from `if let altitude {` (after the host) up to the
        // switch, holding the one altitude mount and its opaque background.
        let start = (host ?? 0)
        let gate = code.indices.first { $0 > start && $0 < cover.line
            && code[$0].contains("if let altitude {") }
        let layer = gate.map { Array(code[$0..<cover.line]) } ?? []
        if count("ProjectAltitudePane(", in: layer) != 1 {
            faults.append("the altitude layer is not gated on `if let altitude` between "
                          + "EditorHost( and the cover switch")
        } else if !layer.contains(where: { $0.contains(".background(") }) {
            faults.append("the altitude layer is not opaque")
        }
        if count("ProjectAltitudePane(", in: code) > count("ProjectAltitudePane(", in: layer) {
            faults.append("ProjectAltitudePane( is mounted outside the altitude layer")
        }
        for (name, view) in covers {
            let inArm = count(view, in: cover.arms[name] ?? [])
            if inArm == 0 { faults.append("\(view) is not mounted in the `.\(name)` arm") }
            if count(view, in: code) > inArm {
                faults.append("\(view) is mounted outside the `.\(name)` arm")
            }
        }
        return faults
    }
}

// MARK: - The edition's centre (shell p4 Task 5)

@MainActor
final class EditionCentreTests: XCTestCase {

    private static let day = Date(timeIntervalSince1970: 1_800_000_000)

    private static func book(_ version: String, _ language: String?, newer by: Double) -> Publication {
        PublishPreviewCentreTests.publication(
            version: version, outputPath: "exports/\(version).pdf",
            compiledAt: day.addingTimeInterval(by), language: language)
    }

    /// Newest first, as the resolver hands them: a Spanish book, a bilingual
    /// one, the plain source book, a Serbian one.
    static let spanish = book("1.3", "es", newer: 4)
    static let bilingual = book("1.2", "en+sr", newer: 3)
    static let source = book("1.1", nil, newer: 2)
    static let serbian = book("1.0", "SR", newer: 1)
    static let catalog = PublishPreviewResolution.ready(newestFirst: [spanish, bilingual, source, serbian])

    private func shown(_ language: String) -> [Publication] {
        PublishPreviewResolver.edition(Self.catalog, language: language, sourceLanguage: "en")
            .publications
    }

    func test_eachEditionShowsOnlyItsOwnBooks() {
        XCTAssertEqual(shown("es"), [Self.spanish])
        // A bilingual book is in each of its languages' editions; a tag is
        // matched without case.
        XCTAssertEqual(shown("sr"), [Self.bilingual, Self.serbian])
        // An edition with no book of its own has never been compiled — the
        // notice is true per edition.
        XCTAssertEqual(PublishPreviewResolver.edition(Self.catalog, language: "fr", sourceLanguage: "en"),
                       .nothingCompiled)
        // The unreadable catalog stays unreadable, whatever the edition.
        XCTAssertEqual(PublishPreviewResolver.edition(PublishPreviewCentreTests.unreadable,
                                                      language: "es", sourceLanguage: "en"),
                       PublishPreviewCentreTests.unreadable)
    }

    func test_theSourceEditionShowsTheUntranslatedBooks() {
        XCTAssertEqual(shown("en"), [Self.bilingual, Self.source])
        XCTAssertEqual(shown("EN"), [Self.bilingual, Self.source], "the Source matched without case")
    }

    /// The tag a book's body carries — the `<tag>` of its anchors.
    func test_theBodyTagIsTheCompilesOwnSpelling() {
        XCTAssertEqual(PublishPreviewResolver.bodyTag(of: Self.serbian, edition: "sr", sourceLanguage: "en"), "SR")
        XCTAssertEqual(PublishPreviewResolver.bodyTag(of: Self.bilingual, edition: "en", sourceLanguage: "en"), "en")
        XCTAssertEqual(PublishPreviewResolver.bodyTag(of: Self.source, edition: "en", sourceLanguage: "en"), "en")
        XCTAssertNil(PublishPreviewResolver.bodyTag(of: Self.source, edition: "es", sourceLanguage: "en"))
    }

    /// **The window's centre asks for the edition's own books** — the model
    /// filters, so the route the window draws is per edition.
    func test_theCentreDrawsTheOpenEditionsBooks() {
        let model = PublishCentreModel()
        model.publishSelection(after: Self.catalog)
        model.sourceLanguage = "en"
        func cover(_ language: String) -> CentreCover? {
            let subject = SubjectSamples.opened(.edition(language: language))
            guard case .editor(_, let cover) = ProjectWindow.centreRoute(
                subject: subject, bookView: .cards, editionView: .book, projectType: .novel,
                structure: CentreRouteTests.structure, preview: model.preview(for: subject.open))
            else { return nil }
            return cover
        }
        XCTAssertEqual(cover("es"), .books([Self.spanish]))
        XCTAssertEqual(cover("en"), .books([Self.bilingual, Self.source]))
        XCTAssertEqual(cover("fr"), .notice(.neverCompiled))
        XCTAssertTrue(model.isSourceEdition(.edition(language: "EN")))
        XCTAssertFalse(model.isSourceEdition(.edition(language: "es")))
        XCTAssertEqual(model.preview(for: .project), Self.catalog, "nothing but an edition is filtered")
    }

    /// **Status is a view, never covered by the Book or its notice** — the
    /// problems, the round and the gate still cover it, in their order.
    func test_statusIsNeverCoveredByTheBookOrItsNotice() {
        let subject = SubjectSamples.opened(.edition(language: "es"))
        for state in CentreRouteTests.PublishState.allCases {
            let route = ProjectWindow.centreRoute(
                subject: subject, bookView: .cards, editionView: .status, projectType: .novel,
                structure: CentreRouteTests.structure, preview: state.preview,
                proposal: state.proposal, round: state.round)
            guard case .editor(let altitude, let cover) = route else {
                return XCTFail("an edition's Status is the editor's altitude layer: \(route)")
            }
            XCTAssertEqual(altitude, .status, "\(state)")
            switch cover {
            case .books, .notice:
                XCTFail("\(state): the book or its notice covered the edition's Status")
            case .some(.translationRound):
                XCTAssertTrue(state == .round || state == .proposalAndRound, "\(state)")
            case .some(.designGate):
                XCTAssertEqual(state, .proposal)
            case .none:
                XCTAssertTrue([.nothingCompiled, .unreadable, .compiled].contains(state), "\(state)")
            default:
                XCTFail("\(state): \(String(describing: cover))")
            }
        }
        // The problems list still covers it.
        let problems = [TectonicLogParser.Diagnostic(level: .error, file: nil, line: nil, message: "x", contextLines: [])]
        if case .editor(_, let cover) = ProjectWindow.centreRoute(
            subject: subject, bookView: .cards, editionView: .status, projectType: .novel,
            structure: CentreRouteTests.structure, preview: .nothingCompiled, problems: problems) {
            XCTAssertEqual(cover, .publishProblems(problems))
        }
        // …and the edition's Book view is still covered by its book.
        if case .editor(let altitude, let cover) = ProjectWindow.centreRoute(
            subject: subject, bookView: .outline, editionView: .book, projectType: .novel,
            structure: CentreRouteTests.structure, preview: .ready(newestFirst: [Self.spanish])) {
            XCTAssertEqual(altitude, .outline)
            XCTAssertEqual(cover, .books([Self.spanish]))
        }
        // An edition's Status is never the passes board.
        XCTAssertFalse(ProjectWindow.reviewCentreShowsBoard(
            subject: subject, bookView: .status, structure: CentreRouteTests.structure))
    }

    /// **The compile runs on the window** — the desk owns none of its own, so
    /// the compile survives the column and the desk going.
    func test_theCompileRunnerLivesOnTheWindow() throws {
        let desk = try SourceTree.read("Maugham/Views/Publish/DepartmentPaneHost.swift")
        XCTAssertFalse(desk.contains("DeskCompileRunner()"), "the desk constructs no runner")
        let model = try SourceTree.read("Maugham/Views/Publish/PublishCentreModel.swift")
        XCTAssertTrue(model.contains("let compileRunner = DeskCompileRunner()"))
        // The one constructor in the app's sources.
        let constructions = try SourceTree.sources(under: "Maugham")
            .filter { $0.text.contains("DeskCompileRunner()") }.map(\.path)
        XCTAssertEqual(constructions.map { ($0 as NSString).lastPathComponent }, ["PublishCentreModel.swift"])
    }

    /// **A compile that settles over the manuscript's problems covers the
    /// centre with them**; one that landed with warnings does not.
    func test_aRefusalOverProblemsCoversTheCentre() {
        let problem = TectonicLogParser.Diagnostic(level: .error, file: nil, line: nil, message: "broken",
                                                  contextLines: [], pieceID: "c1")
        let running = DepartmentCompileState(phase: .running(format: .pdf, languages: [], imprint: nil),
                                             isRunning: true)
        let refused = DepartmentCompileState(phase: .refused("no"), isRunning: false,
                                             problems: [problem], judgedTheManuscript: true)
        let model = PublishCentreModel()
        model.compileSettled(from: running, to: refused)
        XCTAssertEqual(model.selectedProblems, [problem])

        let landed = DepartmentCompileState(phase: .completed(EditionCentreTests.spanish),
                                            isRunning: false, problems: [problem])
        let other = PublishCentreModel()
        other.compileSettled(from: running, to: landed)
        XCTAssertNil(other.selectedProblems, "a book with warnings offers Show Problems; it does not cover")
    }

    /// **Compile… from an edition** asks with that edition checked.
    func test_compileFromAnEditionChecksThatEdition() {
        let spanish = EditionCompileAsk.make(editions: ["en", "es", "sr"], edition: "es")
        XCTAssertEqual(spanish.languages, ["es", "sr"])
        XCTAssertEqual(spanish.bookLanguage, "en")
        XCTAssertFalse(spanish.includesBook)
        XCTAssertEqual(spanish.selected, ["es"])
        let source = EditionCompileAsk.make(editions: ["en", "es"], edition: nil)
        XCTAssertTrue(source.includesBook)
        XCTAssertEqual(source.selected, [])
    }

    /// **Nothing in the edition's Status is wider than the centre's floor.**
    func test_theEditionsStatusFitsTheCentresFloor() {
        XCTAssertLessThanOrEqual(EditionStatusView.intrinsicWidth(isSource: false),
                                 ProjectWindow.centreColumnFloor)
        XCTAssertLessThanOrEqual(EditionStatusView.intrinsicWidth(isSource: true),
                                 ProjectWindow.centreColumnFloor)
    }

    /// **Every ask goes to its page** (fix round 1, I2): a new ask for the
    /// same page goes there again — the same chapter after scrolling away,
    /// or chapter → Part → the same chapter — and an unrelated update
    /// re-applies nothing.
    func test_everyAskGoesToItsPage() {
        let url = URL(fileURLWithPath: "/tmp/book.pdf")
        let first = PDFPreview.Target(page: 3, ask: 1)
        XCTAssertFalse(PDFPreview.shouldGo(to: nil, in: url, applied: nil))
        XCTAssertTrue(PDFPreview.shouldGo(to: first, in: url, applied: nil))
        XCTAssertFalse(PDFPreview.shouldGo(to: first, in: url, applied: (url, first)),
                       "a redraw with the same ask goes nowhere")
        XCTAssertTrue(PDFPreview.shouldGo(to: .init(page: 3, ask: 2), in: url, applied: (url, first)),
                      "the same page asked again goes there again")
        XCTAssertTrue(PDFPreview.shouldGo(to: first, in: URL(fileURLWithPath: "/tmp/other.pdf"),
                                          applied: (url, first)))
        // Each resolve is a new ask: the place carries its serial.
        XCTAssertNotEqual(PiecePlace(.page(3), title: "One", ask: 1).target,
                          PiecePlace(.page(3), title: "One", ask: 2).target)
        XCTAssertNil(PiecePlace(.notInBook, title: "One", ask: 1).target)
    }

    /// **The compiling pill stands aside only for this window's compile**
    /// (fix round 1, I3): an MCP or another window's compile keeps it.
    func test_thePillStandsAsideOnlyForThisWindowsCompile() {
        let edition = SubjectSamples.opened(.edition(language: "es"))
        XCTAssertTrue(ProjectWindow.editionBookShowsCompile(
            subject: edition, editionView: .book, runnerIsRunning: true))
        XCTAssertFalse(ProjectWindow.editionBookShowsCompile(
            subject: edition, editionView: .book, runnerIsRunning: false),
            "a compile the bar does not know of keeps its pill")
        XCTAssertFalse(ProjectWindow.editionBookShowsCompile(
            subject: edition, editionView: .status, runnerIsRunning: true))
        XCTAssertFalse(ProjectWindow.editionBookShowsCompile(
            subject: SubjectSamples.opened(.project), editionView: .book, runnerIsRunning: true))
    }

    /// **A one-body book is read by the tag its anchors carry** (minor 1): an
    /// imprint's own language, or the ordinal an unsafe tag became.
    func test_aOneBodyBookIsReadByTheTagItsAnchorsCarry() {
        let edition = EditionBook(language: "en", sourceLanguage: "en")
        XCTAssertEqual(PiecePlace.bodyTag(of: Self.source, edition: edition,
                                          pages: ["p-en-GB-aaaa": 0]), "en-GB")
        XCTAssertEqual(PiecePlace.bodyTag(of: Self.source, edition: edition,
                                          pages: ["p-en-aaaa": 0]), "en")
        XCTAssertEqual(PiecePlace.bodyTag(of: Self.bilingual, edition: edition,
                                          pages: ["p-1-aaaa": 0, "p-2-aaaa": 3]), "en",
                       "a bilingual book's tags are its own; no guessing")
        XCTAssertNil(PiecePlace.bodyTag(of: Self.serbian, edition: edition, pages: ["p-SR-aaaa": 0]))
    }

    /// The faces on a document is the piece the book goes to; anything else
    /// leaves the page.
    func test_onlyADocumentOnTheFacesMovesTheBook() {
        let doc = StructureItem(id: "c1", title: "One", type: .document, path: "one.md")
        let part = StructureItem(id: "p1", title: "Part", type: .group, children: [doc])
        XCTAssertEqual(CentreColumn.pieceInBook(faces: .item("c1"), structure: [part]),
                       PieceInBook(id: "c1", title: "One"))
        XCTAssertNil(CentreColumn.pieceInBook(faces: .item("p1"), structure: [part]))
        XCTAssertNil(CentreColumn.pieceInBook(faces: .project, structure: [part]))
        XCTAssertEqual(PiecePlace.notInBookLine("One"), "One is not in this book")
    }
}

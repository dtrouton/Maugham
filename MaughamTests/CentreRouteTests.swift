import XCTest
import MaughamCore
@testable import Maugham

/// **The centre column has ONE exhaustive route** (foundations plan 4, Task 3).
///
/// Before `CentreRoute`, what the centre showed was decided twice — an if/else
/// chain in `editorPane` and independent `if` layers in `manuscriptEditor`'s
/// `ZStack`, where the surface the writer saw was whichever layer came LAST.
/// This suite pins the route those two mechanisms produced, over every persona,
/// every subject shape, the palette wall open and shut, and every publish
/// state — derived from the old code's order and from the implication tests
/// that already held it in place (`ReviewBoardRoutingTests`,
/// `PublishPreviewCentreTests`, `ProjectAltitudeCentreTests`, `DesignGateTests`).
///
/// The expected table below is written out by hand on purpose. Built from the
/// same statics `centreRoute` composes, it could only ever agree with them.
@MainActor
final class CentreRouteTests: XCTestCase {

    // MARK: - Fixtures

    /// One document, one group (from `ProjectAltitudeCentreTests`), and the
    /// subject shapes this suite walks.
    static let structure = ProjectAltitudeCentreTests.structure

    enum Shape: CaseIterable, CustomStringConvertible {
        case none, project, group, document, research
        var subject: BinderSubject? {
            switch self {
            case .none: return nil
            case .project: return .project
            case .group: return .item("part-one")
            case .document: return .item("chapter-1")
            case .research: return .research("res-1")
            }
        }
        var description: String {
            switch self {
            case .none: return "no subject"
            case .project: return "the project"
            case .group: return "a group"
            case .document: return "a document"
            case .research: return "a research item"
            }
        }
    }

    static let book = PublishPreviewCentreTests.aBook
    static let proposal = PublishCentreModelTests.proposal()
    static let round = PublishCentreModelTests.round()

    /// Every publish state the window can hold: the three resolutions, and the
    /// desk's two Shows (alone and — though the model clears one with the
    /// other — together, so the ORDER is pinned and not the invariant).
    enum PublishState: CaseIterable, CustomStringConvertible {
        case nothingCompiled, unreadable, compiled, proposal, round, proposalAndRound
        var preview: PublishPreviewResolution {
            switch self {
            case .nothingCompiled: return .nothingCompiled
            case .unreadable: return PublishPreviewCentreTests.unreadable
            default: return .ready(newestFirst: [CentreRouteTests.book])
            }
        }
        var proposal: DesignProposalStore.Proposal? {
            self == .proposal || self == .proposalAndRound ? CentreRouteTests.proposal : nil
        }
        var round: TranslationRound? {
            self == .round || self == .proposalAndRound ? CentreRouteTests.round : nil
        }
        var description: String { "\(self)" as String }
    }

    static func route(_ persona: Persona, _ shape: Shape, wall: Bool,
                      _ publish: PublishState,
                      projectType: ProjectType = .novel,
                      structure: [StructureItem] = CentreRouteTests.structure) -> CentreRoute {
        ProjectWindow.centreRoute(
            persona: persona, subject: shape.subject, projectType: projectType,
            structure: structure, showsPaletteWall: wall,
            preview: publish.preview, proposal: publish.proposal, round: publish.round)
    }

    // MARK: - The table

    /// **What the old chain and the old stack's TOP layer produced, for every
    /// combination.** Written per persona from the old code:
    ///
    /// - The wall first, everywhere but Plan.
    /// - Plan: the canvas, whatever the subject (a research subject previews
    ///   BESIDE it).
    /// - Author: a research item takes the centre; a document is the bare
    ///   editor; anything else is altitude.
    /// - Review: as Author, with the board where altitude would be (the board
    ///   was the layer over altitude).
    /// - Publish: a research subject falls through (`.nothingMoves`); a round
    ///   draws over anything, the chapter included; at project level the gate,
    ///   then the book, then a notice saying which nothing it is; over a
    ///   chapter, nothing.
    /// - Altitude stays a layer beneath every cover wherever the subject names
    ///   no document, exactly as the old stack mounted it.
    static func expected(_ persona: Persona, _ shape: Shape, wall: Bool,
                         _ publish: PublishState) -> CentreRoute {
        if wall && persona != .plan { return .paletteWall }
        // Altitude is the layer that was mounted for every manuscript persona
        // whenever the subject named no document — a research subject in
        // Publish included, since Publish hands it to neither column.
        let altitude = shape != .document
        switch persona {
        case .plan:
            return .canvas
        case .author:
            if shape == .research { return .research(id: "res-1") }
            return .editor(altitude: altitude, cover: nil)
        case .review:
            if shape == .research { return .research(id: "res-1") }
            return .editor(altitude: altitude, cover: altitude ? .reviewBoard : nil)
        case .publish:
            if publish.round != nil {
                return .editor(altitude: altitude, cover: .translationRound(round))
            }
            if shape == .document { return .editor(altitude: false, cover: nil) }
            if let proposal = publish.proposal {
                return .editor(altitude: true, cover: .designGate(proposal))
            }
            switch publish {
            case .nothingCompiled:
                return .editor(altitude: true, cover: .notice(.neverCompiled))
            case .unreadable:
                return .editor(altitude: true, cover: .notice(.unreadableCatalog(
                    reason: PublishPreviewCentreTests.unreadableReason)))
            default:
                return .editor(altitude: true, cover: .books([book]))
            }
        }
    }

    func test_everyCombinationRoutesWhereTheOldChainAndStackSentIt() {
        XCTAssertEqual(Persona.allCases.count, 4,
                       "a fifth persona must be given a row in `expected` — the "
                       + "table is written out by hand, so it cannot grow one itself")
        for persona in Persona.allCases {
            for shape in Shape.allCases {
                for wall in [false, true] {
                    for publish in PublishState.allCases {
                        XCTAssertEqual(
                            Self.route(persona, shape, wall: wall, publish),
                            Self.expected(persona, shape, wall: wall, publish),
                            "\(persona), \(shape), wall \(wall ? "open" : "shut"), \(publish)")
                    }
                }
            }
        }
    }

    // MARK: - What the old stack decided by z-order, now a fact

    /// **Two covers are never both offered.** The old stack's comment said
    /// so ("the two are never both offered") and nothing checked it: the board
    /// and Publish's surface were layered one over the other, and only the
    /// persona predicates kept them apart. Over the whole product: the board's
    /// rule and the publish rule never both answer.
    func test_theBoardAndThePublishSurfaceAreNeverBothOffered() {
        for persona in Persona.allCases {
            for shape in Shape.allCases {
                for publish in PublishState.allCases {
                    let board = ProjectWindow.reviewCentreShowsBoard(
                        persona: persona, subject: shape.subject, structure: Self.structure)
                    let book = ProjectWindow.publishCentre(
                        persona: persona, subject: shape.subject, structure: Self.structure,
                        preview: publish.preview, proposal: publish.proposal,
                        round: publish.round)
                    XCTAssertFalse(board && book != nil,
                                   "\(persona), \(shape), \(publish): both the board "
                                   + "and \(String(describing: book)) would have shown")
                }
            }
        }
    }

    /// **Every project-level cover stands on altitude.** The notice, the
    /// board, the book and the gate only ever appear where the altitude layer
    /// is mounted beneath them — so the notice explains a corkboard that is
    /// really there, and a cover coming or going never decides whether altitude
    /// is mounted. The round alone may cover a chapter.
    func test_everyProjectLevelCoverStandsOnAltitude() {
        for persona in Persona.allCases {
            for shape in Shape.allCases {
                for wall in [false, true] {
                    for publish in PublishState.allCases {
                        guard case .editor(let altitude, let cover?) =
                                Self.route(persona, shape, wall: wall, publish)
                        else { continue }
                        if case .translationRound = cover { continue }
                        XCTAssertTrue(altitude,
                                      "\(persona), \(shape), \(publish): \(cover) with "
                                      + "no corkboard under it")
                    }
                }
            }
        }
    }

    /// **The altitude layer is the rule's answer whatever covers it** — the
    /// fact the layer's identity rests on.
    func test_theAltitudeLayerIsTheRulesAnswerWhateverCoversIt() {
        for persona in Persona.allCases {
            for shape in Shape.allCases {
                for publish in PublishState.allCases {
                    guard case .editor(let altitude, _) =
                            Self.route(persona, shape, wall: false, publish)
                    else { continue }
                    XCTAssertEqual(altitude, ProjectWindow.subjectShowsAltitude(
                        persona: persona, subject: shape.subject, structure: Self.structure),
                        "\(persona), \(shape), \(publish)")
                }
            }
        }
    }

    /// **Where the old stack drew one surface over another, the route names
    /// the one on top** — with the premise that the one beneath really was
    /// offered, so these are about precedence rather than about absence.
    func test_theSurfaceThatWasOnTopIsTheOneTheRouteNames() {
        let altitude = { (persona: Persona) in
            ProjectWindow.subjectShowsAltitude(persona: persona, subject: .project,
                                               structure: Self.structure)
        }
        XCTAssertTrue(altitude(.review), "premise: Review's project row answers altitude too")
        XCTAssertEqual(Self.route(.review, .project, wall: false, .nothingCompiled),
                       .editor(altitude: true, cover: .reviewBoard),
                       "the board was the layer OVER the corkboard")
        XCTAssertTrue(altitude(.publish), "premise: so does Publish's")
        XCTAssertEqual(Self.route(.publish, .project, wall: false, .compiled),
                       .editor(altitude: true, cover: .books([Self.book])),
                       "the book was the LAST layer")
        XCTAssertEqual(Self.route(.publish, .project, wall: false, .proposal),
                       .editor(altitude: true, cover: .designGate(Self.proposal)),
                       "the gate outranks the book")
        XCTAssertEqual(Self.route(.publish, .project, wall: false, .proposalAndRound),
                       .editor(altitude: true, cover: .translationRound(Self.round)),
                       "the round outranks the gate")
        XCTAssertNotNil(ProjectWindow.researchSubjectPlacement(
            persona: .review, subject: .research("res-1")).centreItemID,
                        "premise: Review hands a research subject the centre")
        XCTAssertEqual(Self.route(.review, .research, wall: false, .nothingCompiled),
                       .research(id: "res-1"),
                       "…above the editor arm, so the board never covers the note "
                       + "(though `reviewCentreShowsBoard` alone answers TRUE)")
        XCTAssertEqual(Self.route(.author, .research, wall: true, .nothingCompiled),
                       .paletteWall, "the wall is above even a research subject")
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
            for persona in Persona.allCases where !persona.centresTheCanvas {
                XCTAssertEqual(
                    ProjectWindow.centreRoute(
                        persona: persona, subject: .item(piece.id), projectType: .collection,
                        structure: [piece], showsPaletteWall: false,
                        preview: .ready(newestFirst: [Self.book])),
                    .reference(piece: piece), "\(persona), \(piece.title)")
            }
            XCTAssertEqual(
                ProjectWindow.centreRoute(
                    persona: .plan, subject: .item(piece.id), projectType: .collection,
                    structure: [piece], showsPaletteWall: false, preview: .nothingCompiled),
                .canvas, "Plan's canvas outranks the reference arm")
            XCTAssertEqual(
                ProjectWindow.centreRoute(
                    persona: .author, subject: .item(piece.id), projectType: .novel,
                    structure: [piece], showsPaletteWall: false, preview: .nothingCompiled),
                .editor(altitude: piece.path == nil, cover: nil),
                "only a COLLECTION's reference piece takes the arm")
        }
    }

    // MARK: - The shape, in production

    /// **`centreRoute` composes the window's decisions and restates none.**
    /// Each named rule is asked, and none of the primitives underneath them is
    /// spelled — a second spelling is a second answer free to disagree.
    func test_theRouteComposesTheExistingDecisions() throws {
        XCTAssertEqual(CentreRouteSource.compositionFaults(in: try CentreRouteSource.rule()), [])
    }

    /// **`editorPane` is one switch over the route, and `manuscriptEditor`'s
    /// stack is the host FIRST, altitude SECOND, and one switch over the
    /// cover** — every cover in its own arm and none layered beside the
    /// switch, so which one shows is the route's answer and never a z-order.
    /// Neither builder asks a routing rule of its own.
    func test_theCentreIsRenderedByOneSwitchPerLevel() throws {
        XCTAssertEqual(CentreRouteSource.paneFaults(in: try CentreRouteSource.pane()), [])
        XCTAssertEqual(CentreRouteSource.stackFaults(in: try CentreRouteSource.editorArm()), [])
    }

    /// **The planted controls**: each census above fires on the shape it bans.
    func test_theShapeCensusesFireOnPlantedOffenders() {
        // A route that re-derives the document question instead of asking it.
        let restating = """
        static func centreRoute() -> CentreRoute {
            showsPaletteWallCentre(); researchSubjectPlacement(); editorRoute()
            publishCentre(); reviewCentreShowsBoard()
            return .editor(altitude: !selectionIsDocument(subject, in: structure), cover: nil)
        }
        """
        XCTAssertEqual(CentreRouteSource.compositionFaults(in: restating),
                       ["does not ask subjectShowsAltitude(",
                        "restates selectionIsDocument("])

        // A switch whose subject runs over several lines, as production's does,
        // is still read arm by arm.
        let multiLine = """
        private func editorPane() -> some View {
            switch Self.centreRoute(persona: persona,
                                    subject: subject) {
            case .canvas: canvasCentre(store: store)
            case .editor(let altitude, let cover): manuscriptEditor(altitude: altitude, cover: cover)
            }
        }
        """
        XCTAssertEqual(CentreRouteSource.paneFaults(in: multiLine), [])
        XCTAssertEqual(CentreRouteSource.switchArms(
            in: multiLine, over: "switch Self.centreRoute(")?.arms.keys.sorted(),
                       ["canvas", "editor"])

        // The old chain: gates asked inside the pane.
        let chain = """
        private func editorPane() -> some View {
            if Self.showsPaletteWallCentre(showsPaletteWall: w, persona: p) { PaletteWallCentre() }
            else { manuscriptEditor() }
        }
        """
        XCTAssertEqual(CentreRouteSource.paneFaults(in: chain),
                       ["does not ask Self.centreRoute(",
                        "has no switch over the route",
                        "asks Self.showsPaletteWallCentre( itself"])

        // The compliant stack, as production spells it: no fault.
        let compliant = """
        private func manuscriptEditor() -> some View {
            ZStack {
                EditorHost()
                if altitude {
                    ProjectAltitudePane()
                    .background(Color.white)
                }
                switch cover {
                case .notice(let notice): PublishCentreNoticeBanner()
                case .reviewBoard: ReviewBoardPane()
                case .books(let publications): PublishPreviewCentre()
                case .designGate(let proposal): DesignGateView()
                case .translationRound(let round): TranslationRoundReportHost()
                case .none: EmptyView()
                }
            }
        }
        """
        XCTAssertEqual(CentreRouteSource.stackFaults(in: compliant), [])

        // The old stack: a cover layered beside the switch, decided by z-order,
        // and the notice moved into another arm.
        let layered = """
        private func manuscriptEditor() -> some View {
            ZStack {
                EditorHost()
                if altitude {
                    ProjectAltitudePane()
                    .background(Color.white)
                }
                if Self.reviewCentreShowsBoard(persona: p) { ReviewBoardPane() }
                switch cover {
                case .notice(let notice): EmptyView()
                case .reviewBoard: EmptyView()
                case .books(let publications):
                    PublishPreviewCentre()
                    PublishCentreNoticeBanner()
                case .designGate(let proposal): DesignGateView()
                case .translationRound(let round): TranslationRoundReportHost()
                case .none: EmptyView()
                }
            }
        }
        """
        XCTAssertEqual(CentreRouteSource.stackFaults(in: layered),
                       ["asks Self.reviewCentreShowsBoard( itself",
                        "PublishCentreNoticeBanner( is not mounted in the `.notice` arm",
                        "PublishCentreNoticeBanner( is mounted outside the `.notice` arm",
                        "ReviewBoardPane( is not mounted in the `.reviewBoard` arm",
                        "ReviewBoardPane( is mounted outside the `.reviewBoard` arm"])

        // Altitude moved into the cover switch: its identity would follow the
        // cover, which is the remount this layer exists to avoid — and a
        // second altitude mount beside it is caught too.
        let altitudeInside = """
        private func manuscriptEditor() -> some View {
            ZStack {
                EditorHost()
                switch cover {
                case .notice(let notice):
                    ProjectAltitudePane().background(Color.white)
                    PublishCentreNoticeBanner()
                case .reviewBoard: ReviewBoardPane()
                case .books(let publications): PublishPreviewCentre()
                case .designGate(let proposal): DesignGateView()
                case .translationRound(let round): TranslationRoundReportHost()
                case .none: ProjectAltitudePane()
                }
            }
        }
        """
        XCTAssertEqual(CentreRouteSource.stackFaults(in: altitudeInside),
                       ["the altitude layer is not gated on `if altitude` between "
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

    /// Each cover case, and the surface its arm must mount.
    static let covers: [(cover: String, view: String)] = [
        ("notice", "PublishCentreNoticeBanner("),
        ("reviewBoard", "ReviewBoardPane("),
        ("books", "PublishPreviewCentre("),
        ("designGate", "DesignGateView("),
        ("translationRound", "TranslationRoundReportHost("),
    ]

    /// The routing rules a builder must not ask for itself.
    static let gates = [
        "Self.showsPaletteWallCentre(", "Self.researchSubjectPlacement(",
        "Self.editorRoute(", "Self.publishCentre(", "Self.reviewCentreShowsBoard(",
        "Self.subjectShowsAltitude(",
    ]

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
        for asked in ["showsPaletteWallCentre(", "researchSubjectPlacement(", "editorRoute(",
                      "publishCentre(", "reviewCentreShowsBoard(", "subjectShowsAltitude("]
        where !code.contains(asked) {
            faults.append("does not ask \(asked)")
        }
        for primitive in ["selectionIsDocument(", "centresTheCanvas", "previewsThePublishedBook",
                          "showsTheReviewBoard", "showsManuscriptDocuments", "persona ==",
                          "persona !=", "TreeWalk."]
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
        if !code.contains("Self.centreRoute(") { faults.append("does not ask Self.centreRoute(") }
        if let route = switchArms(in: pane, over: "switch Self.centreRoute(") {
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
    /// `if altitude`, opaque, and mounted nowhere else; then each cover in its
    /// own arm and nowhere else; and no routing rule asked here.
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
        // The altitude layer: from `if altitude {` (after the host) up to the
        // switch, holding the one altitude mount and its opaque background.
        let start = (host ?? 0)
        let gate = code.indices.first { $0 > start && $0 < cover.line
            && code[$0].contains("if altitude {") }
        let layer = gate.map { Array(code[$0..<cover.line]) } ?? []
        if count("ProjectAltitudePane(", in: layer) != 1 {
            faults.append("the altitude layer is not gated on `if altitude` between "
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

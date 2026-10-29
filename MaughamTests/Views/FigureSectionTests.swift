import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **The tree's Figures section and the piece count** (report plan 8a Task 4,
/// D8-1): shown only where the manuscript holds figures and one is not parked;
/// rows in the listing's reading order with their numbers and tags, read from
/// the state's cached array; a piece row's count, its filter and the chip that
/// clears it; the row menu's verbs on the real store.
@MainActor
final class FigureSectionTests: XCTestCase {

    private final class InputsBox {
        var value: FigureCardInputs
        init(_ value: FigureCardInputs) { self.value = value }
    }

    // MARK: - Planted rows

    private static func row(_ id: String, _ name: String, kind: FigureKind = .table,
                            caption: String = "", number: String,
                            in pieces: [String] = []) -> FigureListing.Row {
        FigureListing.Row(
            figureId: id, kind: kind, name: name, caption: caption, number: number,
            usedIn: pieces.enumerated().map { FigureListing.Use(docId: $1, lineIndex: $0) },
            referencedFrom: [], pieceOfLine: pieces.first)
    }

    private let cash = row("fig-0a1b2c3d", "cash", caption: "Cash at year end",
                           number: "Table 1", in: ["doc-a", "doc-b"])
    private let map = row("fig-1a1b2c3d", "map", kind: .image, number: "Figure 1", in: ["doc-a"])
    private let tax = row("fig-2a1b2c3d", "tax", number: "Table 2", in: ["doc-a"])
    private let spare = row("fig-3a1b2c3d", "spare", number: FigureListing.unusedNumber)

    private var listing: [FigureListing.Row] { [cash, map, tax, spare] }

    private func state(_ rows: [FigureListing.Row]) -> BinderTreeSectionsState {
        let state = BinderTreeSectionsState()
        state.refreshFigureRows(listing: rows)
        return state
    }

    // MARK: - Whether the section shows (D8-1)

    func test_theSectionIsAbsentWithNoFigures() {
        XCTAssertFalse(state([]).showsFigures(projectType: .novel))
        XCTAssertTrue(state([cash]).showsFigures(projectType: .novel), "control: one figure shows it")
    }

    func test_theSectionIsAbsentInAScreenplay() {
        let state = state(listing)
        XCTAssertFalse(state.showsFigures(projectType: .screenplay),
                       "a screenplay's manuscript holds no figures (holdsFigures)")
        XCTAssertFalse(state.showsFigures(projectType: .unknown))
        for type in [ProjectType.novel, .shortStory, .collection] {
            XCTAssertTrue(state.showsFigures(projectType: type), "\(type)")
        }
        XCTAssertNil(state.figureCountText(forPiece: "doc-a", projectType: .screenplay),
                     "no section, no count")
    }

    /// Parked is the card's answer (`FigureCardModel.Kind.parked`), filled by
    /// the tree's own cache; a parked figure draws no row, and a book whose
    /// every figure is parked shows no section.
    func test_theSectionIsAbsentWhenEveryFigureIsParked() async {
        let state = state([cash, map])
        var parkedState = FigureState(kind: .table, table: FigureTable(rows: 1, columns: 1))
        parkedState.parked = FigureParking(path: "research/cash.csv", hash: "h")
        let records = [FigureRecord(id: cash.figureId, name: "cash", kind: .table, piece: nil,
                                    path: "figures/cash.csv"),
                       FigureRecord(id: map.figureId, name: "map", kind: .image, piece: nil,
                                    path: "figures/map.png")]
        let inputs = InputsBox(FigureCardInputs(
            records: records, states: [cash.figureId: parkedState],
            workbook: nil, pinChanged: [], locale: TableLocale(languageTag: "en-GB")))
        state.figureCards.onVersionChange = { [weak state] _ in state?.figureCardsChanged() }
        state.figureCards.attach(FigureCardCache.Source(read: { inputs.value }))
        await state.figureCards.idle()
        XCTAssertEqual(state.figureRows.map(\.id), [map.figureId],
                       "the parked table drew a row; the picture with no card yet stays")
        XCTAssertTrue(state.showsFigures(projectType: .novel))

        var mapParked = FigureState(kind: .image)
        mapParked.parked = FigureParking(path: "research/map.png", hash: "h")
        inputs.value.states[map.figureId] = mapParked
        state.figureCards.invalidate()
        await state.figureCards.idle()
        XCTAssertEqual(state.figureRows, [])
        XCTAssertFalse(state.showsFigures(projectType: .novel),
                       "every figure parked: the section is gone")
    }

    // MARK: - Rows, numbers and tags

    /// The rows keep the listing's order (reading order, then unused) with its
    /// numbers, and the tags come from each figure's card.
    func test_rowsKeepTheListingsOrderWithNumbersAndTags() {
        let cards: [String: FigureCardModel] = [
            cash.figureId: FigureCardModel(kind: .table, readsResearch: true, pinChanged: true),
            tax.figureId: FigureCardModel(kind: .table, readsResearch: true),
            spare.figureId: FigureCardModel(kind: .table),
        ]
        let rows = FigureTreeRow.build(listing: listing, card: { cards[$0] })
        XCTAssertEqual(rows.map(\.id), listing.map(\.figureId))
        XCTAssertEqual(rows.map(\.listing.number), ["Table 1", "Figure 1", "Table 2", "—"])
        XCTAssertEqual(rows.map(\.title), ["Cash at year end", "map", "tax", "spare"],
                       "the caption, else the name")
        XCTAssertEqual(rows.map(FigureRow.tags(of:)),
                       [["Research", "changed"], [], ["Research"], ["unused"]])
    }

    /// **The section draws the state's cached array and nothing else**
    /// (tripwire 4): the section's `ForEach` reads `drawnFigureRows`, and no
    /// row or section body reaches the cards' fill or the disk.
    func test_theRowSourceIsTheCachedArray() throws {
        let state = state(listing)
        XCTAssertEqual(state.figureRows.map(\.listing), listing)
        XCTAssertEqual(state.drawnFigureRows, state.figureRows)

        let section = try Self.source(of: "Views/FigureSection.swift")
        let builder = try XCTUnwrap(Self.declaration(named: "var figuresSection: some View {", in: section))
        XCTAssertTrue(builder.contains("ForEach(state.drawnFigureRows)"))
        let row = try Self.source(of: "Views/FigureRow.swift")
        for body in [builder, row] {
            for read in ["figureCardInputs", "model(forFigureId", "FileManager", "contentsOf"] {
                XCTAssertFalse(SourceScan.codeLines(of: body).joined().contains(read),
                               "a Figures row or the section reads `\(read)` in a body (tripwire 4)")
            }
        }
    }

    // MARK: - The piece count, its filter and the chip

    func test_thePieceCountReadsTheFiguresItsTextUses() {
        let state = state(listing)
        XCTAssertEqual(state.figureCountText(forPiece: "doc-a", projectType: .novel),
                       "2 tables, 1 figure")
        XCTAssertEqual(state.figureCountText(forPiece: "doc-b", projectType: .novel), "1 table")
        XCTAssertNil(state.figureCountText(forPiece: "doc-c", projectType: .novel),
                     "nothing is shown at 0")
        XCTAssertEqual(FigureCount(tables: 3).text, "3 tables")
        XCTAssertEqual(FigureCount(figures: 1).text, "1 figure")
        XCTAssertEqual(FigureCount(figures: 2).text, "2 figures")
        XCTAssertNil(FigureCount().text)
    }

    /// The count's press (the row's `onShowFigures`, which both hosts wire to
    /// `showFigures(inPiece:)`) filters the section to the piece, opens it
    /// and scrolls to its header; the chip clears it. Selection follows the
    /// drawn rows.
    func test_theCountFiltersTheSectionAndTheChipClearsIt() throws {
        let state = state(listing)
        state.figuresSectionExpanded = false
        state.showFigures(inPiece: "doc-b")
        XCTAssertEqual(state.pieceFilter, "doc-b")
        XCTAssertTrue(state.figuresSectionExpanded)
        XCTAssertEqual(state.scrollRequest, .figuresHeader)
        XCTAssertEqual(state.drawnFigureRows.map(\.id), [cash.figureId])
        XCTAssertEqual(BinderTreeSelection.drawnFigureOrder(state), [cash.figureId])
        XCTAssertTrue(state.drawsFigure(map.figureId, projectType: .novel),
                      "a figure the filter hides still has a row: a note's click travels to it")

        state.clearFigureFilter()
        XCTAssertNil(state.pieceFilter)
        XCTAssertEqual(state.drawnFigureRows.map(\.id), listing.map(\.figureId))

        for host in ["Views/BinderView.swift", "Views/CollectionPiecesPane.swift"] {
            let source = try Self.source(of: host)
            XCTAssertTrue(source.contains("onShowFigures: { treeState.showFigures(inPiece: "),
                          "\(host)'s piece row count does not filter the section")
            XCTAssertTrue(source.contains("figureCount: treeState.figureCountText("), host)
        }
    }

    /// **A note's travel to a figure the filter hides lifts the filter**
    /// (review I1): the figure counterpart of `reveal` — the section opens,
    /// the tree scrolls to the row; a figure the section has no row for (a
    /// parked one) moves nothing.
    func test_revealingAFigureTheFilterHidesLiftsTheFilterAndOpensTheSection() {
        let state = state(listing)
        state.showFigures(inPiece: "doc-b")
        state.figuresSectionExpanded = false
        state.scrollRequest = nil

        state.revealFigure(cash.figureId)
        XCTAssertEqual(state.pieceFilter, "doc-b", "a figure the filter shows keeps the filter")
        XCTAssertTrue(state.figuresSectionExpanded)
        XCTAssertEqual(state.scrollRequest, .row(.figure(cash.figureId)))

        state.revealFigure(map.figureId)
        XCTAssertNil(state.pieceFilter, "the filter hid the figure: lifted")
        XCTAssertTrue(state.drawnFigureRows.contains { $0.id == map.figureId })
        XCTAssertEqual(state.scrollRequest, .row(.figure(map.figureId)))

        state.showFigures(inPiece: "doc-b")
        state.scrollRequest = nil
        state.revealFigure("fig-99999999")
        XCTAssertEqual(state.pieceFilter, "doc-b", "no row for it: nothing moves")
        XCTAssertNil(state.scrollRequest)
    }

    /// The pane reveals before it travels, and the window hands it the tree's reveal.
    func test_theQueuesFigureTravelRevealsTheRowFirst() throws {
        let pane = try Self.source(of: "Views/AnnotationsPane.swift")
        XCTAssertTrue(pane.contains("if case .figure(let id) = subject { revealFigure(id) }\n            onTravel(subject)"))
        let window = try Self.source(of: "Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains("revealFigure: { [treeState] in treeState.revealFigure($0) }"))
    }

    func test_aFilterOnAPieceThatNoLongerUsesAFigureLetsGo() {
        let state = state(listing)
        state.showFigures(inPiece: "doc-b")
        state.refreshFigureRows(listing: [map, tax, spare])
        XCTAssertNil(state.pieceFilter)
    }

    /// The selection's order and a note's travel follow the section: a
    /// parked figure is neither ordered nor travelled to.
    func test_selectionOrderAndTravelFollowTheDrawnRows() async {
        let state = state([cash, tax])
        XCTAssertEqual(
            BinderTreeSelection.ordered([.figure(tax.figureId), .figure(cash.figureId)],
                                        structure: [], research: [],
                                        figures: BinderTreeSelection.drawnFigureOrder(state)),
            [.figure(cash.figureId), .figure(tax.figureId)])
        XCTAssertTrue(state.drawsFigure(cash.figureId, projectType: .novel))
        XCTAssertFalse(state.drawsFigure(cash.figureId, projectType: .screenplay))
        XCTAssertFalse(state.drawsFigure("fig-99999999", projectType: .novel))
    }

    // MARK: - Folding before a send

    /// `FigureWindows.foldGrids(on:)` folds the in-place grid and closes the
    /// window on the figure, and only those.
    func test_foldGridsFoldsTheInPlaceGridAndClosesTheWindowOnTheFigure() async {
        let windows = FigureWindows()
        var folded: [String] = [], closed: [String] = []
        var hold: FigureWindows.InPlaceHold?
        hold = windows.holdInPlace(cash.figureId, focus: {}, fold: {
            folded.append("cash")
            if let hold { windows.releaseInPlace(hold, visitEnding: nil) }
        })
        _ = windows.holdInPlace(tax.figureId, focus: {}, fold: { folded.append("tax") })
        _ = windows.opened(map.figureId, close: { closed.append("map") })
        _ = windows.opened(spare.figureId, close: { closed.append("spare") })

        await windows.foldGrids(on: cash.figureId)
        await windows.foldGrids(on: map.figureId)
        XCTAssertEqual(folded, ["cash"])
        XCTAssertEqual(closed, ["map"])
        XCTAssertFalse(windows.isHeld(cash.figureId))
    }

    // MARK: - Source helpers

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/Views/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func declaration(named header: String, in source: String) -> String? {
        guard let start = source.range(of: header) else { return nil }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }
}

/// **A figure row's verbs on a real book** (report plan 8a Task 4): Open in
/// Window hands the listing's number and caption; Send to Research parks the
/// figure, whose row then leaves the section through the tree's own cards;
/// Rename renames it. Each verb is called as its menu item would call it.
@MainActor
final class FigureSectionVerbTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figuresection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    /// The registry's figures as the listing gives them unused: no line yet.
    private func unusedRows(_ store: ProjectStore) -> [FigureListing.Row] {
        (store.manifest.figures ?? []).map {
            FigureListing.Row(figureId: $0.id, kind: $0.kind, name: $0.name, caption: "",
                              number: FigureListing.unusedNumber, usedIn: [],
                              referencedFrom: [], pieceOfLine: nil)
        }
    }

    func test_openInWindowHandsTheWindowTheListingsNumberAndCaption() async throws {
        let (documentStore, store) = try await openBook()
        defer { withExtendedLifetime(documentStore) {} }
        let state = BinderTreeSectionsState()
        let windows = FigureWindows()
        state.figureWindows = windows
        state.refreshFigureRows(listing: [FigureListing.Row(
            figureId: "fig-0a1b2c3d", kind: .table, name: "cash", caption: "Cash at year end",
            number: "Table 1", usedIn: [FigureListing.Use(docId: "doc-a", lineIndex: 0)],
            referencedFrom: [], pieceOfLine: "doc-a")])
        let verbs = FigureSectionVerbs(store: store, state: state)

        verbs.openInWindow(state.figureRows[0])

        let handoff = windows.handoff(for: "fig-0a1b2c3d")
        XCTAssertEqual(handoff?.number, "Table 1")
        XCTAssertEqual(handoff?.caption, "Cash at year end")
        XCTAssertEqual(handoff?.piece, "doc-a", "the piece holding its line")
        XCTAssertEqual(verbs.sendDestinations(for: state.figureRows[0]), [.piece, .shared])
    }

    /// **Send to Research from the row**: the figure parks, the tree's cards
    /// refill, its row leaves, and with the last figure the section goes.
    func test_sendToResearchFromTheRowParksItAndTheSectionLetsItGo() async throws {
        let (documentStore, store) = try await openBook()
        let kept = try await store.createFigure(kind: .table, name: "kept", piece: nil)
        let sent = try await store.createFigure(kind: .table, name: "sent", piece: nil)
        let state = BinderTreeSectionsState()
        FigureSectionWiring.attach(state, to: documentStore)
        state.refreshFigureRows(listing: unusedRows(store))
        await state.figureCards.idle()
        XCTAssertEqual(Set(state.figureRows.map(\.id)), [kept.id, sent.id])
        let verbs = FigureSectionVerbs(store: store, state: state)
        let row = try XCTUnwrap(state.figureRows.first { $0.id == sent.id })
        XCTAssertTrue(verbs.mayEdit(sent.id), "the book's author may send it")
        XCTAssertEqual(verbs.sendDestinations(for: row), [.shared], "no piece: shared only")

        await verbs.sendToResearch(row, to: .shared)?.value
        await state.figureCards.idle()

        XCTAssertNil(state.pendingError)
        XCTAssertEqual(state.figureRows.map(\.id), [kept.id])
        XCTAssertTrue(state.showsFigures(projectType: .novel))

        _ = try await store.sendToResearch(figureId: kept.id, scope: .shared)
        await state.figureCards.idle()
        XCTAssertFalse(state.showsFigures(projectType: .novel),
                       "the last figure parked: no section")
        FigureSectionWiring.attach(state, to: nil)
    }

    func test_renameFromTheRowRenamesTheFigure() async throws {
        let (documentStore, store) = try await openBook()
        let figure = try await store.createFigure(kind: .table, name: "cash", piece: nil)
        let state = BinderTreeSectionsState()

        await FigureSectionVerbs(store: store, state: state).rename(figure.id, to: "cashflow").value
        withExtendedLifetime(documentStore) {}   // the store holds it weakly

        XCTAssertNil(state.pendingError)
        XCTAssertEqual(store.manifest.figures?.first { $0.id == figure.id }?.name, "cashflow")
    }

    /// One chapter bootstrapped into its op log, and a window over the book
    /// (`FigureSubjectValidationTests`' fixture).
    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        let chapter = projectURL.appendingPathComponent("manuscript/a.md")
        try "Words.\n".write(to: chapter, atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document,
                                      path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(url: chapter, actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }
}

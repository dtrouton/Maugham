import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Figures already in Research, and Move into Figures** (report plan 8b
/// Task 9, spec §4.4): a figure line written before figures had their own
/// folder (`../research/q3.csv`) lists in the Figures section tagged
/// "in Research" — the section shows for it with no figure at all — and its
/// menu's *Move into Figures* makes the figure (`useInDocument`, the line's
/// label as its name) and then points the line at it (`retargetFigureLine`),
/// in a closed piece. Nothing is made where the window or the posture
/// refuses, where the path names nothing in Research, or where the line's
/// label could not be the figure's name; a line refused after the figure was
/// made leaves it unused, and says so. Each verb is called as its menu item
/// calls it.
@MainActor
final class LegacyFigureMoveTests: XCTestCase {

    private var projectURL: URL!
    /// Held for the test's length: `ProjectStore.documentStore` is weak.
    private var documentStore: DocumentStore?

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("legacyfig-\(UUID().uuidString)")
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
        ProjectStore.figureRelabelReadFailsForTesting = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        documentStore = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private static let labelled = "Intro.\n\n![Revenue](../research/q3.csv){#tbl:q3}\n\nAfter.\n"

    /// A novel with chapter A holding `text`, closed, Research holding
    /// `q3.csv`, and a window over it.
    private func openBook(_ text: String = labelled,
                          csv contents: String = "Quarter,Revenue\nQ3,100\n") async throws -> (ProjectStore, ResearchItem) {
        try text.write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        documentStore = store
        let outside = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let csv = outside.appendingPathComponent("q3.csv")
        try Data(contents.utf8).write(to: csv)
        let item = try await projectStore.addResearchAsset(parentId: nil, fromURL: csv)
        XCTAssertEqual(item.path, "research/q3.csv", "precondition: shared Research")
        return (projectStore, item)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    /// Chapter A's text now, from its op log.
    private func chapterText() async throws -> String {
        let doc = try await Document.load(url: file("manuscript/a.md"), actor: .author, session: "read", presenter: nil)
        let text = doc.displayText
        await doc.close()
        return text
    }

    /// The index of chapter A's `text`, as the window builds it.
    private func index(_ text: String) -> ReferenceIndex {
        ReferenceIndex.build(pieces: [(docId: "doc-a", summary: ReferenceIndex.PieceSummary(text: text))],
                             research: [], words: .english)
    }

    /// The tree's state with chapter A's lines into Research listed, as
    /// `FigureSectionWiring` hands them on.
    private func tree(_ store: ProjectStore, text: String) async throws -> BinderTreeSectionsState {
        let state = BinderTreeSectionsState()
        state.refreshLegacyFigureRows(FigureListing.legacyRows(
            index: index(text), research: store.manifest.research,
            documentPathOf: { $0 == "doc-a" ? "manuscript/a.md" : nil }))
        await documentStore?.postureSettled()
        return state
    }

    private func verbs(_ store: ProjectStore, _ state: BinderTreeSectionsState) -> FigureSectionVerbs {
        FigureSectionVerbs(store: store, state: state)
    }

    // MARK: - The listing

    /// **A line into Research lists, tagged, and shows the section with no
    /// figure at all**; it is matched to its Research item, numbered as it
    /// publishes, and selects nothing. A line into `figures/`, a titled link
    /// and an angle-bracketed path are not legacy lines (the last two are no
    /// figure line at all, so Move never meets them).
    func test_aLegacyLineListsWithItsTag() async throws {
        let (store, item) = try await openBook()
        let text = "![Revenue](../research/q3.csv){#tbl:q3}\n\n"
            + "![Cash](../figures/cash.csv)\n\n"
            + "![Titled](../research/q3.csv \"t\")\n\n"
            + "![Angled](<../research/q3.csv>)\n"
        let lines = FigureListing.legacyRows(index: index(text), research: store.manifest.research,
                                             documentPathOf: { _ in "manuscript/a.md" })
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line.docId, "doc-a")
        XCTAssertEqual(line.lineIndex, 0)
        XCTAssertEqual(line.path, "../research/q3.csv")
        XCTAssertEqual(line.number, "Table 1")
        XCTAssertEqual(line.label?.reference, "tbl:q3")
        XCTAssertEqual(line.researchItemId, item.id)

        let state = try await tree(store, text: text)
        XCTAssertTrue(state.figureRows.isEmpty, "precondition: no figure records")
        XCTAssertTrue(state.showsFigures(projectType: .novel), "the section shows for a legacy line alone")
        XCTAssertEqual(state.legacyFigureRows.map(\.title), ["Revenue"])
        XCTAssertEqual(LegacyFigureTreeRow.tag, "in Research")
        XCTAssertEqual(state.figureCountText(forPiece: "doc-a", projectType: .novel), "1 table")
        XCTAssertTrue(verbs(store, state).legacyActions(
            for: try XCTUnwrap(state.legacyFigureRows.first), select: { _ in }).mayMove())
    }

    /// Typing above the line moves its index but redraws no row; the press
    /// reads the new index.
    func test_aMovedLineRedrawsNothingButThePressReadsIt() async throws {
        let (store, _) = try await openBook()
        let state = try await tree(store, text: "![Revenue](../research/q3.csv){#tbl:q3}\n")
        let drawn = state.legacyFigureRows
        state.refreshLegacyFigureRows(FigureListing.legacyRows(
            index: index("Above.\n\n![Revenue](../research/q3.csv){#tbl:q3}\n"),
            research: store.manifest.research, documentPathOf: { _ in "manuscript/a.md" }))
        XCTAssertEqual(state.legacyFigureRows, drawn)
        XCTAssertEqual(state.legacyFigureLines[drawn[0].id]?.lineIndex, 2)
    }

    // MARK: - Move into Figures

    /// **In a closed piece**: the figure is made under the line's label name
    /// and the line points at it — caption and label kept; then the line
    /// resolves to the figure, which numbers, and no legacy line is left.
    func test_moveIntoFiguresMakesTheFigureAndRetargetsTheLineInAClosedPiece() async throws {
        let (store, _) = try await openBook()
        XCTAssertNil(documentStore?.document(for: "manuscript/a.md"), "precondition: A is closed")
        let state = try await tree(store, text: try await chapterText())
        let row = try XCTUnwrap(state.legacyFigureRows.first)

        await verbs(store, state).moveIntoFigures(row.id)?.value

        XCTAssertNil(state.pendingError)
        let figure = try XCTUnwrap(store.manifest.figures?.first)
        XCTAssertEqual(figure.name, "q3")
        XCTAssertEqual(figure.kind, .table)
        XCTAssertNil(figure.piece, "shared Research: the whole book's figure")
        XCTAssertEqual(state.pendingFigureReveal, figure.id, "its row is revealed once drawn")
        let text = try await chapterText()
        XCTAssertEqual(text, "Intro.\n\n![Revenue](../figures/q3.csv){#tbl:q3}\n\nAfter.")

        let rows = FigureListing.build(index: index(text), records: store.manifest.figures ?? [],
                                       documentPathOf: { _ in "manuscript/a.md" })
        XCTAssertEqual(rows.map(\.figureId), [figure.id])
        XCTAssertEqual(rows.first?.number, "Table 1")
        XCTAssertEqual(rows.first?.usedIn, [FigureListing.Use(docId: "doc-a", lineIndex: 2)])
        XCTAssertTrue(FigureListing.legacyRows(index: index(text), research: store.manifest.research,
                                               documentPathOf: { _ in "manuscript/a.md" }).isEmpty)
    }

    /// **An unlabelled line takes the figure's label**, so Send and Rename
    /// find it.
    func test_anUnlabelledLineTakesTheFiguresLabel() async throws {
        let (store, _) = try await openBook("![Revenue](../research/q3.csv)\n")
        let state = try await tree(store, text: try await chapterText())
        await verbs(store, state).moveIntoFigures(try XCTUnwrap(state.legacyFigureRows.first).id)?.value

        XCTAssertNil(state.pendingError)
        let figure = try XCTUnwrap(store.manifest.figures?.first)
        let text = try await chapterText()
        XCTAssertEqual(text, "![Revenue](../figures/\(figure.name).csv){#tbl:\(figure.name)}")
    }

    /// **A piece this Mac may not write**: Move is not offered, and the verb
    /// refuses with the reason — nothing made, the line as it was. A window
    /// that refuses figure writes offers nothing either.
    func test_aPostureRefusalMakesNothing() async throws {
        let (store, _) = try await openBook()
        let sam = LocalIdentities.softwareForTesting()
        _ = try await documentStore?.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam\u{2019}s Mac",
            permit: .author(.pieces(["doc-a"])))
        let state = try await tree(store, text: try await chapterText())
        XCTAssertEqual(documentStore?.posture(forDocId: "doc-a").yieldingTo, "Sam",
                       "precondition: this Mac yields on A")
        let row = try XCTUnwrap(state.legacyFigureRows.first)
        let actions = verbs(store, state).legacyActions(for: row, select: { _ in })
        XCTAssertFalse(actions.mayMove())

        await verbs(store, state).moveIntoFigures(row.id)?.value
        XCTAssertEqual(state.pendingError,
                       FigureActions.MoveIntoFiguresRefused(reason: .pieceNotWritable("A")).localizedDescription)
        XCTAssertTrue(store.manifest.figures?.isEmpty ?? true, "nothing made")
        let text = try await chapterText()
        XCTAssertEqual(text, "Intro.\n\n![Revenue](../research/q3.csv){#tbl:q3}\n\nAfter.")

        state.pendingError = nil
        documentStore?.overrideYield(docId: "doc-a")
        state.figureWritesRefused = true
        XCTAssertFalse(verbs(store, state).legacyActions(for: row, select: { _ in }).mayMove())
        XCTAssertNil(verbs(store, state).moveIntoFigures(row.id))
        XCTAssertEqual(state.pendingError, FigureSectionVerbs.windowMakesNoFigures)
        XCTAssertTrue(store.manifest.figures?.isEmpty ?? true, "nothing made")
    }

    /// **A path that names nothing in Research** offers no Move — the menu
    /// says the file isn't in Research — and the verb says so.
    func test_aPathMatchingNoResearchItemOffersNoMove() async throws {
        let (store, _) = try await openBook("![Gone](../research/gone.csv){#tbl:gone}\n")
        let state = try await tree(store, text: try await chapterText())
        let row = try XCTUnwrap(state.legacyFigureRows.first)
        XCTAssertFalse(row.movable)
        XCTAssertEqual(LegacyFigureTreeRow.notInResearch, "The file isn\u{2019}t in Research")
        XCTAssertFalse(verbs(store, state).legacyActions(for: row, select: { _ in }).mayMove())

        XCTAssertNil(verbs(store, state).moveIntoFigures(row.id))
        XCTAssertEqual(state.pendingError,
                       FigureActions.MoveIntoFiguresRefused(reason: .notInResearch).localizedDescription)
        XCTAssertTrue(store.manifest.figures?.isEmpty ?? true)
    }

    /// **A label another figure has** is not changed under its
    /// cross-references: refused, nothing made.
    func test_aLabelAnotherFigureHasIsRefused() async throws {
        let (store, _) = try await openBook()
        _ = try await store.createFigure(kind: .table, name: "q3", piece: nil)
        let state = try await tree(store, text: try await chapterText())
        await verbs(store, state).moveIntoFigures(try XCTUnwrap(state.legacyFigureRows.first).id)?.value
        XCTAssertEqual(state.pendingError,
                       FigureActions.MoveIntoFiguresRefused(reason: .nameTaken("q3")).localizedDescription)
        XCTAssertEqual(store.manifest.figures?.count, 1, "nothing more made")
    }

    /// **A line that moved since it was listed** is refused before anything
    /// is made (the retarget's dry run on the piece's current text).
    func test_aLineThatMovedSinceItWasListedMakesNothing() async throws {
        let (store, _) = try await openBook()
        let state = try await tree(store, text: try await chapterText())
        let row = try XCTUnwrap(state.legacyFigureRows.first)
        let live = try await Document.load(url: file("manuscript/a.md"), actor: .author, session: "live", presenter: nil)
        documentStore?.register(document: live, for: "manuscript/a.md")
        live.setFullText("New first line.\n" + live.displayText)
        let moved = live.displayText

        await verbs(store, state).moveIntoFigures(row.id)?.value

        XCTAssertEqual(state.pendingError, FigureLineRetargetRefused(reason: .lineNotFound).localizedDescription)
        XCTAssertTrue(store.manifest.figures?.isEmpty ?? true, "nothing made")
        XCTAssertEqual(live.displayText, moved, "the line as it was")
        documentStore?.unregister(path: "manuscript/a.md")
        await live.close()
    }

    /// **The line refused after the figure was made** (its piece will not
    /// read as the write holds it): the figure stays, unused and revealed,
    /// and the writer is told — with what the read kept as text.
    func test_aRefusedLineLeavesTheFigureUnusedAndSaysSo() async throws {
        let (store, _) = try await openBook(csv: "Quarter,Revenue\nQ3,=1+\n")
        let state = try await tree(store, text: try await chapterText())
        let row = try XCTUnwrap(state.legacyFigureRows.first)
        ProjectStore.figureRelabelReadFailsForTesting = ["doc-a"]

        await verbs(store, state).moveIntoFigures(row.id)?.value

        let figure = try XCTUnwrap(store.manifest.figures?.first, "the figure was made")
        XCTAssertEqual(state.pendingFigureReveal, figure.id, "and revealed")
        let said = try XCTUnwrap(state.pendingError)
        XCTAssertTrue(said.hasPrefix(FigureActions.LineNotMoved(
            name: figure.name,
            reason: FigureLineRetargetRefused(reason: .unreadable("A")).localizedDescription).localizedDescription),
            said)
        XCTAssertTrue(said.contains("unused"))
        XCTAssertTrue(said.contains("kept as text"), "the read's notice is said too: \(said)")
        let text = try await chapterText()
        XCTAssertEqual(text, "Intro.\n\n![Revenue](../research/q3.csv){#tbl:q3}\n\nAfter.", "the line as it was")
    }

    /// **Move again after a refused line** takes the unused figure the first
    /// Move made — no second figure — and only points the line at it, for a
    /// labelled line and an unlabelled one.
    func test_aRetryReusesTheUnusedFigureAndMakesNoSecond() async throws {
        for (body, moved) in [
            (Self.labelled, "Intro.\n\n![Revenue](../figures/q3.csv){#tbl:q3}\n\nAfter."),
            ("![Revenue](../research/q3.csv)\n", nil),
        ] {
            try await setUp()
            let (store, _) = try await openBook(body)
            let state = try await tree(store, text: try await chapterText())
            let row = try XCTUnwrap(state.legacyFigureRows.first)
            ProjectStore.figureRelabelReadFailsForTesting = ["doc-a"]
            await verbs(store, state).moveIntoFigures(row.id)?.value
            let first = try XCTUnwrap(store.manifest.figures?.first)
            XCTAssertNotNil(state.pendingError, "precondition: the line was refused")

            ProjectStore.figureRelabelReadFailsForTesting = []
            state.pendingError = nil
            await verbs(store, state).moveIntoFigures(row.id)?.value

            XCTAssertNil(state.pendingError)
            XCTAssertEqual(store.manifest.figures?.map(\.id), [first.id], "no second figure")
            let text = try await chapterText()
            XCTAssertEqual(text, moved ?? "![Revenue](../figures/\(first.name).csv){#tbl:\(first.name)}")
            try await tearDown()
        }
    }

    /// **An unlabelled line's new label is vacant among the book's labels**,
    /// not only the figures': with Y labelled `tbl:q3` (and referenced), X —
    /// unlabelled, earlier — takes another name, so `@tbl:q3` keeps Y's number.
    func test_anUnlabelledLinesLabelIsClearOfTheBooksLabels() async throws {
        let body = "![X](../research/q3.csv)\n\n![Y](../research/q3.csv){#tbl:q3}\n\nSee @tbl:q3.\n"
        let (store, _) = try await openBook(body)
        let state = try await tree(store, text: try await chapterText())
        let x = try XCTUnwrap(state.legacyFigureRows.first { $0.title == "X" })

        await verbs(store, state).moveIntoFigures(x.id)?.value

        XCTAssertNil(state.pendingError)
        let figure = try XCTUnwrap(store.manifest.figures?.first)
        XCTAssertNotEqual(figure.name, "q3")
        let text = try await chapterText()
        XCTAssertEqual(text, "![X](../figures/\(figure.name).csv){#tbl:\(figure.name)}\n\n"
                       + "![Y](../research/q3.csv){#tbl:q3}\n\nSee @tbl:q3.")

        let lines = FigureListing.legacyRows(index: index(text), research: store.manifest.research,
                                             documentPathOf: { _ in "manuscript/a.md" })
        XCTAssertEqual(lines.count, 1, "Y is still a line into Research")
    }

    /// A label another piece defines (the window's index) is kept clear too.
    func test_anUnlabelledLinesLabelIsClearOfAnotherPiecesLabels() async throws {
        let (store, _) = try await openBook("![X](../research/q3.csv)\n")
        let state = try await tree(store, text: try await chapterText())
        state.definedFigureLabels = { [ManuscriptLabel(reference: "tbl:q3")!] }
        await verbs(store, state).moveIntoFigures(try XCTUnwrap(state.legacyFigureRows.first).id)?.value
        XCTAssertNil(state.pendingError)
        XCTAssertNotEqual(try XCTUnwrap(store.manifest.figures?.first).name, "q3")
    }
}

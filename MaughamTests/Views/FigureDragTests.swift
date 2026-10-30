import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **The drags between Research and the Figures section, performed** (report
/// plan 8b Task 5, D8-2). A Research table dropped on Figures makes an unused
/// figure with no question; a figure dropped on Research asks first — Cancel
/// changes nothing, Send parks it where the drop aimed (a piece's Research, a
/// group) and the window's figure subject repairs. A drop within Figures is
/// refused; a Mac that may not change the figure gets the reason and no
/// question. Each drop enters through the router its destination calls, and
/// each answer through the verb the alert's button calls.
@MainActor
final class FigureDragTests: XCTestCase {

    private var projectURL: URL!
    /// Held for the test's length: `ProjectStore.documentStore` is weak.
    private var documentStore: DocumentStore?

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figuredrag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        installIdentities(at: projectURL)
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        documentStore = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func installIdentities(at folder: URL) {
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: folder.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: folder.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: folder.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    // MARK: - Fixture

    /// A novel with one chapter and a window over it.
    private func openNovel() async throws -> ProjectStore {
        try "Words.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
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
        return projectStore
    }

    /// A Collection with one loose piece and a window over it.
    private func openCollection() async throws -> (ProjectStore, StructureItem) {
        let folder = TestTemp.root.appendingPathComponent("figuredrag-coll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "Stories", in: folder)
        projectURL = url
        installIdentities(at: folder)
        let documentStore = try await DocumentStore.open(url: url)
        self.documentStore = documentStore
        let store = try await ProjectStore.load(from: url)
        store.documentStore = documentStore
        documentStore.projectStore = store
        let piece = try await store.addLoosePiece(title: "Story A", format: .markdown)
        return (store, piece)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func external(_ name: String, _ text: String) throws -> URL {
        let folder = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// The tree's state with its cards on the window's store, and the
    /// listing drawing every registry figure — `number` for the first one.
    private func tree(_ store: ProjectStore, number: String = FigureListing.unusedNumber) async -> BinderTreeSectionsState {
        let state = BinderTreeSectionsState()
        FigureSectionWiring.attach(state, to: documentStore)
        state.refreshFigureRows(listing: (store.manifest.figures ?? []).enumerated().map { index, record in
            let used = index == 0 && number != FigureListing.unusedNumber
            return FigureListing.Row(figureId: record.id, kind: record.kind, name: record.name, caption: "",
                                     number: index == 0 ? number : FigureListing.unusedNumber,
                                     usedIn: used ? [FigureListing.Use(docId: "doc-a", lineIndex: 0)] : [],
                                     referencedFrom: [], pieceOfLine: used ? "doc-a" : nil)
        })
        await state.figureCards.idle()
        return state
    }

    private func verbs(_ store: ProjectStore, _ state: BinderTreeSectionsState) -> BinderTreeVerbs {
        BinderTreeVerbs(store: store, state: state, selectedSubject: .constant(nil))
    }

    private func isParked(_ figureId: String) async throws -> Bool {
        try await XCTUnwrap(documentStore).figureIsParked(figureId)
    }

    // MARK: - Research → Figures

    /// A Research table dropped on the Figures header makes an unused figure
    /// at once — no question (D8-2) — and its row is revealed once drawn.
    func test_aResearchTableDroppedOnFiguresMakesAnUnusedFigure() async throws {
        let store = try await openNovel()
        let table = try await store.addResearchAsset(
            parentId: nil, fromURL: try external("budget.csv", "Item,Amount\nRent,100\n"))
        let state = await tree(store)

        let work = FigureSectionVerbs(store: store, state: state).dropToUse(researchId: table.id)
        XCTAssertNil(state.pendingFigureSend, "no confirmation this way")
        await work?.value

        XCTAssertNil(state.pendingError)
        let figure = try XCTUnwrap(store.manifest.figures?.first)
        XCTAssertEqual(figure.name, "budget")
        XCTAssertEqual(state.pendingFigureReveal, figure.id, "revealed once its row draws")
        FigureSectionWiring.attach(state, to: nil)
    }

    /// The window refusing figure writes refuses the drop and says why; a
    /// note is refused by the classifier. Nothing is made either way.
    func test_aDropOnFiguresIsRefusedForANoteAndInARefusingWindow() async throws {
        let store = try await openNovel()
        let table = try await store.addResearchAsset(
            parentId: nil, fromURL: try external("t.csv", "1,2\n"))
        let note = try await store.addResearchTextNote(parentId: nil, title: "Ships")
        let state = await tree(store)

        XCTAssertFalse(verbs(store, state).routeFiguresDrop(draggedId: note.id, target: .figuresSection))
        XCTAssertNil(state.pendingError, "a classifier refusal bounces the drag")

        state.figureWritesRefused = true
        XCTAssertFalse(verbs(store, state).routeFiguresDrop(draggedId: table.id, target: .figuresSection))
        XCTAssertEqual(state.pendingError, FigureSectionVerbs.windowMakesNoFigures)
        XCTAssertEqual(store.manifest.figures ?? [], [])
        FigureSectionWiring.attach(state, to: nil)
    }

    /// A piece's own Research makes that piece's figure; when the piece's
    /// author is somebody else, the store's refusal is what the alert says.
    func test_aRefusedDoorOnADropIsTheStoresReason() async throws {
        let (store, piece) = try await openCollection()
        let item = try await store.addPieceResearchAsset(pieceId: piece.id, fromURL: try external("t.csv", "1,2\n"))
        let sam = LocalIdentities.softwareForTesting()
        let documentStore = try XCTUnwrap(documentStore)
        _ = try await documentStore.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces([piece.id])))
        await documentStore.postureSettled()
        let state = await tree(store)

        await FigureSectionVerbs(store: store, state: state).dropToUse(researchId: item.id)?.value
        XCTAssertEqual(state.pendingError, "This Mac may not make a figure here, so nothing was made.")
        XCTAssertEqual(store.manifest.figures ?? [], [])
        FigureSectionWiring.attach(state, to: nil)
    }

    // MARK: - Within Figures

    func test_aFigureDroppedWithinFiguresIsRefusedAndNothingMoves() async throws {
        let store = try await openNovel()
        let cash = try await store.createFigure(kind: .table, name: "cash", piece: nil)
        let tax = try await store.createFigure(kind: .table, name: "tax", piece: nil)
        let state = await tree(store)
        let before = store.manifest.figures

        XCTAssertFalse(verbs(store, state).routeFiguresDrop(draggedId: cash.id, target: .figureRow(tax.id)))
        XCTAssertFalse(verbs(store, state).routeFiguresDrop(draggedId: cash.id, target: .figuresSection))
        XCTAssertNil(state.pendingFigureSend)
        XCTAssertNil(state.pendingError)
        XCTAssertEqual(store.manifest.figures, before)
        FigureSectionWiring.attach(state, to: nil)
    }

    // MARK: - Figures → Research (D8-2)

    /// Dropped on the Research header, a figure asks — "Send Table 3 to
    /// Research?" — and Cancel changes nothing; dropped again and confirmed,
    /// it parks in shared Research and its subject repairs to the project.
    func test_aFigureDroppedOnResearchAsksCancelChangesNothingAndSendParksIt() async throws {
        let store = try await openNovel()
        let cash = try await store.createFigure(kind: .table, name: "cash", piece: nil)
        let state = await tree(store, number: "Table 3")
        let research = store.manifest.research

        XCTAssertTrue(verbs(store, state).routeSharedSectionDrop(draggedId: cash.id))
        let asked = try XCTUnwrap(state.pendingFigureSend)
        XCTAssertEqual(asked, PendingFigureSend(figureId: cash.id, scope: .shared, group: nil,
                                                called: "Table 3", hasLine: true))
        XCTAssertEqual(asked.title, "Send Table 3 to Research?")
        XCTAssertEqual(asked.message, "Its line leaves the text. This can’t be undone.")

        FigureSectionVerbs(store: store, state: state).cancelFigureSend()
        XCTAssertNil(state.pendingFigureSend)
        let stillHere = try await isParked(cash.id)
        XCTAssertFalse(stillHere, "Cancel sent nothing")
        XCTAssertEqual(store.manifest.research, research, "Cancel made nothing in Research")

        XCTAssertTrue(verbs(store, state).routeSharedSectionDrop(draggedId: cash.id))
        let again = try XCTUnwrap(state.pendingFigureSend)
        await FigureSectionVerbs(store: store, state: state).confirmFigureSend(again).value

        XCTAssertNil(state.pendingFigureSend)
        XCTAssertNil(state.pendingError)
        let parked = try await isParked(cash.id)
        XCTAssertTrue(parked)
        let copy = try XCTUnwrap(store.manifest.research.first)
        XCTAssertNil(store.researchHomePiece(ofItemId: copy.id), "shared Research")
        XCTAssertEqual(
            ProjectWindow.validSubject(.figure(cash.id), in: store.manifest.structure,
                                       research: store.manifest.research,
                                       figures: store.manifest.figures ?? [], parked: [cash.id]),
            .project, "the window's figure subject repairs")
        FigureSectionWiring.attach(state, to: nil)
    }

    /// An unused figure is called by its name and has no line to lose.
    func test_anUnusedFigureIsAskedAboutByName() async throws {
        let store = try await openNovel()
        let cash = try await store.createFigure(kind: .table, name: "cash", piece: nil)
        let state = await tree(store)
        XCTAssertTrue(verbs(store, state).routeSharedSectionDrop(draggedId: cash.id))
        XCTAssertEqual(state.pendingFigureSend?.title, "Send “cash” to Research?")
        XCTAssertEqual(state.pendingFigureSend?.message, "This can’t be undone.")
        FigureSectionWiring.attach(state, to: nil)
    }

    /// Dropped on a Collection piece's row, the figure goes to that piece's
    /// own Research.
    func test_aFigureDroppedOnAPieceGoesToThatPiecesResearch() async throws {
        let (store, piece) = try await openCollection()
        let cash = try await store.createFigure(kind: .table, name: "cash", piece: piece.id)
        let state = await tree(store)

        XCTAssertTrue(verbs(store, state).routePieceRowDrop(draggedId: cash.id, documentId: piece.id) {
            XCTFail("a figure is no manuscript reorder")
        })
        let asked = try XCTUnwrap(state.pendingFigureSend)
        XCTAssertEqual(asked.scope, .document(piece.id))
        await FigureSectionVerbs(store: store, state: state).confirmFigureSend(asked).value

        XCTAssertNil(state.pendingError)
        let parked = try await isParked(cash.id)
        XCTAssertTrue(parked)
        let copies = TreeWalk.collect(in: store.manifest.research) { $0.type == .asset }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(store.researchHomePiece(ofItemId: copies[0].id), piece.id)
        FigureSectionWiring.attach(state, to: nil)
    }

    /// Dropped on a Research group, the figure goes to the scope's root and
    /// then into the group; a move that fails leaves it at the root and the
    /// writer is told.
    func test_aFigureDroppedOnAGroupLandsInItAndAFailedMoveIsSaid() async throws {
        let store = try await openNovel()
        let cash = try await store.createFigure(kind: .table, name: "cash", piece: nil)
        let tax = try await store.createFigure(kind: .table, name: "tax", piece: nil)
        let world = try await store.addResearchItem(parentId: nil, title: "World", kind: nil)
        let state = await tree(store, number: "Table 1")

        XCTAssertTrue(verbs(store, state).routeResearchRowDrop(
            draggedId: cash.id, position: .middle, target: world, inFoldOf: nil))
        let asked = try XCTUnwrap(state.pendingFigureSend)
        XCTAssertEqual(asked.group, world.id)
        await FigureSectionVerbs(store: store, state: state).confirmFigureSend(asked).value
        XCTAssertNil(state.pendingError)
        let group = try XCTUnwrap(TreeWalk.find(id: world.id, in: store.manifest.research))
        XCTAssertEqual(group.children?.count, 1, "the copy is inside the group")

        // A group gone by the time the send lands: the copy stays at the root.
        let stale = PendingFigureSend(figureId: tax.id, scope: .shared, group: "gone-group",
                                      called: "“tax”", hasLine: false)
        await FigureSectionVerbs(store: store, state: state).confirmFigureSend(stale).value
        let parked = try await isParked(tax.id)
        XCTAssertTrue(parked, "the send itself landed")
        XCTAssertTrue(state.pendingError?.hasPrefix("“tax” is in Research, but it couldn’t go into “gone-group”")
                      == true, state.pendingError ?? "nothing said")
        XCTAssertEqual(store.manifest.research.filter { $0.type == .asset }.count, 1,
                       "the copy is at the root")
        FigureSectionWiring.attach(state, to: nil)
    }

    /// A Mac that may not change the figure gets no question — only the
    /// reason — whether the window refuses writes or the figure's door does.
    func test_aPostureRefusedWriterSeesNoConfirmationAndAReason() async throws {
        let (store, piece) = try await openCollection()
        let cash = try await store.createFigure(kind: .table, name: "cash", piece: piece.id)
        let state = await tree(store)

        state.figureWritesRefused = true
        XCTAssertFalse(verbs(store, state).routeSharedSectionDrop(draggedId: cash.id))
        XCTAssertNil(state.pendingFigureSend)
        XCTAssertEqual(state.pendingError, FigureSectionVerbs.mayNotSend)

        state.figureWritesRefused = false
        state.pendingError = nil
        XCTAssertTrue(verbs(store, state).routeSharedSectionDrop(draggedId: cash.id), "control: asked")
        FigureSectionVerbs(store: store, state: state).cancelFigureSend()

        let sam = LocalIdentities.softwareForTesting()
        let documentStore = try XCTUnwrap(documentStore)
        _ = try await documentStore.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces([piece.id])))
        await documentStore.postureSettled()
        XCTAssertFalse(verbs(store, state).routeSharedSectionDrop(draggedId: cash.id),
                       "the piece's figure, now Sam's")
        XCTAssertNil(state.pendingFigureSend)
        XCTAssertEqual(state.pendingError, FigureSectionVerbs.mayNotSend)
        let parked = try await isParked(cash.id)
        XCTAssertFalse(parked)
        FigureSectionWiring.attach(state, to: nil)
    }

    // MARK: - The reveal's token (Task 4's carried minor)

    /// A second reveal of the same figure inside the window is not let go
    /// by the first request's expiry.
    func test_aSecondRevealOfTheSameFigureOutlivesTheFirstsExpiry() async {
        let saved = BinderTreeSectionsState.figureRevealWindow
        BinderTreeSectionsState.figureRevealWindow = .milliseconds(20)
        defer { BinderTreeSectionsState.figureRevealWindow = saved }
        let state = BinderTreeSectionsState()
        let first = state.revealFigureWhenDrawn("fig-0a1b2c3d")
        BinderTreeSectionsState.figureRevealWindow = .seconds(30)
        let second = state.revealFigureWhenDrawn("fig-0a1b2c3d")
        await first?.value
        XCTAssertEqual(state.pendingFigureReveal, "fig-0a1b2c3d", "the first expiry let the second go")
        state.refreshFigureRows(listing: [FigureListing.Row(
            figureId: "fig-0a1b2c3d", kind: .table, name: "cash", caption: "",
            number: FigureListing.unusedNumber, usedIn: [], referencedFrom: [], pieceOfLine: nil)])
        XCTAssertEqual(state.scrollRequest, .row(.figure("fig-0a1b2c3d")))
        second?.cancel()
    }
}

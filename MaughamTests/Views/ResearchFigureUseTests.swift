import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **Use in Document and Bring Back to Figures, from Research** (report plan
/// 8b Task 4, spec §4.1–4.2, D8b-1): a Research table, picture or PDF offers
/// *Use in Document* in its row menu and its inspector; both make an unused
/// figure through the store's verb and reveal its row in the Figures section
/// once drawn. A parked figure's working copy reads *Bring Back to Figures*
/// and the same verb returns it with its history. A note offers nothing; a
/// window refusing writes offers nothing; the figure's door refusing is said.
/// Each verb is called as its menu item or button calls it.
@MainActor
final class ResearchFigureUseTests: XCTestCase {

    private var projectURL: URL!
    /// Held for the test's length: `ProjectStore.documentStore` is weak.
    private var documentStore: DocumentStore?

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("researchuse-\(UUID().uuidString)")
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
    private func openBook() async throws -> ProjectStore {
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

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func external(_ name: String, _ text: String) throws -> URL {
        try external(name, Data(text.utf8))
    }

    private func external(_ name: String, _ data: Data) throws -> URL {
        let folder = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// The tree's state with its cards on the window's store, as
    /// `FigureSectionWiring` leaves it.
    private func tree(_ store: ProjectStore) -> BinderTreeSectionsState {
        let state = BinderTreeSectionsState()
        FigureSectionWiring.attach(state, to: documentStore)
        return state
    }

    /// The listing catching up: every registry figure as an unused row, then
    /// the cards' fill.
    private func listingSettles(_ store: ProjectStore, _ state: BinderTreeSectionsState) async {
        state.refreshFigureRows(listing: (store.manifest.figures ?? []).map {
            FigureListing.Row(figureId: $0.id, kind: $0.kind, name: $0.name, caption: "",
                              number: FigureListing.unusedNumber, usedIn: [],
                              referencedFrom: [], pieceOfLine: nil)
        })
        await state.figureCards.idle()
    }

    private func menu(_ store: ProjectStore, _ state: BinderTreeSectionsState) -> ResearchTreeActions {
        BinderTreeVerbs(store: store, state: state, selectedSubject: .constant(nil)).bundle
    }

    // MARK: - Use in Document

    /// The row's menu: a Research CSV offers *Use in Document*; choosing it
    /// makes an unused figure (no line — D8b-1) and, once the listing draws
    /// its row, the Figures section opens and scrolls to it.
    func test_theRowMenuMakesAnUnusedFigureAndRevealsIt() async throws {
        let store = try await openBook()
        let item = try await store.addResearchAsset(
            parentId: nil, fromURL: try external("budget.csv", "Item,Amount\nRent,100\n"))
        let state = tree(store)
        state.figuresSectionExpanded = false
        let actions = menu(store, state)

        XCTAssertEqual(actions.figureVerb(item), .use)
        XCTAssertEqual(actions.figureVerb(item)?.title, "Use in Document")
        await actions.performFigureVerb(item)?.value

        XCTAssertNil(state.pendingError)
        let figure = try XCTUnwrap(store.manifest.figures?.first)
        XCTAssertEqual(figure.name, "budget")
        XCTAssertNil(figure.piece, "shared Research: the whole book's figure")
        XCTAssertEqual(state.pendingFigureReveal, figure.id, "its row is not drawn yet")
        XCTAssertNil(state.scrollRequest)

        await listingSettles(store, state)
        XCTAssertEqual(state.scrollRequest, .row(.figure(figure.id)))
        XCTAssertTrue(state.figuresSectionExpanded)
        XCTAssertNil(state.pendingFigureReveal)
        XCTAssertEqual(state.figureRows.first { $0.id == figure.id }?.isUnused, true)
        FigureSectionWiring.attach(state, to: nil)
    }

    /// The inspector's button: the same verb, a picture this time; the figure
    /// already drawn is revealed at once. Cells the read kept as text are
    /// said once, on the panel's line.
    func test_theInspectorMakesAnUnusedFigureRevealsItAndSaysWhatItKeptAsTextOnce() async throws {
        let store = try await openBook()
        let state = tree(store)
        let item = try await store.addResearchAsset(
            parentId: nil, fromURL: try external("odd.csv", "A,B\n1,=1+\n2,=2+\n"))
        XCTAssertEqual(InspectorResearchPanel.figureVerb(for: item, store: store, tree: state,
                                                         windowRefusesWrites: false), .use)
        var said: [String] = []
        await InspectorResearchPanel.useInDocument(item, store: store, tree: state,
                                                   windowRefusesWrites: false) { said.append($0) }.value

        let figure = try XCTUnwrap(store.manifest.figures?.first)
        XCTAssertEqual(said.count, 1, "said once: \(said)")
        XCTAssertTrue(said.first?.contains("2 formulas couldn’t be read") == true, said.first ?? "")
        XCTAssertNil(state.pendingError, "the inspector's line, not the tree's alert")
        await listingSettles(store, state)
        XCTAssertEqual(state.scrollRequest, .row(.figure(figure.id)))

        // A second figure, its row drawn before the verb answers: revealed at once.
        let picture = try await store.addResearchAsset(
            parentId: nil, fromURL: try external("harbour.png", try TestImageBytes.png(seed: 4)))
        said = []
        await InspectorResearchPanel.useInDocument(picture, store: store, tree: state,
                                                   windowRefusesWrites: false) { said.append($0) }.value
        XCTAssertEqual(said, [], "a picture has nothing to say")
        let second = try XCTUnwrap(store.manifest.figures?.first { $0.id != figure.id })
        XCTAssertEqual(second.kind, .image)
        await listingSettles(store, state)
        XCTAssertEqual(state.scrollRequest, .row(.figure(second.id)))
        FigureSectionWiring.attach(state, to: nil)
    }

    /// A note or a link offers nothing; neither does a window that refuses
    /// figure writes — the menu's and the inspector's answers alike.
    func test_aNoteOffersNothingAndARefusingWindowOffersNothing() async throws {
        let store = try await openBook()
        let state = tree(store)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Ships")
        let table = try await store.addResearchAsset(
            parentId: nil, fromURL: try external("t.csv", "1,2\n"))
        let group = try await store.addResearchItem(parentId: nil, title: "G", kind: nil)

        XCTAssertNil(menu(store, state).figureVerb(note))
        XCTAssertNil(menu(store, state).figureVerb(group))
        XCTAssertNil(InspectorResearchPanel.figureVerb(for: note, store: store, tree: state,
                                                       windowRefusesWrites: false))
        XCTAssertEqual(menu(store, state).figureVerb(table), .use, "control: a table offers it")

        state.figureWritesRefused = true
        XCTAssertNil(menu(store, state).figureVerb(table), "a view-only share, ⌘⌥⇧R, Review")
        XCTAssertNil(InspectorResearchPanel.figureVerb(for: table, store: store, tree: state,
                                                       windowRefusesWrites: true))
        FigureSectionWiring.attach(state, to: nil)
    }

    // MARK: - Bring Back to Figures

    /// A parked figure's unchanged working copy reads *Bring Back to Figures*;
    /// the verb resumes that same figure — its record, its stream with one
    /// resume appended, its cells — and its row is revealed again.
    func test_anUnchangedParkedCopyBringsTheFigureBackWithItsHistory() async throws {
        let store = try await openBook()
        let source = try await store.addResearchAsset(
            parentId: nil, fromURL: try external("cash.csv", "Item,Amount\nRent,1200\n"))
        let cash = try await store.useInDocument(researchItemId: source.id, piece: nil).record
        let state = tree(store)
        await listingSettles(store, state)
        let before = try await figureState(cash.id)
        let copy = try await store.sendToResearch(figureId: cash.id, scope: .shared)
        await listingSettles(store, state)
        XCTAssertFalse(state.figureRows.contains { $0.id == cash.id }, "parked: no row")
        let parkedOps = try OpLogStore.loadSyncMerged(forDocId: cash.id, in: projectURL, facts: .empty).count

        await state.refreshFigureReturns(store: store)
        XCTAssertEqual(state.figureReturns, [copy.id: cash.id])
        let actions = menu(store, state)
        XCTAssertEqual(actions.figureVerb(copy), .returnToFigures(figureId: cash.id))
        XCTAssertEqual(actions.figureVerb(copy)?.title, "Bring Back to Figures")
        XCTAssertEqual(actions.figureVerb(source), .use, "control: the figure's own source makes a new one")

        await actions.performFigureVerb(copy)?.value

        XCTAssertNil(state.pendingError)
        XCTAssertEqual(store.manifest.figures?.map(\.id), [cash.id], "nothing new was made")
        let back = try await figureState(cash.id)
        XCTAssertNil(back.parked)
        XCTAssertEqual(back.table, before.table, "its cells and ids as they were")
        XCTAssertEqual(try OpLogStore.loadSyncMerged(forDocId: cash.id, in: projectURL, facts: .empty).count,
                       parkedOps + 1, "its history kept, one resume appended")
        await listingSettles(store, state)
        XCTAssertEqual(state.scrollRequest, .row(.figure(cash.id)))
        await state.refreshFigureReturns(store: store)
        XCTAssertEqual(state.figureReturns, [:], "back: the copy brings nothing back now")
        FigureSectionWiring.attach(state, to: nil)
    }

    private func figureState(_ id: String) async throws -> FigureState {
        let doc = try await FigureDocument.load(
            figureId: id, projectURL: projectURL, actor: .author,
            session: "read", presenter: nil, documentStore: nil)
        let state = doc.state
        await doc.close()
        return state
    }

    // MARK: - A piece's Research, and the door

    /// In a Collection the figure belongs to the piece whose Research holds
    /// the item. When that piece's author is somebody else, this Mac yields on
    /// it: the new figure's door refuses, nothing is made, and the tree's
    /// alert says so. Control: an item in shared Research makes the whole
    /// book's figure.
    func test_aPiecesItemIsThatPiecesFigureAndARefusedDoorIsSaid() async throws {
        let folder = TestTemp.root.appendingPathComponent("researchuse-coll-\(UUID().uuidString)")
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
        let pieceItem = try await store.addPieceResearchAsset(
            pieceId: piece.id, fromURL: try external("tally.csv", "1,2\n"))
        let sharedItem = try await store.addResearchAsset(
            parentId: nil, fromURL: try external("shared.csv", "3,4\n"))
        XCTAssertEqual(store.researchHomePiece(ofItemId: pieceItem.id), piece.id)
        XCTAssertNil(store.researchHomePiece(ofItemId: sharedItem.id))

        let sam = LocalIdentities.softwareForTesting()
        _ = try await documentStore.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces([piece.id])))
        await documentStore.postureSettled()
        XCTAssertFalse(documentStore.posture(forDocId: piece.id).allows(.writeText),
                       "precondition: this Mac yields on Sam's piece")

        let state = tree(store)
        let actions = menu(store, state)
        XCTAssertEqual(actions.figureVerb(pieceItem), .use, "offered: the door is the store's to ask")
        await actions.performFigureVerb(pieceItem)?.value
        XCTAssertEqual(state.pendingError, "This Mac may not make a figure here, so nothing was made.")
        XCTAssertEqual(store.manifest.figures ?? [], [])
        XCTAssertNil(state.pendingFigureReveal)

        state.pendingError = nil
        await actions.performFigureVerb(sharedItem)?.value
        XCTAssertNil(state.pendingError)
        XCTAssertEqual(store.manifest.figures?.map(\.piece), [nil], "control: shared Research, the whole book's")
        FigureSectionWiring.attach(state, to: nil)
    }
}

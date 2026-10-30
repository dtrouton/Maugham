import XCTest
import SwiftUI
@testable import Maugham
@testable import MaughamCore

/// **New Table in Research** (report plan 8b Task 8, D8b-2): wherever
/// Research offers New Note — the section header's menu, a row's or group's
/// context menu, a piece's fold — it offers New Table: a blank table of three
/// columns, a header row and three empty body rows, named "Untitled Table"
/// (then "Untitled Table 2"), selected so the centre opens it in the grid,
/// and in rename as a new note is. Not offered on a view-only share or in
/// Review. Each menu item's own closure is called, and its work awaited.
@MainActor
final class ResearchNewTableTests: XCTestCase {

    private var folder: URL!
    private var stores: [DocumentStore] = []

    override func setUp() async throws {
        folder = TestTemp.root.appendingPathComponent("newtable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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

    override func tearDown() async throws {
        for store in stores { await store.close() }
        stores = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Fixture

    private func open(_ url: URL) async throws -> ProjectStore {
        let documentStore = try await DocumentStore.open(url: url)
        stores.append(documentStore)
        let store = try await ProjectStore.load(from: url)
        store.documentStore = documentStore
        documentStore.projectStore = store
        await store.wordCountPopulationTask?.value
        return store
    }

    private func novel() async throws -> ProjectStore {
        try await open(try await ProjectFactory.createNovelProject(named: "Novel", in: folder))
    }

    private func collection() async throws -> ProjectStore {
        try await open(try await ProjectFactory.createCollectionProject(named: "Stories", in: folder))
    }

    /// The window's subject, as the tree's binding writes it.
    private final class Subject { var value: BinderSubject? }

    private func verbs(_ store: ProjectStore, _ state: BinderTreeSectionsState,
                       _ subject: Subject) -> BinderTreeVerbs {
        BinderTreeVerbs(store: store, state: state,
                        selectedSubject: Binding(get: { subject.value }, set: { subject.value = $0 }))
    }

    private func fold(for documentId: String, _ store: ProjectStore, _ state: BinderTreeSectionsState,
                      _ subject: Subject) -> BinderPieceFold {
        BinderPieceFold(
            store: store, state: state,
            selectedSubject: Binding(get: { subject.value }, set: { subject.value = $0 }),
            documentId: documentId,
            fold: TreeSectionDerivation.pieceFold(
                forDocumentId: documentId, structure: store.manifest.structure,
                research: store.manifest.research, projectType: store.manifest.type))
    }

    /// Asserts `item` is a blank table — three columns, a header row and
    /// three empty body rows, in its file and in the grid — and that the
    /// window now points at it, in rename, routed to the grid.
    private func assertBlankTableOpened(_ item: ResearchItem, in store: ProjectStore,
                                        state: BinderTreeSectionsState, subject: Subject,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(item.type, .asset, file: file, line: line)
        XCTAssertEqual(item.kind, .table, file: file, line: line)
        let path = try XCTUnwrap(item.path, file: file, line: line)
        let text = try String(contentsOf: store.url.appendingPathComponent(path), encoding: .utf8)
        XCTAssertEqual(TableCSV.rows(text).rows, Array(repeating: ["", "", ""], count: 4),
                       "a blank three-by-four table on disk", file: file, line: line)
        let sidecar = try XCTUnwrap(try ResearchTableSidecar.read(forItem: item.id, in: store.url),
                                    file: file, line: line)
        XCTAssertEqual(sidecar.headerRows, 1, file: file, line: line)
        XCTAssertEqual(sidecar.contentHash, ContentHash.of(Data(text.utf8)),
                       "the sidecar is for these bytes", file: file, line: line)

        XCTAssertEqual(subject.value, .research(item.id), "selected", file: file, line: line)
        XCTAssertEqual(state.pendingRenameId, item.id, "in rename, as a new note is", file: file, line: line)
        guard case .table(let routed, _) = ProjectWindow.researchCentreRoute(
            id: item.id, in: store.manifest.research) else {
            return XCTFail("the centre opens it in the grid", file: file, line: line)
        }
        XCTAssertEqual(routed.id, item.id, file: file, line: line)

        let documentStore = try XCTUnwrap(store.documentStore, file: file, line: line)
        let host = try await documentStore.openResearchTable(itemId: item.id)
        XCTAssertEqual(host.state.table.rows.count, 4, file: file, line: line)
        XCTAssertEqual(host.state.table.columns.count, 3, file: file, line: line)
        XCTAssertEqual(host.state.table.headerRows, 1, "one header row", file: file, line: line)
        XCTAssertTrue(host.state.table.cells.isEmpty, "empty", file: file, line: line)
        await documentStore.releaseResearchTable(host)
    }

    private func newItem(in store: ProjectStore, besides before: Set<String>) throws -> ResearchItem {
        let made = TreeWalk.collect(in: store.manifest.research) { !before.contains($0.id) }
        XCTAssertEqual(made.count, 1, "one item made")
        return try XCTUnwrap(made.first)
    }

    private func ids(_ store: ProjectStore) -> Set<String> {
        Set(TreeWalk.collect(in: store.manifest.research) { _ in true }.map(\.id))
    }

    // MARK: - The section header

    /// The Research header's New Table makes "Untitled Table" in shared
    /// Research, selected, in rename and open in the grid; again, "Untitled
    /// Table 2" in a file of its own.
    func test_theHeadersNewTableMakesABlankTableThenADeduplicatedOne() async throws {
        let store = try await novel()
        let state = BinderTreeSectionsState(), subject = Subject()
        let newTable = try XCTUnwrap(verbs(store, state, subject).bundle.newTable, "offered")

        var before = ids(store)
        await newTable(nil).value
        XCTAssertNil(state.pendingError)
        let first = try newItem(in: store, besides: before)
        XCTAssertEqual(first.title, "Untitled Table")
        XCTAssertNil(store.researchHomePiece(ofItemId: first.id), "shared Research")
        XCTAssertTrue(store.manifest.research.contains { $0.id == first.id }, "at the root")
        try await assertBlankTableOpened(first, in: store, state: state, subject: subject)

        before = ids(store)
        await newTable(nil).value
        let second = try newItem(in: store, besides: before)
        XCTAssertEqual(second.title, "Untitled Table 2")
        XCTAssertNotEqual(second.path, first.path, "a file of its own")
        try await assertBlankTableOpened(second, in: store, state: state, subject: subject)
    }

    // MARK: - A group's and a row's context menu

    /// A group's New Table makes the table inside the group; a row's makes it
    /// beside the row (its parent group), as New Note does. A table in
    /// another group still takes the next free name, so a `research:` name
    /// never names two tables.
    func test_aGroupsAndARowsNewTableLandInThatGroup() async throws {
        let store = try await novel()
        let state = BinderTreeSectionsState(), subject = Subject()
        let world = try await store.addResearchItem(parentId: nil, title: "World", kind: nil)
        let newTable = try XCTUnwrap(verbs(store, state, subject).bundle.newTable)

        await newTable(world.id).value
        XCTAssertNil(state.pendingError)
        var group = try XCTUnwrap(TreeWalk.find(id: world.id, in: store.manifest.research))
        let inGroup = try XCTUnwrap(group.children?.first)
        XCTAssertEqual(inGroup.title, "Untitled Table")
        XCTAssertTrue(inGroup.path?.hasPrefix((group.path ?? "") + "/") == true, inGroup.path ?? "")
        try await assertBlankTableOpened(inGroup, in: store, state: state, subject: subject)

        // A row inside the group: the menu passes the row's parent.
        let parent = verbs(store, state, subject).findParentId(of: inGroup.id)
        XCTAssertEqual(parent, world.id)
        await newTable(parent).value
        group = try XCTUnwrap(TreeWalk.find(id: world.id, in: store.manifest.research))
        XCTAssertEqual(group.children?.map(\.title), ["Untitled Table", "Untitled Table 2"])

        // At the root, the name is still the next free one.
        let before = ids(store)
        await newTable(nil).value
        XCTAssertEqual(try newItem(in: store, besides: before).title, "Untitled Table 3")
    }

    // MARK: - A piece's Research

    /// From a Collection piece's fold, New Table lands in that piece's own
    /// research folder; from a novel chapter's fold, in shared Research,
    /// linked to the chapter — where New Note lands from each.
    func test_aFoldsNewTableLandsInThatPiecesResearch() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        let state = BinderTreeSectionsState(), subject = Subject()
        let newTable = try XCTUnwrap(fold(for: piece.id, store, state, subject).actions.newTable)

        let before = ids(store)
        await newTable(nil).value
        XCTAssertNil(state.pendingError)
        let made = try newItem(in: store, besides: before)
        XCTAssertEqual(made.title, "Untitled Table")
        XCTAssertEqual(store.researchHomePiece(ofItemId: made.id), piece.id, "the piece's own Research")
        try await assertBlankTableOpened(made, in: store, state: state, subject: subject)

        let book = try await novel()
        let chapter = try XCTUnwrap(book.manifest.structure.first { $0.type == .document })
        let chapterState = BinderTreeSectionsState(), chapterSubject = Subject()
        let chapterNewTable = try XCTUnwrap(
            fold(for: chapter.id, book, chapterState, chapterSubject).actions.newTable)
        let earlier = ids(book)
        await chapterNewTable(nil).value
        let linked = try newItem(in: book, besides: earlier)
        let links = TreeWalk.find(id: chapter.id, in: book.manifest.structure)?.linkedResearchIds ?? []
        XCTAssertTrue(links.contains(linked.id), "linked to the chapter it was made from")
        try await assertBlankTableOpened(linked, in: book, state: chapterState, subject: chapterSubject)
    }

    // MARK: - Where it is not offered

    /// A view-only share and Review offer no New Table — not in the header,
    /// a row's menu or a fold — and the window's rule is the research
    /// centre's own.
    func test_aViewOnlyShareAndReviewOfferNoNewTable() async throws {
        XCTAssertTrue(BinderTreeSectionsState.offersNewTable(shareIsReadOnly: false, persona: .author))
        XCTAssertTrue(BinderTreeSectionsState.offersNewTable(shareIsReadOnly: false, persona: .plan))
        XCTAssertFalse(BinderTreeSectionsState.offersNewTable(shareIsReadOnly: true, persona: .author),
                       "a view-only share")
        XCTAssertFalse(BinderTreeSectionsState.offersNewTable(shareIsReadOnly: false, persona: .review),
                       "Review")

        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        let state = BinderTreeSectionsState(), subject = Subject()
        state.offersNewTable = false
        XCTAssertNil(verbs(store, state, subject).bundle.newTable, "the header's and every row's")
        XCTAssertNil(fold(for: piece.id, store, state, subject).actions.newTable, "a piece's fold")
        state.offersNewTable = true
        XCTAssertNotNil(verbs(store, state, subject).bundle.newTable, "control")
    }

    /// Both menus offer the item only when the bundle carries it — the header
    /// and the row menu build it from `actions.newTable`, never on their own.
    func test_bothMenusOfferNewTableOnlyThroughTheBundle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Maugham/Views/BinderTreeSections.swift", "Maugham/Views/ResearchTree.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertEqual(text.components(separatedBy: "Button(\"New Table\")").count - 1, 1, file)
            XCTAssertTrue(text.contains("if let newTable = actions.newTable {"), file)
        }
    }

    // MARK: - A refused write is said

    /// A table that cannot be written — here Research's folder is a file —
    /// is said in the tree's alert; nothing is made and nothing selected.
    func test_aWriteThatFailsIsSaidAndMakesNothing() async throws {
        let store = try await novel()
        let research = store.url.appendingPathComponent("research")
        try? FileManager.default.removeItem(at: research)
        try Data("not a folder".utf8).write(to: research)
        let state = BinderTreeSectionsState(), subject = Subject()
        let newTable = try XCTUnwrap(verbs(store, state, subject).bundle.newTable)

        await newTable(nil).value

        XCTAssertNotNil(state.pendingError, "the refusal is said")
        XCTAssertNil(subject.value, "nothing selected")
        XCTAssertNil(state.pendingRenameId)
        XCTAssertTrue(TreeWalk.collect(in: store.manifest.research) { $0.kind == .table }.isEmpty)
    }

    /// A file already at the new table's path (a name the folder listing
    /// missed) is never written over: the coordinated copy refuses it.
    func test_aFileAlreadyThereIsNeverOverwritten() async throws {
        let store = try await novel()
        let documentStore = try XCTUnwrap(store.documentStore)
        let source = TestTemp.root.appendingPathComponent("src-\(UUID().uuidString).csv")
        try Data("new".utf8).write(to: source)
        let target = store.url.appendingPathComponent("research/kept.csv")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: target)
        do {
            try await documentStore.executeCopy(from: source, to: target)
            XCTFail("an existing file was written over")
        } catch {}
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "kept")
    }
}

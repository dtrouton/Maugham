import XCTest
@testable import Maugham
@testable import MaughamCore

/// **The table door writes only inside a research root** (note versions plan
/// 2, fix wave 2 D). A synced manifest (stale, corrupt, or another Mac's:
/// tripwire 58's untrusted input) can list a `.table` Research item whose
/// path is the manuscript or a `.maugham/` file; `SafeRelativePath` confines
/// it to the project, not to research. `ResearchTextRole.tablePath` is the
/// one question: the grid does not open such a table (the centre shows the
/// preview), a grid already open does not write it when the manifest moves
/// under it, and a version Restore is refused — the file untouched, no
/// version kept. A piece's own research folder is still a root. No control is
/// pressed (tripwire 33).
@MainActor
final class ResearchTableOutsideResearchTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("tableoutside-\(UUID().uuidString)")
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
        for observer in noticeObservers { NotificationCenter.default.removeObserver(observer) }
        noticeObservers = []
        for store in stores { await store.close() }
        stores = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        try "Words.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        stores.append(store)
        let doc = try await Document.load(
            url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func csv(_ text: String) throws -> URL {
        let folder = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("model.csv")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// The two out-of-root paths every test plants: the manuscript's own file
    /// (made by `openBook`) and one under `.maugham/`.
    private let strayPaths = ["manuscript/a.md", ".maugham/ops/stray.csv"]

    private func plantStray(_ path: String) throws {
        let url = file(path)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("Item,Amount\nRent,10\n".utf8).write(to: url)
    }

    private func versions(of itemId: String, in project: URL? = nil) -> [ResearchVersion] {
        ResearchVersionStore(projectURL: project ?? projectURL).versions(itemId: itemId)
    }

    private func keepByHand(_ text: String, of itemId: String) throws -> ResearchVersion {
        try ResearchVersionStore(projectURL: projectURL).keep(
            priorBytes: Data(text.utf8), priorSidecar: nil, writtenBy: nil,
            itemId: itemId, device: DeviceIdentity.author.slug,
            at: Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    private final class Heard: @unchecked Sendable { var notices: [String] = [] }   // touched on the main actor only
    private var noticeObservers: [NSObjectProtocol] = []

    private func listen() -> Heard {
        let heard = Heard()
        noticeObservers.append(NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let message = note.userInfo?[MaughamEvent.noticeMessageKey] as? String {
                MainActor.assumeIsolated { heard.notices.append(message) }
            }
        })
        return heard
    }

    // MARK: - Not opened, not routed to the grid, not restored

    /// A `.table` item outside a research root is not opened in the grid
    /// (the host refuses to load it), the centre column routes it to the
    /// preview, and a Restore is refused: the file is as it was and the only
    /// version is the one kept by hand.
    func test_aTableOutsideAResearchRootIsNotOpenedRoutedOrRestored() async throws {
        let (store, projectStore) = try await openBook()
        for (n, path) in strayPaths.enumerated() {
            try plantStray(path)
            let item = ResearchItem(id: "res-stray00\(n)", title: "Stray \(n)", type: .asset,
                                    kind: .table, path: path)
            projectStore.manifest.research.append(item)
            let before = try Data(contentsOf: file(path))

            XCTAssertNil(ResearchTextRole.tablePath(of: item, structure: projectStore.manifest.structure), path)
            do {
                _ = try await store.openResearchTable(itemId: item.id)
                XCTFail("\(path): the grid must not open it")
            } catch is ResearchTableHost.Unreadable {}
            guard case .preview = ProjectWindow.researchCentreRoute(id: item.id, in: projectStore.manifest) else {
                return XCTFail("\(path): routed to the preview, not the grid")
            }

            let kept = try keepByHand("Item,Amount\nRent,99\n", of: item.id)
            do {
                try await store.restoreResearchTable(itemId: item.id, to: kept, shareIsReadOnly: false)
                XCTFail("\(path): the restore must be refused")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: file(path)), before, "\(path) is untouched")
            XCTAssertEqual(versions(of: item.id).count, 1, "\(path): no version kept")
        }
    }

    // MARK: - A grid already open when the manifest moves under it

    /// A grid opened on a real table, whose item a synced manifest then points
    /// at the manuscript or a `.maugham/` file: the writer's edit and a
    /// Restore are both refused at the door. Nothing is written there, no
    /// version is kept, and the edit's refusal is said.
    func test_anOpenGridWhoseItemMovesOutsideResearchWritesNothing() async throws {
        let (store, projectStore) = try await openBook()
        for path in strayPaths {
            try plantStray(path)
            let item = try await projectStore.addResearchAsset(parentId: nil, fromURL: try csv("Year,Revenue\n2025,10\n"))
            let host = try await store.openResearchTable(itemId: item.id)
            projectStore.mutateResearchItem(id: item.id) { $0.path = path }
            let before = try Data(contentsOf: file(path))
            let heard = listen()

            let table = host.state.table
            try await host.setCell(Cell(content: .value(.number(20))),
                                   at: CellKey(row: table.rows[1], column: table.columns[1]), undoManager: nil)
            await host.flush()
            XCTAssertEqual(try Data(contentsOf: file(path)), before, "\(path): the edit wrote nothing")
            XCTAssertTrue(versions(of: item.id).isEmpty, "\(path): no version kept")
            XCTAssertTrue(heard.notices.contains { $0.contains("isn’t a table inside Research") }, "\(heard.notices)")

            let kept = try keepByHand("Year,Revenue\n2025,99\n", of: item.id)
            do {
                try await host.restore(kept)
                XCTFail("\(path): the restore must be refused")
            } catch is ResearchTableHost.NotSaved {}
            XCTAssertEqual(try Data(contentsOf: file(path)), before, "\(path): the restore wrote nothing")
            XCTAssertEqual(versions(of: item.id).count, 1, "\(path): only the version kept by hand")
            await store.releaseResearchTable(host)
        }
    }

    // MARK: - The control: a piece's own research folder

    /// A piece's own Research (`pieces/<NN>-<slug>/research/…`) is a research
    /// root: its table opens, saves (keeping the version before) and restores.
    func test_aPieceScopedTableSavesAndRestores() async throws {
        let url = try await ProjectFactory.createCollectionProject(named: "Anthology", in: projectURL)
        let projectStore = try await ProjectStore.load(from: url)
        let piece = try await projectStore.addLoosePiece(title: "Story A", format: .markdown)
        let store = try await DocumentStore.open(url: url)
        stores.append(store)
        projectStore.documentStore = store
        store.projectStore = projectStore
        let item = try await projectStore.createResearchAsset(
            scope: .document(piece.id), fromURL: try csv("Year,Revenue\n2025,10\n"))
        let path = try XCTUnwrap(item.path)
        XCTAssertTrue(path.hasPrefix("pieces/") && path.contains("/research/") && item.kind == .table,
                      "premise: \(path)")
        XCTAssertEqual(ResearchTextRole.tablePath(of: item, structure: projectStore.manifest.structure), path)
        guard case .table = ProjectWindow.researchCentreRoute(id: item.id, in: projectStore.manifest) else {
            return XCTFail("a piece's table opens in the grid")
        }

        let host = try await store.openResearchTable(itemId: item.id)
        let table = host.state.table
        try await host.setCell(Cell(content: .value(.number(20))),
                               at: CellKey(row: table.rows[1], column: table.columns[1]), undoManager: nil)
        await host.flush()
        await store.releaseResearchTable(host)
        let rows = { TableCSV.rows(String(decoding: try Data(contentsOf: url.appendingPathComponent(path)),
                                          as: UTF8.self)).rows }
        XCTAssertEqual(try rows(), [["Year", "Revenue"], ["2025", "20"]])
        let kept = versions(of: item.id, in: url)
        XCTAssertEqual(kept.count, 1, "the save kept the table before it")

        try await store.restoreResearchTable(itemId: item.id, to: kept[0], shareIsReadOnly: false)
        XCTAssertEqual(try rows(), [["Year", "Revenue"], ["2025", "10"]], "the version is the file again")
    }
}

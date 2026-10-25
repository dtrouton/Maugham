import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **Use in document** (report plan 6b Task 6, spec §4.1, ruling P-4): a CSV
/// or TSV added to Research is a Research table, and *Use in document* turns
/// a Research table, picture or PDF into a figure that records where it came
/// from. A working copy of a parked figure is not made into a new figure: it
/// goes to Task 8's return.
@MainActor
final class UseInDocumentTests: XCTestCase {

    private var projectURL: URL!
    /// Held for the test's length: `ProjectStore.documentStore` is weak.
    private var documentStore: DocumentStore?

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("useindoc-\(UUID().uuidString)")
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
        documentStore = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// One chapter, bootstrapped, and a window over the book.
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
        let doc = try await Document.load(url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        documentStore = store
        return (store, projectStore)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    /// A file outside the book, the way a writer drags one into Research.
    private func external(_ name: String, _ data: Data) throws -> URL {
        let folder = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Figure `id`'s stream, read windowless.
    private func state(_ id: String) async throws -> FigureState {
        let doc = try await FigureDocument.load(
            figureId: id, projectURL: projectURL, actor: .author,
            session: "read", presenter: nil, documentStore: nil)
        let state = doc.state
        await doc.close()
        return state
    }

    private func rendered(_ record: FigureRecord) throws -> [[String]] {
        let text = try String(contentsOf: file(record.path), encoding: .utf8)  // adr-0018-ok: test reads the derived render to assert what was written
        return TableCSV.rows(text).rows
    }

    private let budgetCSV = """
        Item,Amount
        Rent,100
        Food,50
        Total,=SUM(B2:B3)
        Odd,=NOPE(1)
        Broken,=1+

        """

    // MARK: - Tables

    /// A CSV added to Research is a table; Use in document reads it into a new
    /// figure: `=SUM(B2:B3)` a formula (150), `=NOPE(1)` a formula showing
    /// `#NAME?`, `=1+` text holding itself and reported; the source recorded.
    func test_aResearchCSVBecomesATableFigure() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("budget.csv", Data(budgetCSV.utf8)))
        XCTAssertEqual(item.kind, .table, "a CSV added to Research is a Research table")
        let researchFile = file(try XCTUnwrap(item.path))

        let record = try await projectStore.useInDocument(researchItemId: item.id, piece: "doc-a")

        XCTAssertEqual(record.kind, .table)
        XCTAssertEqual(record.name, "budget", "named from the item's title")
        XCTAssertEqual(record.piece, "doc-a")
        XCTAssertEqual(projectStore.manifest.figures?.map(\.id), [record.id])

        let s = try await state(record.id)
        XCTAssertEqual(s.table.rows.count, 6)
        XCTAssertEqual(s.table.columns.count, 2)
        XCTAssertEqual(s.table.headerRows, 1, "a text first row over numbers is a header")
        let at = { (r: Int, c: Int) in s.table[CellKey(row: s.table.rows[r], column: s.table.columns[c])]?.content }
        guard case .formula? = at(3, 1) else { return XCTFail("=SUM(B2:B3) is a formula") }
        guard case .formula? = at(4, 1) else { return XCTFail("=NOPE(1) stays a formula") }
        XCTAssertEqual(at(5, 1), .value(.text("=1+")), "an unparseable formula is text holding its =…")
        XCTAssertEqual(projectStore.lastUseInDocumentProblems.map { [$0.row, $0.column] }, [[5, 1]],
                       "and it comes back as a problem")
        XCTAssertEqual(s.source, FigureSource(
            researchItemId: item.id, path: try XCTUnwrap(item.path),
            contentHash: try ContentHash.ofFile(researchFile)))

        await store.awaitOpenFigureRenderForTesting()
        let rows = try rendered(record)
        XCTAssertEqual(rows[3], ["Total", "150"])
        XCTAssertEqual(rows[4], ["Odd", "#NAME?"])
        XCTAssertEqual(rows[5], ["Broken", "=1+"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: researchFile.path),
                      "the Research copy stays where it was")
    }

    /// The name is the item's title, made vacant against the registry.
    func test_theNameIsDeDuplicatedAgainstTheRegistry() async throws {
        let (_, projectStore) = try await openBook()
        _ = try await projectStore.createFigure(kind: .table, name: "Budget", piece: nil)
        let item = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("budget.tsv", Data("a\tb\n1\t2\n".utf8)))
        XCTAssertEqual(item.kind, .table, "a TSV is a Research table too")
        let record = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)
        XCTAssertEqual(record.name, "budget_2")
        XCTAssertEqual(projectStore.lastUseInDocumentProblems, [])
        let s = try await state(record.id)
        XCTAssertEqual(s.table[CellKey(row: s.table.rows[1], column: s.table.columns[1])]?.content,
                       .value(.number(2)))
    }

    // MARK: - Pictures

    /// A picture in Research becomes an image figure through the image path,
    /// with its source's hash recorded on the create.
    func test_aPictureItemBecomesAnImageFigureWithItsSourceHash() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("Harbour Map.png", try TestImageBytes.png(seed: 3)))
        XCTAssertEqual(item.kind, .image)
        let researchFile = file(try XCTUnwrap(item.path))
        let hash = try ContentHash.ofFile(researchFile)

        let record = try await projectStore.useInDocument(researchItemId: item.id, piece: "doc-a")

        XCTAssertEqual(record.kind, .image)
        XCTAssertEqual(record.name, "harbour-map")
        XCTAssertEqual(record.path, "figures/harbour-map.png")
        let s = try await state(record.id)
        XCTAssertEqual(s.source, FigureSource(
            researchItemId: item.id, path: try XCTUnwrap(item.path), contentHash: hash))
        XCTAssertEqual(s.image?.contentHash, hash, "a PNG is copied as it is")
        XCTAssertEqual(projectStore.lastUseInDocumentProblems, [])
    }

    /// A note can't be a figure: refused, nothing made.
    func test_aNoteIsRefused() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("notes.md", Data("# Notes\n".utf8)))
        do {
            _ = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)
            XCTFail("a note is not a figure")
        } catch let refused as UseInDocumentRefused {
            XCTAssertEqual(refused.reason, .notAFigure("notes"))
        }
        XCTAssertEqual(projectStore.manifest.figures ?? [], [])
    }

    // MARK: - A parked figure's working copy (Task 8's seam)

    /// An item whose sidecar names a PARKED figure goes to `bringBack` — today
    /// `FigureReturnPending`, nothing made. A sidecar naming a figure that is
    /// not parked, or not in the book, is used as a fresh table. Task 8
    /// replaces the first half with the return itself.
    func test_aParkedFiguresWorkingCopyRoutesToTheReturn() async throws {
        let (store, projectStore) = try await openBook()
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let live = try await projectStore.createFigure(kind: .table, name: "live", piece: nil)
        let opStore = Document.makeLoadOpStore(projectURL: projectURL, presenter: nil)
        try await opStore.append(Op(
            opId: ULID.generate(), docId: cash.id, at: Date(),
            device: Document.loadIdentities[.author].deviceId, session: "park",
            kind: .figureParked, changes: [],
            figure: FigureOpPayload(parkedPath: "research/cash.csv", parkedHash: "0123456789abcdef")))
        _ = try await opStore.sealChain(docId: cash.id, actor: .author)
        store.figureCache.invalidate(figureId: cash.id)

        let copy = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("cash.csv", Data("1,2\n".utf8)))
        try ResearchTableSidecar.write(
            ResearchTableSidecar(figureId: cash.id, name: "cash"), forItem: copy.id, in: projectURL)
        do {
            _ = try await projectStore.useInDocument(researchItemId: copy.id, piece: nil)
            XCTFail("a parked figure's copy goes back to its own log")
        } catch let pending as FigureReturnPending {
            XCTAssertEqual(pending.researchItemId, copy.id)
        }
        XCTAssertEqual(projectStore.manifest.figures?.map(\.id), [cash.id, live.id], "nothing was made")

        // Not parked, or not in the book: a fresh figure.
        let other = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("other.csv", Data("3,4\n".utf8)))
        try ResearchTableSidecar.write(ResearchTableSidecar(figureId: live.id), forItem: other.id, in: projectURL)
        let fresh = try await projectStore.useInDocument(researchItemId: other.id, piece: nil)
        XCTAssertEqual(fresh.name, "other")
        let stray = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("stray.csv", Data("5\n".utf8)))
        try ResearchTableSidecar.write(
            ResearchTableSidecar(figureId: "fig-gone0001"), forItem: stray.id, in: projectURL)
        let fresh2 = try await projectStore.useInDocument(researchItemId: stray.id, piece: nil)
        XCTAssertEqual(fresh2.name, "stray")
    }
}

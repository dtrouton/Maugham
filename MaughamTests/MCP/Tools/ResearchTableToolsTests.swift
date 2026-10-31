import XCTest
@testable import MaughamCore
@testable import Maugham

/// Report plan 9d Tasks 4–5: the assistant writes, creates and reads Research
/// tables over MCP — through the table's one door (`ResearchTableHost.assistantEdit`),
/// so every write keeps a version and a figure pinning the table goes "changed".
@MainActor
final class ResearchTableToolsTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("researchtabletools-\(UUID().uuidString)")
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
        for store in stores { await store.close() }
        stores = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private struct Book {
        let ds: DocumentStore
        let store: ProjectStore
        let registry: ProjectRegistry
        let id: String
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func openBook() async throws -> Book {
        try "Opening.\n\n![Summary](../figures/summary.csv){#tbl:summary}\n"
            .write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "Chapter A", type: .document,
                                      path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let ds = try await DocumentStore.open(url: projectURL)
        stores.append(ds)
        let doc = try await Document.load(
            url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = ds
        ds.projectStore = store
        let registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        return Book(ds: ds, store: store, registry: registry, id: ProjectIdentifier.id(for: projectURL))
    }

    /// A Research table named `model` holding `body`.
    private func researchTable(_ book: Book, _ body: String) async throws -> ResearchItem {
        let outside = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let csv = outside.appendingPathComponent("model.csv")
        try Data(body.utf8).write(to: csv)
        let item = try await book.store.addResearchAsset(parentId: nil, fromURL: csv)
        XCTAssertEqual(item.kind, .table, "precondition: a Research table")
        return item
    }

    private func bytes(of item: ResearchItem) throws -> Data {
        try Data(contentsOf: file(try XCTUnwrap(item.path)))
    }

    private func rows(of item: ResearchItem) throws -> [[String]] {
        TableCSV.rows(String(decoding: try bytes(of: item), as: UTF8.self)).rows
    }

    private func versions(of item: ResearchItem) -> [ResearchVersion] {
        ResearchVersionStore(projectURL: projectURL).versions(itemId: item.id)
    }

    private func json(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @discardableResult
    private func write(_ book: Book, _ item: ResearchItem, _ rest: String) async throws -> WriteResearchCellsTool.Result {
        let data = try await WriteResearchCellsTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(book.id)\",\"item_id\":\"\(item.id)\",\(rest)}".utf8),
            registry: book.registry)
        return try JSONDecoder().decode(WriteResearchCellsTool.Result.self, from: data)
    }

    /// The `invalidArgument` message a call threw, or a failure.
    private func refusal(_ call: () async throws -> Void) async -> String {
        do {
            try await call()
            XCTFail("expected a refusal")
            return ""
        } catch MCPError.invalidArgument(let message) {
            return message
        } catch {
            XCTFail("expected invalidArgument, got \(error)")
            return ""
        }
    }

    // MARK: - write_research_cells

    /// Values, a formula and a format land; cells past the edge add a row and
    /// a column; header and total row are set. The CSV and its sidecar say so.
    func test_valuesFormulasAndFormatsLandAndTheTableGrowsPastItsEdge() async throws {
        let book = try await openBook()
        let item = try await researchTable(book, "Item,Amount\nRent,10\nFood,20\n")
        let money = CellFormat(number: .number(decimals: 2, grouping: true))

        let result = try await write(book, item, """
            "cells":[{"a1":"B2","value":"1500.5","format":\(try json(money))},\
            {"a1":"a4","value":"Total"},{"a1":"B4","value":"=SUM(B2:B3)"},{"a1":"C1","value":"Note"}],\
            "header_rows":1,"total_row":true
            """)

        XCTAssertEqual(result.rows, 4)
        XCTAssertEqual(result.columns, 3)
        XCTAssertEqual(result.rows_added, 1)
        XCTAssertEqual(result.columns_added, 1)
        XCTAssertEqual(result.cells_written, 4)
        XCTAssertEqual(try rows(of: item), [
            ["Item", "Amount", "Note"],
            ["Rent", "1500.5", ""],
            ["Food", "20", ""],
            ["Total", "=SUM(B2:B3)", ""],
        ])
        let sidecar = try XCTUnwrap(try ResearchTableSidecar.read(forItem: item.id, in: projectURL))
        XCTAssertEqual(sidecar.writtenBy, .assistant)
        XCTAssertEqual(sidecar.headerRows, 1)
        XCTAssertTrue(sidecar.totalRow)
        XCTAssertEqual(sidecar.formats.map { [$0.row, $0.column] }, [[1, 1]])
        XCTAssertEqual(sidecar.formats.first?.format, money)
    }

    /// Every write keeps the version before it; the write after an
    /// assistant's write keeps the assistant's bytes, marked as theirs.
    func test_eachWriteKeepsAVersionAndTheAssistantsBytesAreMarkedSo() async throws {
        let book = try await openBook()
        let item = try await researchTable(book, "Item,Amount\nRent,10\n")
        let original = try bytes(of: item)

        try await write(book, item, #""cells":[{"a1":"B2","value":"11"}]"#)
        var kept = versions(of: item)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try ResearchVersionStore(projectURL: projectURL).read(try XCTUnwrap(kept.first)).0, original,
                       "the version before the write holds the bytes it replaced")

        try await write(book, item, #""cells":[{"a1":"B2","value":"12"}]"#)
        kept = versions(of: item)
        XCTAssertEqual(kept.count, 2, "\(kept)")
        XCTAssertTrue(kept.contains { $0.writtenBy == .assistant },
                      "the second write keeps the assistant's first write, marked as the assistant's: \(kept)")
        XCTAssertEqual(try rows(of: item)[1], ["Rent", "12"])
    }

    /// A figure pinning the table goes "changed" after the write — nothing more.
    func test_aFigurePinnedToTheTableGoesChangedAfterAWrite() async throws {
        let book = try await openBook()
        let item = try await researchTable(book, "Year,Revenue\n2025,10\n2026,20\n")
        let record = try await book.store.createFigure(kind: .table, name: "summary", piece: nil)
        let host = try await book.ds.openFigure(figureId: record.id)
        let a1 = CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
        let names = FormulaNames(research: [(item.id, item.title)])
        guard case .success(let f) = FormulaParser.parse("research:model!B2*2", in: host.state.table, names: names)
        else { return XCTFail("the formula did not parse") }
        try await host.setCell(Cell(content: .formula(f)), at: a1)
        await book.ds.awaitOpenFigureRenderForTesting()
        await book.ds.closeFigure(figureId: record.id)

        func listed() async throws -> ListFiguresTool.Figure? {
            let data = try await ListFiguresTool.handle(
                paramsJSON: Data("{\"project_id\":\"\(book.id)\"}".utf8), registry: book.registry)
            return try JSONDecoder().decode(ListFiguresTool.Result.self, from: data).figures
                .first { $0.id == record.id }
        }
        let before = try await listed()
        XCTAssertEqual(before?.changed, false, "precondition: the pin is current")

        try await write(book, item, #""cells":[{"a1":"B2","value":"99"}]"#)

        let after = try await listed()
        XCTAssertEqual(after?.pins.map(\.status), ["source_changed"])
        XCTAssertEqual(after?.changed, true)
    }

    /// A grid open on the table shares the host: it shows the write at once.
    func test_anOpenGridsHostShowsTheWrite() async throws {
        let book = try await openBook()
        let item = try await researchTable(book, "Item,Amount\nRent,10\n")
        let grid = try await book.ds.openResearchTable(itemId: item.id)

        try await write(book, item, #""cells":[{"a1":"B3","value":"7"}]"#)

        XCTAssertEqual(grid.state.table.rows.count, 3, "the grid's host grew")
        let b3 = CellKey(row: grid.state.table.rows[2], column: grid.state.table.columns[1])
        XCTAssertEqual(grid.state.table[b3]?.content, .value(.number(7)))
        XCTAssertFalse(grid.isClosed, "the tool let go of its use only")
        await book.ds.releaseResearchTable(grid)
    }

    /// Unknown item, an item that is not a table, a value that does not read
    /// and an address that is not one: refused, and nothing written or kept.
    func test_refusalsWriteNothing() async throws {
        let book = try await openBook()
        let item = try await researchTable(book, "Item,Amount\nRent,10\n")
        let note = try await book.store.addResearchTextNote(parentId: nil, title: "A note")
        let original = try bytes(of: item)

        var message = await refusal {
            let data = Data("{\"project_id\":\"\(book.id)\",\"item_id\":\"res-nope\",\"cells\":[{\"a1\":\"A1\",\"value\":\"1\"}]}".utf8)
            _ = try await WriteResearchCellsTool.handle(paramsJSON: data, registry: book.registry)
        }
        XCTAssertTrue(message.contains("res-nope"), message)
        message = await refusal { try await self.write(book, note, #""cells":[{"a1":"A1","value":"1"}]"#) }
        XCTAssertTrue(message.contains("not a Research table"), message)
        message = await refusal { try await self.write(book, item, #""cells":[{"a1":"B2","value":"1,500"}]"#) }
        XCTAssertTrue(message.contains("B2") && message.contains("'.'"), message)
        message = await refusal { try await self.write(book, item, #""cells":[{"a1":"B2","value":"=SUM(B2"}]"#) }
        XCTAssertTrue(message.contains("does not read"), message)
        for bad in ["B", "3B", "B2:C3", "A0"] {
            message = await refusal { try await self.write(book, item, "\"cells\":[{\"a1\":\"\(bad)\",\"value\":\"1\"}]") }
            XCTAssertTrue(message.contains("not an A1 cell address"), "\(bad): \(message)")
        }
        message = await refusal {
            try await self.write(book, item, #""cells":[{"a1":"A1","value":"x"},{"a1":"C9","value":"=SUM("}]"#)
        }
        XCTAssertTrue(message.contains("C9"), "one bad cell refuses the whole call: \(message)")
        message = await refusal { try await self.write(book, item, #""cells":[{"a1":"A1","format":{"number":7}}]"#) }
        XCTAssertTrue(message.contains("format"), message)

        XCTAssertEqual(try bytes(of: item), original, "nothing was written")
        XCTAssertTrue(versions(of: item).isEmpty, "nothing was kept")
    }
}

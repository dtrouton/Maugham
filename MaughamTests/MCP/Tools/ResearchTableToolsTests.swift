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
        MCPShareLock.readerForTesting = nil
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
        XCTAssertEqual(kept.first?.replacedBy, .assistant, "marked as the state before the assistant's change")

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
    /// **A table outside a research root takes no cells** (wave 2 D): a
    /// synced manifest can list a `.table` Research item whose path is the
    /// manuscript or Maugham's own files. `write_research_cells` refuses it
    /// before a host is opened: the file is as it was and no version is kept.
    func test_aTableOutsideAResearchRootIsRefused_andNothingIsWritten() async throws {
        let book = try await openBook()
        for (n, path) in ["manuscript/a.md", ".maugham/ops/stray.csv"].enumerated() {
            let url = file(path)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("Item,Amount\nRent,10\n".utf8).write(to: url)
            }
            let item = ResearchItem(id: "res-stray00\(n)", title: "Stray \(n)", type: .asset,
                                    kind: .table, path: path)
            book.store.manifest.research.append(item)
            let before = try Data(contentsOf: url)
            let message = await refusal { try await self.write(book, item, #""cells":[{"a1":"A1","value":"1"}]"#) }
            XCTAssertTrue(message.contains("not a Research table inside Research"), message)
            XCTAssertEqual(try Data(contentsOf: url), before, "\(path) is untouched")
            XCTAssertTrue(versions(of: item).isEmpty, "\(path): no version kept")
            XCTAssertNil(book.ds.researchTables[item.id], "\(path): no host was opened")
        }
    }

    /// The control: a piece's own Research (`pieces/<NN>-<slug>/research/…`)
    /// is a research root, and its table takes cells.
    func test_aPieceScopedTableTakesCells() async throws {
        let url = try await ProjectFactory.createCollectionProject(named: "Anthology", in: projectURL)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", format: .markdown)
        let ds = try await DocumentStore.open(url: url)
        stores.append(ds)
        store.documentStore = ds
        ds.projectStore = store
        let registry = ProjectRegistry()
        registry.register(url: url, store: store)
        let book = Book(ds: ds, store: store, registry: registry, id: ProjectIdentifier.id(for: url))
        let csv = TestTemp.root.appendingPathComponent("piece-\(UUID().uuidString).csv")
        try Data("Item,Amount\nRent,10\n".utf8).write(to: csv)
        let item = try await store.createResearchAsset(scope: .document(piece.id), fromURL: csv)
        let path = try XCTUnwrap(item.path)
        XCTAssertTrue(path.hasPrefix("pieces/") && path.contains("/research/") && item.kind == .table,
                      "premise: \(path)")

        try await write(book, item, #""cells":[{"a1":"B2","value":"12"}]"#)
        XCTAssertEqual(TableCSV.rows(String(decoding: try Data(contentsOf: url.appendingPathComponent(path)),
                                            as: UTF8.self)).rows,
                       [["Item", "Amount"], ["Rent", "12"]])
        XCTAssertEqual(ResearchVersionStore(projectURL: url).versions(itemId: item.id).count, 1,
                       "the write kept the version before it")
    }

    // MARK: - create_research_table / read_research_table

    private func create(_ book: Book, _ rest: String) async throws -> CreateResearchTableTool.Result {
        let data = try await CreateResearchTableTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(book.id)\",\(rest)}".utf8), registry: book.registry)
        return try JSONDecoder().decode(CreateResearchTableTool.Result.self, from: data)
    }

    private func readJSON(_ book: Book, _ itemId: String, range: String? = nil) async throws -> [String: Any] {
        let rangePart = range.map { ",\"range\":\"\($0)\"" } ?? ""
        let data = try await ReadResearchTableTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(book.id)\",\"item_id\":\"\(itemId)\"\(rangePart)}".utf8),
            registry: book.registry)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func cell(_ read: [String: Any], _ a1: String) throws -> [String: Any] {
        let cells = try XCTUnwrap(read["cells"] as? [[String: Any]])
        return try XCTUnwrap(cells.first { $0["a1"] as? String == a1 }, "no \(a1)")
    }

    /// Created with cells (no blank first version), read back with the
    /// formula computed and the format shown, in read_figure's cell shapes.
    func test_createThenReadRoundTripsWithAComputedFormula() async throws {
        let book = try await openBook()
        let money = CellFormat(number: .number(decimals: 2, grouping: true))
        let made = try await create(book, """
            "title":"Budget","cells":[{"a1":"A1","value":"Item"},{"a1":"B1","value":"Amount"},\
            {"a1":"A2","value":"Rent"},{"a1":"B2","value":"1234.5","format":\(try json(money))},\
            {"a1":"A3","value":"Food"},{"a1":"B3","value":"100"},\
            {"a1":"A4","value":"Total"},{"a1":"B4","value":"=SUM(B2:B3)"}]
            """)
        XCTAssertEqual(made.title, "Budget")
        XCTAssertEqual(made.rows, 4)
        XCTAssertEqual(made.columns, 2)
        let item = try XCTUnwrap(book.store.findResearchItem(id: made.item_id, in: book.store.manifest.research))
        XCTAssertEqual(item.kind, .table)
        XCTAssertEqual(try rows(of: item), [["Item", "Amount"], ["Rent", "1234.5"], ["Food", "100"],
                                            ["Total", "=SUM(B2:B3)"]])
        XCTAssertTrue(versions(of: item).isEmpty, "made with its content: no blank first version")
        XCTAssertEqual(try ResearchTableSidecar.read(forItem: item.id, in: projectURL)?.writtenBy, .assistant)

        let read = try await readJSON(book, item.id)
        XCTAssertEqual(read["name"] as? String, "Budget")
        XCTAssertEqual(read["rows"] as? Int, 4)
        XCTAssertEqual(read["header_rows"] as? Int, 1)
        XCTAssertEqual(read["range"] as? String, "all")
        XCTAssertTrue(read["note"] is NSNull, "note is a fact: null, never absent")
        XCTAssertEqual(read["research_reads"] as? [String], [])
        let b4 = try cell(read, "B4")
        XCTAssertEqual(b4["formula"] as? String, "=SUM(B2:B3)")
        XCTAssertEqual((b4["raw"] as? [String: Any])?["type"] as? String, "number")
        XCTAssertEqual((b4["raw"] as? [String: Any])?["value"] as? Double, 1334.5)
        XCTAssertEqual(try cell(read, "B2")["value"] as? String, "1,234.50")
        let text = try XCTUnwrap(read["text"] as? String)
        XCTAssertTrue(text.contains("1,234.50") && text.contains("| A "), text)

        // The cells decode as read_figure's own shape.
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(read["cells"]))
        let typed = try JSONDecoder().decode([ReadFigureTool.Cell].self, from: data)
        XCTAssertEqual(typed.first { $0.a1 == "B2" }?.format, money)

        // The first write keeps the created table, marked as the assistant's.
        try await write(book, item, #""cells":[{"a1":"B3","value":"200"}]"#)
        XCTAssertEqual(versions(of: item).map(\.writtenBy), [.assistant])
        let after = try await readJSON(book, item.id)
        XCTAssertEqual((try cell(after, "B4")["raw"] as? [String: Any])?["value"] as? Double, 1434.5)
    }

    /// Plan Review Focus 5: a formula written past the edge grows the table
    /// and computes in read_research_table.
    func test_aSumWrittenPastTheEdgeComputes() async throws {
        let book = try await openBook()
        let item = try await researchTable(book, "Item,Amount\nRent,10\nFood,20\n")
        try await write(book, item, #""cells":[{"a1":"B4","value":"=SUM(B2:B3)"}]"#)
        let read = try await readJSON(book, item.id)
        XCTAssertEqual(read["rows"] as? Int, 4)
        XCTAssertEqual((try cell(read, "B4")["raw"] as? [String: Any])?["value"] as? Double, 30)
    }

    /// No cells: New Table's blank shape; an unknown scope is refused.
    func test_createWithNoCellsIsTheBlankTableAndAScopeMustBeADocument() async throws {
        let book = try await openBook()
        let made = try await create(book, #""title":"Blank","scope":"doc-a""#)
        XCTAssertEqual([made.rows, made.columns], [4, 3])
        let message = await refusal { _ = try await self.create(book, #""title":"X","scope":"doc-nope""#) }
        XCTAssertTrue(message.contains("doc-nope"), message)
    }

    /// `range` limits the cells; one outside the table is a clear error.
    func test_rangeLimitsTheCells() async throws {
        let book = try await openBook()
        let item = try await researchTable(book, "Item,Amount\nRent,10\nFood,20\n")
        let part = try await readJSON(book, item.id, range: "B3:A2")
        XCTAssertEqual(part["range"] as? String, "A2:B3")
        XCTAssertEqual((part["cells"] as? [[String: Any]])?.compactMap { $0["a1"] as? String }, ["A2", "B2", "A3", "B3"])
        let message = await refusal { _ = try await self.readJSON(book, item.id, range: "A1:Z99") }
        XCTAssertTrue(message.contains("range"), message)
    }

    /// A `research:` reference inside a Research table computes only through
    /// pins, which it has none of: the read names the cell and says so.
    func test_aResearchReferenceSaysItComputesOnlyThroughPins() async throws {
        let book = try await openBook()
        let model = try await researchTable(book, "Year,Revenue\n2025,10\n")
        let made = try await create(book, """
            "title":"Reader","cells":[{"a1":"A1","value":"From model"},{"a1":"B2","value":"=research:\(model.title)!B2*2"}]
            """)
        let read = try await readJSON(book, made.item_id)
        XCTAssertEqual(read["research_reads"] as? [String], ["B2"])
        let note = try XCTUnwrap(read["note"] as? String)
        XCTAssertTrue(note.contains("B2") && note.contains("pins"), note)
        let raw = try XCTUnwrap(try cell(read, "B2")["raw"] as? [String: Any])
        XCTAssertNotEqual(raw["value"] as? Double, 20, "it does not compute live: \(raw)")
    }

    /// Read refuses an unknown item and an item that is not a table.
    func test_readRefusesAnUnknownItemAndANote() async throws {
        let book = try await openBook()
        let note = try await book.store.addResearchTextNote(parentId: nil, title: "A note")
        var message = await refusal { _ = try await self.readJSON(book, "res-nope") }
        XCTAssertTrue(message.contains("res-nope"), message)
        message = await refusal { _ = try await self.readJSON(book, note.id) }
        XCTAssertTrue(message.contains("not a Research table"), message)
    }

    // MARK: - Fix round 1

    private struct FakeShare: ShareMetadataReading {
        let canWrite: Bool?
        func read(for url: URL) -> ShareMetadata? {
            ShareMetadata(isShared: true, isOwner: false, canWrite: canWrite, ownerName: "Sam", currentUserName: "Ana")
        }
    }

    /// I1 — a read-only share refuses both table writers and add_note with
    /// no grid mounted; the read still answers; a writable share writes.
    func test_aViewOnlyShareRefusesEveryResearchWriteWithNoGridOpen() async throws {
        let book = try await openBook()
        let item = try await researchTable(book, "Item,Amount\nRent,10\n")
        let original = try bytes(of: item)
        let researchBefore = book.store.manifest.research.count
        MCPShareLock.readerForTesting = FakeShare(canWrite: false)
        let sentence = FigureGridGate.Reason.viewOnlyShare.sentence

        var message = await refusal { try await self.write(book, item, #""cells":[{"a1":"B2","value":"11"}]"#) }
        XCTAssertEqual(message, sentence)
        message = await refusal { _ = try await self.create(book, #""title":"New""#) }
        XCTAssertEqual(message, sentence)
        message = await refusal {
            _ = try await AddNoteTool.handle(
                paramsJSON: Data("{\"project_id\":\"\(book.id)\",\"title\":\"N\",\"body\":\"B\"}".utf8),
                registry: book.registry)
        }
        XCTAssertTrue(message.contains("view-only"), message)
        XCTAssertEqual(try bytes(of: item), original)
        XCTAssertTrue(versions(of: item).isEmpty)
        XCTAssertEqual(book.store.manifest.research.count, researchBefore, "nothing was created")

        let read = try await readJSON(book, item.id)
        XCTAssertEqual(read["rows"] as? Int, 2, "reading is not writing")

        MCPShareLock.readerForTesting = FakeShare(canWrite: true)
        try await write(book, item, #""cells":[{"a1":"B2","value":"11"}]"#)
        XCTAssertEqual(try rows(of: item)[1], ["Rent", "11"])
    }

    /// I2 — growing below a total row is refused unless the call sets the
    /// total row itself.
    func test_growingBelowATotalRowIsRefusedUnlessTheCallSetsTheTotalRow() async throws {
        let book = try await openBook()
        let item = try await researchTable(book, "Item,Amount\nRent,10\nTotal,10\n")
        try await write(book, item, #""total_row":true"#)
        let original = try bytes(of: item)

        let message = await refusal { try await self.write(book, item, #""cells":[{"a1":"A4","value":"Food"}]"#) }
        XCTAssertTrue(message.contains("total row") && message.contains("total_row: false"), message)
        XCTAssertEqual(try bytes(of: item), original, "nothing written")

        // Writing inside the table is fine.
        try await write(book, item, #""cells":[{"a1":"B2","value":"12"}]"#)
        // The ruling's route: total_row false, write below, total_row true again.
        try await write(book, item, #""cells":[{"a1":"A4","value":"Food"}],"total_row":false"#)
        let result = try await write(book, item, #""cells":[{"a1":"A5","value":"Total"},{"a1":"B5","value":"=SUM(B2:B4)"}],"total_row":true"#)
        XCTAssertEqual(result.rows, 5)
        XCTAssertEqual(try ResearchTableSidecar.read(forItem: item.id, in: projectURL)?.totalRow, true)
    }

    /// Minor — rows_added counts the assistant's rows only, measured after the
    /// writer's pending edits land.
    func test_rowsAddedIsMeasuredAfterTheWritersPendingEdits() async throws {
        let book = try await openBook()
        let item = try await researchTable(book, "Item,Amount\nRent,10\n")
        let grid = try await book.ds.openResearchTable(itemId: item.id)
        grid.saveDelay = .seconds(600)
        _ = try await grid.insertRow(after: grid.state.table.rows.last, undoManager: nil)   // pending

        let result = try await write(book, item, #""cells":[{"a1":"B2","value":"11"}]"#)
        XCTAssertEqual(result.rows, 3)
        XCTAssertEqual(result.rows_added, 0, "the writer's row is not the assistant's")
        await book.ds.releaseResearchTable(grid)
    }

    /// Minor — a cell that makes nothing does not grow the table.
    func test_aCellThatMakesNothingDoesNotGrowTheTable() async throws {
        let book = try await openBook()
        let item = try await researchTable(book, "Item,Amount\nRent,10\n")
        let result = try await write(book, item, """
            "cells":[{"a1":"B2","value":"11"},{"a1":"Z99","value":""},{"a1":"E9","format":\(try json(CellFormat()))}]
            """)
        XCTAssertEqual([result.rows, result.columns, result.rows_added, result.columns_added], [2, 2, 0, 0])
    }

    /// Minor — a document-scoped create in a novel goes to shared Research
    /// and links the table to the chapter.
    func test_aDocumentScopedCreateLinksTheTableToTheChapter() async throws {
        let book = try await openBook()
        let made = try await create(book, #""title":"Chapter data","scope":"doc-a","cells":[{"a1":"A1","value":"x"}]"#)
        let chapter = try XCTUnwrap(book.store.manifest.structure.first { $0.id == "doc-a" })
        XCTAssertEqual(chapter.linkedResearchIds ?? [], [made.item_id])
        XCTAssertNotNil(book.store.manifest.research.first { $0.id == made.item_id }, "in shared Research")
    }

    /// Minor — two writes at once queue through the one host: both land, each
    /// keeps its version.
    func test_twoConcurrentWritesQueue() async throws {
        let book = try await openBook()
        let item = try await researchTable(book, "Item,Amount\nRent,10\nFood,20\n")
        async let first = write(book, item, #""cells":[{"a1":"B2","value":"11"}]"#)
        async let second = write(book, item, #""cells":[{"a1":"B3","value":"21"}]"#)
        _ = try await (first, second)
        XCTAssertEqual(try rows(of: item), [["Item", "Amount"], ["Rent", "11"], ["Food", "21"]])
        XCTAssertEqual(versions(of: item).count, 2)
    }
}

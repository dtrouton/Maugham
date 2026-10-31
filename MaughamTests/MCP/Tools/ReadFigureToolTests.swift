import XCTest
import AppKit
@testable import MaughamCore
@testable import Maugham

/// Report plan 9b Task 8: `read_figure`, the read-only figure reader.
@MainActor
final class ReadFigureToolTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("readfigure-\(UUID().uuidString)")
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

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private struct Book {
        let ds: DocumentStore
        let store: ProjectStore
        let registry: ProjectRegistry
        let id: String
    }

    private func openBook() async throws -> Book {
        try "Opening.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "Chapter A", type: .document,
                                      path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let ds = try await DocumentStore.open(url: projectURL)
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

    private func params(_ book: Book, _ rest: String) -> Data {
        Data("{\"project_id\":\"\(book.id)\",\(rest)}".utf8)
    }

    private func read(_ book: Book, _ rest: String) async throws -> ReadFigureTool.TableResult {
        let json = try await ReadFigureTool.handle(paramsJSON: params(book, rest), registry: book.registry)
        return try JSONDecoder().decode(ReadFigureTool.TableResult.self, from: json)
    }

    private func key(_ table: FigureTable, _ row: Int, _ column: Int) -> CellKey {
        CellKey(row: table.rows[row], column: table.columns[column])
    }

    /// A 4x2 table: header, 1234.5 (currency), 100, and `=SUM(B2:B3)`.
    private func cashTable() throws -> FigureTable {
        var table = FigureTable(rows: 4, columns: 2)
        table.headerRows = 1
        table.setCell(Cell(content: .value(.text("Item"))), at: key(table, 0, 0))
        table.setCell(Cell(content: .value(.text("Amount"))), at: key(table, 0, 1))
        table.setCell(Cell(content: .value(.text("Rent"))), at: key(table, 1, 0))
        table.setCell(Cell(content: .value(.number(1234.5)),
                           format: CellFormat(number: .number(decimals: 2, grouping: true))),
                      at: key(table, 1, 1))
        table.setCell(Cell(content: .value(.text("Food"))), at: key(table, 2, 0))
        table.setCell(Cell(content: .value(.number(100))), at: key(table, 2, 1))
        guard case .success(let f) = FormulaParser.parse("SUM(B2:B3)", in: table, names: .empty)
        else { throw FigureEditInvalid(reason: "the formula did not parse") }
        table.setCell(Cell(content: .formula(f)), at: key(table, 3, 1))
        return table
    }

    func test_aFormulaCellReadsFormulaValueAndRaw() async throws {
        let book = try await openBook()
        _ = try await book.store.createFigure(kind: .table, name: "cash", piece: nil, table: try cashTable())
        await book.ds.awaitOpenFigureRenderForTesting()
        // The render is a derived file: delete it, the values still come.
        try? FileManager.default.removeItem(at: file("figures/cash.csv"))

        for label in ["cash", "tbl:cash", "CASH"] {
            let result = try await read(book, "\"name\":\"\(label)\"")
            XCTAssertEqual(result.rows, 4)
            XCTAssertEqual(result.cells.count, 8)
            let b4 = try XCTUnwrap(result.cells.first { $0.a1 == "B4" })
            XCTAssertEqual(b4.formula, "=SUM(B2:B3)")
            XCTAssertEqual(b4.raw.type, "number")
            XCTAssertEqual(b4.raw.number, 1334.5)
            let b2 = try XCTUnwrap(result.cells.first { $0.a1 == "B2" })
            XCTAssertNil(b2.formula)
            XCTAssertEqual(b2.value, "1,234.50")
            XCTAssertEqual(b2.raw.number, 1234.5)
            XCTAssertEqual(b2.format.number, .number(decimals: 2, grouping: true))
            XCTAssertTrue(result.text.contains("1,234.50"))
            XCTAssertTrue(result.text.contains("| A "), "column letters head the text table")
        }
        await book.ds.close()
    }

    func test_rangeLimitsTheCellsAndAnInvalidOneIsAClearError() async throws {
        let book = try await openBook()
        _ = try await book.store.createFigure(kind: .table, name: "cash", piece: nil, table: try cashTable())
        let part = try await read(book, "\"name\":\"cash\",\"range\":\"A1:B2\"")
        XCTAssertEqual(part.cells.map(\.a1), ["A1", "B1", "A2", "B2"])
        XCTAssertEqual(part.range, "A1:B2")
        let one = try await read(book, "\"name\":\"cash\",\"range\":\"b3\"")
        XCTAssertEqual(one.cells.map(\.a1), ["B3"])

        for bad in ["Z99", "A1:", "nonsense"] {
            do {
                _ = try await ReadFigureTool.handle(
                    paramsJSON: params(book, "\"name\":\"cash\",\"range\":\"\(bad)\""), registry: book.registry)
                XCTFail("range \(bad) should be refused")
            } catch let MCPError.invalidArgument(message) {
                XCTAssertTrue(message.contains("range"), message)
            }
        }
        await book.ds.close()
    }

    func test_aLargeTableWithoutRangeIsRefusedWithAHintNamingRange() async throws {
        let book = try await openBook()
        // Empty cells are still answered (a1, value, raw, format), so a grid of 25,000 cells is
        // large with no stored cell: creating thousands of stored cells is slow, reading is not.
        _ = try await book.store.createFigure(kind: .table, name: "big", piece: nil, rows: 500, columns: 50)
        do {
            _ = try await ReadFigureTool.handle(
                paramsJSON: params(book, "\"name\":\"big\""), registry: book.registry)
            XCTFail("25,000 cells should not fit one response")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "payload_too_large")
            XCTAssertTrue(payload.hint?.contains("range") ?? false)
        }
        let json = try await ReadFigureTool.handle(
            paramsJSON: params(book, "\"name\":\"big\",\"range\":\"A1:F50\""), registry: book.registry)
        XCTAssertLessThan(json.count, MCPResponseBudget.maxTextBytes)
        let part = try JSONDecoder().decode(ReadFigureTool.TableResult.self, from: json)
        XCTAssertEqual(part.cells.count, 300)
        await book.ds.close()
    }

    func test_anUnknownNameListsTheNearestNames() async throws {
        let book = try await openBook()
        _ = try await book.store.createFigure(kind: .table, name: "cash", piece: nil, table: try cashTable())
        _ = try await book.store.createFigure(kind: .table, name: "census", piece: nil)
        do {
            _ = try await ReadFigureTool.handle(
                paramsJSON: params(book, "\"name\":\"cas\""), registry: book.registry)
            XCTFail("unknown name")
        } catch let MCPError.invalidArgument(message) {
            XCTAssertTrue(message.contains("cash"), message)
            XCTAssertTrue(message.contains("nearest"), message)
        }
        await book.ds.close()
    }

    func test_aParkedTableReadsItsParkedState() async throws {
        let book = try await openBook()
        let record = try await book.store.createFigure(kind: .table, name: "cash", piece: nil, table: try cashTable())
        _ = try await book.store.sendToResearch(figureId: record.id, scope: .shared)
        await book.ds.awaitOpenFigureRenderForTesting()
        let result = try await read(book, "\"name\":\"cash\",\"range\":\"B4\"")
        XCTAssertEqual(result.cells.first?.formula, "=SUM(B2:B3)")
        XCTAssertEqual(result.cells.first?.raw.number, 1334.5)
        await book.ds.close()
    }

    private func writePNG(to url: URL, width: Int, height: Int) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<width { for y in 0..<height {
            rep.setColor(NSColor(calibratedRed: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height),
                                 blue: 0.5, alpha: 1), atX: x, y: y)
        } }
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private struct Envelope: Decodable {
        struct Block: Decodable { let type: String; let data: String?; let text: String? }
        let content: [Block]
    }

    func test_anImageFigureReturnsAnEnvelopeUnderTheCapAndRegionCrops() async throws {
        let book = try await openBook()
        let source = TestTemp.root.appendingPathComponent("pic-\(UUID().uuidString).png")
        try writePNG(to: source, width: 3000, height: 2000)
        _ = try await book.store.createImageFigure(fromURL: source, name: "photo", piece: nil)

        let full = try await ReadFigureTool.handle(
            paramsJSON: params(book, "\"name\":\"fig:photo\""), registry: book.registry)
        XCTAssertLessThan(full.count, 1_000_000)
        let image = try XCTUnwrap(try JSONDecoder().decode(Envelope.self, from: full).content.first { $0.type == "image" })
        let fullBytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(image.data)))
        let fullSize = try XCTUnwrap(NSBitmapImageRep(data: fullBytes)).pixelsWide

        let crop = try await ReadFigureTool.handle(
            paramsJSON: params(book, "\"name\":\"photo\",\"max_dimension\":4096,\"region\":{\"x\":0,\"y\":0,\"width\":0.1,\"height\":0.1}"),
            registry: book.registry)
        let cropImage = try XCTUnwrap(try JSONDecoder().decode(Envelope.self, from: crop).content.first { $0.type == "image" })
        let cropRep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(cropImage.data)))))
        XCTAssertLessThan(cropRep.pixelsWide, fullSize, "the region is a smaller picture")
        XCTAssertEqual(cropRep.pixelsWide, 300, accuracy: 2)
        await book.ds.close()
    }

    // MARK: - Final fix wave (I1, M2, M3, M7)

    /// The ENCODED JSON of a raw value, so the wire is pinned and not the struct.
    private func wire(_ value: CellValue) throws -> [String: Any] {
        let data = try JSONEncoder().encode(ReadFigureTool.Raw(value))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_rawWireShapeIsTypeAndValueForEveryCase() throws {
        let n = try wire(.number(1334.5))
        XCTAssertEqual(Set(n.keys), ["type", "value"])
        XCTAssertEqual(n["type"] as? String, "number"); XCTAssertEqual(n["value"] as? Double, 1334.5)
        let t = try wire(.text("Rent"))
        XCTAssertEqual(Set(t.keys), ["type", "value"]); XCTAssertEqual(t["value"] as? String, "Rent")
        let b = try wire(.bool(true))
        XCTAssertEqual(Set(b.keys), ["type", "value"]); XCTAssertEqual(b["value"] as? Bool, true)
        let d = try wire(.date(45000))
        XCTAssertEqual(Set(d.keys), ["type", "value", "iso"])
        XCTAssertEqual(d["value"] as? Int, 45000); XCTAssertNotNil(d["iso"] as? String)
        let e = try wire(.error(.ref))
        XCTAssertEqual(Set(e.keys), ["type", "value"]); XCTAssertEqual(e["value"] as? String, "#REF!")
        let m = try wire(.empty)
        XCTAssertEqual(Set(m.keys), ["type"]); XCTAssertEqual(m["type"] as? String, "empty")
    }

    func test_aLabelOfTheWrongKindIsRefusedNamingTheRightLabel() async throws {
        let book = try await openBook()
        _ = try await book.store.createFigure(kind: .table, name: "sales", piece: nil, table: try cashTable())
        do {
            _ = try await ReadFigureTool.handle(
                paramsJSON: params(book, "\"name\":\"fig:sales\""), registry: book.registry)
            XCTFail("fig:sales is not the table sales")
        } catch let MCPError.invalidArgument(message) {
            XCTAssertTrue(message.contains("tbl:sales"), message)
        }
        let ok = try await read(book, "\"name\":\"tbl:sales\"")
        XCTAssertEqual(ok.name, "sales")
        await book.ds.close()
    }

    func test_aSpanishBookReadsItsValuesInSpanish() async throws {
        let book = try await openBook()
        try FileManager.default.createDirectory(
            at: file(".maugham/publish"), withIntermediateDirectories: true)
        try Data(#"{"metadata":{"language":"es-ES"}}"#.utf8).write(to: file(".maugham/publish/config.json"))
        var table = FigureTable(rows: 1, columns: 1)
        table.setCell(Cell(content: .value(.number(12345.6)),
                           format: CellFormat(number: .number(decimals: 1, grouping: true))),
                      at: key(table, 0, 0))
        _ = try await book.store.createFigure(kind: .table, name: "es", piece: nil, table: table)
        let result = try await read(book, "\"name\":\"es\"")
        XCTAssertEqual(result.cells.first?.value, "12.345,6")
        await book.ds.close()
    }

    func test_anImageFileOutsideFiguresIsNeverRead() async throws {
        let book = try await openBook()
        let source = TestTemp.root.appendingPathComponent("pic-\(UUID().uuidString).png")
        try writePNG(to: source, width: 20, height: 20)
        let record = try await book.store.createImageFigure(fromURL: source, name: "photo", piece: nil)
        let snapshot = await book.store.publishFigures()
        let state = try XCTUnwrap(snapshot.states[record.id])
        var traversing = state
        traversing.image = FigureImageRef(filename: "../manuscript/escape.png", contentHash: "h")
        try writePNG(to: file("manuscript/escape.png"), width: 20, height: 20)
        do {
            _ = try ReadFigureTool.imageEnvelopeForTesting(
                record: record, state: traversing, projectURL: projectURL)
            XCTFail("a filename with a separator must be refused")
        } catch let MCPError.invalidArgument(message) {
            XCTAssertTrue(message.contains("unsafe path"), message)
        }
        await book.ds.close()
    }
}

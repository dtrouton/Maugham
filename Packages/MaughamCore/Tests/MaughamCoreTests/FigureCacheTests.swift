import XCTest
@testable import MaughamCore

private struct NoPins: ResearchPinSource {
    func pinnedValue(research name: String, row: Int, column: Int) -> CellValue? { nil }
}

/// Report plan 6a Task 4: the mtime-keyed figure cache and the document
/// workbook keyed by figure name.
@MainActor
final class FigureCacheTests: XCTestCase {

    private let r1 = RowID("r1aaaaaa"), c1 = ColumnID("c1dddddd")
    private var counter = 0

    private func op(_ id: String, _ kind: OpKind, _ payload: FigureOpPayload) -> Op {
        counter += 1
        return Op(opId: String(format: "op%04d", counter), docId: id,
                  at: Date(timeIntervalSince1970: TimeInterval(1_000 + counter)),
                  device: "macA", session: "s", kind: kind, changes: [], figure: payload)
    }

    private func append(_ ops: [Op], docId: String, to root: URL) throws {
        let dir = root.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        let blob = try ops.map { String(data: try enc.encode($0), encoding: .utf8)! }
            .joined(separator: "\n") + "\n"
        let url = dir.appendingPathComponent("\(docId).jsonl")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(blob.utf8)); try h.close()
        } else {
            try blob.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func skeleton(_ id: String) -> [Op] {
        [op(id, .figureCreate, FigureOpPayload(kind: .table)),
         op(id, .figureStructure, FigureOpPayload(structure: .insertRow(r1, after: nil))),
         op(id, .figureStructure, FigureOpPayload(structure: .insertColumn(c1, after: nil)))]
    }

    private func setCell(_ id: String, _ cell: Cell) -> Op {
        op(id, .figureCellSet, FigureOpPayload(cell: CellKey(row: r1, column: c1), next: cell, prior: nil))
    }

    private func newRoot() -> URL { TestTemp.root.appendingPathComponent("fc-\(UUID().uuidString)") }

    private func record(_ id: String, _ name: String, piece: String? = nil) -> FigureRecord {
        FigureRecord(id: id, name: name, kind: .table, piece: piece, path: "figures/\(name).csv")
    }

    func test_secondReadWithFilesUnchanged_hitsTheCache() throws {
        let root = newRoot()
        try append(skeleton("fig-aaaa1111") + [setCell("fig-aaaa1111", Cell(content: .value(.number(5))))],
                   docId: "fig-aaaa1111", to: root)
        let cache = FigureCache()
        let facts = DocumentClass.Facts.empty
        let a = try cache.state(forFigureId: "fig-aaaa1111", in: root, facts: facts)
        let b = try cache.state(forFigureId: "fig-aaaa1111", in: root, facts: facts)
        XCTAssertEqual(a, b)
        XCTAssertEqual(cache.deriveCount, 1)
        XCTAssertEqual(a.table.rows, [r1])
    }

    func test_appendingAnOp_invalidatesByToken_andInvalidateForcesARederive() throws {
        let root = newRoot()
        let id = "fig-aaaa1111"
        try append(skeleton(id), docId: id, to: root)
        let cache = FigureCache()
        let facts = DocumentClass.Facts.empty
        let before = try cache.state(forFigureId: id, in: root, facts: facts)
        XCTAssertNil(before.table[CellKey(row: r1, column: c1)])
        try append([setCell(id, Cell(content: .value(.number(7))))], docId: id, to: root)
        let after = try cache.state(forFigureId: id, in: root, facts: facts)
        XCTAssertEqual(cache.deriveCount, 2)
        XCTAssertNotEqual(before, after)
        cache.invalidate(figureId: id)
        _ = try cache.state(forFigureId: id, in: root, facts: facts)
        XCTAssertEqual(cache.deriveCount, 3)
    }

    private func twoFigureBook() throws -> (URL, ProjectManifest, FigureTable) {
        let root = newRoot()
        try append(skeleton("fig-cash0001") + [setCell("fig-cash0001", Cell(content: .value(.number(100))))],
                   docId: "fig-cash0001", to: root)
        let cash = FigureDeriver.derive(try OpLogStore.loadSyncMerged(
            forDocId: "fig-cash0001", in: root, facts: .empty)).table
        guard case .success(let f) = FormulaParser.parse("cashflow!A1", in: cash, figures: ["cashflow": cash]) else {
            XCTFail("unparseable"); throw CancellationError()
        }
        try append(skeleton("fig-summ0001") + [setCell("fig-summ0001", Cell(content: .formula(f)))],
                   docId: "fig-summ0001", to: root)
        let manifest = ProjectManifest(type: .novel, title: "T", author: "A", created: Date(), modified: Date(), structure: [], research: [], figures: [record("fig-cash0001", "cashflow"), record("fig-summ0001", "summary")])
        return (root, manifest, cash)
    }

    func test_workbookEvaluatesACrossFigureReferenceByName() throws {
        let (root, manifest, _) = try twoFigureBook()
        let cache = FigureCache()
        let wb = workbook(for: manifest, cache: cache, projectURL: root, pins: NoPins())
        XCTAssertEqual(Set(wb.tables.keys), ["cashflow", "summary"])
        let t = try XCTUnwrap(wb.tables["summary"])
        XCTAssertEqual(wb.value(at: CellAddress(table: "summary", key: CellKey(row: t.rows[0], column: t.columns[0]))),
                       .number(100))
    }

    func test_aParkedFigureIsAbsent_andAReferenceToItIsREF() throws {
        let (root, manifest, _) = try twoFigureBook()
        try append([op("fig-cash0001", .figureParked,
                       FigureOpPayload(parkedPath: "research/cashflow.csv", parkedHash: "h1"))],
                   docId: "fig-cash0001", to: root)
        let wb = workbook(for: manifest, cache: FigureCache(), projectURL: root, pins: NoPins())
        XCTAssertNil(wb.tables["cashflow"])
        let t = try XCTUnwrap(wb.tables["summary"])
        XCTAssertEqual(wb.value(at: CellAddress(table: "summary", key: CellKey(row: t.rows[0], column: t.columns[0]))),
                       .error(.ref))
    }
}

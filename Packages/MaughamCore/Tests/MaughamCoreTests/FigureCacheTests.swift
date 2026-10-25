import XCTest
@testable import MaughamCore

private struct NoPins: ResearchPinSource {
    func pinnedValue(home: String, research: String, row: Int, column: Int) -> CellValue? { nil }
}

/// Report plan 6a Task 4: the mtime-keyed figure cache and the document
/// workbook, keyed by figure id since report plan 6b Task 3 (R-D1).
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
        guard case .success(let f) = FormulaParser.parse(
            "cashflow!A1", in: cash, names: FormulaNames(figures: [.init(id: "fig-cash0001", name: "cashflow", table: cash)])) else {
            XCTFail("unparseable"); throw CancellationError()
        }
        try append(skeleton("fig-summ0001") + [setCell("fig-summ0001", Cell(content: .formula(f)))],
                   docId: "fig-summ0001", to: root)
        let manifest = ProjectManifest(type: .novel, title: "T", author: "A", created: Date(), modified: Date(), structure: [], research: [], figures: [record("fig-cash0001", "cashflow"), record("fig-summ0001", "summary")])
        return (root, manifest, cash)
    }

    func test_workbookEvaluatesACrossFigureReferenceById() throws {
        let (root, manifest, _) = try twoFigureBook()
        let cache = FigureCache()
        let r = FigureWorkbook.assemble(for: manifest, cache: cache, projectURL: root, pins: NoPins())
        let wb = r.workbook
        XCTAssertEqual(Set(wb.tables.keys), ["fig-cash0001", "fig-summ0001"])
        XCTAssertEqual(r.parked, [])
        let t = try XCTUnwrap(wb.tables["fig-summ0001"])
        XCTAssertEqual(wb.value(at: CellAddress(table: "fig-summ0001", key: CellKey(row: t.rows[0], column: t.columns[0]))),
                       .number(100))
    }

    /// R-D1: the registry renames the figure a formula reads; no op is appended to either
    /// stream, the value still flows, and the formula shows the new name.
    func test_aRegistryRename_rewritesNoFormula_andTheFormulaShowsTheNewName() throws {
        let (root, manifest, _) = try twoFigureBook()
        let opsBefore = try OpLogStore.loadSyncMerged(forDocId: "fig-summ0001", in: root, facts: .empty).count
        var renamed = manifest
        renamed.figures?[0].name = "cash flow 2026"
        let cache = FigureCache()
        let wb = FigureWorkbook.assemble(for: renamed, cache: cache, projectURL: root, pins: NoPins()).workbook
        let t = try XCTUnwrap(wb.tables["fig-summ0001"])
        let a1 = CellKey(row: t.rows[0], column: t.columns[0])
        XCTAssertEqual(wb.value(at: CellAddress(table: "fig-summ0001", key: a1)), .number(100))
        guard case .formula(let f)? = t[a1]?.content else { return XCTFail("the formula is still there") }
        let names = FormulaNames(records: renamed.figures ?? [], tables: wb.tables, research: renamed.research)
        XCTAssertEqual(FormulaParser.render(f, in: t, names: names), "'cash flow 2026'!A1")
        XCTAssertEqual(try OpLogStore.loadSyncMerged(forDocId: "fig-summ0001", in: root, facts: .empty).count, opsBefore,
                       "nothing was appended")
    }

    /// A parked figure is assembled from its parked state, so its readers keep its values
    /// (R-D2), and it is listed so they can be flagged (plan 6b Task 9).
    func test_aParkedFigureIsAssembledFromItsParkedState_andListed() throws {
        let (root, manifest, _) = try twoFigureBook()
        try append([op("fig-cash0001", .figureParked,
                       FigureOpPayload(parkedPath: "research/cashflow.csv", parkedHash: "h1"))],
                   docId: "fig-cash0001", to: root)
        let r = FigureWorkbook.assemble(for: manifest, cache: FigureCache(), projectURL: root, pins: NoPins())
        XCTAssertEqual(r.parked, ["fig-cash0001"])
        XCTAssertNotNil(r.workbook.tables["fig-cash0001"])
        let t = try XCTUnwrap(r.workbook.tables["fig-summ0001"])
        XCTAssertEqual(r.workbook.value(at: CellAddress(table: "fig-summ0001", key: CellKey(row: t.rows[0], column: t.columns[0]))),
                       .number(100), "the reader keeps the parked figure's last value")
    }

    /// An open host's fold laid over the read wins for `parked` both ways, so the set is
    /// the one answer to which figures sit in Research.
    func test_anOverlaysParkedStatusWins() throws {
        let (root, manifest, cash) = try twoFigureBook()
        var r = FigureWorkbook.assemble(for: manifest, cache: FigureCache(), projectURL: root, pins: NoPins())
        XCTAssertEqual(r.parked, [])
        r.overlay(FigureState(kind: .table, table: cash, parked: FigureParking(path: "research/c.csv", hash: "h1")), id: "fig-cash0001")
        XCTAssertEqual(r.parked, ["fig-cash0001"], "a host that has just parked it")
        r.overlay(FigureState(kind: .table, table: cash), id: "fig-cash0001")
        XCTAssertEqual(r.parked, [], "a host that has resumed it, over a parked read")
        XCTAssertNotNil(r.workbook.tables["fig-cash0001"])
    }

    func test_aRecordAppearingOrItsPieceChanging_missesTheCacheByItself() throws {
        let root = newRoot()
        let id = "fig-aaaa1111"
        try append(skeleton(id), docId: id, to: root)
        let cache = FigureCache()
        func facts(_ rs: [FigureRecord]) -> DocumentClass.Facts { .init(statements: [], figures: rs) }
        _ = try cache.state(forFigureId: id, in: root, facts: facts([]))
        _ = try cache.state(forFigureId: id, in: root, facts: facts([]))
        XCTAssertEqual(cache.deriveCount, 1)
        _ = try cache.state(forFigureId: id, in: root, facts: facts([record(id, "a", piece: "p1")]))
        XCTAssertEqual(cache.deriveCount, 2, "a record appearing misses")
        _ = try cache.state(forFigureId: id, in: root, facts: facts([record(id, "a", piece: "p1")]))
        XCTAssertEqual(cache.deriveCount, 2)
        _ = try cache.state(forFigureId: id, in: root, facts: facts([record(id, "a", piece: "p2")]))
        XCTAssertEqual(cache.deriveCount, 3, "a piece change misses")
    }

    func test_anUnreadableFigureIsListed_andItsDependantsAreREF() throws {
        let (root, manifest, _) = try twoFigureBook()
        let file = root.appendingPathComponent(".maugham/ops/fig-cash0001.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let r = FigureWorkbook.assemble(for: manifest, cache: FigureCache(), projectURL: root, pins: NoPins())
        XCTAssertEqual(r.unreadable.map(\.name), ["cashflow"])
        XCTAssertNil(r.workbook.tables["fig-cash0001"])
        XCTAssertEqual(r.parked, [], "unreadable is never conflated with parked")
        let t = try XCTUnwrap(r.workbook.tables["fig-summ0001"])
        XCTAssertEqual(r.workbook.value(at: CellAddress(table: "fig-summ0001", key: CellKey(row: t.rows[0], column: t.columns[0]))),
                       .error(.ref))
    }

    func test_assembling_evictsFiguresNoLongerInTheManifest() throws {
        let (root, manifest, _) = try twoFigureBook()
        let cache = FigureCache()
        _ = FigureWorkbook.assemble(for: manifest, cache: cache, projectURL: root, pins: NoPins())
        XCTAssertEqual(cache.deriveCount, 2)
        var smaller = manifest
        smaller.figures = [record("fig-summ0001", "summary")]
        _ = FigureWorkbook.assemble(for: smaller, cache: cache, projectURL: root, pins: NoPins())
        _ = FigureWorkbook.assemble(for: manifest, cache: cache, projectURL: root, pins: NoPins())
        XCTAssertEqual(cache.deriveCount, 3, "summary still cached; cashflow was evicted, so re-derived")
    }
}

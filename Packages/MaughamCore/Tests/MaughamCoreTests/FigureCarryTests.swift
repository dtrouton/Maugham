import XCTest
@testable import MaughamCore

/// **What a promotion carries of the book's figures, and the streams that
/// re-create them** (report plan 6c Task 4, rulings Q-4 to Q-6).
final class FigureCarryTests: XCTestCase {

    private let r1 = RowID("r1aaaaaa"), r2 = RowID("r2aaaaaa"), r3 = RowID("r3aaaaaa")
    private let c1 = ColumnID("c1aaaaaa"), c2 = ColumnID("c2aaaaaa"), c3 = ColumnID("c3aaaaaa")

    // MARK: - Building

    /// A figure's stream, op by op, each made against the state the ones
    /// before it left, as a host would.
    private struct History {
        var ops: [Op] = []
        var state = FigureState()

        mutating func emit(_ kind: OpKind, _ payload: FigureOpPayload, device: String = "macA") {
            let op = Op(opId: String(format: "01H%06d", ops.count + 1), docId: "fig-k3m9q2zt",
                        at: Date(timeIntervalSince1970: TimeInterval(ops.count)), device: device,
                        session: "s", kind: kind, changes: [], figure: payload)
            ops.append(op)
            FigureDeriver.fold(op, into: &state)
        }
        mutating func insert(_ r: RowID, after: RowID?) {
            emit(.figureStructure, FigureOpPayload(structure: .insertRow(r, after: after)))
        }
        mutating func insert(_ c: ColumnID, after: ColumnID?) {
            emit(.figureStructure, FigureOpPayload(structure: .insertColumn(c, after: after)))
        }
        mutating func set(_ r: RowID, _ c: ColumnID, _ content: CellContent, format: CellFormat = .init(),
                          device: String = "macA") {
            let key = CellKey(row: r, column: c)
            emit(.figureCellSet, FigureOpPayload(
                cell: key, next: Cell(content: content, format: format), prior: state.table[key]), device: device)
        }
        mutating func pin(_ r: RowID, _ c: ColumnID, research: String, row: Int = 0, value: Double,
                          at: TimeInterval, park: String? = nil) {
            emit(.figurePinSet, FigureOpPayload(
                cell: CellKey(row: r, column: c),
                pin: FigureResearchPin(research: research, row: row, column: 0, value: .number(value),
                                       sourceHash: "h\(Int(value))", at: Date(timeIntervalSince1970: at),
                                       park: park)))
        }
    }

    /// A record of `kind` named `name`, in `piece`.
    private func record(_ id: String, _ name: String, _ kind: FigureKind = .table, piece: String?) -> FigureRecord {
        FigureRecord(id: id, name: name, kind: kind, piece: piece,
                     path: kind == .table ? "figures/\(name).csv" : "figures/\(name).png")
    }

    /// A table whose one cell holds a formula reading `targets`, each at (0, 0).
    private func reading(_ targets: [RefTarget]) -> FigureState {
        var table = FigureTable(rows: 1, columns: 1)
        let refs = targets.map {
            FormulaExpr.ref(FormulaRef(target: $0, anchor: .position(row: 0, column: 0)))
        }
        let expr = refs.dropFirst().reduce(refs.first ?? .number(0)) { .binary(.add, $0, $1) }
        table.setCell(Cell(content: .formula(Formula(expr))), at: CellKey(row: table.rows[0], column: table.columns[0]))
        return FigureState(kind: .table, table: table)
    }

    /// `opening` minted with sortable ids by one device, as a writer would.
    private func mint(_ opening: [(kind: OpKind, payload: FigureOpPayload)], device: String = "macNew") -> [Op] {
        var n = 0
        return FigureCarry.minted(opening) { kind, payload in
            n += 1
            return Op(opId: String(format: "02N%06d", n), docId: "fig-k3m9q2zt",
                      at: Date(timeIntervalSince1970: TimeInterval(n)), device: device,
                      session: "promote", kind: kind, changes: [], figure: payload)
        }
    }

    /// The re-created stream folds clean and to `source`: the whole table —
    /// slots with their tombstones, cells with formulas and formats, header
    /// and total rows, widths — its live pins, picture, source and kind.
    @discardableResult
    private func assertRecreates(_ source: FigureState, record: FigureRecord, parks: [String: String] = [:],
                                 file: StaticString = #filePath, line: UInt = #line) -> (FigureState, [Op]) {
        let ops = mint(FigureCarry.openingOps(for: record, state: source, parks: parks))
        for op in ops {
            XCTAssertTrue(FigureOpPayload.validate(kind: op.kind, payload: op.figure!), "\(op.kind)", file: file, line: line)
        }
        let made = FigureDeriver.derive(ops)
        XCTAssertEqual(made.diagnostics, [], "every op applies", file: file, line: line)
        XCTAssertEqual(made.kind, source.kind, "kind", file: file, line: line)
        XCTAssertEqual(made.table, source.table, "table", file: file, line: line)
        XCTAssertEqual(made.image, source.image, "picture", file: file, line: line)
        XCTAssertEqual(made.source, source.source, "source", file: file, line: line)
        let winners = { (s: FigureState) in
            FigurePinChoice.winners(s.pins, parks: parks).mapValues { "\($0.pin)@\($0.cell.row.raw)\($0.cell.column.raw)" }
        }
        XCTAssertEqual(winners(made), winners(source), "live pins", file: file, line: line)
        XCTAssertEqual(made.parked?.path, source.parked?.path, "parked path", file: file, line: line)
        XCTAssertEqual(made.parked?.hash, source.parked?.hash, "parked hash", file: file, line: line)
        XCTAssertEqual(made.parked?.itemId, source.parked?.itemId, "parked item", file: file, line: line)
        return (made, ops)
    }

    // MARK: - Which figures

    /// Review Focus 3's shape: the text cites a whole-book figure whose
    /// formula reads a second whole-book figure — both are copied, the
    /// second only through the first's formula; the piece's own figure moves;
    /// a figure named by its path is copied; an unnamed one stays.
    func test_theSelection_ownMove_namedAndTransitivelyReadAreCopied() {
        let own = record("fig-00000001", "own", piece: "doc-p")
        let cited = record("fig-00000002", "cited", piece: nil)
        let readOnly = record("fig-00000003", "readonly", piece: nil)
        let elsewhere = record("fig-00000004", "elsewhere", piece: "doc-q")
        let byPath = record("fig-00000005", "map", .image, piece: "doc-q")
        let records = [elsewhere, readOnly, own, byPath, cited]
        let states = [
            cited.id: reading([.figure(id: readOnly.id), .research(id: "res-left")]),
            // A cycle back to the cited figure must not loop.
            readOnly.id: reading([.figure(id: cited.id), .figure(id: "fig-gone0000")]),
        ]
        let text = """
            Intro, as @tbl:cited shows.

            ![A map](figures/map.png)

            ```
            @tbl:elsewhere in a fence names nothing
            ```
            """
        let refs = FigureCarry.references(inText: text)
        XCTAssertEqual(refs.labels, ["tbl:cited"])
        XCTAssertEqual(refs.paths, ["figures/map.png"])

        let carry = FigureCarry.figures(
            forPiece: "doc-p", records: records,
            referencedLabels: refs.labels, referencedPaths: refs.paths, states: states)
        XCTAssertEqual(carry.moved.map(\.id), [own.id])
        XCTAssertEqual(carry.copied.map(\.id), [readOnly.id, byPath.id, cited.id], "registry order")
    }

    /// A figure's own line defines its label: a `{#tbl:…}` caption and a
    /// `{#fig:…}` figure line are references too.
    func test_definedLabelsAreReferences() {
        let text = """
            | A | B |
            |---|---|
            | 1 | 2 |
            Table: Cash {#tbl:cash}

            ![Sites](figures/sites.png){#fig:sites}
            """
        let refs = FigureCarry.references(inText: text)
        XCTAssertEqual(refs.labels, ["tbl:cash", "fig:sites"])
        let cash = record("fig-00000001", "cash", piece: nil)
        let sites = record("fig-00000002", "sites", .image, piece: nil)
        // A label names a figure of its own kind only.
        let wrongKind = record("fig-00000003", "cash", .image, piece: nil)
        let carry = FigureCarry.figures(
            forPiece: "doc-p", records: [cash, sites, wrongKind], referencedLabels: refs.labels, states: [:])
        XCTAssertEqual(carry.copied.map(\.id), [cash.id, sites.id])
    }

    // MARK: - The opening ops, per kind

    /// A table with formulas and formats, a moved row, a deleted row and
    /// column (tombstones kept, so a range edge shrinks as it did), header
    /// and total rows, a width, and pins — the live winner carried, an
    /// inert pin from an earlier park and a losing pin left out.
    func test_aTableRecreatesEqual() throws {
        var h = History()
        h.emit(.figureCreate, FigureOpPayload(kind: .table, source: FigureSource(
            researchItemId: "res-src", path: "research/src.csv", contentHash: "abc")))
        h.insert(r1, after: nil); h.insert(r2, after: r1); h.insert(r3, after: r2)
        h.insert(c1, after: nil); h.insert(c2, after: c1); h.insert(c3, after: c2)
        h.set(r1, c1, .value(.text("Item")))
        h.set(r2, c1, .value(.number(0.25)), format: CellFormat(number: .percent(decimals: 0)))
        h.set(r2, c2, .formula(Formula(.binary(.multiply,
            .ref(FormulaRef(target: .this, anchor: .id(row: r2, column: c1))),
            .ref(FormulaRef(target: .research(id: "res-a"), anchor: .position(row: 1, column: 0)))))))
        h.set(r3, c2, .formula(Formula(.call(name: "SUM", arguments: [.range(FormulaRange(
            start: FormulaRef(target: .this, anchor: .id(row: r1, column: c2)),
            end: FormulaRef(target: .this, anchor: .id(row: r3, column: c2))))]))))
        h.set(r3, c3, .value(.text("gone")))
        h.emit(.figureStructure, FigureOpPayload(structure: .deleteColumn(c3), removed: h.state.removedSlice(column: c3)))
        h.emit(.figureStructure, FigureOpPayload(structure: .moveRow(r3, after: nil, priorAfter: r2)))
        h.emit(.figureStructure, FigureOpPayload(structure: .deleteRow(r1), removed: h.state.removedSlice(row: r1)))
        h.emit(.figureSettings, FigureOpPayload(settings: .headerRows(1, prior: 0)))
        h.emit(.figureSettings, FigureOpPayload(settings: .totalRow(true, prior: false)))
        h.emit(.figureSettings, FigureOpPayload(settings: .columnWidth(c2, 96, prior: nil)))
        h.pin(r2, c2, research: "res-a", row: 1, value: 4, at: 10)
        h.pin(r3, c2, research: "res-a", row: 1, value: 3, at: 5)          // loses to the later pin
        h.pin(r3, c2, research: "fig-parked00", value: 7, at: 20, park: "res-old")   // inert: an earlier park
        h.pin(r2, c2, research: "fig-parked00", row: 2, value: 8, at: 21, park: "res-now")
        XCTAssertEqual(h.state.diagnostics, [], "precondition")
        XCTAssertNotEqual(h.state.table.rowSlots.count, h.state.table.rows.count, "precondition: a tombstone")

        let parks = ["fig-parked00": "res-now"]
        let (made, ops) = assertRecreates(h.state, record: record("fig-k3m9q2zt", "cash", piece: nil), parks: parks)
        XCTAssertEqual(made.pins.values.flatMap { $0 }.count, 2, "the live winners only")
        XCTAssertEqual(ops.filter { $0.kind == .figurePinSet }.count, 2)
        XCTAssertEqual(ops.first?.kind, .figureCreate)
        XCTAssertFalse(ops.contains { $0.kind == .figureParked })
    }

    /// An image: its picture, as it stands, and nothing of the one it replaced.
    func test_anImageRecreatesEqual() {
        var h = History()
        h.emit(.figureCreate, FigureOpPayload(kind: .image))
        h.emit(.figureImageSet, FigureOpPayload(image: FigureImageRef(filename: "map.png", contentHash: "h1")))
        h.emit(.figureImageSet, FigureOpPayload(
            image: FigureImageRef(filename: "map.png", contentHash: "h2"),
            priorImage: FigureImageRef(filename: "map.png", contentHash: "h1")))
        let (_, ops) = assertRecreates(h.state, record: record("fig-k3m9q2zt", "map", .image, piece: nil))
        XCTAssertEqual(ops.map(\.kind), [.figureCreate, .figureImageSet])
        XCTAssertNil(ops.last?.figure?.priorImage)
    }

    /// Q-6: a parked table is re-created, then parked again naming the same
    /// working copy, with what the parker had read — the new stream's own
    /// last op — so a return there diffs against the re-created table.
    func test_aParkedTableRecreatesEqualAndParkedAgain() throws {
        var h = History()
        h.emit(.figureCreate, FigureOpPayload(kind: .table))
        h.insert(r1, after: nil); h.insert(c1, after: nil); h.insert(c2, after: c1)
        h.set(r1, c1, .value(.number(5)))
        h.set(r1, c2, .formula(Formula(.ref(FormulaRef(target: .this, anchor: .id(row: r1, column: c1))))))
        h.emit(.figureParked, FigureOpPayload(
            parkedPath: "research/cash.csv", parkedHash: "ph", parkedItemId: "res-copy",
            parkedFrontier: ["macA": h.ops.last!.opId]))
        // An edit ordered while parked folds nothing, and is not carried.
        h.set(r1, c1, .value(.number(9)), device: "macB")
        XCTAssertNotNil(h.state.parked, "precondition")

        let (made, ops) = assertRecreates(h.state, record: record("fig-k3m9q2zt", "cash", piece: "doc-p"))
        let park = try XCTUnwrap(ops.last)
        XCTAssertEqual(park.kind, .figureParked)
        let lastBefore = ops[ops.count - 2].opId
        XCTAssertEqual(park.figure?.parkedFrontier, ["macNew": lastBefore])
        XCTAssertEqual(made.parked?.frontier, ["macNew": lastBefore])
        XCTAssertEqual(made.parked?.cycle, "res-copy", "a pin on it stays live")

        let base = FigureReturnDiff.base(
            of: ops, streams: ["macNew": ops.map(\.opId)], frontier: made.parked?.frontier ?? [:])
        XCTAssertEqual(base.table, h.state.table, "a return's base is the re-created table")
    }

    /// A kind this build does not know cannot be created: no ops.
    func test_anUnknownKindHasNoOpeningOps() {
        let state = FigureState(kind: .unknown("chart"))
        XCTAssertTrue(FigureCarry.openingOps(
            for: record("fig-k3m9q2zt", "c", .unknown("chart"), piece: nil), state: state).isEmpty)
    }

    /// The parks the opening ops judge pins by: each parked figure's cycle.
    func test_parksAreEachParkedFiguresCycle() {
        var parked = FigureState(kind: .table)
        parked.parked = FigureParking(path: "research/x.csv", hash: "hx", itemId: "res-x")
        var byHash = FigureState(kind: .table)
        byHash.parked = FigureParking(path: "research/y.csv", hash: "hy")
        XCTAssertEqual(FigureCarry.parks(of: ["a": parked, "b": byHash, "c": FigureState(kind: .table)]),
                       ["a": "res-x", "b": "hy"])
    }

    // MARK: - What stays behind

    /// Formulas and pins reading Research that is not carried are listed,
    /// and so is a parked figure whose working copy stays; a read of a
    /// carried item or a carried figure is not.
    func test_leftBehindResearchReadsAreListed() throws {
        let w1 = record("fig-00000001", "w1", piece: nil)
        let w2 = record("fig-00000002", "w2", piece: nil)
        var s1 = reading([.research(id: "res-left"), .research(id: "res-kept"), .figure(id: w2.id)])
        let cell = try XCTUnwrap(s1.table.cells.keys.first)
        let at = Date(timeIntervalSince1970: 1)
        s1.pins[cell] = [
            FigureResearchPin(research: "res-left", row: 0, column: 0, value: .number(1), sourceHash: "a", at: at),
            FigureResearchPin(research: "res-kept", row: 0, column: 0, value: .number(2), sourceHash: "b", at: at),
            // A pin left by a formula since edited away: its source stays behind.
            FigureResearchPin(research: "res-stale", row: 0, column: 0, value: .number(3), sourceHash: "c", at: at),
            FigureResearchPin(research: w2.id, row: 0, column: 0, value: .number(4), sourceHash: "d", at: at,
                              park: "res-w2copy"),
        ]
        var s2 = FigureState(kind: .table)
        s2.parked = FigureParking(path: "research/w2.csv", hash: "h", itemId: "res-w2copy")
        let states = [w1.id: s1, w2.id: s2]
        let parks = FigureCarry.parks(of: states)

        let problems = FigureCarry.leftBehindReads(
            carried: [w1, w2], states: states, carriedResearch: ["res-kept"], parks: parks)
        XCTAssertEqual(problems, [
            FigureCarryProblem(figureId: w1.id, cell: cell, source: "res-left", read: .formula),
            FigureCarryProblem(figureId: w1.id, cell: cell, source: "res-left", read: .pin),
            FigureCarryProblem(figureId: w1.id, cell: cell, source: "res-stale", read: .pin),
            FigureCarryProblem(figureId: w2.id, cell: nil, source: "res-w2copy", read: .parkedCopy),
        ])

        let carriedCopy = FigureCarry.leftBehindReads(
            carried: [w2], states: states, carriedResearch: ["res-w2copy"], parks: parks)
        XCTAssertEqual(carriedCopy, [], "a carried working copy is no problem")
    }
}

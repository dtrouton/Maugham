import XCTest
@testable import MaughamCore

/// Report plan 6b Task 9 (spec §4.3, R-D2, ruling P-8): research pins — what a
/// figure reads through one, where each source stands, what Compare shows and
/// what Refresh writes; and a figure parked in Research read through its
/// reader's pin, else its parked state.
final class PinStatusTests: XCTestCase {

    private let research = "res-model01"
    private let parkedId = "fig-src00001"
    private let homeId = "fig-home0001"
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    // MARK: - Helpers

    private func key(_ t: FigureTable, _ a1: String) -> CellKey {
        let p = A1.parse(a1)!
        return CellKey(row: t.rows[p.row], column: t.columns[p.column])
    }

    private func formula(_ text: String, in t: FigureTable, figures: [String: FigureTable] = [:]) throws -> Formula {
        let names = FormulaNames(figures: figures.map { .init(id: $0.key, name: $0.key == parkedId ? "src" : $0.key, table: $0.value) },
                                 research: [(research, "model")])
        switch FormulaParser.parse(text, in: t, names: names) {
        case .success(let f): return f
        case .failure(let e): throw ParseFailed(e.message)
        }
    }

    private struct ParseFailed: Error { let m: String; init(_ m: String) { self.m = m } }

    /// A research table read as `values` (rows of numbers), hashed `hash`.
    private func source(_ hash: String, _ values: [[Double]]) -> PinSourceRead {
        PinSourceRead(hash: hash, values: values.map { $0.map { .number($0) } })
    }

    /// Folds `writes` onto `state` as `figurePinSet` ops carrying their prior pins.
    private func fold(_ writes: [PinWrite], into state: inout FigureState) {
        for w in writes {
            FigureDeriver.fold(Op(opId: ULID.generate(), docId: homeId, at: Date(), device: "d", session: "s",
                                  kind: .figurePinSet, changes: [],
                                  figure: FigureOpPayload(cell: w.cell, pin: w.pin, priorPin: w.prior)), into: &state)
        }
    }

    private func value(_ state: FigureState, _ a1: String, parked: [String: FigureState] = [:]) -> CellValue {
        var pins = FigurePinIndex()
        for (id, s) in parked { pins.setPark(s.parked?.cycle, figure: id) }
        pins.set(state.pins, home: homeId)
        var book = Workbook(pins: pins)
        for (id, s) in parked {
            if s.parked != nil { book.setParked(true, id: id) }
            book.setTable(s.table, id: id)
        }
        book.setTable(state.table, id: homeId)
        return book.value(at: CellAddress(table: homeId, key: key(state.table, a1)))
    }

    // MARK: - A Research table

    /// Entering a research formula takes its pins; the source edited elsewhere
    /// says changed, Compare lists old and new, Refresh writes pins carrying
    /// the ones they replace, and the value follows. Undoing those pins (each
    /// one's inverse) puts the old values back.
    func test_aResearchSourceChanged_comparesAndRefreshes_andTheInversePutsTheOldPinsBack() throws {
        var state = FigureState(kind: .table, table: FigureTable(rows: 3, columns: 3))
        let a1 = key(state.table, "A1")
        let f = try formula("SUM(research:model!B1:B2)", in: state.table)
        state.table.setCell(Cell(content: .formula(f)), at: a1)
        XCTAssertEqual(FigurePins.reads(of: f, in: state.table, parked: [:]),
                       [PinRead(source: research, row: 0, column: 1), PinRead(source: research, row: 1, column: 1)])

        let before = source("h1", [[0, 10], [0, 20]])
        let taken = FigurePins.entry(of: f, in: a1, state: state, sources: PinSources(research: [research: before]), at: t0)
        XCTAssertEqual(taken.map(\.pin.value), [.number(10), .number(20)])
        XCTAssertTrue(taken.allSatisfy { $0.prior == nil && $0.pin.sourceHash == "h1" && $0.pin.at == t0 })
        fold(taken, into: &state)
        XCTAssertEqual(value(state, "A1"), .number(30))
        XCTAssertEqual(FigurePins.status(of: state, sources: PinSources(research: [research: before])), [research: .current])
        XCTAssertEqual(FigurePins.entry(of: f, in: a1, state: state, sources: PinSources(research: [research: before]), at: t1), [],
                       "a cell already pinned takes nothing")

        let after = source("h2", [[0, 10], [0, 25]])
        let sources = PinSources(research: [research: after])
        XCTAssertEqual(FigurePins.status(of: state, sources: sources), [research: .sourceChanged(old: "h1", new: "h2")])
        XCTAssertEqual(FigurePins.compare(state: state, sources: sources), [
            PinComparison(cell: a1, read: PinRead(source: research, row: 1, column: 1), old: .number(20), new: .number(25)),
        ], "only the value that moves is compared")

        let writes = FigurePins.refresh(state: state, sources: sources, at: t1)
        XCTAssertEqual(writes.count, 2, "both pins move to the new hash")
        XCTAssertEqual(writes.map(\.prior?.sourceHash), ["h1", "h1"])
        XCTAssertEqual(writes.map(\.pin.value), [.number(10), .number(25)])
        let oldPins = state.pins
        fold(writes, into: &state)
        XCTAssertEqual(value(state, "A1"), .number(35))
        XCTAssertEqual(FigurePins.status(of: state, sources: sources), [research: .current])
        XCTAssertEqual(FigurePins.refresh(state: state, sources: sources, at: t1), [], "a second refresh writes nothing")

        // ⌘Z (ruling P-8): every pin set's inverse, last first.
        let visit = writes.map { (OpKind.figurePinSet, FigureOpPayload(cell: $0.cell, pin: $0.pin, priorPin: $0.prior)) }
        for (kind, payload) in FigureInverse.compensating(visit: visit) {
            FigureDeriver.fold(Op(opId: ULID.generate(), docId: homeId, at: Date(), device: "d", session: "s",
                                  kind: kind, changes: [], figure: payload), into: &state)
        }
        XCTAssertEqual(state.pins, oldPins)
        XCTAssertEqual(value(state, "A1"), .number(30))
    }

    /// A Research item that is gone keeps its pinned value, says missing, and
    /// a refresh writes nothing; Compare says there is no new value.
    func test_aMissingResearchSource_keepsItsValue_andRefreshWritesNothing() throws {
        var state = FigureState(kind: .table, table: FigureTable(rows: 2, columns: 2))
        let a1 = key(state.table, "A1")
        let f = try formula("research:model!A1*2", in: state.table)
        state.table.setCell(Cell(content: .formula(f)), at: a1)
        fold(FigurePins.entry(of: f, in: a1, state: state, sources: PinSources(research: [research: source("h1", [[4]])]), at: t0), into: &state)

        let gone = PinSources()
        XCTAssertEqual(FigurePins.status(of: state, sources: gone), [research: .sourceMissing])
        XCTAssertEqual(FigurePins.refresh(state: state, sources: gone, at: t1), [])
        XCTAssertEqual(FigurePins.compare(state: state, sources: gone), [
            PinComparison(cell: a1, read: PinRead(source: research, row: 0, column: 0), old: .number(4), new: nil),
        ])
        XCTAssertEqual(value(state, "A1"), .number(8), "the kept value stands")
        XCTAssertEqual(FigurePins.entry(of: f, in: key(state.table, "B2"), state: state, sources: PinSources(research: [:]), at: t1).map(\.pin.value),
                       [.number(4)], "a second cell reading the same source cell takes the figure's own pin")
    }

    // MARK: - A figure parked in Research (R-D2)

    /// A reader of a parked figure reads its parked state; the working copy
    /// edited says changed against the park's hash; Refresh pins the copy's
    /// value at the cell's position in the parked table and the reader shows
    /// it; once the figure comes back its live value wins and the pin is inert.
    func test_aParkedFiguresCopyChanged_saysSo_andRefreshReadsTheCopy_untilItComesBack() throws {
        var src = FigureState(kind: .table, table: FigureTable(rows: 2, columns: 2))
        src.table.setCell(Cell(content: .value(.number(7))), at: key(src.table, "B2"))
        let parking = FigureParking(path: "research/src.csv", hash: "p1", itemId: "res-copy0001")
        src.parked = parking
        var state = FigureState(kind: .table, table: FigureTable(rows: 2, columns: 2))
        let a1 = key(state.table, "A1")
        let f = try formula("src!B2+1", in: state.table, figures: [parkedId: src.table])
        state.table.setCell(Cell(content: .formula(f)), at: a1)
        XCTAssertEqual(value(state, "A1", parked: [parkedId: src]), .number(8), "no pin: the parked value")

        let parkedValues = PinSourceRead(hash: "p1", values: [[.empty, .empty], [.empty, .number(7)]])
        func sources(copy: PinSourceRead?) -> PinSources {
            PinSources(parked: [parkedId: .init(parking: parking, table: src.table, parkedValues: parkedValues, copy: copy)])
        }
        XCTAssertEqual(FigurePins.status(of: state, sources: sources(copy: parkedValues)), [parkedId: .current])
        XCTAssertEqual(FigurePins.refresh(state: state, sources: sources(copy: parkedValues), at: t0), [],
                       "an unchanged copy needs no pin")

        let edited = PinSourceRead(hash: "p2", values: [[.empty, .empty], [.empty, .number(70)]])
        XCTAssertEqual(FigurePins.status(of: state, sources: sources(copy: edited)),
                       [parkedId: .sourceChanged(old: "p1", new: "p2")])
        XCTAssertEqual(FigurePins.compare(state: state, sources: sources(copy: edited)), [
            PinComparison(cell: a1, read: PinRead(source: parkedId, row: 1, column: 1), old: .number(7), new: .number(70)),
        ])
        let writes = FigurePins.refresh(state: state, sources: sources(copy: edited), at: t1)
        XCTAssertEqual(writes.map(\.pin), [FigureResearchPin(research: parkedId, row: 1, column: 1, value: .number(70),
                                                              sourceHash: "p2", at: t1, park: "res-copy0001")])
        fold(writes, into: &state)
        XCTAssertEqual(value(state, "A1", parked: [parkedId: src]), .number(71), "the reader reads its pin on the copy")
        XCTAssertEqual(FigurePins.status(of: state, sources: sources(copy: edited)), [parkedId: .current])

        // The copy deleted: missing, the pinned value kept.
        XCTAssertEqual(FigurePins.status(of: state, sources: sources(copy: nil)), [parkedId: .sourceMissing])
        XCTAssertEqual(FigurePins.refresh(state: state, sources: sources(copy: nil), at: t1), [])
        XCTAssertEqual(value(state, "A1", parked: [parkedId: src]), .number(71))

        // Back from Research: its live value wins; the pin is inert, and no op is needed.
        var back = src
        back.parked = nil
        XCTAssertEqual(value(state, "A1", parked: [parkedId: back]), .number(8))
        XCTAssertEqual(FigurePins.status(of: state, sources: PinSources()), [:], "a live figure is no pin source")
    }

    // MARK: - The pin index and the workbook

    /// Two cells of one figure pinned to one source cell read the later-taken
    /// pin; the index answers which sources moved; `FigureWorkbook.overlay`
    /// recalculates the figure's readers when its pins change.
    func test_theIndexReadsTheLaterPin_andAnOverlayRecalculatesWhenPinsMove() throws {
        var index = FigurePinIndex()
        let t = FigureTable(rows: 2, columns: 2)
        let early = FigureResearchPin(research: research, row: 0, column: 0, value: .number(1), sourceHash: "h1", at: t0)
        let late = FigureResearchPin(research: research, row: 0, column: 0, value: .number(2), sourceHash: "h2", at: t1)
        XCTAssertEqual(index.set([key(t, "A1"): [late], key(t, "B1"): [early]], home: homeId), [research])
        XCTAssertEqual(index.pinnedValue(home: homeId, research: research, row: 0, column: 0), .number(2))
        XCTAssertNil(index.pinnedValue(home: "fig-other001", research: research, row: 0, column: 0))
        XCTAssertEqual(index.set([key(t, "A1"): [late]], home: homeId), [], "the value read did not move")
        XCTAssertEqual(index.set([:], home: homeId), [research])

        var state = FigureState(kind: .table, table: FigureTable(rows: 2, columns: 2))
        let a1 = key(state.table, "A1")
        state.table.setCell(Cell(content: .formula(try formula("research:model!A1", in: state.table))), at: a1)
        var book = FigureWorkbook(workbook: Workbook(pins: FigurePinIndex()), unreadable: [])
        book.overlay(state, id: homeId)
        XCTAssertEqual(book.workbook.value(at: CellAddress(table: homeId, key: a1)), .error(.ref), "no pin yet")
        state.pins[a1] = [early]
        book.overlay(state, id: homeId)
        XCTAssertEqual(book.workbook.value(at: CellAddress(table: homeId, key: a1)), .number(1))
        state.pins[a1] = [late]
        book.overlay(state, id: homeId)
        XCTAssertEqual(book.workbook.value(at: CellAddress(table: homeId, key: a1)), .number(2))
    }

    /// **A pin is bound to its park cycle** (review rule 1): park → refresh →
    /// resume → park again. The reader shows the NEW parked value, its status
    /// is current, and the old cycle's pin is inert everywhere — the index,
    /// status, Compare, Refresh — with no op written to clear it.
    func test_aPinFromAnEarlierParkIsInert_andTheReaderShowsTheNewParkedState() throws {
        var src = FigureState(kind: .table, table: FigureTable(rows: 2, columns: 2))
        let b2 = key(src.table, "B2")
        src.table.setCell(Cell(content: .value(.number(7))), at: b2)
        let first = FigureParking(path: "research/src.csv", hash: "p1", itemId: "res-copy0001")
        src.parked = first
        var state = FigureState(kind: .table, table: FigureTable(rows: 2, columns: 2))
        let a1 = key(state.table, "A1")
        state.table.setCell(Cell(content: .formula(try formula("src!B2+1", in: state.table, figures: [parkedId: src.table]))), at: a1)
        func sources(_ src: FigureState, copy: [[CellValue]], hash: String) -> PinSources {
            PinSources(parked: [parkedId: .init(
                parking: src.parked!, table: src.table,
                parkedValues: PinSourceRead(hash: src.parked!.hash, values: [[.empty, .empty], [.empty, src.table[b2].flatMap {
                    if case .value(let v) = $0.content { return v } else { return nil } } ?? .empty]]),
                copy: PinSourceRead(hash: hash, values: copy))])
        }
        // Cycle one: the copy edited to 70, refreshed.
        fold(FigurePins.refresh(state: state, sources: sources(src, copy: [[.empty, .empty], [.empty, .number(70)]], hash: "p2"),
                                at: t0), into: &state)
        XCTAssertEqual(state.pins[a1]?.first?.park, "res-copy0001")
        XCTAssertEqual(value(state, "A1", parked: [parkedId: src]), .number(71))

        // Brought back with 9, then sent again: a new copy item, a new cycle.
        src.parked = nil
        src.table.setCell(Cell(content: .value(.number(9))), at: b2)
        XCTAssertEqual(value(state, "A1", parked: [parkedId: src]), .number(10), "back: live wins")
        src.parked = FigureParking(path: "research/src 2.csv", hash: "q1", itemId: "res-copy0002")
        let second = sources(src, copy: [[.empty, .empty], [.empty, .number(9)]], hash: "q1")
        XCTAssertEqual(value(state, "A1", parked: [parkedId: src]), .number(10),
                       "parked again: the new parked value, not cycle one's pin")
        XCTAssertEqual(FigurePins.status(of: state, sources: second), [parkedId: .current])
        XCTAssertEqual(FigurePins.compare(state: state, sources: second), [])
        XCTAssertEqual(FigurePins.refresh(state: state, sources: second, at: t1), [], "no op clears the old pin")
        XCTAssertEqual(state.pins[a1]?.first?.park, "res-copy0001", "it stays, inert")

        // And the workbook's index agrees when an overlay moves the park.
        var book = FigureWorkbook(workbook: Workbook(pins: FigurePinIndex()), unreadable: [])
        var cycleOne = src
        cycleOne.parked = first
        book.overlay(cycleOne, id: parkedId)
        book.overlay(state, id: homeId)
        XCTAssertEqual(book.workbook.value(at: CellAddress(table: homeId, key: a1)), .number(71))
        book.overlay(src, id: parkedId)
        XCTAssertEqual(book.workbook.value(at: CellAddress(table: homeId, key: a1)), .number(10),
                       "re-parked: the reader recalculates to the new parked value")
    }

    /// **SUMIF whose criteria range is a live figure pins its whole sum block**
    /// (review rule 2): the shape comes from the book's tables, the values
    /// only from Research.
    func test_aSUMIFOverALiveFiguresCriteria_pinsItsSumBlock() throws {
        let otherId = "other"  // the helper names a figure by its id
        var other = FigureTable(rows: 3, columns: 1)
        for (i, v) in [1.0, -1, 1].enumerated() {
            other.setCell(Cell(content: .value(.number(v))), at: CellKey(row: other.rows[i], column: other.columns[0]))
        }
        var state = FigureState(kind: .table, table: FigureTable(rows: 1, columns: 1))
        let a1 = key(state.table, "A1")
        let f = try formula("SUMIF(\(otherId)!A1:A3,\">0\",research:model!B1)", in: state.table, figures: [otherId: other])
        state.table.setCell(Cell(content: .formula(f)), at: a1)
        let model = source("h1", [[0, 10], [0, 20], [0, 30]])
        let sources = PinSources(research: [research: model], tables: [otherId: other])
        let taken = FigurePins.entry(of: f, in: a1, state: state, sources: sources, at: t0)
        XCTAssertEqual(taken.map { [$0.pin.row, $0.pin.column] }, [[0, 1], [1, 1], [2, 1]])
        fold(taken, into: &state)
        var pins = FigurePinIndex()
        pins.set(state.pins, home: homeId)
        var book = Workbook(pins: pins)
        book.setTable(other, id: otherId)
        book.setTable(state.table, id: homeId)
        XCTAssertEqual(book.value(at: CellAddress(table: homeId, key: a1)), .number(40))
        let edited = PinSources(research: [research: source("h2", [[0, 10], [0, 20], [0, 35]])], tables: [otherId: other])
        XCTAssertEqual(FigurePins.refresh(state: state, sources: edited, at: t1).map(\.pin.row), [0, 1, 2],
                       "refresh re-reads the whole block")
    }

    /// **One rule picks the pin** (review rule 3): two cells pinned to one
    /// source cell in the same second with different values — the index and
    /// Compare's "old" agree, by cell key, then hash, whatever order the
    /// dictionary holds them in.
    func test_aTieIsBrokenTheSameWayByTheIndexAndByCompare() throws {
        var state = FigureState(kind: .table, table: FigureTable(rows: 2, columns: 2))
        let f = try formula("research:model!A1", in: state.table)
        let cells = [key(state.table, "A1"), key(state.table, "B2")]
        for c in cells { state.table.setCell(Cell(content: .formula(f)), at: c) }
        let first = cells.min { ($0.row.raw, $0.column.raw) < ($1.row.raw, $1.column.raw) }!
        let last = cells.first { $0 != first }!
        state.pins[first] = [FigureResearchPin(research: research, row: 0, column: 0, value: .number(1), sourceHash: "a", at: t0)]
        state.pins[last] = [FigureResearchPin(research: research, row: 0, column: 0, value: .number(2), sourceHash: "z", at: t0)]
        var pins = FigurePinIndex()
        pins.set(state.pins, home: homeId)
        XCTAssertEqual(pins.pinnedValue(home: homeId, research: research, row: 0, column: 0), .number(1), "the earlier cell wins")
        let compared = FigurePins.compare(state: state, sources: PinSources(research: [research: source("n", [[5]])]))
        XCTAssertEqual(compared.map(\.old), [.number(1)])
        // Same cell key cannot hold two pins on one source cell; the hash breaks
        // a tie between equal times on one cell order only through `wins`.
        let a = FigureResearchPin(research: research, row: 0, column: 0, value: .number(1), sourceHash: "a", at: t0)
        let z = FigureResearchPin(research: research, row: 0, column: 0, value: .number(2), sourceHash: "z", at: t0)
        XCTAssertTrue(FigurePinChoice.wins(z, on: first, over: a, on: first))
        XCTAssertFalse(FigurePinChoice.wins(a, on: first, over: z, on: first))
    }

    /// A pin's time is kept to the whole second, so the one read back from the
    /// op log (milliseconds) equals the one written.
    func test_aPinsTimeIsWholeSeconds() throws {
        var state = FigureState(kind: .table, table: FigureTable(rows: 1, columns: 1))
        let a1 = key(state.table, "A1")
        let f = try formula("research:model!A1", in: state.table)
        state.table.setCell(Cell(content: .formula(f)), at: a1)
        let taken = FigurePins.entry(of: f, in: a1, state: state, sources: PinSources(research: [research: source("h", [[1]])]),
                                     at: Date(timeIntervalSince1970: 1_000.75))
        XCTAssertEqual(taken.map(\.pin.at), [Date(timeIntervalSince1970: 1_000)])
    }

    /// A Research CSV's formula is read as a figure's would be: its value, not
    /// its text, is what a pin takes.
    func test_aSourceReadComputesItsFormulas() throws {
        var t = FigureTable(rows: 1, columns: 2)
        t.setCell(Cell(content: .value(.number(3))), at: key(t, "A1"))
        t.setCell(Cell(content: .formula(try formula("A1*4", in: t))), at: key(t, "B1"))
        let read = PinSourceRead(hash: "h", table: t, book: Workbook(pins: FigurePinIndex()), as: "research:x")
        XCTAssertEqual(read.value(row: 0, column: 1), .number(12))
        XCTAssertNil(read.value(row: 1, column: 0), "off the grid")
    }
}

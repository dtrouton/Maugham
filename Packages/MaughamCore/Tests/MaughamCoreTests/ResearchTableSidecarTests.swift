import XCTest
@testable import MaughamCore

/// Report plan 6b Task 6 (ruling P-4): a Research table's sidecar — its shape,
/// its tolerance, and where it lives.
final class ResearchTableSidecarTests: XCTestCase {

    private let full = ResearchTableSidecar(
        figureId: "fig-cash0001", contentHash: "0123456789abcdef", name: "cash", caption: "Cash, 2026",
        headerRows: 1, totalRow: true,
        formats: [.init(row: 1, column: 2, format: CellFormat(number: .percent(decimals: 1)),
                        alignment: .right)],
        columnWidths: [80, nil, 120])

    func test_roundTripsThroughDisk_atTheItemsIdUnderTheResearchTablesFolder() throws {
        let root = TestTemp.root
        try ResearchTableSidecar.write(full, forItem: "res-1a2b3c4d", in: root)
        let file = root.appendingPathComponent(".maugham/research-tables/res-1a2b3c4d.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try ResearchTableSidecar.read(forItem: "res-1a2b3c4d", in: root), full)
        XCTAssertNil(try ResearchTableSidecar.read(forItem: "res-none0000", in: root),
                     "no file is no sidecar")
    }

    func test_theWireWords() throws {
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(full), encoding: .utf8))
        for key in ["\"figure_id\"", "\"content_hash\"", "\"header_rows\"", "\"total_row\"", "\"column_widths\"",
                    "\"formats\"", "\"caption\"", "\"name\""] {
            XCTAssertTrue(json.contains(key), "\(key) in \(json)")
        }
    }

    /// Missing fields take their defaults; a field of the wrong type takes its
    /// default; one unreadable style drops only that style; an unknown key is
    /// ignored.
    func test_decodesTolerantly() throws {
        let empty = try JSONDecoder().decode(ResearchTableSidecar.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, ResearchTableSidecar())

        let odd = Data("""
        {"figure_id": 7, "name": "cash", "header_rows": "one", "total_row": true,
         "formats": [{"row": 0, "column": 0, "alignment": "right"}, {"row": "x"},
                     {"row": 2, "column": 1, "alignment": "sideways"}],
         "column_widths": [40, null], "from_a_later_build": {"x": 1}}
        """.utf8)
        let s = try JSONDecoder().decode(ResearchTableSidecar.self, from: odd)
        XCTAssertNil(s.figureId, "a figure id of the wrong type is no figure id")
        XCTAssertEqual(s.name, "cash")
        XCTAssertEqual(s.headerRows, 0)
        XCTAssertTrue(s.totalRow)
        XCTAssertEqual(s.formats, [.init(row: 0, column: 0, alignment: .right),
                                   .init(row: 2, column: 1, alignment: .automatic)])
        XCTAssertEqual(s.columnWidths, [40, nil])
    }

    /// The item id comes from the synced manifest: one that could leave the
    /// folder, or carries a dot, never names a file (tripwire 58).
    func test_anItemIdThatCannotNameAFileIsRefused() {
        let root = TestTemp.root
        for bad in ["../escape", "a/b", "res.x", "", ".hidden"] {
            XCTAssertThrowsError(try ResearchTableSidecar.fileURL(forItem: bad, in: root), bad)
            XCTAssertThrowsError(try ResearchTableSidecar.write(full, forItem: bad, in: root), bad)
        }
    }

    /// A `.maugham/research-tables` linked out of the project is refused, so a
    /// write never lands outside it.
    func test_aFolderLinkedOutOfTheProjectIsRefused() throws {
        let root = TestTemp.root.appendingPathComponent("book")
        let outside = TestTemp.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".maugham"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".maugham/research-tables"), withDestinationURL: outside)
        XCTAssertThrowsError(try ResearchTableSidecar.write(full, forItem: "res-1a2b3c4d", in: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    /// Review M-1: the settings land on the table at their positions; a style or
    /// width off the grid, or on an empty cell, is skipped.
    func test_appliedLaysTheSettingsOnByPosition() {
        var table = FigureTable(rows: 2, columns: 2)
        let b2 = CellKey(row: table.rows[1], column: table.columns[1])
        table.setCell(Cell(content: .value(.number(0.25))), at: b2)
        let sidecar = ResearchTableSidecar(
            headerRows: 1, totalRow: true,
            formats: [.init(row: 1, column: 1, format: CellFormat(number: .percent(decimals: 1)), alignment: .right),
                      .init(row: 0, column: 0, alignment: .center),
                      .init(row: 9, column: 9, alignment: .left)],
            columnWidths: [nil, 120, 50])
        let out = sidecar.applied(to: table)
        XCTAssertEqual(out.headerRows, 1)
        XCTAssertTrue(out.hasTotalRow)
        XCTAssertEqual(out[b2]?.format, CellFormat(number: .percent(decimals: 1)))
        XCTAssertEqual(out[b2]?.alignment, .right)
        XCTAssertNil(out[CellKey(row: table.rows[0], column: table.columns[0])])
        XCTAssertEqual(out.columnWidths, [table.columns[1]: 120])
    }

    /// Report plan 6b Task 7: the sidecar a park writes is `applied(to:)`'s
    /// inverse — styles only where a cell has a non-default one, widths by
    /// position (none at all when no column has one), and the figure's id,
    /// name, caption and CSV hash.
    func test_whatAParkWritesIsWhatAppliedLaysBackOn() {
        var table = FigureTable(rows: 2, columns: 2)
        let a1 = CellKey(row: table.rows[0], column: table.columns[0])
        let b2 = CellKey(row: table.rows[1], column: table.columns[1])
        table.setCell(Cell(content: .value(.text("Item"))), at: a1)
        var styled = Cell(content: .value(.number(0.25)))
        styled.format = CellFormat(number: .percent(decimals: 1))
        styled.alignment = .right
        table.setCell(styled, at: b2)
        table.headerRows = 1
        table.hasTotalRow = true
        table.columnWidths[table.columns[1]] = 120

        let sidecar = ResearchTableSidecar(
            figureId: "fig-0a1b2c3d", contentHash: "0123456789abcdef", name: "cash", caption: "Cash",
            table: table)
        XCTAssertEqual(sidecar.figureId, "fig-0a1b2c3d")
        XCTAssertEqual(sidecar.contentHash, "0123456789abcdef")
        XCTAssertEqual(sidecar.name, "cash")
        XCTAssertEqual(sidecar.caption, "Cash")
        XCTAssertEqual(sidecar.formats, [.init(row: 1, column: 1, format: CellFormat(number: .percent(decimals: 1)),
                                               alignment: .right)])
        XCTAssertEqual(sidecar.columnWidths, [nil, 120])

        var plain = table
        plain.setCell(Cell(content: .value(.number(0.25))), at: b2)
        plain.headerRows = 0
        plain.hasTotalRow = false
        plain.columnWidths = [:]
        XCTAssertEqual(sidecar.applied(to: plain), table, "laid back on the bare CSV's table, it is the figure again")
        XCTAssertEqual(ResearchTableSidecar(
            figureId: "f", contentHash: "h", name: "n", caption: nil, table: plain).columnWidths, [])
    }
}

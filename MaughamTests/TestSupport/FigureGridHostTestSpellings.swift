import AppKit
import MaughamCore
@testable import Maugham

/// **The undo-less spellings the figure-grid tests write with** through
/// `FigureGridController.host` (`any FigureGridHost`), as `FigureDocument`'s
/// default arguments gave them before the host seam (report plan 8b Task 6).
/// Test-only: no production host carries an undo-less writer.
extension FigureGridHost {
    func setCell(_ cell: Cell?, at key: CellKey) async throws {
        try await setCell(cell, at: key, undoManager: nil)
    }

    func setHeaderRows(_ rows: Int) async throws {
        try await setHeaderRows(rows, undoManager: nil)
    }

    func deleteRow(_ id: RowID) async throws {
        try await deleteRow(id, undoManager: nil)
    }

    func deleteColumn(_ id: ColumnID) async throws {
        try await deleteColumn(id, undoManager: nil)
    }
}


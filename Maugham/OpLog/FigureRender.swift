import Foundation
import MaughamCore

/// **A table figure's derived render: `figures/<name>.csv`** (report plan 6a
/// Task 7). The computed values — formulas evaluated through the book's
/// `Workbook` — as `TableCSV.render` writes them, at the registry record's
/// `path`.
///
/// - **Written, never read** (tripwire 20): the op log is the table's truth.
///   An edit made to the file outside Maugham (Excel, a text editor) is
///   overwritten by the next render and never folds into the table — the
///   `.md` render's policy (ADR 0012), for a table.
/// - **Through `DocumentStore.coordinatedWrite`**, so the write is
///   coordinated with the window's presenter and is never mistaken for
///   somebody else's change.
/// - **An image figure, a parked table and a figure whose kind this build
///   does not know render nothing**: the image's file is its own, a parked
///   table lives in Research (plan 6b), and an unknown kind has no CSV shape.
/// - Research references read no pins until plan 6b Task 9 wires them
///   (`noResearchPins`): such a cell renders `#REF!`.
@MainActor
enum FigureRender {

    /// The pin source until plan 6b Task 9: every research reference is `#REF!`.
    struct NoResearchPins: ResearchPinSource {
        func pinnedValue(home: String, research: String, row: Int, column: Int) -> CellValue? { nil }
    }
    static let noResearchPins = NoResearchPins()

    /// The CSV `record` renders to, or nil when it renders nothing (an image,
    /// a parked or unknown-kind figure). The table is set into a copy of
    /// `workbook` under the record's id first, so the values are this
    /// `state`'s even when the workbook was assembled from an older read.
    static func csv(record: FigureRecord, state: FigureState, workbook: Workbook) -> String? {
        guard record.kind == .table, state.kind == .table, state.parked == nil else { return nil }
        var book = workbook
        book.setTable(state.table, id: record.id)
        return TableCSV.render(state.table) {
            book.value(at: CellAddress(table: record.id, key: $0))
        }
    }

    /// The render's project-relative path, or nil when the record's `path` is
    /// not one this render may write: exactly `figures/<file>.csv`, where
    /// `<file>` is one plain file name (`SafeRelativePath.isPlainFileName`,
    /// the one rule) with a stem before `.csv`. A record synced from another
    /// device is data, so its path is checked before anything is written.
    static func renderPath(of record: FigureRecord) -> String? {
        let parts = record.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == Substring(ProjectStore.figuresFolder),
              let file = parts.last.map(String.init), file.count > 4, file.hasSuffix(".csv"),
              SafeRelativePath.isPlainFileName(file) else { return nil }
        return record.path
    }

    /// **Write `record`'s render**, or nothing when it renders nothing.
    /// Answers whether a file was written. Throws a write failure; a path this
    /// render may not write throws `FigureRenderPathRefused`.
    @discardableResult
    static func render(
        record: FigureRecord, state: FigureState, workbook: Workbook,
        documentStore: DocumentStore
    ) async throws -> Bool {
        guard let text = csv(record: record, state: state, workbook: workbook) else { return false }
        guard let path = renderPath(of: record) else {
            throw FigureRenderPathRefused(name: record.name, path: record.path)
        }
        let folder = documentStore.projectURL.appendingPathComponent(
            ProjectStore.figuresFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // `renderPath` spelled it; the disk is asked too, so a `figures/`
        // linked out of the book is refused (tripwire 58).
        guard let destination = try? SafeRelativePath.resolveForChange(
            path, under: documentStore.projectURL) else {
            throw FigureRenderPathRefused(name: record.name, path: record.path)
        }
        try await documentStore.coordinatedWrite(text: text, to: destination)
        return true
    }
}

/// A figure record whose `path` is not `figures/<file>.csv`: nothing written.
struct FigureRenderPathRefused: LocalizedError, Equatable {
    let name: String
    let path: String
    var errorDescription: String? {
        "the table \(name) names \(path), which is not a file in the figures folder, so it was not written"
    }
}

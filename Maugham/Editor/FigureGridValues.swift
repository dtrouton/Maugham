import Foundation
import MaughamCore

/// **The in-place grid's computed values** (report plan 7c Task 3, R7c-9): one figure's
/// cells as the book computes them, and the display string each shows, kept in memory for
/// the visit.
///
/// The whole book is assembled once — at expand (`reseed()`) and again only on a
/// `figureCardVersion` edge, when another figure may have changed what this one reads. A
/// host state change in between (`advance(to:)`) lays the new state over the held book
/// (`FigureWorkbook.overlay` → `Workbook.setTable`, incremental), recalculating only the
/// cells that read what changed. It observes nothing itself: the grid's controller calls
/// both, and repaints what the returned `Repaint` names (`keys(visibleRows:in:)`).
@MainActor
final class FigureGridValues {
    /// What a view must repaint after `advance(to:)` or `reseed()`.
    enum Repaint: Equatable {
        case none
        /// These cells' values or formats changed (keys of this figure).
        case cells(Set<CellKey>)
        /// Rows or columns moved, came or went, the header or total row changed, or the
        /// book was seeded: every visible cell.
        case everything

        /// The visible cells to repaint, for live rows `rows` of `table`; nil means every
        /// visible cell.
        func keys(visibleRows rows: Range<Int>, in table: FigureTable) -> Set<CellKey>? {
            switch self {
            case .none: return []
            case .everything: return nil
            case .cells(let keys):
                return keys.filter { key in table.rowIndex(of: key.row).map(rows.contains) ?? false }
            }
        }
    }

    let figureId: String
    let locale: TableLocale
    /// The host's state the values were last advanced to.
    private(set) var state: FigureState
    var table: FigureTable { state.table }

    private let assemble: @MainActor () async throws -> FigureWorkbook?
    private var book: FigureWorkbook?
    private var displays: [CellKey: String] = [:]
    private var seedGeneration = 0

    /// `assemble` builds the whole book (`DocumentStore.assembledFigures()`); it is called
    /// by `reseed()` only, never per commit.
    init(figureId: String, state: FigureState, locale: TableLocale,
         assemble: @escaping @MainActor () async throws -> FigureWorkbook?) {
        self.figureId = figureId
        self.state = state
        self.locale = locale
        self.assemble = assemble
    }

    convenience init(figureId: String, state: FigureState, locale: TableLocale, store: DocumentStore) {
        self.init(figureId: figureId, state: state, locale: locale) { [weak store] in
            try await store?.assembledFigures()
        }
    }

    /// Whether a book has been assembled; before it, a formula cell shows nothing.
    var isSeeded: Bool { book != nil }

    /// The cell's computed value: a formula's result, a value cell's value, `.empty` for none.
    func value(at key: CellKey) -> CellValue {
        if let book { return book.workbook.value(at: CellAddress(table: figureId, key: key)) }
        if case .value(let v)? = table[key]?.content { return v }
        return .empty
    }

    /// What the cell shows: its value in its format, in the book's language. Cached until the
    /// cell's value or format changes (tripwire 4: drawing reads strings, never computes them).
    func display(at key: CellKey) -> String {
        if let hit = displays[key] { return hit }
        let shown = CellDisplay.string(for: value(at: key), format: table[key]?.format ?? CellFormat(), locale: locale)
        displays[key] = shown
        return shown
    }

    /// **The host's state changed**: lay it over the held book. Recalculates only the cells
    /// that read what changed; assembles nothing.
    @discardableResult
    func advance(to next: FigureState) -> Repaint {
        guard next != state else { return .none }
        let previous = state.table
        state = next
        if Self.isStructural(previous, next.table) || book == nil {
            if book != nil { book?.overlay(next, id: figureId) }
            displays.removeAll()
            return .everything
        }
        var keys = Set(book?.overlay(next, id: figureId).compactMap { $0.table == figureId ? $0.key : nil } ?? [])
        keys.formUnion(Self.restyled(previous, next.table))
        guard !keys.isEmpty else { return .none }
        for key in keys { displays[key] = nil }
        return .cells(keys)
    }

    /// **Assemble the whole book again** (at expand, and on a `figureCardVersion` edge), the
    /// host's latest state laid over it. Answers the cells whose values changed against the
    /// book held before, or `.everything` for the first seed. A reseed overtaken by a later
    /// one answers `.none` and changes nothing.
    @discardableResult
    func reseed() async throws -> Repaint {
        seedGeneration += 1
        let generation = seedGeneration
        guard var fresh = try await assemble(), generation == seedGeneration else { return .none }
        // `advance` may have run during the await: the latest state wins.
        fresh.overlay(state, id: figureId)
        guard let old = book else {
            book = fresh
            displays.removeAll()
            return .everything
        }
        var keys = Set<CellKey>()
        for key in table.cells.keys {
            let address = CellAddress(table: figureId, key: key)
            if old.workbook.value(at: address) != fresh.workbook.value(at: address) { keys.insert(key) }
        }
        book = fresh
        guard !keys.isEmpty else { return .none }
        for key in keys { displays[key] = nil }
        return .cells(keys)
    }

    // MARK: - Private

    /// A change that moves cells to other positions or changes how whole rows draw.
    private static func isStructural(_ a: FigureTable, _ b: FigureTable) -> Bool {
        a.rowSlots != b.rowSlots || a.columnSlots != b.columnSlots
            || a.headerRows != b.headerRows || a.hasTotalRow != b.hasTotalRow
    }

    /// Cells whose format or alignment changed with the same content (`setTable` reports values only).
    private static func restyled(_ a: FigureTable, _ b: FigureTable) -> Set<CellKey> {
        var keys = Set<CellKey>()
        for (key, cell) in b.cells {
            guard let old = a.cells[key] else { continue }
            if old.format != cell.format || old.alignment != cell.alignment { keys.insert(key) }
        }
        for (key, old) in a.cells where b.cells[key] == nil && (old.format != CellFormat() || old.alignment != .automatic) {
            keys.insert(key)
        }
        return keys
    }
}

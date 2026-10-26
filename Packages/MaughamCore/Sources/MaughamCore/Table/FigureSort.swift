import Foundation

/// **Sort a table figure's rows by one column** (report plan 7c, ruling
/// R7c-7). Pure: the caller hands the computed value of each cell (a
/// formula's result, not its text), and `FigureDocument.sortRows` turns the
/// answer into row moves — formulas move with their rows, since references
/// are by id.
public enum FigureSort {

    /// The table's live rows in sorted order, header and total rows where they
    /// are (the first `headerRows`, and the last when `hasTotalRow`), the body
    /// between them sorted by `column`:
    /// - **ascending**, numbers < dates < text < booleans < errors < empty;
    ///   descending reverses that, except that **empty cells stay last**
    ///   either way (a sort never floats the blanks to the top);
    /// - numbers and dates by value, text case-insensitively with digit runs
    ///   read as numbers ("Item 2" before "Item 10"), false before true;
    /// - **stable**: rows whose values compare equal keep their order, in
    ///   either direction.
    public static func order(
        table: FigureTable, values: (CellKey) -> CellValue, column: ColumnID, ascending: Bool
    ) -> [RowID] {
        let rows = table.rows
        let head = min(table.headerRows, rows.count)
        let bodyEnd = rows.count - (table.hasTotalRow && rows.count > head ? 1 : 0)
        let body = rows[head..<bodyEnd].enumerated().map { offset, row in
            (offset: offset, row: row, value: values(CellKey(row: row, column: column)))
        }
        let sorted = body.sorted { a, b in
            switch compare(a.value, b.value, ascending: ascending) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.offset < b.offset
            }
        }
        var out = Array(rows[..<head])
        out += sorted.map(\.row)
        out += rows[bodyEnd...]
        return out
    }

    /// Where `a` sorts against `b` in the asked direction.
    static func compare(_ a: CellValue, _ b: CellValue, ascending: Bool) -> ComparisonResult {
        let ra = rank(a), rb = rank(b)
        // Empty is last whichever way the sort runs.
        if ra == emptyRank || rb == emptyRank {
            return ra == rb ? .orderedSame : (ra == emptyRank ? .orderedDescending : .orderedAscending)
        }
        let natural: ComparisonResult = ra != rb
            ? (ra < rb ? .orderedAscending : .orderedDescending)
            : sameKind(a, b)
        guard !ascending else { return natural }
        switch natural {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private static let emptyRank = 5

    private static func rank(_ v: CellValue) -> Int {
        switch v {
        case .number: 0
        case .date: 1
        case .text: 2
        case .bool: 3
        case .error: 4
        case .empty: emptyRank
        }
    }

    private static func sameKind(_ a: CellValue, _ b: CellValue) -> ComparisonResult {
        switch (a, b) {
        case let (.number(x), .number(y)): ordered(x, y)
        case let (.date(x), .date(y)): ordered(x, y)
        case let (.text(x), .text(y)): x.compare(y, options: [.caseInsensitive, .numeric])
        case let (.bool(x), .bool(y)): ordered(x ? 1 : 0, y ? 1 : 0)
        default: .orderedSame
        }
    }

    private static func ordered<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
        x < y ? .orderedAscending : (y < x ? .orderedDescending : .orderedSame)
    }
}

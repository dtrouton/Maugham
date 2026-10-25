import Foundation

/// A cell of a CSV that could not be read as the writer meant it (0-based position).
public struct CSVReadProblem: Equatable, Sendable {
    public let row: Int
    public let column: Int
    public let message: String
    public init(row: Int, column: Int, message: String) {
        self.row = row
        self.column = column
        self.message = message
    }
}

/// A table as CSV: the clean values render, research copies that keep their formulas, and reading.
/// Total: no input traps.
public enum TableCSV {
    // MARK: Writing

    /// The computed values by live order: numbers POSIX with no grouping (integers without ".0", else
    /// up to 15 significant digits), dates ISO, TRUE/FALSE, error codes, "" for empty.
    public static func render(_ table: FigureTable, value: (CellKey) -> CellValue) -> String {
        write(table) { text(value($0)) }
    }

    /// A research copy: formulas as "=" + their A1 text, values as in `render`. A text value that
    /// would not read back as exactly that text (a number, date, TRUE, a formula, padding) under the
    /// book's `locale` or POSIX gets the "'" escape. `names` gives every figure and research item a
    /// formula reads its current name: one missing from it renders as `#REF!` in the file, so it has no default.
    public static func renderResearch(_ table: FigureTable, locale: TableLocale, names: FormulaNames) -> String {
        let readers = [posix, locale, locale.readingDecimalPoint()]
        return write(table) { key in
            guard let cell = table[key] else { return "" }
            switch cell.content {
            case .formula(let f): return "=" + FormulaParser.render(f, in: table, names: names)
            case .value(.text(let s)): return readsBackVerbatim(s, under: readers) ? s : "'" + s
            case .value(let v): return text(v)
            }
        }
    }

    private static let posix = TableLocale(languageTag: "en-US")

    private static func readsBackVerbatim(_ s: String, under readers: [TableLocale]) -> Bool {
        if s.isEmpty { return true }
        return readers.allSatisfy { CellInput.parse(s, locale: $0) == .value(.text(s), suggested: nil) }
    }

    private static func write(_ table: FigureTable, field: (CellKey) -> String) -> String {
        var out = ""
        let columns = table.columns
        for row in table.rows {
            out += columns.map { quote(field(CellKey(row: row, column: $0))) }.joined(separator: ",")
            out += "\n"
        }
        return out
    }

    private static func text(_ v: CellValue) -> String {
        switch v {
        case .empty: return ""
        case .number(let x): return FormulaParser.numberText(x)
        case .date(let s): return DateSerial.isoString(s)
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e.rawValue
        }
    }

    private static func quote(_ s: String) -> String {
        let needs = s.unicodeScalars.contains { $0 == "," || $0 == ";" || $0 == "\t" || $0 == "\"" || $0 == "\r" || $0 == "\n" }
            || s.hasPrefix(" ") || s.hasSuffix(" ")
        return needs ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    // MARK: Reading rows

    /// RFC 4180 rows. Strips a UTF-8 BOM. The separator is the most frequent of "," ";" "\t" on the
    /// first line outside quotes (a tie or none is ","). A quote opens a quoted field only at a field's start.
    public static func rows(_ text: String) -> (rows: [[String]], separator: Character) {
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        let sep = detectSeparator(scalars)
        let sepScalar = sep.unicodeScalars.first!
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var rowOpen = false
        var i = 0

        func endField() { row.append(String(field)); field = String.UnicodeScalarView() }
        func endRow() { endField(); rows.append(row); row = []; rowOpen = false }

        while i < scalars.count {
            let c = scalars[i]
            if c == "\"" && field.isEmpty {
                rowOpen = true
                i += 1
                while i < scalars.count {
                    if scalars[i] == "\"" {
                        if i + 1 < scalars.count && scalars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                        i += 1
                        break
                    }
                    field.append(scalars[i]); i += 1
                }
                // Text after the closing quote joins the field.
                while i < scalars.count, scalars[i] != sepScalar, scalars[i] != "\n", scalars[i] != "\r" {
                    field.append(scalars[i]); i += 1
                }
                continue
            }
            if c == sepScalar { rowOpen = true; endField(); i += 1; continue }
            if c == "\r" || c == "\n" {
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                endRow(); i += 1; continue
            }
            rowOpen = true
            field.append(c); i += 1
        }
        if rowOpen { endRow() }
        return (rows, sep)
    }

    private static func detectSeparator(_ scalars: [Unicode.Scalar]) -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for c in scalars {
            if c == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if c == "\n" || c == "\r" { break }
            let ch = Character(c)
            if counts[ch] != nil { counts[ch]! += 1 }
        }
        let best = counts.values.max() ?? 0
        guard best > 0 else { return "," }
        let winners = counts.filter { $0.value == best }.map(\.key)
        return winners.count == 1 ? winners[0] : ","
    }

    // MARK: Reading a table

    /// Reads a CSV into a new table. Cells go through `CellInput` with `locale` (a ";" file reads
    /// decimals with ","); "=" cells go through `FormulaParser.parsePositional`, which turns each
    /// figure and research name into its id through `names` (R-D1); then refs inside the new table,
    /// and `name!B2` refs inside a figure with a table in `names` (by its live positions), become id
    /// refs, so later inserts and deletes never re-point them. A ref off a grid stays positional
    /// (`#REF!` while off it). An unparseable formula — an unknown or shared name included —
    /// becomes text holding its "=…" and a problem. `headerRows` is 1 when the first row is text only and a later row holds a number.
    public static func read(_ text: String, locale: TableLocale,
                            names: FormulaNames) -> (table: FigureTable, problems: [CSVReadProblem]) {
        let (parsed, separator) = rows(text)
        let width = parsed.map(\.count).max() ?? 0
        var table = FigureTable(rows: parsed.count, columns: width)
        let ids = (rows: table.rows, columns: table.columns)
        let cellLocale = separator == ";" ? locale.readingDecimalComma() : locale.readingDecimalPoint()
        var problems: [CSVReadProblem] = []
        var entries: [[CellEntry]] = []

        for (r, raw) in parsed.enumerated() {
            var line: [CellEntry] = []
            for c in 0..<width {
                let field = c < raw.count ? raw[c] : ""
                // The "'" escape keeps the rest verbatim, padding included.
                var entry = field.hasPrefix("'") ? CellEntry.value(.text(String(field.dropFirst())), suggested: nil)
                                                 : CellInput.parse(field, locale: cellLocale)
                var content: CellContent?
                var format = CellFormat()
                switch entry {
                case .empty:
                    break
                case .value(let v, let suggested):
                    content = .value(v)
                    if let suggested { format.number = suggested }
                case .formula(let rest):
                    switch FormulaParser.parsePositional(rest, names: names) {
                    case .success(let f):
                        content = .formula(Formula(resolve(f.expr, this: ids, names: names)))
                    case .failure(let e):
                        let t = field.trimmingCharacters(in: .whitespacesAndNewlines)
                        content = .value(.text(t))
                        entry = .value(.text(t), suggested: nil)
                        problems.append(CSVReadProblem(row: r, column: c, message: e.message))
                    }
                }
                line.append(entry)
                if let content {
                    table.setCell(Cell(content: content, format: format), at: CellKey(row: ids.rows[r], column: ids.columns[c]))
                }
            }
            entries.append(line)
        }
        if let first = entries.first, first.contains(where: isText),
           first.allSatisfy({ isText($0) || $0 == .empty }),
           entries.dropFirst().contains(where: { $0.contains(where: isNumber) }) {
            table.headerRows = 1
        }
        return (table, problems)
    }

    private static func isText(_ e: CellEntry) -> Bool {
        if case .value(.text, _) = e { return true }
        return false
    }

    private static func isNumber(_ e: CellEntry) -> Bool {
        if case .value(.number, _) = e { return true }
        return false
    }

    // MARK: Resolving positions

    private static func resolve(_ e: FormulaExpr, this: (rows: [RowID], columns: [ColumnID]),
                                names: FormulaNames) -> FormulaExpr {
        /// The live ids of the grid `r` reads, when `r` is positional and that grid is known.
        func axes(_ r: FormulaRef) -> (rows: [RowID], columns: [ColumnID])? {
            switch r.target {
            case .this: return this
            case .figure(let id): return names.table(id: id).map { ($0.rows, $0.columns) }
            case .research: return nil
            }
        }
        func inside(_ r: FormulaRef) -> Bool {
            guard case .position(let row, let column) = r.anchor, let a = axes(r) else { return false }
            return row >= 0 && row < a.rows.count && column >= 0 && column < a.columns.count
        }
        func id(_ r: FormulaRef) -> FormulaRef {
            guard case .position(let row, let column) = r.anchor, let a = axes(r) else { return r }
            var out = r
            out.anchor = .id(row: a.rows[row], column: a.columns[column])
            return out
        }
        func go(_ e: FormulaExpr) -> FormulaExpr {
            switch e {
            case .number, .text, .bool, .missing, .error: return e
            case .ref(let r): return inside(r) ? .ref(id(r)) : e
            case .range(let g):
                // Both edges become ids together, or the range stays positional.
                return inside(g.start) && inside(g.end) ? .range(FormulaRange(start: id(g.start), end: id(g.end))) : e
            case .unary(let op, let x): return .unary(op, go(x))
            case .binary(let op, let l, let r): return .binary(op, go(l), go(r))
            case .call(let name, let args): return .call(name: name, arguments: args.map(go))
            }
        }
        return go(e)
    }
}

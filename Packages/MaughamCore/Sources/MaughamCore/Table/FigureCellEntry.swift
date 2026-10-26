import Foundation

/// **Typing into a table figure's cell, and the text the formula bar shows for one**
/// (report plan 7c Task 3, spec §6.3). Pure: the grid's controller hands the result to the
/// figure host's `setCell`/`setCells`.
public enum FigureCellEntry {
    /// The cell `text` makes over `prior`, read the way Excel reads typing (`CellInput`):
    /// numbers, percentages, currency, dates and booleans in the book's language, `'` forces
    /// text, `=` starts a formula resolved against `table`'s ids and `names`.
    ///
    /// - `prior`'s format and alignment are kept; the format the typing suggests (`15%`,
    ///   `£1,200`, a date) replaces only a `.general` number kind, never a format the writer chose.
    /// - Empty text clears the cell: nil, or an empty value keeping `prior`'s format and
    ///   alignment when either is not the default (Excel keeps a cleared cell's format).
    /// - A formula that will not read returns its `FormulaParseError` with the offset counted
    ///   into `text` exactly as given (leading space and the `=` included), so a field holding
    ///   `text` can put the caret there. Nothing is made.
    public static func cell(from text: String, prior: Cell?, table: FigureTable, names: FormulaNames,
                            locale: TableLocale) -> Result<Cell?, FormulaParseError> {
        var format = prior?.format ?? CellFormat()
        let alignment = prior?.alignment ?? .automatic
        switch CellInput.parse(text, locale: locale) {
        case .empty:
            guard format != CellFormat() || alignment != .automatic else { return .success(nil) }
            return .success(Cell(content: .value(.empty), format: format, alignment: alignment))
        case .value(let value, let suggested):
            if let suggested, format.number == .general { format.number = suggested }
            return .success(Cell(content: .value(value), format: format, alignment: alignment))
        case .formula(let body):
            switch FormulaParser.parse(body, in: table, names: names) {
            case .success(let formula):
                return .success(Cell(content: .formula(formula), format: format, alignment: alignment))
            case .failure(let error):
                return .failure(FormulaParseError(message: error.message, offset: error.offset + bodyStart(in: text)))
            }
        }
    }

    /// What the formula bar shows for `cell`, which `cell(from:prior:…)` reads back as the same
    /// cell: a formula as `=` plus its A1 text by current positions; a number raw (15
    /// significant digits, the book's decimal separator, no grouping or symbol), as a percent
    /// when its format is one; a date in the book's day order; text quoted with `'` when it
    /// would otherwise read as something else (a number, a formula, a boolean, or around spaces).
    public static func formulaBarText(for cell: Cell?, table: FigureTable, names: FormulaNames,
                                      locale: TableLocale) -> String {
        guard let cell else { return "" }
        switch cell.content {
        case .formula(let formula):
            return "=" + FormulaParser.render(formula, in: table, names: names)
        case .value(let value):
            switch value {
            case .empty: return ""
            case .bool(let b): return b ? "TRUE" : "FALSE"
            case .error(let e): return e.rawValue
            case .date(let serial): return date(serial, locale: locale)
            case .number(let x):
                if case .percent = cell.format.number { return number(x, scale: 2, locale: locale) + "%" }
                return number(x, scale: 0, locale: locale)
            case .text(let s):
                guard !s.isEmpty else { return "" }
                let readsBack = CellInput.parse(s, locale: locale) == .value(.text(s), suggested: nil)
                return readsBack ? s : "'" + s
            }
        }
    }

    // MARK: - Private

    /// Where the formula body (after the `=`) starts in typed text: `CellInput` trims first.
    private static func bodyStart(in text: String) -> Int {
        let leading = text.prefix { $0.isWhitespace || $0.isNewline }.count
        return leading + 1
    }

    /// `x` × 10^`scale`, at 15 significant digits: POSIX exponent form when `%g` writes one
    /// (`CellInput` reads it in every language), else the book's decimal separator.
    private static func number(_ x: Double, scale: Int, locale: TableLocale) -> String {
        guard x.isFinite else { return FormulaError.num.rawValue }
        let shortest = String(format: "%.15g", x == 0 ? 0 : x)
        var text = shortest
        if scale != 0, !shortest.contains("e"), var d = Decimal(string: shortest, locale: Locale(identifier: "en_US_POSIX")) {
            var scaled = Decimal()
            NSDecimalMultiplyByPowerOf10(&scaled, &d, Int16(scale), .plain)
            text = NSDecimalNumber(decimal: scaled).description(withLocale: Locale(identifier: "en_US_POSIX"))
        } else if scale != 0 {
            text = String(format: "%.15g", x * pow(10, Double(scale)))
        }
        if text.contains("e") { return text }
        return text.replacingOccurrences(of: ".", with: locale.decimalSeparator)
    }

    /// d/m/yyyy or m/d/yyyy by the book's day order — what `CellInput` reads as a `.day` date.
    private static func date(_ serial: Int, locale: TableLocale) -> String {
        guard let c = DateSerial.components(serial) else { return String(serial) }
        let (first, second) = locale.dayFirst ? (c.day, c.month) : (c.month, c.day)
        return "\(first)/\(second)/\(c.year)"
    }
}

import Foundation

/// What the writer sees in a cell: a value and its format, rendered in the book's language.
/// Numeric formats round Excel's way first, so binary artefacts never show.
public enum CellDisplay {
    public static func string(for value: CellValue, format: CellFormat, locale: TableLocale) -> String {
        switch value {
        case .empty: return format.zeroAsDash ? dash : ""
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e.rawValue
        case .number(let x):
            if case .date(let style) = format.number {
                if let serial = serialIfDate(x) { return date(serial, style, locale) }
                return number(x, .general, format, locale)
            }
            return number(x, format.number, format, locale)
        case .date(let serial):
            switch format.number {
            case .general: return date(serial, .day, locale)
            case .date(let style): return date(serial, style, locale)
            default: return number(Double(serial), format.number, format, locale)
            }
        }
    }

    private static let dash = "—"

    private static func serialIfDate(_ x: Double) -> Int? {
        guard x.isFinite, abs(x) < 1e7 else { return nil }
        let s = Int(x.rounded(.down))
        return (DateSerial.earliest...DateSerial.latest).contains(s) ? s : nil
    }

    // MARK: Numbers

    private static func number(_ x: Double, _ kind: NumberFormat, _ format: CellFormat, _ locale: TableLocale) -> String {
        guard x.isFinite else { return FormulaError.num.rawValue }
        // Round to what is shown, then everything after sees the rounded value. Compact rounds the
        // scaled mantissa in the formatter, never the raw value (1499.6 at 0 decimals is 1K, not 2K).
        let digits: Int?
        switch kind {
        case .general, .date: digits = nil
        case .number(let d, _), .currency(_, let d), .compact(let d): digits = clamp(d)
        case .percent(let d): digits = clamp(d) + 2
        }
        var rounded = ExcelRounding.round(x, digits: digits ?? 15)
        if case .compact = kind { rounded = ExcelRounding.round(x, digits: 15) }
        if rounded == 0 { rounded = 0 }                          // never "-0"
        if case .compact(let d) = kind, abs(rounded) < 1000, ExcelRounding.round(x, digits: clamp(d)) == 0 { rounded = 0 }
        if rounded == 0 && format.zeroAsDash { return dash }
        // `.minus` formats the signed value, so the locale's own negative pattern places the sign;
        // `.parentheses` formats the magnitude.
        let wrap = rounded < 0 && format.negatives == .parentheses
        let v = wrap ? abs(rounded) : rounded
        let body: String
        switch kind {
        case .general, .date: body = (v < 0 ? minusSign(locale) : "") + general(abs(v), locale)
        case .number(let d, _): body = formatted(v, .decimal, clamp(d), nil, locale, grouping: groupingAsked(kind))
        case .percent(let d): body = formatted(v, .percent, clamp(d), nil, locale, grouping: true)
        case .currency(let symbol, let d): body = formatted(v, .currency, clamp(d), symbol ?? locale.currencySymbol, locale, grouping: true)
        case .compact(let d): body = compact(v, clamp(d), locale)
        }
        return wrap ? "(" + body + ")" : body
    }

    private static func groupingAsked(_ kind: NumberFormat) -> Bool {
        if case .number(_, let g) = kind { return g }
        return true
    }

    private static func clamp(_ d: Int) -> Int { max(0, min(15, d)) }

    private static func minusSign(_ locale: TableLocale) -> String {
        formatter(locale, .decimal, 0, nil, grouping: false).minusSign ?? "-"
    }

    /// 10 significant digits, trailing zeros trimmed, no grouping; scientific outside 1e-9 ..< 1e11.
    private static func general(_ x: Double, _ locale: TableLocale) -> String {
        if x == 0 { return "0" }
        if x >= 1e11 || x < 1e-9 {
            let s = String(format: "%.5E", x)                   // 1.23457E+11
            let parts = s.split(separator: "E", maxSplits: 1).map(String.init)
            var mantissa = parts[0]
            if mantissa.contains(".") {
                while mantissa.hasSuffix("0") { mantissa.removeLast() }
                if mantissa.hasSuffix(".") { mantissa.removeLast() }
            }
            return mantissa.replacingOccurrences(of: ".", with: locale.decimalSeparator) + "E" + (parts.count > 1 ? parts[1] : "")
        }
        guard let d = Decimal(string: String(format: "%.10g", x)) else { return String(x) }
        return "\(d)".replacingOccurrences(of: ".", with: locale.decimalSeparator)
    }

    private static func formatted(_ x: Double, _ style: NumberFormatter.Style, _ decimals: Int, _ symbol: String?, _ locale: TableLocale, grouping: Bool) -> String {
        formatter(locale, style, decimals, symbol, grouping: grouping).string(from: NSNumber(value: x)) ?? String(x)
    }

    private static func compact(_ x: Double, _ decimals: Int, _ locale: TableLocale) -> String {
        x.formatted(.number.notation(.compactName).rounded(rule: .toNearestOrAwayFromZero).precision(.fractionLength(decimals)).locale(locale.locale))
    }

    // MARK: Formatter cache (one per locale, style, digits, symbol, grouping)

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var numbers: [String: NumberFormatter] = [:]
        private var dates: [String: DateFormatter] = [:]
        func number(_ key: String, _ make: () -> NumberFormatter) -> NumberFormatter {
            lock.lock(); defer { lock.unlock() }
            if let f = numbers[key] { return f }
            let f = make(); numbers[key] = f; return f
        }
        func date(_ key: String, _ make: () -> DateFormatter) -> DateFormatter {
            lock.lock(); defer { lock.unlock() }
            if let f = dates[key] { return f }
            let f = make(); dates[key] = f; return f
        }
    }
    private static let cache = Cache()

    private static func formatter(_ locale: TableLocale, _ style: NumberFormatter.Style, _ decimals: Int, _ symbol: String?, grouping: Bool) -> NumberFormatter {
        let key = "\(locale.locale.identifier)|\(style.rawValue)|\(decimals)|\(symbol ?? "\u{0}")|\(grouping)"
        return cache.number(key) {
            let f = NumberFormatter()
            f.locale = locale.locale
            f.numberStyle = style
            f.minimumFractionDigits = decimals
            f.maximumFractionDigits = decimals
            f.roundingMode = .halfUp
            f.usesGroupingSeparator = grouping
            if let symbol, style == .currency { f.currencySymbol = symbol }
            return f
        }
    }

    // MARK: Dates

    private static func date(_ serial: Int, _ style: DateStyle, _ locale: TableLocale) -> String {
        guard let c = DateSerial.components(serial) else { return FormulaError.value.rawValue }
        let start = locale.financialYearStartMonth
        if start != 1 {
            let endYear = c.month >= start ? c.year + 1 : c.year
            switch style {
            case .year: return "FY" + String(endYear)
            case .quarter:
                let q = ((c.month - start + 12) % 12) / 3 + 1
                let yy = endYear % 100
                return "Q\(q) FY" + (yy < 10 ? "0" : "") + String(yy)
            default: break
            }
        }
        let template: String
        switch style {
        case .iso: return DateSerial.isoString(serial)
        case .day: template = "dMMMy"
        case .month: template = "MMMy"
        case .quarter: template = "QQQy"
        case .year: template = "y"
        }
        let f = dateFormatter(locale, template)
        return f.string(from: Date(timeIntervalSince1970: Double(serial - 25_569) * 86_400))
    }

    private static func dateFormatter(_ locale: TableLocale, _ template: String) -> DateFormatter {
        cache.date("\(locale.locale.identifier)|\(template)") {
            let f = DateFormatter()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "GMT")!
            f.calendar = calendar
            f.locale = locale.locale
            f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            return f
        }
    }
}

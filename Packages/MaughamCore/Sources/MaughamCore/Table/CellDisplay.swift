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
        // Round to what is shown, then everything after sees the rounded value.
        let digits: Int?
        switch kind {
        case .general, .date: digits = nil
        case .number(let d, _), .currency(_, let d), .compact(let d): digits = clamp(d)
        case .percent(let d): digits = clamp(d) + 2
        }
        let rounded: Double
        if let digits { rounded = ExcelRounding.round(x, digits: digits) } else { rounded = ExcelRounding.round(x, digits: 15) }
        if rounded == 0 && format.zeroAsDash { return dash }
        let magnitude = abs(rounded)
        let negative = rounded < 0
        let body: String
        switch kind {
        case .general, .date: body = general(magnitude, locale)
        case .number(let d, let grouping): body = plain(magnitude, clamp(d), grouping, locale)
        case .percent(let d): body = formatted(magnitude, .percent, clamp(d), nil, locale)
        case .currency(let symbol, let d): body = formatted(magnitude, .currency, clamp(d), symbol ?? locale.currencySymbol, locale)
        case .compact(let d): body = compact(magnitude, clamp(d), locale)
        }
        guard negative else { return body }
        switch format.negatives {
        case .parentheses: return "(" + body + ")"
        case .minus: return minusSign(locale) + body
        }
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

    /// `.number`: the locale's digits, grouped in threes whenever asked (some locales, es among them,
    /// skip a four-digit group by default; an explicit ask gets one).
    private static func plain(_ x: Double, _ decimals: Int, _ grouping: Bool, _ locale: TableLocale) -> String {
        let f = formatter(locale, .decimal, decimals, nil, grouping: false)
        let s = f.string(from: NSNumber(value: x)) ?? String(x)
        guard grouping else { return s }
        let decimal = f.decimalSeparator ?? "."
        let integer: String, rest: String
        if let r = s.range(of: decimal) { integer = String(s[..<r.lowerBound]); rest = String(s[r.lowerBound...]) } else { integer = s; rest = "" }
        guard integer.count > 3, integer.allSatisfy(\.isNumber) else { return s }
        var out = "", n = 0
        for ch in integer.reversed() {
            if n > 0 && n % 3 == 0 { out.append(contentsOf: locale.groupingSeparator.reversed()) }
            out.append(ch); n += 1
        }
        return String(out.reversed()) + rest
    }

    private static func formatted(_ x: Double, _ style: NumberFormatter.Style, _ decimals: Int, _ symbol: String?, _ locale: TableLocale) -> String {
        formatter(locale, style, decimals, symbol, grouping: true).string(from: NSNumber(value: x)) ?? String(x)
    }

    private static func compact(_ x: Double, _ decimals: Int, _ locale: TableLocale) -> String {
        // English is K / M / B / T in every region (a ruling); en-GB's own "k / m / bn" is not used.
        let l = locale.locale.language.languageCode?.identifier == "en" ? Locale(identifier: "en") : locale.locale
        return x.formatted(.number.notation(.compactName).precision(.fractionLength(decimals)).locale(l))
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

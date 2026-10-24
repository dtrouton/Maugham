import Foundation

/// What typing or pasting text into a cell means.
public enum CellEntry: Equatable, Sendable {
    case empty
    case value(CellValue, suggested: NumberFormat?)   // the format Excel would apply on entry, or nil
    case formula(String)                              // the text after "=", for FormulaParser
}

/// Reads cell text the way Excel does, in the book's language: numbers, percentages, currency and dates.
/// Total: any string yields an entry, none traps.
public enum CellInput {
    public static func parse(_ text: String, locale: TableLocale) -> CellEntry {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .empty }
        if t.hasPrefix("="), t.count > 1 { return .formula(String(t.dropFirst())) }
        if t.hasPrefix("'") { return .value(.text(String(t.dropFirst())), suggested: nil) }
        switch t.lowercased() {
        case "true": return .value(.bool(true), suggested: nil)
        case "false": return .value(.bool(false), suggested: nil)
        default: break
        }
        if let n = number(t, locale: locale) { return n }
        if let d = date(t, locale: locale) { return d }
        return .value(.text(t), suggested: nil)
    }

    // MARK: Numbers

    private static let knownSymbols = ["£", "$", "€", "¥"]
    private static let spaces: Set<Character> = ["\u{00A0}", "\u{202F}", "\u{2009}"]

    private static func norm(_ s: String) -> String { String(s.map { spaces.contains($0) ? " " : $0 }) }
    private static func isDigit(_ c: Character) -> Bool { ("0"..."9").contains(c) }
    private static func allDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(isDigit) }
    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    private static func number(_ text: String, locale: TableLocale) -> CellEntry? {
        var t = text
        var negative = false, signSeen = false
        if t.count >= 3, t.hasPrefix("("), t.hasSuffix(")") {
            negative = true; signSeen = true
            t = trimmed(String(t.dropFirst().dropLast()))
        }
        func takeSign() -> Bool {   // false = a second sign
            guard let c = t.first, "+-\u{2212}".contains(c) else { return true }
            if signSeen { return false }
            signSeen = true
            negative = c != "+"
            t = trimmed(String(t.dropFirst()))
            return true
        }
        let symbols = ([locale.currencySymbol] + knownSymbols).filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .sorted { $0.count > $1.count }
        guard takeSign() else { return nil }
        var symbol: String?
        if let s = symbols.first(where: { t.hasPrefix($0) }) {
            symbol = s
            t = trimmed(String(t.dropFirst(s.count)))
        }
        guard takeSign() else { return nil }
        var percent = false
        if t.hasSuffix("%") { percent = true; t = trimmed(String(t.dropLast())) }
        if symbol == nil, let s = symbols.first(where: { t.hasSuffix($0) }) {
            symbol = s
            t = trimmed(String(t.dropLast(s.count)))
        }
        if percent && symbol != nil { return nil }
        guard let body = readBody(t, locale: locale), var value = Double(body.canonical), value.isFinite else { return nil }
        if percent { value /= 100 }
        if negative { value = -value }
        if value == 0 { value = 0 }
        let suggested: NumberFormat?
        if percent { suggested = .percent(decimals: body.decimals) }
        else if let symbol { suggested = .currency(symbol: symbol == locale.currencySymbol ? nil : symbol, decimals: body.decimals) }
        else if body.grouped { suggested = .number(decimals: body.decimals, grouping: true) }
        else { suggested = nil }
        return .value(.number(value), suggested: suggested)
    }

    /// The locale's reading first, else POSIX.
    private static func readBody(_ s: String, locale: TableLocale) -> (canonical: String, decimals: Int, grouped: Bool)? {
        guard !s.isEmpty else { return nil }
        if let r = exponentForm(s) { return r }
        if let r = read(s, decimal: locale.decimalSeparator, grouping: locale.groupingSeparator) { return r }
        return read(s, decimal: ".", grouping: nil)
    }

    /// POSIX exponent form (1.5E+20, 1e-7, 2E5), which a table writes for very large and small numbers.
    private static func exponentForm(_ s: String) -> (canonical: String, decimals: Int, grouped: Bool)? {
        let parts = s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "e" || $0 == "E" })
        guard parts.count == 2 else { return nil }
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(mantissa.count), mantissa.allSatisfy({ $0.isEmpty || allDigits(String($0)) }),
              mantissa.contains(where: { !$0.isEmpty }) else { return nil }
        var exp = Substring(parts[1])
        if let c = exp.first, c == "+" || c == "-" { exp = exp.dropFirst() }
        guard allDigits(String(exp)), exp.count <= 4 else { return nil }
        return (s, mantissa.count == 2 ? mantissa[1].count : 0, false)
    }

    private static func read(_ raw: String, decimal: String, grouping: String?) -> (canonical: String, decimals: Int, grouped: Bool)? {
        let s = norm(raw)
        let dec = norm(decimal)
        guard !dec.isEmpty else { return nil }
        let halves = s.components(separatedBy: dec)
        guard halves.count <= 2 else { return nil }
        let whole = halves[0]
        let frac = halves.count == 2 ? halves[1] : ""
        guard frac.isEmpty || allDigits(frac) else { return nil }
        var digits = whole
        var grouped = false
        if let g = grouping.map(norm), !g.isEmpty, g != dec, whole.contains(g) {
            let groups = whole.components(separatedBy: g)
            guard let first = groups.first, (1...3).contains(first.count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }),
                  groups.allSatisfy(allDigits) else { return nil }
            digits = groups.joined()
            grouped = true
        } else if !whole.isEmpty, !allDigits(whole) { return nil }
        guard !(digits.isEmpty && frac.isEmpty) else { return nil }
        return ((digits.isEmpty ? "0" : digits) + (frac.isEmpty ? "" : "." + frac), frac.count, grouped)
    }

    // MARK: Dates

    private static func date(_ t: String, locale: TableLocale) -> CellEntry? {
        if let r = numericDate(t, dayFirst: locale.dayFirst) { return r }
        return wordDate(t, locale: locale)
    }

    private static func entry(_ serial: Int?, _ style: DateStyle) -> CellEntry? {
        serial.map { .value(.date($0), suggested: .date(style)) }
    }

    private static func year(_ s: String) -> Int? {
        guard allDigits(s), s.count == 2 || s.count == 4, let y = Int(s) else { return nil }
        return s.count == 4 ? y : (y < 30 ? 2000 + y : 1900 + y)
    }

    private static func dayOrMonth(_ s: String) -> Int? {
        allDigits(s) && s.count <= 2 ? Int(s) : nil
    }

    private static func numericDate(_ t: String, dayFirst: Bool) -> CellEntry? {
        guard let sep = t.first(where: { "/-.".contains($0) }) else { return nil }
        let parts = t.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        if parts[0].count == 4, sep != "." {   // year first: ISO
            guard allDigits(parts[0]), let y = Int(parts[0]), let m = dayOrMonth(parts[1]), let d = dayOrMonth(parts[2]) else { return nil }
            return entry(DateSerial.serial(year: y, month: m, day: d), .iso)
        }
        guard let a = dayOrMonth(parts[0]), let b = dayOrMonth(parts[1]), let y = year(parts[2]) else { return nil }
        let (d, m) = dayFirst ? (a, b) : (b, a)
        return entry(DateSerial.serial(year: y, month: m, day: d), .day)
    }

    private static func fold(_ s: String) -> String {
        var f = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        while f.hasSuffix(".") { f.removeLast() }
        return f
    }

    private static let nameCache = NSLock()
    nonisolated(unsafe) private static var cachedNames: [String: [String: Int]] = [:]
    nonisolated(unsafe) static var monthNameBuilds = 0   // test spy: how many dictionaries were built

    private static func monthNames(_ locale: TableLocale) -> [String: Int] {
        let key = locale.locale.identifier
        nameCache.lock()
        defer { nameCache.unlock() }
        if let hit = cachedNames[key] { return hit }
        let built = buildMonthNames(locale)
        cachedNames[key] = built
        monthNameBuilds += 1
        return built
    }

    private static func buildMonthNames(_ locale: TableLocale) -> [String: Int] {
        var names: [String: Int] = [:]
        for loc in [Locale(identifier: "en_US"), locale.locale] {
            let f = DateFormatter()
            f.locale = loc
            f.calendar = Calendar(identifier: .gregorian)
            let lists = [f.monthSymbols, f.shortMonthSymbols, f.standaloneMonthSymbols, f.shortStandaloneMonthSymbols]
            for list in lists {
                guard let list, list.count == 12 else { continue }
                for (i, n) in list.enumerated() { names[fold(n)] = i + 1 }
            }
        }
        names["sept"] = 9
        return names
    }

    private static func wordDate(_ t: String, locale: TableLocale) -> CellEntry? {
        let tokens = t.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\u{00A0}" }).map(String.init)
            .filter { fold($0) != "de" && fold($0) != "del" }
        if tokens.count == 2 {
            if let q = quarter(tokens[0], tokens[1]) ?? quarter(tokens[1], tokens[0]) { return q }
        }
        guard (2...3).contains(tokens.count), tokens.contains(where: { $0.contains(where: \.isLetter) }) else { return nil }
        guard tokens.contains(where: allDigits) else { return nil }
        let names = monthNames(locale)
        func month(_ s: String) -> Int? { s.first.map { !isDigit($0) } == true ? names[fold(s)] : nil }
        switch tokens.count {
        case 2:
            guard let m = month(tokens[0]), allDigits(tokens[1]), tokens[1].count == 4, let y = Int(tokens[1]) else { return nil }
            return entry(DateSerial.serial(year: y, month: m, day: 1), .month)
        default:
            if let d = dayOrMonth(tokens[0]), let m = month(tokens[1]), let y = year(tokens[2]) {
                return entry(DateSerial.serial(year: y, month: m, day: d), .day)
            }
            if let m = month(tokens[0]), let d = dayOrMonth(tokens[1]), let y = year(tokens[2]) {
                return entry(DateSerial.serial(year: y, month: m, day: d), .day)
            }
            return nil
        }
    }

    private static func quarter(_ q: String, _ y: String) -> CellEntry? {
        guard q.count == 2, q.first == "Q" || q.first == "q", let n = q.last.flatMap({ Int(String($0)) }), (1...4).contains(n),
              allDigits(y), y.count == 4, let yy = Int(y) else { return nil }
        return entry(DateSerial.serial(year: yy, month: (n - 1) * 3 + 1, day: 1), .quarter)
    }
}

import Foundation

/// One formula function: how many arguments it takes and what it computes from them.
/// A call with too few or too many arguments is `#VALUE!`.
struct FormulaFunction: Sendable {
    let minArguments: Int
    let maxArguments: Int
    /// SUMIF/AVERAGEIF: the evaluator hands over the third argument resized to the first
    /// range's shape from its own top-left cell, as Excel does.
    let resizesThirdToFirst: Bool
    let apply: @Sendable ([FormulaArgument]) -> CellValue

    init(_ minArguments: Int, _ maxArguments: Int = .max, resizesThirdToFirst: Bool = false,
         _ apply: @escaping @Sendable ([FormulaArgument]) -> CellValue) {
        self.minArguments = minArguments
        self.maxArguments = maxArguments
        self.resizesThirdToFirst = resizesThirdToFirst
        self.apply = apply
    }
}

/// The function table, name (uppercased) → implementation, built from one dictionary per
/// group. A new group is a static dictionary added to `groups`; a name not in `all` is `#NAME?`.
enum FormulaFunctions {
    static let groups: [[String: FormulaFunction]] = [totals, rounding, logic, conditionalTotals, finance]

    static let all: [String: FormulaFunction] = groups.reduce(into: [:]) { table, group in
        table.merge(group) { _, _ in preconditionFailure("a formula function is registered twice") }
    }

    // MARK: Totals

    static let totals: [String: FormulaFunction] = [
        "SUM": FormulaFunction(1) { args in
            numeric(args, .total) { xs in FormulaCoercion.finite(xs.reduce(0, +)) }
        },
        "AVERAGE": FormulaFunction(1) { args in
            numeric(args, .total) { xs in
                xs.isEmpty ? .error(.divideByZero) : FormulaCoercion.finite(xs.reduce(0, +) / Double(xs.count))
            }
        },
        "MIN": FormulaFunction(1) { args in numeric(args, .total) { xs in .number(xs.min() ?? 0) } },
        "MAX": FormulaFunction(1) { args in numeric(args, .total) { xs in .number(xs.max() ?? 0) } },
        "COUNT": FormulaFunction(1) { args in numeric(args, .count) { xs in .number(Double(xs.count)) } },
        "MEDIAN": FormulaFunction(1) { args in
            numeric(args, .total) { xs in
                guard !xs.isEmpty else { return .error(.num) }
                let s = xs.sorted(), m = s.count / 2
                return .number(s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2)
            }
        },
    ]

    /// How a total reads its arguments.
    enum NumberRule {
        /// SUM and kin: non-numeric text given directly is `#VALUE!`; any error propagates.
        case total
        /// COUNT: it counts numbers and ignores everything else, errors included.
        case count
    }

    /// The numbers a total reads, in argument order. Inside a range (or a referenced cell)
    /// only numbers and dates count; given directly, numbers, dates, booleans and numeric
    /// text count, and an empty argument slot is 0.
    static func numbers(_ args: [FormulaArgument], _ rule: NumberRule) -> Result<[Double], FormulaError> {
        var xs: [Double] = []
        for arg in args {
            switch arg {
            case .missing: xs.append(0)
            case .range(let rows):
                for row in rows {
                    for v in row {
                        switch v {
                        case .number(let x): xs.append(x)
                        case .date(let d): xs.append(Double(d))
                        case .error(let err): if rule == .total { return .failure(err) }
                        default: break
                        }
                    }
                }
            case .scalar(let v):
                switch v {
                case .empty: break
                case .error(let err): if rule == .total { return .failure(err) }
                case .text(let s):
                    if let x = FormulaCoercion.plainNumber(s) { xs.append(x) } else if rule == .total { return .failure(.value) }
                default:
                    if case .success(let x) = FormulaCoercion.number(v) { xs.append(x) }
                }
            }
        }
        return .success(xs)
    }

    private static func numeric(_ args: [FormulaArgument], _ rule: NumberRule, _ body: ([Double]) -> CellValue) -> CellValue {
        switch numbers(args, rule) {
        case .failure(let err): return .error(err)
        case .success(let xs): return body(xs)
        }
    }

    // MARK: Argument helpers

    /// An argument read as one value: a referenced cell is its value, a larger range `#VALUE!`,
    /// an empty slot 0.
    static func value(_ arg: FormulaArgument) -> CellValue {
        switch arg {
        case .scalar(let v): return v
        case .range(let rows): return FormulaCoercion.single(rows)
        case .missing: return .number(0)
        }
    }

    /// An argument read as one number, with arithmetic's coercion.
    static func number(_ arg: FormulaArgument) -> Result<Double, FormulaError> {
        FormulaCoercion.number(value(arg))
    }

    /// An argument read as a whole number of places, truncated toward zero as Excel does.
    static func integer(_ arg: FormulaArgument) -> Result<Int, FormulaError> {
        number(arg).map { Int(max(-1e9, min(1e9, $0)).rounded(.towardZero)) }
    }

    /// An argument that must be a range (a referenced cell is a 1×1 range).
    static func range(_ arg: FormulaArgument) -> Result<[[CellValue]], FormulaError> {
        switch arg {
        case .range(let rows): return .success(rows)
        case .scalar(.error(let err)): return .failure(err)
        default: return .failure(.value)
        }
    }

    // MARK: Rounding

    static let rounding: [String: FormulaFunction] = [
        "ROUND": roundingFunction(ExcelRounding.round),
        "ROUNDUP": roundingFunction(ExcelRounding.roundUp),
        "ROUNDDOWN": roundingFunction(ExcelRounding.roundDown),
        "ABS": FormulaFunction(1, 1) { args in
            switch number(args[0]) {
            case .failure(let err): return .error(err)
            case .success(let x): return .number(abs(x))
            }
        },
    ]

    private static func roundingFunction(_ f: @escaping @Sendable (Double, Int) -> Double) -> FormulaFunction {
        FormulaFunction(2, 2) { args in
            let x: Double
            switch number(args[0]) {
            case .failure(let err): return .error(err)
            case .success(let v): x = v
            }
            switch integer(args[1]) {
            case .failure(let err): return .error(err)
            case .success(let digits): return FormulaCoercion.finite(f(x, digits))
            }
        }
    }

    // MARK: Logic

    static let logic: [String: FormulaFunction] = [
        "IF": FormulaFunction(2, 3) { args in
            let condition: Bool
            switch value(args[0]) {
            case .error(let err): return .error(err)
            case .text(let t):
                guard let b = FormulaCoercion.textBool(t) else { return .error(.value) }
                condition = b
            case .bool(let b): condition = b
            case .empty: condition = false
            case .number(let x): condition = x != 0
            case .date(let d): condition = d != 0
            }
            if condition { return value(args[1]) }
            return args.count == 3 ? value(args[2]) : .bool(false)
        },
        "IFERROR": FormulaFunction(2, 2) { args in
            let v = value(args[0])
            if case .error = v { return value(args[1]) }
            return v
        },
    ]

    // MARK: Conditional totals

    static let conditionalTotals: [String: FormulaFunction] = [
        "SUMIF": FormulaFunction(2, 3, resizesThirdToFirst: true) { args in
            conditional(args) { xs in FormulaCoercion.finite(xs.reduce(0, +)) }
        },
        "COUNTIF": FormulaFunction(2, 2) { args in
            switch range(args[0]) {
            case .failure(let err): return .error(err)
            case .success(let rows):
                let criteria = FormulaCriteria(value(args[1]))
                return .number(Double(rows.reduce(0) { $0 + $1.filter(criteria.matches).count }))
            }
        },
        "AVERAGEIF": FormulaFunction(2, 3, resizesThirdToFirst: true) { args in
            conditional(args) { xs in
                xs.isEmpty ? .error(.divideByZero) : FormulaCoercion.finite(xs.reduce(0, +) / Double(xs.count))
            }
        },
    ]

    /// SUMIF/AVERAGEIF: the numbers in the third range (default the first) at the positions
    /// where the first range meets the criteria. The evaluator has already resized the third
    /// range to the first's shape; a matched error there propagates.
    private static func conditional(_ args: [FormulaArgument], _ body: ([Double]) -> CellValue) -> CellValue {
        let criteriaRows: [[CellValue]]
        switch range(args[0]) {
        case .failure(let err): return .error(err)
        case .success(let rows): criteriaRows = rows
        }
        var valueRows = criteriaRows
        if args.count == 3, case .missing = args[2] {} else if args.count == 3 {
            switch range(args[2]) {
            case .failure(let err): return .error(err)
            case .success(let rows): valueRows = rows
            }
        }
        let criteria = FormulaCriteria(value(args[1]))
        var xs: [Double] = []
        for (i, row) in criteriaRows.enumerated() where i < valueRows.count {
            for (j, cell) in row.enumerated() where j < valueRows[i].count && criteria.matches(cell) {
                switch valueRows[i][j] {
                case .number(let x): xs.append(x)
                case .date(let d): xs.append(Double(d))
                case .error(let err): return .error(err)
                default: break
                }
            }
        }
        return body(xs)
    }
}

/// An Excel criteria for SUMIF, COUNTIF and AVERAGEIF: a value, or a string that may
/// start with `= <> < > <= >=`. `""` matches empty cells, `"="` only truly empty ones and
/// `"<>"` non-empty ones; `<>` anything matches every cell `=` that would not. A numeric
/// `=` matches numbers, dates and number-like text; `< > <= >=` only numbers and dates.
struct FormulaCriteria: Sendable {
    enum Comparison: Sendable { case equal, less, greater, lessOrEqual, greaterOrEqual }

    enum Test: Sendable {
        case number(Comparison, Double)
        case bool(Comparison, Bool)
        case text(Comparison, String)           // `.equal` reads `*`, `?` and `~` as wildcards
        case error(FormulaError)
        case emptyOrEmptyText                   // the criteria ""
        case emptyOnly                          // the criteria "="
    }

    let test: Test
    let negated: Bool

    init(_ criteria: CellValue) {
        switch criteria {
        case .number(let x): (test, negated) = (.number(.equal, x), false)
        case .date(let d): (test, negated) = (.number(.equal, Double(d)), false)
        case .bool(let b): (test, negated) = (.bool(.equal, b), false)
        case .error(let err): (test, negated) = (.error(err), false)
        case .empty: (test, negated) = (.number(.equal, 0), false)  // an empty criteria cell is 0
        case .text(let s): (test, negated) = Self.parse(s)
        }
    }

    private static func parse(_ s: String) -> (Test, Bool) {
        let prefixes: [(String, Comparison?, Bool)] = [
            ("<=", .lessOrEqual, false), (">=", .greaterOrEqual, false), ("<>", .equal, true),
            ("<", .less, false), (">", .greater, false), ("=", .equal, false),
        ]
        guard let (prefix, comparison, negated) = prefixes.first(where: { s.hasPrefix($0.0) }) else {
            if s.isEmpty { return (.emptyOrEmptyText, false) }
            return (operand(s, .equal), false)
        }
        let rest = String(s.dropFirst(prefix.count))
        let c = comparison ?? .equal
        if rest.isEmpty && c == .equal { return (.emptyOnly, negated) }
        return (operand(rest, c), negated)
    }

    private static func operand(_ text: String, _ c: Comparison) -> Test {
        if let x = FormulaCoercion.plainNumber(text) { return .number(c, x) }
        if let b = FormulaCoercion.textBool(text) { return .bool(c, b) }
        return .text(c, text)
    }

    func matches(_ cell: CellValue) -> Bool { negated != passes(cell) }

    private func passes(_ cell: CellValue) -> Bool {
        switch test {
        case .emptyOnly: return cell == .empty
        case .emptyOrEmptyText: return cell == .empty || cell == .text("")
        case .error(let err): return cell == .error(err)
        case .number(let c, let x):
            switch cell {
            case .number(let y): return Self.holds(c, FormulaCoercion.compare(.number(y), .number(x)))
            case .date(let d): return Self.holds(c, FormulaCoercion.compare(.number(Double(d)), .number(x)))
            case .text(let s):            // `=` also matches number-like text; ordering never does
                guard c == .equal, let y = FormulaCoercion.plainNumber(s) else { return false }
                return FormulaCoercion.compare(.number(y), .number(x)) == .orderedSame
            default: return false
            }
        case .bool(let c, let b):
            guard case .bool = cell else { return false }
            return Self.holds(c, FormulaCoercion.compare(cell, .bool(b)))
        case .text(let c, let t):
            guard case .text(let s) = cell else { return false }
            if c == .equal { return FormulaWildcard.matches(s, pattern: t) }
            return Self.holds(c, s.compare(t, options: [.caseInsensitive]))
        }
    }

    private static func holds(_ c: Comparison, _ r: ComparisonResult) -> Bool {
        switch c {
        case .equal: return r == .orderedSame
        case .less: return r == .orderedAscending
        case .greater: return r == .orderedDescending
        case .lessOrEqual: return r != .orderedDescending
        case .greaterOrEqual: return r != .orderedAscending
        }
    }
}

/// Excel's criteria wildcards, case-insensitive over the whole text: `*` any run, `?` one
/// character, `~` makes the next character literal.
enum FormulaWildcard {
    private enum Token: Equatable { case literal(Character), any, one }

    static func matches(_ text: String, pattern: String) -> Bool {
        let s = Array(text.lowercased())
        var p: [Token] = []
        var chars = Array(pattern.lowercased())[...]
        while let c = chars.popFirst() {
            switch c {
            case "~": p.append(.literal(chars.popFirst() ?? "~"))
            case "*": p.append(.any)
            case "?": p.append(.one)
            default: p.append(.literal(c))
            }
        }
        // Greedy match, backtracking to the last `*`.
        var i = 0, j = 0, star = -1, resume = 0
        while i < s.count {
            if j < p.count, p[j] == .one || p[j] == .literal(s[i]) {
                i += 1; j += 1
            } else if j < p.count, p[j] == .any {
                star = j; resume = i; j += 1
            } else if star >= 0 {
                resume += 1; i = resume; j = star + 1
            } else {
                return false
            }
        }
        while j < p.count, p[j] == .any { j += 1 }
        return j == p.count
    }
}

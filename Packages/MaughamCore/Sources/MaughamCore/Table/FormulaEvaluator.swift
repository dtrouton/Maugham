import Foundation

/// One evaluated function argument. A bare cell reference arrives as a 1×1 `.range`,
/// because Excel treats a referenced cell like a range (`SUM(A1)` skips text in A1);
/// `.missing` is an empty argument slot: `IF(c,,1)`.
public enum FormulaArgument: Sendable {
    case scalar(CellValue)
    case range([[CellValue]])
    case missing
}

/// Where a formula's references are read. `range` returns the range's live cells row by
/// row, or nil when the range is `#REF!`.
public struct FormulaEnvironment: Sendable {
    public var cell: @Sendable (FormulaRef) -> CellValue
    public var range: @Sendable (FormulaRange) -> [[CellValue]]?

    public init(cell: @escaping @Sendable (FormulaRef) -> CellValue,
                range: @escaping @Sendable (FormulaRange) -> [[CellValue]]?) {
        self.cell = cell
        self.range = range
    }
}

/// Evaluates a formula's syntax tree with Excel's coercion, comparison and error rules.
/// Recursion follows the tree, which `FormulaParser.maxDepth` bounds.
public enum FormulaEvaluator {
    /// The formula's value. A result that is a bare empty cell is `0`, as Excel shows `=A1`.
    public static func evaluate(_ formula: Formula, in env: FormulaEnvironment) -> CellValue {
        let v = scalar(formula.expr, env)
        return v == .empty ? .number(0) : v
    }

    /// An expression in a scalar position: an operand, or the whole formula.
    static func scalar(_ e: FormulaExpr, _ env: FormulaEnvironment) -> CellValue {
        switch e {
        case .number(let x): return .number(x)
        case .text(let s): return .text(s)
        case .bool(let b): return .bool(b)
        case .missing: return .number(0)
        case .error(let err): return .error(err)
        case .ref(let r): return env.cell(r)
        case .range(let g):
            guard let cells = env.range(g) else { return .error(.ref) }
            return FormulaCoercion.single(cells)
        case .unary(let op, let x): return unary(op, scalar(x, env))
        case .binary(let op, let l, let r): return binary(op, l, r, env)
        case .call(let name, let arguments): return call(name, arguments, env)
        }
    }

    /// An expression in a function's argument list.
    static func argument(_ e: FormulaExpr, _ env: FormulaEnvironment) -> FormulaArgument {
        switch e {
        case .missing: return .missing
        case .ref(let r): return .range([[env.cell(r)]])
        case .range(let g):
            guard let cells = env.range(g) else { return .scalar(.error(.ref)) }
            return .range(cells)
        default: return .scalar(scalar(e, env))
        }
    }

    private static func call(_ name: String, _ arguments: [FormulaExpr], _ env: FormulaEnvironment) -> CellValue {
        guard let f = FormulaFunctions.all[name] else { return .error(.name) }
        guard arguments.count >= f.minArguments, arguments.count <= f.maxArguments else { return .error(.value) }
        return f.apply(arguments.map { argument($0, env) })
    }

    private static func unary(_ op: UnaryOperator, _ v: CellValue) -> CellValue {
        if op == .plus { return v }                      // Excel's unary plus is a no-op
        switch FormulaCoercion.number(v) {
        case .failure(let err): return .error(err)
        case .success(let x): return FormulaCoercion.finite(op == .negate ? -x : x / 100)
        }
    }

    private static func binary(_ op: BinaryOperator, _ le: FormulaExpr, _ re: FormulaExpr, _ env: FormulaEnvironment) -> CellValue {
        let lv = scalar(le, env)
        if case .error = lv { return lv }
        switch op {
        case .equal, .notEqual, .less, .greater, .lessOrEqual, .greaterOrEqual:
            let rv = scalar(re, env)
            if case .error = rv { return rv }
            let c = FormulaCoercion.compare(lv, rv)
            switch op {
            case .equal: return .bool(c == .orderedSame)
            case .notEqual: return .bool(c != .orderedSame)
            case .less: return .bool(c == .orderedAscending)
            case .greater: return .bool(c == .orderedDescending)
            case .lessOrEqual: return .bool(c != .orderedDescending)
            default: return .bool(c != .orderedAscending)
            }
        default:
            let l: Double
            switch FormulaCoercion.number(lv) {
            case .failure(let err): return .error(err)
            case .success(let x): l = x
            }
            let rv = scalar(re, env)
            let r: Double
            switch FormulaCoercion.number(rv) {
            case .failure(let err): return .error(err)
            case .success(let x): r = x
            }
            return arithmetic(op, l, r, leftIsDate: lv.isDate, rightIsDate: rv.isDate)
        }
    }

    private static func arithmetic(_ op: BinaryOperator, _ l: Double, _ r: Double, leftIsDate: Bool, rightIsDate: Bool) -> CellValue {
        let x: Double
        switch op {
        case .add: x = l + r
        case .subtract: x = l - r
        case .multiply: x = l * r
        case .divide:
            if r == 0 { return .error(.divideByZero) }
            x = l / r
        default:                                          // power
            if l == 0 && r == 0 { return .error(.num) }
            if l == 0 && r < 0 { return .error(.divideByZero) }
            if l < 0 && r != r.rounded(.towardZero) { return .error(.num) }
            x = Foundation.pow(l, r)
        }
        // date ± number stays a date; date − date and everything else is a number.
        let staysDate = (op == .add && leftIsDate != rightIsDate) || (op == .subtract && leftIsDate && !rightIsDate)
        if staysDate, x.isFinite, x == x.rounded(.towardZero), abs(x) < 1e15 { return .date(Int(x)) }
        return FormulaCoercion.finite(x)
    }
}

/// Excel's value coercions, shared by the evaluator and the function table.
enum FormulaCoercion {
    /// An arithmetic operand: number, date serial, TRUE = 1, empty = 0, plain-number text.
    static func number(_ v: CellValue) -> Result<Double, FormulaError> {
        switch v {
        case .number(let x): return .success(x)
        case .date(let d): return .success(Double(d))
        case .bool(let b): return .success(b ? 1 : 0)
        case .empty: return .success(0)
        case .error(let err): return .failure(err)
        case .text(let s):
            guard let x = plainNumber(s) else { return .failure(.value) }
            return .success(x)
        }
    }

    /// Text that reads as a plain POSIX number (`3`, `-1.5`, `1e3`, surrounding spaces allowed), else nil.
    static func plainNumber(_ text: String) -> Double? {
        let s = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        var i = 0
        func digits() -> Int {
            let start = i
            while i < s.count, s[i] >= 0x30, s[i] <= 0x39 { i += 1 }
            return i - start
        }
        if i < s.count, s[i] == 0x2B || s[i] == 0x2D { i += 1 }        // + -
        var mantissa = digits()
        if i < s.count, s[i] == 0x2E { i += 1; mantissa += digits() }  // .
        guard mantissa > 0 else { return nil }
        if i < s.count, s[i] == 0x65 || s[i] == 0x45 {                  // e E
            i += 1
            if i < s.count, s[i] == 0x2B || s[i] == 0x2D { i += 1 }
            guard digits() > 0 else { return nil }
        }
        guard i == s.count, let x = Double(String(decoding: s, as: UTF8.self)), x.isFinite else { return nil }
        return x
    }

    static func finite(_ x: Double) -> CellValue { x.isFinite ? .number(x) : .error(.num) }

    /// A range's cells in a scalar position: a single cell is its value; anything larger
    /// is `#VALUE!` (no implicit intersection).
    static func single(_ cells: [[CellValue]]) -> CellValue {
        guard cells.count == 1, cells[0].count == 1 else { return .error(.value) }
        return cells[0][0]
    }

    /// Excel's ordering: numbers (dates as serials) < text < booleans; text case-insensitive;
    /// an empty cell is `0`, `""` or `FALSE` against those types. Numbers compare on their
    /// 15-significant-digit form, so `0.1+0.2=0.3` is TRUE.
    static func compare(_ a: CellValue, _ b: CellValue) -> ComparisonResult {
        var a = a, b = b
        if a == .empty { a = emptyAgainst(b) }
        if b == .empty { b = emptyAgainst(a) }
        switch (rank(a), rank(b)) {
        case (0, 0):
            let x = fifteen(numeric(a)), y = fifteen(numeric(b))
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case (1, 1):
            guard case .text(let s) = a, case .text(let t) = b else { return .orderedSame }
            return s.compare(t, options: [.caseInsensitive])
        case (2, 2):
            guard case .bool(let p) = a, case .bool(let q) = b else { return .orderedSame }
            return p == q ? .orderedSame : (p ? .orderedDescending : .orderedAscending)
        case (let i, let j):
            return i < j ? .orderedAscending : .orderedDescending
        }
    }

    private static func emptyAgainst(_ other: CellValue) -> CellValue {
        switch other {
        case .text: return .text("")
        case .bool: return .bool(false)
        default: return .number(0)
        }
    }

    private static func rank(_ v: CellValue) -> Int {
        switch v {
        case .text: return 1
        case .bool: return 2
        default: return 0
        }
    }

    private static func numeric(_ v: CellValue) -> Double {
        switch v {
        case .number(let x): return x
        case .date(let d): return Double(d)
        default: return 0
        }
    }

    /// `x` rounded to 15 significant digits, the precision Excel compares at.
    static func fifteen(_ x: Double) -> Double {
        guard x.isFinite, x != 0 else { return x }
        return Double(String(format: "%.15g", x)) ?? x
    }
}

extension CellValue {
    var isDate: Bool {
        if case .date = self { return true }
        return false
    }
}

/// A formula error is a Swift `Error`, so coercions return `Result<_, FormulaError>`.
extension FormulaError: Error {}

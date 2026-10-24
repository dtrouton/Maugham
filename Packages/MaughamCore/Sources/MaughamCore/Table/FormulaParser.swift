import Foundation

/// Why a formula could not be read: a writer-facing message and the character offset
/// (into the text after "=") where reading stopped.
public struct FormulaParseError: Error, Equatable, Sendable {
    public let message: String
    public let offset: Int
    public init(message: String, offset: Int) {
        self.message = message
        self.offset = offset
    }
}

/// Reads formula text into a `Formula` (Excel's precedence, refs resolved to ids),
/// writes it back as A1 text by current positions, and shifts it for fill/copy.
/// A hand-written recursive-descent parser: total over every input string.
public enum FormulaParser {
    /// `text` is what follows the "=". `table` resolves unqualified refs to ids; `figures` resolves `name!B2`.
    public static func parse(_ text: String, in table: FigureTable, figures: [String: FigureTable] = [:]) -> Result<Formula, FormulaParseError> {
        run(text, mode: .entry(table, figures))
    }

    /// Positional parse for a CSV: every ref is `.position`, no table needed.
    public static func parsePositional(_ text: String) -> Result<Formula, FormulaParseError> {
        run(text, mode: .positional)
    }

    /// The formula as A1 text (no leading "="), by current positions.
    public static func render(_ formula: Formula, in table: FigureTable, figures: [String: FigureTable] = [:]) -> String {
        Renderer(table: table, figures: figures).text(formula.expr)
    }

    /// Fill/copy: relative parts shift by the live-position delta from `from` to `to`;
    /// `$` parts stay. A ref (or either edge of a range) that leaves its live grid becomes
    /// `.error(.ref)`. Refs into a figure shift against that figure's grid in `figures`;
    /// research refs shift arithmetically and fall off below row/column 0.
    public static func translate(_ formula: Formula, from: CellKey, to: CellKey, in table: FigureTable,
                                 figures: [String: FigureTable] = [:]) -> Formula {
        guard let fr = table.rowIndex(of: from.row), let fc = table.columnIndex(of: from.column),
              let tr = table.rowIndex(of: to.row), let tc = table.columnIndex(of: to.column) else { return formula }
        let t = Translator(table: table, figures: figures, dRow: tr - fr, dColumn: tc - fc)
        return Formula(t.map(formula.expr))
    }

    private static func run(_ text: String, mode: Parser.Mode) -> Result<Formula, FormulaParseError> {
        var p = Parser(chars: Array(text), mode: mode)
        do {
            return .success(Formula(try p.parseFormula()))
        } catch let e as FormulaParseError {
            return .failure(e)
        } catch {
            return .failure(FormulaParseError(message: "This formula can't be read", offset: 0))
        }
    }

    /// The deepest syntax tree a formula may have (a leaf is depth 1). Measured
    /// 2026-10-24 on a 512 KB thread (Swift concurrency's and a secondary thread's stack):
    /// the costliest shape is nested calls around a range, and in a debug build its
    /// JSONEncoder encode overflows the stack at depth 108 (survives 106); unary and binary
    /// chains survive 140. A JSONDecoder round trip and a render also pass at this bound
    /// (pinned by FormulaParserTests' depth-bound tests). Excel's 64 nested functions fit.
    static let maxDepth = 100
    /// Excel's limit on a formula's length, in characters.
    static let maxLength = 8_192

    // MARK: - Shared grid lookups

    /// A figure name written without quotes: `[A-Za-z_][A-Za-z0-9_]*` and not shaped like
    /// a cell (`A1`). Any other name is quoted, as in `'cash-flow'!B2` (Excel's sheet rule).
    static func isBareFigureName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first == "_",
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return false }
        return A1.parse(name) == nil
    }

    /// A range as it now stands: each edge on a tombstone shrunk inward to the nearest
    /// live slot, normalised top-left first, each `$` travelling with its own edge.
    /// nil when an edge id is unknown or nothing between the edges is live (`#REF!`).
    static func liveRange(_ g: FormulaRange, in grid: FigureTable) -> FormulaRange? {
        guard case .id(let r0, let c0) = g.start.anchor, case .id(let r1, let c1) = g.end.anchor,
              let rs0 = grid.rowSlotIndex(of: r0), let rs1 = grid.rowSlotIndex(of: r1),
              let cs0 = grid.columnSlotIndex(of: c0), let cs1 = grid.columnSlotIndex(of: c1) else { return nil }
        let rows = grid.liveRows(betweenSlots: rs0, rs1), columns = grid.liveColumns(betweenSlots: cs0, cs1)
        guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last else { return nil }
        let rowsInOrder = rs0 <= rs1, columnsInOrder = cs0 <= cs1
        let s = g.start, e = g.end
        return FormulaRange(
            start: FormulaRef(target: s.target, anchor: .id(row: top, column: left),
                              rowAbsolute: rowsInOrder ? s.rowAbsolute : e.rowAbsolute,
                              columnAbsolute: columnsInOrder ? s.columnAbsolute : e.columnAbsolute),
            end: FormulaRef(target: e.target, anchor: .id(row: bottom, column: right),
                            rowAbsolute: rowsInOrder ? e.rowAbsolute : s.rowAbsolute,
                            columnAbsolute: columnsInOrder ? e.columnAbsolute : s.columnAbsolute))
    }

    static func grid(_ target: RefTarget, table: FigureTable, figures: [String: FigureTable]) -> FigureTable? {
        switch target {
        case .this: return table
        case .figure(let name): return figures[name]
        case .research: return nil
        }
    }

    /// A number literal as the formula bar shows it: integral values below 1e15 without
    /// ".0", otherwise up to 15 significant digits with trailing zeros trimmed, never `e`
    /// notation below 1e15. Locale-independent ("." always).
    static func numberText(_ x: Double) -> String {
        guard x.isFinite else { return FormulaError.num.rawValue }
        if x == 0 { return "0" }
        let a = abs(x)
        guard a < 1e15 else { return String(format: "%.15G", x) }
        if x == x.rounded() { return String(Int64(x)) }
        let exponent = Int(floor(log10(a)))
        let decimals = min(max(15 - (exponent + 1), 0), 340)
        var s = String(format: "%.\(decimals)f", x)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}

// MARK: - Parser

private struct Parser {
    enum Mode {
        case entry(FigureTable, [String: FigureTable])
        case positional
    }

    typealias Address = (row: Int, column: Int, rowAbsolute: Bool, columnAbsolute: Bool)

    let chars: [Character]
    let mode: Mode
    var i = 0
    /// Recursion now open: parentheses, calls' arguments and pending right operands.
    var nesting = 0

    static let maxDepth = FormulaParser.maxDepth
    static let maxLength = FormulaParser.maxLength
    static let tooBig = "This formula is too long or too deeply nested — try SUM or split it"

    typealias Node = (expr: FormulaExpr, depth: Int)

    init(chars: [Character], mode: Mode) {
        self.chars = chars
        self.mode = mode
    }

    func fail(_ message: String, at offset: Int? = nil) -> FormulaParseError {
        FormulaParseError(message: message, offset: offset ?? i)
    }

    var peek: Character? { i < chars.count ? chars[i] : nil }

    mutating func skipSpace() {
        while i < chars.count, chars[i].isWhitespace { i += 1 }
    }

    mutating func enter() throws {
        nesting += 1
        if nesting > Self.maxDepth { throw fail(Self.tooBig) }
    }

    /// Every node is built through here, so no tree deeper than `maxDepth` is ever made
    /// (a long flat `1+1+…` chain is left-deep: one level per operator).
    func node(_ expr: FormulaExpr, _ depth: Int) throws -> Node {
        if depth > Self.maxDepth { throw fail(Self.tooBig) }
        return (expr, depth)
    }

    func binary(_ op: BinaryOperator, _ l: Node, _ r: Node) throws -> Node {
        try node(.binary(op, l.expr, r.expr), max(l.depth, r.depth) + 1)
    }

    mutating func parseFormula() throws -> FormulaExpr {
        guard chars.count <= Self.maxLength else { throw fail(Self.tooBig, at: Self.maxLength) }
        skipSpace()
        guard i < chars.count else { throw fail("The formula is empty") }
        let e = try parseNested()
        skipSpace()
        if let c = peek {
            throw fail(c == ")" ? "There is a “)” without its “(”" : "Didn't expect “\(c)” here")
        }
        return e.expr
    }

    // The recursion is kept to small frames on purpose: each nesting level (a "(" or a
    // call's argument) costs parseNested → parseBinary → parseUnary → parsePrimary
    // (→ parseCall), and the bulky scanning lives in non-recursive helpers. In a debug
    // build the old one-function-per-level chain overflowed a 512 KB stack at ~45 levels.

    /// A whole expression one nesting level down: the top level, a "(…)" or an argument.
    mutating func parseNested() throws -> Node {
        try enter()
        defer { nesting -= 1 }
        return try parseBinary(1)
    }

    /// The binary operator at `i` with its level (1 comparison, 2 + -, 3 * /, 4 ^) and width.
    func peekBinary() -> (op: BinaryOperator, level: Int, width: Int)? {
        guard let c = peek else { return nil }
        let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
        switch c {
        case "<":
            if next == "=" { return (.lessOrEqual, 1, 2) }
            if next == ">" { return (.notEqual, 1, 2) }
            return (.less, 1, 1)
        case ">": return next == "=" ? (.greaterOrEqual, 1, 2) : (.greater, 1, 1)
        case "=": return (.equal, 1, 1)
        case "+": return (.add, 2, 1)
        case "-": return (.subtract, 2, 1)
        case "*": return (.multiply, 3, 1)
        case "/": return (.divide, 3, 1)
        case "^": return (.power, 4, 1)
        default: return nil
        }
    }

    /// Levels 1–4 by precedence climbing; every binary level is left-associative, as in
    /// Excel (`2^3^2` is 64).
    mutating func parseBinary(_ minLevel: Int) throws -> Node {
        var lhs = try parseUnary()
        while true {
            skipSpace()
            guard let (op, level, width) = peekBinary(), level >= minLevel else { return lhs }
            i += width
            // The right operand recurses while its binary node is still pending, so it
            // counts as nesting: a deep stack is never built before the depth check runs.
            try enter()
            let rhs = try parseBinary(level + 1)
            nesting -= 1
            lhs = try binary(op, lhs, rhs)
        }
    }

    /// Levels 5–6: prefix `- +` bind tighter than postfix `%` (`-2%` is `(-2)%`) and than
    /// `^` (`-2^2` is `(-2)^2`). Prefix runs are read in a loop, not by recursion.
    mutating func parseUnary() throws -> Node {
        let prefixes = try scanPrefixes()
        let operand = try parsePrimary()
        return try applyUnary(prefixes, to: operand)
    }

    mutating func scanPrefixes() throws -> [UnaryOperator] {
        var prefixes: [UnaryOperator] = []
        while true {
            skipSpace()
            if match("-") { prefixes.append(.negate) } else if match("+") { prefixes.append(.plus) } else { return prefixes }
            if prefixes.count > Self.maxDepth { throw fail(Self.tooBig) }
        }
    }

    mutating func applyUnary(_ prefixes: [UnaryOperator], to operand: Node) throws -> Node {
        var e = operand
        for op in prefixes.reversed() { e = try node(.unary(op, e.expr), e.depth + 1) }
        while true {
            skipSpace()
            if match("%") { e = try node(.unary(.percent, e.expr), e.depth + 1) } else { return e }
        }
    }

    /// Level 7. Only "(" and calls recurse; every other primary is read by `parseAtom`.
    mutating func parsePrimary() throws -> Node {
        skipSpace()
        if peek == "(" { return try parseParenthesised() }
        let start = i
        let atom = try parseAtom()
        guard let name = atom.callName else { return (atom.value, 1) }
        return try parseCall(name: name, at: start)
    }

    mutating func parseParenthesised() throws -> Node {
        let start = i
        i += 1
        let e = try parseNested()
        try expectClosingParenthesis(openedAt: start)
        return e
    }

    mutating func expectClosingParenthesis(openedAt start: Int) throws {
        skipSpace()
        guard match(")") else { throw fail("A “(” is missing its “)”", at: start) }
    }

    /// A leaf, or (`callName` set) a call whose "(" has been consumed.
    struct Atom {
        var value: FormulaExpr = .missing
        var callName: String?
        static func value(_ e: FormulaExpr) -> Atom { Atom(value: e) }
        static func call(_ name: String) -> Atom { Atom(callName: name) }
    }

    /// One leaf (number, text, bool, error, ref, range), or the name of a call whose "("
    /// has been consumed. Never recurses into an expression.
    mutating func parseAtom() throws -> Atom {
        guard let c = peek else { throw fail("The formula ends before its last value") }
        let start = i
        switch c {
        case "\"":
            return .value(.text(try parseString()))
        case "#":
            return .value(.error(try parseErrorLiteral()))
        case "$":
            return .value(try parseRefOrRange(target: .this))
        case "'":
            let name = try parseQuotedName(what: "table")
            guard match("!") else { throw fail("Expected “!” after the table name") }
            return .value(try parseAfterFigureQualifier(name))
        default:
            break
        }
        if c.isASCII, c.isNumber || c == "." { return .value(.number(try parseNumber())) }
        guard c.isASCII, c.isLetter || c == "_" else {
            throw fail(c == ")" || c == "," ? "Expected a value before “\(c)”" : "Didn't expect “\(c)” here")
        }
        // An unquoted figure name: [A-Za-z_][A-Za-z0-9_]* directly before "!" (a "-" is never part of it).
        var f = i
        while f < chars.count, chars[f].isASCII, chars[f].isLetter || chars[f].isNumber || chars[f] == "_" { f += 1 }
        if f < chars.count, chars[f] == "!" {
            let name = String(chars[i..<f])
            guard FormulaParser.isBareFigureName(name) else {
                throw fail("A table named like a cell needs quotes, as in '\(name)'!B2", at: start)
            }
            i = f + 1
            return .value(try parseAfterFigureQualifier(name))
        }
        var j = i
        while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." { j += 1 }
        let word = String(chars[i..<j])
        if word.lowercased() == "research", j < chars.count, chars[j] == ":" {
            i = j + 1
            let name = try parseResearchName()
            return .value(try parseRefOrRange(target: .research(name: name)))
        }
        var k = j
        while k < chars.count, chars[k].isWhitespace { k += 1 }
        if k < chars.count, chars[k] == "(" {
            i = k + 1
            return .call(word.uppercased())
        }
        switch word.uppercased() {
        case "TRUE": i = j; return .value(.bool(true))
        case "FALSE": i = j; return .value(.bool(false))
        default: break
        }
        if let (_, end) = A1.scan(chars, at: i), !continuesName(at: end) {
            return .value(try parseRefOrRange(target: .this))
        }
        throw fail("“\(word)” isn't a cell, a function or a value", at: start)
    }

    /// After `name!`: `#REF!` (a figure ref that fell off its grid) or a cell or range.
    mutating func parseAfterFigureQualifier(_ name: String) throws -> FormulaExpr {
        if peek == "#" { return .error(try parseErrorLiteral()) }
        return try parseRefOrRange(target: .figure(name: name))
    }

    /// A '…'-quoted name ('' is a quote), starting at the opening quote.
    mutating func parseQuotedName(what: String) throws -> String {
        let start = i
        i += 1
        var name = ""
        while true {
            guard let c = peek else { throw fail("The \(what) name is missing its closing “'”", at: start) }
            i += 1
            if c == "'" {
                if peek == "'" { name.append("'"); i += 1 } else { break }
            } else {
                name.append(c)
            }
        }
        guard !name.isEmpty else { throw fail("The \(what) name in quotes is empty", at: start) }
        return name
    }

    mutating func match(_ s: String) -> Bool {
        let sc = Array(s)
        guard i + sc.count <= chars.count, Array(chars[i..<(i + sc.count)]) == sc else { return false }
        i += sc.count
        return true
    }

    func continuesName(at j: Int) -> Bool {
        guard j < chars.count else { return false }
        let c = chars[j]
        return c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "." || c == "$")
    }

    static func isResearchNameCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == " " || c == "_" || c == "." || c == "-")
    }

    /// After "research:": a bare name `[A-Za-z0-9 _.-]+` or a quoted one ('' is a quote), then "!".
    mutating func parseResearchName() throws -> String {
        let start = i
        var name = ""
        if peek == "'" {
            name = try parseQuotedName(what: "research")
        } else {
            while let c = peek, Self.isResearchNameCharacter(c) { name.append(c); i += 1 }
            name = name.trimmingCharacters(in: .whitespaces)
        }
        guard !name.isEmpty else { throw fail("A research reference needs a name, like research:model!B2", at: start) }
        guard name.allSatisfy(Self.isResearchNameCharacter) else {
            throw fail("A research name uses letters, digits, spaces, “_”, “.” and “-”", at: start)
        }
        guard match("!") else { throw fail("Expected “!” after the research name", at: i) }
        return name
    }

    mutating func parseString() throws -> String {
        let start = i
        i += 1
        var s = ""
        while true {
            guard let c = peek else { throw fail("Text is missing its closing quote", at: start) }
            i += 1
            if c == "\"" {
                if peek == "\"" { s.append("\""); i += 1 } else { return s }
            } else {
                s.append(c)
            }
        }
    }

    mutating func parseErrorLiteral() throws -> FormulaError {
        let start = i
        for e in FormulaError.allCases {
            let raw = Array(e.rawValue)
            guard i + raw.count <= chars.count else { continue }
            if String(chars[i..<(i + raw.count)]).uppercased() == e.rawValue {
                i += raw.count
                return e
            }
        }
        var j = i + 1
        while j < chars.count, !chars[j].isWhitespace, j - i < 12 { j += 1 }
        throw fail("“\(String(chars[i..<j]))” isn't an error value", at: start)
    }

    mutating func parseNumber() throws -> Double {
        let start = i
        var j = i
        func digits() { while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 } }
        digits()
        let intDigits = j - start
        var fracDigits = 0
        if j < chars.count, chars[j] == "." {
            j += 1
            let f = j
            digits()
            fracDigits = j - f
        }
        guard intDigits + fracDigits > 0 else { throw fail("Didn't expect “.” here", at: start) }
        if j < chars.count, chars[j] == "e" || chars[j] == "E" {
            var k = j + 1
            if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
            let d = k
            while k < chars.count, chars[k].isASCII, chars[k].isNumber { k += 1 }
            if k > d { j = k }
        }
        let text = String(chars[start..<j])
        guard let value = Double(text), value.isFinite else { throw fail("“\(text)” is too large a number", at: start) }
        i = j
        return value
    }

    /// A call costs one level of nesting (its arguments' own `parseNested`), so
    /// Excel's 64 nested functions fit.
    mutating func parseCall(name: String, at start: Int) throws -> Node {
        var arguments: [FormulaExpr] = []
        var deepest = 0
        skipSpace()
        if !match(")") {
            repeat {
                skipSpace()
                if peek == "," || peek == ")" {
                    arguments.append(.missing)
                } else {
                    let argument = try parseNested()
                    arguments.append(argument.expr)
                    deepest = max(deepest, argument.depth)
                }
            } while try argumentSeparator(in: name, at: start)
        }
        return try node(.call(name: name, arguments: arguments), deepest + 1)
    }

    /// After an argument: true for ",", false for ")", else the writer-facing error.
    mutating func argumentSeparator(in name: String, at start: Int) throws -> Bool {
        skipSpace()
        if match(",") { return true }
        if match(")") { return false }
        if peek == nil { throw fail("“\(name)(” is missing its “)”", at: start) }
        throw fail("Expected “,” or “)” in \(name)")
    }

    mutating func parseRefOrRange(target: RefTarget) throws -> FormulaExpr {
        let start = i
        guard let (a, endA) = A1.scan(chars, at: i), !continuesName(at: endA) else {
            throw fail("Expected a cell like B2 here", at: start)
        }
        i = endA
        guard peek == ":" else { return .ref(try resolve(a, target: target, at: start)) }
        i += 1
        let startB = i
        guard let (b, endB) = A1.scan(chars, at: i), !continuesName(at: endB) else {
            throw fail("Expected a cell after “:”", at: startB)
        }
        i = endB
        // Excel normalises B3:A1 to A1:B3; each `$` travels with its part.
        let rows = a.row <= b.row ? (a.row, a.rowAbsolute, b.row, b.rowAbsolute) : (b.row, b.rowAbsolute, a.row, a.rowAbsolute)
        let cols = a.column <= b.column ? (a.column, a.columnAbsolute, b.column, b.columnAbsolute)
                                        : (b.column, b.columnAbsolute, a.column, a.columnAbsolute)
        // Bounds are reported against each corner as typed.
        _ = try resolve(a, target: target, at: start)
        _ = try resolve(b, target: target, at: startB)
        let s = try resolve((rows.0, cols.0, rows.1, cols.1), target: target, at: start)
        let e = try resolve((rows.2, cols.2, rows.3, cols.3), target: target, at: startB)
        return .range(FormulaRange(start: s, end: e))
    }

    func resolve(_ a: Address, target: RefTarget, at offset: Int) throws -> FormulaRef {
        func positional() -> FormulaRef {
            FormulaRef(target: target, anchor: .position(row: a.row, column: a.column),
                       rowAbsolute: a.rowAbsolute, columnAbsolute: a.columnAbsolute)
        }
        guard case .entry(let table, let figures) = mode else { return positional() }
        let grid: FigureTable
        let outside: String
        let shown = A1.render(row: a.row, column: a.column, rowAbsolute: false, columnAbsolute: false)
        switch target {
        case .research:
            return positional()
        case .this:
            grid = table
            outside = "\(shown) is outside this table"
        case .figure(let name):
            guard let g = figures[name] else { throw fail("There is no table named \(name)", at: offset) }
            grid = g
            outside = "\(shown) is outside the table named \(name)"
        }
        let rows = grid.rows, columns = grid.columns
        guard a.row < rows.count, a.column < columns.count else { throw fail(outside, at: offset) }
        return FormulaRef(target: target, anchor: .id(row: rows[a.row], column: columns[a.column]),
                          rowAbsolute: a.rowAbsolute, columnAbsolute: a.columnAbsolute)
    }
}

// MARK: - Renderer

private struct Renderer {
    let table: FigureTable
    let figures: [String: FigureTable]

    /// Binding strength, loosest 1 … tightest 7 (the grammar's levels).
    static func level(_ e: FormulaExpr) -> Int {
        switch e {
        case .binary(let op, _, _):
            switch op {
            case .equal, .notEqual, .less, .greater, .lessOrEqual, .greaterOrEqual: return 1
            case .add, .subtract: return 2
            case .multiply, .divide: return 3
            case .power: return 4
            }
        case .unary(.percent, _): return 5
        case .unary: return 6
        case .number(let x) where x < 0: return 6
        default: return 7
        }
    }

    static func symbol(_ op: BinaryOperator) -> String {
        switch op {
        case .add: return "+"
        case .subtract: return "-"
        case .multiply: return "*"
        case .divide: return "/"
        case .power: return "^"
        case .equal: return "="
        case .notEqual: return "<>"
        case .less: return "<"
        case .greater: return ">"
        case .lessOrEqual: return "<="
        case .greaterOrEqual: return ">="
        }
    }

    func wrapped(_ e: FormulaExpr, _ parens: Bool) -> String {
        parens ? "(" + text(e) + ")" : text(e)
    }

    func text(_ e: FormulaExpr) -> String {
        switch e {
        case .number(let x): return FormulaParser.numberText(x)
        case .text(let s): return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .missing: return ""
        case .error(let err): return err.rawValue
        case .ref(let r): return prefix(r.target) + (cell(r) ?? FormulaError.ref.rawValue)
        case .range(let g): return rangeText(g)
        case .call(let name, let arguments): return name + "(" + arguments.map(text).joined(separator: ",") + ")"
        case .unary(let op, let operand):
            switch op {
            case .negate: return "-" + wrapped(operand, Self.level(operand) < 6)
            case .plus: return "+" + wrapped(operand, Self.level(operand) < 6)
            case .percent: return wrapped(operand, Self.level(operand) < 5) + "%"
            }
        case .binary(let op, let l, let r):
            let p = Self.level(e)
            return wrapped(l, Self.level(l) < p) + Self.symbol(op) + wrapped(r, Self.level(r) <= p)
        }
    }

    func prefix(_ target: RefTarget) -> String {
        switch target {
        case .this: return ""
        case .figure(let name): return (FormulaParser.isBareFigureName(name) ? name : Self.quoted(name)) + "!"
        case .research(let name):
            let bare = !name.isEmpty && !name.contains(" ") && !name.contains("'")
                && name.trimmingCharacters(in: .whitespaces) == name
            return "research:" + (bare ? name : Self.quoted(name)) + "!"
        }
    }

    static func quoted(_ name: String) -> String {
        "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }

    func cell(_ r: FormulaRef) -> String? {
        switch r.anchor {
        case .position(let row, let column):
            return A1.render(row: row, column: column, rowAbsolute: r.rowAbsolute, columnAbsolute: r.columnAbsolute)
        case .id(let rowID, let columnID):
            guard let grid = FormulaParser.grid(r.target, table: table, figures: figures),
                  let row = grid.rowIndex(of: rowID), let column = grid.columnIndex(of: columnID) else { return nil }
            return A1.render(row: row, column: column, rowAbsolute: r.rowAbsolute, columnAbsolute: r.columnAbsolute)
        }
    }

    func rangeText(_ g: FormulaRange) -> String {
        let p = prefix(g.start.target)
        let s = g.start, e = g.end
        switch (s.anchor, e.anchor) {
        case (.position(let r0, let c0), .position(let r1, let c1)):
            return p + A1.render(row: r0, column: c0, rowAbsolute: s.rowAbsolute, columnAbsolute: s.columnAbsolute)
                + ":" + A1.render(row: r1, column: c1, rowAbsolute: e.rowAbsolute, columnAbsolute: e.columnAbsolute)
        case (.id, .id):
            guard let grid = FormulaParser.grid(s.target, table: table, figures: figures),
                  let live = FormulaParser.liveRange(g, in: grid),
                  let a = cell(live.start), let b = cell(live.end)
            else { return p + FormulaError.ref.rawValue }
            return p + a + ":" + b
        default:
            return p + FormulaError.ref.rawValue
        }
    }
}

// MARK: - Translator

private struct Translator {
    let table: FigureTable
    let figures: [String: FigureTable]
    let dRow: Int
    let dColumn: Int

    func map(_ e: FormulaExpr) -> FormulaExpr {
        switch e {
        case .number, .text, .bool, .missing, .error: return e
        case .ref(let r): return shift(r).map { .ref($0) } ?? .error(.ref)
        case .range(let g): return shift(g).map { .range($0) } ?? .error(.ref)
        case .unary(let op, let x): return .unary(op, map(x))
        case .binary(let op, let l, let r): return .binary(op, map(l), map(r))
        case .call(let name, let arguments): return .call(name: name, arguments: arguments.map(map))
        }
    }

    func shift(_ r: FormulaRef) -> FormulaRef? {
        var out = r
        switch r.anchor {
        case .position(let row, let column):
            let newRow = r.rowAbsolute ? row : row + dRow
            let newColumn = r.columnAbsolute ? column : column + dColumn
            guard newRow >= 0, newColumn >= 0 else { return nil }
            out.anchor = .position(row: newRow, column: newColumn)
        case .id(let rowID, let columnID):
            guard let grid = FormulaParser.grid(r.target, table: table, figures: figures) else {
                return r.rowAbsolute && r.columnAbsolute ? r : nil
            }
            guard let ri = grid.rowIndex(of: rowID), let ci = grid.columnIndex(of: columnID) else { return nil }
            let rows = grid.rows, columns = grid.columns
            let newRow = r.rowAbsolute ? ri : ri + dRow
            let newColumn = r.columnAbsolute ? ci : ci + dColumn
            guard rows.indices.contains(newRow), columns.indices.contains(newColumn) else { return nil }
            out.anchor = .id(row: rows[newRow], column: columns[newColumn])
        }
        return out
    }

    func shift(_ g: FormulaRange) -> FormulaRange? {
        var range = g
        var grid: FigureTable?
        if case .id = g.start.anchor {
            // Shift the range as it now stands: a tombstoned edge has already shrunk inward.
            guard let found = FormulaParser.grid(g.start.target, table: table, figures: figures) else {
                // A figure that isn't here: as for a single ref, only a wholly absolute range survives.
                let pinned = [g.start, g.end].allSatisfy { $0.rowAbsolute && $0.columnAbsolute }
                return pinned ? g : nil
            }
            guard let live = FormulaParser.liveRange(g, in: found) else { return nil }
            range = live
            grid = found
        }
        guard let s = shift(range.start), let e = shift(range.end) else { return nil }
        // An absolute edge can be passed by its relative partner (A$3:A3 filled up two
        // rows): re-normalise per axis, each `$` travelling with its own edge.
        guard let (sr, sc) = position(s, in: grid), let (er, ec) = position(e, in: grid) else { return nil }
        var out = FormulaRange(start: s, end: e)
        if sr > er { Self.swapRows(&out) }
        if sc > ec { Self.swapColumns(&out) }
        return out
    }

    private func position(_ r: FormulaRef, in grid: FigureTable?) -> (Int, Int)? {
        switch r.anchor {
        case .position(let row, let column): return (row, column)
        case .id(let row, let column):
            guard let grid, let ri = grid.rowIndex(of: row), let ci = grid.columnIndex(of: column) else { return nil }
            return (ri, ci)
        }
    }

    private static func swapRows(_ g: inout FormulaRange) {
        switch (g.start.anchor, g.end.anchor) {
        case let (.id(r0, c0), .id(r1, c1)):
            g.start.anchor = .id(row: r1, column: c0); g.end.anchor = .id(row: r0, column: c1)
        case let (.position(r0, c0), .position(r1, c1)):
            g.start.anchor = .position(row: r1, column: c0); g.end.anchor = .position(row: r0, column: c1)
        default: return
        }
        swap(&g.start.rowAbsolute, &g.end.rowAbsolute)
    }

    private static func swapColumns(_ g: inout FormulaRange) {
        switch (g.start.anchor, g.end.anchor) {
        case let (.id(r0, c0), .id(r1, c1)):
            g.start.anchor = .id(row: r0, column: c1); g.end.anchor = .id(row: r1, column: c0)
        case let (.position(r0, c0), .position(r1, c1)):
            g.start.anchor = .position(row: r0, column: c1); g.end.anchor = .position(row: r1, column: c0)
        default: return
        }
        swap(&g.start.columnAbsolute, &g.end.columnAbsolute)
    }
}

import Foundation

/// Which grid a reference reads: this table, another figure in the document, or a pinned
/// research CSV — each by its hidden id (Denver's ruling R-D1). The writer types and reads
/// names; `FormulaNames` turns one into the other, so a rename rewrites no formula.
public enum RefTarget: Hashable, Codable, Sendable {
    case this
    case figure(id: String)       // the figure's `FigureRecord.id`
    case research(id: String)     // the research item's `ResearchItem.id`
}

/// Where a reference points. A ref into this table or a figure is stored by id, so
/// inserting, deleting and moving rows never re-points it; a research CSV has no ids.
public enum RefAnchor: Hashable, Codable, Sendable {
    case id(row: RowID, column: ColumnID)     // this / figure, when resolvable at entry
    case position(row: Int, column: Int)      // research always; a figure ref read from a CSV
}

/// One cell reference with Excel's `$` flags (they govern fill/copy only).
public struct FormulaRef: Hashable, Codable, Sendable {
    public var target: RefTarget
    public var anchor: RefAnchor
    public var rowAbsolute: Bool
    public var columnAbsolute: Bool

    public init(target: RefTarget, anchor: RefAnchor, rowAbsolute: Bool = false, columnAbsolute: Bool = false) {
        self.target = target
        self.anchor = anchor
        self.rowAbsolute = rowAbsolute
        self.columnAbsolute = columnAbsolute
    }
}

/// A rectangular range; both edges share one target. Its cells are the live slots
/// between the edges' slot indices, so deleting an edge row shrinks it (Excel's rule).
public struct FormulaRange: Hashable, Codable, Sendable {
    public var start: FormulaRef
    public var end: FormulaRef

    public init(start: FormulaRef, end: FormulaRef) {
        self.start = start
        self.end = end
    }
}

public enum UnaryOperator: String, Codable, Sendable { case negate, plus, percent }

public enum BinaryOperator: String, Codable, Sendable {
    case add, subtract, multiply, divide, power, equal, notEqual, less, greater, lessOrEqual, greaterOrEqual
}

/// A formula's syntax tree. Parentheses leave no node: the renderer puts back the
/// ones Excel's precedence needs.
public indirect enum FormulaExpr: Equatable, Codable, Sendable {
    case number(Double), text(String), bool(Bool), missing          // `missing` = an empty argument: PV(r, n, , 0)
    case ref(FormulaRef), range(FormulaRange)
    case unary(UnaryOperator, FormulaExpr), binary(BinaryOperator, FormulaExpr, FormulaExpr)
    case call(name: String, arguments: [FormulaExpr])               // name uppercased; unknown names are kept
    case error(FormulaError)                                        // a ref that fell off the grid in a fill
}

// MARK: The wire format

/// Written out so the op log's payload is a visible contract (pinned by golden fixtures):
/// `{"<case>":{…}}`, positional payloads under `_0`, `_1`, `_2`, a call's under `name` and
/// `arguments`, `missing` as `{}`. Decoding refuses a tree deeper than `FormulaParser.maxDepth`
/// before it recurses further, so a corrupt or hostile line cannot exhaust a small stack.
extension FormulaExpr {
    private enum CodingKeys: String, CodingKey { case number, text, bool, missing, ref, range, unary, binary, call, error }
    private enum Positional: String, CodingKey { case _0, _1, _2 }
    private enum CallKeys: String, CodingKey { case name, arguments }
    private static let recursiveKeys: Set<String> = [CodingKeys.unary.rawValue, CodingKeys.binary.rawValue, CodingKeys.call.rawValue]

    public init(from decoder: Decoder) throws {
        // Each enclosing operator or call left its case key on the path; this node is one deeper.
        let depth = decoder.codingPath.lazy.filter { Self.recursiveKeys.contains($0.stringValue) }.count + 1
        guard depth <= FormulaParser.maxDepth else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Formula nested deeper than \(FormulaParser.maxDepth)"))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "A formula node has exactly one case key"))
        }
        func n() throws -> KeyedDecodingContainer<Positional> { try c.nestedContainer(keyedBy: Positional.self, forKey: key) }
        switch key {
        case .number: self = .number(try n().decode(Double.self, forKey: ._0))
        case .text: self = .text(try n().decode(String.self, forKey: ._0))
        case .bool: self = .bool(try n().decode(Bool.self, forKey: ._0))
        case .missing: self = .missing
        case .ref: self = .ref(try n().decode(FormulaRef.self, forKey: ._0))
        case .range: self = .range(try n().decode(FormulaRange.self, forKey: ._0))
        case .unary:
            let p = try n()
            self = .unary(try p.decode(UnaryOperator.self, forKey: ._0), try p.decode(FormulaExpr.self, forKey: ._1))
        case .binary:
            let p = try n()
            self = .binary(try p.decode(BinaryOperator.self, forKey: ._0),
                           try p.decode(FormulaExpr.self, forKey: ._1), try p.decode(FormulaExpr.self, forKey: ._2))
        case .call:
            let p = try c.nestedContainer(keyedBy: CallKeys.self, forKey: key)
            self = .call(name: try p.decode(String.self, forKey: .name), arguments: try p.decode([FormulaExpr].self, forKey: .arguments))
        case .error: self = .error(try n().decode(FormulaError.self, forKey: ._0))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .call(let name, let arguments):
            var n = c.nestedContainer(keyedBy: CallKeys.self, forKey: .call)
            try n.encode(name, forKey: .name)
            try n.encode(arguments, forKey: .arguments)
        case .number(let x): var n = c.nestedContainer(keyedBy: Positional.self, forKey: .number); try n.encode(x, forKey: ._0)
        case .text(let s): var n = c.nestedContainer(keyedBy: Positional.self, forKey: .text); try n.encode(s, forKey: ._0)
        case .bool(let b): var n = c.nestedContainer(keyedBy: Positional.self, forKey: .bool); try n.encode(b, forKey: ._0)
        case .missing: _ = c.nestedContainer(keyedBy: Positional.self, forKey: .missing)
        case .ref(let r): var n = c.nestedContainer(keyedBy: Positional.self, forKey: .ref); try n.encode(r, forKey: ._0)
        case .range(let g): var n = c.nestedContainer(keyedBy: Positional.self, forKey: .range); try n.encode(g, forKey: ._0)
        case .unary(let op, let x):
            var n = c.nestedContainer(keyedBy: Positional.self, forKey: .unary)
            try n.encode(op, forKey: ._0); try n.encode(x, forKey: ._1)
        case .binary(let op, let l, let r):
            var n = c.nestedContainer(keyedBy: Positional.self, forKey: .binary)
            try n.encode(op, forKey: ._0); try n.encode(l, forKey: ._1); try n.encode(r, forKey: ._2)
        case .error(let e): var n = c.nestedContainer(keyedBy: Positional.self, forKey: .error); try n.encode(e, forKey: ._0)
        }
    }
}

/// A cell's formula: its syntax tree, refs stored by id. `FormulaParser` reads and writes the text.
public struct Formula: Equatable, Codable, Sendable {
    public var expr: FormulaExpr
    public init(_ expr: FormulaExpr) { self.expr = expr }
}

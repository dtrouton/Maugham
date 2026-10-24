import Foundation

/// Which grid a reference reads: this table, another figure in the document by name,
/// or a pinned research CSV by name.
public enum RefTarget: Hashable, Codable, Sendable {
    case this
    case figure(name: String)
    case research(name: String)
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

/// A cell's formula: its syntax tree, refs stored by id. `FormulaParser` reads and writes the text.
public struct Formula: Equatable, Codable, Sendable {
    public var expr: FormulaExpr
    public init(_ expr: FormulaExpr) { self.expr = expr }
}

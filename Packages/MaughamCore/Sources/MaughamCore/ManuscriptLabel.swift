import Foundation

/// A cross-reference label such as `fig:revenue`: a kind and a name.
public struct ManuscriptLabel: Hashable, Sendable {
    /// The three label kinds a manuscript may carry.
    public enum Kind: String, Sendable, CaseIterable { case fig, tbl, sec }

    /// What the label names: a figure, a table or a section.
    public let kind: Kind
    /// The part after the colon; matches `[A-Za-z0-9][A-Za-z0-9_-]*`.
    public let name: String

    /// The label as written after `#` or `@`, e.g. `"fig:revenue"`.
    public var reference: String { "\(kind.rawValue):\(name)" }

    /// Parses `"kind:name"`; nil for an unknown kind or an invalid name.
    public init?(reference: String) {
        guard let colon = reference.firstIndex(of: ":"),
              let kind = Kind(rawValue: String(reference[..<colon])) else { return nil }
        let name = String(reference[reference.index(after: colon)...])
        guard Self.isValidName(name) else { return nil }
        self.kind = kind
        self.name = name
    }

    /// True when `name` matches `[A-Za-z0-9][A-Za-z0-9_-]*` (ASCII only).
    /// Citation keys follow the same rule.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isAlnum(first) else { return false }
        return name.unicodeScalars.allSatisfy(isNameScalar)
    }

    /// True for a character a name may contain: `[A-Za-z0-9_-]`.
    static func isNameScalar(_ s: Unicode.Scalar) -> Bool {
        isAlnum(s) || s == "_" || s == "-"
    }

    static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
    }
}

public extension ManuscriptLabel.Kind {
    /// **Which list a figure line numbers in, and so which label kind it
    /// takes** (report plan 7a ruling R7a-1): a table figure's line,
    /// labelled `tbl:` or unlabelled, is a table (numbered in the Tables
    /// list; a `@tbl:` target when labelled); every other figure line is a
    /// figure. A table figure's line is the one whose path names a `.csv`
    /// (`figures/<name>.csv`, any case), read off the line alone, no
    /// registry. An image line labelled `tbl:` or a table figure labelled
    /// `fig:` is a kind mismatch that keeps the figure answer here (diagnosed
    /// in plan 7b). The one rule the editor's index, its live checks,
    /// `ManuscriptIndex` and Publish's numbering share, so they agree.
    static func ofFigureLine(path: String, label: ManuscriptLabel?) -> Self {
        isTableFigurePath(path) && label?.kind != .fig ? .tbl : .fig
    }

    /// Whether a figure line's path names a table figure's render (`.csv`,
    /// any case); the editor's thumbnail store asks the same.
    static func isTableFigurePath(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "csv"
    }
}

/// Reads the trailing `{#kind:name}` attribute block of a line.
public enum ManuscriptAttributes {
    /// Splits a trailing `{#kind:name}` off a line. Returns the text with the
    /// block and the whitespace before it removed, plus the label. A block that
    /// is not at the very end, or names an unknown kind or an invalid name,
    /// leaves the text untouched with label nil.
    public static func split(_ line: String) -> (text: String, label: ManuscriptLabel?) {
        guard line.hasSuffix("}"),
              let open = line.range(of: "{#", options: .backwards) else { return (line, nil) }
        let inner = line[open.upperBound..<line.index(before: line.endIndex)]
        guard let label = ManuscriptLabel(reference: String(inner)) else { return (line, nil) }
        var text = line[..<open.lowerBound]
        while let last = text.last, last == " " || last == "\t" { text.removeLast() }
        return (String(text), label)
    }
}

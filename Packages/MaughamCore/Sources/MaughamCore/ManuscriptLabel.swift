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

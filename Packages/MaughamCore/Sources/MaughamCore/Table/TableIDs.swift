import Foundation

/// A row's stable identity within one figure table; never its position.
public struct RowID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// A column's stable identity within one figure table; never its position.
public struct ColumnID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public enum TableID {
    /// The same 32-character alphabet as `ParagraphID` (no i, l, o, u).
    static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

    /// 8 characters from ParagraphID's alphabet, never one in `used`.
    public static func mint(excluding used: Set<String>) -> String {
        var generator = SystemRandomNumberGenerator()
        while true {
            var chars = [Character]()
            chars.reserveCapacity(8)
            for _ in 0..<8 { chars.append(alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]) }
            let id = String(chars)
            if !used.contains(id) { return id }
        }
    }
}

/// One cell's address: a row id and a column id.
public struct CellKey: Hashable, Codable, Sendable {
    public let row: RowID
    public let column: ColumnID
    public init(row: RowID, column: ColumnID) { self.row = row; self.column = column }
}

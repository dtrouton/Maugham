import Foundation

/// A1 notation: column letters, row numbers (1-based on screen, 0-based here),
/// and `$` absolute markers.
public enum A1 {
    /// Excel's grid limits; a longer address is not a cell (it may be a name).
    static let maxColumns = 16_384      // XFD
    static let maxRows = 1_048_576

    /// 0 → "A", 25 → "Z", 26 → "AA", 701 → "ZZ", 702 → "AAA". A negative index gives "".
    public static func columnLetters(_ index: Int) -> String {
        guard index >= 0 else { return "" }
        var n = index + 1
        var scalars = [Character]()
        while n > 0 {
            let r = (n - 1) % 26
            scalars.append(Character(Unicode.Scalar(UInt8(65 + r))))
            n = (n - 1) / 26
        }
        return String(scalars.reversed())
    }

    /// The inverse of `columnLetters`; case-insensitive; nil for anything but ASCII letters
    /// (and for more than six letters, which no grid reaches).
    public static func columnIndex(_ letters: String) -> Int? {
        guard !letters.isEmpty, letters.count <= 6 else { return nil }
        var n = 0
        for ch in letters {
            guard let a = ch.asciiValue else { return nil }
            let v: Int
            switch a {
            case 65...90: v = Int(a) - 64
            case 97...122: v = Int(a) - 96
            default: return nil
            }
            n = n * 26 + v
        }
        return n - 1
    }

    /// "$B$2" → (1, 1, true, true); "b2" → (1, 1, false, false). 0-based. nil unless the
    /// whole text is one address inside Excel's grid ("A0", "2B" and "B" are nil).
    public static func parse(_ text: String) -> (row: Int, column: Int, rowAbsolute: Bool, columnAbsolute: Bool)? {
        let chars = Array(text)
        guard let (address, end) = scan(chars, at: 0), end == chars.count else { return nil }
        return address
    }

    /// The A1 text of a position: `$` before each absolute part.
    static func render(row: Int, column: Int, rowAbsolute: Bool, columnAbsolute: Bool) -> String {
        (columnAbsolute ? "$" : "") + columnLetters(column) + (rowAbsolute ? "$" : "") + String(row + 1)
    }

    /// Scans one address starting at `start`; returns it and the index just past it.
    /// Does not look at what follows (the caller decides whether that ends the token).
    static func scan(_ chars: [Character], at start: Int) -> ((row: Int, column: Int, rowAbsolute: Bool, columnAbsolute: Bool), Int)? {
        var i = start
        var columnAbsolute = false, rowAbsolute = false
        if i < chars.count, chars[i] == "$" { columnAbsolute = true; i += 1 }
        let lettersStart = i
        while i < chars.count, chars[i].isASCII, chars[i].isLetter { i += 1 }
        guard i > lettersStart, i - lettersStart <= 3,
              let column = columnIndex(String(chars[lettersStart..<i])), column < maxColumns else { return nil }
        if i < chars.count, chars[i] == "$" { rowAbsolute = true; i += 1 }
        let digitsStart = i
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
        guard i > digitsStart, i - digitsStart <= 7,
              let row = Int(String(chars[digitsStart..<i])), row >= 1, row <= maxRows else { return nil }
        return ((row - 1, column, rowAbsolute, columnAbsolute), i)
    }
}

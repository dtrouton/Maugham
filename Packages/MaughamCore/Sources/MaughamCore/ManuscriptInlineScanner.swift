import Foundation

/// One cited source inside a `[@…]` citation: its key and optional locator.
public struct CitationItem: Equatable, Sendable {
    /// The research item's citation key; follows the label name rule.
    public let key: String
    /// The text after the key's comma, trimmed, e.g. `"p. 12"`.
    public let locator: String?

    public init(key: String, locator: String?) {
        self.key = key
        self.locator = locator
    }
}

/// A marker inside a sentence.
public enum ManuscriptInline: Equatable, Sendable {
    /// `[^label]`.
    case footnoteRef(label: String)
    /// `[@key]`, `[@key, p. 12]`, `[@a; @b]`.
    case citation([CitationItem])
    /// `@fig:name`, or `[@fig:name]` in brackets.
    case crossRef(ManuscriptLabel)
}

/// Finds footnote references, citations and cross-references in text.
/// Nothing inside a backtick code span or after a backslash is read. A marker
/// never spans a line break.
public enum ManuscriptInlineScanner {
    /// Every marker in `text`, with its UTF-16 NSRange (the editor's unit), in order.
    /// A bracketed cross-reference covers the whole bracket when it holds one
    /// label; with several labels, each covers its own `@kind:name`.
    public static func scan(_ text: String) -> [(marker: ManuscriptInline, range: NSRange)] {
        var scanner = Scanner(text: text)
        return scanner.run()
    }

    private struct Scanner {
        let text: NSString
        let u: [UInt16]
        var out: [(marker: ManuscriptInline, range: NSRange)] = []

        init(text: String) {
            self.text = text as NSString
            self.u = Array(text.utf16)
        }

        mutating func run() -> [(marker: ManuscriptInline, range: NSRange)] {
            var i = 0
            while i < u.count {
                switch u[i] {
                case backslash: i += 2
                case backtick: i = skipCodeSpan(i)
                case openBracket where at(i + 1) == caret: i = footnote(i)
                case openBracket where at(i + 1) == atSign: i = bracket(i)
                case atSign: i = bare(i)
                default: i += 1
                }
            }
            return out
        }

        // MARK: Pieces

        /// A run of backticks opens a span closed by the next run of the same
        /// length; with no closer, the run is literal text.
        func skipCodeSpan(_ start: Int) -> Int {
            let open = runLength(of: backtick, at: start)
            var j = start + open
            while j < u.count {
                if u[j] == backtick {
                    let run = runLength(of: backtick, at: j)
                    if run == open { return j + run }
                    j += run
                } else {
                    j += 1
                }
            }
            return start + open
        }

        /// `[^label]`, except a definition head `[^label]:` at the start of a line.
        mutating func footnote(_ start: Int) -> Int {
            var j = start + 2
            while j < u.count, u[j] != closeBracket, u[j] != newline, u[j] != openBracket { j += 1 }
            guard at(j) == closeBracket else { return start + 1 }
            let label = string(start + 2, j)
            guard ManuscriptBlocks.isValidFootnoteLabel(label) else { return start + 1 }
            if at(j + 1) == colon, isLineStart(start) { return j + 2 }
            out.append((.footnoteRef(label: label), NSRange(location: start, length: j + 1 - start)))
            return j + 1
        }

        /// `[@key, locator; @key]` as a citation, or `[@kind:name; …]` as
        /// cross-references. Anything else is not a bracket form: scanning
        /// resumes after the `[`, so a label inside still reads bare.
        mutating func bracket(_ start: Int) -> Int {
            enum Item { case key(String, String?), label(ManuscriptLabel, NSRange, hasLocator: Bool) }
            var items: [Item] = []
            var p = start + 1
            while true {
                p = skipSpaces(p)
                guard at(p) == atSign else { return start + 1 }
                let itemStart = p
                p += 1
                let token = readName(&p)
                var label: ManuscriptLabel?
                if at(p) == colon {
                    p += 1
                    let name = readName(&p)
                    guard let l = ManuscriptLabel(reference: token + ":" + name) else { return start + 1 }
                    label = l
                } else if !ManuscriptLabel.isValidName(token) {
                    return start + 1
                }
                let itemRange = NSRange(location: itemStart, length: p - itemStart)
                p = skipSpaces(p)
                var locator: String?
                if at(p) == comma {
                    let from = p + 1
                    p = from
                    while p < u.count, u[p] != semicolon, u[p] != closeBracket, u[p] != newline { p += 1 }
                    let trimmed = string(from, p).trimmingCharacters(in: .whitespaces)
                    locator = trimmed.isEmpty ? nil : trimmed
                }
                if let label {
                    items.append(.label(label, itemRange, hasLocator: locator != nil))
                } else {
                    items.append(.key(token, locator))
                }
                if at(p) == semicolon { p += 1; continue }
                guard at(p) == closeBracket else { return start + 1 }
                p += 1
                break
            }
            let whole = NSRange(location: start, length: p - start)
            let keys = items.compactMap { item -> CitationItem? in
                if case .key(let k, let loc) = item { return CitationItem(key: k, locator: loc) }
                return nil
            }
            if keys.count == items.count {
                out.append((.citation(keys), whole))
                return p
            }
            let labels = items.compactMap { item -> (ManuscriptLabel, NSRange)? in
                if case .label(let l, let r, false) = item { return (l, r) }
                return nil
            }
            guard labels.count == items.count else { return start + 1 }
            for (l, r) in labels { out.append((.crossRef(l), labels.count == 1 ? whole : r)) }
            return p
        }

        /// `@kind:name` whose `@` does not follow an email-address character.
        mutating func bare(_ start: Int) -> Int {
            if start > 0, isEmailUnit(u[start - 1]) { return start + 1 }
            var p = start + 1
            let token = readName(&p)
            guard at(p) == colon, ManuscriptLabel.Kind(rawValue: token) != nil else { return start + 1 }
            p += 1
            let name = readName(&p)
            guard let label = ManuscriptLabel(reference: token + ":" + name) else { return start + 1 }
            out.append((.crossRef(label), NSRange(location: start, length: p - start)))
            return p
        }

        // MARK: Helpers

        func at(_ i: Int) -> UInt16? { i < u.count ? u[i] : nil }

        func string(_ from: Int, _ to: Int) -> String {
            text.substring(with: NSRange(location: from, length: to - from))
        }

        func runLength(of unit: UInt16, at start: Int) -> Int {
            var j = start
            while j < u.count, u[j] == unit { j += 1 }
            return j - start
        }

        func skipSpaces(_ start: Int) -> Int {
            var j = start
            while j < u.count, u[j] == space || u[j] == tab { j += 1 }
            return j
        }

        /// Reads `[A-Za-z0-9_-]*` (the label name characters) and advances past it.
        func readName(_ p: inout Int) -> String {
            let from = p
            while p < u.count, u[p] < 128,
                  ManuscriptLabel.isNameScalar(Unicode.Scalar(UInt8(u[p]))) { p += 1 }
            return string(from, p)
        }

        /// Only spaces or tabs between the line's start and `i`.
        func isLineStart(_ i: Int) -> Bool {
            var j = i - 1
            while j >= 0, u[j] == space || u[j] == tab { j -= 1 }
            return j < 0 || u[j] == newline
        }

        /// `[A-Za-z0-9._%+-]`: a character that may come before `@` in an email address.
        func isEmailUnit(_ c: UInt16) -> Bool {
            guard c < 128 else { return false }
            let s = Unicode.Scalar(UInt8(c))
            return ManuscriptLabel.isAlnum(s) || ".%+-_".unicodeScalars.contains(s)
        }
    }
}

private let backslash = UInt16(UInt8(ascii: "\\"))
private let backtick = UInt16(UInt8(ascii: "`"))
private let openBracket = UInt16(UInt8(ascii: "["))
private let closeBracket = UInt16(UInt8(ascii: "]"))
private let caret = UInt16(UInt8(ascii: "^"))
private let atSign = UInt16(UInt8(ascii: "@"))
private let colon = UInt16(UInt8(ascii: ":"))
private let semicolon = UInt16(UInt8(ascii: ";"))
private let comma = UInt16(UInt8(ascii: ","))
private let newline = UInt16(UInt8(ascii: "\n"))
private let space = UInt16(UInt8(ascii: " "))
private let tab = UInt16(UInt8(ascii: "\t"))

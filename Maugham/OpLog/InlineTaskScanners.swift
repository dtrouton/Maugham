import Foundation

/// Scanner for markdown checkbox list items: `- [ ] body` / `- [x] body`.
/// Returns the line's checked state and body text. The full bracket-range /
/// click-route surface is added in Task 5 as an extension in `Maugham/Editor/`.
public enum MarkdownCheckboxScanner {

    public struct Match: Equatable {
        public let checked: Bool
        public let body: String

        public init(checked: Bool, body: String) {
            self.checked = checked
            self.body = body
        }
    }

    private static let regex: NSRegularExpression = {
        // `^\s*- \[( |x)\] (.*)$` — leading whitespace + bullet + bracket + body.
        return try! NSRegularExpression(pattern: #"^\s*- \[( |x)\] (.*)$"#)
    }()

    public static func match(_ line: String) -> Match? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: line, range: range),
              m.numberOfRanges == 3 else { return nil }
        let checked = ns.substring(with: m.range(at: 1)) == "x"
        let body = ns.substring(with: m.range(at: 2))
        return Match(checked: checked, body: body)
    }
}

/// Scanner for Fountain `[[todo: ...]]` / `[[done: ...]]` boneyards within a
/// paragraph. Multiple occurrences per paragraph are returned in source order.
public enum FountainBoneyardScanner {

    public struct Match: Equatable {
        public let done: Bool
        public let body: String

        public init(done: Bool, body: String) {
            self.done = done
            self.body = body
        }
    }

    private static let regex: NSRegularExpression = {
        // `\[\[(todo|done):\s*(.*?)\]\]` — non-greedy body capture.
        return try! NSRegularExpression(pattern: #"\[\[(todo|done):\s*(.*?)\]\]"#)
    }()

    /// Single-match convenience (first occurrence in line). Used by the
    /// in-paragraph scanner when only a quick test is needed.
    public static func match(_ line: String) -> Match? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: line, range: range),
              m.numberOfRanges == 3 else { return nil }
        let kind = ns.substring(with: m.range(at: 1))
        let body = ns.substring(with: m.range(at: 2))
        return Match(done: kind == "done", body: body)
    }

    /// All `[[todo:]]` / `[[done:]]` occurrences in source order across the
    /// whole input (paragraph text, possibly multi-line).
    public static func matchAll(_ text: String) -> [Match] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, range: range)
        return matches.compactMap { m in
            guard m.numberOfRanges == 3 else { return nil }
            let kind = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            return Match(done: kind == "done", body: body)
        }
    }

    /// Range-bearing match for a single `[[todo: ...]]` / `[[done: ...]]`
    /// inside `text`. `prefixRange` covers the 5-char `todo:`/`done:` glyph
    /// (used by the click-paint pass to stamp `MaughamCheckboxAttr`).
    /// `bodyRange` covers the contents between the prefix and the closing
    /// `]]`, trimmed of the marker but not of inner whitespace. Returns the
    /// first occurrence in source order, or nil if no match exists.
    public static func matchTodo(
        _ content: String
    ) -> (done: Bool, prefixRange: NSRange, bodyRange: NSRange)? {
        matchTodoAll(content).first
    }

    /// All `[[todo: ...]]` / `[[done: ...]]` occurrences with prefix and body
    /// NSRanges, in source order. Returned ranges are in the same UTF-16
    /// space as `content` (NSString-indexed).
    public static func matchTodoAll(
        _ content: String
    ) -> [(done: Bool, prefixRange: NSRange, bodyRange: NSRange)] {
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: content, range: range)
        return matches.compactMap { m in
            guard m.numberOfRanges == 3 else { return nil }
            let kindRange = m.range(at: 1)         // "todo" or "done" (4 chars)
            let bodyCapture = m.range(at: 2)
            let kind = ns.substring(with: kindRange)
            // Prefix is the 5 chars "todo:" / "done:" — kindRange + the
            // following colon.
            let prefixRange = NSRange(
                location: kindRange.location,
                length: kindRange.length + 1)
            return (done: kind == "done",
                    prefixRange: prefixRange,
                    bodyRange: bodyCapture)
        }
    }

    /// Flip the 5-char `todo:` or `done:` glyph at the given UTF-16 offset.
    /// Returns the paragraph string with the swap applied. If the offset
    /// doesn't point to a valid `todo:` or `done:` prefix the string is
    /// returned unchanged. The offset is the location of the first letter
    /// of the prefix (`t` for `todo:`, `d` for `done:`) — i.e., the
    /// `prefixRange.location` returned by `matchTodo`.
    public static func flipTodoDone(
        in paragraph: String,
        atUTF16Offset utf16Offset: Int
    ) -> String {
        let ns = paragraph as NSString
        guard utf16Offset >= 0, utf16Offset + 5 <= ns.length else {
            return paragraph
        }
        let glyph = ns.substring(with: NSRange(location: utf16Offset, length: 5))
        let replacement: String
        switch glyph {
        case "todo:": replacement = "done:"
        case "done:": replacement = "todo:"
        default:      return paragraph
        }
        return ns.replacingCharacters(
            in: NSRange(location: utf16Offset, length: 5),
            with: replacement)
    }
}

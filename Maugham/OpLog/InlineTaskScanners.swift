import Foundation

/// Scanner for markdown checkbox list items: `- [ ] body` / `- [x] body`,
/// optionally followed by a trailing task anchor `<!--t-XXXXXX-->`.
/// Returns the line's checked state, body text (anchor-free, no trailing
/// space), and optional 6-char anchor id. The full bracket-range /
/// click-route surface is added in Task 5 as an extension in `Maugham/Editor/`.
public enum MarkdownCheckboxScanner {

    public struct Match: Equatable {
        public let checked: Bool
        public let body: String
        public let anchorId: String?

        public init(checked: Bool, body: String, anchorId: String? = nil) {
            self.checked = checked
            self.body = body
            self.anchorId = anchorId
        }
    }

    private static let regex: NSRegularExpression = {
        // `^\s*- \[( |x)\] (.+?)(?:\s+<!--t-([alphabet]{6})-->)?$`
        // Non-greedy body capture so the optional trailing anchor group can
        // bite. If the line ends with a well-formed anchor preceded by a
        // single whitespace gap, group 3 captures the id; otherwise group 3's
        // range is NSNotFound and the entire body string is whatever follows
        // the bracket.
        return try! NSRegularExpression(
            pattern: #"^\s*- \[( |x)\] (.+?)(?:\s+<!--t-([0123456789abcdefghjkmnpqrstvwxyz]{6})-->)?$"#)
    }()

    public static func match(_ line: String) -> Match? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: line, range: range),
              m.numberOfRanges == 4 else { return nil }
        let checked = ns.substring(with: m.range(at: 1)) == "x"
        let body = ns.substring(with: m.range(at: 2))
        let anchorRange = m.range(at: 3)
        let anchorId: String? = anchorRange.location == NSNotFound
            ? nil
            : ns.substring(with: anchorRange)
        return Match(checked: checked, body: body, anchorId: anchorId)
    }
}

/// Scanner for Fountain `[[todo: ...]]` / `[[done: ...]]` boneyards within a
/// paragraph, optionally followed by a glued task anchor `<!--t-XXXXXX-->`
/// (no whitespace between `]]` and the anchor). Multiple occurrences per
/// paragraph are returned in source order.
public enum FountainBoneyardScanner {

    public struct Match: Equatable {
        public let done: Bool
        public let body: String
        public let anchorId: String?

        public init(done: Bool, body: String, anchorId: String? = nil) {
            self.done = done
            self.body = body
            self.anchorId = anchorId
        }
    }

    private static let regex: NSRegularExpression = {
        // `\[\[(todo|done):\s*(.*?)\]\](?:<!--t-([alphabet]{6})-->)?`
        // The anchor is glued to the closing `]]` with no whitespace.
        return try! NSRegularExpression(
            pattern: #"\[\[(todo|done):\s*(.*?)\]\](?:<!--t-([0123456789abcdefghjkmnpqrstvwxyz]{6})-->)?"#)
    }()

    /// Single-match convenience (first occurrence in line). Used by the
    /// in-paragraph scanner when only a quick test is needed.
    public static func match(_ line: String) -> Match? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: line, range: range),
              m.numberOfRanges == 4 else { return nil }
        let kind = ns.substring(with: m.range(at: 1))
        let body = ns.substring(with: m.range(at: 2))
        let anchorRange = m.range(at: 3)
        let anchorId: String? = anchorRange.location == NSNotFound
            ? nil
            : ns.substring(with: anchorRange)
        return Match(done: kind == "done", body: body, anchorId: anchorId)
    }

    /// All `[[todo:]]` / `[[done:]]` occurrences in source order across the
    /// whole input (paragraph text, possibly multi-line).
    public static func matchAll(_ text: String) -> [Match] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, range: range)
        return matches.compactMap { m in
            guard m.numberOfRanges == 4 else { return nil }
            let kind = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            let anchorRange = m.range(at: 3)
            let anchorId: String? = anchorRange.location == NSNotFound
                ? nil
                : ns.substring(with: anchorRange)
            return Match(done: kind == "done", body: body, anchorId: anchorId)
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
            guard m.numberOfRanges == 4 else { return nil }
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

    /// All `[[todo: ...]]` / `[[done: ...]]` occurrences with prefix, body,
    /// and optional anchor NSRanges, in source order. `anchorRange` covers the
    /// full `<!--t-XXXXXX-->` span (no leading space — Fountain anchors are
    /// glued immediately after `]]`). Returns NSRange with location == NSNotFound
    /// when no anchor is present for a given match.
    public static func matchTodoAllFull(
        _ content: String
    ) -> [(done: Bool, prefixRange: NSRange, bodyRange: NSRange, anchorRange: NSRange)] {
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: content, range: range)
        return matches.compactMap { m in
            guard m.numberOfRanges == 4 else { return nil }
            let kindRange = m.range(at: 1)
            let bodyCapture = m.range(at: 2)
            let anchorIdRange = m.range(at: 3)
            let kind = ns.substring(with: kindRange)
            let prefixRange = NSRange(
                location: kindRange.location,
                length: kindRange.length + 1)
            // Anchor range: if anchorId was captured, reconstruct the full
            // `<!--t-XXXXXX-->` span. The anchor id is 6 chars; the full span
            // is `<!--t-` (6) + 6 + `-->` (3) = 15 chars, starting 3 chars
            // before anchorId (past `<!--t-`).
            let anchorRange: NSRange
            if anchorIdRange.location != NSNotFound {
                anchorRange = NSRange(
                    location: anchorIdRange.location - 6,
                    length: 15)  // `<!--t-` + 6 id chars + `-->` = 15
            } else {
                anchorRange = NSRange(location: NSNotFound, length: 0)
            }
            return (done: kind == "done",
                    prefixRange: prefixRange,
                    bodyRange: bodyCapture,
                    anchorRange: anchorRange)
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

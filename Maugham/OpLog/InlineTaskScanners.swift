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
}

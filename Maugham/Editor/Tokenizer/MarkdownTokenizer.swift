import Foundation

/// Regex-based Markdown tokenizer. Classifies ranges of text into Token kinds
/// for syntax highlighting. Does not handle tables, fenced code blocks, or
/// nested emphasis — defer to later milestones if needed.
public struct MarkdownTokenizer: Sendable {

    public init() {}

    public func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        var tokens: [Token] = []

        // Headings: ^(#{1,6})\s+
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^(#{1,6})\s+([^\n]*)"#,
            into: &tokens) { match in
                let hashes = match.range(at: 1)
                let content = match.range(at: 2)
                let level = nsText.substring(with: hashes).count
                return [
                    Token(range: NSRange(location: hashes.location,
                                          length: content.location - hashes.location),
                          kind: .syntaxPunctuation),
                    Token(range: content, kind: .heading(level: level)),
                ]
            }

        // Bold: \*\*([^*]+)\*\*
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"\*\*([^*\n]+)\*\*"#,
            into: &tokens) { match in
                let outer = match.range(at: 0)
                let inner = match.range(at: 1)
                let openPunct = NSRange(location: outer.location, length: 2)
                let closePunct = NSRange(location: inner.location + inner.length, length: 2)
                return [
                    Token(range: openPunct, kind: .syntaxPunctuation),
                    Token(range: inner, kind: .emphasis(strong: true)),
                    Token(range: closePunct, kind: .syntaxPunctuation),
                ]
            }

        // Italic: (?<!\*)\*([^*\n]+)\*(?!\*)
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#,
            into: &tokens) { match in
                let outer = match.range(at: 0)
                let inner = match.range(at: 1)
                let openPunct = NSRange(location: outer.location, length: 1)
                let closePunct = NSRange(location: inner.location + inner.length, length: 1)
                return [
                    Token(range: openPunct, kind: .syntaxPunctuation),
                    Token(range: inner, kind: .emphasis(strong: false)),
                    Token(range: closePunct, kind: .syntaxPunctuation),
                ]
            }

        // Inline code: `([^`\n]+)`
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"`([^`\n]+)`"#,
            into: &tokens) { match in
                let outer = match.range(at: 0)
                let inner = match.range(at: 1)
                let openPunct = NSRange(location: outer.location, length: 1)
                let closePunct = NSRange(location: inner.location + inner.length, length: 1)
                return [
                    Token(range: openPunct, kind: .syntaxPunctuation),
                    Token(range: inner, kind: .code),
                    Token(range: closePunct, kind: .syntaxPunctuation),
                ]
            }

        // Link: \[([^\]\n]+)\]\(([^\)\n]+)\)
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#,
            into: &tokens) { match in
                let outer = match.range(at: 0)
                let labelInner = match.range(at: 1)
                let href = match.range(at: 2)
                let hrefString = nsText.substring(with: href)

                let labelOpen = NSRange(location: outer.location, length: 1)        // [
                let labelClose = NSRange(location: labelInner.location + labelInner.length, length: 1)  // ]
                let parensOpen = NSRange(location: labelClose.location + 1, length: 1)  // (
                let parensCloseLoc = href.location + href.length
                let parensClose = NSRange(location: parensCloseLoc, length: 1)
                return [
                    Token(range: labelOpen, kind: .syntaxPunctuation),
                    Token(range: labelInner, kind: .link(href: hrefString)),
                    Token(range: labelClose, kind: .syntaxPunctuation),
                    Token(range: parensOpen, kind: .syntaxPunctuation),
                    Token(range: href, kind: .syntaxPunctuation),
                    Token(range: parensClose, kind: .syntaxPunctuation),
                ]
            }

        // List marker: ^(\s*)([-*+]|\d+\.)\s
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^(\s*)([-*+]|\d+\.)\s"#,
            into: &tokens) { match in
                let marker = match.range(at: 2)
                return [Token(range: marker, kind: .listMarker)]
            }

        // Blockquote: ^>\s
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^(>)\s"#,
            into: &tokens) { match in
                return [Token(range: match.range(at: 1), kind: .blockquote)]
            }

        // Horizontal rule: ^---+\s*$
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^(---+)\s*$"#,
            into: &tokens) { match in
                return [Token(range: match.range(at: 1), kind: .horizontalRule)]
            }

        // Sort by location and fill gaps with .plain tokens
        tokens.sort { $0.range.location < $1.range.location }
        let merged = fillGapsWithPlain(tokens, fullRange: fullRange)
        return merged
    }

    // MARK: - Helpers

    private func addMatches(
        in nsText: NSString,
        fullRange: NSRange,
        pattern: String,
        into tokens: inout [Token],
        _ build: (NSTextCheckingResult) -> [Token]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        regex.enumerateMatches(in: nsText as String, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            // Skip if any of the new tokens overlap with already-classified ranges
            let candidates = build(match)
            for c in candidates {
                if !tokens.contains(where: { $0.range.intersection(c.range) != nil }) {
                    tokens.append(c)
                }
            }
        }
    }

    private func fillGapsWithPlain(_ classified: [Token], fullRange: NSRange) -> [Token] {
        var result: [Token] = []
        var cursor = 0
        for token in classified {
            if token.range.location > cursor {
                let gap = NSRange(location: cursor, length: token.range.location - cursor)
                result.append(Token(range: gap, kind: .plain))
            }
            result.append(token)
            cursor = token.range.location + token.range.length
        }
        if cursor < fullRange.length {
            let gap = NSRange(location: cursor, length: fullRange.length - cursor)
            result.append(Token(range: gap, kind: .plain))
        }
        return result
    }
}

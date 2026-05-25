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

        // Wiki links: [[Title]]
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"\[\[([^\[\]\n]+?)\]\]"#,
            into: &tokens) { match in
                let outer = match.range(at: 0)
                let inner = match.range(at: 1)
                let title = nsText
                    .substring(with: inner)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return [] }
                return [Token(range: outer, kind: .wikiLink(title: title))]
            }

        // Checkbox: ^(\s*)- \[( |x)\] (.+?)(?:(\s+<!--t-[alphabet]{6}-->))?$
        // Emits: listMarker for `-`, .checkbox for `[ ]`/`[x]`, .taskBody for
        // the body text, and .invisibleAnchor for the trailing anchor span (if
        // present, including its leading space). Must run before the generic
        // list-marker pass so the bracket region is claimed first.
        //
        // Note: taskBody and invisibleAnchor are appended directly (not via
        // addMatches) because body text may contain wiki-link or emphasis tokens
        // already claimed by earlier passes — addMatches would skip the taskBody
        // token on overlap, but we need it in the token stream for paint.
        var taskBodyTokens: [Token] = []
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^(\s*)- \[( |x)\] (.+?)(\s+<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->)?$"#,
            into: &tokens) { match in
                let indent = match.range(at: 1)
                let dashRange = NSRange(
                    location: indent.location + indent.length,
                    length: 1)  // the "-"
                let bracketChar = match.range(at: 2)
                let bracketRange = NSRange(
                    location: bracketChar.location - 1,
                    length: 3)  // covers "[ ]" or "[x]"
                let checked = nsText.substring(with: bracketChar) == "x"
                let bodyRange = match.range(at: 3)
                let anchorCapture = match.range(at: 4)
                if bodyRange.location != NSNotFound && bodyRange.length > 0 {
                    taskBodyTokens.append(Token(range: bodyRange, kind: .taskBody))
                }
                if anchorCapture.location != NSNotFound && anchorCapture.length > 0 {
                    taskBodyTokens.append(Token(range: anchorCapture, kind: .invisibleAnchor))
                }
                return [
                    Token(range: dashRange, kind: .listMarker),
                    Token(range: bracketRange, kind: .checkbox(checked: checked)),
                ]
            }
        // Append taskBody / invisibleAnchor tokens directly — they must be in
        // the stream for ProseMode's paint pass even when the body range is
        // partially occupied by inline tokens from earlier passes.
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
        var merged = fillGapsWithPlain(tokens, fullRange: fullRange)

        // Append task-semantic tokens AFTER the gap-fill pass so that
        // taskBody / invisibleAnchor are present in the token stream for the
        // ProseMode paint pass without disturbing the gap-fill logic.
        // These tokens may overlap existing inline tokens (e.g. a wiki-link
        // inside a task body) — that is intentional; addAttributes in the paint
        // pass applies them in order, so finer-grained inline tokens win.
        merged.append(contentsOf: taskBodyTokens)
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

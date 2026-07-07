import Foundation
import MaughamCore

/// Regex-based Markdown tokenizer. Classifies ranges of text into Token kinds
/// for syntax highlighting. Asterisk emphasis (incl. `***both***`, nesting,
/// and `~~strikethrough~~`) is paragraph-scoped via the shared
/// `InlineEmphasisScanner` (see the emphasis pass below) — nested emphasis IS
/// handled, contrary to this header's old claim. Does not handle tables or
/// fenced-code syntax highlighting; see `markdown-syntax.md` for the full
/// documented subset.
public struct MarkdownTokenizer: Sendable {

    public init() {}

    public func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        var tokens: [Token] = []

        // Horizontal rule / scene break: ^ {0,3}(-{3,}|\*{3}|#{3})\s*$
        // Runs FIRST so a lone `***` or `###` line is claimed as a rule
        // before the heading pass (which would otherwise read `### ` as an
        // empty level-3 heading) or the paragraph-scoped emphasis scan
        // (which would otherwise see `***` as an open/close delimiter run
        // spanning into surrounding prose). The overlap-skip in addMatches
        // and in the emphasis loop then keeps those passes off this range.
        // Kept in exact parity with the shared block grammar
        // (`MarkdownBlockParser.isThematicBreakLine`): exactly three `*`/`#`
        // (space-stripped equality) or three-or-more `-`.
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^ {0,3}(-{3,}|\*{3}|#{3})\s*$"#,
            into: &tokens) { match in
                return [Token(range: match.range(at: 1), kind: .horizontalRule)]
            }

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

        // Asterisk emphasis (*, **, ***, nesting) + `~~strikethrough~~` via the
        // shared scanner, scanned PER BLANK-LINE-DELIMITED BLOCK so emphasis is
        // paragraph-scoped: it spans a hard line break within a stanza but never
        // crosses a blank line (spec ledger: paragraph-scoped emphasis, which
        // inverts the old per-line rule). Backslash escapes are faded as syntax
        // punctuation so `\*literal\*` reads as literal asterisks.
        BlankLineBlocks.enumerate(nsText, in: fullRange) { blockRange in
            let block = nsText.substring(with: blockRange)
            let scan = InlineEmphasisScanner.scan(block as NSString,
                                                  options: [.strikethrough])
            for run in scan.runs {
                let r = NSRange(location: blockRange.location + run.range.location,
                                length: run.range.length)
                let tok = Token(range: r, kind: .emphasis(run.traits))
                if !tokens.contains(where: { $0.range.intersection(r) != nil }) {
                    tokens.append(tok)
                }
            }
            for marker in scan.markers {
                let r = NSRange(location: blockRange.location + marker.location,
                                length: marker.length)
                let tok = Token(range: r, kind: .syntaxPunctuation)
                if !tokens.contains(where: { $0.range.intersection(r) != nil }) {
                    tokens.append(tok)
                }
            }
            for esc in scan.escapes {
                let r = NSRange(location: blockRange.location + esc.location,
                                length: esc.length)
                if !tokens.contains(where: { $0.range.intersection(r) != nil }) {
                    tokens.append(Token(range: r, kind: .syntaxPunctuation))
                }
            }
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

        // Link: (?<!\!)\[([^\]\n]+)\]\(([^\)\n]+)\)
        // Negative lookbehind excludes `![alt](url)` image syntax — its
        // `[alt](url)` tail is not a link and must not be link-styled.
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?<!\!)\[([^\]\n]+)\]\(([^\)\n]+)\)"#,
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
                    taskBodyTokens.append(Token(
                        range: bodyRange, kind: .taskBody(done: checked)))
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

        // Fountain-style inline tasks `[[todo: …]]` / `[[done: …]]` in prose.
        // Writers use this syntax to drop mid-paragraph todos without
        // splitting prose paragraphs. The tasks pane already derives them
        // via FountainBoneyardScanner regardless of writing mode; the
        // editor needs to mirror that by emitting checkbox/taskBody/
        // invisibleAnchor tokens so the body gets distinct styling
        // (and strikethrough on `[[done: …]]`).
        for hit in FountainBoneyardScanner.matchTodoAllFull(nsText as String) {
            let prefix = NSRange(
                location: hit.prefixRange.location,
                length: hit.prefixRange.length)
            taskBodyTokens.append(Token(
                range: prefix,
                kind: .checkbox(checked: hit.done)))
            if hit.bodyRange.length > 0 {
                let body = NSRange(
                    location: hit.bodyRange.location,
                    length: hit.bodyRange.length)
                taskBodyTokens.append(Token(
                    range: body,
                    kind: .taskBody(done: hit.done)))
            }
            if hit.anchorRange.location != NSNotFound,
               hit.anchorRange.length > 0 {
                let anchor = NSRange(
                    location: hit.anchorRange.location,
                    length: hit.anchorRange.length)
                taskBodyTokens.append(Token(
                    range: anchor,
                    kind: .invisibleAnchor))
            }
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

import Foundation
import MaughamCore

/// Regex-based Markdown tokenizer. Classifies ranges of text into Token kinds
/// for syntax highlighting. Asterisk emphasis (incl. `***both***`, nesting,
/// and `~~strikethrough~~`) is paragraph-scoped via the shared
/// `InlineEmphasisScanner` (see the emphasis pass below) — nested emphasis IS
/// handled, contrary to this header's old claim. The report elements
/// (tables, figure lines, footnotes, citations, cross-references, `{#…}`
/// labels) come from `ReportBlocks`. Does not handle fenced-code syntax
/// highlighting; see `markdown-syntax.md` for the full documented subset.
public struct MarkdownTokenizer: Sendable {

    public init() {}

    public func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        var tokens: [Token] = []
        // Every claimed range, so "the first claim wins" is a range-set query
        // rather than a scan of every token so far (that scan was
        // O(tokens²) per document, paid on every keystroke).
        var claims = TokenClaims()
        // Overlays appended after the gap fill (see the end of this function).
        var overlayTokens: [Token] = []
        // The blank-line blocks, enumerated once and shared by the per-block
        // passes (report blocks, emphasis, inline markers).
        var blocks: [NSRange] = []
        BlankLineBlocks.enumerate(nsText, in: fullRange) { blocks.append($0) }

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
            into: &tokens, claims: &claims) { match in
                return [Token(range: match.range(at: 1), kind: .horizontalRule)]
            }

        // Headings: ^(#{1,6})\s+
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^(#{1,6})\s+([^\n]*)"#,
            into: &tokens, claims: &claims) { match in
                let hashes = match.range(at: 1)
                var content = match.range(at: 2)
                let level = nsText.substring(with: hashes).count
                var out = [
                    Token(range: NSRange(location: hashes.location,
                                          length: content.location - hashes.location),
                          kind: .syntaxPunctuation),
                ]
                // A trailing `{#sec:x}` is a label, not heading text.
                if let label = Self.trailingAttributeBlock(in: nsText, line: content) {
                    var end = label.location
                    while end > content.location,
                          [0x20, 0x09].contains(nsText.character(at: end - 1)) { end -= 1 }
                    content.length = end - content.location
                    out.append(Token(range: label, kind: .attributeBlock))
                }
                out.append(Token(range: content, kind: .heading(level: level)))
                return out
            }

        // Asterisk emphasis (*, **, ***, nesting) + `~~strikethrough~~` via the
        // shared scanner, scanned PER BLANK-LINE-DELIMITED BLOCK so emphasis is
        // paragraph-scoped: it spans a hard line break within a stanza but never
        // crosses a blank line (spec ledger: paragraph-scoped emphasis, which
        // inverts the old per-line rule). Backslash escapes are faded as syntax
        // punctuation so `\*literal\*` reads as literal asterisks.
        //
        // The report blocks (tables, figure lines, footnote-definition labels)
        // are claimed FIRST, so a pipe is never swallowed by an emphasis run
        // that crosses cells and a row starting `- |` never reads as a list.
        for blockRange in blocks {
            ReportBlocks.tokenize(block: blockRange, in: nsText,
                                  into: &tokens, overlays: &overlayTokens,
                                  claims: &claims)
        }

        for blockRange in blocks {
            let block = nsText.substring(with: blockRange)
            let scan = InlineEmphasisScanner.scan(block as NSString,
                                                  options: [.strikethrough])
            for run in scan.runs {
                let r = NSRange(location: blockRange.location + run.range.location,
                                length: run.range.length)
                claims.claimIfFree(Token(range: r, kind: .emphasis(run.traits)), into: &tokens)
            }
            for marker in scan.markers {
                let r = NSRange(location: blockRange.location + marker.location,
                                length: marker.length)
                claims.claimIfFree(Token(range: r, kind: .syntaxPunctuation), into: &tokens)
            }
            for esc in scan.escapes {
                let r = NSRange(location: blockRange.location + esc.location,
                                length: esc.length)
                claims.claimIfFree(Token(range: r, kind: .syntaxPunctuation), into: &tokens)
            }
        }

        // Inline code: `([^`\n]+)`
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"`([^`\n]+)`"#,
            into: &tokens, claims: &claims) { match in
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

        // Footnote references, citations and cross-references, from the
        // shared scanner (it skips code spans and escapes itself), per block.
        // BEFORE the link pass, so `[@a](x)` and `[^1](x)` are claimed as
        // markers, not links. After emphasis: a marker inside an emphasis run
        // stays part of the run, as a link there does.
        for blockRange in blocks {
            ReportBlocks.tokenizeInlineMarkers(block: blockRange, in: nsText,
                                               into: &tokens, claims: &claims)
        }

        // Link: (?<!\!)\[([^\]\n]+)\]\(([^\)\n]+)\)
        // Negative lookbehind excludes `![alt](url)` image syntax — its
        // `[alt](url)` tail is not a link and must not be link-styled.
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?<!\!)\[([^\]\n]+)\]\(([^\)\n]+)\)"#,
            into: &tokens, claims: &claims,
            // A match whose opening `[` already belongs to another token
            // (`[@a](x)`, `[^1](x)`) is not a link at all: drop all of it, so
            // the `(x)` after a citation stays prose instead of muted.
            dropWholeMatchIfClaimed: { NSRange(location: $0.range.location, length: 1) }) { match in
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
            into: &tokens, claims: &claims) { match in
                let outer = match.range(at: 0)
                let inner = match.range(at: 1)
                let title = nsText
                    .substring(with: inner)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return [] }
                return [Token(range: outer, kind: .wikiLink(title: title))]
            }

        // Checkbox: ^(\s*)- \[( |x|X)\] (.+?)(?:(\s+<!--t-[alphabet]{6}-->))?$
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
            pattern: #"(?m)^(\s*)- \[( |x|X)\] (.+?)(\s+<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->)?$"#,
            into: &tokens, claims: &claims) { match in
                let indent = match.range(at: 1)
                let dashRange = NSRange(
                    location: indent.location + indent.length,
                    length: 1)  // the "-"
                let bracketChar = match.range(at: 2)
                let bracketRange = NSRange(
                    location: bracketChar.location - 1,
                    length: 3)  // covers "[ ]" or "[x]"
                // bracketChar is one of " ", "x", "X"; anything but space is checked.
                let checked = nsText.substring(with: bracketChar) != " "
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

        // A line inside a table is a row, never a list item or a quote
        // (`- | a |` is a header or body row whose first cell is `-`).
        var tableLines = IndexSet()
        for t in overlayTokens where t.kind == .tableBlock {
            tableLines.insert(integersIn: t.range.location..<NSMaxRange(t.range))
        }

        // List marker: ^(\s*)([-*+]|\d+\.)\s
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^(\s*)([-*+]|\d+\.)\s"#,
            into: &tokens, claims: &claims) { match in
                let marker = match.range(at: 2)
                guard !tableLines.contains(marker.location) else { return [] }
                return [Token(range: marker, kind: .listMarker)]
            }

        // Blockquote: ^>\s
        addMatches(
            in: nsText, fullRange: fullRange,
            pattern: #"(?m)^(>)\s"#,
            into: &tokens, claims: &claims) { match in
                guard !tableLines.contains(match.range(at: 1).location) else { return [] }
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
        // The report overlays (`tableHeader`, `tableBlock`) likewise sit on
        // top of the main stream: a header cell keeps its own emphasis or
        // citation token, and the block token is unstyled.
        merged.append(contentsOf: overlayTokens)
        return merged
    }

    /// The whole table (header row through caption line) whose range holds
    /// `location`, from a token stream this tokenizer produced. A caret just
    /// after the table's last character counts as inside it. nil outside any
    /// table.
    static func tableBlockRange(containing location: Int, in tokens: [Token]) -> NSRange? {
        tokens.first {
            $0.kind == .tableBlock
                && location >= $0.range.location && location <= NSMaxRange($0.range)
        }?.range
    }

    /// The range of a valid trailing `{#kind:name}` block on `line` (the
    /// rule is `ManuscriptAttributes.split`'s), or nil.
    static func trailingAttributeBlock(in text: NSString, line: NSRange) -> NSRange? {
        guard line.length >= 4,
              text.character(at: NSMaxRange(line) - 1) == UInt16(UInt8(ascii: "}")) else { return nil }
        let open = text.range(of: "{#", options: .backwards, range: line)
        guard open.location != NSNotFound,
              ManuscriptAttributes.split(text.substring(with: line)).label != nil else { return nil }
        return NSRange(location: open.location, length: NSMaxRange(line) - open.location)
    }

    // MARK: - Helpers

    private func addMatches(
        in nsText: NSString,
        fullRange: NSRange,
        pattern: String,
        into tokens: inout [Token],
        claims: inout TokenClaims,
        dropWholeMatchIfClaimed: ((NSTextCheckingResult) -> NSRange)? = nil,
        _ build: (NSTextCheckingResult) -> [Token]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        regex.enumerateMatches(in: nsText as String, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            if let probe = dropWholeMatchIfClaimed, claims.overlaps(probe(match)) { return }
            // Skip any new token that overlaps an already-classified range.
            for c in build(match) { claims.claimIfFree(c, into: &tokens) }
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

/// The ranges the tokenizer has claimed so far. A candidate overlapping any
/// of them is dropped ("the first claim wins"), with exactly the overlap rule
/// `NSRange.intersection` gives: positive-length ranges overlap when they
/// share a character; a zero-length range at `loc` overlaps a positive one
/// covering `loc` (start ≤ loc < end); two zero-length ranges never do.
/// An `IndexSet` makes each query logarithmic, where the old
/// `tokens.contains(where:)` scan made the whole tokenize O(tokens²).
struct TokenClaims {
    private var covered = IndexSet()
    /// Locations of the zero-length tokens claimed so far (rare: an empty
    /// heading at the end of the text).
    private var empties: [Int] = []

    func overlaps(_ r: NSRange) -> Bool {
        if r.length == 0 { return covered.contains(r.location) }
        if covered.intersects(integersIn: r.location..<NSMaxRange(r)) { return true }
        return empties.contains { $0 >= r.location && $0 < NSMaxRange(r) }
    }

    /// Appends `token` to `tokens` and claims its range unless it overlaps
    /// an earlier claim.
    mutating func claimIfFree(_ token: Token, into tokens: inout [Token]) {
        guard !overlaps(token.range) else { return }
        tokens.append(token)
        if token.range.length == 0 {
            empties.append(token.range.location)
        } else {
            covered.insert(integersIn: token.range.location..<NSMaxRange(token.range))
        }
    }
}

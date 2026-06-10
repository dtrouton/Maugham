// Maugham/OpLog/ParagraphParser.swift
import Foundation

public struct ParsedParagraph: Equatable, Sendable {
    public let id: String?
    public let text: String
    public init(id: String?, text: String) {
        self.id = id
        self.text = text
    }
}

public enum ParagraphParser {
    /// Split markdown text into paragraphs by blank lines. An optional
    /// `<!-- ¶id -->` comment immediately preceding a paragraph attaches
    /// its id to that paragraph. Stray comments without a following text
    /// block are discarded.
    ///
    /// Hot path: runs once per keystroke on the whole display text. The
    /// per-line work is hand-tuned to avoid Foundation bridging on the
    /// overwhelmingly-common pure-ASCII line — see `isBlankLine` and
    /// `mightBeAnchorComment` — while preserving EXACT behavior by falling
    /// back to the Foundation path the moment a line carries any non-ASCII
    /// scalar (where Unicode whitespace like U+00A0 could differ).
    public static func parse(_ markdown: String) -> [ParsedParagraph] {
        var result: [ParsedParagraph] = []
        var pendingId: String? = nil
        var buffer: [Substring] = []

        func flushParagraph() {
            guard !buffer.isEmpty else { return }
            let text = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if !text.isEmpty {
                result.append(ParsedParagraph(id: pendingId, text: text))
            }
            buffer.removeAll(keepingCapacity: true)
            pendingId = nil
        }

        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for line in lines {
            if isBlankLine(line) {
                flushParagraph()
                continue
            }
            if mightBeAnchorComment(line), let id = ParagraphID.parseComment(String(line)) {
                // Comment lines flush any in-progress buffer and stash the id
                // for the next paragraph. Existing pendingId (from a prior
                // stray comment) is replaced.
                flushParagraph()
                pendingId = id
                continue
            }
            buffer.append(line)
        }
        flushParagraph()
        return result
    }

    /// True iff `line` is empty after trimming `CharacterSet.whitespaces`
    /// (space, tab, and the Unicode `Zs` separators). Fast path: a pure-ASCII
    /// line is blank iff every byte is space (0x20) or tab (0x09). Any
    /// non-ASCII byte means a scalar that *might* be Unicode whitespace
    /// (U+00A0 etc.), so we defer to the exact Foundation check rather than
    /// guess.
    @inline(__always)
    private static func isBlankLine(_ line: Substring) -> Bool {
        let utf8 = line.utf8
        for byte in utf8 {
            if byte == 0x20 || byte == 0x09 { continue }   // space / tab
            if byte >= 0x80 {
                // Non-ASCII present — exact semantics via Foundation.
                return String(line).trimmingCharacters(in: .whitespaces).isEmpty
            }
            return false   // ASCII non-whitespace → not blank
        }
        return true   // all space/tab (or empty)
    }

    /// Cheap pre-check before the (relatively costly) `ParagraphID.parseComment`
    /// regex. `parseComment` first trims `.whitespacesAndNewlines` then requires
    /// the result to start `<!--`. So a line can only be an anchor comment if,
    /// after skipping leading ASCII whitespace, it begins with `<` (`<!--`).
    /// Pure-ASCII lines that don't are rejected in O(prefix) with no allocation.
    /// Any leading non-ASCII byte defers to the full parser (a leading Unicode
    /// space would be trimmed there).
    @inline(__always)
    private static func mightBeAnchorComment(_ line: Substring) -> Bool {
        for byte in line.utf8 {
            if byte == 0x20 || byte == 0x09 { continue }   // skip leading space/tab
            if byte >= 0x80 { return true }                // non-ASCII lead → defer
            return byte == 0x3C                            // '<'
        }
        return false   // all whitespace (handled as blank earlier anyway)
    }
}

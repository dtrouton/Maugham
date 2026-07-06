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
    /// Hot path: runs once per keystroke on the whole display text. This is a
    /// SINGLE UTF-8 byte-buffer pass — the line split, the blank pre-check, and
    /// the `<!--` anchor pre-check all read raw bytes, and each content line is
    /// materialized as a `String` exactly once from its byte range. The line
    /// terminators recognized are EXACTLY `Character.isNewline`'s set
    /// (`\n`, `\r`, `\r\n` as ONE terminator, U+0085 NEL, U+2028 LS, U+2029 PS),
    /// reproducing `markdown.split(whereSeparator: \.isNewline,
    /// omittingEmptySubsequences: false)` byte-for-byte — pinned by
    /// `PerfFastPathDifferentialTests` against the pre-fast-path Foundation
    /// reference. Pure-ASCII lines take the fast classification path; any
    /// non-ASCII byte routes that line's blank/anchor check through Foundation
    /// (where Unicode whitespace like U+00A0 could differ) — the fix-C deferral
    /// pattern, unchanged in meaning.
    ///
    /// `preservesHeldBlankLines` (Fountain documents only) makes a whitespace-only
    /// line of length >= 1 — a Fountain "held blank", the two-space dialogue pause
    /// tokenized by `FountainTokenizer` (Task 13) — stay inside the in-progress
    /// paragraph's content VERBATIM instead of splitting it. A truly empty line
    /// (length 0) still separates, in every mode; and a whitespace-only line with
    /// no paragraph in progress is still dropped (it is a separator, not a pause).
    /// Prose keeps whitespace-only = blank (default `false`): writers routinely
    /// leave invisible trailing spaces on separator lines and paragraph identity —
    /// the op-log join key — must not hinge on them. Because Materializer joins
    /// paragraphs with clean `\n\n` (never trailing-space) and truly-empty lines
    /// always split, `parse -> materialize -> parse` is idempotent in both modes:
    /// only a user-typed held line is preserved, and on re-parse it is still a
    /// whitespace-only line inside the same paragraph. See E1 (MCP smoke).
    public static func parse(
        _ markdown: String, preservesHeldBlankLines: Bool = false
    ) -> [ParsedParagraph] {
        guard !markdown.isEmpty else { return [] }

        var result: [ParsedParagraph] = []
        var pendingId: String? = nil
        // Accumulates the materialized content lines of the in-progress
        // paragraph; joined with "\n" and `.newlines`-trimmed on flush, exactly
        // as the prior `buffer.joined(separator: "\n")` did.
        var buffer: [String] = []

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

        let utf8 = Array(markdown.utf8)
        let n = utf8.count
        utf8.withUnsafeBufferPointer { buf in
            var i = 0
            // The split keeps empty subsequences (omittingEmptySubsequences:
            // false), so a trailing terminator yields a trailing empty line and
            // consecutive terminators yield empty lines between — both blank,
            // both flush. We replicate that by always emitting a line for the
            // span before each terminator AND one final span after the last
            // terminator (even when empty).
            while true {
                let lineStart = i
                // Walk to the next terminator (or EOF).
                var isASCII = true
                while i < n {
                    let b = buf[i]
                    if b == 0x0A || b == 0x0D { break }                 // LF, CR
                    if b == 0xC2, i + 1 < n, buf[i + 1] == 0x85 { break } // NEL
                    if b == 0xE2, i + 2 < n, buf[i + 1] == 0x80,
                       (buf[i + 2] == 0xA8 || buf[i + 2] == 0xA9) { break } // LS/PS
                    if b >= 0x80 { isASCII = false }
                    i += 1
                }
                let contentEnd = i   // exclusive; excludes terminator
                // Classify + consume this line. Inlined (not a helper taking
                // `&buffer`/`flushParagraph`) so the exclusivity checker sees a
                // single access to the captured paragraph state per line.
                if isBlankSpan(buf, lineStart, contentEnd, isASCII) {
                    // Fountain "held blank": a whitespace-only line (length >= 1)
                    // inside an open paragraph is a paused dialogue continuation
                    // (Task 13) — preserve it as content verbatim, don't split.
                    // A truly empty line (contentEnd == lineStart) always
                    // separates; a whitespace-only line with an empty buffer is a
                    // leading/inter-paragraph separator, not a pause, so it flushes
                    // (a no-op when the buffer is already empty) and is dropped.
                    if preservesHeldBlankLines
                        && contentEnd > lineStart
                        && !buffer.isEmpty {
                        buffer.append(spanString(buf, lineStart, contentEnd))
                    } else {
                        flushParagraph()
                    }
                } else if mightBeAnchorSpan(buf, lineStart, contentEnd, isASCII) {
                    let lineStr = spanString(buf, lineStart, contentEnd)
                    if let id = ParagraphID.parseComment(lineStr) {
                        flushParagraph()
                        pendingId = id
                    } else {
                        buffer.append(lineStr)
                    }
                } else {
                    buffer.append(spanString(buf, lineStart, contentEnd))
                }

                // Advance past the terminator (CRLF merges as one).
                if i >= n { break }
                let b = buf[i]
                if b == 0x0D {
                    if i + 1 < n, buf[i + 1] == 0x0A { i += 2 } else { i += 1 }
                } else if b == 0x0A {
                    i += 1
                } else if b == 0xC2 {       // NEL: C2 85
                    i += 2
                } else {                    // LS/PS: E2 80 A8/A9
                    i += 3
                }
            }
        }
        flushParagraph()
        return result
    }

    /// Materialize the line `String` from a UTF-8 byte span exactly once.
    @inline(__always)
    private static func spanString(
        _ buf: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int
    ) -> String {
        if lo == hi { return "" }
        return String(decoding: UnsafeBufferPointer(rebasing: buf[lo..<hi]),
                      as: UTF8.self)
    }

    /// True iff the content span is empty after trimming
    /// `CharacterSet.whitespaces`. Pure-ASCII fast path: blank iff every byte
    /// is space (0x20) or tab (0x09). Any non-ASCII byte defers to the exact
    /// Foundation check (a U+00A0 etc. could be `Zs` whitespace). Mirrors the
    /// prior `isBlankLine`.
    @inline(__always)
    private static func isBlankSpan(
        _ buf: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int, _ isASCII: Bool
    ) -> Bool {
        if isASCII {
            var k = lo
            while k < hi {
                let b = buf[k]
                if b != 0x20 && b != 0x09 { return false }
                k += 1
            }
            return true
        }
        return spanString(buf, lo, hi)
            .trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Cheap pre-check before `ParagraphID.parseComment`'s regex: after skipping
    /// leading ASCII whitespace a line can only be an anchor comment if it then
    /// begins with `<` (`<!--`). Any leading non-ASCII byte defers to the full
    /// parser (a leading Unicode space would be trimmed there). Mirrors the
    /// prior `mightBeAnchorComment`.
    @inline(__always)
    private static func mightBeAnchorSpan(
        _ buf: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int, _ isASCII: Bool
    ) -> Bool {
        var k = lo
        while k < hi {
            let b = buf[k]
            if b == 0x20 || b == 0x09 { k += 1; continue }  // skip space/tab
            if b >= 0x80 { return true }                    // non-ASCII → defer
            return b == 0x3C                                // '<'
        }
        return false   // all whitespace (handled as blank earlier anyway)
    }
}

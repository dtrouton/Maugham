import Foundation

/// Enumerate blank-line-delimited blocks of `text` within `range`.
/// A blank line contains only spaces/tabs. Block ranges exclude the
/// delimiting blank lines. Used so inline emphasis scans per PARAGRAPH
/// (spec ledger: paragraph-scoped emphasis) instead of per line.
enum BlankLineBlocks {
    static func enumerate(_ text: NSString, in range: NSRange,
                          _ body: (NSRange) -> Void) {
        var blockStart: Int? = nil
        var lineStart = range.location
        let end = range.location + range.length
        func flush(_ upTo: Int) {
            if let s = blockStart, upTo > s {
                body(NSRange(location: s, length: upTo - s)); blockStart = nil
            }
        }
        while lineStart < end {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let content = text.substring(with: lineRange)
            let isBlank = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank { flush(lineStart) }
            else if blockStart == nil { blockStart = lineRange.location }
            lineStart = lineRange.location + lineRange.length
            if lineRange.length == 0 { break }   // safety at text end
        }
        flush(end)
    }
}

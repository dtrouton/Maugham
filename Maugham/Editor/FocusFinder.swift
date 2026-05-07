import Foundation

/// Given a body of text and a cursor location, returns the range of the
/// containing sentence or paragraph. Used by the editor to compute the
/// "active region" for sentence/paragraph focus dimming.
public enum FocusFinder {

    public static func sentenceRange(in text: String, cursor: Int) -> NSRange {
        rangeOfSentence(in: text, cursor: cursor)
    }

    public static func paragraphRange(in text: String, cursor: Int) -> NSRange {
        rangeOfParagraph(in: text, cursor: cursor)
    }

    // MARK: - Sentence

    private static func rangeOfSentence(in text: String, cursor: Int) -> NSRange {
        let nsText = text as NSString
        guard nsText.length > 0 else { return NSRange(location: 0, length: 0) }

        let clamped = max(0, min(cursor, nsText.length))
        let probe = clamped == nsText.length ? max(0, clamped - 1) : clamped

        var found = NSRange(location: 0, length: nsText.length)
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, stop in
            if NSLocationInRange(probe, range) || range.location == probe {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: - Paragraph (blank-line-delimited blocks)

    /// Returns the range of the blank-line-delimited paragraph block that
    /// contains `cursor`. A "paragraph" here is a run of lines separated from
    /// adjacent runs by one or more blank lines (lines containing only \n).
    private static func rangeOfParagraph(in text: String, cursor: Int) -> NSRange {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        let clamped = max(0, min(cursor, length))

        // Build paragraph block ranges by scanning for double-newline separators.
        // We collect (start, end) pairs where each range covers a block of
        // non-blank content (plus its trailing newlines up to but not including
        // the blank-line boundary).
        var blocks: [NSRange] = []
        var blockStart = 0
        var i = 0

        while i < length {
            let ch = nsText.character(at: i)
            // Detect a blank line: \n followed immediately by \n (or \r\n etc.)
            // We scan for runs of newlines. A run of 2+ consecutive newline
            // characters signals a paragraph boundary.
            if ch == UInt16(("\n" as UnicodeScalar).value) {
                // Check if the *next* character is also a newline (blank line).
                if i + 1 < length &&
                   nsText.character(at: i + 1) == UInt16(("\n" as UnicodeScalar).value) {
                    // End current block at i (exclusive), record it.
                    if i > blockStart {
                        blocks.append(NSRange(location: blockStart, length: i - blockStart))
                    }
                    // Skip over all consecutive newlines.
                    while i < length &&
                          nsText.character(at: i) == UInt16(("\n" as UnicodeScalar).value) {
                        i += 1
                    }
                    blockStart = i
                    continue
                }
            }
            i += 1
        }
        // Capture trailing block.
        if blockStart < length {
            blocks.append(NSRange(location: blockStart, length: length - blockStart))
        }

        // If no blocks found, return full range.
        guard !blocks.isEmpty else {
            return NSRange(location: 0, length: length)
        }

        // Find the block containing the cursor.
        // For cursor == length (end of text), use length - 1.
        let probe = clamped == length ? max(0, length - 1) : clamped

        for block in blocks {
            if NSLocationInRange(probe, block) || block.location == probe {
                return block
            }
        }

        // Cursor is in a separator region; find nearest block.
        // Return the block just after the cursor position (next block start >= cursor).
        for block in blocks {
            if block.location >= probe {
                return block
            }
        }

        // Fallback: last block.
        return blocks.last!
    }
}

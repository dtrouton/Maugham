import Foundation

/// Strips the inline paragraph-id anchors the Mac writes into manuscript
/// markdown, so the phone reader never renders raw `<!-- ¶XXXX -->` noise.
///
/// WHY this exact shape: the anchor format is the join key between the `.md`
/// on disk and the op log. It is EMITTED by
/// `ParagraphID.formatComment` (MaughamCore/ParagraphID.swift:22-24) as
/// `"<!-- ¶\(id) -->"`, and the authoritative PARSE gate is
/// `ParagraphID.parseComment` (same file, lines 26-35) whose regex is
/// `^<!--\s*¶([0-9abcdefghjkmnpqrstvwxyz]{4})\s*-->$`. So the anchor always:
///   - opens with `<!--`, optional whitespace, a literal `¶` sentinel,
///   - then exactly 4 chars from the alphabet `0-9 a-z` minus the ambiguous
///     letters `i l o u` (tripwire 8: `[0123456789abcdefghjkmnpqrstvwxyz]`),
///   - optional whitespace, `-->`.
/// Materializer (MaughamCore/Materializer.swift:14-21) writes each anchor on
/// its OWN line followed by a blank line, then the paragraph text. We therefore
/// match the `¶` sentinel + 4-char alphabet exactly — NOT "any HTML comment" —
/// so unrelated comments like `<!-- TODO -->` survive.
enum ParagraphAnchorStripper {
    /// Remove the inline paragraph-id HTML-comment anchors from manuscript
    /// markdown. Leaves all other content (including unrelated HTML comments)
    /// intact.
    static func strip(_ markdown: String) -> String {
        // Match only the anchor TOKEN — mirroring `ParagraphID.parseComment`'s
        // gate (the `¶` sentinel + 4 chars from the restricted alphabet). We do
        // NOT consume surrounding newlines: an own-line anchor removal leaves an
        // empty line, which the blank-run collapse below folds back into normal
        // paragraph spacing. Matching the token only keeps a mid-paragraph
        // (inline) anchor from eating an adjacent paragraph break.
        let anchorPattern = "<!--[ \\t]*¶[0123456789abcdefghjkmnpqrstvwxyz]{4}[ \\t]*-->"
        guard let regex = try? NSRegularExpression(pattern: anchorPattern) else {
            return markdown
        }
        let fullRange = NSRange(markdown.startIndex..., in: markdown)
        let withoutAnchors = regex.stringByReplacingMatches(
            in: markdown, range: fullRange, withTemplate: ""
        )

        // Trim trailing whitespace an inline anchor removal may leave dangling at
        // a line end, preserving line structure (incl. any trailing newline:
        // split+join with empty subsequences round-trips it).
        let trimmed = withoutAnchors
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var end = line.endIndex
                while end > line.startIndex {
                    let prev = line.index(before: end)
                    if line[prev] == " " || line[prev] == "\t" { end = prev } else { break }
                }
                return line[line.startIndex..<end]
            }
            .joined(separator: "\n")

        // The Materializer writes each anchor on its own line followed by a
        // deliberate blank line. Removing the anchor leaves that blank PLUS the
        // now-empty anchor line — a run of 3+ newlines. Collapse runs of 3+ to
        // exactly 2 so paragraphs keep a single blank line between them, while a
        // correct `\n\n` break (or a no-anchor doc) is left untouched.
        guard let collapse = try? NSRegularExpression(pattern: "\\n{3,}") else { return trimmed }
        return collapse.stringByReplacingMatches(
            in: trimmed,
            range: NSRange(trimmed.startIndex..., in: trimmed),
            withTemplate: "\n\n"
        )
    }
}

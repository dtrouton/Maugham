import Foundation

/// Turns the on-disk manuscript markdown (which carries the op-log join
/// anchors) into the *display* form, with the anchors hidden. The single
/// source of truth for that transform across both targets: the Mac editor's
/// `RenderFilter.stripComments` forwards here, and the iOS reader
/// (`DocumentReaderView`) calls it directly — so the two surfaces can never
/// drift, and neither can forget a kind of anchor.
///
/// Two anchor kinds live in a manuscript:
///   - `<!-- ¶id -->` paragraph anchors — always on their OWN line (the
///     `Materializer` emits each on its own line followed by a blank). The
///     gate is `ParagraphID.parseComment` (`^…$`-anchored), so only own-line
///     anchors are stripped; an unrelated comment like `<!-- TODO -->` and a
///     wrong-shaped id both survive.
///   - `<!--t-XXXXXX-->` inline task anchors — appear mid-line; stripped by a
///     regex that also eats one optional leading whitespace so
///     `[[todo: x]]<!--t-X--> rest` collapses to `[[todo: x]] rest`.
public enum MarkdownDisplayFilter {
    /// Inline task anchor + an optional single leading whitespace char. Eating
    /// the leading space keeps `… foo <!--t-X-->` collapsing to `… foo` (no
    /// trailing space) and bracketed forms to a single space.
    private static let taskAnchorRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"\s?<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->"#)
    }()

    /// Captures the 6-char id out of a task anchor (no leading-space prefix).
    private static let taskAnchorIDRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<!--t-([0123456789abcdefghjkmnpqrstvwxyz]{6})-->"#)
    }()

    /// Strip the `<!-- ¶id -->` paragraph-anchor lines (collapsing the blank
    /// that separated each from its paragraph) and any inline `<!--t-XXXXXX-->`
    /// task anchors. Other HTML comments are kept. Leading/trailing whitespace
    /// is trimmed (display form).
    ///
    /// Removing a paragraph-anchor line collapses the following blank, so
    /// `<!-- ¶id -->\n\nFirst.` becomes `First.` rather than `\n\nFirst.` — the
    /// deliberate blank line *between* paragraphs is the one that follows the
    /// paragraph body, which is preserved.
    public static func stripAnchors(_ stored: String) -> String {
        let lines = stored.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var out: [String] = []
        var skipNextBlank = false
        for line in lines {
            let s = String(line)
            if ParagraphID.parseComment(s) != nil {
                // Drop this anchor line and the single blank that immediately
                // follows it (the separator between the comment and its
                // paragraph).
                skipNextBlank = true
                continue
            }
            if skipNextBlank {
                skipNextBlank = false
                if s.trimmingCharacters(in: .whitespaces).isEmpty {
                    continue
                }
            }
            out.append(s)
        }
        let paragraphStripped = out.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripTaskAnchorsInline(paragraphStripped)
    }

    /// Strip inline task anchors from arbitrary text. Used by the display strip
    /// above and by the Mac editor's save-time anchor round-trip.
    public static func stripTaskAnchorsInline(_ s: String) -> String {
        let ns = s as NSString
        return taskAnchorRegex.stringByReplacingMatches(
            in: s,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "")
    }

    /// The first inline task anchor in `line`: the full match range (which
    /// includes the optional single leading-whitespace char, matching the strip
    /// regex) and the 6-char anchor id. nil when the line has no task anchor.
    /// The Mac editor's `RenderFilter.extractAnchor` uses this to re-inject an
    /// anchor onto an edited line; the phone never calls it.
    public static func firstTaskAnchor(in line: String) -> (range: NSRange, id: String)? {
        let ns = line as NSString
        guard let match = taskAnchorRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        let matched = ns.substring(with: match.range)
        let matchedNS = matched as NSString
        guard let idMatch = taskAnchorIDRegex.firstMatch(
            in: matched, range: NSRange(location: 0, length: matchedNS.length)),
            let r = Range(idMatch.range(at: 1), in: matched)
        else { return nil }
        return (match.range, String(matched[r]))
    }
}

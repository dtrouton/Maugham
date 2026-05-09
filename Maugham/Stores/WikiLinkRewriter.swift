import Foundation

/// Rewrites `[[Title]]` wiki-link occurrences in a document body when the
/// referenced document is renamed. Match is case-insensitive and trims
/// whitespace inside the brackets (matching the resolver in
/// `WikiLinkProject`); replacement uses the new title's exact casing
/// without any padding whitespace.
public enum WikiLinkRewriter {

    /// Returns a rewritten body with every `[[oldTitle]]` replaced by
    /// `[[newTitle]]`. Returns nil when no replacements were made — the
    /// caller can use that signal to skip the disk write.
    public static func rewrite(
        body: String,
        oldTitle: String,
        newTitle: String
    ) -> String? {
        let normalizedOld = oldTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedOld.isEmpty else { return nil }

        let nsBody = body as NSString
        guard let regex = try? NSRegularExpression(
            pattern: #"\[\[([^\[\]\n]+?)\]\]"#) else {
            return nil
        }

        let fullRange = NSRange(location: 0, length: nsBody.length)
        let matches = regex.matches(in: body, range: fullRange)
        guard !matches.isEmpty else { return nil }

        // Build the rewrite back-to-front so earlier ranges stay valid.
        var output = body
        var didReplace = false
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let outerRange = Range(match.range, in: output),
                  let innerRange = Range(match.range(at: 1), in: output) else {
                continue
            }
            let inner = String(output[innerRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard inner == normalizedOld else { continue }
            output.replaceSubrange(outerRange, with: "[[\(newTitle)]]")
            didReplace = true
        }

        return didReplace ? output : nil
    }
}

import Foundation

/// The two recognised shapes a ruling's text can take (translation pipeline
/// spec §3, §3.1) — a **directive** anchored to a paragraph, and a **glossary
/// entry**. Both are computed over `text`; nothing here changes what
/// `RulingsSection` parses, renders or round-trips, which is what lets a
/// pre-pipeline build read the same file as ordinary rulings.
///
/// **No em-dash, guillemet or line break may appear in a composed line.**
/// `RulingsSection.parseItem` splits on the rightmost `—` to find the
/// `ruled <date>, <provenance>` suffix, so an em-dash inside a directive's
/// instruction or a glossary note would be read as the suffix; `«`/`»` inside
/// a glossary component would break `glossaryPattern`'s `[^«»]+` grouping; an
/// interior newline would break the one-line-per-ruling stratum. The
/// composers sanitize every component before assembling the line.
public extension Ruling {

    enum Provenance {
        public static let translatorsNote = "translator's note"
        public static let glossary = "glossary"
    }

    // MARK: - Directive

    /// `¶k7mq: keep the three "and"s` → `("k7mq", "keep the three \"and\"s")`.
    /// The anchor must be a 4-char id in `ParagraphID`'s alphabet followed by a
    /// colon and a non-empty instruction; anything else is an ordinary ruling.
    var directive: (paragraphId: String, text: String)? {
        guard let match = Self.directivePattern.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)),
              let idRange = Range(match.range(at: 1), in: text),
              let bodyRange = Range(match.range(at: 2), in: text)
        else { return nil }
        let body = text[bodyRange].trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return (String(text[idRange]), body)
    }

    /// The paragraph a directive is about; nil for every other ruling.
    var paragraphId: String? { directive?.paragraphId }

    /// The line text for a directive on `paragraphId`.
    static func directiveText(paragraphId: String, _ instruction: String) -> String {
        "¶\(paragraphId): \(lineSafe(instruction))"
    }

    // MARK: - Glossary

    /// `«October» → «Octubre» (the month, never a name)` →
    /// `("October", "Octubre", "the month, never a name")`; the note is optional.
    var glossary: (term: String, rendering: String, note: String?)? {
        guard let match = Self.glossaryPattern.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)),
              let termRange = Range(match.range(at: 1), in: text),
              let renderingRange = Range(match.range(at: 2), in: text)
        else { return nil }
        let note = Range(match.range(at: 3), in: text).map {
            text[$0].trimmingCharacters(in: .whitespaces)
        }
        return (String(text[termRange]), String(text[renderingRange]),
                (note?.isEmpty ?? true) ? nil : note)
    }

    /// The line text for a glossary entry.
    static func glossaryText(term: String, rendering: String, note: String?) -> String {
        var line = "«\(lineSafe(term))» → «\(lineSafe(rendering))»"
        if let note, !note.trimmingCharacters(in: .whitespaces).isEmpty {
            line += " (\(lineSafe(note)))"
        }
        return line
    }

    // MARK: - Patterns

    /// The alphabet is `ParagraphID`'s: no i, l, o, u.
    private static let directivePattern = try! NSRegularExpression(
        pattern: "^¶([0-9abcdefghjkmnpqrstvwxyz]{4}):(.*)$")

    private static let glossaryPattern = try! NSRegularExpression(
        pattern: "^«([^«»]+)»\\s*→\\s*«([^«»]+)»(?:\\s*\\((.*)\\))?$")

    /// Makes a component safe to sit inside a composed ruling line: the
    /// em-dash `parseItem` splits on becomes a hyphen, the guillemets
    /// `glossaryPattern` reserves for term/rendering delimiters are removed,
    /// and any run of whitespace (including a line break) collapses to a
    /// single space, so the stratum's one-line-per-ruling shape always holds.
    private static func lineSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "«", with: "")
            .replacingOccurrences(of: "»", with: "")
            .replacingOccurrences(of: "[\\s]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation
import MaughamCore

/// **What a gloss is briefed on** (translation pipeline spec §9): one
/// translated paragraph, its two neighbours as context, and the edition's
/// texture — nothing else.
///
/// The author's question is *what does this now say?*, and the only honest
/// answer comes from a model that has **not seen the original**. Shown the
/// source, a model renders the source it can read rather than the translation
/// it was asked about, and the author is told their book is intact by a process
/// that never looked at the book. So there is no source field on `Inputs` at
/// all: the property is enforced by the type, not by a caller remembering. That
/// is the difference between this and `CollatorBriefing`, which holds both
/// texts on purpose because judging drift is exactly what it is for.
///
/// Pure, like every briefing here — no I/O, no clock (`TranslatorBriefing`'s
/// discipline). What is read off disk is `SpotCheck`'s.
enum GlossBriefing {

    struct Inputs: Equatable {
        /// The language being glossed FROM.
        let language: String
        /// The author's own, which the gloss is written IN.
        let authorLanguage: String
        /// The edition's texture line, when the brief has one — the register
        /// the gloss should be read against. Nil when it has none.
        let textureLine: String?
        /// The paragraph before, as context. Nil at the top of the document.
        let before: String?
        /// The paragraph being glossed.
        let paragraph: String
        /// The paragraph after, as context. Nil at the end of the document.
        let after: String?

        init(language: String, authorLanguage: String, textureLine: String? = nil,
             before: String? = nil, paragraph: String, after: String? = nil) {
            self.language = language
            self.authorLanguage = authorLanguage
            self.textureLine = textureLine
            self.before = before
            self.paragraph = paragraph
            self.after = after
        }
    }

    /// One object, one field. `CollatorReport.schemaDescription`'s shape at the
    /// smallest size the catalogue has: a gloss is a sentence, and a schema
    /// that let it be anything else would put prose where the author expects
    /// their own paragraph back.
    static let schemaDescription: String = """
        Respond with exactly one fenced JSON object \u{2014} no prose before, inside, \
        or after it:
        {"gloss":<a literal rendering, into the author's language, of what this paragraph now says>}
        "gloss" is required and never empty. It is a back-rendering, not a \
        translation you would publish: keep what the paragraph actually says, \
        including anything clumsy or wrong, because that is what the author is \
        reading it to find. Nothing else belongs in the object.
        """

    static func compose(inputs: Inputs) -> String {
        var sections = [roleFrame(inputs)]
        if let texture = inputs.textureLine, !texture.isEmpty {
            sections.append("The edition\u{2019}s texture: \(cleaned(texture))")
        }
        sections.append(paragraphSection(inputs))
        sections.append(schemaDescription)
        return sections.joined(separator: "\n\n")
    }

    /// **The line that finds the register.** An edition brief is an essay, and
    /// somewhere in it the author usually says what this edition should SOUND
    /// like. Briefing the whole essay would drown one paragraph's gloss in
    /// doctrine it cannot act on; briefing nothing would gloss a deliberately
    /// archaic rendering as though it were a mistake.
    ///
    /// Markdown is stripped rather than matched, so the same sentence is found
    /// whether the author wrote `**Texture** — …`, `## Texture`, or a bullet.
    static func textureLine(in editionBrief: String?) -> String? {
        guard let editionBrief else { return nil }
        for raw in editionBrief.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = strippingMarkdown(String(raw))
            if line.lowercased().hasPrefix(marker) { return line }
        }
        return nil
    }

    private static let marker = "texture"

    /// Emphasis removed wherever it is, then leading heading/list/emphasis
    /// punctuation — so a prefix test can be a prefix test.
    private static func strippingMarkdown(_ line: String) -> String {
        var text = line
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
        while let first = text.first, "#->*_ \t".contains(first) {
            text.removeFirst()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func roleFrame(_ inputs: Inputs) -> String {
        "You are glossing one paragraph of a \(inputs.language) translation for its "
            + "author, who reads \(inputs.authorLanguage) and not \(inputs.language). "
            + "Render, literally, what the paragraph says \u{2014} a back-rendering, "
            + "not a polish, not a judgement."
    }

    private static func paragraphSection(_ inputs: Inputs) -> String {
        var lines: [String] = []
        if inputs.before != nil || inputs.after != nil {
            lines.append("The neighbouring paragraphs are here for continuity only "
                         + "\u{2014} do not gloss these.")
        }
        if let before = inputs.before { lines.append("Before: \(cleaned(before))") }
        lines.append("The paragraph: \(cleaned(inputs.paragraph))")
        if let after = inputs.after { lines.append("After: \(cleaned(after))") }
        return lines.joined(separator: "\n")
    }

    private static func cleaned(_ text: String) -> String {
        MarkdownDisplayFilter.stripAnchors(text)
    }
}

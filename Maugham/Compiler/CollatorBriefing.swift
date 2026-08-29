import Foundation
import MaughamCore

/// What the collator is sent (translation pipeline spec §2): role frame and
/// doctrine; craft intent verbatim (fidelity to what the writer MEANT is its
/// business); the edition brief verbatim; the glossary as a table; and the
/// paragraph pairs in `sequence` order — original, translation, then that
/// paragraph's directives, which are the standard for it.
///
/// **Not briefed**: reader notes, translator queries, the bible. Pure.
enum CollatorBriefing {

    struct Inputs: Equatable {

        /// One paragraph, both texts. `translation` nil = untranslated, listed
        /// as such so the collator can report `untranslated` rather than guess.
        /// The caller strips inline task anchors
        /// (`MarkdownDisplayFilter.stripTaskAnchorsInline`) before passing
        /// text here, as the translator's gather does; `compose` strips only
        /// whole-line `¶id` anchors.
        struct Pair: Equatable {
            let paragraphId: String
            let sourceText: String
            let translation: String?
            /// The writer's directives on this paragraph, from either
            /// statement — `Directives.byParagraph`'s texts.
            let directives: [String]

            init(paragraphId: String, sourceText: String, translation: String?,
                 directives: [String] = []) {
                self.paragraphId = paragraphId
                self.sourceText = sourceText
                self.translation = translation
                self.directives = directives
            }
        }

        let collatorName: String
        let language: String
        let authorLanguage: String
        let roleBrief: String?
        let craftIntentText: String?
        let editionBriefText: String?
        let glossary: [GlossaryEntry]
        let pairs: [Pair]

        init(collatorName: String, language: String, authorLanguage: String,
             roleBrief: String? = nil, craftIntentText: String? = nil,
             editionBriefText: String? = nil, glossary: [GlossaryEntry] = [],
             pairs: [Pair] = []) {
            self.collatorName = collatorName
            self.language = language
            self.authorLanguage = authorLanguage
            self.roleBrief = roleBrief
            self.craftIntentText = craftIntentText
            self.editionBriefText = editionBriefText
            self.glossary = glossary
            self.pairs = pairs
        }

        /// `CollatorReport.parse(_:briefedParagraphIds:)`'s second argument:
        /// a departure names a paragraph with a translation to depart in.
        var briefedParagraphIds: Set<String> {
            Set(pairs.compactMap { $0.translation == nil ? nil : $0.paragraphId })
        }
    }

    static func compose(inputs: Inputs) -> String {
        var sections: [String] = [roleFrame(inputs)]
        if let intent = inputs.craftIntentText, !intent.isEmpty {
            sections.append("Declared intent:\n\(cleaned(intent))")
        }
        if let brief = inputs.editionBriefText, !brief.isEmpty {
            sections.append(
                "Edition brief for \(inputs.language) — the author's doctrine for this "
                    + "edition, rulings included. A directive on a paragraph is the "
                    + "standard for that paragraph:\n" + cleaned(brief))
        }
        if let table = GlossaryTable.render(inputs.glossary) {
            sections.append(
                "Glossary — the edition's fixed renderings. Read the whole document "
                    + "against it: a name or term rendered two ways is a departure "
                    + "(kind \"inconsistency\") even when each paragraph is fine alone:\n"
                    + table)
        }
        sections.append(pairsSection(inputs))
        sections.append(CollatorReport.schemaDescription)
        return sections.joined(separator: "\n\n")
    }

    private static func roleFrame(_ inputs: Inputs) -> String {
        var lines = [
            "You are \(inputs.collatorName). You hold the original and the "
                + "\(inputs.language) translation side by side. Write every note and "
                + "every gloss in \(inputs.authorLanguage): the author reads that "
                + "language and not this one, and the gloss is how they will judge "
                + "what the translation now says."
        ]
        if let brief = inputs.roleBrief, !brief.isEmpty {
            lines.append(cleaned(brief))
        }
        return lines.joined(separator: "\n")
    }

    private static func pairsSection(_ inputs: Inputs) -> String {
        var lines = [
            "The document, paragraph by paragraph — the original, then what the "
                + "translation says there, then any directive the author has ruled "
                + "on that paragraph:"
        ]
        for pair in inputs.pairs {
            if let translation = pair.translation {
                lines.append("[\(pair.paragraphId)]")
                lines.append("Original: \(cleaned(pair.sourceText))")
                lines.append("Translation: \(cleaned(translation))")
            } else {
                lines.append("[\(pair.paragraphId)] (not translated)")
                lines.append("Original: \(cleaned(pair.sourceText))")
            }
            for directive in pair.directives {
                lines.append("Directive from the author: \(cleaned(directive))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func cleaned(_ text: String) -> String {
        MarkdownDisplayFilter.stripAnchors(text)
    }
}

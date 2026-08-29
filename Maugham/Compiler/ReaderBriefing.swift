import Foundation
import MaughamCore

/// What the blind reader is sent (translation pipeline spec §2): a role frame,
/// the edition brief verbatim, the translated text in `sequence` order with a
/// marker where nothing stands yet, and the report contract.
///
/// **What is NOT here is the design.** No source text — the type has no field
/// it could travel in. No craft intent essay (it is about the English), no
/// translator queries, no prior reader notes (a reader shown its last notes
/// defends them), no bible (a side channel to the source). A stale or missing
/// paragraph is a gap marker and never the source.
///
/// Pure, `TranslatorBriefing`'s discipline: no I/O, no clock, no store.
enum ReaderBriefing {

    struct Inputs: Equatable {

        /// One paragraph of the edition, in `sequence` order. `translation`
        /// is nil for a paragraph the reader must not see yet — missing, or
        /// stale (the caller passes nil for stale: an out-of-date translation
        /// is not the edition either). The caller strips inline task anchors
        /// (`MarkdownDisplayFilter.stripTaskAnchorsInline`) before passing
        /// text here, as the translator's gather does; `compose` strips only
        /// whole-line `¶id` anchors.
        struct Paragraph: Equatable {
            let paragraphId: String
            let translation: String?

            init(paragraphId: String, translation: String?) {
                self.paragraphId = paragraphId
                self.translation = translation
            }
        }

        let readerName: String
        let language: String
        /// The language the report and every note are written in — the
        /// author's own. Resolved by the caller (Plan 3); this type only
        /// says it.
        let authorLanguage: String
        /// `ProductionRole.effectiveBrief` for this reader.
        let roleBrief: String?
        /// The edition brief verbatim, rulings and directives included.
        let editionBriefText: String?
        let paragraphs: [Paragraph]

        init(readerName: String, language: String, authorLanguage: String,
             roleBrief: String? = nil, editionBriefText: String? = nil,
             paragraphs: [Paragraph] = []) {
            self.readerName = readerName
            self.language = language
            self.authorLanguage = authorLanguage
            self.roleBrief = roleBrief
            self.editionBriefText = editionBriefText
            self.paragraphs = paragraphs
        }

        /// The ids a note may name — `ReaderReport.parse(_:briefedParagraphIds:)`'s
        /// second argument. A gap is not readable and cannot be noted.
        var briefedParagraphIds: Set<String> {
            Set(paragraphs.compactMap { $0.translation == nil ? nil : $0.paragraphId })
        }
    }

    static func compose(inputs: Inputs) -> String {
        var sections: [String] = [roleFrame(inputs)]
        if let brief = inputs.editionBriefText, !brief.isEmpty {
            sections.append(
                "Edition brief for \(inputs.language) — the author's doctrine for this "
                    + "edition: its register, what stays foreign, and rulings settled in "
                    + "earlier sessions. A feature the brief declares deliberate is not a "
                    + "fault:\n" + cleaned(brief))
        }
        sections.append(textSection(inputs))
        sections.append(ReaderReport.schemaDescription)
        return sections.joined(separator: "\n\n")
    }

    /// `[<id> — not yet translated]`, spec §2's exact shape.
    static func gapMarker(_ paragraphId: String) -> String {
        "[\(paragraphId) \u{2014} not yet translated]"
    }

    private static func roleFrame(_ inputs: Inputs) -> String {
        var lines = [
            "You are \(inputs.readerName), reading the \(inputs.language) edition of a "
                + "book. You have not seen, and will not see, any other version of it. "
                + "Write your notes and your report in \(inputs.authorLanguage): the "
                + "author reads that language and not this one."
        ]
        if let brief = inputs.roleBrief, !brief.isEmpty {
            lines.append(cleaned(brief))
        }
        return lines.joined(separator: "\n")
    }

    private static func textSection(_ inputs: Inputs) -> String {
        var lines = [
            "The book, in \(inputs.language), paragraph by paragraph. A paragraph "
                + "marked not yet translated has no text for you; do not note it and "
                + "do not guess at it:"
        ]
        for paragraph in inputs.paragraphs {
            if let translation = paragraph.translation {
                lines.append("[\(paragraph.paragraphId)]")
                lines.append(cleaned(translation))
            } else {
                lines.append(gapMarker(paragraph.paragraphId))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func cleaned(_ text: String) -> String {
        MarkdownDisplayFilter.stripAnchors(text)
    }
}

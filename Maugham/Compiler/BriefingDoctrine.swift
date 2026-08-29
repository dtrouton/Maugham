import Foundation
import MaughamCore

/// **The writer's directives and glossary, as the plain values a briefing
/// takes** (translation pipeline spec §2, §3, §3.1).
///
/// Both live in the writer's own statements as rulings of a recognised shape
/// (`Ruling.directive`, `Ruling.glossary` — MaughamCore, P1). This file is
/// where a statement's markdown becomes lists the three briefings and the
/// work-list derivation can read without knowing what a statement is. Pure:
/// no store, no clock, no I/O — `TranslatorBriefing`'s discipline, one layer
/// down.

/// One paragraph-anchored instruction from the writer.
struct Directive: Equatable {
    enum Source: Equatable {
        /// The piece's craft intent — a directive about the English, applying
        /// to every edition.
        case craftIntent
        /// This language's edition brief — this edition only.
        case editionBrief
    }

    let paragraphId: String
    let text: String
    /// The day it was ruled (UTC midnight — `RulingsSection`'s date is a day),
    /// or nil for a hand-written line with no suffix.
    let ruledOn: Date?
    let source: Source
}

enum Directives {

    /// Every directive in the two statements, craft intent first, each in its
    /// statement's own order. Either text may be nil (no statement) or carry
    /// no rulings at all.
    static func gather(craftIntent: String?, editionBrief: String?) -> [Directive] {
        directives(in: craftIntent, source: .craftIntent)
            + directives(in: editionBrief, source: .editionBrief)
    }

    static func byParagraph(_ directives: [Directive]) -> [String: [Directive]] {
        Dictionary(grouping: directives, by: \.paragraphId)
    }

    /// **Whether a FRESH paragraph is this round's work anyway** — spec §2's
    /// `directed`: a directive ruled after the paragraph's translation record.
    ///
    /// Compared on **days**, because that is what the stratum stores: a
    /// ruling's `ruledOn` is UTC midnight of its day, so "after" means "ruled
    /// on or after the day the record was written". Same-day counts — the day
    /// cannot say which came first, and re-sending a paragraph once is cheaper
    /// than silently dropping the writer's ruling. The consequence, recorded:
    /// a paragraph directed today stays in the work-list for the rest of
    /// today's Runs. Plan 3's round record is the place to refine that if it
    /// ever costs anything.
    ///
    /// An **undated** directive (a bare hand-written line) never directs: with
    /// no date there is no "after", and treating it as always-after would keep
    /// the paragraph work on every Run for ever. It still reaches the
    /// translator whenever the paragraph is work for another reason.
    ///
    /// `translatedAt == nil` (no record) is `missing`, already work — this
    /// predicate answers only for paragraphs that have a translation.
    static func isDirected(translatedAt: Date?, directives: [Directive]) -> Bool {
        guard let translatedAt else { return false }
        let translatedDay = utc.startOfDay(for: translatedAt)
        return directives.contains { directive in
            guard let ruledOn = directive.ruledOn else { return false }
            return ruledOn >= translatedDay
        }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func directives(in markdown: String?, source: Directive.Source) -> [Directive] {
        guard let markdown, !markdown.isEmpty else { return [] }
        return RulingsSection.parse(markdown).rulings.compactMap { ruling in
            guard let directive = ruling.directive else { return nil }
            return Directive(paragraphId: directive.paragraphId, text: directive.text,
                             ruledOn: ruling.ruledOn, source: source)
        }
    }
}

/// One glossary row: a source-language term and the edition's rendering.
struct GlossaryEntry: Equatable {
    let term: String
    let rendering: String
    let note: String?
}

enum GlossaryTable {

    /// Every glossary-shaped ruling in the edition brief, in the brief's order.
    static func gather(editionBrief: String?) -> [GlossaryEntry] {
        guard let editionBrief, !editionBrief.isEmpty else { return [] }
        return RulingsSection.parse(editionBrief).rulings.compactMap { ruling in
            guard let entry = ruling.glossary else { return nil }
            return GlossaryEntry(term: entry.term, rendering: entry.rendering, note: entry.note)
        }
    }

    /// The table a briefing carries — a markdown table, because a table is
    /// what makes a glossary readable by an author who cannot read the
    /// language (spec §3.1), and what a model reads back as rows. `nil` for
    /// no entries: a briefing announces no empty glossary.
    static func render(_ entries: [GlossaryEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        var lines = ["| Term | Rendering | Note |", "|---|---|---|"]
        for entry in entries {
            lines.append("| \(cell(entry.term)) | \(cell(entry.rendering)) | \(cell(entry.note ?? "")) |")
        }
        return lines.joined(separator: "\n")
    }

    /// A pipe inside a cell is the table's own delimiter; escaped, not stripped
    /// — the writer's term is the writer's term.
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }
}

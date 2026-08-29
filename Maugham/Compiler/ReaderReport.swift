import Foundation

/// What one blind read returns (translation pipeline spec §4): an `overall`
/// reader's report with a verdict against the brief's TEXTURE line, and notes
/// that can only be about fluency — the kinds are closed to the reader's remit.
/// A note names a paragraph the reader was briefed with, or the report fails.
struct ReaderReport: Equatable {

    enum Verdict: String, CaseIterable {
        case readsAsNative = "reads_as_native"
        case readsAsTranslated = "reads_as_translated"
        case mixed
    }

    enum NoteKind: String, CaseIterable {
        case unidiomatic, register, rhythm, grammar, inconsistency
    }

    enum Severity: String, CaseIterable { case minor, major }

    struct Overall: Equatable {
        let verdict: Verdict
        let text: String
    }

    struct Note: Equatable {
        let paragraphId: String
        let kind: NoteKind
        let severity: Severity
        let text: String
    }

    let overall: Overall
    let notes: [Note]

    enum WireField {
        static let overall = "overall"
        static let verdict = "verdict"
        static let text = "text"
        static let notes = "notes"
        static let paragraphId = "paragraph_id"
        static let kind = "kind"
        static let severity = "severity"
    }

    static let schemaDescription: String = """
        Respond with exactly one fenced JSON object — no prose before, inside, \
        or after it:
        {"overall":{"verdict":"reads_as_native"|"reads_as_translated"|"mixed",\
        "text":<a short reader's report, to the author>},\
        "notes":[{"paragraph_id":<id>,"kind":"unidiomatic"|"register"|"rhythm"|\
        "grammar"|"inconsistency","severity":"minor"|"major","text":<the note>}]}
        "overall" is required: the verdict is against the edition brief's stated \
        texture, and its "text" is a paragraph written to the author in the \
        author's language. Each note names one paragraph you were shown, gives \
        one kind and one severity from the lists above, and says in the \
        author's language what does not sound like this language there. Do not \
        rewrite; do not suggest a rendering; do not guess what an original said. \
        Zero notes is a complete, valid answer. Any note about a paragraph you \
        were not shown, any empty "text", or any kind or severity outside the \
        lists makes the whole report unusable.
        """

    static func parse(_ raw: String, briefedParagraphIds: Set<String>) -> ReaderReport? {
        guard let object = ReportJSON.lastObject(in: raw, shapedBy: [WireField.overall, WireField.notes]),
              let overallObject = object[WireField.overall] as? [String: Any],
              let verdict = ReportJSON.enumValue(overallObject[WireField.verdict], as: Verdict.self),
              let overallText = ReportJSON.nonEmptyString(overallObject[WireField.text]),
              let notes = ReportJSON.parseList(object, key: WireField.notes, parseItem: {
                  parseNote($0, briefed: briefedParagraphIds)
              })
        else { return nil }
        return ReaderReport(overall: Overall(verdict: verdict, text: overallText), notes: notes)
    }

    private static func parseNote(_ item: [String: Any], briefed: Set<String>) -> Note? {
        guard let paragraphId = ReportJSON.nonEmptyString(item[WireField.paragraphId]),
              briefed.contains(paragraphId),
              let kind = ReportJSON.enumValue(item[WireField.kind], as: NoteKind.self),
              let severity = ReportJSON.enumValue(item[WireField.severity], as: Severity.self),
              let text = ReportJSON.nonEmptyString(item[WireField.text])
        else { return nil }
        return Note(paragraphId: paragraphId, kind: kind, severity: severity, text: text)
    }
}

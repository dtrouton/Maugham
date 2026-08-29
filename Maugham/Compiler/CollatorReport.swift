import Foundation

/// What one collation returns (translation pipeline spec §4): an `overall`
/// paragraph on how the two texts hold together, and every departure with a
/// verdict (`holds` — still says what the source says; `drifted` — meaning
/// moved), an accuracy kind, a note, and a **gloss**: the literal back-rendering
/// of what the translation now says there, in the author's language. The gloss
/// is required, because it is the only thing on this report an author who
/// cannot read the language can rule on.
struct CollatorReport: Equatable {

    enum Verdict: String, CaseIterable { case holds, drifted }

    enum Kind: String, CaseIterable {
        case mistranslation, omission, addition, untranslated, inconsistency, rendering
    }

    struct Departure: Equatable {
        let paragraphId: String
        let verdict: Verdict
        let kind: Kind
        let note: String
        let gloss: String
    }

    let overall: String
    let departures: [Departure]

    /// The fix leg's input: only what moved meaning. `holds` departures are
    /// information for the author, never work for the translator.
    var drifted: [Departure] { departures.filter { $0.verdict == .drifted } }

    enum WireField {
        static let overall = "overall"
        static let text = "text"
        static let departures = "departures"
        static let paragraphId = "paragraph_id"
        static let verdict = "verdict"
        static let kind = "kind"
        static let note = "note"
        static let gloss = "gloss"
    }

    static let schemaDescription: String = """
        Respond with exactly one fenced JSON object — no prose before, inside, \
        or after it:
        {"overall":{"text":<how the translation holds together with the original, to the author>},\
        "departures":[{"paragraph_id":<id>,"verdict":"holds"|"drifted",\
        "kind":"mistranslation"|"omission"|"addition"|"untranslated"|"inconsistency"|"rendering",\
        "note":<why this is a departure>,"gloss":<a literal rendering, into the author's language, of what the translation now says here>}]}
        "overall" is required and written to the author in the author's language. \
        A departure is any place the translation does not say what the original \
        says: "holds" when it still means the same thing (a pun re-made, a \
        sentence split — kind "rendering"), "drifted" when meaning moved. A name \
        or term rendered two ways across the document is kind "inconsistency". \
        Every departure carries a "gloss" — never empty — so the author can judge \
        it without reading the language. Zero departures is a complete, valid \
        answer. Any departure about a paragraph you were not shown, any empty \
        field, or any verdict or kind outside the lists makes the whole report \
        unusable.
        """

    static func parse(_ raw: String, briefedParagraphIds: Set<String>) -> CollatorReport? {
        guard let object = ReportJSON.lastObject(in: raw, shapedBy: [WireField.overall, WireField.departures]),
              let overallObject = object[WireField.overall] as? [String: Any],
              let overall = ReportJSON.nonEmptyString(overallObject[WireField.text]),
              let departures = ReportJSON.parseList(object, key: WireField.departures, parseItem: {
                  parseDeparture($0, briefed: briefedParagraphIds)
              })
        else { return nil }
        return CollatorReport(overall: overall, departures: departures)
    }

    private static func parseDeparture(_ item: [String: Any], briefed: Set<String>) -> Departure? {
        guard let paragraphId = ReportJSON.nonEmptyString(item[WireField.paragraphId]),
              briefed.contains(paragraphId),
              let verdict = ReportJSON.enumValue(item[WireField.verdict], as: Verdict.self),
              let kind = ReportJSON.enumValue(item[WireField.kind], as: Kind.self),
              let note = ReportJSON.nonEmptyString(item[WireField.note]),
              let gloss = ReportJSON.nonEmptyString(item[WireField.gloss])
        else { return nil }
        return Departure(paragraphId: paragraphId, verdict: verdict, kind: kind, note: note, gloss: gloss)
    }
}

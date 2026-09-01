import Foundation

/// **What one gloss returns** (translation pipeline spec §9): a single sentence
/// — the literal back-rendering of what the translated paragraph now says, in
/// the author's own language.
///
/// One field, and the smallest parser in the catalogue, but it is a parser
/// rather than "take the turn's text" for the reason every report here has one:
/// a model that answers in prose has not answered. A gloss the author cannot
/// distinguish from commentary is worse than no gloss, because they will act on
/// it. `ReportJSON`'s last-object rule applies unchanged — a model that reasons
/// out loud puts its worked example first and the answer last.
enum GlossReport {

    enum WireField {
        static let gloss = "gloss"
    }

    static func parse(_ raw: String) -> String? {
        guard let object = ReportJSON.lastObject(in: raw, shapedBy: [WireField.gloss])
        else { return nil }
        return ReportJSON.nonEmptyString(object[WireField.gloss])
    }
}

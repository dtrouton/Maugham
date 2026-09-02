import Foundation
import MaughamCore

/// The grammar of the lessons ledger (`Statement.Kind.lessons`): the one place
/// that reads a `## Rulings` row as a **lesson**, a **choice**, or a **retired**
/// entry.
///
/// **A ledger entry is an ordinary ruling and nothing else.** The ledger's file
/// is a statement document like any other — `RulingsSection` parses it,
/// `RulingPerformer` writes it, undo and cross-device merge arrive built. What
/// this type adds is a reading of the ruling's own words, so that "this is a
/// choice I have already made" and "this lesson is retired" are expressible
/// without a fourth field on `Ruling` that only one kind of statement would ever
/// populate.
///
/// **The grammar runs over `Ruling.text` and never over the whole line.** The
/// writer types these entries by hand, so the parser must not require the
/// canonical `— ruled <d MMM yyyy>, <provenance>` suffix (`RulingsSection`'s own
/// tolerance); and a provenance that happens to spell `Choice: ` or
/// `(retired …)` is somebody's *name for who ruled it*, not a marker. Running
/// the grammar over the line would read all of those as something they are not.
///
/// **Addressing an entry.** `RulingsSection` derives a ruling's `id` from its
/// text, so retiring an entry — which rewrites that text — changes its id. No
/// caller may hold one across a write. Address an entry by index at the moment
/// of the write (`RulingsStratum.currentRows(kind:forScope:store:)`) or by
/// heading through `matches`, never by a remembered id.
enum LessonsLedger {

    /// One row of the ledger: what it says, what it is, and the ruling it was
    /// read from.
    ///
    /// `ruling` is kept rather than dropped so a caller that has to write back
    /// can see the provenance and date the writer's file actually carries,
    /// without parsing the section a second time.
    struct Entry: Equatable {
        let heading: String
        let kind: Kind
        let ruling: Ruling
    }

    /// What a row is.
    ///
    /// The date on `.retired` is optional because the marker is what classifies
    /// — a writer who typos the month has still retired the entry, and putting
    /// it back among the open lessons over a bad date would be the parser
    /// arguing with them.
    enum Kind: Equatable {
        case lesson
        case choice
        case retired(Date?)
    }

    /// The marker that makes a row a settled choice rather than a live lesson.
    static let choicePrefix = "Choice: "

    /// The opening of the retired suffix. A retired row ends with a parenthetical
    /// this opens: `<heading> (retired 2 Sep 2026)`.
    private static let retiredPrefix = "(retired"

    // MARK: - Reading

    /// The ledger's preamble and its rows, in file order.
    ///
    /// The essay half is `RulingsSection`'s verbatim, untouched: the ledger's
    /// entries are its content, but the writer may still put a paragraph above
    /// them and this must not move it.
    static func parse(_ markdown: String) -> (essay: String, entries: [Entry]) {
        let (essay, rulings) = RulingsSection.parse(markdown)
        return (essay, rulings.map { ruling in
            Entry(heading: heading(of: ruling.text),
                  kind: classify(ruling.text),
                  ruling: ruling)
        })
    }

    /// The headings of the live lessons, in file order — what the writer is
    /// still working on.
    ///
    /// Choices and retired entries are excluded: a choice is a decision already
    /// made, and a retired lesson is one they are done with.
    static func open(in markdown: String) -> [String] {
        parse(markdown).entries.filter { $0.kind == .lesson }.map(\.heading)
    }

    /// The headings of the settled choices, in file order.
    static func choices(in markdown: String) -> [String] {
        parse(markdown).entries.filter { $0.kind == .choice }.map(\.heading)
    }

    /// A row's heading: its text with the choice prefix and the retired suffix
    /// taken off, so the same lesson has the same heading before and after it is
    /// retired.
    static func heading(of rulingText: String) -> String {
        let withoutSuffix = retirement(in: rulingText)?.heading
            ?? rulingText.trimmingCharacters(in: .whitespaces)
        guard withoutSuffix.hasPrefix(choicePrefix) else { return withoutSuffix }
        return String(withoutSuffix.dropFirst(choicePrefix.count))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Writing the two markers

    /// The ruling text for a settled choice.
    static func choiceText(_ heading: String) -> String {
        choicePrefix + heading
    }

    /// The ruling text for a retired entry.
    ///
    /// The date is written in `RulingsSection`'s own format rather than a second
    /// one declared here — the suffix sits inside the very text that file's
    /// `— ruled <date>` suffix hangs off, and two formats in one line is two
    /// answers to what a date in a ruling looks like.
    static func retiredText(_ heading: String, on date: Date) -> String {
        "\(heading) \(retiredPrefix) \(RulingsSection.formatted(date)))"
    }

    // MARK: - Naming an entry

    /// Whether `candidate` names the entry whose heading is `heading`.
    ///
    /// **Exact after trimming whitespace, and case-sensitive.** The model is
    /// briefed on the heading verbatim, so a heading that comes back in a
    /// different case or with a full stop added is one it rewrote — and matching
    /// it would attach an exercise, or a retirement, to a row the writer never
    /// named. Trimming is forgiven because it is invisible in the file and
    /// nothing about the writer's intent rides on it.
    static func matches(_ candidate: String, heading: String) -> Bool {
        candidate.trimmingCharacters(in: .whitespaces)
            == heading.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Classification

    /// What a row is, read from its own text.
    ///
    /// The public face of the classification `parse` applies, for a caller
    /// holding `Ruling`s rather than markdown: `RulingsStratum.currentRows` is
    /// how a verb addresses the writer's file at the moment of a write (the
    /// addressing note above) and it answers `[Ruling]`. Without this, asking
    /// whether one of those rows is still an OPEN lesson would mean reading and
    /// re-parsing the same statement a second time — and two reads around one
    /// write is two answers that can straddle it.
    static func kind(of rulingText: String) -> Kind { classify(rulingText) }

    /// **Retirement wins over the choice prefix.** A retired choice is nonsense
    /// the writer can fix by hand; reading it as a live choice would put a
    /// closed decision back in front of them, which is the one direction this
    /// disagreement must not fail in.
    private static func classify(_ rulingText: String) -> Kind {
        if let retired = retirement(in: rulingText) { return .retired(retired.date) }
        let trimmed = rulingText.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(choicePrefix) ? .choice : .lesson
    }

    /// The heading and date of a retired row, or nil when the text carries no
    /// retired suffix.
    ///
    /// The closing parenthesis is required because that is what `retiredText`
    /// writes; a bare `(retired` with nothing closing it is a row the writer is
    /// mid-way through typing, and treating it as retired would take the lesson
    /// off their list on a keystroke.
    private static func retirement(in rulingText: String) -> (heading: String, date: Date?)? {
        let trimmed = rulingText.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"),
              let marker = trimmed.range(of: retiredPrefix, options: .backwards)
        else { return nil }
        let inner = trimmed[marker.upperBound..<trimmed.index(before: trimmed.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        let heading = trimmed[..<marker.lowerBound].trimmingCharacters(in: .whitespaces)
        return (heading, RulingsSection.date(from: inner))
    }
}

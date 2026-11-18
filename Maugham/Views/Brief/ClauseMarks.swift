import Foundation
import MaughamCore

/// One of the latest check's readings, placed on the writer's own intent.
///
/// **It carries no model text** (constitution must-not #2, ADR 0027 §1): a
/// kind drawn from one of three words, a range of the WRITER's sentence, the
/// writer's own sentence as the check quoted it, and — for a solid mark — the
/// id of the To resolve item where what the check said is shown.
struct ClauseMark: Equatable {
    /// `strains` draws solid, `silent` dotted. `holds` is no mark at all.
    enum Kind: Equatable { case strains, silent }
    let kind: Kind
    /// UTF-16 offsets into the text the marks were placed in.
    let range: NSRange
    /// The check's quote of the writer's sentence, verbatim as stored.
    let clauseQuote: String
    /// `ResolveItem.finding(docId:_:).id` of the sidecar strain this mark
    /// stands for, when one was given; nil for a dotted mark.
    var resolveItemId: String? = nil
}

/// Whether the latest check's reading may be drawn on the intent, and where.
enum ClauseMarks {

    /// The marks placed, and how many strains/silent quotes were found nowhere.
    struct Placement: Equatable {
        let marks: [ClauseMark]
        let skipped: Int
    }

    /// **True iff the intent is, byte for byte, the text the check read** —
    /// `run.intentSnapshot` and `statementText` both present and equal under
    /// `DerivedWorld.sourceHash(of:)`, the comparison `IntentDrift.mayTrailDraft`
    /// makes. An intent edited since the check gets no marks at all — never a
    /// best-effort match over changed text, which could land a reading on a
    /// sentence the check never saw.
    ///
    /// `statementText` is the WHOLE statement (the snapshot is the whole).
    static func applies(run: CompilerRun?, statementText: String?) -> Bool {
        guard let snapshot = run?.intentSnapshot, let statementText else { return false }
        return DerivedWorld.sourceHash(of: snapshot) == DerivedWorld.sourceHash(of: statementText)
    }

    /// The marks in `paragraph`. See `placement`.
    static func marks(in paragraph: String,
                      clauses: [DiagnosticIngest.ClauseStatus]) -> [ClauseMark] {
        placement(in: paragraph, clauses: clauses).marks
    }

    /// Place each `strains`/`silent` clause on `text` (a paragraph, or the
    /// whole essay — ranges are in whatever string is given, and `skipped`
    /// only means "found nowhere" when that string is the whole essay).
    ///
    /// - A quote matches where its folded form (`fold`) occurs in the text's
    ///   folded form; the range maps back through the fold to the text's own
    ///   UTF-16 offsets. The ingest stores the quote trimmed of surrounding
    ///   whitespace and nothing else (`DiagnosticIngest.nonEmptyString`); the
    ///   fold is wider because a model quoting a sentence straightens its
    ///   quotes, reflows its whitespace and adds quotation marks around it.
    /// - Each clause takes the first occurrence not already taken by an
    ///   earlier clause with the same range; one clause marks once.
    /// - Strains are placed before silent ones, and a silent range that
    ///   overlaps a strain is dropped (it was found, so it is not skipped).
    /// - `holds` gives no mark and is never counted. An empty quote matches
    ///   nothing.
    /// - `findings` (the check's sidecar strains for `docId`) give each solid
    ///   mark its To resolve item, matched by exact `clauseQuote`.
    ///
    /// Marks come back in text order.
    static func placement(in text: String, clauses: [DiagnosticIngest.ClauseStatus],
                          findings: [Diagnostic] = [], docId: String? = nil) -> Placement {
        let folded = Folded(text)
        let ordered = clauses.filter { $0.status == DiagnosticIngest.SectionField.strains }
            + clauses.filter { $0.status == DiagnosticIngest.SectionField.silent }

        var placed: [ClauseMark] = []
        var skipped = 0
        for clause in ordered {
            let kind: ClauseMark.Kind = clause.status == DiagnosticIngest.SectionField.strains
                ? .strains : .silent
            let needle = trimmedQuote(fold(clause.clauseQuote))
            let taken = Set(placed.map { NSStringFromRange($0.range) })
            guard !needle.isEmpty,
                  let range = folded.ranges(of: needle).first(where: { !taken.contains(NSStringFromRange($0)) })
            else {
                skipped += 1
                continue
            }
            if kind == .silent, placed.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) {
                continue
            }
            var resolveItemId: String?
            if kind == .strains, let docId,
               let finding = findings.first(where: { $0.clauseQuote == clause.clauseQuote }) {
                resolveItemId = ResolveItem.finding(docId: docId, finding).id
            }
            placed.append(ClauseMark(kind: kind, range: range, clauseQuote: clause.clauseQuote,
                                     resolveItemId: resolveItemId))
        }
        return Placement(marks: placed.sorted { $0.range.location < $1.range.location }, skipped: skipped)
    }

    // MARK: - The fold

    /// One folded unit per original character (whitespace runs collapse to
    /// one): curly quotes and apostrophes straightened, whitespace a single
    /// space, lowercased.
    private static func fold(_ string: String) -> [String] {
        var units: [String] = []
        for character in string {
            if character.isWhitespace {
                if units.last != " " { units.append(" ") }
            } else {
                units.append(foldCharacter(character))
            }
        }
        return units
    }

    private static func foldCharacter(_ character: Character) -> String {
        switch character {
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}": return "'"
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}": return "\""
        default: return String(character).lowercased()
        }
    }

    private static let quotationMarks: Set<String> = ["\"", "'", "\u{00AB}", "\u{00BB}"]
    private static let trailingPunctuation: Set<String> = [".", ",", ";", ":", "!", "?"]

    /// A folded quote trimmed of surrounding spaces and quotation marks, and
    /// of trailing `.,;:!?`.
    private static func trimmedQuote(_ units: [String]) -> [String] {
        var slice = units[...]
        while let first = slice.first, first == " " || quotationMarks.contains(first) {
            slice = slice.dropFirst()
        }
        while let last = slice.last,
              last == " " || quotationMarks.contains(last) || trailingPunctuation.contains(last) {
            slice = slice.dropLast()
        }
        return Array(slice)
    }

    /// A text's folded units, each knowing the UTF-16 range it came from.
    private struct Folded {
        var units: [String] = []
        var origin: [NSRange] = []

        init(_ text: String) {
            var offset = 0
            for character in text {
                let length = character.utf16.count
                defer { offset += length }
                if character.isWhitespace {
                    if units.last == " " {
                        // The run's one space covers every character of it.
                        origin[origin.count - 1].length += length
                    } else {
                        units.append(" ")
                        origin.append(NSRange(location: offset, length: length))
                    }
                } else {
                    units.append(ClauseMarks.foldCharacter(character))
                    origin.append(NSRange(location: offset, length: length))
                }
            }
        }

        /// Every occurrence of `needle`, in text order, as original ranges.
        func ranges(of needle: [String]) -> [NSRange] {
            guard !needle.isEmpty, needle.count <= units.count else { return [] }
            var found: [NSRange] = []
            for start in 0...(units.count - needle.count)
            where units[start] == needle[0] && Array(units[start..<(start + needle.count)]) == needle {
                let first = origin[start], last = origin[start + needle.count - 1]
                found.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
            }
            return found
        }
    }
}

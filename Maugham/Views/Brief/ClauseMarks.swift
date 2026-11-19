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
    /// **A mark's click** (shell plan 3 Task 6): a solid mark asks To
    /// resolve to open its finding's group and mark the row — or, where the
    /// strain has no item or the list no longer holds it, to say it is
    /// settled. A dotted mark asks nothing. The right column moves to To
    /// resolve with it (`RightColumnPosition.resolve`).
    static func jump(for mark: ClauseMark, docId: String) -> ResolveRequest? {
        guard mark.kind == .strains else { return nil }
        return .focusFinding(docId: docId, itemId: mark.resolveItemId)
    }

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
    /// - Marks never overlap. Strains are placed before silent ones, and
    ///   within each kind the LONGER quote first (stable, so clauses with one
    ///   quote keep their order): an outer sentence is placed before a phrase
    ///   nested in it.
    /// - Each clause takes the FIRST UNMARKED occurrence of its quote, in
    ///   order — one overlapping no mark already placed. A duplicate quote
    ///   therefore lands on the next free occurrence; one clause marks once.
    /// - A clause with no unmarked occurrence is skipped and counted (a nested
    ///   inner strain, a duplicate with no second occurrence) — except a
    ///   silent clause every occurrence of which overlaps a strain: the strain
    ///   wins there, and the silent one is accounted for, not skipped.
    /// - `holds` gives no mark and is never counted. An empty quote matches
    ///   nothing and is counted.
    /// - `findings` (the check's sidecar strains for `docId`) give each solid
    ///   mark its To resolve item. A strain's finding is the one the ingest
    ///   minted from that very clause: same run, a conformance strain, the
    ///   same `clauseQuote` string the clause carries (the ingest writes one
    ///   value into both; there is no other identity). Each finding answers
    ///   one mark; a finding of another run or kind answers none.
    ///
    /// Marks come back in text order.
    static func placement(in text: String, clauses: [DiagnosticIngest.ClauseStatus],
                          findings: [Diagnostic] = [], docId: String? = nil) -> Placement {
        let folded = Folded(text)
        func byKind(_ status: String) -> [Candidate] {
            let candidates: [Candidate] = clauses.filter { $0.status == status }.enumerated().map {
                Candidate(clause: $0.element, needle: trimmedQuote(fold($0.element.clauseQuote)), order: $0.offset)
            }
            return candidates.sorted(by: Candidate.placedFirst)
        }
        let ordered = byKind(DiagnosticIngest.SectionField.strains) + byKind(DiagnosticIngest.SectionField.silent)

        var placed: [ClauseMark] = []
        var skipped = 0
        var unclaimed = findings.filter { $0.kind == .conformanceStrain }
        for candidate in ordered {
            let clause = candidate.clause, needle = candidate.needle
            let kind: ClauseMark.Kind = clause.status == DiagnosticIngest.SectionField.strains
                ? .strains : .silent
            let occurrences = needle.isEmpty ? [] : folded.ranges(of: needle)
            let overlaps = { (range: NSRange, marks: [ClauseMark]) in
                marks.contains { NSIntersectionRange($0.range, range).length > 0 }
            }
            guard let range = occurrences.first(where: { !overlaps($0, placed) }) else {
                let strains = placed.filter { $0.kind == .strains }
                let strainWon = kind == .silent && !occurrences.isEmpty
                    && occurrences.allSatisfy { overlaps($0, strains) }
                if !strainWon { skipped += 1 }
                continue
            }
            var resolveItemId: String?
            if kind == .strains, let docId,
               let index = unclaimed.firstIndex(where: { $0.clauseQuote == clause.clauseQuote }) {
                resolveItemId = ResolveItem.finding(docId: docId, unclaimed.remove(at: index)).id
            }
            placed.append(ClauseMark(kind: kind, range: range, clauseQuote: clause.clauseQuote,
                                     resolveItemId: resolveItemId))
        }
        return Placement(marks: placed.sorted { $0.range.location < $1.range.location }, skipped: skipped)
    }

    /// One clause with its folded quote and its place in the check's order.
    private struct Candidate {
        let clause: DiagnosticIngest.ClauseStatus
        let needle: [String]
        let order: Int

        /// Longer quote first; ties keep the check's order.
        static func placedFirst(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.needle.count != rhs.needle.count { return lhs.needle.count > rhs.needle.count }
            return lhs.order < rhs.order
        }
    }

    // MARK: - The fold

    /// One folded unit per original character (whitespace runs collapse to
    /// one): curly quotes and apostrophes straightened, whitespace a single
    /// space, lowercased.
    ///
    /// **Wider than the ingest on purpose** (controller ruling, 2026-11-18).
    /// The ingest stores the quote trimmed and nothing more; a check routinely
    /// quotes the writer's sentence with straightened quotes or reflowed
    /// spaces, and an exact rule would drop those real marks. The fold is safe
    /// because it can only ever land on the WRITER's own text, and a quote it
    /// still cannot find is skipped and counted (`Placement.skipped`), never
    /// guessed at.
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

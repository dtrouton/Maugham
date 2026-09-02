import Foundation

/// **One pipeline round, as the record the author reads** (translation
/// pipeline spec §7). Derived: `.maugham/translations/rounds/<lang>.json`, a
/// ring of ten per language (`TranslationRoundStore`); losing it costs a
/// report, never words.
///
/// Everything a leg produced that the AUTHOR needs to see lands here — reader
/// reports, every note and departure with what the translator did about it,
/// the summary and glossary proposals — and the queue holds only what needs
/// the author's answer (spec §6). A `Codable` value with no store behind it:
/// `TranslationPipeline` builds one, `TranslationRoundStore` writes it, Plan
/// 4's report surface draws it.
struct TranslationRound: Codable, Equatable, Sendable {

    /// The seven legs, numbered as the spec's table numbers them.
    enum Leg: Int, Codable, CaseIterable, Sendable {
        case translate = 1, read, fix, reread, fixAgain, collate, finalFix

        /// The noun the record and the report use.
        var name: String {
            switch self {
            case .translate: return "translate"
            case .read: return "read"
            case .fix, .fixAgain, .finalFix: return "fix"
            case .reread: return "re-read"
            case .collate: return "collate"
            }
        }

        /// The present participle the desk's status slot draws (spec §8) —
        /// exposed here so Plan 4 only draws it.
        var verb: String {
            switch self {
            case .translate: return "translating"
            case .read: return "reading"
            case .fix, .fixAgain, .finalFix: return "fixing"
            case .reread: return "re-reading"
            case .collate: return "collating"
            }
        }

        var isFix: Bool { self == .fix || self == .fixAgain || self == .finalFix }
    }

    enum LegStatus: String, Codable, Sendable { case ran, skipped, failed, cancelled }

    /// What a leg that ran produced. Every field defaults to zero so a leg
    /// records only the counts it has.
    struct LegCounts: Codable, Equatable, Sendable {
        var entries = 0
        var queries = 0
        var notes = 0
        var departures = 0
        var addressed = 0
        var declined = 0

        init(entries: Int = 0, queries: Int = 0, notes: Int = 0,
             departures: Int = 0, addressed: Int = 0, declined: Int = 0) {
            self.entries = entries; self.queries = queries; self.notes = notes
            self.departures = departures; self.addressed = addressed; self.declined = declined
        }
    }

    /// `ran(counts) | skipped(reason) | failed(sentence) | cancelled`, flattened
    /// so the record stays plain JSON: `reason` carries a skip's reason or a
    /// failure's sentence.
    struct LegRecord: Codable, Equatable, Sendable {
        let leg: Leg
        let status: LegStatus
        var counts: LegCounts?
        var reason: String?

        init(leg: Leg, status: LegStatus, counts: LegCounts? = nil, reason: String? = nil) {
            self.leg = leg; self.status = status; self.counts = counts; self.reason = reason
        }
    }

    /// A reader's `overall`: `ReaderReport.Verdict.rawValue` and the paragraph
    /// written to the author.
    struct ReaderReportRecord: Codable, Equatable, Sendable {
        let verdict: String
        let text: String
    }

    /// The paragraph's translation before and after a fix leg — the sidecar is
    /// append-only, so the two record ids name the two entries and the texts
    /// travel beside them so the report needs no second read.
    struct Rewrite: Codable, Equatable, Sendable {
        let beforeRecordId: String?
        let before: String?
        let afterRecordId: String?
        let after: String?
    }

    enum NoteOutcome: Codable, Equatable, Sendable {
        case addressed(Rewrite)
        case declined(reason: String, annotationId: String?)
    }

    /// A reader's note (leg 2 or 4). `id` is minted by the pipeline BEFORE the
    /// fix leg is briefed and is what `addressed`/`declined` name. `outcome`
    /// nil = the fix leg never reached it (skipped, failed, cancelled, or the
    /// paragraph lost its translation in between).
    struct NoteRecord: Codable, Equatable, Sendable {
        let id: String
        let leg: Leg
        let author: String
        let paragraphId: String
        let kind: String
        let severity: String?
        let text: String
        var outcome: NoteOutcome?
    }

    enum DepartureOutcome: Codable, Equatable, Sendable {
        case addressed(Rewrite)
        case declined(reason: String, annotationId: String?)
        /// **No longer written** (P4 Task 4's fix round). This case existed for
        /// the author's own "Fine", and writing it here erased the pipeline's
        /// own fact: an addressed departure that lost its `Rewrite` to a click,
        /// a declined one that lost the translator's reason. The author's
        /// disposition is a separate fact and lives in `DepartureRecord.dismissed`;
        /// the case is kept so a record written before that fix still decodes,
        /// and `TranslationRoundReport.departureRows` still reads it as
        /// dismissed.
        case dismissed
    }

    /// A collator's departure (leg 6). Only `drifted` ones are briefed to leg
    /// 7, but every one is recorded. `id` as for a note.
    struct DepartureRecord: Codable, Equatable, Sendable {
        let id: String
        let paragraphId: String
        let verdict: String
        let kind: String
        let note: String
        let gloss: String
        var outcome: DepartureOutcome?
        /// **The author's own "Fine", beside the pipeline's fact and never over
        /// it** (P4 Task 4's fix round). `outcome` is what the TRANSLATOR did —
        /// the rewrite, or the reason they declined — and the report offers Fine
        /// on every row, so a disposition stored in `outcome` erased the
        /// before/after or the decline reason on the first click, permanently
        /// and with nothing red.
        ///
        /// Declared AFTER `outcome` so the memberwise init keeps its argument
        /// order and existing callers compile, and optional so a record written
        /// before this fix decodes (as `nil` — its dismissal, if it had one, is
        /// in `outcome` and `departureRows` still reads it there).
        var dismissed: Bool? = nil
    }

    struct GlossaryProposalRecord: Codable, Equatable, Sendable {
        let term: String
        let rendering: String
        let reason: String
        var adopted: Bool
        /// The author's own "Skip" on the round report (Plan 4) — declared
        /// AFTER `adopted` so the memberwise init keeps its argument order and
        /// existing callers compile. `nil` on a record an older build wrote
        /// (no such verb existed yet) and on one nobody has answered.
        var skipped: Bool? = nil
    }

    /// A note or departure the translator declined — the report's
    /// Disagreements section (spec §8 item 3).
    enum Disagreement: Equatable {
        case note(NoteRecord, reason: String, annotationId: String?)
        case departure(DepartureRecord, reason: String, annotationId: String?)

        /// The underlying record's own id — what a resolution (Answer,
        /// dismiss) is filed against.
        var recordId: String {
            switch self {
            case .note(let record, _, _): return record.id
            case .departure(let record, _, _): return record.id
            }
        }

        var paragraphId: String {
            switch self {
            case .note(let record, _, _): return record.paragraphId
            case .departure(let record, _, _): return record.paragraphId
            }
        }

        var annotationId: String? {
            switch self {
            case .note(_, _, let annotationId): return annotationId
            case .departure(_, _, let annotationId): return annotationId
            }
        }

        var reason: String {
            switch self {
            case .note(_, let reason, _): return reason
            case .departure(_, let reason, _): return reason
            }
        }

        /// The note's own author for a reader's note; nil for a departure (the
        /// caller names the collator — a departure record carries no author of
        /// its own).
        var author: String? {
            if case .note(let record, _, _) = self { return record.author }
            return nil
        }

        var text: String {
            switch self {
            case .note(let record, _, _): return record.text
            case .departure(let record, _, _): return record.note
            }
        }
    }

    let number: Int
    let language: String
    let docId: String
    let startedAt: Date
    var endedAt: Date?
    var legs: [LegRecord] = []
    var leg2: ReaderReportRecord?
    var leg4: ReaderReportRecord?
    var collatorOverall: String?
    var notes: [NoteRecord] = []
    var departures: [DepartureRecord] = []
    var summary: String?
    var glossaryProposals: [GlossaryProposalRecord] = []

    init(number: Int, language: String, docId: String, startedAt: Date) {
        self.number = number; self.language = language; self.docId = docId
        self.startedAt = startedAt
    }

    /// The leg a failed or cancelled round stopped at, or nil for one that ran
    /// to the end.
    var stoppedAt: Leg? {
        legs.first { $0.status == .failed || $0.status == .cancelled }?.leg
    }

    var wasCancelled: Bool { legs.contains { $0.status == .cancelled } }
    var failed: Bool { legs.contains { $0.status == .failed } }

    /// Notes per round — the desk's trend figure (spec §7).
    var noteCount: Int { notes.count }

    var declinedCount: Int {
        notes.filter { if case .declined = $0.outcome { return true } else { return false } }.count
            + departures.filter { if case .declined = $0.outcome { return true } else { return false } }.count
    }

    /// Every declined note and departure, notes then departures. What the
    /// report's Disagreements section walks (spec §8 item 3).
    var disagreements: [Disagreement] {
        notes.compactMap { note in
            if case .declined(let reason, let annotationId) = note.outcome {
                return .note(note, reason: reason, annotationId: annotationId)
            }
            return nil
        } + departures.compactMap { departure in
            if case .declined(let reason, let annotationId) = departure.outcome {
                return .departure(departure, reason: reason, annotationId: annotationId)
            }
            return nil
        }
    }
}

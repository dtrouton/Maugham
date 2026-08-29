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
        /// The author's own "Fine" on the round report (Plan 4).
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
    }

    struct GlossaryProposalRecord: Codable, Equatable, Sendable {
        let term: String
        let rendering: String
        let reason: String
        var adopted: Bool
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
}

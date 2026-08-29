import XCTest
@testable import Maugham

/// The round record (spec §7): derived, a ring of ten per language, numbered
/// per language across documents. Losing it costs a report, never words.
@MainActor
final class TranslationRoundStoreTests: XCTestCase {

    private func makeStore() throws -> TranslationRoundStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoundStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return TranslationRoundStore(projectURL: root)
    }

    private func round(number: Int, language: String = "es", docId: String = "doc-1",
                       notes: Int = 0) -> TranslationRound {
        var round = TranslationRound(number: number, language: language, docId: docId,
                                     startedAt: Date(timeIntervalSince1970: 1_000))
        round.endedAt = Date(timeIntervalSince1970: 2_000)
        round.notes = (0..<notes).map { index in
            TranslationRound.NoteRecord(
                id: "n\(index)", leg: .read, author: "Ocampo", paragraphId: "a1b2",
                kind: "rhythm", severity: "minor", text: "Limps.",
                outcome: .addressed(.init(beforeRecordId: "r1", before: "old",
                                          afterRecordId: "r2", after: "new")))
        }
        return round
    }

    func test_aFullRecordRoundTripsThroughTheStore() throws {
        let store = try makeStore()
        var round = round(number: 1, notes: 1)
        round.legs = [
            .init(leg: .translate, status: .ran, counts: .init(entries: 2, queries: 1)),
            .init(leg: .read, status: .ran, counts: .init(notes: 1)),
            .init(leg: .fix, status: .skipped, reason: "the reader found nothing to fix"),
            .init(leg: .reread, status: .failed, reason: "The translation round died."),
        ]
        round.leg2 = .init(verdict: "mixed", text: "Reads well.")
        round.collatorOverall = "Holds."
        round.departures = [
            .init(id: "d1", paragraphId: "c3d4", verdict: "drifted", kind: "omission",
                  note: "Lost a clause.", gloss: "The fog came.",
                  outcome: .declined(reason: "Deliberate.", annotationId: "ann-1")),
            .init(id: "d2", paragraphId: "a1b2", verdict: "holds", kind: "rendering",
                  note: "Split.", gloss: "She shut it.", outcome: .dismissed),
            .init(id: "d3", paragraphId: "a1b2", verdict: "holds", kind: "rendering",
                  note: "Pun.", gloss: "…", outcome: nil),
        ]
        round.summary = "Done."
        round.glossaryProposals = [.init(term: "October", rendering: "Octubre",
                                         reason: "the month", adopted: false)]
        try store.append(round)

        XCTAssertEqual(store.rounds(language: "es"), [round])
        XCTAssertEqual(store.latest(language: "es", docId: "doc-1"), round)
        XCTAssertEqual(round.stoppedAt, .reread, "a failed leg is where the round stopped")
    }

    func test_theRingKeepsTheNewestTenAndNumberingRunsPastIt() throws {
        let store = try makeStore()
        for number in 1...12 {
            XCTAssertEqual(store.nextNumber(language: "es"), number)
            try store.append(round(number: number))
        }
        let kept = store.rounds(language: "es")
        XCTAssertEqual(kept.count, TranslationRoundStore.ringSize)
        XCTAssertEqual(kept.map(\.number), Array((3...12).reversed()), "newest first")
        XCTAssertEqual(store.nextNumber(language: "es"), 13,
                       "the number outlives the ring — round 3 must not be minted twice")
    }

    func test_numberingIsPerLanguageAcrossDocuments() throws {
        let store = try makeStore()
        try store.append(round(number: 1, language: "es", docId: "doc-1"))
        try store.append(round(number: 2, language: "es", docId: "doc-2"))
        XCTAssertEqual(store.nextNumber(language: "es"), 3)
        XCTAssertEqual(store.nextNumber(language: "fr"), 1)
        XCTAssertEqual(store.latest(language: "es", docId: "doc-1")?.number, 1,
                       "the newest round for THIS pair, not for the language")
        XCTAssertEqual(store.latest(language: "es", docId: nil)?.number, 2)
        XCTAssertNil(store.latest(language: "es", docId: "doc-9"))
    }

    func test_theTrendReadsNotesPerRoundForTheLastFive() throws {
        let store = try makeStore()
        for (number, notes) in [(1, 9), (2, 5), (3, 4), (4, 4), (5, 2), (6, 1)] {
            try store.append(round(number: number, notes: notes))
        }
        XCTAssertEqual(store.trend(language: "es"), [5, 4, 4, 2, 1], "oldest first")
        XCTAssertEqual(store.trend(language: "fr"), [])
    }

    func test_anUndecodableLedgerReadsAsEmptyRatherThanThrowing() throws {
        let store = try makeStore()
        let url = TranslationRoundStore.fileURL(language: "es", in: store.projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(store.rounds(language: "es"), [])
        XCTAssertEqual(store.nextNumber(language: "es"), 1)
        try store.append(round(number: 1))
        XCTAssertEqual(store.rounds(language: "es").count, 1, "the store recovers by rewriting")
    }

    func test_aCancelledRoundRecordsWhereItStoppedAndNoSummary() {
        var round = round(number: 1)
        round.legs = [.init(leg: .translate, status: .ran, counts: .init(entries: 1)),
                      .init(leg: .read, status: .cancelled)]
        XCTAssertEqual(round.stoppedAt, .read)
        XCTAssertTrue(round.wasCancelled)
        XCTAssertNil(round.summary)
    }

    func test_everyLegHasANameAndAVerb() {
        XCTAssertEqual(TranslationRound.Leg.allCases.count, 7)
        XCTAssertEqual(TranslationRound.Leg.allCases.map(\.rawValue), Array(1...7))
        for leg in TranslationRound.Leg.allCases {
            XCTAssertFalse(leg.name.isEmpty)
            XCTAssertFalse(leg.verb.isEmpty)
        }
        XCTAssertEqual(TranslationRound.Leg.reread.name, "re-read")
        XCTAssertEqual(TranslationRound.Leg.collate.verb, "collating")
    }

    func test_theLanguageFileIsLowercased() throws {
        let store = try makeStore()
        XCTAssertEqual(TranslationRoundStore.fileURL(language: "ES", in: store.projectURL)
                           .lastPathComponent, "es.json")
        XCTAssertEqual(TranslationRoundStore.directoryURL(in: store.projectURL).path
                           .hasSuffix(".maugham/translations/rounds"), true)
    }
}

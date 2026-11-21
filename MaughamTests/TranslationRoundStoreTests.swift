import XCTest
@testable import Maugham

/// The round record (spec §7): derived, a ring of ten per language, numbered
/// per language across documents. Losing it costs a report, never words.
@MainActor
final class TranslationRoundStoreTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() {
        super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    private func makeStore() throws -> TranslationRoundStore {
        let root = TestTemp.root
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

    func test_updateRewritesOneRoundInPlaceAndKeepsTheOthers() throws {
        let store = TranslationRoundStore(projectURL: temp.url)
        var first = TranslationRound(number: 1, language: "es", docId: "d", startedAt: Date())
        var second = TranslationRound(number: 2, language: "es", docId: "d", startedAt: Date())
        second.departures = [.init(id: "dep", paragraphId: "a1b2", verdict: "holds",
                                   kind: "rendering", note: "n", gloss: "g")]
        try store.append(first)
        try store.append(second)

        second.departures[0].outcome = .dismissed
        try store.update(second)

        let rounds = store.rounds(language: "es")
        XCTAssertEqual(rounds.map(\.number), [2, 1])
        XCTAssertEqual(rounds[0].departures[0].outcome, .dismissed)
        XCTAssertEqual(store.nextNumber(language: "es"), 3, "update never mints")
        first.summary = "x"
        XCTAssertNoThrow(try store.update(first))
    }

    func test_updatingARoundThatAgedOutOfTheRingIsRefusedInWords() throws {
        let store = TranslationRoundStore(projectURL: temp.url)
        let gone = TranslationRound(number: 99, language: "es", docId: "d", startedAt: Date())
        XCTAssertThrowsError(try store.update(gone)) { error in
            guard case TranslationRoundStore.UpdateError.roundGone(let number) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(number, 99)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func test_aSkippedProposalRoundTripsAndAnOldRecordWithoutTheFieldStillDecodes() throws {
        var round = TranslationRound(number: 1, language: "es", docId: "d", startedAt: Date())
        round.glossaryProposals = [.init(term: "fog", rendering: "niebla", reason: "r", adopted: false)]
        round.glossaryProposals[0].skipped = true
        let data = try JSONEncoder().encode(round)
        let back = try JSONDecoder().decode(TranslationRound.self, from: data)
        XCTAssertEqual(back.glossaryProposals[0].skipped, true)
        let old = #"{"term":"fog","rendering":"niebla","reason":"r","adopted":false}"#.data(using: .utf8)!
        let record = try JSONDecoder().decode(TranslationRound.GlossaryProposalRecord.self, from: old)
        XCTAssertNil(record.skipped)
    }

    /// **The author's disposition is its own field, and it arrived after the
    /// record shipped** (P4 Task 4's fix round) — so a departure written
    /// before it decodes with `dismissed` nil, and a dismissal round-trips
    /// beside the translator's `outcome` rather than over it.
    func test_aDismissedDepartureRoundTripsAndAnOldRecordWithoutTheFieldStillDecodes() throws {
        var round = TranslationRound(number: 1, language: "es", docId: "d", startedAt: Date())
        round.departures = [
            .init(id: "d1", paragraphId: "a1b2", verdict: "drifted", kind: "omission",
                  note: "Lost a clause.", gloss: "The fog came.",
                  outcome: .addressed(.init(beforeRecordId: "b", before: "x",
                                            afterRecordId: "a", after: "y")))]
        round.departures[0].dismissed = true
        let data = try JSONEncoder().encode(round)
        let back = try JSONDecoder().decode(TranslationRound.self, from: data)
        XCTAssertEqual(back.departures[0].dismissed, true)
        XCTAssertEqual(back.departures[0].outcome,
                       .addressed(.init(beforeRecordId: "b", before: "x",
                                        afterRecordId: "a", after: "y")),
                       "the dismissal displaced the translator's own fact")

        let old = #"{"id":"d1","paragraphId":"a1b2","verdict":"holds","kind":"rendering","note":"Split.","gloss":"g"}"#
            .data(using: .utf8)!
        let record = try JSONDecoder().decode(TranslationRound.DepartureRecord.self, from: old)
        XCTAssertNil(record.dismissed)
        XCTAssertNil(record.outcome)
    }

    func test_disagreementsAreTheDeclinedNotesAndDepartures() {
        var round = TranslationRound(number: 1, language: "es", docId: "d", startedAt: Date())
        round.notes = [
            .init(id: "n1", leg: .read, author: "Ocampo", paragraphId: "a1b2", kind: "rhythm",
                  severity: "minor", text: "limps", outcome: .declined(reason: "meter", annotationId: "ann-1")),
            .init(id: "n2", leg: .read, author: "Ocampo", paragraphId: "a1b2", kind: "rhythm",
                  severity: "minor", text: "fine", outcome: .addressed(.init(
                    beforeRecordId: nil, before: nil, afterRecordId: nil, after: nil)))
        ]
        round.departures = [
            .init(id: "d1", paragraphId: "c3d4", verdict: "drifted", kind: "omission", note: "lost",
                  gloss: "g", outcome: .declined(reason: "no", annotationId: nil))
        ]
        let ids = round.disagreements.map(\.recordId)
        XCTAssertEqual(ids, ["n1", "d1"])
        XCTAssertEqual(round.disagreements[0].annotationId, "ann-1")
        XCTAssertNil(round.disagreements[1].annotationId)
        XCTAssertEqual(round.disagreements[0].author, "Ocampo")
    }

    // MARK: - Every piece keeps its latest round (shell plan 4 Task 2)

    /// Twelve chapters in one whole-book run, a ring of ten: the ring drops
    /// two chapters' rounds, and every chapter still answers.
    func test_aWholeBookRunKeepsEveryChaptersLatestRound() throws {
        let store = try makeStore()
        for number in 1...12 {
            try store.append(round(number: number, docId: "ch-\(number)", notes: number))
        }
        XCTAssertFalse(store.rounds(language: "es").contains { $0.docId == "ch-1" },
                       "premise: the ring has aged chapter one out")
        for number in 1...12 {
            XCTAssertEqual(store.latestFinished(language: "es", docId: "ch-\(number)")?.number,
                           number, "chapter \(number)'s letter was lost")
        }
        XCTAssertEqual(store.latestFinishedByPiece(language: "es").count, 12)
        XCTAssertEqual(store.latestFinishedByPiece(language: "es")["ch-1"]?.noteCount, 1)
        XCTAssertNil(store.latestFinished(language: "fr", docId: "ch-1"))
    }

    func test_aCancelledRoundIsNotTheLatestFinished() throws {
        let store = try makeStore()
        try store.append(round(number: 1, docId: "ch-1", notes: 2))
        var cancelled = round(number: 2, docId: "ch-1")
        cancelled.legs = [.init(leg: .read, status: .cancelled)]
        try store.append(cancelled)
        var unended = round(number: 3, docId: "ch-1")
        unended.endedAt = nil
        try store.append(unended)
        var failed = round(number: 4, docId: "ch-2")
        failed.legs = [.init(leg: .read, status: .failed, reason: "died")]
        try store.append(failed)

        XCTAssertEqual(store.latestFinished(language: "es", docId: "ch-1")?.number, 1,
                       "a cancelled or unended round is in the ring only")
        XCTAssertEqual(store.latest(language: "es", docId: "ch-1")?.number, 3,
                       "the ring still holds them")
        XCTAssertEqual(store.latestFinished(language: "es", docId: "ch-2")?.number, 4,
                       "a failed round ran to an end and says where it stopped")
        XCTAssertEqual(store.latestFinishedByPiece(language: "es").mapValues(\.number),
                       ["ch-1": 1, "ch-2": 4])
    }

    /// A verb on an old chapter's report must not say `roundGone` while that
    /// round is still the chapter's latest.
    func test_updateFindsARoundThatAgedOutOfTheRing() throws {
        let store = try makeStore()
        var old = round(number: 1, docId: "ch-1")
        old.departures = [.init(id: "dep", paragraphId: "a1b2", verdict: "holds",
                                kind: "rendering", note: "n", gloss: "g")]
        try store.append(old)
        for number in 2...(TranslationRoundStore.ringSize + 1) {
            try store.append(round(number: number, docId: "ch-\(number)"))
        }
        XCTAssertFalse(store.rounds(language: "es").contains { $0.number == 1 }, "premise")

        old.departures[0].outcome = .dismissed
        XCTAssertNoThrow(try store.update(old))
        XCTAssertEqual(store.latestFinished(language: "es", docId: "ch-1")?
                           .departures.first?.outcome, .dismissed)
        XCTAssertFalse(store.rounds(language: "es").contains { $0.number == 1 },
                       "the update did not put the round back into the ring")

        // A round in BOTH places is rewritten in both.
        var newest = try XCTUnwrap(store.latestFinished(language: "es", docId: "ch-11"))
        newest.summary = "edited"
        try store.update(newest)
        XCTAssertEqual(store.latest(language: "es", docId: "ch-11")?.summary, "edited")
        XCTAssertEqual(store.latestFinished(language: "es", docId: "ch-11")?.summary, "edited")
    }

    /// A ledger written before the map existed decodes with an empty map
    /// (tripwire 11), and its finished rounds still answer from the ring.
    func test_anOldLedgerReadsWithNoLatestRounds() throws {
        let store = try makeStore()
        let legacy = TranslationRoundStore.Ledger(
            nextNumber: 3, rounds: [round(number: 1, docId: "ch-1"), round(number: 2, docId: "ch-2")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "latestByPiece")
        let url = TranslationRoundStore.fileURL(language: "es", in: store.projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // adr-0018-ok: the round ledger is derived state, not manuscript text
        let back = try decoder.decode(TranslationRoundStore.Ledger.self, from: Data(contentsOf: url))
        XCTAssertEqual(back.latestByPiece, [:])
        XCTAssertEqual(back.rounds.count, 2)
        XCTAssertEqual(store.nextNumber(language: "es"), 3, "the old ledger was read, not replaced")
        XCTAssertEqual(store.latestFinished(language: "es", docId: "ch-1")?.number, 1)
        XCTAssertEqual(store.latestFinishedByPiece(language: "es").mapValues(\.number),
                       ["ch-1": 1, "ch-2": 2])
    }

    func test_trendIsThePiecesOwn() throws {
        let store = try makeStore()
        for (number, docId, notes) in [(1, "ch-1", 9), (2, "ch-2", 5), (3, "ch-1", 4),
                                       (4, "ch-2", 3), (5, "ch-1", 1)] {
            try store.append(round(number: number, docId: docId, notes: notes))
        }
        XCTAssertEqual(store.trend(language: "es", docId: "ch-1"), [9, 4, 1], "oldest first")
        XCTAssertEqual(store.trend(language: "es", docId: "ch-2"), [5, 3])
        XCTAssertEqual(store.trend(language: "es", docId: "ch-9"), [])
    }

    /// Two Macs can mint one number in one language for different chapters
    /// (each read `nextNumber` before the other's file arrived). `update` on
    /// one chapter's round must not overwrite the other chapter's (review M5).
    func test_updateMatchesTheRingByNumberAndPiece() throws {
        let store = try makeStore()
        try store.append(round(number: 7, docId: "ch-a"))
        try store.append(round(number: 7, docId: "ch-b"))
        var mine = try XCTUnwrap(store.latestFinished(language: "es", docId: "ch-b"))
        mine.summary = "b's"
        try store.update(mine)

        let ring = store.rounds(language: "es")
        XCTAssertEqual(ring.first { $0.docId == "ch-a" }?.summary, nil,
                       "chapter a's round was overwritten by chapter b's")
        XCTAssertEqual(ring.first { $0.docId == "ch-b" }?.summary, "b's")
        XCTAssertEqual(ring.map(\.docId).sorted(), ["ch-a", "ch-b"])
    }
}

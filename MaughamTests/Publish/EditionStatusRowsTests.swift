import XCTest
import MaughamCore
@testable import Maugham

/// **An edition's Status, as values** (shell p4 Task 5): the rows, what each
/// cell says, and what a click opens — pure, no window and no disk.
@MainActor
final class EditionStatusRowsTests: XCTestCase {

    private static let one = StructureItem(id: "c1", title: "One", type: .document, path: "one.md")
    private static let two = StructureItem(id: "c2", title: "Two", type: .document, path: "two.md")
    private static let three = StructureItem(id: "c3", title: "Three", type: .document, path: "three.md")
    private static let part = StructureItem(id: "p1", title: "Part One", type: .group,
                                            children: [one, two])
    private static let structure = [part, three]

    private static func translation(_ doc: String, fresh: Int, stale: Int = 0, missing: Int = 0,
                                    questions: Int = 0) -> EditionStatus.DocumentRow {
        EditionStatus.DocumentRow(documentId: doc, language: "es", translator: "Ana",
                                  fresh: fresh, stale: stale, missing: missing,
                                  verbatim: 0, orphans: 0, openQueries: questions)
    }

    private static func departure(_ id: String, outcome: TranslationRound.DepartureOutcome? = nil,
                                  dismissed: Bool? = nil) -> TranslationRound.DepartureRecord {
        TranslationRound.DepartureRecord(id: id, paragraphId: "aaaa", verdict: "drifted", kind: "sense",
                                         note: "n", gloss: "g", outcome: outcome, dismissed: dismissed)
    }

    private static func round(_ number: Int, doc: String) -> TranslationRound {
        var round = TranslationRound(number: number, language: "es", docId: doc,
                                     startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        round.endedAt = round.startedAt.addingTimeInterval(60)
        round.departures = [
            departure("d1"),                                               // to look at
            departure("d2", dismissed: true),                              // the writer said Fine
            departure("d3", outcome: .declined(reason: "no", annotationId: nil)), // the translator answered
            departure("d4"),                                               // to look at
        ]
        return round
    }

    func test_theStatusRowsCarryTranslationRoundChangesAndTrend() {
        let rows = EditionStatusRows.rows(
            structure: Self.structure,
            report: [Self.translation("c1", fresh: 10, stale: 2, questions: 3),
                     Self.translation("c3", fresh: 0, missing: 7)],
            rounds: ["c1": Self.round(4, doc: "c1"),
                     // A round for a piece the manifest no longer holds.
                     "gone": Self.round(2, doc: "gone")],
            trends: ["c1": [5, 3, 1], "gone": [9]])

        // Pieces only, in the book's order; the Part is a heading, not a row.
        XCTAssertEqual(rows.map(\.id), ["c1", "c2", "c3"])
        let first = rows[0]
        XCTAssertEqual(first.translation?.stale, 2)
        XCTAssertEqual(first.latestRound?.number, 4)
        XCTAssertEqual(first.changesToLookAt, 2, "unsettled departures only")
        XCTAssertEqual(first.trend, [5, 3, 1])
        XCTAssertNil(rows[1].translation)
        XCTAssertNil(rows[1].latestRound)
        XCTAssertEqual(rows[1].changesToLookAt, 0)

        // What the cells say.
        XCTAssertEqual(EditionStatusRows.translation(first, unreadable: false).text, "2 stale")
        XCTAssertEqual(EditionStatusRows.translation(rows[2], unreadable: false).text, "7 missing")
        XCTAssertEqual(EditionStatusRows.translation(rows[1], unreadable: false), .empty)
        XCTAssertTrue(EditionStatusRows.round(first).text.hasPrefix("#4"))
        XCTAssertTrue(EditionStatusRows.round(first).help.contains("finished"))
        XCTAssertEqual(EditionStatusRows.questions(first).text, "3")
        XCTAssertEqual(EditionStatusRows.changes(first).text, "2")
        XCTAssertEqual(EditionStatusRows.trend(first).text, "5\u{2192}3\u{2192}1")
        XCTAssertEqual(EditionStatusRows.questions(rows[1]), .empty)
    }

    func test_aFailedRoundSaysWhereItStopped() {
        var round = Self.round(5, doc: "c1")
        round.legs = [.init(leg: .translate, status: .ran), .init(leg: .read, status: .failed)]
        let row = EditionStatusRows.Row(piece: Self.one, translation: nil, latestRound: round,
                                        changesToLookAt: 0, trend: [])
        XCTAssertTrue(EditionStatusRows.round(row).help.contains("failed while reading"),
                      EditionStatusRows.round(row).help)
    }

    func test_anUnreadableChapterIsNamedNotEmpty() {
        let unreadable = [EditionStatus.UnreadableDocument(documentId: "c2", title: "Two",
                                                           reason: "its history could not be read")]
        let notices = EditionStatusRows.notices(unreadable)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].headline.contains("Two"), notices[0].headline)
        XCTAssertEqual(notices[0].detail, "its history could not be read")
        // Its row says it could not be read — never an empty cell that reads
        // as "nothing translated".
        let row = EditionStatusRows.Row(piece: Self.two, translation: nil, latestRound: nil,
                                        changesToLookAt: 0, trend: [])
        XCTAssertEqual(EditionStatusRows.translation(row, unreadable: true).text, "\u{2014}")
    }

    /// Denver's answer 3: a chapter opens read in the edition's language.
    func test_aRowOpensTheChapterInTheEditionsLanguage() {
        XCTAssertEqual(EditionStatusRows.opening(pieceId: "c1", language: "es", isSource: false,
                                                 firstParagraph: "aaaa"),
                       .reveal(TranslationReveal(docId: "c1", language: "es", paragraphId: "aaaa")))
        XCTAssertEqual(EditionStatusRows.opening(pieceId: "c1", language: "en", isSource: true,
                                                 firstParagraph: "aaaa"),
                       .piece("c1"), "the Source edition opens the piece")
        XCTAssertEqual(EditionStatusRows.opening(pieceId: "c1", language: "es", isSource: false,
                                                 firstParagraph: nil),
                       .piece("c1"), "an empty piece opens the piece")
        XCTAssertEqual(EditionStatusRows.opening(pieceId: "c1", language: "es", isSource: false,
                                                 hasTranslation: false, firstParagraph: "aaaa"),
                       .piece("c1"), "nothing translated yet opens the source")
        let started = EditionStatusRows.Row(piece: Self.one, translation: Self.translation("c1", fresh: 0, stale: 2),
                                            latestRound: nil, changesToLookAt: 0, trend: [])
        let empty = EditionStatusRows.Row(piece: Self.one, translation: Self.translation("c1", fresh: 0, missing: 4),
                                          latestRound: nil, changesToLookAt: 0, trend: [])
        XCTAssertTrue(EditionStatusRows.hasTranslation(started))
        XCTAssertFalse(EditionStatusRows.hasTranslation(empty))
        XCTAssertFalse(EditionStatusRows.hasTranslation(nil))
    }

    func test_thePublishingCellSaysTheContentsAndTheStart() {
        XCTAssertEqual(EditionStatusRows.publishing(nil).text, "TOC")
        var section = PublishConfig.Section()
        section.includeInToc = false
        section.startOn = .recto
        let cell = EditionStatusRows.publishing(section)
        XCTAssertEqual(cell.text, "No TOC \u{00B7} R")
        XCTAssertEqual(cell.long, "Not in contents \u{00B7} right page")
        XCTAssertEqual(cell.help, "Not in contents, starts on a right page")
    }

    /// **Long wording wherever the width holds it; terse only near the floor**
    /// (fix round 1, the writer's seat).
    func test_theColumnsWordThemselvesLongWhenTheWidthAllows() {
        XCTAssertFalse(EditionStatusView.columns(width: ProjectWindow.centreColumnFloor, isSource: false).wide)
        XCTAssertTrue(EditionStatusView.columns(width: 900, isSource: false).wide)
        XCTAssertTrue(EditionStatusView.columns(width: ProjectWindow.centreColumnFloor, isSource: true).wide,
                      "the Source's one column words itself at the floor")
        let wide = EditionStatusView.columns(width: 900, isSource: false)
        XCTAssertLessThanOrEqual(wide.fixedWidth(isSource: false) + EditionStatusView.minimumTitleColumnWidth, 900)
        XCTAssertLessThanOrEqual(EditionStatusView.intrinsicWidth(isSource: false), ProjectWindow.centreColumnFloor)

        let row = EditionStatusRows.Row(piece: Self.one,
                                        translation: Self.translation("c1", fresh: 4, stale: 5, missing: 3, questions: 2),
                                        latestRound: Self.round(4, doc: "c1"), changesToLookAt: 3, trend: [5, 3, 1])
        XCTAssertEqual(EditionStatusRows.translation(row, unreadable: false).wording(wide: false), "3 missing")
        XCTAssertEqual(EditionStatusRows.translation(row, unreadable: false).wording(wide: true),
                       "3 missing \u{00B7} 5 stale")
        XCTAssertEqual(EditionStatusRows.questions(row).wording(wide: true), "2 questions")
        XCTAssertEqual(EditionStatusRows.questions(row).wording(wide: false), "2")
        XCTAssertEqual(EditionStatusRows.changes(row).wording(wide: true), "3 to look at")
        XCTAssertTrue(EditionStatusRows.round(row).wording(wide: true).hasPrefix("Round 4"))
        XCTAssertEqual(EditionStatusRows.publishing(nil).wording(wide: true), "In contents")
    }

    /// **VoiceOver hears the whole row** (fix round 1, I5): the title, then
    /// each cell that says something, in its own sentence.
    func test_aRowsLabelIsItsCellsSentences() {
        let row = EditionStatusRows.Row(piece: Self.one,
                                        translation: Self.translation("c1", fresh: 10, stale: 2, questions: 3),
                                        latestRound: Self.round(4, doc: "c1"), changesToLookAt: 2, trend: [5, 3])
        let label = EditionStatusRows.accessibilityLabel(row, unreadable: false, isSource: false)
        XCTAssertTrue(label.hasPrefix("One, 10 fresh"), label)
        for part in ["2 stale", "Round 4", "finished", "3 open questions",
                     "2 changes from the last round to look at", "Notes per round: 5, 3"] {
            XCTAssertTrue(label.contains(part), "\(part) missing from: \(label)")
        }
        XCTAssertEqual(EditionStatusRows.accessibilityLabel(row, unreadable: false, isSource: true), "One")
        XCTAssertTrue(EditionStatusRows.accessibilityLabel(row, unreadable: true, isSource: false)
            .contains("could not be read"))
    }

    /// The trend is read once per language, keyed by piece.
    func test_theTrendsAreReadOncePerLanguage() throws {
        let url = TestTemp.root.appendingPathComponent("trends-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TranslationRoundStore(projectURL: url)
        var a = Self.round(1, doc: "c1"); a.notes = []
        var b = Self.round(2, doc: "c2")
        b.notes = [.init(id: "n", leg: .read, author: "r", paragraphId: "aaaa", kind: "k",
                         severity: nil, text: "t")]
        try store.append(a)
        try store.append(b)
        XCTAssertEqual(store.trendsByPiece(language: "es"), ["c1": [0], "c2": [1]])
        XCTAssertEqual(store.trendsByPiece(language: "es")["c2"], store.trend(language: "es", docId: "c2"))
    }
}

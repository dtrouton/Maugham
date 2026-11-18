import XCTest
import MaughamCore
@testable import Maugham

/// Shell plan 3, Task 1 — `BriefDecisions`: Decided's order, fold, standing
/// rule and the Book's filter.
final class BriefDecisionsTests: XCTestCase {

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400) }

    private func ruling(_ id: String, on day: Int?) -> Ruling {
        Ruling(id: id, text: id, ruledOn: day.map(self.day), provenance: nil)
    }

    func test_decisionsAreNewestFirstAndUndatedLast() {
        let file = [ruling("hand-1", on: nil), ruling("old", on: 1), ruling("new", on: 9),
                    ruling("hand-2", on: nil), ruling("mid-a", on: 5), ruling("mid-b", on: 5)]
        XCTAssertEqual(BriefDecisions.newestFirst(file).map(\.id),
                       ["new", "mid-a", "mid-b", "old", "hand-1", "hand-2"],
                       "dated by day descending (ties in file order), then hand-typed in file order")
    }

    func test_threeShowAndTheRestFold() {
        XCTAssertEqual(BriefDecisions.showing, 3)
        let five = (1...5).map { ruling("r\($0)", on: 10 - $0) }
        let split = BriefDecisions.split(five)
        XCTAssertEqual(split.showing.map(\.id), ["r1", "r2", "r3"])
        XCTAssertEqual(split.folded.map(\.id), ["r4", "r5"])
        let two = BriefDecisions.split(Array(five.prefix(2)))
        XCTAssertEqual(two.showing.count, 2)
        XCTAssertTrue(two.folded.isEmpty)
    }

    func test_aRetiredLessonIsNotStanding() {
        let rows = [
            Ruling(id: "l1", text: "Cut the throat-clearing openings", ruledOn: day(1), provenance: nil),
            Ruling(id: "l2", text: "Choice: present tense throughout", ruledOn: day(2), provenance: nil),
            Ruling(id: "l3", text: "Over-explaining the joke (retired 2 Sep 2026)", ruledOn: day(3), provenance: nil),
        ]
        guard case .retired = LessonsLedger.kind(of: rows[2].text) else {
            return XCTFail("premise: the third row is retired by the ledger's own grammar")
        }
        XCTAssertEqual(BriefDecisions.standing(rows, kind: .lessons).map(\.id), ["l1", "l2"])
        // CONTROL: the same words in an intent are all standing.
        XCTAssertEqual(BriefDecisions.standing(rows, kind: .intent).map(\.id), ["l1", "l2", "l3"])
    }

    func test_theBookFilterListsOnlyOriginsThatHaveDecisions() {
        let structure = [
            StructureItem(id: "doc-a", title: "A", type: .document),
            StructureItem(id: "doc-b", title: "B", type: .document),
            StructureItem(id: "doc-c", title: "C", type: .document),
        ]
        let r = ruling("r", on: 1)
        let decisions = [
            BriefDecision(ruling: r, origin: .edition(language: "sr")),
            BriefDecision(ruling: r, origin: .piece(docId: "doc-c")),
            BriefDecision(ruling: r, origin: .lessons),
            BriefDecision(ruling: r, origin: .edition(language: "es")),
            BriefDecision(ruling: r, origin: .piece(docId: "doc-a")),
            BriefDecision(ruling: ruling("r2", on: 2), origin: .piece(docId: "doc-a")),
            BriefDecision(ruling: r, origin: .book),
        ]
        XCTAssertEqual(BriefDecisions.origins(of: decisions, structure: structure), [
            .book, .piece(docId: "doc-a"), .piece(docId: "doc-c"), .lessons,
            .edition(language: "es"), .edition(language: "sr"),
        ], "book, pieces in manuscript order, lessons, first reader, editions by tag — and no doc-b, no first reader")

        XCTAssertEqual(BriefDecisions.filtered(decisions, by: .piece(docId: "doc-a")).map(\.ruling.id), ["r", "r2"])
        XCTAssertEqual(BriefDecisions.filtered(decisions, by: nil), decisions, "no filter is every decision")
        XCTAssertEqual(Set(decisions.map(\.id)).count, decisions.count,
                       "an id is origin-qualified: one ruling id under several origins never collides")
    }
}

import XCTest
import MaughamCore
@testable import Maugham

/// The queue's order (M3 P2 Task 4). `AnnotationQueueOrder.sorted` is the pane's
/// final ordering pass — pure, so the whole truth table is assertable without
/// mounting `AnnotationsPane`.
///
/// It orders what the writer is about to WORK THROUGH, which is a different
/// question from the order the deriver returns (M5-AN-004, newest-first): that
/// claim is about the projection and is untouched here.
final class AnnotationQueueOrderTests: XCTestCase {

    // Tripwire 8: 4-char ids from `[0-9a-hjkmnp-tv-z]` — these cross the
    // `.md` ↔ op log boundary in production even though this test is pure.
    private let seq = ["aaaa", "bbbb", "cccc", "dddd"]

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(
        id: String,
        paragraph: String?,
        triage: TriageMark? = nil,
        offset: TimeInterval = 0
    ) -> Annotation {
        Annotation(
            id: id, kind: .comment, paragraphId: paragraph,
            body: "body", suggestedText: nil, priorText: nil,
            createdAt: t0.addingTimeInterval(offset), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil,
            isStale: false, triage: triage)
    }

    private func ids(_ annotations: [Annotation]) -> [String] {
        AnnotationQueueOrder.sorted(annotations, sequence: seq).map(\.id)
    }

    // MARK: - The `do` group comes first

    func test_theDoGroupLeadsTheQueueRegardlessOfPosition() {
        // The `do` note is LAST in the document; it still leads the queue.
        let doNote = note(id: "n1", paragraph: "dddd", triage: .do)
        let plain = note(id: "n2", paragraph: "aaaa")
        XCTAssertEqual(ids([plain, doNote]), ["n1", "n2"])
    }

    func test_declineDiscussAndUntriagedShareTheSecondGroup() {
        // Only `do` is promoted. decline / discuss / untriaged are all "everyone
        // else" and sort among themselves by position alone.
        let decline = note(id: "n1", paragraph: "cccc", triage: .decline)
        let discuss = note(id: "n2", paragraph: "bbbb", triage: .discuss)
        let untriaged = note(id: "n3", paragraph: "aaaa")
        XCTAssertEqual(ids([decline, discuss, untriaged]), ["n3", "n2", "n1"])
    }

    // MARK: - Document order within a group

    func test_withinAGroupTheOrderIsTheDocumentsOwn() {
        let a = note(id: "n1", paragraph: "dddd")
        let b = note(id: "n2", paragraph: "aaaa")
        let c = note(id: "n3", paragraph: "cccc")
        XCTAssertEqual(ids([a, b, c]), ["n2", "n3", "n1"])
    }

    func test_bothGroupsOrderByPositionIndependently() {
        let doLate = note(id: "d2", paragraph: "cccc", triage: .do)
        let doEarly = note(id: "d1", paragraph: "aaaa", triage: .do)
        let plainLate = note(id: "p2", paragraph: "dddd")
        let plainEarly = note(id: "p1", paragraph: "bbbb")
        XCTAssertEqual(
            ids([plainLate, doLate, plainEarly, doEarly]),
            ["d1", "d2", "p1", "p2"])
    }

    // MARK: - The tail: no paragraph, and a paragraph that left

    func test_aNoteWithNoParagraphSitsLastInItsOwnGroup() {
        // Craft notes carry no paragraphId; they belong to the whole document,
        // so they follow everything anchored in it rather than leading.
        let floating = note(id: "n1", paragraph: nil)
        let anchored = note(id: "n2", paragraph: "dddd")
        XCTAssertEqual(ids([floating, anchored]), ["n2", "n1"])
    }

    func test_theTailIsPerGroupNotPerQueue() {
        // A floating `do` note still beats an anchored untriaged one: the tail
        // is the last position WITHIN a group, not the end of the queue.
        let floatingDo = note(id: "n1", paragraph: nil, triage: .do)
        let anchoredPlain = note(id: "n2", paragraph: "aaaa")
        XCTAssertEqual(ids([anchoredPlain, floatingDo]), ["n1", "n2"])
    }

    func test_aParagraphThatLeftTheSequenceSortsWithTheTail() {
        // Stale anchor ≠ crash: a note whose paragraph was deleted has no
        // position to sort by, so it joins the no-paragraph tail rather than
        // trapping the sort (an `Int` lookup that force-unwrapped, or a 0 that
        // silently promoted the orphan to the top of the queue).
        let orphan = note(id: "n1", paragraph: "zzzz")
        let floating = note(id: "n2", paragraph: nil)
        let anchored = note(id: "n3", paragraph: "bbbb")
        let out = ids([orphan, floating, anchored])
        XCTAssertEqual(out.first, "n3", "the anchored note leads")
        XCTAssertEqual(Set(out.dropFirst()), ["n1", "n2"], "both tail together")
    }

    // MARK: - Ties are broken deterministically

    func test_tiesAtOnePositionBreakByCreatedAtDescending() {
        let older = note(id: "n1", paragraph: "aaaa", offset: 0)
        let newer = note(id: "n2", paragraph: "aaaa", offset: 60)
        XCTAssertEqual(ids([older, newer]), ["n2", "n1"])
    }

    func test_tiesAtOneInstantBreakByIdDescending() {
        let low = note(id: "n1", paragraph: "aaaa")
        let high = note(id: "n2", paragraph: "aaaa")
        XCTAssertEqual(ids([low, high]), ["n2", "n1"])
    }

    func test_theTailBreaksItsOwnTiesTheSameWay() {
        let a = note(id: "n1", paragraph: nil)
        let b = note(id: "n2", paragraph: "zzzz")
        // Same position (the tail), same instant → id descending.
        XCTAssertEqual(ids([a, b]), ["n2", "n1"])
    }

    func test_theOrderIsIndependentOfTheInputOrder() {
        // Every key is a total order over distinct ids, so the result does not
        // depend on `sorted`'s (unspecified) stability.
        let all = [
            note(id: "n1", paragraph: "cccc", triage: .do),
            note(id: "n2", paragraph: nil, triage: .do),
            note(id: "n3", paragraph: "aaaa"),
            note(id: "n4", paragraph: "aaaa", offset: 60),
            note(id: "n5", paragraph: "zzzz", triage: .discuss),
            note(id: "n6", paragraph: "dddd", triage: .decline)
        ]
        let expected = ids(all)
        XCTAssertEqual(expected, ["n1", "n2", "n4", "n3", "n6", "n5"])
        for permutation in [all.reversed().map { $0 }, all.shuffled(), all.shuffled()] {
            XCTAssertEqual(ids(permutation), expected)
        }
    }

    // MARK: - Degenerate inputs

    func test_anEmptySequenceLeavesEveryNoteInTheTail() {
        // A document with no paragraphs yet (or a caller with a stale sequence)
        // orders by the tie-breakers alone rather than refusing to sort.
        let a = note(id: "n1", paragraph: "aaaa")
        let b = note(id: "n2", paragraph: "bbbb")
        XCTAssertEqual(
            AnnotationQueueOrder.sorted([a, b], sequence: []).map(\.id),
            ["n2", "n1"])
    }

    func test_anEmptyQueueIsEmpty() {
        XCTAssertTrue(AnnotationQueueOrder.sorted([], sequence: seq).isEmpty)
    }

    // MARK: - The triage filter

    func test_allAdmitsEveryMarkAndTheUnmarked() {
        for triage in TriageMark.allCases.map({ Optional($0) }) + [nil] {
            XCTAssertTrue(
                AnnotationTriageFilter.all.matches(
                    note(id: "n", paragraph: "aaaa", triage: triage)))
        }
    }

    func test_eachMarkFilterAdmitsOnlyItsOwnMark() {
        let pairs: [(AnnotationTriageFilter, TriageMark)] = [
            (.doThis, .do), (.decline, .decline), (.discuss, .discuss)
        ]
        for (filter, own) in pairs {
            for mark in TriageMark.allCases {
                XCTAssertEqual(
                    filter.matches(note(id: "n", paragraph: "aaaa", triage: mark)),
                    mark == own,
                    "\(filter) vs \(mark)")
            }
            XCTAssertFalse(filter.matches(note(id: "n", paragraph: "aaaa")),
                           "\(filter) does not admit an untriaged note")
        }
    }

    func test_untriagedAdmitsOnlyTheUnmarked() {
        XCTAssertTrue(
            AnnotationTriageFilter.untriaged.matches(note(id: "n", paragraph: "aaaa")))
        for mark in TriageMark.allCases {
            XCTAssertFalse(
                AnnotationTriageFilter.untriaged.matches(
                    note(id: "n", paragraph: "aaaa", triage: mark)))
        }
    }

    func test_everyMarkHasExactlyOneFilterOfItsOwn() {
        // A mark with no filter is a note the writer can make and never find
        // again; two filters for one mark is a menu that lies about which is on.
        for mark in TriageMark.allCases {
            let marked = note(id: "n", paragraph: "aaaa", triage: mark)
            let matching = AnnotationTriageFilter.allCases
                .filter { $0 != .all && $0.matches(marked) }
            XCTAssertEqual(matching.count, 1, "\(mark) has one filter")
            XCTAssertEqual(matching.first?.label, mark.queueLabel,
                           "and the filter is named for the mark")
        }
    }
}

import XCTest
import MaughamCore
@testable import Maugham

/// Shell plan 3, Task 1 — `ClauseMarks`: the latest check's reading, placed on
/// the writer's own intent sentences. Review Focus 1.
final class ClauseMarksTests: XCTestCase {

    private func clause(_ quote: String, _ status: String) -> DiagnosticIngest.ClauseStatus {
        DiagnosticIngest.ClauseStatus(clauseQuote: quote, status: status, refs: [])
    }

    private func run(snapshot: String?) -> CompilerRun {
        CompilerRun(id: "run-1", at: Date(timeIntervalSince1970: 1_700_000_000), model: "m",
                    lastOpId: nil, deltaSummary: "", intentSnapshot: snapshot, passId: nil, round: nil,
                    freshEyes: nil, kind: .check)
    }

    private func text(_ paragraph: String, _ mark: ClauseMark) -> String {
        (paragraph as NSString).substring(with: mark.range)
    }

    // MARK: - Whether marks apply at all

    func test_marksApplyOnlyWhileTheIntentIsTheTextTheCheckRead() {
        let intent = "Kelly never lies.\n\n## Rulings\n\n- The harbour stays shut\n"
        XCTAssertTrue(ClauseMarks.applies(run: run(snapshot: intent), statementText: intent))

        // Edited after the check — even by one character, even whitespace.
        XCTAssertFalse(ClauseMarks.applies(run: run(snapshot: intent), statementText: intent + " "))
        XCTAssertFalse(ClauseMarks.applies(
            run: run(snapshot: intent), statementText: intent.replacingOccurrences(of: "never", with: "always")))

        // Either side missing: nothing to compare, so no marks.
        XCTAssertFalse(ClauseMarks.applies(run: nil, statementText: intent))
        XCTAssertFalse(ClauseMarks.applies(run: run(snapshot: nil), statementText: intent))
        XCTAssertFalse(ClauseMarks.applies(run: run(snapshot: intent), statementText: nil))
    }

    // MARK: - Placing them

    func test_holdsIsNoMarkStrainsIsSolidSilentIsDotted() {
        let p = "Kelly never lies. The harbour stays shut. Nobody mentions the war."
        let placed = ClauseMarks.marks(in: p, clauses: [
            clause("Kelly never lies.", "holds"),
            clause("The harbour stays shut.", "strains"),
            clause("Nobody mentions the war.", "silent"),
        ])
        XCTAssertEqual(placed.map(\.kind), [.strains, .silent])
        XCTAssertEqual(placed.map { text(p, $0) }, ["The harbour stays shut", "Nobody mentions the war"])
        XCTAssertEqual(placed.map(\.clauseQuote), ["The harbour stays shut.", "Nobody mentions the war."],
                       "the mark keeps the quote it was found by, verbatim")
    }

    func test_aQuoteMatchesAcrossCurlyQuotesWhitespaceAndCase() {
        let p = "She said \u{201C}I\u{2019}m  not\nlying\u{201D} and   meant it."
        let placed = ClauseMarks.marks(in: p, clauses: [
            clause("  \"she said \"i'm not lying\" and meant it.\"  ", "strains"),
        ])
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed.first.map { text(p, $0) },
                       "She said \u{201C}I\u{2019}m  not\nlying\u{201D} and   meant it",
                       "the range is the writer's own characters, curly quotes and runs of whitespace intact")
    }

    func test_aQuoteFoundTwiceMarksOnlyTheFirst() {
        let p = "Keep it quiet. Then the storm. Keep it quiet."
        let one = ClauseMarks.marks(in: p, clauses: [clause("Keep it quiet", "strains")])
        XCTAssertEqual(one.map(\.range), [NSRange(location: 0, length: 13)])

        // Two clauses with one quote take the first unmarked occurrence each, in order.
        let two = ClauseMarks.marks(in: p, clauses: [clause("Keep it quiet", "silent"),
                                                     clause("Keep it quiet", "silent")])
        XCTAssertEqual(two.map(\.range), [NSRange(location: 0, length: 13), NSRange(location: 31, length: 13)])
    }

    func test_aQuoteNotInTheParagraphMarksNothing() {
        let p = "Kelly never lies."
        let placement = ClauseMarks.placement(in: p, clauses: [
            clause("Kelly always lies.", "strains"),
            clause("", "silent"),
            clause("\u{201C}.\u{201D}", "silent"),
            clause("Kelly never lies.", "holds"),
        ])
        XCTAssertEqual(placement.marks, [])
        XCTAssertEqual(placement.skipped, 3,
                       "three strains/silent quotes found nowhere — an empty one matches nothing; holds is never counted")
        XCTAssertEqual(ClauseMarks.marks(in: "", clauses: [clause("x", "strains")]), [])
    }

    func test_aRangeIsInTheParagraphsOwnUTF16Offsets() {
        let p = "\u{1F600} Kelly never lies, \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} not once."
        let placed = ClauseMarks.marks(in: p, clauses: [
            clause("Kelly never lies", "strains"),
            clause("not once.", "silent"),
        ])
        XCTAssertEqual(placed.map(\.range), [
            NSRange(location: 3, length: 16),
            NSRange(location: 3 + 16 + 2 + 8 + 1, length: 8),
        ], "UTF-16 units: the face is 2, the family is 8")
        XCTAssertEqual(placed.map { text(p, $0) }, ["Kelly never lies", "not once"])
    }

    func test_strainsWinsAnOverlapWithSilent() {
        let p = "The harbour stays shut until the war ends."
        let placed = ClauseMarks.marks(in: p, clauses: [
            clause("stays shut until the war", "silent"),
            clause("The harbour stays shut", "strains"),
            clause("ends", "silent"),
        ])
        XCTAssertEqual(placed.map(\.kind), [.strains, .silent])
        XCTAssertEqual(placed.map { text(p, $0) }, ["The harbour stays shut", "ends"],
                       "the overlapping silent mark is dropped; the strain stands")
        // An overlapped silent quote was found, so it is not counted skipped.
        XCTAssertEqual(ClauseMarks.placement(in: p, clauses: [
            clause("stays shut until the war", "silent"), clause("The harbour stays shut", "strains"),
        ]).skipped, 0)
    }

    func test_aNestedStrainDoesNotDoubleMarkTheOuterWins() {
        let p = "The harbour stays shut until the war ends."
        // The inner phrase comes first in the check's order; the outer still wins.
        let placement = ClauseMarks.placement(in: p, clauses: [
            clause("stays shut", "strains"),
            clause("The harbour stays shut until the war", "strains"),
        ])
        XCTAssertEqual(placement.marks.map { text(p, $0) }, ["The harbour stays shut until the war"])
        XCTAssertEqual(placement.skipped, 1, "the nested inner strain is skipped and counted")
        // Silent nested in silent: the same rule.
        let silent = ClauseMarks.placement(in: p, clauses: [
            clause("until the war", "silent"), clause("stays shut until the war ends", "silent"),
        ])
        XCTAssertEqual(silent.marks.map { text(p, $0) }, ["stays shut until the war ends"])
        XCTAssertEqual(silent.skipped, 1)
    }

    func test_aDuplicateQuoteLandsOnTheFirstUnmarkedOccurrenceInOrder() {
        let p = "Keep it quiet now. Keep it quiet. And keep it quiet."
        let placed = ClauseMarks.placement(in: p, clauses: [
            clause("Keep it quiet now.", "strains"),
            clause("Keep it quiet", "silent"),
            clause("Keep it quiet", "silent"),
            clause("Keep it quiet", "silent"),
        ])
        XCTAssertEqual(placed.marks.map(\.range.location), [0, 19, 38],
                       "the first occurrence is under the strain, so the duplicates take the next free ones, in order")
        XCTAssertEqual(placed.skipped, 1, "the third duplicate has no occurrence left")
    }

    func test_aSolidMarkNamesItsToResolveFinding() {
        let p = "Kelly never lies. The harbour stays shut."
        let strain = Diagnostic(id: "d-1", docId: "doc-a", anchor: nil, body: "pulls", category: nil,
                                runId: "run-1", kind: .conformanceStrain, refs: [],
                                clauseQuote: "The harbour stays shut.")
        let placement = ClauseMarks.placement(
            in: p, clauses: [clause("The harbour stays shut.", "strains"), clause("Kelly never lies.", "silent")],
            findings: [strain], docId: "doc-a")
        XCTAssertEqual(placement.marks.map(\.resolveItemId),
                       [nil, ResolveItem.finding(docId: "doc-a", strain).id],
                       "in text order: dotted carries none; solid carries the To resolve item's id")
    }
}

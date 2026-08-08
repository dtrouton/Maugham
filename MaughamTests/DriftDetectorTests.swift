import XCTest
@testable import Maugham

/// `DriftDetector` is pure — no store, no project, just the ring shape
/// `DiagnosticsStore.clauseStatusHistory` produces. Fixtures build that
/// shape directly.
final class DriftDetectorTests: XCTestCase {
    private func status(
        _ quote: String, _ status: String, refs: [Diagnostic.Ref] = []
    ) -> DiagnosticIngest.ClauseStatus {
        DiagnosticIngest.ClauseStatus(clauseQuote: quote, status: status, refs: refs)
    }

    func test_emptyHistory_yieldsNoFindings() {
        XCTAssertEqual(DriftDetector.drift(history: []), [])
    }

    func test_fewerRunsThanThreshold_yieldsNoFindings() {
        let history = [
            [status("Cold, and never wistful.", "strains")],
            [status("Cold, and never wistful.", "strains")]
        ]
        XCTAssertEqual(DriftDetector.drift(history: history), [],
            "two straining runs is not yet a pattern at threshold 3")
    }

    func test_kConsecutiveStrainsOfTheSameQuote_fires() {
        let quote = "Cold, and never wistful."
        let history = [
            [status(quote, "strains")],
            [status(quote, "strains")],
            [status(quote, "strains")]
        ]
        XCTAssertEqual(
            DriftDetector.drift(history: history),
            [DriftFinding(clauseQuote: quote, runsStraining: 3)])
    }

    func test_aHoldInTheMiddleBreaksTheStreak() {
        let quote = "Cold, and never wistful."
        let history = [
            [status(quote, "strains")],
            [status(quote, "holds")],
            [status(quote, "strains")]
        ]
        XCTAssertEqual(DriftDetector.drift(history: history), [],
            "a hold is the clause behaving — the streak resets, it does not pause")
    }

    func test_aSilentRunBreaksTheStreak() {
        let quote = "Cold, and never wistful."
        let history = [
            [status(quote, "strains")],
            [status(quote, "silent")],
            [status(quote, "strains")]
        ]
        XCTAssertEqual(DriftDetector.drift(history: history), [])
    }

    /// A re-derivation renamed the clause: it simply is not in that run's
    /// checked list. An honest reset, not a special case — the same break
    /// path as a hold or a silence.
    func test_absenceFromARunBreaksTheStreak() {
        let quote = "Cold, and never wistful."
        let history: [[DiagnosticIngest.ClauseStatus]] = [
            [status(quote, "strains")],
            [], // the clause was not checked this run at all
            [status(quote, "strains")]
        ]
        XCTAssertEqual(DriftDetector.drift(history: history), [])
    }

    func test_revokedRulingScenario_clauseVanishesFromLaterRuns_noGhostDrift() {
        let quote = "Kelly never speaks first."
        // Two strains, then the ruling is revoked and the clause is
        // re-derived away entirely — it never appears again.
        let history: [[DiagnosticIngest.ClauseStatus]] = [
            [status(quote, "strains")],
            [status(quote, "strains")],
            [status("Cold, and never wistful.", "strains")],
            [status("Cold, and never wistful.", "strains")]
        ]
        let findings = DriftDetector.drift(history: history)
        XCTAssertFalse(findings.contains { $0.clauseQuote == quote },
            "the vanished clause must not still read as drifting")
    }

    /// Two clauses drift on their own timelines — B has one extra run of
    /// strain that A does not share — and the detector must not lock-step
    /// their streak lengths together.
    func test_twoClausesCanDriftIndependently() {
        let quoteA = "Cold, and never wistful."
        let quoteB = "Kelly never speaks first."
        let history: [[DiagnosticIngest.ClauseStatus]] = [
            [status(quoteB, "strains")],
            [status(quoteA, "strains"), status(quoteB, "strains")],
            [status(quoteA, "strains"), status(quoteB, "strains")],
            [status(quoteA, "strains"), status(quoteB, "strains")]
        ]
        let findings = DriftDetector.drift(history: history)
        XCTAssertTrue(
            findings.contains(DriftFinding(clauseQuote: quoteA, runsStraining: 3)))
        XCTAssertTrue(
            findings.contains(DriftFinding(clauseQuote: quoteB, runsStraining: 4)))
        XCTAssertEqual(findings.count, 2)
    }

    func test_aStreakLongerThanTheThreshold_reportsItsFullLength() {
        let quote = "Cold, and never wistful."
        let history = Array(repeating: [status(quote, "strains")], count: 4)
        XCTAssertEqual(
            DriftDetector.drift(history: history),
            [DriftFinding(clauseQuote: quote, runsStraining: 4)],
            "the finding reports how long the streak actually runs, not just the threshold")
    }

    func test_theSameQuoteOnlyProducesOneFindingEvenIfRepeatedInTheNewestRun() {
        let quote = "Cold, and never wistful."
        let history = [
            [status(quote, "strains")],
            [status(quote, "strains")],
            [status(quote, "strains"), status(quote, "strains")]
        ]
        XCTAssertEqual(
            DriftDetector.drift(history: history),
            [DriftFinding(clauseQuote: quote, runsStraining: 3)])
    }
}

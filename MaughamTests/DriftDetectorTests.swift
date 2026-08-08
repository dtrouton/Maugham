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

    /// **The three readers of the straining status are held on one spelling by
    /// reference, not by equal strings** (M1).
    ///
    /// `DiagnosticIngest` mints the value, `DriftDetector` matches on it and
    /// `DiagnosticsPane` renders it. The detector carried a raw `"strains"`
    /// literal while the other two went through
    /// `DiagnosticIngest.SectionField.strains`; the strings agreed, so nothing
    /// was ever red, and a contract that moved the word would have left drift
    /// silently inert — an inert rule with a live reader, this codebase's most
    /// repeated Critical.
    ///
    /// Nothing below spells the word as a literal of its own. The value travels
    /// out of a real section parse and into both readers, so a move that missed
    /// one of the three fails here rather than shipping quiet.
    @MainActor
    func test_theDetectorAndThePaneAgreeOnStrainsBySymbol() throws {
        let parsed = try XCTUnwrap(
            parseOneCheck(status: DiagnosticIngest.SectionField.strains),
            "the fixture line did not parse as a conformance check")

        let straining = Array(
            repeating: [parsed], count: DriftDetector.consecutiveRunsThreshold)
        XCTAssertEqual(
            DriftDetector.drift(history: straining).map(\.clauseQuote),
            [parsed.clauseQuote],
            "the detector must recognise the very status the ingest minted")
        XCTAssertEqual(
            DiagnosticsPane.statusWord(parsed.status),
            DiagnosticIngest.SectionField.strains,
            "and the pane must say the same word about the same value")

        // The control, so the assertion above cannot be satisfied by a detector
        // that fires on everything.
        let holding = try XCTUnwrap(parseOneCheck(status: DiagnosticIngest.SectionField.holds))
        XCTAssertEqual(
            DriftDetector.drift(
                history: Array(repeating: [holding],
                               count: DriftDetector.consecutiveRunsThreshold)),
            [],
            "a clause that holds is not drifting")
    }

    /// One conformance check off a real ingest parse, so the status a test
    /// hands the detector is the one the wire schema produces rather than one
    /// the test typed.
    private func parseOneCheck(status: String) -> DiagnosticIngest.ClauseStatus? {
        let line = "{\"section\":\"conformance\",\"checks\":[{"
            + "\"clause_quote\":\"Cold, and never wistful.\","
            + "\"status\":\"\(status)\",\"refs\":[\"a1b2\"],"
            + "\"what_pulls\":\"The last line reaches for a sigh.\"}]}"
        return DiagnosticIngest.parseSection(
            line: line, runId: "r1", docId: "d1",
            liveParagraphText: { _ in "The fog came." })?.conformance.first
    }
}

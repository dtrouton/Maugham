import XCTest
import MaughamCore
@testable import Maugham

/// Task 6 (Plan B, spec §5's return path): a document that opens normally
/// tries its own held quarantine records without being asked. Pins the pure
/// mapping from a sweep's `[ReturnOutcome]` to the notice
/// text `EditorHost.loadDocumentIfNeeded`'s hook posts (or doesn't) — the
/// `needsReload`/`recoveryActionIsCurrent` precedent for testing this host's
/// logic without mounting a window.
final class EditorHostAutoReturnNoticeTests: XCTestCase {

    private func report(orphanTexts: [String]) -> RecoveredHistoryReport {
        RecoveredHistoryReport(
            orphans: orphanTexts.map { .init(paragraphId: ULID.generate(), text: $0) },
            redundant: orphanTexts.isEmpty)
    }

    func test_noRecords_postsNothing() {
        XCTAssertNil(EditorHost.autoReturnNotice(outcomes: []))
    }

    func test_allStillUnreadable_postsNothing() {
        let outcomes: [ReturnOutcome] = [
            .stillUnreadable(reason: "permission denied"),
        ]
        XCTAssertNil(EditorHost.autoReturnNotice(outcomes: outcomes),
                     "the writer never asked — silence, the standing History notice covers it")
    }

    func test_allCorrupt_postsNothing() {
        let outcomes: [ReturnOutcome] = [
            .corrupt(reason: "a line failed to decode"),
        ]
        XCTAssertNil(EditorHost.autoReturnNotice(outcomes: outcomes))
    }

    func test_mixOfUnreadableAndCorrupt_postsNothing() {
        let outcomes: [ReturnOutcome] = [
            .stillUnreadable(reason: "a"),
            .corrupt(reason: "b"),
        ]
        XCTAssertNil(EditorHost.autoReturnNotice(outcomes: outcomes))
    }

    func test_returnedWithNoOrphans_postsNothingWasMissing() {
        let outcomes: [ReturnOutcome] = [.returned(report(orphanTexts: []))]
        XCTAssertEqual(EditorHost.autoReturnNotice(outcomes: outcomes),
                       "Recovered history merged — nothing was missing")
    }

    func test_supersededWithNoOrphans_postsNothingWasMissing() {
        let outcomes: [ReturnOutcome] = [.supersededBySync(report(orphanTexts: []))]
        XCTAssertEqual(EditorHost.autoReturnNotice(outcomes: outcomes),
                       "Recovered history merged — nothing was missing")
    }

    func test_returnedWithOrphans_postsTheOrphanCount() {
        let outcomes: [ReturnOutcome] = [
            .returned(report(orphanTexts: ["One.", "Two."])),
        ]
        XCTAssertEqual(EditorHost.autoReturnNotice(outcomes: outcomes),
                       "2 paragraphs from the recovered history aren’t in your draft — View")
    }

    func test_orphanCountsSumAcrossMultipleRecords() {
        let outcomes: [ReturnOutcome] = [
            .returned(report(orphanTexts: ["One."])),
            .supersededBySync(report(orphanTexts: ["Two.", "Three."])),
        ]
        XCTAssertEqual(EditorHost.autoReturnNotice(outcomes: outcomes),
                       "3 paragraphs from the recovered history aren’t in your draft — View")
    }

    /// A record that failed to return contributes nothing to the count even
    /// when another record in the same sweep succeeded — the notice is about
    /// what CAME BACK, not about the sweep's size.
    func test_unreturnedRecordDoesNotDiluteTheReturnedCount() {
        let outcomes: [ReturnOutcome] = [
            .returned(report(orphanTexts: ["One."])),
            .stillUnreadable(reason: "still broken"),
        ]
        XCTAssertEqual(EditorHost.autoReturnNotice(outcomes: outcomes),
                       "1 paragraph from the recovered history isn’t in your draft — View")
    }

    // MARK: - Did the sweep change a record? (fix round: I2b)

    /// The predicate the records-changed post is gated on. `.returned` and
    /// `.supersededBySync` each rewrite a sidecar and take a record out of the
    /// held set, which is what makes another surface's copy of that set stale;
    /// the two failures leave everything exactly as it was.
    func test_changedARecord_isTrueForBothOutcomesThatRewriteASidecar() {
        XCTAssertTrue(EditorHost.autoReturnChangedARecord(
            outcomes: [.returned(report(orphanTexts: []))]))
        XCTAssertTrue(EditorHost.autoReturnChangedARecord(
            outcomes: [.supersededBySync(report(orphanTexts: ["One."]))]))
        XCTAssertTrue(EditorHost.autoReturnChangedARecord(outcomes: [
            .stillUnreadable(reason: "a"),
            .returned(report(orphanTexts: [])),
        ]), "one changed record in a sweep is enough to make the pane stale")
    }

    func test_changedARecord_isFalseWhenNothingCameBack() {
        XCTAssertFalse(EditorHost.autoReturnChangedARecord(outcomes: []))
        XCTAssertFalse(EditorHost.autoReturnChangedARecord(outcomes: [
            .stillUnreadable(reason: "permission denied"),
            .corrupt(reason: "a line failed to decode"),
        ]), "nothing moved and no sidecar was rewritten — no surface is stale")
    }

    // MARK: - The set-aside press's two belts (fix round: M4)

    /// Both are states unreachable by construction today, which is exactly why
    /// the copy needs pinning: nothing else will ever read it.
    func test_theSetAsideBeltNoticesAreWriterVoiced() {
        for notice in [EditorHost.setAsideNoDocumentNotice,
                       EditorHost.setAsideNothingToMoveNotice] {
            XCTAssertTrue(notice.contains("set nothing aside"),
                          "the notice says what did NOT happen — got \(notice)")
            XCTAssertFalse(notice.localizedCaseInsensitiveContains("quarantine"),
                           "the internal term must never reach the writer — got \(notice)")
            XCTAssertFalse(notice.contains("'"),
                           "typographic apostrophes in writer-facing copy — got \(notice)")
        }
    }
}

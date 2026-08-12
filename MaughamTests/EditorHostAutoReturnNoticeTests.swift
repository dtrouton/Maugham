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
}

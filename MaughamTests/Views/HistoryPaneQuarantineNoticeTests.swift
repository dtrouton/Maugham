import XCTest
import MaughamCore
@testable import Maugham

/// Static-copy pins for HistoryPane's Plan B set-aside surfacing — the
/// standing notice for `.held` records and the post-Retry report notice.
/// Pinned without mounting, mirroring `unreadableCheckpointNotice`'s pattern
/// (`CheckpointStoreTests`).
@MainActor
final class HistoryPaneQuarantineNoticeTests: XCTestCase {

    // MARK: - quarantineNotice

    func test_quarantineNotice_nilWhenNothingHeld() {
        XCTAssertNil(HistoryPane.quarantineNotice(heldCount: 0))
    }

    func test_quarantineNotice_namesSetAside_whenRecordsAreHeld() {
        let notice = HistoryPane.quarantineNotice(heldCount: 1)
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice?.contains("set aside") == true,
                      "writer-facing copy names 'set aside', never 'quarantine' (CLAUDE.md)")
        XCTAssertFalse(notice?.localizedCaseInsensitiveContains("quarantine") == true,
                       "the internal term must never reach the writer")
    }

    // MARK: - recoveredHistoryNotice

    func test_recoveredHistoryNotice_zeroOrphans_saysNothingWasMissing() {
        XCTAssertEqual(
            HistoryPane.recoveredHistoryNotice(orphanCount: 0),
            "Recovered history merged — nothing was missing",
            "honest for the zero-byte-file case by design: a returned file "
            + "carrying nothing new reads the same as a genuinely redundant return")
    }

    func test_recoveredHistoryNotice_nOrphans_namesTheCountAndOffersView() {
        let notice = HistoryPane.recoveredHistoryNotice(orphanCount: 3)
        XCTAssertTrue(notice.contains("3"))
        XCTAssertTrue(notice.contains("paragraphs"))
        XCTAssertTrue(notice.contains("aren’t in your draft"))
        XCTAssertTrue(notice.hasSuffix("— View"))
    }

    func test_recoveredHistoryNotice_singularOrphan_usesSingularGrammar() {
        let notice = HistoryPane.recoveredHistoryNotice(orphanCount: 1)
        XCTAssertTrue(notice.contains("1 paragraph "))
        XCTAssertFalse(notice.contains("paragraphs"))
        XCTAssertTrue(notice.contains("isn’t in your draft"))
    }
}

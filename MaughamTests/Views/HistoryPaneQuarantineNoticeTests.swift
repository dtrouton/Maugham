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

    // MARK: - stillHeldNotice (fix round: I2 — an all-failed Retry said nothing)

    func test_stillHeldNotice_namesTheReason_andStaysWriterVoiced() {
        let notice = HistoryPane.stillHeldNotice(reason: "permission denied")
        XCTAssertTrue(notice.contains("still can’t be read"),
                      "the pressed button reports what happened — got \(notice)")
        XCTAssertTrue(notice.contains("permission denied"),
                      "and names the reason, because the reasons want opposite responses")
        XCTAssertTrue(notice.contains("set aside"))
        XCTAssertFalse(notice.localizedCaseInsensitiveContains("quarantine"),
                       "the internal term must never reach the writer")
    }

    // MARK: - `redundant` has a production reader (fix round: I1)

    /// `RecoveredHistoryReport.redundant` shipped with **zero** production
    /// readers while this pane hand-built its sheet report with
    /// `redundant: false` written in — so the flag said "sync had already
    /// delivered all of this" about sweeps where it had delivered none of it.
    /// The `RegionBindingTests.test_theProjectionHasAProductionCaller` shape:
    /// a field nothing reads is a field nothing keeps honest.
    func test_theReportsRedundantFlagHasAProductionReader() throws {
        let readers = try Self.productionFiles()
            .filter { SourceScan.namesInCode(".redundant", in: $0.source) }
            .map(\.name)
            .sorted()
        XCTAssertEqual(readers, ["HistoryPane.swift"],
                       "if this is ever empty, `redundant` is back to being a field "
                       + "nothing consumes. If it grows, the new reader is a deliberate "
                       + "edit here — and it says what it does with the flag.")
    }

    /// The other half, and the defect itself: no production surface may
    /// assemble a `RecoveredHistoryReport` by hand. A sweep's verdict comes
    /// from `RecoveredHistoryReport.aggregate`, which is the one place that
    /// decides what several returns add up to.
    func test_noProductionSurfaceHandBuildsAReport() throws {
        let builders = try Self.productionFiles()
            .filter { SourceScan.namesInCode("RecoveredHistoryReport(orphans:", in: $0.source) }
            .map(\.name)
        XCTAssertEqual(builders, [],
                       "a hand-built report writes `redundant` from whatever the caller "
                       + "guessed — use RecoveredHistoryReport.aggregate. Offenders: \(builders)")
        XCTAssertTrue(
            try Self.productionFiles().contains {
                SourceScan.namesInCode("RecoveredHistoryReport.aggregate(", in: $0.source)
            },
            "…and the corpus is being read: the aggregate has production callers")
    }

    /// Every `.swift` file under `Maugham/`, with its source. Walked here
    /// rather than shelling out, matching `TripwireGrepTests`' readers.
    private static func productionFiles() throws -> [(name: String, source: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Views/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate \(root.path)"); return []
        }
        var out: [(name: String, source: String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertFalse(out.isEmpty, "the production corpus must not read empty")
        return out
    }
}

import XCTest
@testable import Maugham
@testable import MaughamCore

/// T12 — ADR 0016 enforcement: a tampered segment is quarantined + marks the
/// doc unhealthy (which pauses backups, existing v0.8.0 behavior), never
/// silently skipped; salvageable ops still derive.
@MainActor
final class SegmentIntegrityTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("segintegrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        Document.segmentSealThresholdForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    func test_tamperedSegment_quarantinedNotSilent() async throws {
        // Build real history and seal it.
        let url = projectURL.appendingPathComponent("manuscript/doc.md")
        try "Alpha paragraph.\n\nBeta paragraph."
            .write(to: url, atomically: true, encoding: .utf8)
        let doc = try await Document.load(
            url: url, device: "test-mac", session: "s1", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        doc.setParagraph(id: doc.sequence[0], text: "Alpha, sealed history.")
        try await doc.flushBurstNow()
        Document.segmentSealThresholdForTesting = 1
        await doc.close()

        let segURL = OpLogStore.opLogFileURLs(forDocId: doc.docId, in: projectURL)
            .first { $0.pathExtension == "mzseg" }!
        // Flip a byte in the stored digest: decompression still succeeds →
        // salvage path; checksum fails → quarantine + unhealthy.
        var bytes = try Data(contentsOf: segURL)
        bytes[16] ^= 0xFF
        try bytes.write(to: segURL)

        // 1. The integrity report marks the doc unhealthy.
        let report = try await ProjectIntegrity.check(projectURL: projectURL)
        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.docSkips.contains { $0.docId == doc.docId })

        // 2. Loading the doc writes a forensic quarantine record.
        Document.segmentSealThresholdForTesting = nil
        let reloaded = try await Document.load(
            url: url, device: "test-mac", session: "s2", presenter: nil)
        let quarantineDir = projectURL
            .appendingPathComponent(".maugham/conflicts/quarantine")
        let records = (try? FileManager.default.contentsOfDirectory(
            atPath: quarantineDir.path)) ?? []
        XCTAssertTrue(records.contains { $0.hasPrefix(doc.docId) },
                      "checksum failure must leave a quarantine record")

        // 3. Salvageable ops still derived — the sealed edit is visible.
        XCTAssertTrue(reloaded.displayText.contains("Alpha, sealed history."),
                      "salvage must keep the manuscript readable")
        await reloaded.close()
    }
}

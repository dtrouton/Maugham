import XCTest
@testable import Maugham
@testable import MaughamCore

@MainActor
final class SegmentSealTriggerTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sealtrigger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        Document.segmentSealThresholdForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func makeDoc(device: String = "test-mac") async throws -> Document {
        let url = projectURL.appendingPathComponent("manuscript/doc.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try "Alpha paragraph.\n\nBeta paragraph."
                .write(to: url, atomically: true, encoding: .utf8)
        }
        return try await Document.load(
            url: url, device: device, session: "s1", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
    }

    private func segmentURLs(docId: String) -> [URL] {
        OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL)
            .filter { $0.pathExtension == "mzseg" }
    }

    func test_close_sealsOversizedTail() async throws {
        let doc = try await makeDoc()
        // Grow the tail past the test threshold with real bursts.
        for i in 0..<30 {
            doc.setParagraph(id: doc.sequence[0],
                             text: "Alpha grown \(i) " + String(repeating: "y", count: 300))
            try await doc.flushBurstNow()
        }
        let before = try await OpLogStore(projectURL: projectURL).load(docId: doc.docId)
        Document.segmentSealThresholdForTesting = 1   // force the seal at close
        await doc.close()

        XCTAssertFalse(segmentURLs(docId: doc.docId).isEmpty,
                       "close() must seal an oversized tail")
        let after = try await OpLogStore(projectURL: projectURL).load(docId: doc.docId)
        XCTAssertEqual(after, before, "sealing at close must not change the logical log")

        // Full reload round-trip through the production path.
        Document.segmentSealThresholdForTesting = nil
        let reloaded = try await makeDoc()
        XCTAssertTrue(reloaded.displayText.contains("Alpha grown 29"))
        await reloaded.close()
    }

    func test_close_underThreshold_doesNotSeal() async throws {
        let doc = try await makeDoc()
        doc.setParagraph(id: doc.sequence[0], text: "tiny edit")
        try await doc.flushBurstNow()
        await doc.close()    // default 512 KB threshold — far under
        XCTAssertTrue(segmentURLs(docId: doc.docId).isEmpty)
    }

    // T11 — a remote device's seal delivers as a no-op re-derive.
    func test_sealIsDeriveNoOp_acrossPresenter() async throws {
        // Remote device "other-mac" writes history into ITS tail.
        let remote = try await makeDoc(device: "other-mac")
        remote.setParagraph(id: remote.sequence[0], text: "Alpha from other-mac.")
        try await remote.flushBurstNow()
        await remote.close()

        // Local doc opens and sees the merged state.
        let local = try await makeDoc(device: "test-mac")
        let textBefore = local.displayText
        let seqBefore = local.sequence

        // The remote seals its own tail (segment appears, tail disappears).
        let store = OpLogStore(projectURL: projectURL)
        let sealed = try await store.sealTailIfNeeded(
            docId: local.docId, deviceSlug: DeviceSlug.make(from: "other-mac"),
            threshold: 1)
        XCTAssertNotNil(sealed)

        // The presenter delivery on the local device: identical op set → no-op.
        try await local.handleExternalLogChange()
        XCTAssertEqual(local.displayText, textBefore)
        XCTAssertEqual(local.sequence, seqBefore)
        await local.close()
    }

    func test_sidecarPath_routesSegmentAsOpLog() {
        let url = projectURL.appendingPathComponent(
            ".maugham/ops/doc-ab12.testmac.seg0001.mzseg")
        let routed = MaughamSidecarPath.classify(url: url, projectURL: projectURL)
        guard case .opLog(let docId) = routed else {
            return XCTFail("segment must route as .opLog, got \(routed)")
        }
        XCTAssertEqual(docId, "doc-ab12")
    }

    func test_documentStoreOpen_runsSealMaintenance() async throws {
        let doc = try await makeDoc(device: MacDeviceID.current)
        for i in 0..<30 {
            doc.setParagraph(id: doc.sequence[0],
                             text: "grown \(i) " + String(repeating: "z", count: 300))
            try await doc.flushBurstNow()
        }
        // Close WITHOUT the test threshold: tail stays unsealed.
        await doc.close()
        XCTAssertTrue(segmentURLs(docId: doc.docId).isEmpty)

        Document.segmentSealThresholdForTesting = 1
        let store = try await DocumentStore.open(url: projectURL)
        XCTAssertFalse(segmentURLs(docId: doc.docId).isEmpty,
                       "project-open maintenance must seal this Mac's oversized tails")
        await store.close()
    }
}

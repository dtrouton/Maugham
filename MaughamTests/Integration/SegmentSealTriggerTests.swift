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
        // Process-wide, so a leak would silently change what every later
        // test's load can vouch for.
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    /// Give this test a device whose four writers can all SIGN, and a chain
    /// memory of its own.
    ///
    /// The machine running the suite may have no key at all — CI's VM has no
    /// Secure Enclave, so every actor there is the unsigned token twin and
    /// `sealChain` correctly writes nothing. Injecting the software signers is
    /// what makes a seal assertion decidable rather than machine-dependent; the
    /// fresh state keeps one test's remembered heads out of another's.
    ///
    /// Answers the AUTHOR's device string, because in production the two are
    /// the same fact: `Document.load(actor: .author, …)` derives its device id
    /// from exactly this value, so the file an op is appended to (named from
    /// `op.device`) and the file `sealChain` seals (named from `identity.slug`)
    /// are one file. A test that took the fixture's own "test-mac" would seal a
    /// file nothing wrote to and prove nothing.
    @discardableResult
    private func useASigningIdentity() -> String {
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        return identities.author.deviceId
    }

    /// The injected author, for the assertions that name its fingerprint.
    private func injectedAuthor() throws -> DeviceIdentity {
        try XCTUnwrap(Document.localIdentitiesForTesting).author
    }

    private func tailLines(docId: String, device: String = "test-mac") throws -> [Data] {
        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: DeviceSlug.make(from: device),
            in: projectURL)
        return try Data(contentsOf: url)
            .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
            .map { Data($0) }
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

    /// The device string is the AUTHOR's own, because that is what production
    /// hands `Document.load(actor: .author, …)` — and since P1b close rotates
    /// the tails of this device's own actors and nobody else's, a doc loaded
    /// under a made-up device string would grow a tail no local slug names.
    func test_close_sealsOversizedTail() async throws {
        let device = DeviceIdentity.author.deviceId
        let doc = try await makeDoc(device: device)
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
        let reloaded = try await makeDoc(device: device)
        XCTAssertTrue(reloaded.displayText.contains("Alpha grown 29"))
        await reloaded.close()
    }

    // MARK: - Signed op log P1: the chain seal on burst and on close

    /// A burst is "typing followed by idle" (spec §4.3's third trigger), so it
    /// seals what it just wrote. Without this the whole live tail stays merely
    /// chained — tamper-evident, but signed by nobody — until the writer quits.
    func test_burstSealsTheRunItJustWrote() async throws {
        let device = useASigningIdentity()
        let doc = try await makeDoc(device: device)
        doc.setParagraph(id: doc.sequence[0], text: "Alpha, sealed.")
        try await doc.flushBurstNow()

        let lines = try tailLines(docId: doc.docId, device: device)
        XCTAssertTrue(OpLogChain.isSealLine(try XCTUnwrap(lines.last)),
                      "the burst's own seal is the tail's last line")
        let seal = try XCTUnwrap(OpLogChain.Seal.parse(try XCTUnwrap(lines.last)))
        XCTAssertTrue(seal.verifies(), "and it holds together under its own key")
        XCTAssertEqual(
            seal.key, try injectedAuthor().fingerprint,
            "signed by THIS device, which is the whole claim a seal makes")
        await doc.close()
    }

    /// The seal is maintenance, and maintenance may never cost the writer the
    /// burst that has already landed: a chain seal that cannot be written
    /// leaves the ops exactly where they are. A device with no key is the
    /// ordinary case of that (spec §4.1), not an error.
    func test_burstWithNoKeyStillWritesTheOps_andSealsNothing() async throws {
        let identity = DeviceIdentity.unsignedForTesting(
            token: Data(repeating: 7, count: 32))
        Document.localIdentitiesForTesting = .forTesting(author: identity)
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        let doc = try await makeDoc(device: identity.deviceId)
        doc.setParagraph(id: doc.sequence[0], text: "Alpha, unsigned.")
        try await doc.flushBurstNow()

        let lines = try tailLines(docId: doc.docId, device: identity.deviceId)
        XCTAssertFalse(lines.contains(where: OpLogChain.isSealLine),
                       "a device with no key signs nothing — a state, not a failure")
        await doc.close()
        let reloaded = try await makeDoc(device: identity.deviceId)
        XCTAssertTrue(reloaded.displayText.contains("Alpha, unsigned."),
                      "and the words are safe regardless")
        await reloaded.close()
    }

    /// Order is the whole point: `sealChain` runs BEFORE `sealTailIfNeeded`, so
    /// a rotated segment ENDS on a seal line and its whole span is verified
    /// inside the container. The other order rotates the unsealed tail away and
    /// leaves that span unsigned forever — there is no going back to it.
    func test_close_sealsTheChainBeforeRotatingTheTail() async throws {
        let device = useASigningIdentity()
        let doc = try await makeDoc(device: device)
        for i in 0..<30 {
            doc.setParagraph(id: doc.sequence[0],
                             text: "Alpha grown \(i) " + String(repeating: "y", count: 300))
            try await doc.flushBurstNow()
        }
        // The last thing in the tail must be UNSEALED, or this test cannot
        // tell the two orders apart: a burst seals itself, so a tail whose
        // last event was a burst already ends on a seal whichever order close
        // runs in. A checkpoint breadcrumb is a real, ordinary op that arrives
        // outside the burst path — the shape annotation and task ops share —
        // and it is exactly the span close's own `sealChain` exists to cover.
        try await doc.appendMirrored(Op(
            opId: ULID.generate(), docId: doc.docId, at: Date(),
            device: device, session: "s1", kind: .checkpoint, changes: []))
        let lastBeforeClose = try XCTUnwrap(tailLines(docId: doc.docId, device: device).last)
        XCTAssertFalse(OpLogChain.isSealLine(lastBeforeClose),
                       "precondition: the tail ends unsealed going into close()")

        Document.segmentSealThresholdForTesting = 1   // force the rotation
        await doc.close()

        let segments = segmentURLs(docId: doc.docId)
        XCTAssertEqual(segments.count, 1, "the oversized tail rotated")
        let decoded = OpLogSegment.decodeVerifying(try Data(contentsOf: segments[0]))
        XCTAssertTrue(decoded.isVerified, "precondition: the container checks out")
        let segmentLines = try XCTUnwrap(decoded.jsonl)
            .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
            .map { Data($0) }
        XCTAssertTrue(
            OpLogChain.isSealLine(try XCTUnwrap(segmentLines.last)),
            "the segment ends on a seal line — the chain was sealed first")

        let sigURL = OpLogStore.segmentSignatureURL(for: segments[0])
        let signature = try XCTUnwrap(
            SegmentSignature.read(at: sigURL),
            "and the segment is signed beside itself")
        XCTAssertTrue(signature.verifies())
        XCTAssertEqual(
            signature.key,
            try injectedAuthor().fingerprint)
    }

    /// The same order, from the OTHER caller. Project-open maintenance runs the
    /// pair for every doc this Mac has written, and a second spelling of the
    /// order is a second place it can be got wrong.
    func test_documentStoreOpenMaintenanceSealsTheChainBeforeRotating() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Maugham/Stores/DocumentStore.swift"),
            encoding: .utf8)
        let chain = try XCTUnwrap(source.range(of: "sealStore.sealChain(docId:"))
        let rotate = try XCTUnwrap(source.range(of: "sealStore.sealTailIfNeeded("))
        XCTAssertTrue(
            chain.lowerBound < rotate.lowerBound,
            "open-time maintenance seals the chain before rotating the tail — "
            + "the other order strands an unsealed span inside an immutable segment")
    }

    // MARK: - Signed op log P1b: every local actor's tail rotates

    /// A device is four writers, and each of them has a per-doc file of its
    /// own. Rotation used to name ONE slug — the author's — so an assistant
    /// file grown past the threshold by a long MCP session chained and sealed
    /// but never became a segment, and the growth ADR 0016 exists to bound was
    /// bounded for the writer's file alone.
    ///
    /// The sidecar is the second half of the claim: the segment carries the
    /// key of the actor whose slug names it, so an assistant's segment is
    /// signed by the assistant and never by the writer's hand.
    func test_close_rotatesEveryLocalActorsOversizedTail() async throws {
        let device = useASigningIdentity()
        let identities = try XCTUnwrap(Document.localIdentitiesForTesting)
        let doc = try await makeDoc(device: device)
        doc.setParagraph(id: doc.sequence[0], text: "Alpha, by the writer.")
        try await doc.flushBurstNow()

        // An op through MCP: same document, the assistant's own key and its
        // own file. `append` routes by `op.device`, so this lands in
        // `<doc>.assistant-…jsonl` and is chained under the assistant.
        try await doc.appendMirrored(Op(
            opId: ULID.generate(), docId: doc.docId, at: Date(),
            device: identities.assistant.deviceId, session: "s1",
            kind: .checkpoint, changes: []))

        Document.segmentSealThresholdForTesting = 1   // force both rotations
        await doc.close()

        for identity in [identities.author, identities.assistant] {
            let segments = segmentURLs(docId: doc.docId)
                .filter { $0.lastPathComponent.contains(identity.slug.raw) }
            XCTAssertEqual(
                segments.count, 1,
                "\(identity.deviceId)'s oversized tail must rotate at close")
            let signature = try XCTUnwrap(
                SegmentSignature.read(
                    at: OpLogStore.segmentSignatureURL(for: segments[0])),
                "\(identity.deviceId)'s segment is signed beside itself")
            XCTAssertTrue(signature.verifies())
            XCTAssertEqual(
                signature.key, identity.fingerprint,
                "signed by the actor whose slug the segment is named for")
        }
    }

    /// The same rule from the other caller. Project-open maintenance sweeps
    /// this Mac's oversized tails, and this Mac has four of them per doc.
    func test_openMaintenanceRotatesEveryLocalActorsOversizedTail() async throws {
        let device = useASigningIdentity()
        let identities = try XCTUnwrap(Document.localIdentitiesForTesting)
        let doc = try await makeDoc(device: device)
        doc.setParagraph(id: doc.sequence[0], text: "Alpha, by the writer.")
        try await doc.flushBurstNow()
        try await doc.appendMirrored(Op(
            opId: ULID.generate(), docId: doc.docId, at: Date(),
            device: identities.assistant.deviceId, session: "s1",
            kind: .checkpoint, changes: []))
        // Close WITHOUT the test threshold, so both tails survive unrotated
        // and the sweep is the only thing that can rotate them.
        await doc.close()
        XCTAssertTrue(segmentURLs(docId: doc.docId).isEmpty,
                      "precondition: nothing rotated at close")

        Document.segmentSealThresholdForTesting = 1
        let store = try await DocumentStore.open(url: projectURL)
        defer { Task { await store.close() } }
        for identity in [identities.author, identities.assistant] {
            XCTAssertEqual(
                segmentURLs(docId: doc.docId)
                    .filter { $0.lastPathComponent.contains(identity.slug.raw) }
                    .count,
                1,
                "open-time maintenance must rotate \(identity.deviceId)'s tail too")
        }
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
        let doc = try await makeDoc(device: DeviceIdentity.author.deviceId)
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

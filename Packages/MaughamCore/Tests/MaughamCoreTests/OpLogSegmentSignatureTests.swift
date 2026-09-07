import CryptoKit
import XCTest
@testable import MaughamCore

/// A sealed segment is immutable bytes with a digest already inside it. The
/// signature beside it says WHO those bytes belong to — one signature over the
/// 32 digest bytes, written when the segment is minted, read once and then
/// remembered so a segment is never walked twice.
@MainActor
final class OpLogSegmentSignatureTests: XCTestCase {

    private let docId = "doc-sig"
    private var projectURL: URL!
    private var identity: DeviceIdentity!
    private var state: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        identity = .softwareForTesting()
        state = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private func op(_ opId: String, next: String) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: identity.deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: next)],
           sequence: ["aaaa"])
    }

    /// Fill this device's tail past the seal threshold, then rotate it.
    private func sealATail(
        store: OpLogStore, opIds: [String]
    ) async throws -> URL {
        let filler = String(repeating: "x", count: 2_000)
        for id in opIds { try await store.append(op(id, next: filler)) }
        let sealed = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: identity.slug, threshold: 1_000)
        return try XCTUnwrap(sealed)
    }

    private func makeStore(_ id: DeviceIdentity? = nil) -> OpLogStore {
        OpLogStore(projectURL: projectURL, identity: id ?? identity, state: state)
    }

    // MARK: - (a) the sidecar itself

    /// Minting a segment mints its signature: `<name>.mzseg.sig`, over the
    /// segment's own 32 digest bytes, under this device's key.
    func test_sealingATailWritesASignatureBesideTheSegment() async throws {
        let store = makeStore()
        let segURL = try await sealATail(store: store, opIds: ["01A", "01B"])
        let sigURL = OpLogStore.segmentSignatureURL(for: segURL)
        XCTAssertEqual(sigURL.lastPathComponent, segURL.lastPathComponent + ".sig")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sigURL.path))

        let signature = try XCTUnwrap(SegmentSignature.read(at: sigURL))
        let digest = try XCTUnwrap(
            OpLogSegment.decodeVerifying(try Data(contentsOf: segURL)).digest)
        XCTAssertEqual(signature.digest, digest)
        XCTAssertEqual(signature.key, identity.fingerprint)
        XCTAssertTrue(signature.verifies(), "the signature is over the digest's own bytes")
    }

    /// The sidecar is not an op-log file. If the glob ever listed it, every
    /// reader would try to parse a signature as history.
    func test_opLogFileURLsNeverListsTheSidecar() async throws {
        let store = makeStore()
        let segURL = try await sealATail(store: store, opIds: ["01A", "01B"])
        let listed = OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL)
            .map(\.lastPathComponent)
        XCTAssertTrue(listed.contains(segURL.lastPathComponent))
        XCTAssertFalse(
            listed.contains(OpLogStore.segmentSignatureURL(for: segURL).lastPathComponent),
            "the signature is derived metadata, never a file of history")
    }

    /// A device with no key seals its tail all the same and signs nothing. That
    /// segment is unsigned history — honest, and not a refusal.
    func test_anUnsignedDeviceWritesNoSidecarAndItsSegmentIsUnsignedHistory() async throws {
        let unsigned = DeviceIdentity.unsignedForTesting(token: Data("token".utf8))
        let store = OpLogStore(projectURL: projectURL, identity: unsigned, state: state)
        let filler = String(repeating: "x", count: 2_000)
        for id in ["01A", "01B"] {
            try await store.append(Op(
                opId: id, docId: docId, at: Date(timeIntervalSince1970: 0),
                device: unsigned.deviceId, session: "s", kind: .typingBurst,
                changes: [.init(paragraphId: "aaaa", prior: nil, next: filler)],
                sequence: ["aaaa"]))
        }
        let sealedURL = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: unsigned.slug, threshold: 1_000)
        let segURL = try XCTUnwrap(sealedURL)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: OpLogStore.segmentSignatureURL(for: segURL).path))

        let loaded = try await store.loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["01A", "01B"])
        let file = try XCTUnwrap(loaded.provenance.files.first {
            $0.name == segURL.lastPathComponent
        })
        XCTAssertTrue(file.isSealedSegment)
        XCTAssertEqual(file.segmentVerified, false)
        XCTAssertEqual(file.verified, 0)
    }

    // MARK: - (b) the signature settles the segment

    /// A signed segment from this device's own key loads as verified, and the
    /// device remembers the digest so the next load skips the walk entirely.
    func test_aSignedSegmentIsVerifiedAndRemembered() async throws {
        let store = makeStore()
        let segURL = try await sealATail(store: store, opIds: ["01A", "01B"])
        let digest = try XCTUnwrap(
            OpLogSegment.decodeVerifying(try Data(contentsOf: segURL)).digest)
        XCTAssertFalse(state.isVerified(segmentDigest: digest))

        let loaded = try await store.loadDiagnosed(docId: docId)
        let file = try XCTUnwrap(loaded.provenance.files.first {
            $0.name == segURL.lastPathComponent
        })
        XCTAssertEqual(file.segmentVerified, true)
        XCTAssertGreaterThan(file.verified, 0)
        XCTAssertEqual(file.unsignedHistory, 0)
        XCTAssertTrue(state.isVerified(segmentDigest: digest),
                      "a segment is read once and remembered")
    }

    /// A signature from a key this device does not trust settles nothing. The
    /// bytes are still applied — P1 has no registry — but they are history.
    func test_aForeignSignatureLeavesTheSegmentAsUnsignedHistory() async throws {
        let store = makeStore()
        let segURL = try await sealATail(store: store, opIds: ["01A", "01B"])

        let stranger = makeStore(.softwareForTesting())
        let loaded = try await stranger.loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["01A", "01B"])
        let file = try XCTUnwrap(loaded.provenance.files.first {
            $0.name == segURL.lastPathComponent
        })
        XCTAssertEqual(file.segmentVerified, false)
        XCTAssertEqual(file.verified, 0)
    }

    /// The signature is over the DIGEST. Change the bytes and the digest moves,
    /// so the old signature no longer names these bytes — and the segment falls
    /// back to being walked, unverified.
    func test_aChangedSegmentIsNoLongerNamedByItsSignature() async throws {
        let store = makeStore()
        let segURL = try await sealATail(store: store, opIds: ["01A", "01B"])
        let originalDigest = try XCTUnwrap(
            OpLogSegment.decodeVerifying(try Data(contentsOf: segURL)).digest)

        // Re-mint the container over different content, leaving the signature
        // where it is: a whole, self-consistent segment whose digest has moved.
        let replacement = try await OpLogStore.loadFileDiagnosed(url: segURL, presenter: nil)
        var jsonl = Data()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        encoder.outputFormatting = [.sortedKeys]
        for op in replacement.ops {
            jsonl.append(try encoder.encode(op))
            jsonl.append(0x0A)
        }
        jsonl.append(try encoder.encode(op("09Z", next: "inserted")))
        jsonl.append(0x0A)
        try OpLogSegment.encode(jsonl: jsonl).write(to: segURL)

        let movedDigest = try XCTUnwrap(
            OpLogSegment.decodeVerifying(try Data(contentsOf: segURL)).digest)
        XCTAssertNotEqual(movedDigest, originalDigest)
        let signature = try XCTUnwrap(
            SegmentSignature.read(at: OpLogStore.segmentSignatureURL(for: segURL)))
        XCTAssertNotEqual(signature.digest, movedDigest,
                          "the signature names bytes that are no longer there")

        let loaded = try await store.loadDiagnosed(docId: docId)
        let file = try XCTUnwrap(loaded.provenance.files.first {
            $0.name == segURL.lastPathComponent
        })
        XCTAssertEqual(file.segmentVerified, false)
        XCTAssertEqual(file.verified, 0)
        XCTAssertFalse(state.isVerified(segmentDigest: movedDigest))
    }

    /// A corrupt container is still the checksum's business, and the reader
    /// still says so — a signature beside it changes nothing about that.
    func test_aCorruptSegmentIsStillReportedCorrupt() async throws {
        let store = makeStore()
        let segURL = try await sealATail(store: store, opIds: ["01A", "01B"])
        var bytes = try Data(contentsOf: segURL)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: segURL)

        let loaded = try await store.loadDiagnosed(docId: docId)
        XCTAssertFalse(loaded.diagnostics.skipped.isEmpty,
                       "a damaged segment is named, not silently dropped")
        let file = try XCTUnwrap(loaded.provenance.files.first {
            $0.name == segURL.lastPathComponent
        })
        XCTAssertEqual(file.segmentVerified, false)
    }

    /// A failed sidecar write must never cost the seal — the tail still goes,
    /// and a segment with no signature is unsigned history.
    func test_aFailedSidecarWriteStillSealsTheTail() async throws {
        let store = makeStore()
        let filler = String(repeating: "x", count: 2_000)
        for id in ["01A", "01B"] { try await store.append(op(id, next: filler)) }
        let tailURL = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: identity.slug, in: projectURL)

        // A directory where the sidecar wants to be: the write cannot succeed.
        let segURL = OpLogStore.segmentFileURL(
            forDocId: docId, deviceSlug: identity.slug, index: 1, in: projectURL)
        try FileManager.default.createDirectory(
            at: OpLogStore.segmentSignatureURL(for: segURL),
            withIntermediateDirectories: true)

        let sealed = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: identity.slug, threshold: 1_000)
        XCTAssertEqual(sealed, segURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tailURL.path),
                       "the tail is still deleted")
        let reloaded = try await store.loadDiagnosed(docId: docId)
        XCTAssertEqual(reloaded.ops.map(\.opId), ["01A", "01B"])
    }
}

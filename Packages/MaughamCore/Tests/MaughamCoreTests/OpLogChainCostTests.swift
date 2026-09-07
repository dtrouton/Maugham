import CryptoKit
import XCTest
@testable import MaughamCore

/// What the verified load COSTS. Two tests with two different jobs: one
/// structural and always on, pinning that a remembered segment is not walked at
/// all; one env-gated fixture that prints real numbers at book scale.
@MainActor
final class OpLogChainCostTests: XCTestCase {

    private let docId = "doc-cost"
    private var projectURL: URL!
    private var identity: DeviceIdentity!
    private var state: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        identity = .softwareForTesting()
        state = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state.json"))
    }

    override func tearDown() async throws {
        OpLogChain.verifyObserverForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func op(_ opId: String, next: String) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: identity.deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: next)],
           sequence: ["aaaa"])
    }

    private func encodedLine(_ op: Op, prev: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        encoder.outputFormatting = [.sortedKeys]
        return OpLogChain.chainedLine(
            elementJSON: try encoder.encode(op), prev: prev)
    }

    // MARK: - (1) structural: a remembered segment is not walked

    /// The whole point of remembering a digest: the second load does not read a
    /// single line of that segment's chain. A counting seam on the verifier is
    /// the only way to see the difference — the ops come out the same either
    /// way, which is exactly why this needs pinning.
    func test_aRememberedSegmentIsNeverWalkedAgain() async throws {
        let store = OpLogStore(projectURL: projectURL, identity: identity, state: state)
        let filler = String(repeating: "x", count: 2_000)
        for id in ["01A", "01B"] { try await store.append(op(id, next: filler)) }
        let sealed = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: identity.slug, threshold: 1_000)
        let segURL = try XCTUnwrap(sealed)
        let digest = try XCTUnwrap(
            OpLogSegment.decodeVerifying(try Data(contentsOf: segURL)).digest)

        // Cold: the sidecar is read and the digest remembered.
        _ = try await store.loadDiagnosed(docId: docId)
        XCTAssertTrue(state.isVerified(segmentDigest: digest))

        // Warm: nothing in this load may reach the verifier.
        nonisolated(unsafe) var calls = 0
        OpLogChain.verifyObserverForTesting = { calls += 1 }
        let warm = try await store.loadDiagnosed(docId: docId)
        OpLogChain.verifyObserverForTesting = nil

        XCTAssertEqual(warm.ops.map(\.opId), ["01A", "01B"])
        XCTAssertEqual(calls, 0, "a remembered segment is not walked")
    }

    /// The converse, so the seam itself is known to work: a segment the device
    /// has never verified IS walked.
    func test_anUnrememberedSegmentIsWalked() async throws {
        let store = OpLogStore(projectURL: projectURL, identity: identity, state: state)
        let filler = String(repeating: "x", count: 2_000)
        for id in ["01A", "01B"] { try await store.append(op(id, next: filler)) }
        let sealed = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: identity.slug, threshold: 1_000)
        XCTAssertNotNil(sealed)

        // A stranger's reader: the sidecar is ours, not theirs, so it settles
        // nothing and the segment has to be read line by line.
        let stranger = OpLogStore(
            projectURL: projectURL, identity: .softwareForTesting(),
            state: OpLogDeviceState(
                fileURL: projectURL.appendingPathComponent("stranger.json")))
        nonisolated(unsafe) var calls = 0
        OpLogChain.verifyObserverForTesting = { calls += 1 }
        _ = try await stranger.loadDiagnosed(docId: docId)
        OpLogChain.verifyObserverForTesting = nil
        XCTAssertGreaterThan(calls, 0)
    }

    // MARK: - (2) the fixture

    /// 50,000 chained op lines, sealed every 100, in seven segments plus a
    /// tail — a long novel's whole history. Prints a cold verified load, a warm
    /// one, and the control (the same bytes parsed with no verification at all).
    /// Asserts nothing about time: the numbers go in the handoff.
    func test_fixture_fiftyThousandChainedLines() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAUGHAM_PERF_FIXTURE"] == "1",
            "perf fixture: run with MAUGHAM_PERF_FIXTURE=1")

        let totalLines = 50_000
        let sealEvery = 100
        let segments = 7
        let perSegment = totalLines / (segments + 1)
        // ~719 B mean, matching the spike's measured shape.
        let body = String(repeating: "y", count: 560)

        var index = 0
        func nextOpId() -> String {
            index += 1
            return String(format: "OP%08d", index)
        }

        /// One run of chained lines plus its seals, as JSONL bytes.
        func chainedRun(count: Int) throws -> Data {
            var out = Data()
            var head = OpLogChain.genesis
            var sinceSeal = 0
            for _ in 0..<count {
                let line = try encodedLine(op(nextOpId(), next: body), prev: head)
                out.append(line)
                out.append(0x0A)
                head = OpLogChain.lineHash(line)
                sinceSeal += 1
                if sinceSeal == sealEvery {
                    let seal = try OpLogChain.Seal.line(
                        head: head, identity: identity, at: Date(timeIntervalSince1970: 0))
                    out.append(seal)
                    out.append(0x0A)
                    head = OpLogChain.lineHash(seal)
                    sinceSeal = 0
                }
            }
            return out
        }

        var totalBytes = 0
        for segment in 1...segments {
            let jsonl = try chainedRun(count: perSegment)
            totalBytes += jsonl.count
            let segURL = OpLogStore.segmentFileURL(
                forDocId: docId, deviceSlug: identity.slug, index: segment, in: projectURL)
            try OpLogSegment.encode(jsonl: jsonl).write(to: segURL)
            try OpLogStore.writeSegmentSignature(
                for: segURL, jsonl: jsonl, identity: identity)
        }
        let tail = try chainedRun(count: totalLines - perSegment * segments)
        totalBytes += tail.count
        try tail.write(to: OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: identity.slug, in: projectURL))

        func seconds(_ work: () async throws -> Int) async rethrows -> (Double, Int) {
            let started = DispatchTime.now().uptimeNanoseconds
            let count = try await work()
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            return (Double(elapsed) / 1_000_000, count)
        }

        let cold = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("cold.json"))
        let coldStore = OpLogStore(projectURL: projectURL, identity: identity, state: cold)
        let (coldMs, coldOps) = try await seconds {
            try await coldStore.loadDiagnosed(docId: docId).ops.count
        }
        let (warmMs, warmOps) = try await seconds {
            try await coldStore.loadDiagnosed(docId: docId).ops.count
        }
        // The control: the same bytes, parsed, with no chain walked at all.
        let (controlMs, controlOps) = try await seconds {
            var n = 0
            for url in OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL) {
                let bytes = try Data(contentsOf: url)
                let jsonl = url.pathExtension == OpLogSegment.fileExtension
                    ? (OpLogSegment.decodeVerifying(bytes).jsonl ?? Data())
                    : bytes
                n += JSONLAppendStore<Op>.parse(
                    bytes: jsonl, dedupKey: { $0.opId },
                    sortedBy: { $0.opId < $1.opId }).elements.count
            }
            return n
        }

        print("""

        === OpLogChainCostTests fixture ===
        lines: \(index) op lines, seals every \(sealEvery), \
        \(segments) sealed segments + tail, \(totalBytes) JSONL bytes
        cold verified load (empty state):  \(String(format: "%.1f", coldMs)) ms  (\(coldOps) ops)
        warm verified load (state warm):   \(String(format: "%.1f", warmMs)) ms  (\(warmOps) ops)
        control (parse only, no verify):   \(String(format: "%.1f", controlMs)) ms  (\(controlOps) ops)

        """)
        XCTAssertEqual(coldOps, totalLines)
        XCTAssertEqual(warmOps, totalLines)
    }
}

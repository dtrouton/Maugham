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

        // Cold: the sidecar is read and the digest remembered — in THIS state
        // instance, under the exact string `decodeVerifying` reports. Both
        // halves matter: a warm load that consulted a different state, or asked
        // for a differently-spelled digest, would silently walk the segment
        // again and every assertion about the ops would still pass.
        _ = try await store.loadDiagnosed(docId: docId)
        XCTAssertTrue(state.isVerified(segmentDigest: digest),
                      "the cold load remembered this digest in this state")

        // Warm: the SAME store, so the same state instance, and nothing in this
        // load may reach the verifier.
        nonisolated(unsafe) var calls = 0
        OpLogChain.verifyObserverForTesting = { calls += 1 }
        let warm = try await store.loadDiagnosed(docId: docId)
        OpLogChain.verifyObserverForTesting = nil

        XCTAssertTrue(store.deviceState === state,
                      "the warm load consults the state the cold load wrote")
        XCTAssertEqual(warm.ops.map(\.opId), ["01A", "01B"])
        XCTAssertEqual(calls, 0, "a remembered segment is not walked")
        let file = try XCTUnwrap(warm.provenance.files.first {
            $0.name == segURL.lastPathComponent
        })
        XCTAssertEqual(file.segmentVerified, true,
                       "and it took the cached branch, not a fresh sidecar read")
    }

    /// The cache key is a string, and three places have to spell it the same
    /// way: what the container reports, what the sidecar names, and what the
    /// device remembers. One lowercase-hex spelling, pinned against a digest
    /// whose value is known independently of this codebase.
    func test_everyDigestIsTheSameLowercaseHexString() async throws {
        XCTAssertEqual(
            OpLogSegment.hex(Data(SHA256.hash(data: Data()))),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "the one hex spelling: lowercase, two characters a byte")

        let store = OpLogStore(projectURL: projectURL, identity: identity, state: state)
        let filler = String(repeating: "x", count: 2_000)
        for id in ["01A", "01B"] { try await store.append(op(id, next: filler)) }
        let sealed = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: identity.slug, threshold: 1_000)
        let segURL = try XCTUnwrap(sealed)

        let reported = try XCTUnwrap(
            OpLogSegment.decodeVerifying(try Data(contentsOf: segURL)).digest)
        let signature = try XCTUnwrap(
            SegmentSignature.read(at: OpLogStore.segmentSignatureURL(for: segURL)))
        XCTAssertEqual(signature.digest, reported,
                       "the sidecar names the digest the container reports")
        XCTAssertEqual(reported.count, 64)
        XCTAssertTrue(reported.allSatisfy { $0.isHexDigit && !$0.isUppercase })

        XCTAssertFalse(state.isVerified(segmentDigest: reported))
        _ = try await store.loadDiagnosed(docId: docId)
        XCTAssertTrue(state.isVerified(segmentDigest: reported),
                      "and that is the string the device remembers")
        XCTAssertFalse(state.isVerified(segmentDigest: reported.uppercased()),
                       "one spelling, not two")
    }

    /// A CHECK is not a load. `ProjectIntegrity.check` classifies with the nil
    /// defaults — no key, no remembered head — so its picture of a file is
    /// strictly weaker than the load's, and a forensic record written from it
    /// would file the load's event under the check's weaker reading. It reports;
    /// the load records.
    func test_anIntegrityCheckSetsNothingAside() async throws {
        // A foreign device's file whose chain breaks.
        let stranger = DeviceIdentity.softwareForTesting()
        let strangerStore = OpLogStore(
            projectURL: projectURL, identity: stranger,
            state: OpLogDeviceState(
                fileURL: projectURL.appendingPathComponent("stranger.json")))
        try await strangerStore.append(Op(
            opId: "01A", docId: docId, at: Date(timeIntervalSince1970: 0),
            device: stranger.deviceId, session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "aaaa", prior: nil, next: "kept")],
            sequence: ["aaaa"]))
        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: stranger.slug, in: projectURL)
        var bytes = try Data(contentsOf: url)
        bytes.append(try encodedLine(
            op("09Z", next: "broken"), prev: String(repeating: "0", count: 64)))
        bytes.append(0x0A)
        try bytes.write(to: url)

        func records() -> [QuarantineRecord] {
            OpLogQuarantine.records(forDocId: docId, in: projectURL)
                .filter { $0.kind == .lines }
        }

        _ = try await ProjectIntegrity.check(projectURL: projectURL)
        XCTAssertTrue(records().isEmpty,
                      "a check reports; it does not set anything aside")

        let store = OpLogStore(projectURL: projectURL, identity: identity, state: state)
        let loaded = try await store.loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["01A"])
        XCTAssertEqual(records().count, 1, "the load records, exactly once")
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

        /// Best of three. A single six-second reading swings by a few hundred
        /// milliseconds on a machine with anything else running, which is the
        /// same size as the whole quantity being measured — so the minimum,
        /// which is the run that was least interrupted, is the honest one.
        func best(_ work: () async throws -> Int) async rethrows -> (Double, Int) {
            var lowest = Double.greatestFiniteMagnitude
            var count = 0
            for _ in 0..<3 {
                let started = DispatchTime.now().uptimeNanoseconds
                count = try await work()
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                lowest = min(lowest, Double(elapsed) / 1_000_000)
            }
            return (lowest, count)
        }

        // Cold: a state that has never seen this project. A FRESH one each
        // time, so the reading can be a best-of-three like the others rather
        // than one noisy sample — a load is what warms a state, so repeating it
        // on the same state would be measuring the warm path.
        nonisolated(unsafe) var round = 0
        let (coldMs, coldOps) = try await best {
            round += 1
            let cold = OpLogDeviceState(
                fileURL: projectURL.appendingPathComponent("cold-\(round).json"))
            return try await OpLogStore(
                projectURL: projectURL, identity: identity, state: cold)
                .loadDiagnosed(docId: docId).ops.count
        }
        let warm = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("warm.json"))
        let warmStore = OpLogStore(projectURL: projectURL, identity: identity, state: warm)
        _ = try await warmStore.loadDiagnosed(docId: docId)
        let (warmMs, warmOps) = try await best {
            try await warmStore.loadDiagnosed(docId: docId).ops.count
        }
        // The control: the same bytes, through the same parser and the same
        // merge, with no chain walked and no signature checked. It has to
        // include `mergeSortedDedup` — the load path sorts 50,000 ops and the
        // control would otherwise be timing a different job.
        let (controlMs, controlOps) = await best {
            var all: [Op] = []
            for url in OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL) {
                // Coordinated, like the real read — otherwise the delta is
                // partly `NSFileCoordinator` and not the chain at all.
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinationError: NSError?
                var read: Data?
                coordinator.coordinate(readingItemAt: url, options: [],
                                       error: &coordinationError) { readable in
                    read = try? Data(contentsOf: readable)
                }
                let bytes = read ?? Data()
                let jsonl = url.pathExtension == OpLogSegment.fileExtension
                    ? (OpLogSegment.decodeVerifying(bytes).jsonl ?? Data())
                    : bytes
                all.append(contentsOf: JSONLAppendStore<Op>.parse(
                    bytes: jsonl, dedupKey: { $0.opId },
                    sortedBy: { $0.opId < $1.opId }).elements)
            }
            return OpLogStore.mergeSortedDedup(all).count
        }

        // The chain's own work, timed directly. The end-to-end deltas above sit
        // inside a six-second load and are smaller than its run-to-run spread,
        // so THIS is the number that means something: everything the verified
        // load does that the control does not.
        var chainMs = Double.greatestFiniteMagnitude
        var signatureMs = Double.greatestFiniteMagnitude
        let tailBytes = try Data(contentsOf: OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: identity.slug, in: projectURL))
        let fingerprint = identity.fingerprint
        for _ in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = OpLogChain.verify(
                bytes: tailBytes, trusted: { $0 == fingerprint }, rememberedHead: nil)
            let t1 = DispatchTime.now().uptimeNanoseconds
            chainMs = min(chainMs, Double(t1 - t0) / 1_000_000)

            let t2 = DispatchTime.now().uptimeNanoseconds
            for segment in 1...segments {
                let segURL = OpLogStore.segmentFileURL(
                    forDocId: docId, deviceSlug: identity.slug,
                    index: segment, in: projectURL)
                _ = SegmentSignature.read(
                    at: OpLogStore.segmentSignatureURL(for: segURL))?.verifies()
            }
            let t3 = DispatchTime.now().uptimeNanoseconds
            signatureMs = min(signatureMs, Double(t3 - t2) / 1_000_000)
        }

        print("""

        === OpLogChainCostTests fixture ===
        lines: \(index) op lines, seals every \(sealEvery), \
        \(segments) sealed segments + tail, \(totalBytes) JSONL bytes
        cold verified load (empty state):  \(String(format: "%.1f", coldMs)) ms  (\(coldOps) ops)
        warm verified load (state warm):   \(String(format: "%.1f", warmMs)) ms  (\(warmOps) ops)
        control (parse only, no verify):   \(String(format: "%.1f", controlMs)) ms  (\(controlOps) ops)

        Do not read the three end-to-end figures as a measurement of the chain.
        All three are dominated by `JSONDecoder` over 42 MB, they swing by more
        than a second on a machine with anything else running, and the quantity
        of interest is under a tenth of that swing. They are here to show the
        shape — the load is parsing, and always was — not to be subtracted.

        What the two lines below measure is the chain itself, and they are
        stable. The verify CACHE is deliberately not visible in them either:
        every segment in this fixture has a signature beside it, so the COLD
        load already settles each one whole and skips its walk, and the cache
        saves the sidecar read and the P256 check rather than a walk. The load a
        cache rescues is one whose segments were sealed before the sidecar
        existed, and that load takes the keyless-walk arm.

        Note also that this tail is eight times the size a real one reaches: a
        tail is rotated into a segment past `segmentSealThreshold` (512 KB, some
        600 lines), so a real load walks a small fraction of what is timed here.
        chain walk over the live tail:              \(String(format: "%.1f", chainMs)) ms
        \(segments) sidecar reads + signature checks:      \(String(format: "%.1f", signatureMs)) ms

        """)
        XCTAssertEqual(coldOps, totalLines)
        XCTAssertEqual(warmOps, totalLines)
    }
}

import XCTest
@testable import MaughamCore

/// The interval seal inside `OpLogStore.append` is maintenance (#75): the op
/// is durable before it runs, so a failure must not fail the append.
@MainActor
final class IntervalSealTests: XCTestCase {

    private struct SealBoom: Error {}
    private let docId = "doc-interval"
    private var projectURL: URL!
    private var identities: LocalIdentities!
    private var store: OpLogStore!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("interval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        identities = .softwareForTesting()
        let state = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("device-state.json"),
            identity: identities.author.fingerprint)
        store = OpLogStore(projectURL: projectURL, identities: identities, state: state)
    }

    private func op(_ n: Int) -> Op {
        Op(opId: "op-\(String(format: "%04d", n))", docId: docId,
           at: Date(timeIntervalSince1970: 0), device: identities.author.deviceId,
           session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: "s\(n)")],
           sequence: ["aaaa"])
    }

    private func lastLineIsSeal() throws -> Bool {
        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: identities.author.slug, in: projectURL)
        let last = try Data(contentsOf: url)
            .split(separator: 0x0A, omittingEmptySubsequences: true).last
        return OpLogChain.isSealLine(Data(try XCTUnwrap(last)))
    }

    func test_aFailedIntervalSealDoesNotFailTheAppendThatLanded() async throws {
        for n in 1..<OpLogStore.chainSealInterval { try await store.append(op(n)) }
        store.sealFailureForTesting = SealBoom()
        try await store.append(op(OpLogStore.chainSealInterval))
        let loaded = try await store.load(docId: docId)
        XCTAssertEqual(loaded.count, OpLogStore.chainSealInterval)
    }

    func test_aFailedIntervalSealIsRetriedOnTheNextAppend() async throws {
        for n in 1..<OpLogStore.chainSealInterval { try await store.append(op(n)) }
        store.sealFailureForTesting = SealBoom()
        try await store.append(op(OpLogStore.chainSealInterval))
        XCTAssertFalse(try lastLineIsSeal())
        store.sealFailureForTesting = nil
        try await store.append(op(OpLogStore.chainSealInterval + 1))
        XCTAssertTrue(try lastLineIsSeal())
    }
}

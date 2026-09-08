import XCTest
@testable import MaughamCore

/// A device is four writers, and each one signs with its own key.
///
/// P1 gave the device one identity: `append` chained iff `op.device` was that
/// one id, `trusted` was that one fingerprint, and `sealChain` sealed that one
/// file. With the actors (P1b) all three widen to the four local identities —
/// and the widening has to be exact in both directions. An op the assistant
/// wrote must be sealed by the ASSISTANT's key, or the role is back to being a
/// label. A file the translator has not written must cost no seal, or every
/// close spends four enclave signatures to say nothing.
@MainActor
final class ActorSigningTests: XCTestCase {

    private let docId = "doc-actors"
    private var projectURL: URL!
    private var identities: LocalIdentities!
    private var state: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("actors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        identities = .softwareForTesting()
        state = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("device-state.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private func makeStore() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identities: identities, state: state)
    }

    private func fileURL(of identity: DeviceIdentity) -> URL {
        OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: identity.slug, in: projectURL)
    }

    private func op(_ opId: String, by identity: DeviceIdentity,
                    next: String = "a sentence") -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: identity.deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: next)],
           sequence: ["aaaa"])
    }

    private func lines(of url: URL) throws -> [Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Data(contentsOf: url)
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map { Data($0) }
    }

    private func seals(of identity: DeviceIdentity) throws -> [OpLogChain.Seal] {
        try lines(of: fileURL(of: identity)).compactMap(OpLogChain.Seal.parse)
    }

    // MARK: - (a) sealChain covers every local actor, and only what is unsealed

    /// Two actors wrote into this doc, so two files hold unsealed lines, so one
    /// `sealChain` writes two seals — each under the key of the actor whose
    /// file it seals. The two that wrote nothing are not signed for: a device
    /// with four keys must not spend four enclave signatures per close.
    func test_sealChainSealsEveryActorThatWroteAndNoOthers() async throws {
        let store = makeStore()
        try await store.append(op("op-0001", by: identities.author))
        try await store.append(op("op-0002", by: identities.assistant))

        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed, "a doc with unsealed lines seals")

        let authorSeals = try seals(of: identities.author)
        let assistantSeals = try seals(of: identities.assistant)
        XCTAssertEqual(authorSeals.map(\.key), [identities.author.fingerprint],
            "the author's file is sealed by the author's key")
        XCTAssertEqual(assistantSeals.map(\.key), [identities.assistant.fingerprint],
            "the assistant's file is sealed by the ASSISTANT's key — the role is "
            + "in the key, not in a label beside the op")
        XCTAssertTrue(try lines(of: fileURL(of: identities.translator)).isEmpty,
                      "the translator wrote nothing and is not signed for")
        XCTAssertTrue(try lines(of: fileURL(of: identities.maugham)).isEmpty,
                      "nor is Maugham itself")
    }

    /// And the seal is idempotent per file: nothing unsealed, nothing written.
    func test_aSecondSealChainOverTheSameDocWritesNothing() async throws {
        let store = makeStore()
        try await store.append(op("op-0001", by: identities.author))
        try await store.append(op("op-0002", by: identities.assistant))
        _ = try await store.sealChain(docId: docId)

        let again = try await store.sealChain(docId: docId)
        XCTAssertFalse(again, "nothing is unsealed, so nothing is signed")
        XCTAssertEqual(try seals(of: identities.author).count, 1)
        XCTAssertEqual(try seals(of: identities.assistant).count, 1)
    }

    /// A doc only the translator touched seals the translator's file and
    /// nobody else's — the author is not the fallback signer for the device.
    func test_aDocOnlyTheTranslatorWroteIsSealedByTheTranslator() async throws {
        let store = makeStore()
        try await store.append(op("op-0001", by: identities.translator))
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed)

        XCTAssertEqual(try seals(of: identities.translator).map(\.key),
                       [identities.translator.fingerprint])
        XCTAssertTrue(try lines(of: fileURL(of: identities.author)).isEmpty,
                      "the author's file was never created, let alone sealed")
    }

    // MARK: - (b) the segment sidecar is signed by the slug's own actor

    /// `sealTailIfNeeded` takes a slug, and the sidecar it writes must carry
    /// the key of the actor that slug names. Signing every segment with the
    /// author's key would have the read path settle the assistant's segment
    /// under a signature the assistant never made.
    func test_eachActorsSegmentIsSignedByThatActorsKey() async throws {
        let store = makeStore()
        let filler = String(repeating: "x", count: 2_000)
        let actors = [identities.author, identities.assistant]
        for (i, actor) in actors.enumerated() {
            for n in 1...2 {
                try await store.append(
                    op("op-\(i)\(n)", by: actor, next: filler))
            }
        }

        for actor in actors {
            let rotated = try await store.sealTailIfNeeded(
                docId: docId, deviceSlug: actor.slug, threshold: 1_000)
            let segURL = try XCTUnwrap(rotated)
            let signature = try XCTUnwrap(
                SegmentSignature.read(at: OpLogStore.segmentSignatureURL(for: segURL)),
                "every local actor's segment is signed")
            XCTAssertEqual(signature.key, actor.fingerprint)
            XCTAssertTrue(signature.verifies())
        }
    }

    /// A slug naming no local actor gets no sidecar. Nothing on this device
    /// may vouch for another device's bytes.
    func test_aSlugNamingNoLocalActorGetsNoSidecar() async throws {
        let stranger = DeviceIdentity.softwareForTesting(actor: .author)
        let store = makeStore()
        let filler = String(repeating: "x", count: 2_000)
        for n in 1...2 {
            try await store.append(op("op-9\(n)", by: stranger, next: filler))
        }

        let rotated = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: stranger.slug, threshold: 1_000)
        let segURL = try XCTUnwrap(rotated)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: OpLogStore.segmentSignatureURL(for: segURL).path),
            "this device signs only its own actors' segments")
    }

    // MARK: - (c) the per-file seal cadence is the appending actor's

    /// The interval trigger inside `append` seals the file it just appended
    /// to, under that file's own actor — not the author's, and not every
    /// file's.
    func test_theIntervalTriggerSealsTheAppendingActorsOwnFile() async throws {
        let store = makeStore()
        try await store.append(op("op-0000", by: identities.author))
        for i in 1...OpLogStore.chainSealInterval {
            try await store.append(
                op("op-\(String(format: "%04d", i))", by: identities.maugham))
        }

        XCTAssertEqual(try seals(of: identities.maugham).map(\.key),
                       [identities.maugham.fingerprint],
            "the run that crossed the interval was Maugham's own")
        XCTAssertTrue(try seals(of: identities.author).isEmpty,
            "the author's single line is below the interval and is not sealed "
            + "by another actor's cadence")
    }

    // MARK: - (d) naming an actor is what mints it (the C1 rule, on a real store)

    /// The rebalance case, over a device folder nobody has written into.
    ///
    /// A store built on `LocalIdentities.current`'s own shape trusts NOTHING at
    /// construction — that is what keeps the phone to one key. The Maugham
    /// rebalance is the case that shows the other half is intact: the app names
    /// the actor to build the op's device string (`Document+Tasks` reads
    /// `opStore.identities.maugham.deviceId`), which mints the key, and the
    /// append that follows finds it and CHAINS the line rather than writing it
    /// unchained as another device's.
    ///
    /// Chaining, not sealing, is what is asserted: a runner with no Secure
    /// Enclave holds the unsigned token twin, which chains exactly the same and
    /// signs nothing, and this test is about the lookup rather than the key.
    func test_namingAnActorMintsItAndTheAppendThatFollowsIsChained() async throws {
        let keyDir = projectURL.appendingPathComponent("device-keys")
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
        let lazyLocal = LocalIdentities.device(in: keyDir)
        let store = OpLogStore(projectURL: projectURL, identities: lazyLocal, state: state)

        XCTAssertTrue(store.identities.fingerprints.isEmpty,
            "constructing a store mints nothing — the phone's whole protection")

        // The writer's act: the app names the actor it is about to write as.
        let maugham = store.identities.maugham
        try await store.append(op("op-0001", by: maugham))

        XCTAssertEqual(store.identities.fingerprints, [maugham.fingerprint],
            "naming Maugham minted Maugham's key and nobody else's")
        let written = try lines(of: fileURL(of: maugham))
        XCTAssertEqual(written.count, 1)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: written[0]) as? [String: Any])
        XCTAssertNotNil(envelope["prev"],
            "the op named a local actor, so the line is chained rather than "
            + "appended plain as another device's would be")
        XCTAssertFalse(
            DeviceIdentity.hasPersistedIdentity(for: .author, in: keyDir),
            "and the three actors nothing named still have no key")
    }
}

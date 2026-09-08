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
        OpLogChain.verifyObserverForTesting = nil
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

    // MARK: - (c2) the seal reads only what this store wrote (I1)

    /// The burst boundary calls `sealChain(docId:)` on the writer's keystroke
    /// path, and `appendSeal` cannot discover that a file has nothing unsealed
    /// without opening a writing coordination, reading the whole file and
    /// verifying its chain. So on a document Claude has annotated and the
    /// rebalance has touched, a fan-out over four actors was three extra
    /// coordinated acquisitions, three extra whole-file reads and three extra
    /// verifies per burst — while the store's own `linesSinceSeal` counters
    /// already knew the answer for nothing.
    ///
    /// One burst by the author, therefore exactly one verify.
    func test_aSealAfterOneActorsBurstReadsOneFile() async throws {
        let store = makeStore()
        // Four files, all of them sealed, so the only difference between them
        // afterwards is which one this store writes into next.
        for actor in identities.all {
            try await store.append(op("op-a-\(actor.actor.rawValue)", by: actor))
        }
        _ = try await store.sealChain(docId: docId)
        for actor in identities.all {
            XCTAssertEqual(try seals(of: actor).count, 1, "precondition: all four sealed")
        }

        try await store.append(op("op-burst", by: identities.author))

        nonisolated(unsafe) var verifies = 0
        OpLogChain.verifyObserverForTesting = { verifies += 1 }
        let sealed = try await store.sealChain(docId: docId)
        OpLogChain.verifyObserverForTesting = nil

        XCTAssertTrue(sealed, "the author's run is sealed")
        XCTAssertEqual(verifies, 1,
            "a burst reads and verifies the file the burst wrote into, and no "
            + "other — the three actors this store has not written to since "
            + "their last seal are not opened at all")
        XCTAssertEqual(try seals(of: identities.author).count, 2)
        for actor in [identities.assistant, identities.translator, identities.maugham] {
            XCTAssertEqual(try seals(of: actor).count, 1,
                           "\(actor.deviceId) was not sealed again")
        }
    }

    /// And a seal with nothing written since the last one reads nothing at all.
    func test_aSealWithNothingWrittenSinceTheLastOneOpensNoFile() async throws {
        let store = makeStore()
        try await store.append(op("op-0001", by: identities.author))
        _ = try await store.sealChain(docId: docId)

        nonisolated(unsafe) var verifies = 0
        OpLogChain.verifyObserverForTesting = { verifies += 1 }
        let again = try await store.sealChain(docId: docId)
        OpLogChain.verifyObserverForTesting = nil

        XCTAssertFalse(again)
        XCTAssertEqual(verifies, 0,
            "the counter says there is nothing to seal, so nothing is read to "
            + "find that out")
    }

    /// The counter-free door the project-open sweep uses. A fresh store has no
    /// counters, so it names the actor it means — the author, whose
    /// crash-window leftover the sweep exists for — and touches no other file.
    func test_theNamedActorSealIsForAStoreWithNoCounters() async throws {
        let writer = makeStore()
        try await writer.append(op("op-0001", by: identities.author))
        try await writer.append(op("op-0002", by: identities.assistant))

        // A second store over the same project: this is the sweep's position,
        // with everything unsealed and nothing remembered.
        let sweep = makeStore()
        let counterDriven = try await sweep.sealChain(docId: docId)
        XCTAssertFalse(counterDriven,
            "a counter-driven seal from a store that wrote nothing seals nothing")

        nonisolated(unsafe) var verifies = 0
        OpLogChain.verifyObserverForTesting = { verifies += 1 }
        let sealed = try await sweep.sealChain(docId: docId, actor: .author)
        OpLogChain.verifyObserverForTesting = nil

        XCTAssertTrue(sealed)
        XCTAssertEqual(verifies, 1, "the author's file, and only the author's")
        XCTAssertEqual(try seals(of: identities.author).map(\.key),
                       [identities.author.fingerprint])
        XCTAssertTrue(try seals(of: identities.assistant).isEmpty,
            "the assistant's run is left to its own writer's cadence and close")
    }

    /// An actor with no file here is not an error and is not a mint of work:
    /// the sweep asks about every doc it finds, and most docs the assistant
    /// never touched.
    func test_theNamedActorSealAnswersFalseWhenThatActorHasNoFile() async throws {
        let store = makeStore()
        try await store.append(op("op-0001", by: identities.author))
        let sealed = try await store.sealChain(docId: docId, actor: .translator)
        XCTAssertFalse(sealed)
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

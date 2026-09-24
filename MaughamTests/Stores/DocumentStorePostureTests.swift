import XCTest
@testable import Maugham
@testable import MaughamCore

/// **The Mac's one door** (signed op log P3c Task 2): `DocumentStore.posture(forDocId:)`,
/// fresh on every trust change, with the root's cooperative yield and the
/// re-stamp of every open document.
///
/// Both directions, mid-session, in the same window: a demotion arriving while
/// a document is open locks its posture AND its own stamped writes, and the
/// promotion back unlocks both — with no reopen.
@MainActor
final class DocumentStorePostureTests: XCTestCase {

    private var projectURL: URL!
    private var docURL: URL!
    private var identities: LocalIdentities!
    private var roots: [URL] = []

    private static let docId = "doc-test"
    private static let docPath = "manuscript/c1.md"

    override func setUp() async throws {
        let (dir, doc) = try makeTestProject(prefix: "POSTURE", initialMd: "Hello.\n")
        projectURL = dir
        docURL = doc
        roots = [dir]
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    // MARK: - Fixtures

    /// Signing software keys and a private memory for everything this device
    /// remembers, so nothing leaks into this machine's real registry cache.
    private func beASigningMac() {
        identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    /// Another Mac as the book's root, with THIS device admitted by it as an
    /// author of the whole book — `DocumentWaitingTests.makeRoot`'s shape.
    private func makeForeignRoot() throws -> DeviceIdentity {
        let root = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: root.fingerprint, name: "The other Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: root.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1_000)),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: root.fingerprint, label: "Sam", ownName: "The other Mac",
                role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 1_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: identities.author.fingerprint, name: "This Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, identities[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 2_000)),
            signedBy: identities.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: "Denver",
                ownName: "This Mac", role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 2_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        return root
    }

    /// **P3b's `changePermit`, driven through the test root** — the verb the
    /// root's own Mac would press, signed by the root's key, with the mark the
    /// production sweep computes. Then delivered to THIS window through the
    /// presenter's registry route, as iCloud would deliver it.
    private func rootChangesMyPermit(
        to permit: Permit, root: DeviceIdentity, store: DocumentStore
    ) async throws {
        let mark = try OpLogStore.appliedPositions(
            ofDeviceIds: Set(identities.all.map(\.deviceId)),
            in: projectURL,
            trust: try TrustResolution.resolve(
                projectURL: projectURL, identities: identities))
        let rootCache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("root-cache.json"),
            identity: root.fingerprint)
        _ = try RegistryAdmission.changePermit(
            person: identities.author.fingerprint,
            role: permit.wireRole, scope: permit.wireScope, pieces: permit.wirePieces,
            mark: mark,
            // Every stream here is signed, so the photograph of the unsigned
            // ones is empty; a narrowing still has to carry one (P3b).
            unsigned: permit.narrows ? .nothingApplied : nil,
            in: projectURL, by: root, cache: rootCache)
        store.presenterDidChangeSubitem(at: RegistryWriter.url(
            .people, fingerprint: identities.author.fingerprint, in: projectURL))
        await store.flushRegistryChangeForTesting()
        await store.postureSettled()
    }

    private func openDocument(in store: DocumentStore) async throws -> Document {
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        store.register(document: doc, for: Self.docPath)
        return doc
    }

    // MARK: - Both directions, mid-session, no reopen

    func test_aDemotionLocksTheOpenDocumentAndAPromotionUnlocksIt() async throws {
        beASigningMac()
        let root = try makeForeignRoot()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument(in: store)
        await store.postureSettled()

        XCTAssertTrue(store.posture(forDocId: Self.docId).allows(.writeText),
                      "precondition: an author of the whole book")
        XCTAssertTrue(doc.mayWriteThePendingFile)
        let before = store.postureEpoch

        // Demotion.
        try await rootChangesMyPermit(to: .reviewer, root: root, store: store)

        XCTAssertGreaterThan(store.postureEpoch, before, "the trust change bumped the epoch")
        let demoted = store.posture(forDocId: Self.docId)
        XCTAssertFalse(demoted.allows(.writeText))
        XCTAssertTrue(demoted.allows(.annotate), "the reviewer row stays")
        XCTAssertEqual(demoted.reason, .reviewer)
        XCTAssertFalse(doc.mayWriteThePendingFile,
                       "the open document was re-stamped, so its own writes stop too")
        XCTAssertFalse(store.posture(forPath: Self.docPath).allows(.writeText),
                       "the path door answers through the same door")

        // Promotion back, same document object, no reopen.
        let demotedEpoch = store.postureEpoch
        try await rootChangesMyPermit(to: .bookAuthor, root: root, store: store)

        XCTAssertGreaterThan(store.postureEpoch, demotedEpoch)
        XCTAssertTrue(store.posture(forDocId: Self.docId).allows(.writeText),
                      "the promotion unlocked the posture")
        XCTAssertNil(store.posture(forDocId: Self.docId).reason)
        XCTAssertTrue(doc.mayWriteThePendingFile, "and the open document's own writes")
        XCTAssertIdentical(store.document(forDocId: Self.docId), doc, "no reopen")
        await doc.close()
    }

    /// **The promotion half on its own**: a posture first asked while demoted
    /// is not the answer after the root widens her again — the epoch's cache
    /// clear is what makes the second question a fresh one.
    func test_aPromotionUnlocksAPostureFirstAskedWhileDemoted() async throws {
        beASigningMac()
        let root = try makeForeignRoot()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument(in: store)
        try await rootChangesMyPermit(to: .reviewer, root: root, store: store)

        XCTAssertFalse(store.posture(forDocId: Self.docId).allows(.writeText),
                       "precondition: asked, and answered, while demoted")
        XCTAssertFalse(doc.mayWriteThePendingFile)

        try await rootChangesMyPermit(to: .bookAuthor, root: root, store: store)

        XCTAssertTrue(store.posture(forDocId: Self.docId).allows(.writeText),
                      "the promotion is not read through a stale posture")
        XCTAssertTrue(doc.mayWriteThePendingFile)
        await doc.close()
    }

    /// **The P3a carry**: `close()`'s failed-flush arm declines to re-persist on
    /// a not-permitted device, and a clean close declines to clear the pending
    /// file. Neither may cost a keystroke typed while the device WAS permitted.
    func test_aDemotedDocumentsCloseLosesNoKeystrokeTypedWhilePermitted() async throws {
        beASigningMac()
        let root = try makeForeignRoot()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument(in: store)
        await store.postureSettled()

        let phrase = "Typed while she could."
        doc.setFullText(doc.displayText + "\n\n" + phrase)

        try await rootChangesMyPermit(to: .reviewer, root: root, store: store)
        XCTAssertFalse(doc.mayWriteThePendingFile, "precondition: demoted and re-stamped")

        await doc.close()

        XCTAssertTrue(try filesUnderMaugham().contains { $0.contains(phrase) },
                      "the keystrokes reached disk — in the op log or the pending file")
    }

    // MARK: - The root's cooperative yield

    func test_theRootYieldsOnAPieceNamedForSomebodyElseUntilItOverrides() async throws {
        beASigningMac()
        let store = try await DocumentStore.open(url: projectURL)  // this Mac roots the empty book
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces([Self.docId])))
        await store.postureSettled()

        let yielding = store.posture(forDocId: Self.docId)
        XCTAssertEqual(yielding.yieldingTo, "Sam")
        XCTAssertEqual(yielding.reason, .yielding(to: "Sam"))
        XCTAssertFalse(yielding.allows(.writeText))
        XCTAssertTrue(yielding.allows(.annotate))
        XCTAssertNil(store.posture(forDocId: Self.docId, as: .translator).yieldingTo,
                     "only the writer's hand is yielded")

        // Edit Anyway, in this window.
        store.overrideYield(docId: Self.docId)
        let overridden = store.posture(forDocId: Self.docId)
        XCTAssertNil(overridden.yieldingTo)
        XCTAssertTrue(overridden.allows(.writeText))

        // A second window on the same book still yields.
        let second = try await DocumentStore.open(url: projectURL)
        await second.postureSettled()
        XCTAssertEqual(second.posture(forDocId: Self.docId).yieldingTo, "Sam")
        XCTAssertNil(store.posture(forDocId: Self.docId).yieldingTo,
                     "and the first keeps its override")
    }

    /// **A co-writing whole-book author is never yielded to** — her scope names
    /// no piece, so she is on no piece's row.
    func test_theRootDoesNotYieldToAWholeBookCoAuthor() async throws {
        beASigningMac()
        let store = try await DocumentStore.open(url: projectURL)
        let ada = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: ada.author.fingerprint, label: "Ada", ownName: "Ada’s Mac",
            permit: .bookAuthor)
        await store.postureSettled()

        let posture = store.posture(forDocId: Self.docId)
        XCTAssertNil(posture.yieldingTo)
        XCTAssertTrue(posture.allows(.writeText))
        XCTAssertEqual(posture, .author)
    }

    /// And a whole-book author who is NOT the root yields to nobody, even on a
    /// piece somebody else's scope names.
    func test_aWholeBookAuthorWhoIsNotTheRootYieldsToNobody() async throws {
        beASigningMac()
        let root = try makeForeignRoot()
        let ren = LocalIdentities.softwareForTesting()
        try RegistryWriter.write(
            PersonRecord(
                person: ren.author.fingerprint, label: "Ren", ownName: "Ren’s Mac",
                role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 2_500),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        // The root names this piece as Ren's — through the verb, so the
        // TIMELINE says so (tripwire 43: a record's field is not read).
        _ = try RegistryAdmission.changePermit(
            person: ren.author.fingerprint,
            role: Permit.authorRole, scope: Permit.piecesScope, pieces: [Self.docId],
            mark: .nothingApplied, unsigned: .nothingApplied,
            in: projectURL, by: root,
            cache: RegistryCache(
                fileURL: projectURL.appendingPathComponent("root-cache.json"),
                identity: root.fingerprint))
        XCTAssertEqual(
            PieceWriters.resolve(
                registry: try RegistryReader.load(projectURL: projectURL),
                table: try TrustResolution.resolve(
                    projectURL: projectURL, identities: identities),
                pieces: [PermitControl.Piece(id: Self.docId, title: "C1")]
            ).writers(of: Self.docId), ["Ren"],
            "precondition: the book names Ren on this piece")
        let store = try await DocumentStore.open(url: projectURL)
        await store.postureSettled()

        XCTAssertNil(store.posture(forDocId: Self.docId).yieldingTo)
        XCTAssertTrue(store.posture(forDocId: Self.docId).allows(.writeText))
    }

    // MARK: - Neutral where nothing is registered

    /// **A book with no register answers `.author` and reads nothing** — no
    /// registry resolution, so this device's identity is never even asked for
    /// (`RegistryCacheTests.test_aProjectWithNoRegistryNeverReachesForTheEnclave`'s
    /// shape).
    func test_aBookWithNoRegistryIsTheAuthorAndResolvesNothing() async throws {
        // Unsigned keys, so the open writes no record and the book stays
        // registerless.
        identities = LocalIdentities(
            author: .unsignedForTesting(token: Data("posture-author".utf8)),
            assistant: .unsignedForTesting(token: Data("posture-assistant".utf8), actor: .assistant),
            translator: .unsignedForTesting(token: Data("posture-translator".utf8), actor: .translator),
            maugham: .unsignedForTesting(token: Data("posture-maugham".utf8), actor: .maugham))
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        let counter = IdentityCounter()
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            resolvingIdentity: counter.next)

        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument(in: store)
        await store.postureSettled()

        XCTAssertFalse(TrustResolution.hasRegistry(in: projectURL), "precondition")
        XCTAssertEqual(store.posture(forDocId: Self.docId), .author)
        XCTAssertEqual(store.posture(forDocId: "doc-not-open"), .author)
        XCTAssertEqual(counter.count, 0, "no registry was resolved, anywhere")
        await doc.close()
    }

    // MARK: - Manifest adoption

    func test_adoptingAnotherDevicesManifestBumpsTheEpoch() async throws {
        beASigningMac()
        let store = try await DocumentStore.open(url: projectURL)
        await store.postureSettled()
        let before = store.postureEpoch

        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.title = "Retitled elsewhere"
        try ProjectManifest.makeEncoder().encode(manifest).write(to: manifestURL)
        store.presenterDidChangeSubitem(at: manifestURL)

        XCTAssertGreaterThan(store.postureEpoch, before,
                             "a class can change when a manifest arrives")
        await store.postureSettled()
        XCTAssertEqual(store.posture(forDocId: Self.docId), .author)
    }

    // MARK: - Helpers

    private func filesUnderMaugham() throws -> [String] {
        let dir = projectURL.appendingPathComponent(".maugham")
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            if let text = try? String(contentsOf: url, encoding: .utf8) { out.append(text) }
        }
        return out
    }

    private final class IdentityCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return asked
        }
        func next() -> String {
            lock.lock(); defer { lock.unlock() }
            asked += 1
            return "device-under-test"
        }
    }
}

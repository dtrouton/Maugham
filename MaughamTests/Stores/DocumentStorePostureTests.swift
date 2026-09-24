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

    // MARK: - The refresh's ordering and its pre-warm (P3c Task 10, rulings AD and AG)

    /// The root's demotion WRITTEN to the folder and not delivered — the state
    /// between a record landing and the presenter's debounced invalidation.
    private func rootWritesMyPermitWithoutTelling(
        to permit: Permit, root: DeviceIdentity
    ) throws {
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
            unsigned: permit.narrows ? .nothingApplied : nil,
            in: projectURL, by: root, cache: rootCache)
    }

    /// The same builder the door asks, over the same inputs — what a miss
    /// would build right now. A test is outside the posture census.
    private func freshPosture(_ docId: String) -> Posture {
        let url = projectURL!
        return Posture(Document.makeLoadOpStore(projectURL: url, presenter: nil)
            .localWritePermit(as: .author) { Document.documentClass(forDocId: docId, in: url) })
    }

    /// Every main-actor turn during a refresh, seen from outside.
    @MainActor private final class TurnLog {
        struct Sample: Hashable { let epoch: Int; let locked: Bool; let drawnLocked: Bool }
        var samples: [Sample] = []
        var running = true
    }

    /// **The re-stamp, the drawn answer and the epoch bump are ONE main-actor
    /// turn** (ruling AG; the whole-branch fix wave's Minor 1). The Document's
    /// stamp decides whether its own writes are made; the drawing door is what
    /// a surface draws; the epoch re-renders the editor's membrane. If any turn
    /// sees one moved and not the others, a keystroke in that turn reaches an
    /// editor drawn one way over a Document answering the other.
    ///
    /// **How ordering is observed with no window:** a sampler task on the main
    /// actor records `(postureEpoch, !mayWriteThePendingFile, the DRAWN
    /// answer)` and yields,
    /// over and over, for the whole of the demotion's delivery and refresh.
    /// Every `await` the refresh makes — the off-main warm, each pre-warm
    /// chunk — lets the sampler run, so any turn boundary between the
    /// re-stamp and the bump is SEEN as a sample. The invariants: no epoch is
    /// ever observed with the document both unlocked and locked, and in EVERY
    /// sample the drawing door answers what the Document's stamp answers — a
    /// pre-warm that published its answers before the re-stamp (or a table
    /// published before it) draws the new answer over the old stamp. Enough
    /// keys are asked first that the pre-warm yields several times.
    func test_theRestampAndTheBumpAreOneTurn() async throws {
        beASigningMac()
        let root = try makeForeignRoot()
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await openDocument(in: store)
        await store.postureSettled()
        for i in 0..<48 { _ = store.posture(forDocId: "doc-queue-\(i)") }
        _ = store.posture(forDocId: Self.docId)
        XCTAssertTrue(doc.mayWriteThePendingFile, "precondition: an author of the whole book")

        let log = TurnLog()
        let sampler = Task { @MainActor in
            while log.running {
                log.samples.append(.init(
                    epoch: store.postureEpoch, locked: !doc.mayWriteThePendingFile,
                    drawnLocked: !store.posture(forDocId: Self.docId).allows(.writeText)))
                await Task.yield()
            }
        }
        try await rootChangesMyPermit(to: .reviewer, root: root, store: store)
        log.running = false
        await sampler.value
        log.samples.append(.init(
            epoch: store.postureEpoch, locked: !doc.mayWriteThePendingFile,
            drawnLocked: !store.posture(forDocId: Self.docId).allows(.writeText)))

        XCTAssertTrue(log.samples.contains { !$0.locked }, "the sampler saw the unlocked state")
        XCTAssertTrue(log.samples.contains { $0.locked }, "and the demotion land")
        let unlockedEpochs = Set(log.samples.filter { !$0.locked }.map(\.epoch))
        let lockedEpochs = Set(log.samples.filter { $0.locked }.map(\.epoch))
        XCTAssertTrue(unlockedEpochs.isDisjoint(with: lockedEpochs),
            "a turn saw the Document's stamp and the epoch disagree — the re-stamp "
            + "and the bump were split across turns. Unlocked at \(unlockedEpochs.sorted()), "
            + "locked at \(lockedEpochs.sorted()), over \(log.samples.count) samples")
        let split = log.samples.filter { $0.locked != $0.drawnLocked }
        XCTAssertTrue(split.isEmpty,
            "a turn drew one answer over a Document stamped with the other — the "
            + "pre-warm's answers were published before the re-stamp. Split samples: "
            + "\(split.count) of \(log.samples.count)")
        await doc.close()
    }

    /// **The pre-warm re-answers every asked key, cached or not** (ruling AG).
    /// A drawing miss after a record landed, but before the debounced
    /// invalidation, schedules a refresh that no clearing bump preceded; a
    /// cached answer taken off the table it replaces must not survive it.
    func test_aRefreshNoInvalidationPrecededStillReanswersACachedKey() async throws {
        beASigningMac()
        let root = try makeForeignRoot()
        let store = try await DocumentStore.open(url: projectURL)
        await store.postureSettled()
        XCTAssertTrue(store.posture(forDocId: Self.docId).allows(.writeText),
                      "precondition: cached as an author of the whole book")

        try rootWritesMyPermitWithoutTelling(to: .reviewer, root: root)
        // A miss about a document never asked finds the folder moved and
        // schedules the refresh; the cached key is not touched by it.
        _ = store.posture(forDocId: "doc-never-asked")
        await store.postureSettled()

        XCTAssertFalse(store.posture(forDocId: Self.docId).allows(.writeText),
            "the refresh re-answered the cached key off the table it warmed")
        XCTAssertEqual(store.posture(forDocId: Self.docId), freshPosture(Self.docId))
    }

    /// **After a trust change, the redraw of what the window asked is all
    /// cache hits, and every pre-warmed answer is the one a fresh build gives**
    /// (ruling AD's pre-warm, gated — `PostureMissCostTests` only measures it).
    func test_theRedrawAfterATrustChangeIsAllHitsAndEveryHitIsFresh() async throws {
        beASigningMac()
        let root = try makeForeignRoot()
        let store = try await DocumentStore.open(url: projectURL)
        await store.postureSettled()
        let ids = [Self.docId] + (0..<40).map { "doc-queue-\($0)" }
        for id in ids { _ = store.posture(forDocId: id) }

        try await rootChangesMyPermit(to: .reviewer, root: root, store: store)

        let before = store.postureBuilderCallsForTesting
        let redrawn = ids.map { store.posture(forDocId: $0) }
        XCTAssertEqual(store.postureBuilderCallsForTesting, before,
                       "the redraw after the refresh asked the builder nothing")
        for (id, answer) in zip(ids, redrawn) {
            XCTAssertEqual(answer, freshPosture(id), "\(id)'s pre-warmed answer is fresh")
            XCTAssertFalse(answer.allows(.writeText))
        }
    }

    // MARK: - Open statement editors are re-stamped too (whole-branch fix wave, I1)

    /// **A statement editor's `Document` is in no `DocumentStore` registry**,
    /// so the re-stamp walks the project store's open statements as well:
    /// a demotion stops its own writes (the pending file) as it locks the
    /// surface, and the promotion restores both — no reopen.
    func test_anOpenStatementDocumentIsRestampedInBothDirections() async throws {
        beASigningMac()
        let root = try makeForeignRoot()
        let statementId = "stmt-c1-intent"
        let statementPath = "intent/c1.md"
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.statements = [Statement(
            id: statementId, kind: .intent, scope: .document(Self.docId),
            path: statementPath)]
        try ProjectManifest.makeEncoder().encode(manifest).write(to: manifestURL)
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("intent"), withIntermediateDirectories: true)
        try "What this chapter is for.\n".write(
            to: projectURL.appendingPathComponent(statementPath),
            atomically: true, encoding: .utf8)

        let store = try await DocumentStore.open(url: projectURL)
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        let statement = try await Document.load(
            url: projectURL.appendingPathComponent(statementPath),
            actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        projectStore.noteStatementDocumentOpened(statement, id: statementId)
        await store.postureSettled()
        XCTAssertTrue(statement.mayWriteThePendingFile, "precondition: hers to write")

        try await rootChangesMyPermit(to: .reviewer, root: root, store: store)
        XCTAssertFalse(store.posture(forDocId: statementId).allows(.editStatement),
                       "the surface locks")
        XCTAssertFalse(statement.mayWriteThePendingFile,
                       "and the open statement Document was re-stamped with it")

        try await rootChangesMyPermit(to: .bookAuthor, root: root, store: store)
        XCTAssertTrue(statement.mayWriteThePendingFile, "the promotion restores both")
        XCTAssertTrue(store.posture(forDocId: statementId).allows(.editStatement))
        await statement.close()
    }

    // MARK: - The standing line's History clause is observed (whole-branch fix wave, Minor 6)

    /// The review read `Document.ownLinesKeptInHistory` as a non-observed
    /// stored Int. `Document` is `@Observable` and the property is not
    /// `@ObservationIgnored`, so a view that reads it in `body` re-renders the
    /// moment a re-read changes it. Pinned, so the premise is a test rather
    /// than a sentence.
    func test_theKeptInHistoryCountIsObservedByAViewThatReadsIt() async throws {
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let changed = Box(false)
        withObservationTracking {
            _ = doc.ownLinesKeptInHistory
        } onChange: {
            changed.value = true
        }
        doc.ownLinesKeptInHistory = 3
        XCTAssertTrue(changed.value, "a read of the count is an observed read")
        await doc.close()
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
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

    /// **Ruling H**: a yielded piece's own statement yields with it — the
    /// yield keys on the piece a document's class is about. And Edit Anyway
    /// on the statement lifts the piece.
    func test_aYieldedPiecesStatementYieldsToo() async throws {
        beASigningMac()
        let statementId = "stmt-c1-intent"
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.statements = [Statement(
            id: statementId, kind: .intent, scope: .document(Self.docId),
            path: "intent/c1.md")]
        try ProjectManifest.makeEncoder().encode(manifest).write(to: manifestURL)

        let store = try await DocumentStore.open(url: projectURL)
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces([Self.docId])))
        await store.postureSettled()

        XCTAssertEqual(store.posture(forDocId: statementId).yieldingTo, "Sam")
        XCTAssertFalse(store.posture(forDocId: statementId).allows(.editStatement))
        XCTAssertNil(store.posture(forDocId: "doc-someone-elses").yieldingTo,
                     "a piece nobody's scope names yields to nobody")

        store.overrideYield(docId: statementId)
        XCTAssertNil(store.posture(forDocId: Self.docId).yieldingTo,
                     "the override is the piece's")
        XCTAssertNil(store.posture(forDocId: statementId).yieldingTo)
    }

    /// **Never to this device's own person** (m6): the root's own second Mac,
    /// admitted as an author of this piece under the writer's own label.
    func test_theRootNeverYieldsToItsOwnLabel() async throws {
        beASigningMac()
        let store = try await DocumentStore.open(url: projectURL)
        let myLabel = try XCTUnwrap(
            try RegistryReader.load(projectURL: projectURL)
                .person(identities.author.fingerprint)?.label)
        let secondMac = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: secondMac.author.fingerprint, label: myLabel,
            ownName: "My other Mac", permit: .author(.pieces([Self.docId])))
        await store.postureSettled()

        XCTAssertNil(store.posture(forDocId: Self.docId).yieldingTo)
        XCTAssertTrue(store.posture(forDocId: Self.docId).allows(.writeText))
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

    // MARK: - The door never fails open about a document it has never answered (fix round 1, I1)

    /// A reviewer's Mac, as the root has made it: a foreign root, this device
    /// admitted and then narrowed to the reviewer row — all BEFORE the window
    /// opens.
    private func beAReviewersMac() async throws -> DeviceIdentity {
        beASigningMac()
        let root = try makeForeignRoot()
        let rootCache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("root-cache.json"),
            identity: root.fingerprint)
        _ = try RegistryAdmission.changePermit(
            person: identities.author.fingerprint,
            role: Permit.reviewerRole, scope: Permit.bookScope, pieces: [],
            mark: .nothingApplied, unsigned: .nothingApplied,
            in: projectURL, by: root, cache: rootCache)
        return root
    }

    /// **Right after open, about a CLOSED document**: both accessors answer
    /// the reviewer, because `open` waited for the first warm.
    func test_aReviewerAskingAboutAClosedDocumentRightAfterOpenIsAReviewer() async throws {
        _ = try await beAReviewersMac()
        let store = try await DocumentStore.open(url: projectURL)

        let drawn = store.posture(forDocId: Self.docId)
        XCTAssertFalse(drawn.allows(.writeText))
        XCTAssertFalse(drawn.allows(.acceptOrReject))
        XCTAssertTrue(drawn.allows(.annotate))
        XCTAssertEqual(drawn.reason, .reviewer, "a real answer, not a provisional one")

        let settled = await store.settledPosture(forDocId: Self.docId)
        XCTAssertFalse(settled.allows(.writeText))
        XCTAssertEqual(settled.reason, .reviewer)
    }

    /// **After a trust change, about a document never asked**: the drawing
    /// accessor has nothing to go on and the table is cold, and it offers the
    /// reviewer row alone — never the whole book.
    func test_aColdDoorDrawsTheReviewerRowAloneNeverTheWholeBook() async throws {
        _ = try await beAReviewersMac()
        let store = try await DocumentStore.open(url: projectURL)

        store.invalidateTrust()
        let cold = store.posture(forDocId: "doc-never-asked")
        XCTAssertFalse(cold.allows(.writeText), "a cold door does not fail open")
        XCTAssertFalse(cold.allows(.acceptOrReject))
        XCTAssertTrue(cold.allows(.annotate))
        XCTAssertTrue(cold.isSettling)

        let cold2 = store.posture(forDocId: "doc-never-asked", as: .translator)
        XCTAssertFalse(cold2.allows(.translate), "nor for another actor")

        await store.postureSettled()
        XCTAssertEqual(store.posture(forDocId: "doc-never-asked").reason, .reviewer,
                       "and the refresh replaces it with the real answer")
    }

    /// **`settledPosture` never returns a provisional answer** — not even when
    /// the registry moved on disk after the warm and nothing has told the
    /// window yet.
    func test_settledPostureWarmsAgainWhenTheFolderMovedUnderIt() async throws {
        let root = try await beAReviewersMac()
        let store = try await DocumentStore.open(url: projectURL)

        // A record lands with no presenter callback: the signature moves.
        let stranger = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: stranger.fingerprint, name: "A third Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: stranger.fingerprint],
                madeAt: Date(timeIntervalSince1970: 4_000)),
            signedBy: stranger, in: projectURL)
        _ = root
        // Deliberately NOT asked through the drawing accessor first: its cold
        // miss schedules a refresh, and `settledPosture` would then be saved by
        // the wait alone rather than by its own re-warm.

        let settled = await store.settledPosture(forDocId: "doc-fresh")
        XCTAssertFalse(settled.isSettling)
        XCTAssertEqual(settled.reason, .reviewer)
        XCTAssertFalse(settled.allows(.writeText))
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

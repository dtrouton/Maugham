import XCTest
@testable import Maugham
@testable import MaughamCore

/// **A narrowed book on disk, and a window on it** (signed op log P3c Task 3) —
/// `DocumentStorePostureTests`' fixtures, shared by the standing line's suite
/// and the membrane's (`ReviewModeMembraneTests`' posture half).
///
/// Another Mac is the book's root and has admitted THIS device, as an author of
/// the whole book; `changeMyPermit` is the verb the root's own Mac would press,
/// delivered to the window through the presenter's registry route.
@MainActor
final class PostureFixture {
    static let docId = "doc-test"
    static let docPath = "manuscript/c1.md"
    static let projectStatementId = "stmt-proj-intent"
    static let pieceStatementId = "stmt-c1-intent"

    let projectURL: URL
    let docURL: URL
    private(set) var identities: LocalIdentities!
    private(set) var root: DeviceIdentity?

    init() throws {
        let (dir, doc) = try makeTestProject(prefix: "POSTURE-T3", initialMd: "Hello.\n")
        projectURL = dir
        docURL = doc
    }

    func tearDown() {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    /// Signing software keys and a private memory for everything this device
    /// remembers.
    func beASigningMac() {
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

    /// Two statements in the manifest: the project's intent, and the piece's.
    func addStatements() throws {
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.statements = [
            Statement(id: Self.projectStatementId, kind: .intent, scope: .project,
                      path: "intent.md"),
            Statement(id: Self.pieceStatementId, kind: .intent,
                      scope: .document(Self.docId), path: "intent/c1.md"),
        ]
        try ProjectManifest.makeEncoder().encode(manifest).write(to: manifestURL)
    }

    /// Another Mac as the book's root ("Sam"), with this device admitted by it
    /// as an author of the whole book ("Denver").
    func makeForeignRoot() throws {
        let root = DeviceIdentity.softwareForTesting()
        self.root = root
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
    }

    /// The root changes this device's permit — before any window is open
    /// (`store` nil), or delivered to an open one as iCloud would.
    func changeMyPermit(
        to permit: Permit, store: DocumentStore?, reachingBackToTheStart: Bool = false,
        role: String? = nil
    ) async throws {
        guard let root else { return XCTFail("no root") }
        // `reachingBackToTheStart`: a mark of nothing applied, so every line
        // she already wrote is judged under the NEW permit — the smoke's own
        // shape, her prose set aside by a demotion that did not see it.
        let mark = reachingBackToTheStart ? PermitMark.nothingApplied : try OpLogStore.appliedPositions(
            ofDeviceIds: Set(identities.all.map(\.deviceId)),
            in: projectURL,
            trust: try TrustResolution.resolve(
                projectURL: projectURL, identities: identities))
        let rootCache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("root-cache.json"),
            identity: root.fingerprint)
        _ = try RegistryAdmission.changePermit(
            person: identities.author.fingerprint,
            role: role ?? permit.wireRole, scope: permit.wireScope, pieces: permit.wirePieces,
            mark: mark,
            unsigned: permit.narrows ? .nothingApplied : nil,
            in: projectURL, by: root, cache: rootCache)
        guard let store else { return }
        store.presenterDidChangeSubitem(at: RegistryWriter.url(
            .people, fingerprint: identities.author.fingerprint, in: projectURL))
        await store.flushRegistryChangeForTesting()
        await store.postureSettled()
    }

    /// A window on a book this device already holds `permit` in.
    func openAs(_ permit: Permit, statements: Bool = false) async throws -> DocumentStore {
        beASigningMac()
        if statements { try addStatements() }
        try makeForeignRoot()
        if permit != .bookAuthor { try await changeMyPermit(to: permit, store: nil) }
        let store = try await DocumentStore.open(url: projectURL)
        await store.postureSettled()
        return store
    }

    /// Every line of every op-log file this book holds, in any stream.
    func opLineCount() throws -> Int {
        let dir = projectURL.appendingPathComponent(".maugham/ops")
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var lines = 0
        for case let url as URL in walker {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            lines += text.split(separator: "\n", omittingEmptySubsequences: true).count
        }
        return lines
    }

    func checkpointCount() async -> Int {
        await CheckpointStore(projectURL: projectURL).load().checkpoints.count
    }
}

/// **The standing line** (P3c Task 3): one sentence per `Posture.Reason`, nothing
/// where there is no reason, and the root's Edit Anyway through the door. Plus
/// ⌘S's door (plan ruling R5), counted through `CheckpointCapture.run`
/// directly — never through a mounted keystroke (tripwire 33).
@MainActor
final class PostureStandingLineTests: XCTestCase {

    private var fixture: PostureFixture!

    override func setUp() async throws {
        fixture = try PostureFixture()
    }

    override func tearDown() async throws {
        fixture.tearDown()
        fixture = nil
    }

    private func permit(_ permit: Permit, _ cls: DocumentClass) -> LocalWritePermit {
        LocalWritePermit(permit: permit, actor: .author, documentClass: cls)
    }

    // MARK: - The sentences

    func test_everyReasonHasItsOneSentence() {
        let reviewer = PostureStandingLine.line(
            for: Posture(permit(.reviewer, .piece("d"))), title: "Chapter 3", docId: "d")
        XCTAssertEqual(reviewer?.kind, .reviewer)
        XCTAssertEqual(reviewer?.sentence(root: "Sam"),
                       "You’re reviewing this book — your notes reach Sam; the text is theirs.")
        XCTAssertEqual(reviewer?.sentence(root: nil),
                       "You’re reviewing this book — your notes reach the book’s author; "
                       + "the text is theirs.",
                       "a root not yet read is named by what it is")
        XCTAssertEqual(reviewer?.offersEditAnyway, false)

        let notMine = PostureStandingLine.line(
            for: Posture(permit(.author(.pieces(["a"])), .piece("d"))),
            title: "Chapter 3", docId: "d")
        XCTAssertEqual(notMine?.sentence(root: "Sam"),
                       "“Chapter 3” isn’t one of your pieces — you can leave notes.")
        XCTAssertEqual(notMine?.offersEditAnyway, false)

        let yielding = PostureStandingLine.line(
            for: Posture(.unrestricted, yieldingTo: "Sam"), title: "Chapter 3", docId: "d")
        XCTAssertEqual(yielding?.sentence(root: nil), "This is Sam’s piece.")
        XCTAssertEqual(yielding?.offersEditAnyway, true, "the one reason she can lift")
        XCTAssertEqual(yielding?.docId, "d")

        let unreadable = PostureStandingLine.line(
            for: Posture(permit(.unjudgeable(raw: "editor"), .piece("d"))),
            title: "Chapter 3", docId: "d")
        XCTAssertEqual(unreadable?.sentence(root: "Sam"),
                       "This Mac can’t read the permission it was given — "
                       + "update Maugham to write here.")
        XCTAssertEqual(unreadable?.offersEditAnyway, false)
    }

    /// Nothing to name: her own words, her own piece (restricted — she may not
    /// start a piece — and still nothing to say, ruling E), and `settling`,
    /// whose answer is on its way.
    func test_noReasonDrawsNoLine() {
        XCTAssertNil(PostureStandingLine.line(
            for: Posture(.unrestricted), title: "C", docId: "d"))
        let ownPiece = Posture(permit(.author(.pieces(["d"])), .piece("d")))
        XCTAssertTrue(ownPiece.isRestricted, "precondition: restricted")
        XCTAssertNil(PostureStandingLine.line(for: ownPiece, title: "C", docId: "d"),
                     "restricted, but the words she is looking at are hers")
        XCTAssertNil(PostureStandingLine.line(for: .settling, title: "C", docId: "d"),
                     "nothing is decided yet, so nothing is named")
    }

    // MARK: - Both directions, through the door

    func test_aReviewersLineAppearsAndAPromotionTakesItAway() async throws {
        let store = try await fixture.openAs(.reviewer)
        let demoted = PostureStandingLine.line(
            for: store.posture(forDocId: PostureFixture.docId), title: "C1",
            docId: PostureFixture.docId)
        XCTAssertEqual(demoted?.kind, .reviewer)

        let label = await PostureStandingLine.rootLabel(projectURL: fixture.projectURL)
        XCTAssertEqual(label, "Sam", "the reviewer's sentence names the root, read off-main")

        try await fixture.changeMyPermit(to: .bookAuthor, store: store)
        XCTAssertNil(PostureStandingLine.line(
            for: store.posture(forDocId: PostureFixture.docId), title: "C1",
            docId: PostureFixture.docId), "promoted mid-session: the line is gone")
    }

    func test_aPiecesAuthorOutsideHerPiecesIsToldSo() async throws {
        let store = try await fixture.openAs(.author(.pieces(["elsewhere"])))
        XCTAssertEqual(PostureStandingLine.line(
            for: store.posture(forDocId: PostureFixture.docId), title: "C1",
            docId: PostureFixture.docId)?.kind, .notYourPiece(title: "C1"))
    }

    /// The root on Sam's piece: the line offers Edit Anyway, and pressing it —
    /// `overrideYield`, the verb the button calls — unlocks and takes the line
    /// away.
    func test_theRootsEditAnywayLiftsTheLineAndTheLock() async throws {
        fixture.beASigningMac()
        let store = try await DocumentStore.open(url: fixture.projectURL)  // roots the book
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces([PostureFixture.docId])))
        await store.postureSettled()

        let yielding = store.posture(forDocId: PostureFixture.docId)
        let line = try XCTUnwrap(PostureStandingLine.line(
            for: yielding, title: "C1", docId: PostureFixture.docId))
        XCTAssertEqual(line.kind, .yielding(to: "Sam"))
        XCTAssertTrue(line.offersEditAnyway)
        XCTAssertTrue(EditorControlMirror.membrane(
            posture: yielding, manualReview: false, shareIsReadOnly: false).lockEditing)

        store.overrideYield(docId: line.docId)

        let after = store.posture(forDocId: PostureFixture.docId)
        XCTAssertNil(PostureStandingLine.line(for: after, title: "C1", docId: line.docId))
        XCTAssertFalse(EditorControlMirror.membrane(
            posture: after, manualReview: false, shareIsReadOnly: false).lockEditing)
    }

    // MARK: - Her own lines, kept in History (controller ruling K)

    /// The clause is decided from the COUNT, never from the reason: with no
    /// reason at all it is still said, and with a reason it rides beside it.
    func test_theClauseFollowsTheCountWhateverTheReason() {
        let author = PostureStandingLine.line(
            for: Posture(.unrestricted), title: "C", docId: "d", ownLinesKeptInHistory: 2)
        XCTAssertNil(author?.kind, "her words are hers again")
        XCTAssertEqual(author?.keptInHistory, true, "and some of them are still in History")
        XCTAssertNil(author?.sentence(root: nil))
        XCTAssertEqual(PostureStandingLine.keptInHistoryClause,
                       "Some of what you wrote here is kept in History.")

        let reviewer = PostureStandingLine.line(
            for: Posture(permit(.reviewer, .piece("d"))), title: "C", docId: "d",
            ownLinesKeptInHistory: 1)
        XCTAssertEqual(reviewer?.kind, .reviewer)
        XCTAssertEqual(reviewer?.keptInHistory, true)

        XCTAssertNil(PostureStandingLine.line(
            for: Posture(.unrestricted), title: "C", docId: "d", ownLinesKeptInHistory: 0))
        XCTAssertEqual(PostureStandingLine.line(
            for: Posture(permit(.reviewer, .piece("d"))), title: "C", docId: "d")?
            .keptInHistory, false)
    }

    /// Her own prose, typed as the book's author into THIS device's author
    /// file, then set aside by a demotion that reaches back past it: the load
    /// counts it on the document, and the line says so beside the reviewer's
    /// sentence.
    func test_herOwnSetAsideProseIsCountedOnTheDocument() async throws {
        fixture.beASigningMac()
        try fixture.makeForeignRoot()
        let store = try await DocumentStore.open(url: fixture.projectURL)
        let doc = try await Document.load(
            url: fixture.docURL, actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        doc.setFullText(doc.displayText + "\n\nHer own sentence.")
        try await doc.flushBurstNow()
        XCTAssertEqual(doc.ownLinesKeptInHistory, 0, "precondition: nothing set aside")
        await doc.close()

        try await fixture.changeMyPermit(
            to: .reviewer, store: store, reachingBackToTheStart: true)

        let reloaded = try await Document.load(
            url: fixture.docURL, actor: .author, session: "s2", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        XCTAssertGreaterThan(reloaded.ownLinesKeptInHistory, 0,
                             "her own set-aside lines are counted")
        XCTAssertEqual(reloaded.ownLinesKeptInHistory,
                       reloaded.provenance?.ownLinesKeptInHistory)
        // The same real files, read as ANOTHER device's: not hers.
        let files = try XCTUnwrap(reloaded.provenance?.files)
        XCTAssertEqual(OpLogProvenance(files: files, ownStreams: ["author-somebody-else"])
            .ownLinesKeptInHistory, 0, "the same lines in another device's file are not hers")
        let line = PostureStandingLine.line(
            for: store.posture(forDocId: PostureFixture.docId), title: "C1",
            docId: PostureFixture.docId,
            ownLinesKeptInHistory: reloaded.ownLinesKeptInHistory)
        XCTAssertEqual(line?.kind, .reviewer)
        XCTAssertEqual(line?.keptInHistory, true)
        await reloaded.close()
    }

    /// Her own prose HELD rather than set aside — a permit this build cannot
    /// read — is kept in History too.
    func test_herOwnHeldProseIsCountedOnTheDocument() async throws {
        fixture.beASigningMac()
        try fixture.makeForeignRoot()
        let store = try await DocumentStore.open(url: fixture.projectURL)
        let doc = try await Document.load(
            url: fixture.docURL, actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        doc.setFullText(doc.displayText + "\n\nHer own sentence.")
        try await doc.flushBurstNow()
        await doc.close()

        try await fixture.changeMyPermit(
            to: .reviewer, store: store, reachingBackToTheStart: true,
            role: "editor")  // a rung a later build invented

        let reloaded = try await Document.load(
            url: fixture.docURL, actor: .author, session: "s2", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        XCTAssertGreaterThan(reloaded.provenance?.pendingLines ?? 0, 0,
                             "precondition: her lines are held, not set aside")
        XCTAssertGreaterThan(reloaded.ownLinesKeptInHistory, 0,
                             "her own held lines are counted")
        await reloaded.close()
    }

    // MARK: - ⌘S (plan ruling R5)

    private func checkpoint(
        _ store: DocumentStore, label: String? = nil
    ) async throws -> Checkpoint {
        try await CheckpointCapture.run(
            projectURL: fixture.projectURL,
            activeDocId: PostureFixture.docId,
            allDocIds: [PostureFixture.docId],
            device: "m", session: "s", label: label,
            posture: { await store.settledPosture(forDocId: $0) })
    }

    func test_aReviewersCheckpointWritesNoOpAndNoEntry() async throws {
        let store = try await fixture.openAs(.reviewer)
        let opsBefore = try fixture.opLineCount()
        let entriesBefore = await fixture.checkpointCount()

        do {
            _ = try await checkpoint(store)
            XCTFail("a reviewer's checkpoint was taken")
        } catch let refusal as CheckpointRefusal {
            XCTAssertEqual(refusal, .notYourText)
        }

        XCTAssertEqual(try fixture.opLineCount(), opsBefore, "no new op in any stream")
        let entriesAfter = await fixture.checkpointCount()
        XCTAssertEqual(entriesAfter, entriesBefore, "and no checkpoint entry")
    }

    func test_anAuthorsCheckpointWritesItsOpAndItsEntry() async throws {
        let store = try await fixture.openAs(.bookAuthor)
        let opsBefore = try fixture.opLineCount()
        let entriesBefore = await fixture.checkpointCount()

        _ = try await checkpoint(store)

        XCTAssertEqual(try fixture.opLineCount(), opsBefore + 1, "the breadcrumb op")
        let entriesAfter = await fixture.checkpointCount()
        XCTAssertEqual(entriesAfter, entriesBefore + 1, "and the entry")
    }

    /// **⇧⌘S's Confirm after a demotion** (fix round 1): the sheet opened
    /// while she could; by Confirm she cannot. Nothing is written and the
    /// flash still fires, as ⌘S's does. And an author's Confirm flashes with
    /// its entry.
    func test_theLabelledConfirmFlashesOverARefusalAndWritesNothing() async throws {
        let store = try await fixture.openAs(.reviewer)
        let opsBefore = try fixture.opLineCount()
        let entriesBefore = await fixture.checkpointCount()
        var flashes = 0
        await CheckpointFlashDecision.labelled(
            "Before the cut", projectURL: fixture.projectURL,
            activeDocId: PostureFixture.docId, allDocIds: [PostureFixture.docId],
            device: "m", session: "s", activeDocument: nil,
            posture: { await store.settledPosture(forDocId: $0) },
            flash: { flashes += 1 })
        XCTAssertEqual(flashes, 1, "the flash survives the refusal")
        XCTAssertEqual(try fixture.opLineCount(), opsBefore)
        let entriesAfter = await fixture.checkpointCount()
        XCTAssertEqual(entriesAfter, entriesBefore, "and nothing was written")

        try await fixture.changeMyPermit(to: .bookAuthor, store: store)
        await CheckpointFlashDecision.labelled(
            "After", projectURL: fixture.projectURL,
            activeDocId: PostureFixture.docId, allDocIds: [PostureFixture.docId],
            device: "m", session: "s", activeDocument: nil,
            posture: { await store.settledPosture(forDocId: $0) },
            flash: { flashes += 1 })
        XCTAssertEqual(flashes, 2)
        let entriesPromoted = await fixture.checkpointCount()
        XCTAssertEqual(entriesPromoted, entriesBefore + 1)
    }

    /// ⌘S always flashes: the refusal reaches `onSuccess` and posts no notice.
    /// Any other error keeps today's behaviour — no flash.
    func test_theFlashSurvivesTheRefusalAndOnlyTheRefusal() async {
        var flashes = 0
        await CheckpointFlashDecision.run(
            projectURL: fixture.projectURL, onSuccess: { flashes += 1 }
        ) { throw CheckpointRefusal.notYourText }
        XCTAssertEqual(flashes, 1, "a refused checkpoint still flashes")

        struct Broken: Error {}
        await CheckpointFlashDecision.run(
            projectURL: fixture.projectURL, onSuccess: { flashes += 1 }
        ) { throw Broken() }
        XCTAssertEqual(flashes, 1, "a failed checkpoint does not")
    }
}

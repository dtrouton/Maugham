// MaughamTests/Stores/ClosedHeldLinesTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The admission sheet counts closed documents' held lines** (signed op log
/// P3 plan 3, carry C4).
///
/// Before C4 `DocumentStore.heldLines()` was the open documents plus the inbox,
/// so a stranger who had written only in chapters nobody had opened was never
/// asked about until one of them was opened. These pin the closed-document
/// sweep against a real project, a real registry and a real stranger's sealed
/// file — windowlessly: the post is the wiring, and what the window does with
/// it is `AdmissionDecision`'s, asserted here as a value (tripwire 33).
@MainActor
final class ClosedHeldLinesTests: XCTestCase {

    private var projectURL: URL!
    private var cache: RegistryCache!
    private var memory: AdmissionMemory!
    private var stranger: DeviceIdentity!
    private var strangerState: OpLogDeviceState!
    private var me: LocalIdentities!
    private var posts = 0
    private var token: NSObjectProtocol?

    override func setUp() async throws {
        let (dir, _) = try makeTestProject(prefix: "CLOSEDHELD", initialMd: "Hello.\n")
        projectURL = dir
        stranger = LocalIdentities.softwareForTesting().author
        strangerState = OpLogDeviceState(
            fileURL: dir.appendingPathComponent("stranger-state.json"))
        cache = RegistryCache(
            fileURL: dir.appendingPathComponent("registry-cache.json"),
            identity: "test")
        memory = AdmissionMemory(
            fileURL: dir.appendingPathComponent("admission-memory.json"),
            identity: "test")
        Document.registryCacheForTesting = cache
        Document.admissionMemoryForTesting = memory
        me = LocalIdentities.forTesting(author: .softwareForTesting())
        Document.localIdentitiesForTesting = me
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: dir.appendingPathComponent("op-log-state.json"))
        posts = 0
        token = NotificationCenter.default.addObserver(
            forName: Notification.Name.maughamAdmissionRequested, object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.posts += 1 }
            }
    }

    override func tearDown() async throws {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
        projectURL = nil
    }

    // MARK: - Fixtures

    private let path = "manuscript/c1.md"
    private var docURL: URL { projectURL.appendingPathComponent(path) }
    private let docId = "doc-test"

    /// This Mac opens the book once — writing its root record — loads the
    /// chapter so its opening is minted, and closes everything.
    private func bootstrapTheBookAndCloseIt() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        XCTAssertEqual(doc.docId, docId)
        store.register(document: doc, for: path)
        await doc.close()
        store.unregister(path: path)
        await settle(store)
        await store.close()
    }

    private func writeStrangerFile(opIds: [String]) async throws {
        let store = OpLogStore(
            projectURL: projectURL, identity: stranger, state: strangerState)
        for id in opIds {
            try await store.append(Op(
                opId: id, docId: docId, at: Date(timeIntervalSince1970: 0),
                device: stranger.deviceId, session: "s", kind: .typingBurst,
                changes: [.init(paragraphId: "aaaa", prior: nil, next: id)],
                sequence: ["aaaa"]))
        }
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed)
    }

    /// Every pass queued so far has landed (or declined to).
    private func settle(_ store: DocumentStore) async {
        while true {
            let tail = store.closedSweepTask
            await tail?.value
            if store.closedSweepTask == tail { return }
        }
    }

    /// What the admission sheet's queue would be, from this store's union.
    private func sheet(_ store: DocumentStore) throws -> [AdmissionRequest] {
        let registry = try RegistryReader.load(projectURL: projectURL)
        let union = store.heldLines()
        return AdmissionDecision.requests(
            pending: union.counts, streams: union.streams, registry: registry,
            memory: [:],
            myRoot: AdmissionDecision.askingRoot(
                in: registry, thisDevice: me.author.fingerprint),
            thisDevice: me.author.fingerprint)
    }

    // MARK: - Review Focus 1

    /// **A stranger's lines only in a CLOSED document.** The root opens the
    /// book with nothing open; once the sweep lands the sheet has the right
    /// count — and a second recompute does not ask twice.
    func test_aStrangerWhoWroteOnlyInAClosedChapterIsAskedAboutOnceTheSweepLands() async throws {
        try await bootstrapTheBookAndCloseIt()
        try await writeStrangerFile(opIds: ["02", "03"])
        posts = 0

        let store = try await DocumentStore.open(url: projectURL)
        await settle(store)

        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 2,
                       "two held ops in a chapter nobody has open")
        XCTAssertNotNil(store.heldLines().waiting[stranger.fingerprint]?[docId],
                        "and the sheet can say where they are")
        let queue = try sheet(store)
        XCTAssertEqual(queue.map(\.fingerprint), [stranger.fingerprint])
        XCTAssertEqual(queue.first?.waitingCount, 2)
        XCTAssertEqual(posts, 1, "the landed sweep asks the window once")

        // A second pass over the same bytes finds the same lines.
        store.sweepClosedProvenance()
        await settle(store)
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 2)
        XCTAssertEqual(posts, 1, "and does not ask twice")
        await store.close()
    }

    // MARK: - Review Focus 2

    /// **A document closes after the sweep ran.** Its held lines move from the
    /// open union into the closed map rather than vanishing until the next
    /// sweep.
    func test_closingAChapterAfterTheSweepKeepsItsCount() async throws {
        try await bootstrapTheBookAndCloseIt()
        try await writeStrangerFile(opIds: ["02", "03"])
        let store = try await DocumentStore.open(url: projectURL)
        await settle(store)
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 2)

        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        store.register(document: doc, for: path)
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 2,
                       "open: counted once, from the live load")

        await doc.close()
        store.unregister(path: path)
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 2,
                       "closed again: still counted, with no sweep in between")
        await store.close()
    }

    // MARK: - A trust change re-sweeps

    /// **A revocation's `invalidateTrust` re-sweeps**, so a span it refuses
    /// stops counting as held. The chapter is never opened on this Mac: a
    /// book author's opening would make the stranger's line a refusal from the
    /// start rather than a §4.5 hold.
    func test_aRevocationReSweepsSoARefusedSpanStopsCounting() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        try await writeStrangerFile(opIds: ["02"])
        store.sweepClosedProvenance()
        await settle(store)
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 1,
                       "a stranger's span in a closed piece")

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: PermitControl.permit(for: .somePieces, pieces: ["ch-A"]))
        await settle(store)
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 1,
                       "admitted to other pieces: held, now for the piece question")

        _ = try await store.revoke(person: stranger.fingerprint)
        await settle(store)
        XCTAssertNil(store.heldLinesByDevice()[stranger.fingerprint],
                     "revoked: the span is refused, and nothing is waiting")
        await store.close()
    }

    // MARK: - Neutrality

    /// **An un-narrowed book with no strangers sweeps and posts nothing.**
    func test_aBookWithNobodyWaitingSweepsAndPostsNothing() async throws {
        try await bootstrapTheBookAndCloseIt()
        posts = 0
        let store = try await DocumentStore.open(url: projectURL)
        await settle(store)

        XCTAssertGreaterThan(store.closedPassesLandedForTesting, 0, "it did sweep")
        XCTAssertNotNil(store.closedProvenance[docId], "and read the chapter")
        XCTAssertTrue(store.heldLinesByDevice().isEmpty)
        XCTAssertEqual(posts, 0)
        await store.close()
    }

    // MARK: - Sync into a closed document

    /// **A stranger's file syncing into a chapter nobody has open** is
    /// re-classified through the presenter's own debounce, and asks once.
    func test_aStrangersFileSyncingIntoAClosedChapterIsCounted() async throws {
        try await bootstrapTheBookAndCloseIt()
        let store = try await DocumentStore.open(url: projectURL)
        await settle(store)
        posts = 0
        XCTAssertNil(store.heldLinesByDevice()[stranger.fingerprint])

        try await writeStrangerFile(opIds: ["02", "03"])
        store.presenterDidChangeSubitem(at: OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: stranger.slug, in: projectURL))
        await store.flushPendingAnnounceForTesting()
        await settle(store)

        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 2)
        XCTAssertEqual(posts, 1)
        await store.close()
    }

    // MARK: - A local removal (fix round 1)

    /// The window's two stores, wired both ways as `ProjectWindow.load` wires
    /// them — so the live manifest is the one a local structural verb edits.
    private func openWindow() async throws -> (ProjectStore, DocumentStore) {
        let project = try await ProjectStore.load(from: projectURL)
        let store = try await DocumentStore.open(url: projectURL)
        project.documentStore = store
        store.projectStore = project
        await settle(store)
        return (project, store)
    }

    /// **Trashing an open chapter holding a stranger's span stops its count
    /// at once**, with no pass run — every local removal edits the live
    /// manifest, and the union asks it.
    func test_trashingAnOpenChapterStopsItsCountWithNoSweep() async throws {
        try await bootstrapTheBookAndCloseIt()
        try await writeStrangerFile(opIds: ["02", "03"])
        let (project, store) = try await openWindow()
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        store.register(document: doc, for: path)
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 2)
        let landed = store.closedPassesLandedForTesting

        try await project.deleteStructureItem(id: docId)

        XCTAssertEqual(store.closedPassesLandedForTesting, landed, "no pass ran")
        XCTAssertNil(store.heldLinesByDevice()[stranger.fingerprint],
                     "a trashed chapter's held lines are not waiting in this book")
        XCTAssertNil(store.heldLines().waiting[stranger.fingerprint]?[docId])
        await store.close()
    }

    /// The other direction: a chapter the live manifest still lists keeps its
    /// count after it closes, with the project attached.
    func test_aChapterTheLiveManifestStillListsKeepsItsCount() async throws {
        try await bootstrapTheBookAndCloseIt()
        try await writeStrangerFile(opIds: ["02", "03"])
        let (_, store) = try await openWindow()
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 2,
                       "swept while closed")
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil)
        store.register(document: doc, for: path)
        await doc.close()
        store.unregister(path: path)
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 2,
                       "closed again and still listed: still counted")
        await store.close()
    }

    /// **A piece the manifest no longer lists does not count.**
    func test_aChapterTheManifestNoLongerListsStopsCounting() async throws {
        try await bootstrapTheBookAndCloseIt()
        try await writeStrangerFile(opIds: ["02", "03"])
        let store = try await DocumentStore.open(url: projectURL)
        await settle(store)
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 2)

        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.structure = []
        try ProjectManifest.makeEncoder().encode(manifest).write(to: manifestURL)
        store.sweepClosedProvenance()
        await settle(store)

        XCTAssertNil(store.heldLinesByDevice()[stranger.fingerprint])
        XCTAssertNil(store.closedProvenance[docId])
        await store.close()
    }

    // MARK: - Figures (report plan 6a final review, I-3)

    /// **A stranger's lines in a figure's stream are counted** — swept while
    /// the figure is closed (the manifest's `figures` are swept streams), the
    /// open figure's own provenance while a window holds it, and kept in the
    /// closed map when it closes again.
    func test_aStrangersFigureLinesAreCountedClosedOpenAndClosedAgain() async throws {
        try await bootstrapTheBookAndCloseIt()
        let created = try await ProjectStore.load(from: projectURL)
        let record = try await created.createFigure(kind: .table, name: "t", piece: nil)
        let read = try await FigureDocument.load(
            figureId: record.id, projectURL: projectURL, actor: .author, session: "s",
            presenter: nil, documentStore: nil)
        let key = CellKey(row: try XCTUnwrap(read.state.table.rows.first),
                          column: try XCTUnwrap(read.state.table.columns.first))
        await read.close()

        let theirs = OpLogStore(projectURL: projectURL, identity: stranger, state: strangerState)
        try await theirs.append(Op(
            opId: ULID.generate(), docId: record.id, at: Date(), device: stranger.deviceId,
            session: "s", kind: .figureCellSet, changes: [],
            figure: FigureOpPayload(cell: key, next: Cell(content: .value(.text("x"))), prior: nil)))
        let sealed = try await theirs.sealChain(docId: record.id)
        XCTAssertTrue(sealed)

        let (_, store) = try await openWindow()
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 1,
                       "a closed figure's held line is swept like a chapter's")
        XCTAssertNotNil(store.closedProvenance[record.id])

        let open = try await store.openFigure(figureId: record.id)
        XCTAssertNil(store.closedProvenance[record.id], "an open figure answers for itself")
        XCTAssertGreaterThan(open.provenance?.pendingLines ?? 0, 0)
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 1,
                       "counted once, from the open figure")

        await store.closeFigure(figureId: record.id)
        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 1,
                       "closed again: its provenance moved into the closed map")
        XCTAssertTrue(DocumentStore.sweptDocIds(in: created.manifest).contains(record.id))
        await store.close()
    }

    /// **Residual N-2**: a closed figure whose stream arrived before its
    /// record is re-swept when the record is adopted. While unlisted, the
    /// open sweep skips the stream; adopting the record queues a closed pass
    /// over it, so the stranger's line is counted without waiting for a
    /// reopen, a trust change or another line.
    func test_aClosedFiguresHeldLinesAreCountedWhenItsRecordIsAdopted() async throws {
        try await bootstrapTheBookAndCloseIt()
        let created = try await ProjectStore.load(from: projectURL)
        let record = try await created.createFigure(kind: .table, name: "t", piece: nil)
        let read = try await FigureDocument.load(
            figureId: record.id, projectURL: projectURL, actor: .author, session: "s",
            presenter: nil, documentStore: nil)
        let key = CellKey(row: try XCTUnwrap(read.state.table.rows.first),
                          column: try XCTUnwrap(read.state.table.columns.first))
        await read.close()

        let theirs = OpLogStore(projectURL: projectURL, identity: stranger, state: strangerState)
        try await theirs.append(Op(
            opId: ULID.generate(), docId: record.id, at: Date(), device: stranger.deviceId,
            session: "s", kind: .figureCellSet, changes: [],
            figure: FigureOpPayload(cell: key, next: Cell(content: .value(.text("x"))), prior: nil)))
        let sealed = try await theirs.sealChain(docId: record.id)
        XCTAssertTrue(sealed)

        // The stream is here; the record is not.
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        let withRecord = manifest
        manifest.figures = []
        try ProjectManifest.encodeForDisk(manifest).write(to: manifestURL)

        let (project, store) = try await openWindow()
        XCTAssertNil(store.heldLinesByDevice()[stranger.fingerprint],
                     "precondition: an unlisted figure is not swept")

        // The record arrives: another Mac's manifest, adopted by this window.
        try ProjectManifest.encodeForDisk(withRecord).write(to: manifestURL)
        store.presenterDidChangeSubitem(at: manifestURL)
        XCTAssertEqual(project.manifest.figures?.map(\.id), [record.id],
                       "precondition: the window adopted the record")
        await settle(store)

        XCTAssertEqual(store.heldLinesByDevice()[stranger.fingerprint], 1,
                       "the closed figure was re-swept when its record landed")
        XCTAssertNotNil(store.closedProvenance[record.id])
        await store.close()
    }
}

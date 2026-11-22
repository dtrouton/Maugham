import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Read-through's state, gate and offer** (shell read-through Task 1): the
/// per-device store, what a piece in read-through refuses, and what the window
/// offers for the open piece.
@MainActor
final class ReadThroughStoreTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = TestTemp.root.appendingPathComponent("read-through-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: root.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: root.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: root.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }

    private let mac = DeviceSlug.make(from: "read-through-mac")
    private let otherMac = DeviceSlug.make(from: "read-through-other-mac")
    private let started = Date(timeIntervalSince1970: 1_790_000_000)

    private func projectDir() throws -> URL {
        let dir = root.appendingPathComponent("project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - The store

    func test_theFileIsTheSlugs() {
        let project = URL(fileURLWithPath: "/tmp/project")
        XCTAssertEqual(
            ReadThroughStore.fileURL(projectRoot: project, device: mac).path,
            project.appendingPathComponent(".maugham/read-through.\(mac.raw).json").path)
    }

    /// Begin, quit (the store goes), reopen (a new store on the same file):
    /// the piece is still in read-through, with its start. End forgets it,
    /// across a reopen too.
    func test_beginRemembersAcrossAReopen_andEndForgets() throws {
        let project = try projectDir()
        let first = ReadThroughStore(projectRoot: project, device: mac)
        first.begin("doc-a", at: started)
        XCTAssertEqual(first.pieceIds, ["doc-a"])

        let reopened = ReadThroughStore(projectRoot: project, device: mac)
        XCTAssertEqual(reopened.pieceIds, ["doc-a"], "a ⌘Q right after Start still remembers")
        XCTAssertEqual(reopened.pieces["doc-a"], started)

        reopened.end("doc-a")
        XCTAssertTrue(reopened.pieceIds.isEmpty)
        XCTAssertTrue(ReadThroughStore(projectRoot: project, device: mac).pieceIds.isEmpty,
                      "end is written at once")
    }

    /// A second begin keeps the first start.
    func test_aSecondBeginKeepsTheFirstStart() throws {
        let store = ReadThroughStore(projectRoot: try projectDir(), device: mac)
        store.begin("doc-a", at: started)
        store.begin("doc-a", at: started.addingTimeInterval(60))
        XCTAssertEqual(store.pieces["doc-a"], started)
    }

    /// **It does not sync**: two stores on two slugs never see each other.
    func test_twoSlugsDoNotSeeEachOther() throws {
        let project = try projectDir()
        ReadThroughStore(projectRoot: project, device: mac).begin("doc-a", at: started)
        ReadThroughStore(projectRoot: project, device: otherMac).begin("doc-b", at: started)
        XCTAssertEqual(ReadThroughStore(projectRoot: project, device: mac).pieceIds, ["doc-a"])
        XCTAssertEqual(ReadThroughStore(projectRoot: project, device: otherMac).pieceIds, ["doc-b"])
    }

    /// A corrupt file reads as empty, and is left as it is until a change.
    func test_aCorruptFileReadsEmptyAndIsNotRewrittenUntilAChange() throws {
        let project = try projectDir()
        let url = ReadThroughStore.fileURL(projectRoot: project, device: mac)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)

        let store = ReadThroughStore(projectRoot: project, device: mac)
        XCTAssertTrue(store.pieceIds.isEmpty)
        store.prune(keeping: [])
        store.end("doc-a")
        XCTAssertEqual(try Data(contentsOf: url), garbage, "nothing changed, nothing written")

        store.begin("doc-a", at: started)
        XCTAssertEqual(ReadThroughStore(projectRoot: project, device: mac).pieceIds, ["doc-a"],
                       "the first change rewrites it")
    }

    /// The read-through's checkpoint id is remembered with the piece, across
    /// a reopen; end and prune forget it with the piece; a piece not in
    /// read-through records none.
    func test_theCheckpointIdIsRememberedWithThePiece() throws {
        let project = try projectDir()
        let store = ReadThroughStore(projectRoot: project, device: mac)
        store.recordCheckpoint("cp-0", for: "doc-a")
        XCTAssertFalse(store.hasCheckpoint("doc-a"), "not in read-through, nothing recorded")
        store.begin("doc-a", at: started)
        store.begin("doc-b", at: started)
        XCTAssertFalse(store.hasCheckpoint("doc-a"))
        store.recordCheckpoint("cp-a", for: "doc-a")
        store.recordCheckpoint("cp-b", for: "doc-b")

        let reopened = ReadThroughStore(projectRoot: project, device: mac)
        XCTAssertEqual(reopened.checkpoints, ["doc-a": "cp-a", "doc-b": "cp-b"])
        reopened.end("doc-a")
        reopened.prune(keeping: [])
        XCTAssertTrue(reopened.checkpoints.isEmpty)
        XCTAssertTrue(ReadThroughStore(projectRoot: project, device: mac).checkpoints.isEmpty)
    }

    /// A file written before checkpoints were recorded still reads: its pieces
    /// are on, with no checkpoint.
    func test_aFileWithoutCheckpointsStillReads() throws {
        let project = try projectDir()
        let url = ReadThroughStore.fileURL(projectRoot: project, device: mac)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"pieces":{"doc-a":"2026-11-22T12:00:00Z"}}"#.utf8).write(to: url)
        let store = ReadThroughStore(projectRoot: project, device: mac)
        XCTAssertEqual(store.pieceIds, ["doc-a"])
        XCTAssertFalse(store.hasCheckpoint("doc-a"))
    }

    /// A missing file is empty.
    func test_aMissingFileIsEmpty() throws {
        XCTAssertTrue(ReadThroughStore(projectRoot: try projectDir(), device: mac).pieceIds.isEmpty)
    }

    /// **The prune rule over the real verbs**, in a Collection: a renamed and
    /// a moved piece keep their read-through; a trashed, a deleted and a
    /// promoted one are pruned; a piece restored from Trash comes back writing.
    func test_renameAndMoveKeep_trashDeleteAndPromotionPrune_restoreComesBackWriting() async throws {
        let collection = try await ProjectFactory.createCollectionProject(
            named: "Anthology \(UUID().uuidString.prefix(8))", in: root)
        let project = try await ProjectStore.load(from: collection)
        let renamed = try await project.addLoosePiece(title: "Renamed", format: .markdown)
        let moved = try await project.addLoosePiece(title: "Moved", format: .markdown)
        let trashed = try await project.addLoosePiece(title: "Trashed", format: .markdown)
        let deleted = try await project.addLoosePiece(title: "Deleted", format: .markdown)
        let promoted = try await project.addLoosePiece(title: "Promoted", format: .markdown)
        let documents = try await DocumentStore.open(url: collection)
        project.documentStore = documents
        documents.projectStore = project

        let store = ReadThroughStore(projectRoot: collection, device: mac)
        for piece in [renamed, moved, trashed, deleted, promoted] { store.begin(piece.id, at: started) }
        func prune() { store.prune(keeping: ReadThrough.eligibleIds(in: project.manifest.structure)) }

        try await project.renamePiece(pieceId: renamed.id, newTitle: "Renamed Again")
        try await project.movePiece(pieceId: moved.id, toIndex: 0)
        prune()
        XCTAssertTrue(ReadThrough.isOn(renamed.id, in: store.pieceIds), "a rename keeps the id")
        XCTAssertTrue(ReadThrough.isOn(moved.id, in: store.pieceIds), "a move keeps the id")

        try await project.deleteStructureItem(id: trashed.id)
        prune()
        XCTAssertFalse(ReadThrough.isOn(trashed.id, in: store.pieceIds), "Trash prunes it")

        _ = try await project.restoreLastDeletion()
        prune()
        XCTAssertNotNil(TreeWalk.find(id: trashed.id, in: project.manifest.structure),
                        "precondition: it is back in the structure")
        XCTAssertFalse(ReadThrough.isOn(trashed.id, in: store.pieceIds), "and comes back writing")

        try await project.deleteStructureItem(id: deleted.id)
        let entry = try XCTUnwrap(project.trashEntries.first { $0.id.hasSuffix(deleted.id) })
        try await project.permanentlyDeleteTrashEntry(id: entry.id)
        prune()
        XCTAssertFalse(ReadThrough.isOn(deleted.id, in: store.pieceIds), "delete prunes it")

        _ = try await project.promotePieceToProject(
            pieceId: promoted.id, destination: root.appendingPathComponent("Promoted"))
        prune()
        XCTAssertFalse(ReadThrough.isOn(promoted.id, in: store.pieceIds),
                       "a promoted piece leaves the structure, so it opens writing")
        XCTAssertEqual(store.pieceIds, [renamed.id, moved.id])
        XCTAssertEqual(ReadThroughStore(projectRoot: collection, device: mac).pieceIds,
                       [renamed.id, moved.id], "each prune is written")
    }

    /// Never pruned before the manifest has loaded: an absent structure keeps
    /// nothing to prune by.
    func test_noPruneBeforeTheManifestHasLoaded() {
        XCTAssertNil(ReadThrough.keeping(for: nil))
        XCTAssertEqual(ReadThrough.keeping(for: [doc("a", "manuscript/a.md")]), ["a"])
    }

    // MARK: - The one predicate

    func test_isOnIsTrueOnlyForANonNilIdInTheSet() {
        XCTAssertTrue(ReadThrough.isOn("a", in: ["a"]))
        XCTAssertFalse(ReadThrough.isOn("b", in: ["a"]))
        XCTAssertFalse(ReadThrough.isOn(nil, in: ["a"]))
    }

    func test_eligibleIdsAreTheManuscriptDocuments() {
        let structure = [
            StructureItem(id: "g", title: "Part", type: .group, path: "manuscript/part",
                          children: [doc("a", "manuscript/part/a.md")]),
            doc("b", "manuscript/b.md"),
            StructureItem(id: "ref", title: "Ref", type: .document, path: "elsewhere.md",
                          pieceKind: .reference),
            StructureItem(id: "nopath", title: "None", type: .document),
        ]
        XCTAssertEqual(ReadThrough.eligibleIds(in: structure), ["a", "b"])
    }

    // MARK: - The label

    func test_theCheckpointLabelNamesTheDayAndThePiece() {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour) = (2026, 11, 22, 12)
        let date = Calendar.current.date(from: parts)!
        XCTAssertEqual(
            ReadThrough.checkpointLabel(at: date, title: "Chapter Three",
                                        locale: Locale(identifier: "en_GB")),
            "Read-through, 22 Nov — Chapter Three")
        XCTAssertEqual(
            ReadThrough.checkpointLabel(at: date, title: "Chapter Three",
                                        locale: Locale(identifier: "en_US")),
            "Read-through, Nov 22 — Chapter Three", "the writer's locale orders the day")
    }

    // MARK: - The gate

    private func doc(_ id: String, _ path: String, loose: Bool = false) -> StructureItem {
        ReadThroughGateFixture.doc(id, path, loose: loose)
    }

    private func collectionGate(pieces: Set<String>) -> ReadThroughGate {
        ReadThroughGateFixture.gate(pieces: pieces)
    }

    func test_theWritingGateRefusesNothing() {
        for target in [ReadThroughTarget.piece("piece-a"), .research("a-nested"), .figure("fig-a")] {
            XCTAssertFalse(ReadThroughGate.writing.refusesEdits(target))
        }
        XCTAssertFalse(collectionGate(pieces: []).refusesEdits(.research("a-nested")))
    }

    func test_aPieceInReadThroughRefusesItself_itsFoldersResearch_andItsFigures() {
        let gate = collectionGate(pieces: ["piece-a"])
        XCTAssertTrue(gate.refusesEdits(.piece("piece-a")))
        XCTAssertTrue(gate.refusesEdits(.research("a-folder")))
        XCTAssertTrue(gate.refusesEdits(.research("a-nested")), "nested items through their root")
        XCTAssertTrue(gate.refusesEdits(.figure("fig-a")))
        XCTAssertEqual(gate.owners(of: .research("a-nested")), ["piece-a"])
        XCTAssertFalse(gate.refusesEdits(.piece("piece-b")), "control: another piece writes")
    }

    func test_sharedResearchAndAnUnownedFigureAreRefusedByNothing() {
        let gate = collectionGate(pieces: ["piece-a", "piece-b"])
        XCTAssertFalse(gate.refusesEdits(.research("shared")))
        XCTAssertFalse(gate.refusesEdits(.figure("fig-book")))
        XCTAssertEqual(gate.owners(of: .research("shared")), [])
        XCTAssertEqual(gate.owners(of: .figure("fig-book")), [])
    }

    /// A novel's research linked to the chapter is the book's, and stays
    /// editable while the chapter is in read-through.
    func test_aNovelsLinkedResearchIsShared() {
        var chapter = doc("ch-1", "manuscript/ch-1.md")
        chapter.linkedResearchIds = ["linked"]
        let gate = ReadThroughGate(
            pieces: ["ch-1"], structure: [chapter],
            research: [ResearchItem(id: "linked", title: "Ships", type: .asset,
                                    kind: .document, path: "research/ships.md")],
            figures: [], figureLines: [])
        XCTAssertTrue(gate.refusesEdits(.piece("ch-1")))
        XCTAssertFalse(gate.refusesEdits(.research("linked")))
    }

    // MARK: - The offer

    private let chapter = StructureItem(id: "ch-1", title: "Chapter", type: .document,
                                        path: "manuscript/ch-1.md")

    private func offer(docId: String? = "ch-1", item: StructureItem? = nil,
                       posture: Posture? = .author, share: Bool = false,
                       translation: Bool = false, pieces: Set<String> = []) -> ReadThroughOffer? {
        ReadThroughOffer.of(docId: docId, item: item ?? chapter, posture: posture,
                            shareIsReadOnly: share, isReadingTranslation: translation,
                            isTextVisible: true, pieces: pieces, lackingCheckpoint: [])
    }

    private var reviewer: Posture {
        Posture(LocalWritePermit(permit: .reviewer, actor: .author,
                                 documentClass: .piece("ch-1")))
    }

    func test_startIsOfferedForAWritableOpenPiece() {
        XCTAssertEqual(offer(), ReadThroughOffer(docId: "ch-1", isOn: false, isEnabled: true,
                                                 reason: nil))
    }

    func test_noOfferWhereNoManuscriptPieceIsOpen() {
        XCTAssertNil(offer(docId: nil), "no piece")
        let reference = StructureItem(id: "ch-1", title: "Ref", type: .document,
                                      path: "elsewhere.md", pieceKind: .reference)
        XCTAssertNil(offer(item: reference), "a reference piece")
        XCTAssertNil(offer(item: reference, pieces: ["ch-1"]), "never, even if remembered")
    }

    func test_eachRefusalHasItsReason_forStart() {
        XCTAssertEqual(offer(posture: reviewer)?.reason, ReadThroughOffer.postureRefusal)
        XCTAssertEqual(offer(posture: reviewer)?.isEnabled, false)
        XCTAssertEqual(offer(posture: nil)?.isEnabled, false, "no door fails closed")
        XCTAssertEqual(offer(share: true)?.reason, ReadThroughOffer.shareRefusal)
        XCTAssertEqual(offer(share: true)?.isEnabled, false)
        XCTAssertEqual(offer(translation: true)?.reason, ReadThroughOffer.translationRefusal)
        XCTAssertEqual(offer(translation: true)?.isEnabled, false)
    }

    func test_resumeIsEnabledUnderEveryRefusal() {
        let resume = ReadThroughOffer(docId: "ch-1", isOn: true, isEnabled: true, reason: nil)
        XCTAssertEqual(offer(pieces: ["ch-1"]), resume)
        XCTAssertEqual(offer(posture: reviewer, pieces: ["ch-1"]), resume)
        XCTAssertEqual(offer(posture: nil, pieces: ["ch-1"]), resume)
        XCTAssertEqual(offer(share: true, pieces: ["ch-1"]), resume)
        XCTAssertEqual(offer(translation: true, pieces: ["ch-1"]), resume)
    }

    // MARK: - The request

    func test_theRequestRoundTripsThroughItsPayload() {
        let token = MaughamEvent.observe(
            .maughamSetReadThrough,
            context: { EventReceiverContext(kind: .keyWindow, isWindowLive: true, isWindowKey: true) },
            handler: { [weak self] note in self?.received = ReadThrough.request(of: note.userInfo) })
        defer { NotificationCenter.default.removeObserver(token) }
        ReadThrough.post(.init(docId: "ch-1", on: true))
        XCTAssertEqual(received, .init(docId: "ch-1", on: true))
        XCTAssertNil(ReadThrough.request(of: ["doc_id": "ch-1"]), "a malformed post is nothing")
    }

    private var received: ReadThrough.Request?
}

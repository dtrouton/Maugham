import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Starting and resuming a read-through, and History's Compare** (shell
/// read-through Task 1): the state lands at once, the burst is flushed before
/// the checkpoint, the checkpoint is the piece's and labelled, a refused one
/// says so and leaves read-through on, and Compare opens Rewind's diff at the
/// version the read-through began with.
@MainActor
final class ReadThroughVerbsTests: XCTestCase {

    private var fixture: PostureFixture!
    private var notices: [String] = []
    private var noticeToken: NSObjectProtocol?
    /// Held for the test: `DocumentStore.projectStore` is weak, and the
    /// window's session is what holds it in production.
    private var project: ProjectStore?

    override func setUp() async throws {
        fixture = try PostureFixture()
        let projectId = ProjectIdentifier.id(for: fixture.projectURL)
        noticeToken = MaughamEvent.observe(
            .maughamDocumentNotice,
            context: { EventReceiverContext(kind: .project(id: projectId),
                                            isWindowLive: true, isWindowKey: false) },
            handler: { [weak self] note in
                if let message = note.userInfo?[MaughamEvent.noticeMessageKey] as? String {
                    self?.notices.append(message)
                }
            })
    }

    override func tearDown() async throws {
        if let noticeToken { NotificationCenter.default.removeObserver(noticeToken) }
        fixture.tearDown()
    }

    private let docId = PostureFixture.docId
    private let started = Date(timeIntervalSince1970: 1_790_000_000)

    /// A window's worth of stores on the fixture's book, as `permit` holds it,
    /// with the piece open as `EditorHost` opens it when `open`.
    private func window(_ permit: Permit, open: Bool = true)
        async throws -> (DocumentStore, ReadThroughStore, Document?) {
        let documents = try await fixture.openAs(permit)
        let project = try await ProjectStore.load(from: fixture.projectURL)
        project.documentStore = documents
        documents.projectStore = project
        self.project = project
        var document: Document?
        if open {
            let doc = try await Document.load(
                url: fixture.docURL, actor: .author, session: "read-through",
                presenter: documents.presenter)
            documents.register(document: doc, for: PostureFixture.docPath)
            document = doc
        }
        let store = ReadThroughStore(projectRoot: fixture.projectURL,
                                     device: DeviceSlug.make(from: "read-through-test"))
        return (documents, store, document)
    }

    private func checkpoints() async -> [Checkpoint] {
        await CheckpointStore(projectURL: fixture.projectURL).load().checkpoints
    }

    private func text(_ state: Deriver.DerivedState) -> [String] {
        state.sequence.compactMap { state.paragraphs[$0] }.filter { !$0.isEmpty }
    }

    // MARK: - Start

    /// The state lands in the same turn; the burst is flushed before the
    /// checkpoint; the checkpoint is the piece's, labelled by the writer's
    /// verb, and holds the sentence typed just before.
    func test_startBeginsAtOnce_flushesThenCheckpointsThePiece() async throws {
        let (documents, store, document) = try await window(.bookAuthor)
        let doc = try XCTUnwrap(document)
        doc.setFullText("Hello.\n\nTyped just before.\n")
        var steps: [ReadThroughVerbs.Step] = []
        var flashes = 0

        let task = ReadThroughVerbs.start(
            docId: docId, store: store, documentStore: documents,
            backups: BackupCoordinator(), flash: { flashes += 1 },
            now: started, record: { steps.append($0) })
        XCTAssertTrue(ReadThrough.isOn(docId, in: store.pieceIds),
                      "the tree, line and padlock show in the same turn")
        await task?.value

        XCTAssertEqual(steps, [.began, .flushed, .checkpointed])
        XCTAssertEqual(flashes, 1, "it flashes as ⇧⌘S does")
        let all = await checkpoints()
        let cp = try XCTUnwrap(all.last)
        XCTAssertEqual(cp.activeDoc, docId)
        XCTAssertEqual(cp.labelSource, .user)
        XCTAssertEqual(cp.label, ReadThrough.checkpointLabel(at: started, title: "C1"))
        let pointer = try XCTUnwrap(cp.docPointers[docId])
        let ops = try await doc.opLog()
        let atStart = Deriver.derive(ops: ops, upTo: .atOp(opId: pointer, at: cp.at))
        XCTAssertEqual(text(atStart), ["Hello.", "Typed just before."],
                       "the checkpoint holds the typing the burst had not yet written")
        XCTAssertTrue(notices.isEmpty, "\(notices)")
        await doc.close()
    }

    /// A piece already in read-through takes no second checkpoint.
    func test_aSecondStartTakesNoSecondCheckpoint() async throws {
        let (documents, store, document) = try await window(.bookAuthor)
        await ReadThroughVerbs.start(docId: docId, store: store, documentStore: documents,
                                     backups: BackupCoordinator(), flash: {})?.value
        let count = await checkpoints().count
        XCTAssertNil(ReadThroughVerbs.start(docId: docId, store: store, documentStore: documents,
                                            backups: BackupCoordinator(), flash: {}))
        let after = await checkpoints().count
        XCTAssertEqual(after, count)
        await document?.close()
    }

    /// A refused checkpoint leaves the piece in read-through, writes nothing,
    /// does not flash, and says why.
    func test_aRefusedCheckpointLeavesReadThroughOnAndSaysSo() async throws {
        let (documents, store, _) = try await window(.reviewer, open: false)
        let before = await checkpoints().count
        var flashes = 0
        await ReadThroughVerbs.start(docId: docId, store: store, documentStore: documents,
                                     backups: BackupCoordinator(), flash: { flashes += 1 })?.value
        XCTAssertTrue(ReadThrough.isOn(docId, in: store.pieceIds))
        let after = await checkpoints().count
        XCTAssertEqual(after, before, "the door wrote nothing")
        XCTAssertEqual(flashes, 0, "no flash over a version that was not saved")
        XCTAssertEqual(notices, [ReadThroughVerbs.refusedCheckpointNotice])
    }

    /// Resume ends it.
    func test_resumeEndsIt() throws {
        let store = ReadThroughStore(projectRoot: fixture.projectURL,
                                     device: DeviceSlug.make(from: "read-through-test"))
        store.begin(docId, at: started)
        ReadThroughVerbs.resume(docId: docId, store: store)
        XCTAssertFalse(ReadThrough.isOn(docId, in: store.pieceIds))
    }

    // MARK: - Compare

    private func checkpoint(activeDoc: String?, pointers: [String: String]) -> Checkpoint {
        Checkpoint(checkpointId: "cp", label: "L", labelSource: .user, at: started,
                   device: "m", activeDoc: activeDoc, docPointers: pointers,
                   manuscriptWordCount: 0)
    }

    func test_comparePayloadOpensTheDiffAtThePiecesPointer() throws {
        let cp = checkpoint(activeDoc: docId, pointers: [docId: "op-7", "other": "op-9"])
        let payload = try XCTUnwrap(HistoryPane.comparePayload(docId: docId, checkpoint: cp))
        XCTAssertEqual(payload["scrub_op_id"] as? String, "op-7")
        XCTAssertEqual(payload["scrub_op_at"] as? Date, started)
        XCTAssertEqual(payload[ManuscriptNavigation.docIdKey] as? String, docId)
        XCTAssertEqual(RewindModifier.initialPreview(of: payload), .diff)
        XCTAssertEqual(RewindModifier.initialPreview(of: HistoryPane.rewindPayload(docId: docId, before: nil)),
                       .doc, "every other rewind opens on Doc")
        XCTAssertEqual(RewindModifier.rewindTarget(of: payload, isOpen: { _ in true }), docId)
        XCTAssertNil(HistoryPane.comparePayload(docId: docId,
                                                checkpoint: checkpoint(activeDoc: docId, pointers: [:])),
                     "no pointer, no Compare")
    }

    func test_compareIsOfferedOnlyOnTheOpenPiecesCheckpoints() {
        let mine = checkpoint(activeDoc: docId, pointers: [docId: "op-7"])
        XCTAssertTrue(HistoryPane.offersCompare(mine, docId: docId, documentIsOpen: true))
        XCTAssertFalse(HistoryPane.offersCompare(mine, docId: docId, documentIsOpen: false),
                       "Rewind is the open piece's")
        XCTAssertFalse(HistoryPane.offersCompare(
            checkpoint(activeDoc: "other", pointers: [docId: "op-7"]),
            docId: docId, documentIsOpen: true), "another piece's checkpoint")
        XCTAssertFalse(HistoryPane.offersCompare(
            checkpoint(activeDoc: nil, pointers: [docId: "op-7"]),
            docId: docId, documentIsOpen: true), "a checkpoint of no piece")
        XCTAssertFalse(HistoryPane.offersCompare(
            checkpoint(activeDoc: docId, pointers: [:]),
            docId: docId, documentIsOpen: true), "no pointer")
    }

    /// **The store-level round trip**: text typed after the read-through began
    /// is not in the derive at Compare's op, which equals the piece at the
    /// start.
    func test_compareDerivesThePieceAsItWasAtTheStart() async throws {
        let (documents, store, document) = try await window(.bookAuthor)
        let doc = try XCTUnwrap(document)
        doc.setFullText("Hello.\n\nThe version under review.\n")
        await ReadThroughVerbs.start(docId: docId, store: store, documentStore: documents,
                                     backups: BackupCoordinator(), flash: {},
                                     now: started)?.value
        let opsAtStart = try await doc.opLog()
        let atStart = text(Deriver.derive(ops: opsAtStart, upTo: .now))

        doc.setFullText("Hello.\n\nThe version under review.\n\nAn accepted change.\n")
        try await doc.flushBurstNow()

        let all = await checkpoints()
        let cp = try XCTUnwrap(all.last)
        let payload = try XCTUnwrap(HistoryPane.comparePayload(docId: docId, checkpoint: cp))
        let opId = try XCTUnwrap(payload["scrub_op_id"] as? String)
        let at = try XCTUnwrap(payload["scrub_op_at"] as? Date)
        let opsNow = try await doc.opLog()
        let derived = Deriver.derive(ops: opsNow, upTo: .atOp(opId: opId, at: at))
        XCTAssertEqual(text(derived), atStart)
        XCTAssertEqual(atStart, ["Hello.", "The version under review."])
        await doc.close()
    }
}

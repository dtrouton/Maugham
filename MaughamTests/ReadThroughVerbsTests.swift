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
            docId: docId, mayTakeCheckpoint: true, store: store, documentStore: documents,
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
        XCTAssertEqual(store.checkpoints[docId], cp.checkpointId, "the checkpoint is recorded")
        await doc.close()
    }

    /// A piece already in read-through takes no second checkpoint.
    func test_aSecondStartTakesNoSecondCheckpoint() async throws {
        let (documents, store, document) = try await window(.bookAuthor)
        await ReadThroughVerbs.start(docId: docId, mayTakeCheckpoint: true, store: store, documentStore: documents,
                                     backups: BackupCoordinator(), flash: {})?.value
        let count = await checkpoints().count
        XCTAssertNil(ReadThroughVerbs.start(docId: docId, mayTakeCheckpoint: true, store: store, documentStore: documents,
                                            backups: BackupCoordinator(), flash: {}))
        let after = await checkpoints().count
        XCTAssertEqual(after, count)
        await document?.close()
    }

    /// A refused checkpoint leaves the piece in read-through, writes nothing,
    /// does not flash, records no checkpoint, and says so in the one notice.
    func test_aRefusedCheckpointLeavesReadThroughOnAndSaysSo() async throws {
        let (documents, store, _) = try await window(.reviewer, open: false)
        let before = await checkpoints().count
        var flashes = 0
        await ReadThroughVerbs.start(docId: docId, mayTakeCheckpoint: true, store: store, documentStore: documents,
                                     backups: BackupCoordinator(), flash: { flashes += 1 })?.value
        XCTAssertTrue(ReadThrough.isOn(docId, in: store.pieceIds))
        XCTAssertFalse(store.hasCheckpoint(docId))
        let after = await checkpoints().count
        XCTAssertEqual(after, before, "the door wrote nothing")
        XCTAssertEqual(flashes, 0, "no flash over a version that was not saved")
        XCTAssertEqual(notices, [ReadThroughVerbs.unsavedCheckpointNotice(
            why: PostureStandingLine.checkpointRefusal, offersSaveOne: false)],
                       "a posture's refusal never points at Save one, which it would refuse again")
        XCTAssertFalse(notices.first?.contains("Save one") == true)
    }

    /// The checkpoint file this Mac appends to, occupied by a folder so the
    /// capture throws as a full or unwritable disk would.
    private func breakTheCheckpointFile() throws -> URL {
        let url = CheckpointStore.fileURL(
            deviceSlug: DeviceSlug.make(from: _checkpointDeviceId), in: fixture.projectURL)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// **An I/O failure says the same thing as a refusal** (review M1): the
    /// read-through is on, no checkpoint was saved, and why — one notice, not
    /// the ⌘S one. Then, the disk mended, Start again takes the missing
    /// checkpoint; a third Start takes none.
    func test_aFailedCheckpointSaysSo_andStartAgainTakesTheMissingOne() async throws {
        let (documents, store, document) = try await window(.bookAuthor)
        let before = await checkpoints().count
        let broken = try breakTheCheckpointFile()
        var flashes = 0
        await ReadThroughVerbs.start(docId: docId, mayTakeCheckpoint: true, store: store, documentStore: documents,
                                     backups: BackupCoordinator(), flash: { flashes += 1 },
                                     now: started)?.value
        XCTAssertTrue(ReadThrough.isOn(docId, in: store.pieceIds))
        XCTAssertFalse(store.hasCheckpoint(docId))
        XCTAssertEqual(flashes, 0)
        XCTAssertEqual(notices.count, 1, "\(notices)")
        XCTAssertTrue(notices.first?.hasPrefix(
            "Read-through is on, but no checkpoint was saved — ") == true, "\(notices)")
        XCTAssertFalse(notices.first?.contains("Couldn’t save a checkpoint") == true,
                       "the read-through's notice, not ⌘S's")
        XCTAssertTrue(notices.first?.hasSuffix("Press Save one over the text to save it.") == true,
                      "the notice names the line's button (Task 3's carry B)")
        XCTAssertEqual(store.piecesLackingCheckpoint, [docId],
                       "the line over the text now offers Save one")
        XCTAssertEqual(ReadThroughOffer.of(
            docId: docId, item: project.flatMap { TreeWalk.find(id: docId, in: $0.manifest.structure) },
            posture: .author, shareIsReadOnly: false, isReadingTranslation: false,
            isTextVisible: true,
            pieces: store.pieceIds, lackingCheckpoint: store.piecesLackingCheckpoint)?
            .saveCheckpointRequest, ReadThrough.Request(docId: docId, on: true),
            "Save one posts the Start that takes the missing checkpoint")

        try FileManager.default.removeItem(at: broken)
        let retry = ReadThroughVerbs.start(docId: docId, mayTakeCheckpoint: true, store: store, documentStore: documents,
                                           backups: BackupCoordinator(), flash: { flashes += 1 },
                                           now: started.addingTimeInterval(60))
        XCTAssertNotNil(retry, "Start on a piece in read-through with no checkpoint takes it")
        XCTAssertEqual(store.piecesLackingCheckpoint, [],
                       "while the capture runs, the line does not say none was saved")
        await retry?.value
        let saved = await checkpoints()
        XCTAssertEqual(saved.count, before + 1)
        XCTAssertEqual(store.checkpoints[docId], saved.last?.checkpointId)
        XCTAssertEqual(store.pieces[docId], started, "the read-through keeps its first start")
        XCTAssertEqual(flashes, 1)
        XCTAssertNil(ReadThroughVerbs.start(docId: docId, mayTakeCheckpoint: true, store: store, documentStore: documents,
                                            backups: BackupCoordinator(), flash: {}),
                     "with its checkpoint, a further Start takes none")
        await document?.close()
    }

    /// **A ⌘Q between `begin` and the capture** leaves the piece on with no
    /// checkpoint, across the relaunch; Start then takes it.
    func test_aQuitBeforeTheCaptureIsRecoveredByStartAgain() async throws {
        let (documents, first, document) = try await window(.bookAuthor)
        let before = await checkpoints().count
        first.begin(docId, at: started)
        let relaunched = ReadThroughStore(projectRoot: fixture.projectURL,
                                          device: DeviceSlug.make(from: "read-through-test"))
        XCTAssertTrue(ReadThrough.isOn(docId, in: relaunched.pieceIds))
        XCTAssertFalse(relaunched.hasCheckpoint(docId))
        XCTAssertEqual(relaunched.piecesLackingCheckpoint, [docId], "the line offers Save one")
        await ReadThroughVerbs.start(docId: docId, mayTakeCheckpoint: true, store: relaunched, documentStore: documents,
                                     backups: BackupCoordinator(), flash: {})?.value
        XCTAssertTrue(relaunched.hasCheckpoint(docId))
        let saved = await checkpoints()
        XCTAssertEqual(saved.count, before + 1)
        await document?.close()
    }

    /// Two Starts in one moment take one checkpoint.
    func test_twoStartsAtOnceTakeOneCheckpoint() async throws {
        let (documents, store, document) = try await window(.bookAuthor)
        let before = await checkpoints().count
        let a = ReadThroughVerbs.start(docId: docId, mayTakeCheckpoint: true, store: store, documentStore: documents,
                                       backups: BackupCoordinator(), flash: {})
        let b = ReadThroughVerbs.start(docId: docId, mayTakeCheckpoint: true, store: store, documentStore: documents,
                                       backups: BackupCoordinator(), flash: {})
        XCTAssertNotNil(a)
        XCTAssertNil(b, "the first is still capturing")
        await a?.value
        let saved = await checkpoints()
        XCTAssertEqual(saved.count, before + 1)
        await document?.close()
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
        func offer(_ cp: Checkpoint, open: Bool = true, holds: Bool = true) -> HistoryPane.CompareOffer {
            HistoryPane.compareOffer(cp, docId: docId, documentIsOpen: open, holdsOp: { _ in holds })
        }
        let mine = checkpoint(activeDoc: docId, pointers: [docId: "op-7"])
        XCTAssertEqual(offer(mine), .compare)
        XCTAssertEqual(offer(mine, open: false), .absent, "Rewind is the open piece's")
        XCTAssertEqual(offer(checkpoint(activeDoc: "other", pointers: [docId: "op-7"])), .absent,
                       "another piece's checkpoint")
        XCTAssertEqual(offer(checkpoint(activeDoc: nil, pointers: [docId: "op-7"])), .absent,
                       "a checkpoint of no piece")
        XCTAssertEqual(offer(checkpoint(activeDoc: docId, pointers: [:])), .absent, "no pointer")
    }

    /// **A pointer whose op is not in the loaded history** (review fix 2):
    /// Rewind's derive would fall back to now and the diff would read "no
    /// change", so Compare… is drawn disabled with its reason. The lookup is
    /// the pointer's own op.
    func test_aCheckpointWhoseOpIsGoneCannotBeCompared() {
        let cp = checkpoint(activeDoc: docId, pointers: [docId: "op-7"])
        var asked: [String] = []
        let offer = HistoryPane.compareOffer(cp, docId: docId, documentIsOpen: true,
                                             holdsOp: { asked.append($0); return false })
        XCTAssertEqual(offer, .unavailable)
        XCTAssertEqual(asked, ["op-7"])
        XCTAssertFalse(HistoryPane.compareUnavailableHelp.isEmpty)
        // And the premise: at an op not in the log, the derive is now's.
        let ops = [Op(opId: "op-1", docId: docId, at: started, device: "m", session: "s",
                      kind: .typingBurst, changes: [], sequence: nil, provenance: nil)]
        XCTAssertEqual(Deriver.derive(ops: ops, upTo: .atOp(opId: "op-7", at: started)),
                       Deriver.derive(ops: ops, upTo: .now))
    }

    /// **The store-level round trip**: text typed after the read-through began
    /// is not in the derive at Compare's op, which equals the piece at the
    /// start.
    func test_compareDerivesThePieceAsItWasAtTheStart() async throws {
        let (documents, store, document) = try await window(.bookAuthor)
        let doc = try XCTUnwrap(document)
        doc.setFullText("Hello.\n\nThe version under review.\n")
        await ReadThroughVerbs.start(docId: docId, mayTakeCheckpoint: true, store: store, documentStore: documents,
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

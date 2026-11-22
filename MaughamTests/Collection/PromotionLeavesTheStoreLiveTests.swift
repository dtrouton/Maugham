import XCTest
import AppKit
@testable import MaughamCore
@testable import Maugham

/// **A promotion closes only what it moves** (shell p4 Task 11, call 6;
/// Review Focus 5). `promotePieceToProject` used to `close()` the window's
/// whole `DocumentStore` — every open `Document` drained, every figure
/// closed, the presenter removed — and neither the failure path nor the
/// success path reopened it, so the Collection window carried on over a dead
/// store: typing in another piece reached no op log, a third piece opened
/// with no presenter, and a peer's sync was never seen.
///
/// Each test holds a window's worth of state the way production does: a
/// `DocumentStore` cross-linked to the `ProjectStore`, and pieces open as
/// `EditorHost` opens them (`Document.load` with the store's presenter, then
/// `register`). Every failure is production code's own throw, arranged
/// through the `afterStaging:` seam.
@MainActor
final class PromotionLeavesTheStoreLiveTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = TestTemp.root.appendingPathComponent("promote-live-\(UUID().uuidString)")
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

    // MARK: - Fixture

    /// A Collection with three loose pieces and a window over it: Story A
    /// (the one promoted) and Story B open, each with typing not yet flushed
    /// to its op log; Story C closed.
    private struct Window {
        let projectStore: ProjectStore
        let store: DocumentStore
        let a: StructureItem, b: StructureItem, c: StructureItem
        let aDoc: Document, bDoc: Document
        let collection: URL
    }

    private func openWindow() async throws -> Window {
        let collection = try await ProjectFactory.createCollectionProject(
            named: "Anthology \(UUID().uuidString.prefix(8))", in: root)
        let projectStore = try await ProjectStore.load(from: collection)
        let a = try await projectStore.addLoosePiece(title: "Story A", format: .markdown)
        let b = try await projectStore.addLoosePiece(title: "Story B", format: .markdown)
        let c = try await projectStore.addLoosePiece(title: "Story C", format: .markdown)
        let store = try await DocumentStore.open(url: collection)
        projectStore.documentStore = store
        store.projectStore = projectStore
        let aDoc = try await open(a, in: store, collection: collection)
        let bDoc = try await open(b, in: store, collection: collection)
        // Typed and not yet flushed: the promotion must lose neither.
        aDoc.setFullText("The tide went out.\n")
        bDoc.setFullText("Story B, first words.\n")
        return Window(projectStore: projectStore, store: store, a: a, b: b, c: c,
                      aDoc: aDoc, bDoc: bDoc, collection: collection)
    }

    /// Open `piece` as `EditorHost` does.
    private func open(_ piece: StructureItem, in store: DocumentStore, collection: URL) async throws -> Document {
        let path = try XCTUnwrap(piece.path)
        let doc = try await Document.load(
            url: collection.appendingPathComponent(path),
            actor: .author, session: "promote-live", presenter: store.presenter)
        store.register(document: doc, for: path)
        return doc
    }

    private func stagingTrees() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix(".maugham-staging-") }
    }

    /// A directory where the staged manifest is about to be written, so step
    /// 5's own atomic write throws with every staging move done.
    private func occupyStagedManifestPath() {
        for tree in stagingTrees() {
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent(tree).appendingPathComponent(ProjectManifest.fileName),
                withIntermediateDirectories: true)
        }
    }

    /// Whether `text` is in `docId`'s op log on disk — what autosave reaching
    /// the source of truth means. A needle made only of hex/base64 characters
    /// is refused: the log's hashes and signatures are those characters, so
    /// "ebb" matched a `head` hash in about one run in thirty.
    private func opLogHolds(_ text: String, docId: String, in projectURL: URL,
                            file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let hashAlphabet = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard text.unicodeScalars.contains(where: { !hashAlphabet.contains($0) }) else {
            XCTFail("needle \"\(text)\" could match a hash or signature; give it a space or punctuation",
                    file: file, line: line)
            return false
        }
        let needle = Data(text.utf8)
        return try OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL).contains { url in
            try Data(contentsOf: url).range(of: needle) != nil
        }
    }

    /// Every byte of `docId`'s op log files, by file name.
    private func opLogBytes(docId: String, in projectURL: URL) throws -> [String: Data] {
        var bytes: [String: Data] = [:]
        for url in try OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL) {
            bytes[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return bytes
    }

    /// The window is live: B still open and registered, the presenter still
    /// installed with the file coordinator, B's typing (before and after)
    /// reaches its op log, and a third piece opens and saves.
    private func assertTheWindowIsLive(_ w: Window, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertFalse(w.bDoc.isClosed, "another piece's open Document was closed", file: file, line: line)
        XCTAssertTrue(w.store.document(for: try XCTUnwrap(w.b.path)) === w.bDoc,
                      "another piece's Document was unregistered", file: file, line: line)
        let presenter = try XCTUnwrap(w.store.presenter, "the presenter was removed", file: file, line: line)
        XCTAssertTrue(NSFileCoordinator.filePresenters.contains { $0 === presenter },
                      "the presenter is no longer installed: a peer's sync goes unseen", file: file, line: line)

        w.bDoc.setFullText("Story B, first words.\nAnd after the promotion.\n")
        try await w.bDoc.flushBurstNow()
        XCTAssertTrue(try opLogHolds("Story B, first words.", docId: w.bDoc.docId, in: w.collection),
                      "B's typing from before the promotion never reached its op log", file: file, line: line)
        XCTAssertTrue(try opLogHolds("And after the promotion.", docId: w.bDoc.docId, in: w.collection),
                      "typing in another piece after the promotion goes nowhere", file: file, line: line)

        let cDoc = try await open(w.c, in: w.store, collection: w.collection)
        XCTAssertFalse(cDoc.isClosed, file: file, line: line)
        cDoc.setFullText("Story C opened afterwards.\n")
        try await cDoc.flushBurstNow()
        XCTAssertTrue(try opLogHolds("Story C opened afterwards.", docId: cDoc.docId, in: w.collection),
                      "a piece opened after the promotion does not save", file: file, line: line)
        await cDoc.close()
        await w.bDoc.close()
    }

    // MARK: - The contract's three

    /// A failure mid-move (every staging move done, the manifest write
    /// refused): the Collection is as it was, the store is live, and the
    /// writer is told the cause and that everything was put back.
    func test_aFailedPromotionLeavesTheStoreLive() async throws {
        let w = try await openWindow()
        let aPath = try XCTUnwrap(w.a.path)
        let returnsBefore = w.store.promotionReturns
        var heldMidway = false, bLiveMidway = false

        do {
            _ = try await w.projectStore.promotePieceToProject(
                pieceId: w.a.id, destination: root.appendingPathComponent("Promoted A"),
                afterStaging: {
                    heldMidway = w.store.isWithdrawnForPromotion(path: aPath)
                    bLiveMidway = !w.bDoc.isClosed && w.store.presenter != nil
                    self.occupyStagedManifestPath()
                })
            XCTFail("the promotion reported success with its manifest unwritable")
        } catch let failed as PiecePromotionFailed {
            XCTAssertEqual(failed.filesAre, .putBack)
            XCTAssertTrue(failed.localizedDescription.hasPrefix("\u{201C}Story A\u{201D} couldn\u{2019}t be promoted: "),
                          failed.localizedDescription)
            XCTAssertTrue(failed.localizedDescription.hasSuffix("Everything was put back where it was."),
                          failed.localizedDescription)
        }

        XCTAssertTrue(heldMidway, "the piece's path was not held while its file was staged away")
        XCTAssertTrue(bLiveMidway, "the store was closed during the promotion")
        XCTAssertFalse(w.store.isWithdrawnForPromotion(path: aPath), "the failure never gave the path back")
        XCTAssertEqual(w.store.promotionReturns, returnsBefore + 1,
                       "an editor left on the closed piece is never told to load again")
        try await assertTheWindowIsLive(w)

        // The promoted piece: back where it was, its unflushed typing kept,
        // and it opens again on the live store.
        let item = try XCTUnwrap(w.projectStore.manifest.structure.first { $0.id == w.a.id })
        XCTAssertEqual(item.pieceKind, .loose)
        XCTAssertTrue(EditorHost.loadsAsAManuscript(item))
        let reopened = try await open(item, in: w.store, collection: w.collection)
        XCTAssertTrue(reopened.displayText.hasPrefix("The tide went out."),
                       "typing in the promoted piece before the promotion was lost")
        await reopened.close()
        XCTAssertEqual(stagingTrees(), [])
    }

    /// A success: the new project holds the piece's unflushed typing, the
    /// piece is a reference (which no editor loads as a manuscript), and the
    /// Collection's store is live.
    func test_aSuccessfulPromotionLeavesTheCollectionLive() async throws {
        let w = try await openWindow()
        let returnsBefore = w.store.promotionReturns
        let destination = root.appendingPathComponent("Promoted A")

        let promotion = try await w.projectStore.promotePieceToProject(pieceId: w.a.id, destination: destination)

        XCTAssertEqual(promotion.url, destination)
        XCTAssertFalse(w.store.isWithdrawnForPromotion(path: try XCTUnwrap(w.a.path)))
        XCTAssertEqual(w.store.promotionReturns, returnsBefore + 1)
        try await assertTheWindowIsLive(w)

        let item = try XCTUnwrap(w.projectStore.manifest.structure.first { $0.id == w.a.id })
        XCTAssertEqual(item.pieceKind, .reference)
        XCTAssertFalse(EditorHost.loadsAsAManuscript(item),
                       "an editor still mounted on the piece would load its link file as a manuscript")

        let promoted = try await ProjectStore.load(from: destination)
        let doc = try XCTUnwrap(promoted.manifest.structure.first)
        let carriedDoc = try await Document.load(
            url: destination.appendingPathComponent(try XCTUnwrap(doc.path)),
            actor: .author, session: "promote-live", presenter: nil)
        XCTAssertTrue(carriedDoc.displayText.hasPrefix("The tide went out."),
                       "the piece's unflushed typing did not reach the new project")
        await carriedDoc.close()
    }

    /// The promotion closes the piece it moves — flushed, closed,
    /// unregistered — on success and failure alike.
    func test_thePromotedPiecesDocumentIsClosed() async throws {
        for fails in [false, true] {
            let w = try await openWindow()
            let aPath = try XCTUnwrap(w.a.path)
            _ = try? await w.projectStore.promotePieceToProject(
                pieceId: w.a.id, destination: root.appendingPathComponent("Promoted \(fails)"),
                afterStaging: { if fails { self.occupyStagedManifestPath() } })
            XCTAssertTrue(w.aDoc.isClosed, "fails \(fails): the promoted piece's Document is still open")
            XCTAssertNil(w.store.document(for: aPath), "fails \(fails): it is still registered")
            await w.bDoc.close()
        }
    }

    // MARK: - Each failure point

    /// Refused before anything moves (the piece is not a loose piece): the
    /// promotion touched nothing, the promoted piece's own Document included.
    func test_aRefusalBeforeAnyMoveTouchesNothing() async throws {
        let w = try await openWindow()
        do {
            _ = try await w.projectStore.promotePieceToProject(
                pieceId: "no-such-piece", destination: root.appendingPathComponent("Promoted"))
            XCTFail("an unknown piece was promoted")
        } catch is PiecePromotionFailed {
            XCTFail("a refusal before any move must say why in its own words, not as a rollback")
        } catch {}
        XCTAssertFalse(w.aDoc.isClosed)
        XCTAssertTrue(w.store.document(for: try XCTUnwrap(w.a.path)) === w.aDoc)
        try await assertTheWindowIsLive(w)
        await w.aDoc.close()
    }

    /// A move-back that cannot complete: the staging tree is kept, the writer
    /// is told where, and the store is live.
    func test_aStrandedMoveBackSaysWhereTheFilesAre_andLeavesTheStoreLive() async throws {
        let w = try await openWindow()
        let note = try await w.projectStore.addPieceResearchNote(pieceId: w.a.id, title: "Tide tables")
        let researchFolder = w.collection
            .appendingPathComponent(((try XCTUnwrap(note.path)) as NSString).deletingLastPathComponent)

        do {
            _ = try await w.projectStore.promotePieceToProject(
                pieceId: w.a.id, destination: root.appendingPathComponent("Promoted A"),
                afterStaging: {
                    self.occupyStagedManifestPath()
                    try? FileManager.default.createDirectory(at: researchFolder, withIntermediateDirectories: true)
                })
            XCTFail("the promotion reported success with its manifest unwritable")
        } catch let failed as PiecePromotionFailed {
            let kept = try XCTUnwrap(stagingTrees().first)
            guard case .keptIn(let folder) = failed.filesAre else {
                return XCTFail("the writer was not told where the kept files are: \(failed.filesAre)")
            }
            XCTAssertEqual(folder.lastPathComponent, kept)
            XCTAssertTrue(failed.localizedDescription.contains("couldn\u{2019}t be put back; they are in"),
                          failed.localizedDescription)
        }
        try await assertTheWindowIsLive(w)
    }

    /// A failure after the new project is in place (the Collection's link
    /// file refused): the files are whole at the destination, the writer is
    /// told so and that the Collection still lists the piece, and the store
    /// is live — the piece's editor loads it again from its op log.
    func test_aFailureAfterTheDestinationExistsSaysSo_andLeavesTheStoreLive() async throws {
        let w = try await openWindow()
        let pieceFolder = (try XCTUnwrap(w.a.path) as NSString).deletingLastPathComponent
        let linkPath = w.collection.appendingPathComponent("\(pieceFolder)/.maugham-link.json")
        let destination = root.appendingPathComponent("Promoted A")

        do {
            _ = try await w.projectStore.promotePieceToProject(
                pieceId: w.a.id, destination: destination,
                afterStaging: {
                    try? FileManager.default.createDirectory(at: linkPath, withIntermediateDirectories: true)
                })
            XCTFail("the promotion reported success with its link file unwritable")
        } catch let failed as PiecePromotionFailed {
            XCTAssertEqual(failed.filesAre, .atTheDestination(destination))
            XCTAssertTrue(failed.localizedDescription.contains("is now a project at \(destination.path)"),
                          failed.localizedDescription)
            XCTAssertTrue(failed.localizedDescription.contains("The Collection still lists it as its own piece."),
                          failed.localizedDescription)
        }
        try await assertTheWindowIsLive(w)
    }

    /// What the alert says where the files are (fix round 1, M4, M5): a
    /// kept folder is named as hidden with Reveal in Finder; a failure after
    /// the piece's figures went to the Trash names them.
    func test_theFailureSentencesSayWhereEverythingIs() {
        struct Cause: LocalizedError { var errorDescription: String? { "The disk is full." } }
        let kept = PiecePromotionFailed(
            title: "Story A", cause: Cause(),
            filesAre: .keptIn(URL(fileURLWithPath: "/b/.maugham-staging-1")))
        XCTAssertEqual(kept.localizedDescription,
                       "\u{201C}Story A\u{201D} couldn\u{2019}t be promoted: The disk is full. Some of its files couldn\u{2019}t be put back; they are in a hidden folder beside the Collection, /b/.maugham-staging-1. Reveal in Finder shows it.")
        let there = PiecePromotionFailed(
            title: "Story A", cause: Cause(),
            filesAre: .atTheDestination(URL(fileURLWithPath: "/b/Story A")),
            figuresInTrash: ["own", "map"])
        XCTAssertTrue(there.localizedDescription.hasSuffix(
            "Its figures own, map are in the Collection\u{2019}s Trash, and in the new project."),
            there.localizedDescription)
    }

    // MARK: - A load of the held piece, and the carried notes

    /// **The hold's wait, tested directly** (fix round 1, I2). The earlier
    /// test started its waiter inside `afterStaging:`, and nothing between
    /// there and the promotion's `defer` suspends, so the waiter only ran
    /// once the hold was gone and passed with the wait removed. Here: hold,
    /// start a waiter, yield — it is still waiting — give back, and it goes on.
    func test_aLoadOfTheHeldPieceWaitsForTheReturn() async throws {
        let w = try await openWindow()
        let aPath = try XCTUnwrap(w.a.path)
        let hold = await w.store.withdrawForPromotion(path: aPath)
        var woke = false
        let waiter = Task { @MainActor in
            await w.store.waitWhileWithdrawnForPromotion(path: aPath)
            woke = true
        }
        // Until the waiter has either reached the hold (one load waiting on
        // it) or gone past it (woke): a state, never a clock.
        while !woke && w.store.loadsWaitingForPromotion(path: aPath) == 0 { await Task.yield() }
        XCTAssertFalse(woke, "a load of the held piece went on while it was held")
        XCTAssertEqual(w.store.loadsWaitingForPromotion(path: aPath), 1)

        w.store.returnFromPromotion(hold)
        await waiter.value
        XCTAssertTrue(woke, "the return did not let the waiting load go on")
        await w.bDoc.close()
    }

    /// **A hold is its promotion's** (fix round 1, M1): a second hold on the
    /// same path gives back nothing of the first's.
    func test_onlyTheHoldThatTookThePathGivesItBack() async throws {
        let w = try await openWindow()
        let aPath = try XCTUnwrap(w.a.path)
        let first = await w.store.withdrawForPromotion(path: aPath)
        let second = await w.store.withdrawForPromotion(path: aPath)
        w.store.returnFromPromotion(second)
        XCTAssertTrue(w.store.isWithdrawnForPromotion(path: aPath),
                      "another promotion's return gave back the first one's hold")
        w.store.returnFromPromotion(first)
        XCTAssertFalse(w.store.isWithdrawnForPromotion(path: aPath))
        await w.bDoc.close()
    }

    /// **One promotion at a time** (fix round 1, M1): while one is running,
    /// another — of this piece or any other — is refused before it touches
    /// anything, naming the one running.
    func test_aSecondPromotionWhileOneIsRunningIsRefused() async throws {
        let w = try await openWindow()
        w.projectStore.promotionInFlight = w.c.id
        defer { w.projectStore.promotionInFlight = nil }
        do {
            _ = try await w.projectStore.promotePieceToProject(
                pieceId: w.a.id, destination: root.appendingPathComponent("Promoted A"))
            XCTFail("a promotion started while another was running")
        } catch let running as PromotionAlreadyRunning {
            XCTAssertEqual(running.localizedDescription,
                           "\u{201C}Story C\u{201D} is being promoted right now \u{2014} try again when it has finished.")
        }
        XCTAssertFalse(w.aDoc.isClosed, "the refused promotion closed the piece")
        XCTAssertFalse(w.store.isWithdrawnForPromotion(path: try XCTUnwrap(w.a.path)))
        XCTAssertEqual(stagingTrees(), [])
        await w.aDoc.close()
        await w.bDoc.close()
    }

    // MARK: - Every loader meets the door (fix round 1, I1)

    /// Replace All across the Collection while A is held: B and C change, A
    /// is left as it was and named, nothing is appended to A's op log; Find
    /// meanwhile skips A.
    func test_replaceAllDuringAPromotionChangesEveryPieceButTheHeldOne() async throws {
        let w = try await openWindow()
        let aPath = try XCTUnwrap(w.a.path)
        w.bDoc.setFullText("Story B, the tide.\n")
        try await w.bDoc.flushBurstNow()
        let cDoc = try await open(w.c, in: w.store, collection: w.collection)
        cDoc.setFullText("Story C, the tide.\n")
        try await cDoc.flushBurstNow()
        w.store.unregister(path: try XCTUnwrap(w.c.path))
        await cDoc.close()
        let found = await ProjectSearchEngine().search(query: "tide", options: SearchOptions(), in: w.projectStore)
        XCTAssertEqual(Set(found.matches.map(\.documentTitle)), ["Story A", "Story B", "Story C"],
                       "premise: the search found every piece before the promotion")

        let hold = await w.store.withdrawForPromotion(path: aPath)
        // The hold flushed and closed A: its op log is final until the return.
        let aLogBefore = try opLogBytes(docId: w.aDoc.docId, in: w.collection)
        let during = await ProjectSearchEngine().search(query: "tide", options: SearchOptions(), in: w.projectStore)
        XCTAssertEqual(Set(during.matches.map(\.documentTitle)), ["Story B", "Story C"],
                       "Find listed a piece a promotion is moving")

        let outcome = try await w.projectStore.replaceAll(in: found, with: "ebb")
        XCTAssertEqual(outcome.beingPromoted, ["Story A"])
        XCTAssertEqual(outcome.leftAlone, [])
        XCTAssertEqual(outcome.notice,
                       "Left as it was \u{2014} being promoted to its own project: Story A. Try again in a moment.")
        try await w.bDoc.flushBurstNow()
        XCTAssertTrue(try opLogHolds("Story B, the ebb.", docId: w.bDoc.docId, in: w.collection))
        XCTAssertTrue(try opLogHolds("Story C, the ebb.", docId: cDoc.docId, in: w.collection))
        XCTAssertEqual(try opLogBytes(docId: w.aDoc.docId, in: w.collection), aLogBefore,
                       "Replace All wrote to the op log of a piece a promotion is moving")
        XCTAssertNil(w.store.document(for: aPath), "nothing registered the held piece")

        w.store.returnFromPromotion(hold)
        await w.bDoc.close()
    }

    /// An MCP annotation write on the held piece is refused cleanly
    /// (`being_promoted`), and appends nothing; a task read skips it.
    func test_anMCPAnnotationOnTheHeldPieceIsRefused() async throws {
        let w = try await openWindow()
        let aPath = try XCTUnwrap(w.a.path)
        let hold = await w.store.withdrawForPromotion(path: aPath)
        var ran = false
        do {
            try await withAnnotationDocument(store: w.projectStore, projectURL: w.collection,
                                             documentId: w.a.id) { _ in ran = true }
            XCTFail("an annotation reached a piece a promotion is moving")
        } catch let promoting as ManuscriptBeingPromoted {
            XCTAssertEqual(promoting.localizedDescription,
                           "\u{201C}Story A\u{201D} is being promoted to its own project \u{2014} try again in a moment.")
            XCTAssertEqual(MCPToolsCallHandler.toolErrorPayload(for: promoting).error, "being_promoted")
        }
        XCTAssertFalse(ran)
        w.store.returnFromPromotion(hold)
        await w.bDoc.close()
    }

    /// The presence walk reads op logs, never a load: it runs over a held
    /// piece without error and touches nothing at its path.
    func test_thePresenceWalkRunsOverAHeldPieceWithoutError() async throws {
        let w = try await openWindow()
        let aPath = try XCTUnwrap(w.a.path)
        try await w.aDoc.flushBurstNow()
        let hold = await w.store.withdrawForPromotion(path: aPath)
        let reader = ResolvePresenceReader()
        for _ in 0..<4 {
            let key = ResolvePresenceReader.key(store: w.projectStore, documentStore: w.store,
                                                diagnostics: nil, annotationsToken: 0, script: nil)
            reader.update(key, store: w.projectStore, documentStore: w.store, diagnostics: nil)
            while let request = reader.pendingRequest {
                await reader.run(request, store: w.projectStore, documentStore: w.store, diagnostics: nil)
            }
        }
        XCTAssertNil(w.store.document(for: aPath), "the walk opened the held piece")
        w.store.returnFromPromotion(hold)
        await w.bDoc.close()
    }

    /// **A load that outlived a successful promotion is not handed out**
    /// (fix round 1, M2): the door's after-load question, asked of the
    /// store as a promotion leaves it — the path now names a reference's
    /// link, so a load that began before the return is closed and refused.
    func test_aLoadOverTakenByASuccessfulPromotionIsNotHandedOut() async throws {
        let w = try await openWindow()
        let aPath = try XCTUnwrap(w.a.path)
        XCTAssertTrue(w.store.pathNamesAManuscript(aPath), "premise")
        _ = try await w.projectStore.promotePieceToProject(
            pieceId: w.a.id, destination: root.appendingPathComponent("Promoted A"))
        XCTAssertFalse(w.store.pathNamesAManuscript(aPath),
                       "the old path still names a manuscript after the piece became a reference")
        // And the door refuses a fresh load of it too.
        do {
            _ = try await DocumentStore.loadManuscript(
                path: aPath, url: w.collection.appendingPathComponent(aPath),
                actor: .author, session: "late", presenter: nil, through: w.store)
        } catch {
            // A missing file may throw on its own; what matters is nothing registered.
        }
        XCTAssertNil(w.store.document(for: aPath))
        await w.bDoc.close()
    }

    /// The piece's Research is in flight while its files are staged away, so
    /// the note door writes nothing at their old paths (#142 T2's span); the
    /// span ends with the promotion.
    func test_thePiecesNotesAreInFlightWhileStaged() async throws {
        let w = try await openWindow()
        let note = try await w.projectStore.addPieceResearchNote(pieceId: w.a.id, title: "Tide tables")
        var inFlightMidway: Set<String> = []

        _ = try? await w.projectStore.promotePieceToProject(
            pieceId: w.a.id, destination: root.appendingPathComponent("Promoted A"),
            afterStaging: {
                inFlightMidway = w.projectStore.researchItemsInFlight
                self.occupyStagedManifestPath()
            })

        XCTAssertTrue(inFlightMidway.contains(note.id), "the carried note was not in flight: \(inFlightMidway)")
        XCTAssertTrue(w.projectStore.researchItemsInFlight.isEmpty)
        await w.bDoc.close()
    }

    /// The editor's two hooks into the hold stay wired (the view is not
    /// mounted here; its decisions are the pure `loadsAsAManuscript` above).
    func test_theEditorWaitsOnTheHoldAndLoadsAgainOnTheReturn() throws {
        let source = try String(
            contentsOf: SourceTree.repoRoot.appendingPathComponent("Maugham/Views/EditorHost.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains(".onChange(of: documentStore.promotionReturns)"),
                      "an editor the promotion closed under is never told to load again")
        XCTAssertTrue(source.contains("await documentStore.waitWhileWithdrawnForPromotion(path: path)"),
                      "a load of the held piece does not wait for the promotion")
        XCTAssertTrue(source.contains("guard !documentStore.isWithdrawnForPromotion(path: path),"),
                      "a load that finished mid-promotion registers over a staged-away file")
        XCTAssertTrue(source.contains("let still = currentItem, Self.loadsAsAManuscript(still),"),
                      "a load that outlived a promotion registers at a reference's old path")
        XCTAssertTrue(source.contains("} catch is ManuscriptBeingPromoted {"),
                      "the door's refusal is shown as a failed load")
    }
}

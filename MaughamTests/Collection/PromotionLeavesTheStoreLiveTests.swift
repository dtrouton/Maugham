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
    /// the source of truth means.
    private func opLogHolds(_ text: String, docId: String, in projectURL: URL) throws -> Bool {
        let needle = Data(text.utf8)
        return try OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL).contains { url in
            try Data(contentsOf: url).range(of: needle) != nil
        }
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

    // MARK: - A load of the held piece, and the carried notes

    /// A load of the piece while the promotion holds it waits — no timer —
    /// and goes on once the path is given back.
    func test_aLoadOfTheHeldPieceWaitsForTheReturn() async throws {
        let w = try await openWindow()
        let aPath = try XCTUnwrap(w.a.path)
        var waiter: Task<Bool, Never>?

        _ = try? await w.projectStore.promotePieceToProject(
            pieceId: w.a.id, destination: root.appendingPathComponent("Promoted A"),
            afterStaging: {
                waiter = Task { @MainActor in
                    await w.store.waitWhileWithdrawnForPromotion(path: aPath)
                    // What the load sees when it wakes.
                    return w.store.isWithdrawnForPromotion(path: aPath)
                }
                self.occupyStagedManifestPath()
            })

        let stillHeldWhenItWoke = await (try XCTUnwrap(waiter)).value
        XCTAssertFalse(stillHeldWhenItWoke, "the load went on while the promotion still held the piece")
        // Nothing holds the path now: a fresh wait returns at once.
        await w.store.waitWhileWithdrawnForPromotion(path: aPath)
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
        XCTAssertTrue(source.contains("guard !documentStore.isWithdrawnForPromotion(path: path) else {"),
                      "a load that finished mid-promotion registers over a staged-away file")
    }
}

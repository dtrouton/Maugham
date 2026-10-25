import XCTest
import AppKit
@testable import MaughamCore
@testable import Maugham

@MainActor
final class PromotePieceTests: XCTestCase {
    private func makeCollectionWithPiece(
        format: DocumentFormat
    ) async throws -> (collection: URL, store: ProjectStore, piece: StructureItem) {
        let tmp = TestTemp.root
            .appendingPathComponent("PP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collectionURL = try await ProjectFactory.createCollectionProject(
            named: "Anthology", in: tmp)
        let store = try await ProjectStore.load(from: collectionURL)
        let piece = try await store.addLoosePiece(title: "Story A", format: format)
        return (collectionURL, store, piece)
    }

    func test_promote_prose_createsShortStoryProject() async throws {
        let (collection, store, piece) = try await makeCollectionWithPiece(format: .markdown)
        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted Story A")

        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination).url

        // New project exists with .shortStory type
        let newStore = try await ProjectStore.load(from: newProjectURL)
        XCTAssertEqual(newStore.manifest.type, .shortStory)
        XCTAssertEqual(newStore.manifest.title, "Story A")

        // Collection's piece is now a reference
        guard let converted = store.manifest.structure.first(where: { $0.id == piece.id }) else {
            XCTFail("piece not found in Collection after promote"); return
        }
        XCTAssertEqual(converted.pieceKind, .reference)
        XCTAssertNotNil(converted.linkedProjectBookmark)
    }

    func test_promote_screenplay_createsScreenplayProject() async throws {
        let (collection, store, piece) = try await makeCollectionWithPiece(format: .fountain)
        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted Screenplay")

        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination).url

        let newStore = try await ProjectStore.load(from: newProjectURL)
        XCTAssertEqual(newStore.manifest.type, .screenplay)
    }

    /// **A hand-imported `Piece.FOUNTAIN` promotes to a screenplay** (plan 7,
    /// declared exception 1). The op log already parses an upper-case
    /// `.FOUNTAIN` as Fountain; the promotion asks the same
    /// `DocumentFormat.ofManuscript(path:)` question, so the case of the
    /// extension no longer decides the promoted kind.
    func test_promote_upperCaseFountainMainDoc_createsScreenplayProject() async throws {
        let (collection, store, piece) = try await makeCollectionWithPiece(format: .markdown)
        let oldPath = try XCTUnwrap(piece.path)
        let newPath = ((oldPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("Piece.FOUNTAIN")
        try FileManager.default.moveItem(
            at: collection.appendingPathComponent(oldPath),
            to: collection.appendingPathComponent(newPath))
        let index = try XCTUnwrap(store.manifest.structure.firstIndex { $0.id == piece.id })
        store.manifest.structure[index].path = newPath

        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted Upper Fountain")
        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination).url

        let newStore = try await ProjectStore.load(from: newProjectURL)
        XCTAssertEqual(newStore.manifest.type, .screenplay)
    }

    func test_promote_referenceFails() async throws {
        let (collection, store, _) = try await makeCollectionWithPiece(format: .markdown)
        // Make a reference to test against
        let tmp = collection.deletingLastPathComponent()
        let other = try await ProjectFactory.createShortStoryProject(
            named: "Other", in: tmp)
        let refPiece = try await store.addProjectReference(targetURL: other)

        let dest = tmp.appendingPathComponent("Promoted")
        do {
            _ = try await store.promotePieceToProject(
                pieceId: refPiece.id, destination: dest)
            XCTFail("expected throw — can't promote a reference")
        } catch {
            // ok
        }
    }

    /// **A promoted piece takes its intent with it** (M1A Task 8, contract 7).
    ///
    /// Before M1A a loose piece's craft intent was a research note under
    /// `pieces/<n>-<slug>/research/`, which `writePromotedManifest`'s prefix
    /// rewrite carried for free. After M1A it is a `.document(pieceId)`
    /// **statement** at `intent/<slug>.md` at the Collection's root, which no
    /// research prefix matches — so without this the writer's intent silently
    /// stays behind in a project whose piece is now a reference, reachable from
    /// nothing.
    func test_aPromotedPieceCarriesItsIntent() async throws {
        let (collection, store, piece) = try await makeCollectionWithPiece(format: .markdown)
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(piece.id))
        let intentDocument = try await Document.load(
            url: collection.appendingPathComponent(statement.path),
            device: "promote-intent-test", session: "s", presenter: nil)
        intentDocument.setFullText("Story A should end on the tide going out.")
        try await intentDocument.flushBurstNow()
        await intentDocument.close()

        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted With Intent")
        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination).url

        let promoted = try await ProjectStore.load(from: newProjectURL)
        let docId = try XCTUnwrap(
            TreeWalk.collect(in: promoted.manifest.structure,
                             where: { $0.type == .document }).first?.id)
        let carried = try XCTUnwrap(
            promoted.statement(kind: .intent, scope: .document(docId)),
            "the promoted project holds no intent for its one document; "
            + "statements: \(promoted.manifest.statements)")

        // The prose itself, read the way the Intent pane reads it: through
        // `Document.load`, which bootstraps the carried `.md` into the new
        // project's op log on first open.
        //
        // **Not through `derivedCache`, and the reason is worth knowing.** The
        // promoted project carries no `.maugham/ops/` — the piece's own
        // manuscript history is not staged either — so a derive-only read of
        // any of its documents answers "" until something opens them once. That
        // is promotion's pre-existing shape, inherited here rather than
        // introduced; what the carry has to preserve is the writer's words.
        let reopened = try await Document.load(
            url: newProjectURL.appendingPathComponent(carried.path),
            device: "promote-intent-test", session: "s2", presenter: nil)
        XCTAssertEqual(reopened.displayText,
                       "Story A should end on the tide going out.",
                       "the intent's manifest entry travelled and its words did not")
        await reopened.close()

        // …and it is no longer claimed by the Collection, whose file is gone.
        XCTAssertTrue(store.manifest.statements.isEmpty,
                      "the Collection still claims a statement whose file moved: "
                      + "\(store.manifest.statements)")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: collection.appendingPathComponent(statement.path).path),
            "the intent file is still in the Collection as well")
    }

    /// The control for the test above: a piece with no intent promotes to a
    /// project with no statements, and nothing is invented on the way.
    func test_aPromotedPieceWithNoIntentGetsNone() async throws {
        let (collection, store, piece) = try await makeCollectionWithPiece(format: .markdown)
        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted Without Intent")

        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination).url

        let promoted = try await ProjectStore.load(from: newProjectURL)
        XCTAssertTrue(promoted.manifest.statements.isEmpty,
                      "promotion invented an intent the writer never wrote")
    }

    // MARK: - The failure path (M1A Task 13)

    /// A Collection whose one loose piece owns everything a promotion moves: a
    /// main document with prose in it, a research note, a research *image*, and
    /// an intent statement. Returns the byte-exact contents so a rollback can be
    /// checked against what was there rather than against "a file exists".
    private struct PromotableWorld {
        let collection: URL
        let store: ProjectStore
        let piece: StructureItem
        /// project-relative path → the bytes that were at it before promotion.
        /// Keyed by the paths the store actually minted, so a change in slugging
        /// moves the assertions rather than quietly emptying them.
        let contentsBefore: [String: Data]

        /// The piece's own folder, project-relative.
        var pieceFolder: String {
            ((piece.path ?? "") as NSString).deletingLastPathComponent
        }
    }

    private func makeWorldWorthLosing() async throws -> PromotableWorld {
        let (collection, store, piece) = try await makeCollectionWithPiece(format: .markdown)

        // The manuscript itself.
        let docPath = try XCTUnwrap(piece.path)
        let manuscript = try await Document.load(
            url: collection.appendingPathComponent(docPath),
            device: "rollback-test", session: "s", presenter: nil)
        manuscript.setFullText("The tide went out and did not come back.")
        try await manuscript.flushBurstNow()
        await manuscript.close()

        // A research note, written through the store so the manifest knows it…
        let note = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Tide tables")
        let notePath = try XCTUnwrap(note.path)
        try Data("Spring tides, 1911. Not recoverable from anywhere.\n".utf8)
            .write(to: collection.appendingPathComponent(notePath))

        // …and an image asset, which is the class of thing with no op log and no
        // second copy anywhere in the project.
        let sourceImage = collection.deletingLastPathComponent()
            .appendingPathComponent("harbour-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x07, 0x11])
            .write(to: sourceImage)
        let asset = try await store.addPieceResearchAsset(
            pieceId: piece.id, fromURL: sourceImage)
        let assetPath = try XCTUnwrap(asset.path)

        // The intent statement, which travels from the Collection's ROOT.
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(piece.id))
        let intent = try await Document.load(
            url: collection.appendingPathComponent(statement.path),
            device: "rollback-test", session: "s", presenter: nil)
        intent.setFullText("End on the tide going out.")
        try await intent.flushBurstNow()
        await intent.close()

        var before: [String: Data] = [:]
        for path in [docPath, notePath, assetPath, statement.path] {
            before[path] = try Data(  // adr-0018-ok: byte-exactness IS the subject
                contentsOf: collection.appendingPathComponent(path))
        }
        return PromotableWorld(
            collection: collection, store: store, piece: piece,
            contentsBefore: before)
    }

    private func stagingTrees(besideDestinationIn parent: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
            .filter { $0.hasPrefix(".maugham-staging-") }
    }

    /// Put a **directory** where the staged project's manifest is about to be
    /// written. `Data.write(to:options:.atomic)` cannot overwrite a directory,
    /// so step 5 throws — a real error from real code, at a point where all
    /// three staging moves are done.
    private func occupyStagedManifestPath(besideDestinationIn parent: URL) {
        for tree in stagingTrees(besideDestinationIn: parent) {
            try? FileManager.default.createDirectory(
                at: parent.appendingPathComponent(tree)
                    .appendingPathComponent(ProjectManifest.fileName),
                withIntermediateDirectories: true)
        }
    }

    /// **The writer's research is not the promotion's to spend.**
    ///
    /// `promotePieceToProject` *moves* the piece's main document, its whole
    /// `research/` folder and its intent into a staging tree, and its failure
    /// path used to be `try? FileManager.default.removeItem(at: stagingURL)` —
    /// so any throw below the moves deleted all three with no move-back.
    ///
    /// The blast radius is what sets the severity. The main document and the
    /// intent each leave their op log behind in the Collection, and
    /// `Document+Load` treats a missing file as empty stored bytes with the log
    /// intact, so both re-materialise on next open. **`research/` has no op log
    /// at all** — research notes are plain-edited by design — so its notes and
    /// images went with nothing behind them. Unrecoverable.
    ///
    /// The failure is a real one: the hook occupies the staged manifest's path
    /// with a directory, and `writePromotedManifest`'s own `.write` throws.
    func test_aFailedPromotionLeavesThePiecesResearchWhereItWas() async throws {
        let world = try await makeWorldWorthLosing()
        let parent = world.collection.deletingLastPathComponent()
        let destination = parent.appendingPathComponent("Promoted Story A")

        var thrown: Error?
        do {
            _ = try await world.store.promotePieceToProject(
                pieceId: world.piece.id, destination: destination,
                afterStaging: {
                    // Occupy the staged manifest's path with a directory, so
                    // step 5's own `.write(to:options:.atomic)` throws.
                    self.occupyStagedManifestPath(besideDestinationIn: parent)
                })
            XCTFail("the promotion reported success with its manifest unwritable")
        } catch {
            thrown = error
        }
        XCTAssertNotNil(thrown, "the writer must be told the promotion failed")

        for (path, expected) in world.contentsBefore {
            let restored = world.collection.appendingPathComponent(path)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: restored.path),
                "a failed promotion destroyed \(path)")
            XCTAssertEqual(
                try? Data(contentsOf: restored), expected,  // adr-0018-ok: see above
                "\(path) came back changed")
        }

        // The folder itself, not merely its files: the pane filters research by
        // path prefix, and a piece with no `research/` has nowhere to put the
        // next note.
        let researchFolder = world.collection
            .appendingPathComponent("\(world.pieceFolder)/research")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: researchFolder.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "the piece's research/ folder did not come back as a folder")

        // And the tree that everything came out of is gone, because everything
        // came out of it.
        XCTAssertEqual(
            stagingTrees(besideDestinationIn: parent), [],
            "a completed rollback left its staging tree behind")
    }

    /// **When the compensation itself cannot complete, the files stay findable.**
    ///
    /// A move-back can fail — most plainly when something has taken the path
    /// back — and the tempting shape is to swallow it and remove the staging
    /// tree anyway, which produces a tidy error message and no files. So the
    /// tree is kept, the failure is recorded rather than shrugged off, and every
    /// *other* staged path still goes home: one stranded folder must not cost
    /// the writer the two that could have been returned.
    ///
    /// Both throws here are production code's. The hook only occupies two
    /// paths — the staged manifest's, so step 5 fails, and the piece's old
    /// `research/`, so `moveItem` back onto it fails.
    func test_aFailedMoveBackLeavesTheStagingTreeForRecovery() async throws {
        let world = try await makeWorldWorthLosing()
        let parent = world.collection.deletingLastPathComponent()
        let researchFolder = world.collection
            .appendingPathComponent("\(world.pieceFolder)/research")

        do {
            _ = try await world.store.promotePieceToProject(
                pieceId: world.piece.id,
                destination: parent.appendingPathComponent("Promoted Story A"),
                afterStaging: {
                    self.occupyStagedManifestPath(besideDestinationIn: parent)
                    // Take the research folder's path back, so its move-back
                    // fails on a destination that already exists.
                    try? FileManager.default.createDirectory(
                        at: researchFolder, withIntermediateDirectories: true)
                })
            XCTFail("the promotion reported success with its manifest unwritable")
        } catch {
            // The writer's error is the promotion's, not the cleanup's.
        }

        let remaining = stagingTrees(besideDestinationIn: parent)
        XCTAssertEqual(remaining.count, 1,
                       "the staging tree holding the un-returned research was "
                       + "deleted; trees found: \(remaining)")

        // Recoverable by hand means the notes are actually still in there.
        let strandedNote = parent
            .appendingPathComponent(try XCTUnwrap(remaining.first))
            .appendingPathComponent("research/tide-tables.md")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: strandedNote.path),
            "the staging tree survived but the research note is not in it")

        XCTAssertFalse(
            world.store._debugPromotionStrandedMoveBacks.isEmpty,
            "the failed move-back was silent")
        XCTAssertTrue(
            world.store._debugPromotionStrandedMoveBacks
                .contains { $0.contains(researchFolder.path) },
            "the record does not name what was stranded: "
            + "\(world.store._debugPromotionStrandedMoveBacks)")

        // Per-move isolation: the two that could go home did — every recorded
        // path except the research folder, which is the one that was blocked.
        for path in world.contentsBefore.keys
        where !path.hasPrefix("\(world.pieceFolder)/research/") {
            XCTAssertEqual(
                try? Data(contentsOf:  // adr-0018-ok: byte-exactness IS the subject
                            world.collection.appendingPathComponent(path)),
                world.contentsBefore[path],
                "\(path) was not returned, though nothing was in its way")
        }
    }

    /// **Once the staged tree has become the destination, there is nothing to
    /// roll back — and trying would be the bug.**
    ///
    /// Step 8 converts the Collection's piece into a reference, and it runs
    /// *after* the staged project has been moved into place. A compensation that
    /// reached for the staged paths here would find them gone; one that chased
    /// them into the destination would be undoing a promotion that, on disk,
    /// already happened. The writer's files are whole at the destination, and
    /// the Collection is left with a stale entry — a wrong label on the right
    /// files, which is the recoverable half of the trade.
    ///
    /// The failure is real: the hook occupies `.maugham-link.json`'s path in the
    /// piece folder, so step 8's own write throws.
    func test_aFailureAfterTheDestinationExistsLeavesTheFilesAtTheDestination() async throws {
        let world = try await makeWorldWorthLosing()
        let parent = world.collection.deletingLastPathComponent()
        let destination = parent.appendingPathComponent("Promoted Story A")
        let linkPath = world.collection
            .appendingPathComponent("\(world.pieceFolder)/.maugham-link.json")
        let docPath = try XCTUnwrap(world.piece.path)
        let notePath = "\(world.pieceFolder)/research/tide-tables.md"

        do {
            _ = try await world.store.promotePieceToProject(
                pieceId: world.piece.id, destination: destination,
                afterStaging: {
                    try? FileManager.default.createDirectory(
                        at: linkPath, withIntermediateDirectories: true)
                })
            XCTFail("the promotion reported success with its link file unwritable")
        } catch {
            // The writer's error is the promotion's own.
        }

        // The prose is at the destination, byte for byte, under the promoted
        // project's own layout — the piece folder's paths rewritten to
        // `manuscript/` and `research/`.
        XCTAssertEqual(
            try? Data(contentsOf:  // adr-0018-ok: byte-exactness IS the subject
                        destination.appendingPathComponent(
                            "manuscript/\((docPath as NSString).lastPathComponent)")),
            try XCTUnwrap(world.contentsBefore[docPath]),
            "the manuscript is at neither the Collection nor the destination")
        XCTAssertEqual(
            try? Data(contentsOf:  // adr-0018-ok: as above
                        destination.appendingPathComponent("research/tide-tables.md")),
            try XCTUnwrap(world.contentsBefore[notePath]),
            "the research note is at neither the Collection nor the destination")

        XCTAssertEqual(stagingTrees(besideDestinationIn: parent), [],
                       "the staging tree was consumed by the move; nothing "
                       + "should have re-created it")
        XCTAssertTrue(
            world.store._debugPromotionStrandedMoveBacks.isEmpty,
            "a rollback ran against paths the move had already consumed: "
            + "\(world.store._debugPromotionStrandedMoveBacks)")

        // The Collection's entry did not get its half of the swap.
        let piece = try XCTUnwrap(
            world.store.manifest.structure.first { $0.id == world.piece.id })
        XCTAssertEqual(piece.pieceKind, .loose,
                       "the piece was converted by a step that threw")
    }

    /// The control, and it must pass against unmodified code: a promotion that
    /// works still produces the project and still takes its staging tree with
    /// it. Task 13 adds nothing to the happy path.
    func test_aSuccessfulPromotionStillRemovesItsStagingTree() async throws {
        let world = try await makeWorldWorthLosing()
        let parent = world.collection.deletingLastPathComponent()
        let destination = parent.appendingPathComponent("Promoted Story A")

        let newProjectURL = try await world.store.promotePieceToProject(
            pieceId: world.piece.id, destination: destination).url

        let promoted = try await ProjectStore.load(from: newProjectURL)
        XCTAssertEqual(promoted.manifest.title, "Story A")
        XCTAssertEqual(stagingTrees(besideDestinationIn: parent), [],
                       "a successful promotion left its staging tree behind")
        XCTAssertTrue(
            world.store._debugPromotionStrandedMoveBacks.isEmpty,
            "a successful promotion stranded something")
    }

    func test_promotedProject_carriedResearch_isDerivedForItsDocument() async throws {
        // Collection with a piece that owns one research note.
        let parent = TestTemp.root
            .appendingPathComponent("promote-derive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "C", in: parent)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", format: .markdown)
        let note = try await store.addPieceResearchNote(pieceId: piece.id, title: "Carried")

        let dest = parent.appendingPathComponent("StoryA")
        _ = try await store.promotePieceToProject(pieceId: piece.id, destination: dest)

        // The promoted single-doc project derives the carried research for its
        // document with no re-linking (spec §6: promotion follow-through).
        let promoted = try await ProjectStore.load(from: dest)
        let docId = try XCTUnwrap(
            TreeWalk.collect(in: promoted.manifest.structure,
                             where: { $0.type == .document }).first?.id)
        let derived = promoted.derivedResearchItems(forDocumentId: docId)
        XCTAssertTrue(derived.contains { $0.title == note.title },
                      "carried research must appear derived; got: \(derived.map(\.title))")
        XCTAssertTrue(derived.allSatisfy { $0.path?.hasPrefix("research/") == true },
                      "carried paths must be rewritten to research/…")
    }

    // MARK: - Pass state travels with the prose (M3 P1 Task 2)

    /// The promoted project's document carries the piece's review state, the
    /// same way it carries `status` — the two are set in the same place in
    /// `writePromotedManifest`, and a promotion that kept the writer's status
    /// but dropped which passes they had finished would be a silent loss of
    /// exactly the record the Review board is about.
    func test_aPromotedPieceCarriesItsStatusAndItsPassStates() async throws {
        let (collection, store, piece) = try await makeCollectionWithPiece(format: .markdown)
        // `status` is legacy-read-only as of M3 P1 Task 4 (no store verb
        // writes it any more), so the fixture seeds it directly — the CARRY is
        // what this test is about, and a project written by an older build
        // still arrives with the string set.
        let idx = try XCTUnwrap(store.manifest.structure.firstIndex { $0.id == piece.id })
        store.manifest.structure[idx].status = "revising"
        store.manifest.structure[idx].passStates = [
            "structural": .done, "line": .inProgress, "sensitivity": .unknown("awaiting_reader"),
        ]

        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted With State")
        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination).url

        let promoted = try await ProjectStore.load(from: newProjectURL)
        let doc = try XCTUnwrap(TreeWalk.collect(in: promoted.manifest.structure,
                                                 where: { $0.type == .document }).first)
        XCTAssertEqual(doc.status, "revising")
        XCTAssertEqual(doc.passStates?["structural"], .done)
        XCTAssertEqual(doc.passStates?["line"], .inProgress)
        XCTAssertEqual(doc.passStates?["sensitivity"], .unknown("awaiting_reader"),
                       "a newer build's state must survive the promotion verbatim")
    }

    /// …and the Collection's own row, now a reference, keeps none of it. A
    /// reference piece owns no prose, so the fields describing prose are
    /// cleared — `status` already was; `passStates` is cleared beside it, or
    /// the board would draw a stale finished-Structural cell against a project
    /// whose real state lives in its own manifest.
    func test_convertingToAReferenceClearsPassStatesBesideStatus() async throws {
        let (collection, store, piece) = try await makeCollectionWithPiece(format: .markdown)
        // `status` is legacy-read-only as of M3 P1 Task 4 (no store verb
        // writes it any more), so the fixture seeds it directly — the CARRY is
        // what this test is about, and a project written by an older build
        // still arrives with the string set.
        let idx = try XCTUnwrap(store.manifest.structure.firstIndex { $0.id == piece.id })
        store.manifest.structure[idx].status = "revising"
        store.manifest.structure[idx].passStates = ["structural": .done]

        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted Then Cleared")
        _ = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination)

        let converted = try XCTUnwrap(store.manifest.structure.first { $0.id == piece.id })
        XCTAssertEqual(converted.pieceKind, .reference)
        XCTAssertNil(converted.status)
        XCTAssertNil(converted.passStates,
                     "a reference piece must not keep the prose's pass states")

        // …and the cleared state must survive the round-trip to disk, not just
        // live in memory.
        let reloaded = try await ProjectStore.load(from: collection)
        let onDisk = try XCTUnwrap(reloaded.manifest.structure.first { $0.id == piece.id })
        XCTAssertNil(onDisk.passStates)
    }
}

/// **A piece's promotion brings the book's figures** (report plan 6c Task 5,
/// rulings Q-4 to Q-6; Denver 2026-10-25: promotion re-creates the figures,
/// their history stays in the Collection). The piece's own figures move —
/// re-created in the new project, then removed from the Collection through
/// the removal route — and the figures its text or their formulas name are
/// copied and stay. A window holds the Collection throughout, as in
/// production.
@MainActor
final class PromotePieceFigureTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = TestTemp.root.appendingPathComponent("promote-figures-\(UUID().uuidString)")
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

    /// A Collection holding one loose piece whose text says `text`, with a
    /// window over it. The window is returned so the caller holds it: the
    /// project store's link to it is weak.
    private func openCollection(text: String) async throws -> (ProjectStore, DocumentStore, StructureItem) {
        let collection = try await ProjectFactory.createCollectionProject(named: "Anthology", in: root)
        let projectStore = try await ProjectStore.load(from: collection)
        let piece = try await projectStore.addLoosePiece(title: "Story A", format: .markdown)
        let store = try await DocumentStore.open(url: collection)
        projectStore.documentStore = store
        store.projectStore = projectStore
        let doc = try await Document.load(
            url: collection.appendingPathComponent(try XCTUnwrap(piece.path)),
            actor: .author, session: "boot", presenter: nil)
        doc.setFullText(text)
        await doc.close()
        return (projectStore, store, piece)
    }

    /// The promoted project at `url`, with a window over it.
    private func openProject(_ url: URL) async throws -> (ProjectStore, DocumentStore) {
        let projectStore = try await ProjectStore.load(from: url)
        let store = try await DocumentStore.open(url: url)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (projectStore, store)
    }

    private func png(_ name: String, _ color: NSColor = .blue) throws -> URL {
        let dir = root.appendingPathComponent("png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let url = dir.appendingPathComponent(name)
        try ImagePasteHandler.encodePNG(image).write(to: url)
        return url
    }

    private func lines(of url: URL) throws -> [Data] {
        try Data(contentsOf: url).split(separator: UInt8(0x0A), omittingEmptySubsequences: true).map { Data($0) }
    }

    /// Every op of `figureId`'s stream under `projectURL`, by op id.
    private func ops(_ figureId: String, in projectURL: URL) throws -> [Op] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return try OpLogStore.opLogFileURLs(forDocId: figureId, in: projectURL).flatMap { url in
            try lines(of: url).compactMap { line -> Op? in
                OpLogChain.isSealLine(line) ? nil : try? dec.decode(Op.self, from: line)
            }
        }.sorted { $0.opId < $1.opId }
    }

    private func stagingTrees(in parent: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
            .filter { $0.hasPrefix(".maugham-staging-") }
    }

    private func key(_ table: FigureTable?, _ row: Int, _ column: Int) throws -> CellKey {
        let table = try XCTUnwrap(table)
        return CellKey(row: table.rows[row], column: table.columns[column])
    }

    // MARK: - Review Focus 3: what is carried, where it points, what stays

    /// The piece's text cites a whole-book table (w1) whose formula reads a
    /// second whole-book table (w2) and a Research note that stays in the
    /// Collection, and cites another piece's table (p2). Both whole-book
    /// tables and p2 arrive with their ids, whole-book in the new book; the
    /// piece's own table and picture arrive as the new document's; w1's
    /// formula computes there; the Research read is listed and said. The
    /// Collection keeps the copied figures and its unnamed one, and the
    /// moved ones leave it as Trash entries a restore brings back. A promoted
    /// figure opens and edits in the new project, and the new project's
    /// first checkpoint points at every figure.
    func test_promotionCarriesTheFiguresAndRepointsThem_reviewFocus3() async throws {
        let (projectStore, store, piece) = try await openCollection(text: "As @tbl:w1 and @tbl:p2 show.\n")
        defer { withExtendedLifetime(store) {} }
        let storyB = try await projectStore.addLoosePiece(title: "Story B", format: .markdown)
        let prices = try await projectStore.addResearchTextNote(parentId: nil, title: "Prices")

        var t2 = FigureTable(rows: 1, columns: 1)
        let a1 = try key(t2, 0, 0)
        t2.setCell(Cell(content: .value(.number(21))), at: a1)
        let w2 = try await projectStore.createFigureStream(
            kind: .table, table: t2, name: "w2", piece: nil, source: nil, site: "test")
        var t1 = FigureTable(rows: 1, columns: 2)
        let (computes, readsResearch) = (try key(t1, 0, 0), try key(t1, 0, 1))
        t1.setCell(Cell(content: .formula(Formula(.binary(.multiply,
            .ref(FormulaRef(target: .figure(id: w2.id), anchor: .id(row: a1.row, column: a1.column))),
            .number(2))))), at: computes)
        t1.setCell(Cell(content: .formula(Formula(
            .ref(FormulaRef(target: .research(id: prices.id), anchor: .position(row: 0, column: 0)))))),
            at: readsResearch)
        let w1 = try await projectStore.createFigureStream(
            kind: .table, table: t1, name: "w1", piece: nil, source: nil, site: "test")
        let p2 = try await projectStore.createFigure(kind: .table, name: "p2", piece: storyB.id)
        let own = try await projectStore.createFigure(kind: .table, name: "own", piece: piece.id)
        let map = try await projectStore.createImageFigure(fromURL: try png("map.png"), piece: piece.id)
        let unnamed = try await projectStore.createFigure(kind: .table, name: "unnamed", piece: nil)
        let picture = try Data(contentsOf: projectStore.url.appendingPathComponent(map.path))

        let destination = root.appendingPathComponent("Promoted Story A")
        let promotion = try await projectStore.promotePieceToProject(pieceId: piece.id, destination: destination)

        // What did not carry whole, as data and as the window's sentence.
        XCTAssertEqual(promotion.url, destination)
        XCTAssertEqual(promotion.figureProblems, [
            FigureCarryProblem(figureId: w1.id, cell: readsResearch, source: prices.id, read: .formula),
        ])
        XCTAssertEqual(promotion.figureNotice,
                       "w1 reads Prices, which stays in the Collection, so it shows #REF! here.")

        // The new book's registry: ids kept; the piece's own name the new
        // document, every copied one is whole-book.
        let (promoted, newStore) = try await openProject(destination)
        defer { withExtendedLifetime(newStore) {} }
        let newDoc = try XCTUnwrap(promoted.manifest.structure.first).id
        XCTAssertNotEqual(newDoc, piece.id)
        let carried = try XCTUnwrap(promoted.manifest.figures)
        XCTAssertEqual(carried.map(\.id), [own.id, map.id, w2.id, w1.id, p2.id])
        XCTAssertEqual(carried.map(\.piece), [newDoc, newDoc, nil, nil, nil],
                       "moved → the new document; copied (whole-book or Story B's) → whole-book")
        XCTAssertEqual(carried.map(\.name), ["own", "map", "w2", "w1", "p2"])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(map.path)), picture)

        // w1's formula computes in the new book; its Research read does not.
        let w1Here = try XCTUnwrap(carried.first { $0.id == w1.id })
        let render = await newStore.figureRenderText(for: w1Here)
        let rendered = try XCTUnwrap(render)
        XCTAssertTrue(rendered.hasPrefix("42,"), rendered)
        XCTAssertTrue(rendered.contains("#REF!"), rendered)

        // The Collection keeps what was copied and what was never carried…
        XCTAssertEqual(projectStore.manifest.figures?.map(\.id), [w2.id, w1.id, p2.id, unnamed.id])
        XCTAssertEqual(projectStore.manifest.figures?.first { $0.id == p2.id }?.piece, storyB.id,
                       "a copy leaves the Collection's record alone")
        // …and the moved ones are in its Trash, restorable.
        let entries = try await projectStore.trashStore.list().filter { $0.subject == .figure }
        XCTAssertEqual(Set(entries.map(\.displayTitle)), ["Table: own", "Figure: map"])
        let ownEntry = try XCTUnwrap(entries.first { $0.displayTitle == "Table: own" })
        try await projectStore.restoreTrashEntry(id: ownEntry.id)
        XCTAssertTrue(projectStore.manifest.figures?.contains { $0.id == own.id } == true,
                      "the Trash entry brings the Collection's figure back")

        // A promoted figure opens and edits in the new project.
        try await newStore.withFigureHost(own.id) { host in
            try await host.setCell(Cell(content: .value(.text("edited"))), at: try key(host.state.table, 0, 0))
        }
        let ownState = try await newStore.withFigureHost(own.id) { $0.state }
        XCTAssertEqual(ownState.table[try key(ownState.table, 0, 0)]?.content, .value(.text("edited")))

        // The new project's first checkpoint points at every figure.
        let checkpoint = try await CheckpointCapture.run(
            projectURL: destination, activeDocId: newDoc, allDocIds: [newDoc],
            figureIds: carried.map(\.id), device: Document.loadIdentities[.author].deviceId,
            session: "first", label: "First")
        for record in carried {
            XCTAssertEqual(checkpoint.docPointers[record.id], try ops(record.id, in: destination).last?.opId,
                           "\(record.name) is in the first checkpoint")
        }
    }

    /// A moved figure the Collection cannot take out (here, no window holds
    /// the Collection by the time of the removal, so the removal route
    /// refuses) is listed and said, and stays in the Collection; the
    /// promotion itself has happened and is not reported as a failure.
    func test_aMovedFigureThatWillNotLeaveTheCollectionIsListed() async throws {
        let (projectStore, store, piece) = try await openCollection(text: "Words.\n")
        let own = try await projectStore.createFigure(kind: .table, name: "own", piece: piece.id)
        projectStore.documentStore = nil
        withExtendedLifetime(store) {}

        let promotion = try await projectStore.promotePieceToProject(
            pieceId: piece.id, destination: root.appendingPathComponent("Promoted Story A"))

        XCTAssertEqual(promotion.figureProblems.map(\.read), [.notRemoved])
        XCTAssertEqual(promotion.figureProblems.first?.figureId, own.id)
        XCTAssertTrue(promotion.figureNotice?.hasPrefix("own came along, but it couldn\u{2019}t be taken out of the Collection") == true,
                      promotion.figureNotice ?? "nil")
        XCTAssertEqual(projectStore.manifest.figures?.map(\.id), [own.id], "it stands in both")
        let promoted = try await ProjectStore.load(from: promotion.url)
        XCTAssertEqual(promoted.manifest.figures?.map(\.id), [own.id])
    }

    /// The window's sentence: one line per figure, problem and source —
    /// several cells reading one source say it once — naming figures and
    /// Research items by name, and nil when there is nothing to say.
    func test_theNoticeSaysEachProblemOnce() {
        let (a, b) = (CellKey(row: RowID("r1"), column: ColumnID("c1")),
                      CellKey(row: RowID("r2"), column: ColumnID("c1")))
        let notice = PiecePromotion.notice(
            for: [
                FigureCarryProblem(figureId: "fig-1", cell: a, source: "res-1", read: .formula),
                FigureCarryProblem(figureId: "fig-1", cell: b, source: "res-1", read: .formula),
                FigureCarryProblem(figureId: "fig-2", cell: a, source: "fig-3", read: .pin),
                FigureCarryProblem(figureId: "fig-4", cell: nil, source: "chart", read: .unknownKind),
            ],
            figureNames: ["fig-1": "w1", "fig-2": "costs", "fig-3": "rates", "fig-4": "trend"],
            researchTitles: ["res-1": "Prices"])
        XCTAssertEqual(notice, """
            w1 reads Prices, which stays in the Collection, so it shows #REF! here.
            costs keeps the value it pinned from rates, which stays in the Collection.
            trend was made by a newer Maugham, so it stays in the Collection.
            """)
        XCTAssertNil(PiecePromotion.notice(for: [], figureNames: [:], researchTitles: [:]))
    }

    // MARK: - Review Focus 4: a failure after the figures are staged

    /// The promotion fails after the figures are written into staging (the
    /// staged manifest's path is occupied, so step 5's own write throws):
    /// the staging tree is rolled back, the Collection is unchanged — every
    /// figure record, stream, picture, Research item and table sidecar — and
    /// no figure has gone to its Trash.
    func test_aFailureAfterTheFiguresAreStaged_leavesTheCollectionAsItWas() async throws {
        let (projectStore, store, piece) = try await openCollection(text: "As @tbl:shared shows.\n")
        defer { withExtendedLifetime(store) {} }
        let shared = try await projectStore.createFigure(kind: .table, name: "shared", piece: nil)
        let own = try await projectStore.createFigure(kind: .table, name: "own", piece: piece.id)
        let map = try await projectStore.createImageFigure(fromURL: try png("map.png"), piece: piece.id)
        let parked = try await projectStore.createFigure(kind: .table, name: "parked", piece: piece.id)
        let copy = try await projectStore.sendToResearch(figureId: parked.id, scope: .document(piece.id))
        let sidecar = try ResearchTableSidecar.fileURL(forItem: copy.id, in: projectStore.url)
        let sidecarBytes = try Data(contentsOf: sidecar)

        let figuresBefore = projectStore.manifest.figures
        let researchBefore = projectStore.manifest.research
        let streamsBefore = try [shared, own, map, parked].map { try ops($0.id, in: projectStore.url) }
        let picture = projectStore.url.appendingPathComponent(map.path)
        let pictureBytes = try Data(contentsOf: picture)

        var stagedStreams: [String: Bool] = [:]
        var stagedSidecar = false
        do {
            _ = try await projectStore.promotePieceToProject(
                pieceId: piece.id, destination: root.appendingPathComponent("Promoted Story A"),
                afterStaging: {
                    for tree in self.stagingTrees(in: self.root) {
                        let staging = self.root.appendingPathComponent(tree)
                        for record in [shared, own, map, parked] {
                            stagedStreams[record.id] = !OpLogStore.opLogFileURLs(
                                forDocId: record.id, in: staging).isEmpty
                        }
                        stagedSidecar = (try? ResearchTableSidecar.fileURL(forItem: copy.id, in: staging))
                            .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                        try? FileManager.default.createDirectory(
                            at: staging.appendingPathComponent(ProjectManifest.fileName),
                            withIntermediateDirectories: true)
                    }
                })
            XCTFail("the promotion reported success with its manifest unwritable")
        } catch {
            // The writer's error is the promotion's own.
        }

        XCTAssertEqual(stagedStreams, [shared.id: true, own.id: true, map.id: true, parked.id: true],
                       "precondition: the figures were written into staging before the failure")
        XCTAssertTrue(stagedSidecar, "precondition: the sidecar was staged")
        XCTAssertEqual(stagingTrees(in: root), [], "the staging tree was rolled back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Promoted Story A").path))

        XCTAssertEqual(projectStore.manifest.figures, figuresBefore, "no figure record left the Collection")
        XCTAssertEqual(projectStore.manifest.research, researchBefore)
        XCTAssertEqual(try [shared, own, map, parked].map { try ops($0.id, in: projectStore.url) }, streamsBefore)
        XCTAssertEqual(try Data(contentsOf: picture), pictureBytes)
        XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBytes, "the sidecar came back")
        let trashed = try await projectStore.trashStore.list().filter { $0.subject == .figure }
        XCTAssertEqual(trashed.map(\.displayTitle), [], "no figure went to the Trash")
        let reloaded = try await ProjectStore.load(from: projectStore.url)
        XCTAssertEqual(reloaded.manifest.figures, figuresBefore, "and on disk")
    }

    // MARK: - The chain across the boundary, and Review Focus 5

    /// Promote, then work in the new project — append to a carried table, a
    /// carried picture and the re-parked figure (brought back first, Review
    /// Focus 5: it arrives in Research with its working copy and sidecar) —
    /// and reload with a fresh cache: no diagnostics, nothing quarantined,
    /// held or set aside, every line the author's and verified, one file per
    /// figure, and one unbroken chain from the lines staging wrote to the
    /// ones the destination appended.
    func test_theChainHoldsAcrossTheBoundary_withTheDeviceStateThatStaged() async throws {
        try await promoteThenWorkThenReload(freshDeviceState: false)
    }

    /// The same, with this Mac's chain memory gone between the promotion and
    /// the first edit in the new project (a fresh device state).
    func test_theChainHoldsAcrossTheBoundary_withAFreshDeviceState() async throws {
        try await promoteThenWorkThenReload(freshDeviceState: true)
    }

    private func promoteThenWorkThenReload(freshDeviceState: Bool) async throws {
        let (projectStore, store, piece) = try await openCollection(text: "Words.\n")
        defer { withExtendedLifetime(store) {} }
        var t = FigureTable(rows: 2, columns: 2)
        t.setCell(Cell(content: .value(.number(5))), at: try key(t, 0, 0))
        let own = try await projectStore.createFigureStream(
            kind: .table, table: t, name: "own", piece: piece.id, source: nil, site: "test")
        let map = try await projectStore.createImageFigure(fromURL: try png("map.png"), piece: piece.id)
        let parked = try await projectStore.createFigure(kind: .table, name: "parked", piece: piece.id)
        let copy = try await projectStore.sendToResearch(figureId: parked.id, scope: .document(piece.id))

        let destination = root.appendingPathComponent("Promoted Story A")
        let promotion = try await projectStore.promotePieceToProject(pieceId: piece.id, destination: destination)
        XCTAssertEqual(promotion.figureProblems, [])
        XCTAssertNil(promotion.figureNotice)
        let figures = [own, map, parked]
        let staged = try figures.map { try ops($0.id, in: destination).count }

        if freshDeviceState {
            Document.deviceStateForTesting = OpLogDeviceState(
                fileURL: root.appendingPathComponent("fresh-op-log-state.json"))
        }
        let (promoted, newStore) = try await openProject(destination)
        let newDoc = try XCTUnwrap(promoted.manifest.structure.first).id

        // Review Focus 5: in Research with its working copy and sidecar…
        let item = try XCTUnwrap(promoted.manifest.research.first { $0.id == copy.id })
        XCTAssertTrue(item.path?.hasPrefix("research/") == true, "\(item.path ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(try XCTUnwrap(item.path)).path), "its working copy")
        XCTAssertEqual(try ResearchTableSidecar.read(forItem: copy.id, in: destination)?.figureId, parked.id,
                       "its sidecar names its figure")
        let parkedHere = try await newStore.withFigureHost(parked.id) { $0.state.parked }
        XCTAssertEqual(parkedHere?.itemId, copy.id, "parked, naming its working copy")
        // …and bringing it back there works.
        try await promoted.bringBack(researchItemId: copy.id, piece: newDoc)
        let back = try await newStore.withFigureHost(parked.id) { $0.state }
        XCTAssertNil(back.parked, "brought back in the new project")

        // Appends in the new project: a carried table, a carried picture,
        // the brought-back figure.
        try await newStore.withFigureHost(own.id) { host in
            try await host.setCell(Cell(content: .value(.number(6))), at: try key(host.state.table, 1, 1))
        }
        try await newStore.withFigureHost(map.id) { host in
            try await host.setImage(fromURL: try png("map.png", .red))
        }
        try await newStore.withFigureHost(parked.id) { host in
            try await host.setCell(Cell(content: .value(.text("back"))), at: try key(host.state.table, 0, 0))
        }
        await newStore.close()

        // Reload with a fresh cache.
        let author = Document.loadIdentities[.author].deviceId
        let trust = try TrustResolution.resolve(
            projectURL: destination, identities: Document.loadIdentities, cache: Document.loadRegistryCache)
        let facts = DocumentClass.Facts(promoted.manifest)
        let cache = FigureCache()
        for (record, stagedCount) in zip(figures, staged) {
            let all = try ops(record.id, in: destination)
            XCTAssertGreaterThan(all.count, stagedCount, "\(record.name): the destination appended")
            XCTAssertEqual(Set(all.map(\.device)), [author], "\(record.name): every line the author's")

            let fresh = try cache.state(forFigureId: record.id, in: destination, trust: trust, facts: facts)
            XCTAssertEqual(fresh.diagnostics, [], record.name)
            let host = try await FigureDocument.load(
                figureId: record.id, projectURL: destination, actor: .author,
                session: "reread", presenter: nil, documentStore: nil)
            let provenance = try XCTUnwrap(host.provenance)
            XCTAssertEqual(host.state.diagnostics, [], record.name)
            XCTAssertEqual(host.state, fresh, "\(record.name): the cache and the host read the same")
            let fileLines = try OpLogStore.opLogFileURLs(forDocId: record.id, in: destination)
                .reduce(0) { $0 + (try lines(of: $1).count) }
            XCTAssertEqual(provenance.verifiedLines, fileLines, "\(record.name): every line, op and seal, verified")
            XCTAssertEqual(provenance.quarantinedLines, 0, "\(record.name): nothing set aside")
            XCTAssertEqual(provenance.pendingLines, 0, "\(record.name): nothing held")
            XCTAssertEqual(provenance.unsealedLines, 0, record.name)
            XCTAssertEqual(provenance.unsignedHistoryLines, 0, record.name)
            XCTAssertEqual(provenance.legacyLines, 0, record.name)
            await host.close()
            XCTAssertEqual(OpLogQuarantine.records(forDocId: record.id, in: destination).count, 0,
                           "\(record.name): nothing quarantined")

            // One file, one chain: staging's lines and the destination's.
            let files = OpLogStore.opLogFileURLs(forDocId: record.id, in: destination)
            XCTAssertEqual(files.count, 1, "\(record.name): one op file")
            let chain = try lines(of: try XCTUnwrap(files.first))
            for (index, line) in chain.enumerated() {
                let expected = index == 0 ? OpLogChain.genesis : OpLogChain.lineHash(chain[index - 1])
                if OpLogChain.isSealLine(line) {
                    XCTAssertEqual(OpLogChain.Seal.parse(line)?.head, expected, "\(record.name): seal \(index)")
                } else {
                    XCTAssertEqual(OpLogChain.prev(ofLine: line), .some(expected), "\(record.name): line \(index)")
                }
            }
        }
    }
}

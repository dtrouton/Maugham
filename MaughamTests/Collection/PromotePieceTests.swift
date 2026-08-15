import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class PromotePieceTests: XCTestCase {
    private func makeCollectionWithPiece(
        mode: PieceMode
    ) async throws -> (collection: URL, store: ProjectStore, piece: StructureItem) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collectionURL = try await ProjectFactory.createCollectionProject(
            named: "Anthology", in: tmp)
        let store = try await ProjectStore.load(from: collectionURL)
        let piece = try await store.addLoosePiece(title: "Story A", mode: mode)
        return (collectionURL, store, piece)
    }

    func test_promote_prose_createsShortStoryProject() async throws {
        let (collection, store, piece) = try await makeCollectionWithPiece(mode: .prose)
        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted Story A")

        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination)

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
        let (collection, store, piece) = try await makeCollectionWithPiece(mode: .screenplay)
        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted Screenplay")

        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination)

        let newStore = try await ProjectStore.load(from: newProjectURL)
        XCTAssertEqual(newStore.manifest.type, .screenplay)
    }

    func test_promote_referenceFails() async throws {
        let (collection, store, _) = try await makeCollectionWithPiece(mode: .prose)
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
        let (collection, store, piece) = try await makeCollectionWithPiece(mode: .prose)
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
            pieceId: piece.id, destination: destination)

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
        let (collection, store, piece) = try await makeCollectionWithPiece(mode: .prose)
        let destination = collection.deletingLastPathComponent()
            .appendingPathComponent("Promoted Without Intent")

        let newProjectURL = try await store.promotePieceToProject(
            pieceId: piece.id, destination: destination)

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
        let (collection, store, piece) = try await makeCollectionWithPiece(mode: .prose)

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
            pieceId: world.piece.id, destination: destination)

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
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("promote-derive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(named: "C", in: parent)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
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
        let (collection, store, piece) = try await makeCollectionWithPiece(mode: .prose)
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
            pieceId: piece.id, destination: destination)

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
        let (collection, store, piece) = try await makeCollectionWithPiece(mode: .prose)
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

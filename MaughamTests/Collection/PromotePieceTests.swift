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
}

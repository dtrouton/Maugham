import XCTest
import MaughamCore
@testable import Maugham

/// Contract tests for the Review Passes editor (M3 P1 Task 9): the store
/// verb `ProjectStore.setReviewPasses` and the pure array transforms behind
/// `ProjectSettingsSheet`'s list editor (`ReviewPassEditorLogic`).
@MainActor
final class ReviewPassEditorTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeNovel() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(named: "PassEditor", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    // MARK: - setReviewPasses: store round trip

    func test_setReviewPasses_persistsThroughAManifestRoundTrip() async throws {
        let (url, store, ds) = try await makeNovel()
        let custom = [
            ReviewPass(id: "beta", name: "Beta Read"),
            ReviewPass(id: "final", name: "Final Pass"),
        ]

        try await store.setReviewPasses(custom)

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(reloaded.manifest.reviewPasses, custom)
        XCTAssertEqual(reloaded.manifest.effectiveReviewPasses, custom)
        await ds.close()
    }

    func test_setReviewPasses_movesTheProjectsModifiedStamp() async throws {
        let (_, store, ds) = try await makeNovel()
        let before = store.manifest.modified
        try await Task.sleep(for: .milliseconds(1100))

        try await store.setReviewPasses([ReviewPass(id: "beta", name: "Beta Read")])

        XCTAssertGreaterThan(store.manifest.modified, before)
        await ds.close()
    }

    /// Task 1's rule, surfaced through the editor's own write path: an
    /// emptied list is stored as `[]`, and `effectiveReviewPasses` reads
    /// that as "not customized," falling back to the four presets — the
    /// editor's footer text says as much so deleting the last pass isn't a
    /// surprise.
    func test_setReviewPasses_deletingEveryPass_storesEmptyAndReadsAsPresets() async throws {
        let (url, store, ds) = try await makeNovel()
        try await store.setReviewPasses([ReviewPass(id: "beta", name: "Beta Read")])

        try await store.setReviewPasses([])

        XCTAssertEqual(store.manifest.reviewPasses, [])
        XCTAssertEqual(store.manifest.effectiveReviewPasses, ReviewPass.presets)

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(reloaded.manifest.reviewPasses, [])
        XCTAssertEqual(reloaded.manifest.effectiveReviewPasses, ReviewPass.presets)
        await ds.close()
    }

    /// The stale-id rule: a deleted pass's per-piece states are never swept
    /// by this verb. They sit untouched in `passStates` and become live
    /// again — visible on the board and the ladder — the moment a pass with
    /// the same id is added back.
    func test_setReviewPasses_deletedPassStateLingersAndReappearsOnReAdd() async throws {
        let (url, store, ds) = try await makeNovel()
        let id = store.manifest.structure[0].id
        try await store.setPassState(id: id, passId: "structural", .done)
        XCTAssertTrue(store.manifest.effectiveReviewPasses.contains { $0.id == "structural" })

        // Customize the list without "structural" — deletes the column, but
        // per the rule below, not the recorded state.
        let withoutStructural = ReviewPass.presets.filter { $0.id != "structural" }
        try await store.setReviewPasses(withoutStructural)

        var reloaded = try await ProjectStore.load(from: url)
        var item = try XCTUnwrap(reloaded.manifest.structure.first { $0.id == id })
        XCTAssertEqual(item.passStates?["structural"], .done, "the state must linger untouched")
        XCTAssertFalse(
            reloaded.manifest.effectiveReviewPasses.contains { $0.id == "structural" },
            "the column itself is gone")

        // Re-add the same id: the lingering state is immediately usable again.
        try await store.setReviewPasses(ReviewPass.presets)

        reloaded = try await ProjectStore.load(from: url)
        item = try XCTUnwrap(reloaded.manifest.structure.first { $0.id == id })
        XCTAssertEqual(item.passStates?["structural"], .done)
        XCTAssertTrue(reloaded.manifest.effectiveReviewPasses.contains { $0.id == "structural" })
        await ds.close()
    }

    // MARK: - ReviewPassEditorLogic.added

    func test_added_mintsASlugFromTheName() {
        let result = ReviewPassEditorLogic.added(to: [], name: "Read Aloud")
        XCTAssertEqual(result, [ReviewPass(id: "read-aloud", name: "Read Aloud")])
    }

    /// Two passes named the same thing must not collide on id — only the
    /// name may repeat.
    func test_added_twoPassesWithTheSameName_getDistinctIds() {
        var passes: [ReviewPass] = []
        passes = ReviewPassEditorLogic.added(to: passes, name: "Line edit")
        passes = ReviewPassEditorLogic.added(to: passes, name: "Line edit")

        XCTAssertEqual(passes.count, 2)
        XCTAssertEqual(Set(passes.map(\.id)).count, 2, "ids must be distinct")
        XCTAssertEqual(passes.map(\.name), ["Line edit", "Line edit"], "names may repeat")
        XCTAssertEqual(passes[0].id, "line-edit")
        XCTAssertEqual(passes[1].id, "line-edit-2")
    }

    func test_added_appendsToTheEnd() {
        let existing = [ReviewPass(id: "structural", name: "Structural")]
        let result = ReviewPassEditorLogic.added(to: existing, name: "Copyedit")
        XCTAssertEqual(result.map(\.id), ["structural", "copyedit"])
    }

    // MARK: - ReviewPassEditorLogic.renamed

    func test_renamed_preservesId() {
        let passes = [ReviewPass(id: "line", name: "Line")]
        let result = ReviewPassEditorLogic.renamed(passes, id: "line", to: "Line Edit")
        XCTAssertEqual(result, [ReviewPass(id: "line", name: "Line Edit")])
    }

    func test_renamed_leavesOtherPassesUntouched() {
        let passes = [
            ReviewPass(id: "structural", name: "Structural"),
            ReviewPass(id: "line", name: "Line"),
        ]
        let result = ReviewPassEditorLogic.renamed(passes, id: "line", to: "Line Edit")
        XCTAssertEqual(result, [
            ReviewPass(id: "structural", name: "Structural"),
            ReviewPass(id: "line", name: "Line Edit"),
        ])
    }

    // MARK: - ReviewPassEditorLogic.deleted

    func test_deleted_removesOnlyTheMatchingId() {
        let passes = [
            ReviewPass(id: "structural", name: "Structural"),
            ReviewPass(id: "line", name: "Line"),
        ]
        let result = ReviewPassEditorLogic.deleted(passes, id: "structural")
        XCTAssertEqual(result, [ReviewPass(id: "line", name: "Line")])
    }

    func test_deleted_allPasses_yieldsEmptyArray() {
        var passes = ReviewPass.presets
        for pass in ReviewPass.presets {
            passes = ReviewPassEditorLogic.deleted(passes, id: pass.id)
        }
        XCTAssertEqual(passes, [])
    }

    // MARK: - ReviewPassEditorLogic.reordered

    func test_reordered_movesDraggedPassBeforeTheTarget() {
        let passes = [
            ReviewPass(id: "a", name: "A"),
            ReviewPass(id: "b", name: "B"),
            ReviewPass(id: "c", name: "C"),
            ReviewPass(id: "d", name: "D"),
        ]
        let result = ReviewPassEditorLogic.reordered(passes, draggedId: "a", droppedOnId: "c")
        XCTAssertEqual(result.map(\.id), ["b", "a", "c", "d"])
    }

    func test_reordered_movingBackward_alsoLandsBeforeTheTarget() {
        let passes = [
            ReviewPass(id: "a", name: "A"),
            ReviewPass(id: "b", name: "B"),
            ReviewPass(id: "c", name: "C"),
            ReviewPass(id: "d", name: "D"),
        ]
        let result = ReviewPassEditorLogic.reordered(passes, draggedId: "d", droppedOnId: "b")
        XCTAssertEqual(result.map(\.id), ["a", "d", "b", "c"])
    }

    func test_reordered_droppingOnItself_isANoOp() {
        let passes = [ReviewPass(id: "a", name: "A"), ReviewPass(id: "b", name: "B")]
        let result = ReviewPassEditorLogic.reordered(passes, draggedId: "a", droppedOnId: "a")
        XCTAssertEqual(result, passes)
    }

    func test_reordered_unknownId_isANoOp() {
        let passes = [ReviewPass(id: "a", name: "A"), ReviewPass(id: "b", name: "B")]
        XCTAssertEqual(
            ReviewPassEditorLogic.reordered(passes, draggedId: "ghost", droppedOnId: "a"), passes)
        XCTAssertEqual(
            ReviewPassEditorLogic.reordered(passes, draggedId: "a", droppedOnId: "ghost"), passes)
    }

    /// Reorder round-trips: moving a pass forward past its neighbors, then
    /// moving it back to sit before the pass that originally followed it,
    /// lands the array exactly where it started.
    func test_reordered_roundTrips() {
        let original = ReviewPass.presets // structural, line, copyedit, proof
        let moved = ReviewPassEditorLogic.reordered(
            original, draggedId: "line", droppedOnId: "proof")
        XCTAssertEqual(moved.map(\.id), ["structural", "copyedit", "line", "proof"])
        XCTAssertNotEqual(moved.map(\.id), original.map(\.id))

        let restored = ReviewPassEditorLogic.reordered(
            moved, draggedId: "line", droppedOnId: "copyedit")
        XCTAssertEqual(restored.map(\.id), original.map(\.id))
    }
}

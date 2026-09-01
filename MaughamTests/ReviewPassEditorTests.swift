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

    // MARK: - ReviewPassEditorLogic.isSavable (whole-branch review)

    /// A blank-named pass must not be persistable: it would sit as a blank
    /// column header on the board and a blank ladder row in both inspectors.
    /// The sheet's Save button reads this and disables.
    func test_isSavable_refusesABlankOrWhitespaceName() {
        XCTAssertTrue(ReviewPassEditorLogic.isSavable(ReviewPass.presets))
        XCTAssertFalse(ReviewPassEditorLogic.isSavable(
            ReviewPassEditorLogic.renamed(ReviewPass.presets, id: "line", to: "")))
        XCTAssertFalse(ReviewPassEditorLogic.isSavable(
            ReviewPassEditorLogic.renamed(ReviewPass.presets, id: "line", to: "   ")))
    }

    /// The empty LIST stays savable — deleting every pass and Saving is the
    /// deliberate delete-all-restores-presets path (Task 1's rule), and the
    /// blank-name guard must not close it.
    func test_isSavable_anEmptyListIsStillSavable() {
        XCTAssertTrue(ReviewPassEditorLogic.isSavable([]))
    }

    // MARK: - The coach's seat (editorial letter P1 Task 4)

    /// `setCoachVacated` is the one writer of the seat, and it persists
    /// through a manifest round trip like every other metadata verb.
    func test_setCoachVacated_persistsThroughAManifestRoundTrip() async throws {
        let (url, store, ds) = try await makeNovel()
        XCTAssertFalse(store.manifest.coachVacated, "a new project holds the seat")
        XCTAssertEqual(store.manifest.effectiveCoach, ReviewPass.coachPreset)

        try await store.setCoachVacated(true)

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertTrue(reloaded.manifest.coachVacated)
        XCTAssertNil(reloaded.manifest.effectiveCoach)

        try await store.setCoachVacated(false)
        let restored = try await ProjectStore.load(from: url)
        XCTAssertFalse(restored.manifest.coachVacated)
        XCTAssertEqual(restored.manifest.effectiveCoach, ReviewPass.coachPreset)
        await ds.close()
    }

    /// Vacating the seat is a project edit and moves the modified stamp,
    /// like `setReviewPasses` above.
    func test_setCoachVacated_movesTheProjectsModifiedStamp() async throws {
        let (_, store, ds) = try await makeNovel()
        let before = store.manifest.modified
        try await Task.sleep(nanoseconds: 1_100_000_000)

        try await store.setCoachVacated(true)

        XCTAssertGreaterThan(store.manifest.modified, before)
        await ds.close()
    }

    /// **A stage may never carry the coach's id** (spec §4.1): the ladder is
    /// stages only, and a `workshop` stage would put her in
    /// `effectiveReviewPasses`, where `ReviewStatus.derived`, the board's
    /// chips and `validatedActivePass` would all start seeing her.
    ///
    /// CONTROL: the same list with a nearly-identical id saves, so the
    /// refusal is the reserved id and not the shape of the list.
    func test_isSavable_refusesALadderCarryingTheCoachsId() {
        let withCoach = ReviewPass.presets + [ReviewPass(id: "workshop", name: "Workshop")]
        XCTAssertFalse(ReviewPassEditorLogic.isSavable(withCoach))

        let control = ReviewPass.presets + [ReviewPass(id: "workshop2", name: "Workshop")]
        XCTAssertTrue(ReviewPassEditorLogic.isSavable(control))
    }

    /// The reserved id is unreachable from the Add button too: a pass named
    /// "Workshop" slugs to `workshop`, so without the reservation the writer
    /// could mint the coach's id into the ladder by typing her name.
    func test_added_neverMintsTheCoachsReservedId() {
        let minted = ReviewPassEditorLogic.added(to: [], name: "Workshop")
        XCTAssertEqual(minted.count, 1)
        XCTAssertNotEqual(minted[0].id, ReviewPass.coachPreset.id)
        XCTAssertEqual(minted[0].name, "Workshop")
        // And what it mints is savable — the reservation must not produce an
        // id the editor then refuses.
        XCTAssertTrue(ReviewPassEditorLogic.isSavable(minted))
    }
}

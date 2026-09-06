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

    /// **The seat never touches the ladder.** Vacating is not a pass edit:
    /// if it reached `reviewPasses` it would either add a fifth stage or
    /// silently rewrite a customized list, which is the one thing spec §4.1
    /// forbids.
    func test_setCoachVacated_leavesTheLadderExactlyAsItWas() async throws {
        let (_, store, ds) = try await makeNovel()
        let custom = [ReviewPass(id: "beta", name: "Beta Read")]
        try await store.setReviewPasses(custom)

        try await store.setCoachVacated(true)

        XCTAssertEqual(store.manifest.reviewPasses, custom)
        XCTAssertEqual(store.manifest.effectiveReviewPasses, custom)
        await ds.close()
    }

    /// **The sheet's row writes through that verb and holds no draft.** The
    /// pass list batches behind an explicit Save because it is an array of
    /// names being typed; the seat is one Bool, and a Save button over a
    /// single switch is a control whose state the writer has to remember.
    func test_theSettingsRowWritesTheSeatDirectlyAndAboveTheLadder() throws {
        let sheet = try Self.source(of: "Views/ProjectSettingsSheet.swift")
        let section = try XCTUnwrap(
            Self.declaration(named: "private func coachSection() -> some View {",
                             in: sheet),
            "the sheet must carry a readable coach section for this census to "
            + "have a subject")
        XCTAssertTrue(section.contains("store.setCoachVacated("),
                      "the row calls the store verb directly. Got:\n\(section)")
        XCTAssertFalse(section.contains("setReviewPasses("),
                       "\u{2026}and never the pass-list verb \u{2014} the coach "
                       + "is never in that array. Got:\n\(section)")

        let body = try XCTUnwrap(Self.declaration(named: "var body: some View {", in: sheet))
        let coach = try XCTUnwrap(body.range(of: "coachSection()"),
                                  "the section must be mounted at all")
        let ladder = try XCTUnwrap(body.range(of: "reviewPassesSection()"))
        XCTAssertTrue(coach.lowerBound < ladder.lowerBound,
                      "the seat sits ABOVE the ladder \u{2014} below it the row "
                      + "reads as a fifth stage")
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

    // MARK: - The first reader's row (two loops P2 Task 6)

    /// **Describe… before she is described, Edit description… after** — and
    /// dead until she has a name, because the statement is about a person.
    ///
    /// Windowless (tripwire 33): the rule is a pure function, so all four
    /// cells are assertable with nothing mounted.
    func test_describeButton_titleFollowsTheStatementAndEnablementTheName() {
        let unnamedFresh = ProjectSettingsSheet.describeButton(
            name: "", statementExists: false)
        XCTAssertEqual(unnamedFresh.title, "Describe\u{2026}")
        XCTAssertFalse(unnamedFresh.enabled, "there is nobody to describe yet")

        let namedFresh = ProjectSettingsSheet.describeButton(
            name: "Ursula", statementExists: false)
        XCTAssertEqual(namedFresh.title, "Describe\u{2026}")
        XCTAssertTrue(namedFresh.enabled)

        let namedDescribed = ProjectSettingsSheet.describeButton(
            name: "Ursula", statementExists: true)
        XCTAssertEqual(namedDescribed.title, "Edit description\u{2026}")
        XCTAssertTrue(namedDescribed.enabled)

        // The fourth cell, and the one a writer can actually reach: a
        // statement left behind by a reader whose name has since been cleared.
        // The button says what it would open and still refuses, because
        // `setFirstReaderName` maps a blank to nil and there is no reader.
        let unnamedDescribed = ProjectSettingsSheet.describeButton(
            name: "  ", statementExists: true)
        XCTAssertEqual(unnamedDescribed.title, "Edit description\u{2026}")
        XCTAssertFalse(unnamedDescribed.enabled,
                       "whitespace is not a name \u{2014} `setFirstReaderName` "
                       + "stores nil for it")
    }

    /// **The row writes the NAME verb and nothing else**, and it sits directly
    /// beneath the coach's seat: she is the other answer to the same question,
    /// and a row for her below the pass list would read as a fifth stage
    /// exactly as the coach's would.
    func test_theFirstReaderRowWritesItsOwnVerbAndSitsUnderTheCoach() throws {
        let sheet = try Self.source(of: "Views/ProjectSettingsSheet.swift")
        let section = try XCTUnwrap(
            Self.declaration(named: "private func firstReaderSection() -> some View {",
                             in: sheet),
            "the sheet must carry a readable first-reader section for this "
            + "census to have a subject")
        XCTAssertTrue(section.contains("store.statement(kind: .firstReader, scope: .project)"),
                      "the button's title turns on the statement the MANIFEST "
                      + "holds, never `FirstReader.statement`, which is nil for "
                      + "blank prose. Got:\n\(section)")
        XCTAssertFalse(section.contains("setReviewPasses("),
                       "\u{2026}and never the pass-list verb \u{2014} she is "
                       + "never in that array. Got:\n\(section)")

        let commit = try XCTUnwrap(
            Self.declaration(named: "private func commitFirstReaderName() {", in: sheet))
        XCTAssertTrue(commit.contains("store.setFirstReaderName("),
                      "the name commits through its own store verb. Got:\n\(commit)")

        let body = try XCTUnwrap(Self.declaration(named: "var body: some View {", in: sheet))
        let coach = try XCTUnwrap(body.range(of: "coachSection()"))
        let first = try XCTUnwrap(body.range(of: "firstReaderSection()"),
                                  "the section must be mounted at all")
        let ladder = try XCTUnwrap(body.range(of: "reviewPassesSection()"))
        XCTAssertTrue(coach.lowerBound < first.lowerBound,
                      "the coach's seat still leads \u{2014} the two readers "
                      + "are one question, in the order the resolution asks it")
        XCTAssertTrue(first.lowerBound < ladder.lowerBound,
                      "\u{2026}and she sits ABOVE the ladder: below it her row "
                      + "reads as a fifth stage")
    }

    /// **The name is not written per keystroke.** `setFirstReaderName` saves
    /// `project.json`; a `TextField` bound straight through it is a file write
    /// per character. The field is bound to a `@State` draft and committed on
    /// submit and on focus loss.
    func test_theFirstReaderNameCommitsOnSubmitAndFocusLossRatherThanPerKeystroke() throws {
        let sheet = try Self.source(of: "Views/ProjectSettingsSheet.swift")
        let section = try XCTUnwrap(
            Self.declaration(named: "private func firstReaderSection() -> some View {",
                             in: sheet))
        XCTAssertTrue(section.contains("TextField(\"Name\", text: $firstReaderDraft)"),
                      "the field is bound to the draft, not to the store. "
                      + "Got:\n\(section)")
        XCTAssertTrue(section.contains(".onSubmit { commitFirstReaderName() }"),
                      "Return commits. Got:\n\(section)")
        XCTAssertTrue(section.contains("onChange(of: firstReaderNameFocused)"),
                      "leaving the field commits. Got:\n\(section)")
    }

    /// **Describe… does not post its own segment event.** The post is scoped
    /// `.keyWindow`, and while a sheet is up the sheet's window is the key
    /// one — the project window filters the command out, so a sheet posting
    /// for itself would be swallowed by the act of closing. The presenter
    /// records the request and posts it from the sheet's `onDismiss`.
    func test_theDescribeHandoffWaitsForTheSheetToClose() throws {
        let sheet = try Self.source(of: "Views/ProjectSettingsSheet.swift")
        XCTAssertFalse(sheet.contains("postDetailSegment("),
                       "the sheet must not post while it is the key window")
        let describe = try XCTUnwrap(
            Self.declaration(named: "private func describeFirstReader() {", in: sheet))
        XCTAssertTrue(describe.contains("createStatement(kind: .firstReader, scope: .project)"),
                      "the statement is minted if absent. Got:\n\(describe)")
        XCTAssertTrue(describe.contains("onDescribeFirstReader()"),
                      "\u{2026}and the request is handed to the presenter. "
                      + "Got:\n\(describe)")
        XCTAssertTrue(describe.contains("dismiss()"), "Got:\n\(describe)")

        let window = try Self.source(of: "Views/ProjectWindow.swift")
        XCTAssertTrue(
            window.contains("onDismiss: openFirstReaderIfRequested"),
            "the presenter posts from the sheet's own dismissal hook")
        let post = try XCTUnwrap(
            Self.declaration(named: "private func openFirstReaderIfRequested() {",
                             in: window))
        XCTAssertTrue(post.contains("MaughamEvent.postDetailSegment(.firstReader)"),
                      "\u{2026}through the ONE segment post, so the receiver's "
                      + "other two acts keep their single spelling. Got:\n\(post)")
    }

    // MARK: - The name survives every way out of the sheet (fix round 1)

    /// **The one control here that could discard the writer\u{2019}s words.**
    ///
    /// A SwiftUI Button click does not resign an `NSTextField`, so Done never
    /// makes the field lose focus and the draft would go with the sheet. Every
    /// other control in this sheet writes through immediately; this one has a
    /// draft buffer because the verb saves `project.json`, which is exactly
    /// what made the loss possible.
    ///
    /// Windowless (tripwire 33): the census reads the four commit paths, and
    /// `nameNeedsCommitting` below pins what each of them decides.
    func test_theTypedNameCommitsOnEveryWayOutOfTheSheet() throws {
        let sheet = try Self.source(of: "Views/ProjectSettingsSheet.swift")
        let section = try XCTUnwrap(
            Self.declaration(named: "private func firstReaderSection() -> some View {",
                             in: sheet))
        XCTAssertTrue(section.contains(".onSubmit { commitFirstReaderName() }"),
                      "Return commits. Got:\n\(section)")
        XCTAssertTrue(section.contains("onChange(of: firstReaderNameFocused)"),
                      "leaving the field commits. Got:\n\(section)")
        XCTAssertTrue(section.contains(".onDisappear { commitFirstReaderName() }"),
                      "Escape and every other teardown commits \u{2014} the "
                      + "field never loses focus on the way out. Got:\n\(section)")

        let body = try XCTUnwrap(Self.declaration(named: "var body: some View {", in: sheet))
        let done = try XCTUnwrap(
            body.range(of: "Button(\"Done\") {"),
            "the sheet must still carry its Done button")
        let after = String(body[done.lowerBound...])
        let commit = try XCTUnwrap(after.range(of: "commitFirstReaderName()"))
        let dismissed = try XCTUnwrap(after.range(of: "dismiss()"))
        XCTAssertTrue(commit.lowerBound < dismissed.lowerBound,
                      "Done commits BEFORE it dismisses \u{2014} after teardown "
                      + "there is no draft left to read")
    }

    /// **The guard compares trimmed, on both sides.** `setFirstReaderName`
    /// trims what it stores, so a raw comparison re-saves `project.json` on
    /// every focus loss over a field the writer has not touched — and with
    /// four commit paths now calling it, that is four file writes for nothing.
    func test_nameNeedsCommitting_comparesTrimmedAndTreatsBlankAsAbsent() {
        XCTAssertFalse(ProjectSettingsSheet.nameNeedsCommitting(
            draft: "  Ursula  ", stored: "Ursula"),
            "the stored name IS the trimmed draft \u{2014} nothing to write")
        XCTAssertFalse(ProjectSettingsSheet.nameNeedsCommitting(
            draft: "Ursula", stored: "Ursula"))
        XCTAssertFalse(ProjectSettingsSheet.nameNeedsCommitting(draft: "", stored: nil))
        XCTAssertFalse(ProjectSettingsSheet.nameNeedsCommitting(draft: "   ", stored: nil),
                       "a blank field and no first reader are one state")

        XCTAssertTrue(ProjectSettingsSheet.nameNeedsCommitting(draft: "Ursula", stored: nil),
                      "naming her for the first time writes")
        XCTAssertTrue(ProjectSettingsSheet.nameNeedsCommitting(draft: "", stored: "Ursula"),
                      "clearing the field takes the name away")
        XCTAssertTrue(ProjectSettingsSheet.nameNeedsCommitting(
            draft: "Ursula K.", stored: "Ursula"))
    }

    /// Describe\u{2026} shares that guard rather than writing unconditionally,
    /// and does it in ONE Task with the mint, so the two manifest writes cannot
    /// land in the other\u{2019}s order.
    func test_describeSharesTheCommitGuardAndWritesInOneTask() throws {
        let sheet = try Self.source(of: "Views/ProjectSettingsSheet.swift")
        let describe = try XCTUnwrap(
            Self.declaration(named: "private func describeFirstReader() {", in: sheet))
        XCTAssertTrue(describe.contains("Self.nameNeedsCommitting("),
                      "Describe\u{2026} asks the same guard. Got:\n\(describe)")
        XCTAssertEqual(describe.components(separatedBy: "Task {").count - 1, 1,
                       "one Task, so the name is stored before the statement is "
                       + "minted. Got:\n\(describe)")
    }

    // MARK: - Census helpers

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent("Maugham/\(relativePath)"),
            encoding: .utf8)
    }

    /// The text from `name` to the end of its brace-balanced body.
    ///
    /// **A per-suite copy, not a shared helper.** Every census suite that needs
    /// this reader declares its own, because `MaughamTests` has no
    /// census-support module and a private static in the suite that uses it is
    /// what they all settled on — grep `private static func declaration(named`
    /// for the current set. Sharing it would be a real improvement and is
    /// deliberately out of this task's scope; what is fixed here is the
    /// comment, which claimed the copy was the shared one.
    private static func declaration(named name: String, in source: String) -> String? {
        guard let start = source.range(of: name) else { return nil }
        var depth = 0
        var index = start.lowerBound
        var seenOpen = false
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1; seenOpen = true }
            if character == "}" {
                depth -= 1
                if seenOpen && depth == 0 {
                    return String(source[start.lowerBound...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}

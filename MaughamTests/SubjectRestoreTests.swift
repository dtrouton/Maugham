import XCTest
import MaughamCore
@testable import Maugham

/// Where a freshly opened window lands, for every shape a `ui-state.json` can
/// hold — `ProjectWindow.validSubject`, plus the codec that feeds it.
///
/// **The failure this pins is silent.** Before the project row, the restore
/// validated the saved subject with a bare `TreeWalk.contains` over its item id.
/// A project subject has no item id, so it failed that check and the window
/// landed on the first document — no error, no log, nothing on screen except a
/// chapter the writer did not choose. There is no assertion anywhere else in the
/// suite that would have gone red.
final class SubjectRestoreTests: XCTestCase {

    private func structure() -> [StructureItem] {
        [
            StructureItem(
                id: "grp", title: "Part One", type: .group,
                children: [
                    StructureItem(id: "doc-1", title: "Chapter 1",
                                  type: .document, path: "Chapter 1.md"),
                    StructureItem(id: "doc-2", title: "Chapter 2",
                                  type: .document, path: "Chapter 2.md")
                ])
        ]
    }

    // MARK: - The four shapes a ui-state.json can hold

    /// Shape 1 — the project flag. The whole point of task 3.
    func test_theProjectSubjectRestoresToTheProject() {
        XCTAssertEqual(
            ProjectWindow.validSubject(.project, in: structure()),
            .project,
            "the project is in no structure and is valid because of that; "
            + "validating it against the structure lands the window on chapter 1")
    }

    /// Shape 2 — a bare id that still names something. The behaviour every
    /// shipped build has, and the one this change must not move.
    func test_anIdStillInTheStructureRestoresUnchanged() {
        XCTAssertEqual(
            ProjectWindow.validSubject(.item("doc-2"), in: structure()),
            .item("doc-2"))
    }

    /// A GROUP id restores too. Groups are selectable rows and always have been;
    /// a restore that quietly demoted a group selection to the first document
    /// would be a regression the type makes easy to write by accident.
    func test_aGroupIdRestoresUnchanged() {
        XCTAssertEqual(
            ProjectWindow.validSubject(.item("grp"), in: structure()),
            .item("grp"))
    }

    /// Shape 3 — an id naming something deleted since the file was written.
    ///
    /// **This used to fall to the first document, and that expectation was
    /// wrong.** It was inert for as long as the fallback only decided what the
    /// editor showed; slice 3 gave the same value to the canvas, where it is the
    /// difference between an undimmed board and a filtered one. A window that
    /// opens already filtered on a chapter nobody clicked shows the writer a
    /// dark board and a standing offer naming a document that appears nowhere on
    /// screen — and Plan's `.canvas` binder segment has no subject picker in it,
    /// so there is nothing to click to get back out.
    func test_anIdNoLongerInTheStructureRestoresTheProject() {
        XCTAssertEqual(
            ProjectWindow.validSubject(.item("gone"), in: structure()),
            .project,
            "an id naming a deleted item is not a choice the writer made; the "
            + "dim is entered by a click and never by opening a window")
    }

    /// Shape 4 — no selection recorded at all. Same ruling, same reason: nobody
    /// has clicked in this window yet.
    func test_noSavedSelectionRestoresTheProject() {
        XCTAssertEqual(
            ProjectWindow.validSubject(nil, in: structure()),
            .project,
            "a window nobody has clicked in has entered no selection, and "
            + "picking one for them names a chapter on the canvas they did not "
            + "choose — the next sweep then binds to it silently")
    }

    // MARK: - The edges of the fallback

    /// A structure with no document in it, which used to be the one shape with
    /// no answer at all. `.project` is in no structure, so it is now always
    /// available — and `validSubject` returns a subject rather than an
    /// optional one, which is why `load()` no longer has an `if let`.
    func test_aStructureWithNoDocumentStillHasAnAnswer() {
        let groupsOnly = [StructureItem(id: "grp", title: "Part One",
                                        type: .group, children: [])]
        XCTAssertEqual(ProjectWindow.validSubject(nil, in: groupsOnly),
                       .project)
        XCTAssertEqual(ProjectWindow.validSubject(.item("gone"), in: groupsOnly),
                       .project)
    }

    /// The PROJECT restores out of an empty structure too. It is the one subject
    /// that does not need a document to exist, which is what makes the project
    /// row a way out of an empty binder rather than another dead end — and now
    /// also what makes it a landing every project can offer.
    func test_theProjectRestoresEvenWithAnEmptyStructure() {
        XCTAssertEqual(ProjectWindow.validSubject(.project, in: []),
                       .project)
    }

    /// **The joint test, and the one that would have caught the original.**
    ///
    /// Neither half is wrong on its own: `validSubject` returning a document
    /// is a defensible answer for an editor, and `CanvasSubject.resolve` turning
    /// a document into a filtered board is exactly §4. The defect only exists
    /// where they meet, which is `ProjectWindow`'s body handing one to the
    /// other — so it is asserted across the seam rather than inside either side.
    func test_aFreshWindowLandsOnAnUNDIMMEDBoard() {
        for saved in [BinderSubject?.none, .item("gone")] {
            let restored = ProjectWindow.validSubject(saved, in: structure())
            XCTAssertFalse(
                CanvasSubject.resolve(restored, in: structure()).dimsTheBoard,
                "opening a project put the canvas into the dim with no click: "
                + "saved \(String(describing: saved)) restored as \(restored)")
        }
    }

    // MARK: - Through a real file

    /// The codec and the restore together, over a `ui-state.json` written to
    /// disk and read back the way `load()` reads it. The two halves are in
    /// different files and each is green on its own with the pair broken.
    func test_theProjectSurvivesARealFileAndTheRestore() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = temp.url.appendingPathComponent("ui-state.json")

        var state = UIState.empty
        state.selectedSubject = .project
        try JSONEncoder().encode(state).write(to: url)

        let loaded = UIState.loadOrEmpty(from: url)
        XCTAssertEqual(
            ProjectWindow.validSubject(loaded.selectedSubject,
                                          in: structure()),
            .project,
            "select the project, quit, reopen — this is that trip")
    }

    /// The same trip for the file every shipped build has already written: a
    /// bare `selectedItemId` string, no flag, no new key.
    func test_anOldFileOnDiskStillRestoresItsItem() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = temp.url.appendingPathComponent("ui-state.json")
        try Data("""
        {"schemaVersion":5,"selectedItemId":"doc-2","isNoChromeOn":false,
         "binderSegment":"manuscript","researchPreviewVisible":false,
         "detailSegment":"inspector","outlineLayout":"table",
         "isReviewModeOn":false,"persona":"author"}
        """.utf8).write(to: url)

        let loaded = UIState.loadOrEmpty(from: url)
        XCTAssertEqual(
            ProjectWindow.validSubject(loaded.selectedSubject,
                                          in: structure()),
            .item("doc-2"))
    }

    /// **What an older build does with a file this one wrote**, confirmed after
    /// the change rather than inherited from the plan: the project subject is
    /// written under its own key, so a build that only knows `selectedItemId`
    /// reads no selection and runs its own fallback — the first document, since
    /// that is the rule that build ships. This build's answer for the same file
    /// is the project, and the downgrade is therefore visible rather than silent.
    func test_anOlderBuildReadingTheProjectFileFindsNoIdToRestore() throws {
        var state = UIState.empty
        state.selectedSubject = .project
        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(state)) as? [String: Any]
        XCTAssertNil(object?["selectedItemId"] as? String,
                     "an older build would restore an id that is in no structure")

        // What THIS build does with the same absence, which is the rule under
        // test: the project, not a chapter nobody chose.
        XCTAssertEqual(ProjectWindow.validSubject(nil, in: structure()),
                       .project)
    }
}

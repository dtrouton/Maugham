import XCTest
import MaughamCore
@testable import Maugham

/// Where a freshly opened window lands, for every shape a `ui-state.json` can
/// hold — `ProjectWindow.restoredSubject`, plus the codec that feeds it.
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
            ProjectWindow.restoredSubject(saved: .project, in: structure()),
            .project,
            "the project is in no structure and is valid because of that; "
            + "validating it against the structure lands the window on chapter 1")
    }

    /// Shape 2 — a bare id that still names something. The behaviour every
    /// shipped build has, and the one this change must not move.
    func test_anIdStillInTheStructureRestoresUnchanged() {
        XCTAssertEqual(
            ProjectWindow.restoredSubject(saved: .item("doc-2"), in: structure()),
            .item("doc-2"))
    }

    /// A GROUP id restores too. Groups are selectable rows and always have been;
    /// a restore that quietly demoted a group selection to the first document
    /// would be a regression the type makes easy to write by accident.
    func test_aGroupIdRestoresUnchanged() {
        XCTAssertEqual(
            ProjectWindow.restoredSubject(saved: .item("grp"), in: structure()),
            .item("grp"))
    }

    /// Shape 3 — an id naming something deleted since the file was written.
    /// Falls to the first document, exactly as it did before.
    func test_anIdNoLongerInTheStructureFallsToTheFirstDocument() {
        XCTAssertEqual(
            ProjectWindow.restoredSubject(saved: .item("gone"), in: structure()),
            .item("doc-1"))
    }

    /// Shape 4 — no selection recorded at all.
    func test_noSavedSelectionFallsToTheFirstDocument() {
        XCTAssertEqual(
            ProjectWindow.restoredSubject(saved: nil, in: structure()),
            .item("doc-1"))
    }

    // MARK: - The edges of "the first document"

    /// A structure of groups only has no document to fall to. `nil` back means
    /// *no answer*, and `load()` leaves the selection alone rather than clearing
    /// it — the behaviour of the `else if let first` this replaced.
    func test_aStructureWithNoDocumentGivesNoAnswer() {
        let groupsOnly = [StructureItem(id: "grp", title: "Part One",
                                        type: .group, children: [])]
        XCTAssertNil(ProjectWindow.restoredSubject(saved: nil, in: groupsOnly))
        XCTAssertNil(ProjectWindow.restoredSubject(saved: .item("gone"), in: groupsOnly))
    }

    /// …but the PROJECT still restores out of an empty structure. It is the one
    /// subject that does not need a document to exist, which is what makes the
    /// project row a way out of an empty binder rather than another dead end.
    func test_theProjectRestoresEvenWithAnEmptyStructure() {
        XCTAssertEqual(ProjectWindow.restoredSubject(saved: .project, in: []),
                       .project)
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
            ProjectWindow.restoredSubject(saved: loaded.selectedSubject,
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
            ProjectWindow.restoredSubject(saved: loaded.selectedSubject,
                                          in: structure()),
            .item("doc-2"))
    }

    /// **What an older build does with a file this one wrote**, confirmed after
    /// the change rather than inherited from the plan: the project subject is
    /// written under its own key, so a build that only knows `selectedItemId`
    /// reads no selection and falls to the first document — the same landing a
    /// deleted item gets. Modelled by feeding the old rule the old key.
    func test_anOlderBuildReadingTheProjectFileLandsOnTheFirstDocument() throws {
        var state = UIState.empty
        state.selectedSubject = .project
        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(state)) as? [String: Any]
        XCTAssertNil(object?["selectedItemId"] as? String,
                     "an older build would restore an id that is in no structure")

        // What that build then does: no id, so the old validation fails and the
        // fallback runs. Same answer as this build's `saved: nil`.
        XCTAssertEqual(ProjectWindow.restoredSubject(saved: nil, in: structure()),
                       .item("doc-1"))
    }
}

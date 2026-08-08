import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The delivery path three fix rounds needed and never had** (persona shell,
/// slice 1, task 6).
///
/// `ProjectWindow.openPromotedArtifact`'s comment records why `Open`-sets-scope
/// was built, failed three times and was reverted by ruling: *"the pane's scope
/// switch, the request and `prefersProjectScope` interact and **no test drives a
/// press through the binding and back through this view's state** — every
/// `StatementPane` in `StatementMountFixture` is mounted without one. The next
/// attempt should start from that test, not from the control."*
///
/// So this is that test, and it is deliberately written **before** the pane's
/// own scope switch is deleted — the point is a fixture that survives the
/// deletion and is still there for slice 4, not one shaped around today's
/// controls. Nothing here touches `prefersProjectScope` or the picker: it drives
/// the SELECTION, which is the input that remains.
///
/// **What is production, end to end:** `BinderView`'s `List(selection:)` and its
/// row tags; the `Binding` the two columns share; `ProjectWindow`'s boundary
/// conversion (called, not copied — see `BinderBesideThePaneProbeView`);
/// `DetailPaneToggle`'s `segmentContent`; `StatementPane.effectiveScope`; and
/// `StatementEditorHost.reconcile`, which closes the outgoing `Document` before
/// opening the incoming one.
///
/// **How the resolved scope is observed.** It is `@State` two views down and is
/// not readable from outside — and the pane's own lesson (`shouldMount`) is that
/// a scope is resolved exactly when its editor is mounted over its `Document`.
/// So the reading is the words on screen: each scope is seeded with a sentence
/// naming it, and the assertion is which sentence the mounted editor shows.
/// That is the same standard `BinderProjectRowTests` had to settle for — a
/// mounted SwiftUI row will not tell you what it says (macOS 26.5) — arrived at
/// from the other end: here the text is in a real `NSTextView`, which does.
@MainActor
final class StatementPaneSelectionDeliveryTests: XCTestCase {

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { fixture.tearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    /// The two scopes, each holding a sentence that names it.
    private struct Seeded {
        let fixture: StatementMountFixture
        let projectText: String
        let chapterText: String
        var chapterItemId: String { fixture.documentItemId }
    }

    // MARK: - The selection reaches the pane

    /// **Select a chapter in the tree; the Intent pane shows the chapter's
    /// intent. Select the project row; it shows the book's.**
    ///
    /// Every hop is real, and each one has failed on this branch or the last:
    /// the row tag (`.project` is a case a `.tag` must match), the binding write,
    /// the boundary conversion (`itemID` is `nil` for the project — the value a
    /// careless boundary drops), and the pane's own resolution.
    func test_selectingInTheTreeMovesTheIntentPaneOntoThatSubjectsIntent() async throws {
        let seeded = try await seededFixture(named: "SelectionDelivery")
        let made = seeded.fixture
        let window = await made.hostTheBinderBesideThePane(subject: nil)

        // Row zero is the project row (`BinderProjectRowTests` pins that it is
        // exactly one row and that it is the head).
        await made.selectBinderRow(0, in: window, until: {
            made.subjectProbe.subject == BinderSubject.project
        })
        XCTAssertEqual(made.subjectProbe.subject, .project,
                       "precondition: the head row must have written the project "
                       + "subject through the binding")
        try await assertPaneShows(seeded.projectText, in: window, of: made,
                                  "the project row is selected, so the Intent pane "
                                  + "must be showing the book's intent")

        await made.selectBinderRow(1, in: window, until: {
            made.subjectProbe.subject == BinderSubject.item(seeded.chapterItemId)
        })
        XCTAssertEqual(made.subjectProbe.subject, .item(seeded.chapterItemId),
                       "precondition: row one is the first chapter")
        try await assertPaneShows(seeded.chapterText, in: window, of: made,
                                  "the chapter is selected, so the Intent pane must "
                                  + "have closed the project's Document and opened "
                                  + "the chapter's")

        // And back, because a scope change is not a one-way trip: the return is
        // the direction that reconciles onto a scope the host has already been on.
        await made.selectBinderRow(0, in: window, until: {
            made.subjectProbe.subject == BinderSubject.project
        })
        try await assertPaneShows(seeded.projectText, in: window, of: made,
                                  "returning to the project row left the pane on the "
                                  + "chapter's intent")
    }

    /// **The other half of what the blocker names: `detailSegment`.**
    ///
    /// `⌘⌥N`/`⌘⌥V` is not a scope change — `segmentContent` gives `.intent` and
    /// `.visualLanguage` separate `case` arms, so the host is **torn down** and a
    /// fresh one built. Its `@State` does not survive that, and `leave()` exists
    /// because a marker that did survive it was a lie. This drives the round trip
    /// with a chapter selected and asserts the pane comes back on the chapter's
    /// intent rather than on the project's or on nothing.
    func test_leavingTheIntentPaneAndComingBackKeepsTheSelectedChaptersScope() async throws {
        let seeded = try await seededFixture(named: "SegmentRoundTrip")
        let made = seeded.fixture
        let window = await made.hostTheBinderBesideThePane(subject: nil)

        await made.selectBinderRow(1, in: window, until: {
            made.subjectProbe.subject == BinderSubject.item(seeded.chapterItemId)
        })
        XCTAssertEqual(made.subjectProbe.subject, .item(seeded.chapterItemId),
                       "precondition: row one is the first chapter")
        try await assertPaneShows(seeded.chapterText, in: window, of: made,
                                  "precondition: the pane starts on the chapter's intent")

        // Leaving keeps its fixed window: what must have finished before the
        // return trip is the intent host's TEARDOWN, and the incoming pane's
        // editor reports the segment change rather than the outgoing host's
        // `.onDisappear`. This test IS the teardown, so it is not shortened on a
        // proxy for it. Coming back has a condition — the words the assertion
        // below reads.
        await made.showSegment(.visualLanguage)
        await made.showSegment(.intent, until: {
            made.firstTextView(in: window)?.string == seeded.chapterText
        })

        try await assertPaneShows(seeded.chapterText, in: window, of: made,
                                  "coming back to Intent landed on a different scope "
                                  + "than the one the tree still names")
    }

    /// **The subject the tree cannot name is still the pane's answer.** A group
    /// is a selectable row and holds no intent of its own — `createStatement`
    /// throws `.structureMissing` for one — so the pane resolves it to the
    /// project. Asserted through the delivery path rather than only against
    /// `effectiveScope`, because this is the case where the tree's subject and
    /// the pane's scope legitimately DISAGREE, and after slice 1 the header is
    /// the only thing that says so.
    func test_selectingAGroupLeavesTheIntentPaneOnTheProjects() async throws {
        let seeded = try await seededFixture(named: "GroupFallsBack")
        let made = seeded.fixture
        let group = try await made.store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)
        let window = await made.hostTheBinderBesideThePane(subject: nil)

        let table = try XCTUnwrap(made.firstTableView(in: window))
        // The group is the last row the STRUCTURE contributes, which since
        // stage-2a Task 4 is no longer the last row of the list: the Research
        // and Palette sections sit below it. Counted from the structure rather
        // than from the table's end so a future section cannot move it again.
        let groupRow = 1 + made.store.manifest.structure.count - 1
        await made.selectBinderRow(groupRow, in: window, until: {
            made.subjectProbe.subject == BinderSubject.item(group.id)
        })
        XCTAssertEqual(made.subjectProbe.subject, .item(group.id),
                       "precondition: the row under the project row and the "
                       + "chapters is the group just added")

        try await assertPaneShows(seeded.projectText, in: window, of: made,
                                  "a group is not a scope — the pane must fall back "
                                  + "to the project's intent")
    }

    // MARK: - Fixtures and assertions

    /// A novel whose project intent and whose first chapter's intent each hold
    /// one sentence naming themselves.
    ///
    /// Seeded through `createStatement` + `appendToStatement` rather than by
    /// typing: what this file is about is which scope the pane RESOLVES, and a
    /// seed that goes through the pane's own mint would make the arrangement
    /// under test part of the fixture.
    private func seededFixture(named name: String) async throws -> Seeded {
        let made = try await StatementMountFixture.novel(named: name)
        fixtures.append(made)

        let projectText = "The book is going for a cold ending."
        let chapterText = "This chapter is going for the moment before it."

        let project = try await made.store.createStatement(kind: .intent, scope: .project)
        try await made.store.appendToStatement(projectText, to: project, session: "seed")
        let chapter = try await made.store.createStatement(
            kind: .intent, scope: .document(made.documentItemId))
        try await made.store.appendToStatement(chapterText, to: chapter, session: "seed")

        XCTAssertNotEqual(projectText, chapterText,
                          "the two scopes must be distinguishable or every "
                          + "assertion in this file passes vacuously")
        return Seeded(fixture: made, projectText: projectText, chapterText: chapterText)
    }

    /// Wait for the mounted editor to be showing `expected`, then assert it.
    ///
    /// The text view is re-fetched every time rather than held: a scope change
    /// unmounts `EditorSurface` (`canMount` goes false while the incoming
    /// `Document` loads) and mounts a fresh one, so a handle taken before the
    /// change names a view that is no longer on screen.
    private func assertPaneShows(_ expected: String, in window: NSWindow,
                                 of fixture: StatementMountFixture,
                                 _ message: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) async throws {
        await fixture.pumpUntil(deadline: 5) {
            fixture.firstTextView(in: window)?.string == expected
        }
        let textView = try XCTUnwrap(
            fixture.firstTextView(in: window),
            "no editor is mounted at all, so the pane resolved no scope: " + message,
            file: file, line: line)
        XCTAssertEqual(textView.string, expected, message, file: file, line: line)
    }
}

import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The words typed before a statement's file existed belong to the scope they
/// were typed for, and the writer moving on does not un-type them** (issue #21).
///
/// Typing into an Intent or Visual Language pane on a scope with no statement
/// yet parks the text in `StatementTextTarget`'s draft and starts a mint — a
/// detached `Task` nothing cancels. Between the keystroke and the file existing
/// there is a window, and until this file existed **two different doors** threw
/// the writer's characters away inside it:
///
/// 1. **The selection changes** (a binder click). `reconcile` for the incoming
///    scope runs `target.release()`, which emptied the draft, while the mint was
///    still in flight. `test_wordsSurviveASelectionChangeMidMint`.
/// 2. **The pane changes** (`⌘⌥N` / `⌘⌥V`). `DetailPaneToggle.segmentContent`
///    gives `.intent` and `.visualLanguage` separate `case` arms, so the host is
///    **torn down** and `release()` never runs at all — the draft survives in an
///    orphaned box, and the mint's `loadMayBind` refuses (`paneWants` is nil
///    after `leave()`), closing the `Document` it just created without ever
///    writing the words into it. `test_wordsSurviveAPaneSwitchMidMint`.
///
/// A fix aimed at either one alone leaves the other open, which is why both are
/// here and why the second is driven through the **real** `detailSegment`
/// delivery path rather than by calling something.
///
/// **The wedge is the production gate, not a sleep** — the idiom
/// `StatementEditorMountTests` established. `load`'s first line is
/// `await store.lockStatementOpen(statement.id)`, so a test holding that gate
/// parks the mint exactly where it needs it for as long as it likes. The
/// existing scope-change tests structurally cannot see this class:
/// `StatementMountFixture.selectDocument` waits after changing the selection, so
/// the outgoing work always finishes first. Here it is *provably* still in
/// flight when the writer moves — asserted, not assumed.
///
/// The statement is created out of band **after** the pane has resolved its
/// scope as empty, purely so the test knows the id whose gate to hold:
/// `createStatement` is idempotent, so the mint the keystroke starts finds this
/// one, and nothing re-runs `reconcile`, so the pane is still unbound and the
/// keystroke still goes to the draft. Same device as
/// `test_aMintThatOutlivesItsScopeDoesNotBindIntoTheNextOne`.
@MainActor
final class StatementDraftHandoffTests: XCTestCase {

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { fixture.tearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func fixture(named name: String) async throws -> StatementMountFixture {
        let made = try await StatementMountFixture.novel(named: name)
        fixtures.append(made)
        return made
    }

    // MARK: - Door 1: the selection changes while the mint is in flight

    /// `reconcile` for the incoming scope calls `target.release()` before the
    /// mint the writer's own keystroke started has finished creating the file.
    /// The characters were in the draft that `release()` emptied.
    func test_wordsSurviveASelectionChangeMidMint() async throws {
        let fixture = try await fixture(named: "DraftSurvivesSelectionChange")
        let docId = fixture.documentItemId

        // The pane resolves the CHAPTER's scope as empty and mounts an unbound
        // editor.
        let window = await fixture.hostWithASettableSelection(
            kind: .intent, subject: .item(docId))
        let onChapter = try fixture.textView(in: window)
        XCTAssertNil(fixture.store.statement(kind: .intent, scope: .document(docId)),
                     "precondition: the chapter has no intent, so the first "
                     + "keystroke is the one that mints it — which is the whole "
                     + "case this test is about")

        let chapterIntent = try await fixture.store.createStatement(
            kind: .intent, scope: .document(docId))

        // Park the mint's load on the production gate.
        await fixture.store.lockStatementOpen(chapterIntent.id)
        await fixture.type("x", into: onChapter)
        // fixed window: asserting nothing happens — the gate must still be
        // holding the mint, and an absence needs a span of wall clock.
        await fixture.waitOut(0.3)
        XCTAssertNil(fixture.store.openStatementDocument(id: chapterIntent.id),
                     "the mint's load got past the gate this test is holding, so "
                     + "the wedge did not work and nothing below is evidence")

        // The writer moves on **without the mint having finished**. The project
        // has no intent, so the incoming reconcile is wholly synchronous and its
        // `release()` runs while the mint is still parked. The incoming scope's
        // empty editor IS that reconcile having run, which is what the unlock
        // below must come after.
        await fixture.selectDocument(nil, until: {
            fixture.firstTextView(in: window)?.string == ""
        })
        fixture.store.unlockStatementOpen(chapterIntent.id)
        await fixture.pumpUntil(deadline: 5) {
            !fixture.ops(forDocId: chapterIntent.id).isEmpty
        }
        // Both assertions below are settled by the same delivery — the mint
        // writing the character and closing the `Document` it made — so wait for
        // the pair rather than stopping on the first and racing the second.
        await fixture.pumpUntil(deadline: 5) {
            fixture.derivedText(forDocId: chapterIntent.id) == "x"
                && fixture.store.openStatementDocument(id: chapterIntent.id) == nil
        }

        XCTAssertEqual(fixture.derivedText(forDocId: chapterIntent.id), "x",
                       "the writer typed a character into the chapter's intent "
                       + "and clicked another row before the file existed. The "
                       + "statement was created and the character is not in it: "
                       + "the incoming scope's `release()` emptied the draft "
                       + "while the mint that was creating its home was still in "
                       + "flight. No error, nothing in the op log — the words are "
                       + "simply gone (issue #21).")
        XCTAssertNil(fixture.store.openStatementDocument(id: chapterIntent.id),
                     "the mint's `Document` is registered as the live one for a "
                     + "statement no pane is showing — nothing is left to close "
                     + "it, and every statement writer reads it as live")
    }

    // MARK: - Door 2: the pane changes while the mint is in flight

    /// `⌘⌥N`/`⌘⌥V` is **not** a scope change: the host is torn down and a fresh
    /// one built, so `release()` never runs and the draft is orphaned rather than
    /// emptied. The loss arrives at the other end — `loadMayBind` refuses a bind
    /// into a pane that has left, and closes the `Document` it created without
    /// putting the writer's words in it.
    ///
    /// **Driven through the real `detailSegment` binding** (the milestone's own
    /// lesson: twenty-two green undo tests once sat on a ⌘Z that could not reach
    /// the stack). `showSegment` writes the same `Binding<DetailSegment>` the
    /// picker and the `⌘⌥N`/`⌘⌥V` key equivalents write, and
    /// `DetailPaneToggle.segmentContent` does the routing that tears the host
    /// down.
    func test_wordsSurviveAPaneSwitchMidMint() async throws {
        let fixture = try await fixture(named: "DraftSurvivesPaneSwitch")

        let window = await fixture.hostTheBinderBesideThePane(subject: .project)
        let onIntent = try fixture.textView(in: window)
        XCTAssertNil(fixture.store.statement(kind: .intent, scope: .project),
                     "precondition: the project has no intent yet")

        let projectIntent = try await fixture.store.createStatement(
            kind: .intent, scope: .project)

        await fixture.store.lockStatementOpen(projectIntent.id)
        await fixture.type("x", into: onIntent)
        // fixed window: asserting nothing happens — the gate must still be
        // holding the mint, and an absence needs a span of wall clock.
        await fixture.waitOut(0.3)
        XCTAssertNil(fixture.store.openStatementDocument(id: projectIntent.id),
                     "the mint's load got past the gate this test is holding, so "
                     + "the wedge did not work and nothing below is evidence")

        // ⌘⌥V, through the binding the picker and the key equivalent both write.
        // Fixed window on purpose: what has to have happened before the unlock is
        // the host's TEARDOWN (`.onDisappear` → `leave()`), and nothing readable
        // from here reports it — the incoming pane's own editor says the segment
        // moved, not that the outgoing one finished leaving. Shortening this on a
        // proxy would let the mint bind and the test pass for the wrong reason.
        await fixture.showSegment(.visualLanguage)
        fixture.store.unlockStatementOpen(projectIntent.id)
        await fixture.pumpUntil(deadline: 5) {
            !fixture.ops(forDocId: projectIntent.id).isEmpty
        }
        // Both assertions below settle on the same delivery: the mint writing the
        // character into the statement it created, and closing that `Document`.
        await fixture.pumpUntil(deadline: 5) {
            fixture.derivedText(forDocId: projectIntent.id) == "x"
                && fixture.store.openStatementDocument(id: projectIntent.id) == nil
        }

        XCTAssertEqual(fixture.derivedText(forDocId: projectIntent.id), "x",
                       "the writer typed a character into the project's intent "
                       + "and pressed ⌘⌥V before the file existed. The statement "
                       + "was created and the character is not in it: the host "
                       + "was torn down, `leave()` cleared the destination the "
                       + "mint checks itself against, and the mint closed the "
                       + "`Document` it had just created rather than writing the "
                       + "words into it (issue #21, the door a fix aimed at "
                       + "`release()` alone leaves open).")
        XCTAssertNil(fixture.store.openStatementDocument(id: projectIntent.id),
                     "the mint registered a `Document` for a host that no longer "
                     + "exists — nothing is left to close it")
    }

    // MARK: - What the fix makes newly possible

    /// **Two scopes can have words waiting at once, and neither mint may collect
    /// the other's.**
    ///
    /// This is the question the fix's own shape raises, asked separately from
    /// "does it address the finding". Words that outlive their pane have to be
    /// held *somewhere* until their file exists, and the cheap version of that —
    /// one value, moved aside when the pane leaves — is wrong here in a way no
    /// test above can see: type into an undeclared scope, move to another
    /// undeclared scope and type again, and the second keystroke overwrites the
    /// one place the first one's characters were. Two chapters with no intent yet
    /// is the ordinary state of a new book, so this is the shape of a normal
    /// morning, not a corner.
    ///
    /// Keyed by scope, each mint takes its own by name and leaves the other's
    /// alone. Falsified by keying the store on anything but the scope.
    func test_wordsWaitingForOneScopeAreNotCollectedByAnothersMint() async throws {
        let fixture = try await fixture(named: "TwoScopesWaiting")
        let docId = fixture.documentItemId

        let window = await fixture.hostWithASettableSelection(
            kind: .intent, subject: .item(docId))
        let onChapter = try fixture.textView(in: window)

        let chapterIntent = try await fixture.store.createStatement(
            kind: .intent, scope: .document(docId))

        // The chapter's mint is parked and stays parked for the rest of the test.
        await fixture.store.lockStatementOpen(chapterIntent.id)
        await fixture.type("x", into: onChapter)
        // fixed window: asserting nothing happens — the gate must still be
        // holding the chapter's mint.
        await fixture.waitOut(0.3)
        XCTAssertNil(fixture.store.openStatementDocument(id: chapterIntent.id),
                     "the chapter's mint got past the gate this test is holding, "
                     + "so its words are not waiting and nothing below is evidence")

        // On to the project, which also has no intent — so the writer types into
        // a second undeclared scope while the first one's words are still waiting.
        await fixture.selectDocument(nil, until: {
            fixture.firstTextView(in: window)?.string == ""
        })
        let onProject = try fixture.textView(in: window)
        XCTAssertEqual(onProject.string, "",
                       "the project's editor is showing the chapter's waiting "
                       + "words — the pane moved on and its draft did not")
        await fixture.type("y", into: onProject, until: {
            fixture.store.statement(kind: .intent, scope: .project) != nil
        })
        let projectIntent = try XCTUnwrap(
            fixture.store.statement(kind: .intent, scope: .project),
            "the second keystroke minted nothing")

        fixture.store.unlockStatementOpen(chapterIntent.id)
        try await fixture.settle(window, expectingOpsFor: chapterIntent.id, until: {
            fixture.derivedText(forDocId: chapterIntent.id) == "x"
                && fixture.derivedText(forDocId: projectIntent.id) == "y"
        })

        XCTAssertEqual(fixture.derivedText(forDocId: chapterIntent.id), "x",
                       "the chapter's waiting character was taken by the PROJECT's "
                       + "mint, or overwritten by the project's own keystroke — "
                       + "words with no file yet are held per scope for exactly "
                       + "this reason")
        XCTAssertEqual(fixture.derivedText(forDocId: projectIntent.id), "y",
                       "the project's intent holds something other than what was "
                       + "typed into it")
    }

    // MARK: - Door 3: the incoming scope has an intent of its own

    /// The same loss with the *other* refusal in front of it.
    ///
    /// When the pane moves to a scope that HAS a statement, the incoming
    /// `reconcile` binds that scope's `Document` into the box — so the mint,
    /// arriving later, is turned away by `gateArrival` (`.refuse`: someone else's
    /// live `Document` is in the box) rather than by `loadMayBind`, and it is
    /// turned away **before** the load, with no `Document` of its own to put the
    /// words into. Clicking from a chapter with no intent onto one that has an
    /// intent is the ordinary case, not a corner.
    func test_wordsSurviveAMoveOntoAScopeThatAlreadyHasAStatement() async throws {
        let fixture = try await fixture(named: "DraftSurvivesOccupiedBox")
        let docId = fixture.documentItemId
        let prose = "the book is about a house"

        // The project's intent exists and holds prose; the chapter's does not.
        let projectIntent = try await fixture.store.createStatement(
            kind: .intent, scope: .project)
        let seeded = try await Document.load(
            url: fixture.projectURL.appendingPathComponent(projectIntent.path),
            device: "seed", session: "seed", presenter: nil)
        seeded.setFullText(prose)
        try await seeded.flushBurstNow()
        await seeded.close()

        let window = await fixture.hostWithASettableSelection(
            kind: .intent, subject: .item(docId))
        let onChapter = try fixture.textView(in: window)
        XCTAssertEqual(onChapter.string, "",
                       "precondition: the chapter's intent does not exist, so the "
                       + "pane is mounted and unbound")

        let chapterIntent = try await fixture.store.createStatement(
            kind: .intent, scope: .document(docId))

        await fixture.store.lockStatementOpen(chapterIntent.id)
        await fixture.type("x", into: onChapter)
        // fixed window: asserting nothing happens — the gate must still be
        // holding the mint.
        await fixture.waitOut(0.3)
        XCTAssertNil(fixture.store.openStatementDocument(id: chapterIntent.id),
                     "the mint's load got past the gate this test is holding, so "
                     + "the wedge did not work and nothing below is evidence")

        // Onto the project, whose `Document` really loads and takes the box.
        await fixture.selectDocument(nil, until: {
            fixture.firstTextView(in: window)?.string == prose
        })
        XCTAssertEqual(try fixture.textView(in: window).string, prose,
                       "the pane never bound the project's intent, so the box is "
                       + "not occupied and this test is not about what it says")

        fixture.store.unlockStatementOpen(chapterIntent.id)
        await fixture.pumpUntil(deadline: 5) {
            !fixture.ops(forDocId: chapterIntent.id).isEmpty
        }
        // The two assertions below read the two op logs the one delivery writes:
        // the character into the chapter's, and nothing new into the project's.
        await fixture.pumpUntil(deadline: 5) {
            fixture.derivedText(forDocId: chapterIntent.id) == "x"
                && fixture.derivedText(forDocId: projectIntent.id) == prose
        }

        XCTAssertEqual(fixture.derivedText(forDocId: chapterIntent.id), "x",
                       "the mint was refused at the gate because ANOTHER "
                       + "statement's live `Document` had taken the box, and it "
                       + "dropped the writer's character on the way out. Refusing "
                       + "to BIND is right; refusing to deliver is the loss.")
        XCTAssertEqual(fixture.derivedText(forDocId: projectIntent.id), prose,
                       "and the chapter's character was written into the "
                       + "PROJECT's intent — the words followed the pane instead "
                       + "of the scope they were typed for")
    }
}

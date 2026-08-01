import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The mounted editor (M1A Task 5), driven through the **real delivery path**.
///
/// Every test here hosts the production `StatementPane` in an `NSHostingView`,
/// finds the `MaughamTextView` SwiftUI's own mounting produced, and types into
/// it through AppKit's `shouldChangeText` → `didChangeText` sequence. Nothing
/// here hand-calls `Document.setFullText`: a test that does proves the op log
/// works, not that the pane is wired to it. The previous milestone shipped 22
/// green undo tests against a ⌘Z that could not reach the stack, which is the
/// failure mode this file is shaped against — see
/// `test_theMountIsWhatCarriesTheKeystroke`, and the disable experiment
/// recorded in the task report.
@MainActor
final class StatementEditorMountTests: XCTestCase {

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

    // MARK: - §2.4: an intent edit is an ordinary typing burst

    /// The spec's §2.4 claim, made falsifiable: *carried as a `Document`, an
    /// intent edit **is** a typing burst; there is no new operation.* If the op
    /// this produces is anything other than `.typingBurst`, the claim is dead
    /// and the milestone's release story changes shape.
    func test_aKeystrokeInTheMountedPaneReachesTheOpLog() async throws {
        let fixture = try await fixture(named: "KeystrokeToOpLog")
        let statement = try await fixture.store.createStatement(kind: .intent, scope: .project)

        let window = await fixture.host(kind: .intent, activeDocumentId: nil)
        let textView = try fixture.textView(in: window)

        // Control: nothing has been typed, so nothing may be on disk yet. An
        // assertion that cannot distinguish "the mount carried it" from "it was
        // already there" is not an assertion about the mount.
        XCTAssertTrue(fixture.ops(forDocId: statement.id).isEmpty,
                      "the statement's op log is not empty before the first keystroke")

        await fixture.type("the weather is a character", into: textView)
        try await fixture.settle(window, expectingOpsFor: statement.id)

        let ops = fixture.ops(forDocId: statement.id)
        XCTAssertFalse(ops.isEmpty,
                       "typing into the mounted pane produced no op at "
                       + ".maugham/ops/\(statement.id)*.jsonl — the mount is not "
                       + "wired to the Document")
        let kinds = Set(ops.map(\.kind))
        XCTAssertEqual(kinds, [.typingBurst],
                       "spec §2.4 claims a statement edit is an ordinary typing "
                       + "burst and that this milestone needs NO new OpKind. The "
                       + "ops written were \(kinds.map(\.rawValue).sorted()). If "
                       + "that is not [typing_burst] the claim is falsified — say "
                       + "so before adding an OpKind case, because that bumps the "
                       + "manifest schema and changes the release story.")
        XCTAssertTrue(
            ops.flatMap(\.changes).contains { $0.next.contains("the weather is a character") },
            "an op landed but it does not carry the typed text: "
            + "\(ops.flatMap(\.changes).map(\.next))")
    }

    // MARK: - The mount itself

    /// The mount is what carries the keystroke — asserted against the text view
    /// **SwiftUI's own hosting produced**, not one the test built.
    ///
    /// This is the runtime half of the disable experiment. Remove the
    /// `EditorSurface` from `StatementEditorHost` and `textView(in:)` finds
    /// nothing, so this fails at the unwrap; sever the sanctioned binding and it
    /// fails at the `displayText` assertion. The manual half — patch the source,
    /// prove the patch applied, watch this go red — is recorded in the task
    /// report, because a patch that silently matches nothing runs against
    /// unmodified code and reports green.
    func test_theMountIsWhatCarriesTheKeystroke() async throws {
        let fixture = try await fixture(named: "MountCarriesKeystroke")
        let statement = try await fixture.store.createStatement(kind: .intent, scope: .project)

        let window = await fixture.host(kind: .intent, activeDocumentId: nil)
        let textView = try fixture.textView(in: window)
        XCTAssertTrue(textView.delegate is EditorCoordinator,
                      "the hosted text view is not driven by an EditorCoordinator, "
                      + "so nothing about the editor seam is being exercised")

        await fixture.type("a house on a hill", into: textView)

        // The Document the pane owns is private to it; read it back the only way
        // an outsider can — the same file, loaded again after the pane flushes.
        try await fixture.settle(window, expectingOpsFor: statement.id)
        let text = fixture.derivedText(forDocId: statement.id)
        XCTAssertEqual(text, "a house on a hill",
                       "the keystroke reached the hosted text view but not the "
                       + "statement's Document")
    }

    // MARK: - Undo

    /// ⌘Z through the window's real undo manager — not a direct call to an
    /// inverse factory. A statement edit is a typing burst, so the undo that
    /// reverts it is AppKit's own text undo flowing back through the binding.
    func test_undoInTheStatementPaneRevertsThroughTheOrdinaryRegistrar() async throws {
        let fixture = try await fixture(named: "UndoInStatementPane")
        let statement = try await fixture.store.createStatement(kind: .intent, scope: .project)

        let window = await fixture.host(kind: .intent, activeDocumentId: nil)
        let textView = try fixture.textView(in: window)

        await fixture.type("a sentence I will take back", into: textView)
        XCTAssertEqual(textView.string, "a sentence I will take back")

        let undoManager = try XCTUnwrap(textView.undoManager,
                                        "the mounted editor has no undo manager, so "
                                        + "this test could never fail")
        XCTAssertTrue(undoManager.canUndo,
                      "typing registered no undo action — ⌘Z has nothing to reach")
        while undoManager.canUndo { undoManager.undo() }

        XCTAssertEqual(textView.string, "",
                       "⌘Z did not revert the typed text in the mounted editor")
        try await fixture.settle(window)
        XCTAssertEqual(fixture.derivedText(forDocId: statement.id), "",
                       "the buffer reverted but the statement's op log did not — "
                       + "undo never reached the Document")
    }

    // MARK: - Absence is valid (spec §4.3)

    /// A scope with no statement shows an **empty editor** that mints on the
    /// first keystroke — not a "create intent" button and not a nag. Nothing is
    /// on disk until the writer types.
    func test_anUndeclaredScopeMintsNothingUntilAKeystroke() async throws {
        let fixture = try await fixture(named: "MintOnFirstKeystroke")
        XCTAssertNil(fixture.store.statement(kind: .intent, scope: .project))

        let window = await fixture.host(kind: .intent, activeDocumentId: nil)
        let textView = try fixture.textView(in: window)

        XCTAssertTrue(fixture.store.manifest.statements.isEmpty,
                      "mounting the pane registered a statement before a keystroke")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.projectURL.appendingPathComponent("intent.md").path),
            "mounting the pane wrote intent.md before a keystroke")

        await fixture.type("what this book is for", into: textView)
        await fixture.pumpUntil(deadline: 5) {
            fixture.store.statement(kind: .intent, scope: .project) != nil
        }

        let statement = try XCTUnwrap(fixture.store.statement(kind: .intent, scope: .project),
                                      "the first keystroke minted no statement")
        XCTAssertEqual(statement.path, "intent.md")
        try await fixture.settle(window, expectingOpsFor: statement.id)
        XCTAssertEqual(fixture.derivedText(forDocId: statement.id), "what this book is for",
                       "the statement was minted but the words typed before it "
                       + "existed did not reach its op log")
    }

    /// The mint happens mid-burst, under the writer's hands, and the words typed
    /// before the file existed are the ones most easily lost: they live in a
    /// draft until a `Document` exists to take them. Two paragraphs rather than
    /// one because the crossing re-derives the text — a mount that normalised it
    /// would replace the buffer and move the caret out from under the writer.
    func test_wordsTypedBeforeTheStatementExistedSurviveTheMint() async throws {
        let fixture = try await fixture(named: "WordsSurviveTheMint")
        let window = await fixture.host(kind: .visualLanguage, activeDocumentId: nil)
        let textView = try fixture.textView(in: window)

        let typed = "warm paper, cold ink\n\nno rules yet"
        await fixture.type(typed, into: textView)
        await fixture.pumpUntil(deadline: 5) {
            fixture.store.statement(kind: .visualLanguage, scope: .project) != nil
        }

        XCTAssertEqual(textView.string, typed,
                       "the buffer changed as the statement was minted — the "
                       + "editor was replaced under the writer mid-burst")

        let statement = try XCTUnwrap(
            fixture.store.statement(kind: .visualLanguage, scope: .project))
        XCTAssertEqual(statement.path, "visual-language.md")
        try await fixture.settle(window, expectingOpsFor: statement.id)
        XCTAssertEqual(fixture.derivedText(forDocId: statement.id), typed)
    }

    /// **The mint must not tear the editor down mid-word.**
    ///
    /// `createStatement` appends to `manifest.statements` and then SUSPENDS at
    /// `await saveManifest()`; `mintAndBind` suspends again at
    /// `await Document.load`. Across both, the statement exists and no
    /// `Document` is bound yet — so a mount condition derived from those two
    /// facts is FALSE for two whole suspensions, with the main actor free. A
    /// body pass landing in that window removes the `EditorSurface`, runs
    /// `dismantleNSView` → `detach()`, and builds a brand-new surface and
    /// coordinator when the bind lands: caret and first responder lost, the
    /// pane's undo stack emptied, and any keystroke arriving in the gap
    /// reaching no text view at all. That is the very "loses characters" shape
    /// `StatementTextTarget` exists to prevent — the box keeps the *binding*
    /// live; only this keeps the *view* alive.
    ///
    /// **One character, then wait** — that is what makes this able to fail. The
    /// other mint tests type a whole string first and only then wait, so every
    /// keystroke of theirs lands before the mint ever starts.
    func test_theMintDoesNotTearDownTheEditorMidWord() async throws {
        let fixture = try await fixture(named: "MintKeepsTheEditor")
        let window = await fixture.host(kind: .visualLanguage, activeDocumentId: nil)
        let original = try fixture.textView(in: window)

        await fixture.type("w", into: original)
        await fixture.pumpUntil(deadline: 5) {
            fixture.store.statement(kind: .visualLanguage, scope: .project) != nil
        }
        await fixture.waitOut(0.4)

        XCTAssertNotNil(fixture.store.statement(kind: .visualLanguage, scope: .project),
                        "the keystroke minted nothing, so this test never reached "
                        + "the window it is about")
        let now = try fixture.textView(in: window)
        XCTAssertTrue(now === original,
                      "the editor was torn down and rebuilt while the statement was "
                      + "being minted — on the first character of every new "
                      + "statement. The caret, the first responder and the pane's "
                      + "undo stack all go with it, and a keystroke arriving in the "
                      + "gap reaches no text view at all.")
        XCTAssertEqual(now.string, "w", "the typed character did not survive the mint")
    }

    /// Changing scope must close the outgoing `Document` — which is what flushes
    /// its pending typing burst — and it must do so in the same function that
    /// loads the incoming one, so the two can never be in flight together.
    ///
    /// The burst's idle threshold is 30 s, so nothing reaches the op log on its
    /// own inside this test: the control below asserts the log is still empty
    /// while the pane is live, and the flush that follows can only have come
    /// from the scope change.
    func test_changingScopeFlushesTheOutgoingStatement() async throws {
        let fixture = try await fixture(named: "ScopeChangeFlushes")
        let docId = fixture.documentItemId
        let window = await fixture.hostWithASettableSelection(
            kind: .intent, activeDocumentId: docId)
        let textView = try fixture.textView(in: window)

        await fixture.type("the aim of this chapter", into: textView)
        await fixture.pumpUntil(deadline: 5) {
            fixture.store.statement(kind: .intent, scope: .document(docId)) != nil
        }
        let statement = try XCTUnwrap(
            fixture.store.statement(kind: .intent, scope: .document(docId)))
        XCTAssertTrue(fixture.ops(forDocId: statement.id).isEmpty,
                      "the burst reached the op log on its own, so the flush "
                      + "asserted below would not be evidence of anything")

        // Nothing is selected any more: the pane falls back to the project's
        // intent, which does not exist.
        await fixture.selectDocument(nil)
        await fixture.pumpUntil(deadline: 5) { !fixture.ops(forDocId: statement.id).isEmpty }

        XCTAssertEqual(fixture.derivedText(forDocId: statement.id), "the aim of this chapter",
                       "changing scope did not flush the outgoing statement — its "
                       + "Document was abandoned with an un-bursted tail")
        let after = try fixture.textView(in: window)
        XCTAssertEqual(after.string, "",
                       "the pane still shows the previous scope's text after the "
                       + "selection changed")
        XCTAssertNil(fixture.store.statement(kind: .intent, scope: .project),
                     "falling back to the project scope minted a statement with no "
                     + "keystroke")
    }

    // MARK: - A rename does not orphan a statement (tripwire 22)

    /// Renaming the document a statement is about must not move, re-derive or
    /// orphan it: identity is the manifest `id`, and the path is derived from
    /// the title **once, at creation** (spec §2.2).
    ///
    /// Task 3 recorded this half of its contract as untested — nothing within
    /// its reach renamed a document. This is the end-to-end version, and it
    /// closes the question rather than reasoning about it: the intent is written
    /// through the pane, the document is renamed through the production
    /// `renameStructureItem`, and the pane is opened again on the other side.
    func test_renamingTheDocumentLeavesItsIntentWhereItIs() async throws {
        let fixture = try await fixture(named: "RenameSurvival")
        let docId = fixture.documentItemId

        let first = await fixture.host(kind: .intent, activeDocumentId: docId)
        let textView = try fixture.textView(in: first)
        await fixture.type("a chapter about weather", into: textView)
        await fixture.pumpUntil(deadline: 5) {
            fixture.store.statement(kind: .intent, scope: .document(docId)) != nil
        }
        let statement = try XCTUnwrap(
            fixture.store.statement(kind: .intent, scope: .document(docId)),
            "typing into a document-scoped intent minted no statement")
        try await fixture.settle(first, expectingOpsFor: statement.id)

        try await fixture.store.renameStructureItem(id: docId, newTitle: "The Storm")

        let after = try XCTUnwrap(
            fixture.store.statement(kind: .intent, scope: .document(docId)),
            "the rename lost the statement — its scope must follow the document ID, "
            + "not its title or path")
        XCTAssertEqual(after.id, statement.id, "the statement's identity changed")
        XCTAssertEqual(after.path, statement.path,
                       "the statement's path was re-derived from the new title. It "
                       + "must not be: identity is the manifest id, and the file is "
                       + "free to drift from the title (spec §2.2).")
        XCTAssertEqual(fixture.derivedText(forDocId: statement.id), "a chapter about weather",
                       "the statement's op log was orphaned by the rename")

        // …and the pane still shows it on the other side.
        let second = await fixture.host(kind: .intent, activeDocumentId: docId)
        let reopened = try fixture.textView(in: second)
        await fixture.pumpUntil(deadline: 5) { reopened.string.isEmpty == false }
        XCTAssertEqual(reopened.string, "a chapter about weather",
                       "reopening the pane after the rename showed an empty editor — "
                       + "which is also what minting a SECOND statement would look like")
    }

    // MARK: - Two editors in one window

    /// Tearing the statement pane down must not wipe the manuscript editor's
    /// undo stack.
    ///
    /// This is the first time two `EditorSurface`s are alive in one window, and
    /// `EditorCoordinator.detach()` calls `removeAllActions()` on the undo
    /// manager it can reach. If that is the window's — shared with the
    /// manuscript editor — then switching the right pane away from Intent
    /// silently destroys the writer's ⌘Z history for the chapter they are
    /// writing, which is v0.18.0's headline feature failing on a pane switch.
    func test_closingTheStatementPaneLeavesTheManuscriptUndoStackAlone() async throws {
        let fixture = try await fixture(named: "TwoEditorsOneWindow")
        try await fixture.store.createStatement(kind: .intent, scope: .project)

        let window = await fixture.hostBesideAManuscriptEditor(kind: .intent)
        let views = fixture.allTextViews(in: window)
        XCTAssertEqual(views.count, 2,
                       "expected a manuscript editor and a statement editor in one "
                       + "window; found \(views.count) text view(s)")
        let manuscript = views[0]
        let statement = views[1]

        await fixture.type("the manuscript sentence", into: manuscript)
        await fixture.type("the intent sentence", into: statement)

        let manuscriptUndo = try XCTUnwrap(manuscript.undoManager)
        XCTAssertTrue(manuscriptUndo.canUndo,
                      "the manuscript editor registered no undo action, so this "
                      + "test cannot observe one being destroyed")

        // Take the statement pane down the way a pane switch does.
        await fixture.dropStatementPane(in: window)

        XCTAssertTrue(manuscriptUndo.canUndo,
                      "closing the statement pane wiped the manuscript editor's "
                      + "undo stack — EditorCoordinator.detach() called "
                      + "removeAllActions() on an undo manager the two editors "
                      + "share. ⌘Z on the chapter is gone after a pane switch.")
    }

    /// The statement pane's editor must not answer the window's manuscript
    /// commands. Both coordinators observe ⌘⌥R, scene navigation, find-match
    /// selection and the translation membrane through
    /// `EditorCoordinator.receiverContext(.keyWindow)`; a second editor in the
    /// same window answering them is cross-talk the writer sees as the intent
    /// pane flipping into review chrome, or its caret jumping when they click a
    /// scene in the navigator.
    func test_theStatementEditorDoesNotAnswerTheWindowsManuscriptCommands() async throws {
        let fixture = try await fixture(named: "NoCommandCrossTalk")
        try await fixture.store.createStatement(kind: .intent, scope: .project)

        let window = await fixture.host(kind: .intent, activeDocumentId: nil)
        let textView = try fixture.textView(in: window)
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)

        XCTAssertNil(coordinator.receiverContext(.keyWindow),
                     "the statement pane's coordinator accepts the window's "
                     + "manuscript commands (⌘⌥R review toggle, scene/find "
                     + "navigation, the translation membrane)")

        // Control: a manuscript coordinator in a real window still answers, so
        // the assertion above is about this surface and not about a helper that
        // returns nil for everyone.
        let manuscript = EditorIntegrationHarness(initialText: "chapter one")
        XCTAssertNotNil(manuscript.coordinator.receiverContext(.keyWindow),
                        "the control coordinator answers nothing either, so the "
                        + "assertion above proves nothing")
    }

    /// The same claim, driven the way the writer drives it: ⌘⌥R posted as a real
    /// key-window command into a window holding BOTH editors.
    ///
    /// The test above asserts the mechanism — `receiverContext` returns nil. This
    /// asserts the behaviour, and it is the difference this milestone already
    /// paid for once: twenty-two green undo tests against a ⌘Z that could not
    /// reach the stack. If the context filter were bypassed, or a future
    /// observer registered without a context, the mechanism test still passes
    /// and this one does not.
    func test_toggleReviewModeReachesTheManuscriptEditorAndNotTheStatementPane() async throws {
        let fixture = try await fixture(named: "ReviewToggleCrossTalk")
        try await fixture.store.createStatement(kind: .intent, scope: .project)

        let window = await fixture.hostBesideAManuscriptEditor(kind: .intent, key: true)
        let views = fixture.allTextViews(in: window)
        XCTAssertEqual(views.count, 2,
                       "expected both editors in one window; found \(views.count)")
        let coordinators = try views.map {
            try XCTUnwrap($0.delegate as? EditorCoordinator)
        }
        let manuscript = try XCTUnwrap(
            coordinators.first { $0.respondsToWindowCommands },
            "no manuscript coordinator in this window")
        let statementPane = try XCTUnwrap(
            coordinators.first { !$0.respondsToWindowCommands },
            "no statement-pane coordinator in this window")

        // The window must report itself key, or `MaughamEvent.shouldDeliver`
        // filters the post out for BOTH editors and this test passes without
        // exercising anything. A test-host window never becomes key for real —
        // see `AlwaysKeyWindow`, which forces that one fact and leaves the rest
        // of the delivery path production.
        XCTAssertTrue(window.isKeyWindow,
                      "the hosting window does not report itself key, so a "
                      + "`.keyWindow`-scoped post reaches neither editor and this "
                      + "test would prove nothing")

        XCTAssertFalse(manuscript.isReviewMode)
        XCTAssertFalse(statementPane.isReviewMode)

        MaughamEvent.post(.maughamToggleReviewMode, to: .keyWindow)
        await fixture.waitOut(0.3)

        XCTAssertTrue(manuscript.isReviewMode,
                      "⌘⌥R did not reach the manuscript editor, so the assertion "
                      + "below cannot tell scoping from a post that went nowhere")
        XCTAssertFalse(statementPane.isReviewMode,
                       "⌘⌥R flipped the statement pane into review posture: the "
                       + "intent editor gains crafted-render chrome and a "
                       + "Comment/Query/Suggest toolbar wired to nothing")
    }
}

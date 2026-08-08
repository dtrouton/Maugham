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

        let window = await fixture.host(kind: .intent, subject: nil)
        let textView = try fixture.textView(in: window)

        // Control: nothing has been typed, so nothing may be on disk yet. An
        // assertion that cannot distinguish "the mount carried it" from "it was
        // already there" is not an assertion about the mount.
        XCTAssertTrue(fixture.ops(forDocId: statement.id).isEmpty,
                      "the statement's op log is not empty before the first keystroke")

        await fixture.type("the weather is a character", into: textView)
        try await fixture.settle(window, expectingOpsFor: statement.id, until: {
            fixture.ops(forDocId: statement.id)
                .flatMap(\.changes).contains { $0.next.contains("the weather is a character") }
        })

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

        let window = await fixture.host(kind: .intent, subject: nil)
        let textView = try fixture.textView(in: window)
        XCTAssertTrue(textView.delegate is EditorCoordinator,
                      "the hosted text view is not driven by an EditorCoordinator, "
                      + "so nothing about the editor seam is being exercised")

        await fixture.type("a house on a hill", into: textView)

        // The Document the pane owns is private to it; read it back the only way
        // an outsider can — the same file, loaded again after the pane flushes.
        try await fixture.settle(window, expectingOpsFor: statement.id, until: {
            fixture.derivedText(forDocId: statement.id) == "a house on a hill"
        })
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

        let window = await fixture.host(kind: .intent, subject: nil)
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
        // fixed window: asserting nothing happens. The op log must derive to the
        // EMPTY string, which it already does before the close flushes — so
        // there is no condition to wait on, only a span in which a burst that
        // undo failed to reach could still land.
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

        let window = await fixture.host(kind: .intent, subject: nil)
        let textView = try fixture.textView(in: window)

        XCTAssertTrue(fixture.store.manifest.statements.isEmpty,
                      "mounting the pane registered a statement before a keystroke")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.projectURL.appendingPathComponent("intent.md").path),
            "mounting the pane wrote intent.md before a keystroke")

        await fixture.type("what this book is for", into: textView, until: {
            fixture.store.statement(kind: .intent, scope: .project) != nil
        })

        let statement = try XCTUnwrap(fixture.store.statement(kind: .intent, scope: .project),
                                      "the first keystroke minted no statement")
        XCTAssertEqual(statement.path, "intent.md")
        try await fixture.settle(window, expectingOpsFor: statement.id, until: {
            fixture.derivedText(forDocId: statement.id) == "what this book is for"
        })
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
        let window = await fixture.host(kind: .visualLanguage, subject: nil)
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
        try await fixture.settle(window, expectingOpsFor: statement.id, until: {
            fixture.derivedText(forDocId: statement.id) == typed
        })
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
        let window = await fixture.host(kind: .visualLanguage, subject: nil)
        let original = try fixture.textView(in: window)

        await fixture.type("w", into: original)
        await fixture.pumpUntil(deadline: 5) {
            fixture.store.statement(kind: .visualLanguage, scope: .project) != nil
        }
        // fixed window: asserting nothing happens. The claim below is that the
        // editor is NOT torn down and rebuilt across the mint's two suspensions,
        // so the span after the mint lands IS the test — a condition wait would
        // return before the body pass that does the damage.
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
            kind: .intent, subject: .item(docId))
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
        await fixture.selectDocument(nil, until: {
            !fixture.ops(forDocId: statement.id).isEmpty
        })

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

    /// A scope change that does not complete must not leave the OLD scope
    /// looking resolved.
    ///
    /// `reconcile` closes and releases the outgoing `Document` before it can
    /// know whether the incoming one will load. If it then exits early — a
    /// failed load, or a cancellation because the writer moved again — the
    /// marker still names the outgoing scope, and `.task(id:)`'s own
    /// `guard resolvedScope != key` makes the returning task a no-op. The pane
    /// mounts anyway, over a target that has been emptied.
    ///
    /// **The worst outcome needs no race at all**, and this test drives it: one
    /// failed load and a switch back, after which the editor shows the writer's
    /// existing intent as EMPTY — and the first keystroke calls `mintAndBind`,
    /// which find-or-creates (returning the statement that already exists) and
    /// binds `carryingDraft: true`, replacing the whole intent with that one
    /// character. The two cancellation exits reach the same state by a narrower
    /// door: a mounted editor over another scope's `Document`, or over one that
    /// `close()` has already husked.
    func test_aFailedScopeChangeDoesNotLeaveTheOldScopeLookingResolved() async throws {
        let fixture = try await fixture(named: "StaleResolvedScope")
        let docId = fixture.documentItemId
        let prose = "the chapter is about the weather"

        // A — the chapter's intent, with prose already in its op log.
        let chapterIntent = try await fixture.store.createStatement(
            kind: .intent, scope: .document(docId))
        let seeded = try await Document.load(
            url: fixture.projectURL.appendingPathComponent(chapterIntent.path),
            device: "seed", session: "seed", presenter: nil)
        seeded.setFullText(prose)
        try await seeded.flushBurstNow()
        await seeded.close()

        // B — the project's intent, a file with content and NO op log, so
        // loading it BOOTSTRAPS, and bootstrapping is a write.
        let projectIntent = try await fixture.store.createStatement(
            kind: .intent, scope: .project)
        try Data(prose.utf8).write(
            to: fixture.projectURL.appendingPathComponent(projectIntent.path))

        let window = await fixture.hostWithASettableSelection(
            kind: .intent, subject: .item(docId))
        let onA = try fixture.textView(in: window)
        await fixture.pumpUntil(deadline: 5) { !onA.string.isEmpty }
        XCTAssertEqual(onA.string, prose,
                       "the pane never showed the chapter's existing intent, so "
                       + "this test has not reached the state it is about")

        // Make B's load fail: an unwritable op-log directory turns its
        // bootstrap append into a throw.
        let opsDirectory = fixture.projectURL.appendingPathComponent(".maugham/ops")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: opsDirectory.path)
        await fixture.selectDocument(nil)
        // fixed window: asserting nothing happens. "No editor" has to hold for a
        // span — a wait that stopped the moment the surface went away would pass
        // on a transient nil and miss the editor coming back over content that
        // never arrived, which is the whole defect.
        await fixture.waitOut(0.4)
        XCTAssertNil(fixture.firstTextView(in: window),
                     "a scope whose Document failed to load must show no editor — "
                     + "an editable surface over content that never arrived is how "
                     + "an empty draft overwrites a statement")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: opsDirectory.path)

        // Back to the chapter. The marker must not still be claiming it.
        await fixture.selectDocument(docId, until: {
            fixture.firstTextView(in: window) != nil
        })
        let backOnA = try fixture.textView(in: window)
        await fixture.pumpUntil(deadline: 5) { !backOnA.string.isEmpty }
        XCTAssertEqual(backOnA.string, prose,
                       "returning to the chapter showed an EMPTY editor over its "
                       + "existing intent — the failed scope change left the old "
                       + "scope marked resolved while its Document was released, "
                       + "so the returning reconcile early-returned and repaired "
                       + "nothing")

        // …and the next keystroke adds to the prose rather than replacing it.
        await fixture.type("!", into: backOnA)
        // fixed window: asserting nothing happens. The claim is that one
        // keystroke did NOT replace the writer's intent, and the prefix it
        // checks is already true before the close flushes — so there is nothing
        // to wait for, only a span in which a replacing burst could land.
        try await fixture.settle(window, expectingOpsFor: chapterIntent.id)
        XCTAssertTrue(
            fixture.derivedText(forDocId: chapterIntent.id).hasPrefix(prose),
            "one keystroke replaced the writer's whole intent: "
            + "\"\(fixture.derivedText(forDocId: chapterIntent.id))\"")
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

        let first = await fixture.host(kind: .intent, subject: .item(docId))
        let textView = try fixture.textView(in: first)
        await fixture.type("a chapter about weather", into: textView, until: {
            fixture.store.statement(kind: .intent, scope: .document(docId)) != nil
        })
        let statement = try XCTUnwrap(
            fixture.store.statement(kind: .intent, scope: .document(docId)),
            "typing into a document-scoped intent minted no statement")
        try await fixture.settle(first, expectingOpsFor: statement.id, until: {
            fixture.derivedText(forDocId: statement.id) == "a chapter about weather"
        })

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
        let second = await fixture.host(kind: .intent, subject: .item(docId))
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

        // Take the statement pane down the way a pane switch does. Its settle
        // window stays fixed: asserting nothing happens — `canUndo` is already
        // true, and the span after the pane goes is where `detach()`'s
        // `removeAllActions()` would make it false.
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

        let window = await fixture.host(kind: .intent, subject: nil)
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
        // One post, both observers: the delivery that flips the manuscript is
        // the same one that must leave the statement pane alone, so waiting for
        // the positive half settles the negative one too.
        await fixture.pumpUntil(deadline: 5) { manuscript.isReviewMode }

        XCTAssertTrue(manuscript.isReviewMode,
                      "⌘⌥R did not reach the manuscript editor, so the assertion "
                      + "below cannot tell scoping from a post that went nowhere")
        XCTAssertFalse(statementPane.isReviewMode,
                       "⌘⌥R flipped the statement pane into review posture: the "
                       + "intent editor gains crafted-render chrome and a "
                       + "Comment/Query/Suggest toolbar wired to nothing")
    }

    // MARK: - A superseded load must not bind (whole-branch review, C1)

    /// **The wedge is the production gate, not a sleep.** Both tests below need
    /// a load that is provably still in flight while a second scope resolves,
    /// and `load`'s first line is `await store.lockStatementOpen(statement.id)`
    /// — so a test that takes that gate first parks the load exactly where it
    /// needs it, for as long as it likes, with no timing assumption anywhere.
    /// The alternative the review suggested (a fixture that changes the
    /// selection without waiting out the load) races `Document.load` against a
    /// pump interval and would be flaky in the safe direction, which is the
    /// worst kind of regression test: green whether or not the bug is there.

    /// A `reconcile` that has been superseded must not bind its `Document` into
    /// the target the pane is now showing for another scope.
    ///
    /// The arm needs no race the writer has to lose. The chapter has an intent
    /// and the project does not — the ordinary case — so the incoming
    /// `reconcile` for the project scope is **wholly synchronous** (nothing to
    /// close, no statement to load) and finishes while the outgoing one is
    /// still in file I/O. It then binds the CHAPTER's `Document` into the box
    /// the pane is showing for the project, nothing invalidates the body, and
    /// the writer's next keystroke arrives as
    /// `chapterDocument.setFullText("y")` — the whole chapter intent replaced
    /// by one character. Same outcome as N1 and Task 7's C1, through a door
    /// neither fix covers: `carryingDraft` is false here, and `resolvedScope`
    /// is *correct* — it names the project. The target is what is wrong.
    func test_aSupersededLoadDoesNotBindIntoTheScopeThatReplacedIt() async throws {
        let fixture = try await fixture(named: "SupersededLoad")
        let docId = fixture.documentItemId
        let prose = "the chapter is about the weather"

        // The chapter has an intent with real prose in its op log; the project
        // has none.
        let chapterIntent = try await fixture.store.createStatement(
            kind: .intent, scope: .document(docId))
        let seeded = try await Document.load(
            url: fixture.projectURL.appendingPathComponent(chapterIntent.path),
            device: "seed", session: "seed", presenter: nil)
        seeded.setFullText(prose)
        try await seeded.flushBurstNow()
        await seeded.close()

        let window = await fixture.hostWithASettableSelection(
            kind: .intent, subject: nil)
        XCTAssertNotNil(fixture.firstTextView(in: window),
                        "the project scope never resolved, so this test has not "
                        + "reached the state it is about")

        // Hold the chapter's open gate, so the reconcile the next line starts
        // parks inside `load` and cannot possibly finish first.
        await fixture.store.lockStatementOpen(chapterIntent.id)
        await fixture.selectDocument(docId)
        XCTAssertNil(fixture.store.openStatementDocument(id: chapterIntent.id),
                     "the chapter's load got past the gate this test is holding, "
                     + "so the wedge did not work and nothing below is evidence")

        // Move again before it can land. The project scope resolves entirely
        // synchronously.
        await fixture.selectDocument(nil)
        // Let the superseded load through.
        fixture.store.unlockStatementOpen(chapterIntent.id)
        // fixed window: asserting nothing happens. The released load has to be
        // given room to (wrongly) register — a shorter wait passes because the
        // load had not landed yet, which is green whether or not the bug is
        // there.
        await fixture.waitOut(0.5)

        XCTAssertNil(fixture.store.openStatementDocument(id: chapterIntent.id),
                     "a superseded load registered its `Document` as the live one "
                     + "for the chapter's intent while the pane shows the "
                     + "project's — which is what `appendToStatement` and "
                     + "`statementText(of:)` then read, and it is never closed")

        // The keystroke is the proof: it must not reach the chapter. Settle
        // first — the burst's idle threshold is 30 s, so the op log says
        // nothing about a keystroke until the pane's teardown flushes it.
        let textView = try fixture.textView(in: window)
        await fixture.type("y", into: textView)
        // fixed window: asserting nothing happens. The chapter's derived text
        // must be UNCHANGED, so it is already what the assertion wants before
        // the close flushes; the span is what gives a wrongful write time to
        // arrive.
        try await fixture.settle(window)
        XCTAssertEqual(fixture.derivedText(forDocId: chapterIntent.id), prose,
                       "typing into the pane while it showed the PROJECT's intent "
                       + "rewrote the CHAPTER's — the superseded load bound its "
                       + "Document into the box the new scope is using")
        XCTAssertNotNil(fixture.store.statement(kind: .intent, scope: .project),
                        "the keystroke minted no project statement, so it went "
                        + "somewhere else entirely")
    }

    /// The mint's load is never cancelled by anything, so it needs the same
    /// refusal and cannot get it from `Task.isCancelled`.
    ///
    /// `mintAndBind` runs a detached `Task { @MainActor in }`; SwiftUI's
    /// `.task(id:)` knows nothing about it. The reachable shape is the one
    /// `StatementTextTarget.bind` already documents: a statement created out of
    /// band into a scope this pane resolved as empty, so the pane is mounted and
    /// unbound over content that exists. The first keystroke find-or-creates
    /// (getting that statement back) and loads it — and if the writer moves on
    /// while it loads, that load lands in the new scope's box.
    func test_aMintThatOutlivesItsScopeDoesNotBindIntoTheNextOne() async throws {
        let fixture = try await fixture(named: "MintOutlivesScope")
        let docId = fixture.documentItemId
        let prose = "the book is about a house"

        // The pane resolves the project scope as empty…
        let window = await fixture.hostWithASettableSelection(
            kind: .intent, subject: nil)
        let onProject = try fixture.textView(in: window)

        // …and only then does the project's intent come into existence, with
        // prose in it. Nothing re-runs `reconcile`, so the pane stays unbound.
        let projectIntent = try await fixture.store.createStatement(
            kind: .intent, scope: .project)
        let seeded = try await Document.load(
            url: fixture.projectURL.appendingPathComponent(projectIntent.path),
            device: "seed", session: "seed", presenter: nil)
        seeded.setFullText(prose)
        try await seeded.flushBurstNow()
        await seeded.close()

        // Park the mint's load on the production gate.
        await fixture.store.lockStatementOpen(projectIntent.id)
        await fixture.type("x", into: onProject)
        // fixed window: asserting nothing happens — the wedge held.
        await fixture.waitOut(0.3)
        XCTAssertNil(fixture.store.openStatementDocument(id: projectIntent.id),
                     "the mint's load got past the gate this test is holding, so "
                     + "the wedge did not work and nothing below is evidence")

        // Move to the chapter, which has no intent — so it resolves
        // synchronously and mounts an empty editor.
        await fixture.selectDocument(docId)
        fixture.store.unlockStatementOpen(projectIntent.id)
        // fixed window: asserting nothing happens. The released mint has to be
        // given room to (wrongly) register the project's `Document`; a wait
        // that stopped sooner would be green whether or not it does.
        await fixture.waitOut(0.5)

        XCTAssertNil(fixture.store.openStatementDocument(id: projectIntent.id),
                     "the mint's load registered the PROJECT's Document while the "
                     + "pane shows the chapter — nothing will ever close it, and "
                     + "every statement writer reads it as the live one")

        let onChapter = try fixture.textView(in: window)
        await fixture.type("y", into: onChapter)
        // The close is what flushes the "y", and where it lands is the whole
        // question: the last assertion below wants it in the CHAPTER's intent,
        // and the middle one wants it out of the project's. One delivery
        // settles both, so waiting for the positive half is enough — and if the
        // "y" goes to the project instead, this waits out its deadline and the
        // assertions fail as they always did.
        try await fixture.settle(window, until: {
            guard let chapter = fixture.store.statement(
                kind: .intent, scope: .document(docId)) else { return false }
            return fixture.derivedText(forDocId: chapter.id) == "y"
        })
        // **This asserted `prose` for a whole milestone, and that expectation was
        // wrong** (issue #21). It was written to pin one claim — the "y" typed
        // under the chapter's header must not reach the project's intent — but
        // equality against `prose` alone also pinned the loss of the "x" typed
        // *while the pane was showing the project*, which the superseded mint
        // then threw away. Those characters were always going to this statement:
        // the writer typed them here, and the pane moving on is not un-typing
        // them. The refusal is about BINDING, and it says nothing about where the
        // words go — so the mint now deposits into the file it created and closes
        // it, and this expectation carries both halves explicitly.
        XCTAssertEqual(fixture.derivedText(forDocId: projectIntent.id),
                       prose + "\n\nx",
                       "the project's intent must hold its prose and the "
                       + "character typed into the pane while it was showing the "
                       + "project, and nothing else")
        XCTAssertFalse(fixture.derivedText(forDocId: projectIntent.id).contains("y"),
                       "typing under the CHAPTER's header rewrote the PROJECT's "
                       + "intent — the mint bound its Document into the box the "
                       + "next scope is using, and no cancellation ever arrives "
                       + "on that path to stop it")
        // …and the "y" is not merely absent from the project's intent, it is in
        // the chapter's. An assertion that only says where it is NOT passes when
        // it is nowhere at all.
        let chapterIntent = try XCTUnwrap(
            fixture.store.statement(kind: .intent, scope: .document(docId)),
            "the keystroke under the chapter's header minted no statement, so "
            + "the assertion above cannot tell scoping from a second loss")
        XCTAssertEqual(fixture.derivedText(forDocId: chapterIntent.id), "y")
    }

    /// The other half of that same door: the writer comes BACK.
    ///
    /// `loadMayBind` refuses a mint whose pane has moved ON — and **both of its
    /// signals are true when the pane returns to the scope the mint is for**.
    /// Nothing cancels a mint, and the destination it named matches the one the
    /// pane wants again. So the mint binds, `reconcile`'s own load binds, and
    /// the first `Document` is dropped from the box **unclosed**: two live
    /// `Document`s on one statement's file, each with its own `PendingBuffer`,
    /// which is what `ProjectStore.lockStatementOpen` exists to prevent. It is
    /// the defect one level below the superseded-load one above — that was the
    /// wrong scope's document, this is two of the right scope's.
    ///
    /// **The interleaving is the test's, not the runloop's.** Three openers
    /// queue on the production gate in a known order — the mint, this test, and
    /// then the pane's `reconcile` — so the test holds the path at exactly the
    /// instant the mint has bound and the reconcile has not yet loaded, and
    /// asserts that the second load never displaces the first. Without the
    /// middle waiter the only window is one `Document.load` wide and can be
    /// observed only by polling.
    func test_aMintAndAReturningPaneDoNotBothBindTheSameStatement() async throws {
        let fixture = try await fixture(named: "MintAndReturn")
        let docId = fixture.documentItemId
        let prose = "the book is about a house"

        // The pane resolves the project scope as empty…
        let window = await fixture.hostWithASettableSelection(
            kind: .intent, subject: nil)
        let onProject = try fixture.textView(in: window)

        // …and only then does the project's intent come into existence, with
        // prose in it — `StatementTextTarget.bind`'s out-of-band creator.
        // Nothing re-runs `reconcile`, so the pane stays unbound and the first
        // keystroke find-or-creates its way to THIS statement.
        let projectIntent = try await fixture.store.createStatement(
            kind: .intent, scope: .project)
        let seeded = try await Document.load(
            url: fixture.projectURL.appendingPathComponent(projectIntent.path),
            device: "seed", session: "seed", presenter: nil)
        seeded.setFullText(prose)
        try await seeded.flushBurstNow()
        await seeded.close()

        // Park the mint's load on the production gate.
        await fixture.store.lockStatementOpen(projectIntent.id)
        await fixture.type("x", into: onProject)
        // fixed window: asserting nothing happens — the wedge held.
        await fixture.waitOut(0.3)
        XCTAssertNil(fixture.store.openStatementDocument(id: projectIntent.id),
                     "the mint's load got past the gate this test is holding, so "
                     + "the wedge did not work and nothing below is evidence")

        // Queued behind the mint and ahead of everything the pane does next.
        let between = Task { @MainActor in
            await fixture.store.lockStatementOpen(projectIntent.id)
        }
        // Both the mint and this wedge must be PARKED before the pane moves, or
        // the wedge does not sit between them. Same reading as the poll below,
        // and for the same reason (Measured 2026-08-02): a fixed window here is
        // a guess about how long the mint takes to reach the gate.
        await fixture.pumpUntil(deadline: 5) {
            (fixture.store.statementOpenWaiters[projectIntent.id]?.count ?? 0) >= 2
        }

        // The writer visits the chapter (no intent, so it resolves
        // synchronously) and comes back. `reconcile` finds the statement that
        // now exists and starts a load of its own, which queues behind us.
        await fixture.selectDocument(docId)
        await fixture.selectDocument(nil)
        // **Wait for the third opener to actually REACH the gate**, rather than
        // trusting `selectDocument`'s fixed settle window to have been long
        // enough. All three — the mint, this test's wedge and the returning
        // pane's load — have to be parked before the release, or the
        // interleaving this test is about never happens and it fails on its own
        // precondition. Measured 2026-08-02: in a 4,089-test run the pane's load
        // had not reached `lockStatementOpen` within the 0.3s window, and the
        // test went red without anything it guards having changed. A poll on the
        // queue itself is the deterministic form of the same wait; when the
        // window was already enough it returns at once.
        await fixture.pumpUntil(deadline: 5) {
            (fixture.store.statementOpenWaiters[projectIntent.id]?.count ?? 0) >= 3
        }

        // Released: the mint takes the path, binds and registers; we take it
        // next; the returning pane's load is still queued.
        fixture.store.unlockStatementOpen(projectIntent.id)
        await between.value
        let bound = fixture.store.openStatementDocument(id: projectIntent.id)
        let queuedBehindUs = fixture.store.statementOpenWaiters[projectIntent.id]?.count ?? 0
        // Before any assertion, so a failing one cannot leave the pane's load
        // parked on a gate nobody will open.
        fixture.store.unlockStatementOpen(projectIntent.id)
        // fixed window: asserting nothing happens. The released load has to be
        // given room to displace the first `Document` (or close it) — the
        // assertions below read state that must be UNCHANGED once it has run.
        await fixture.waitOut(0.6)

        XCTAssertEqual(queuedBehindUs, 1,
                       "the returning pane's load was not queued behind this "
                       + "test, so the interleaving this test is about never "
                       + "happened and nothing below is evidence")
        let first = try XCTUnwrap(bound,
                                  "the mint bound nothing, so there is no first "
                                  + "`Document` for a second one to displace")
        XCTAssertTrue(fixture.store.openStatementDocument(id: projectIntent.id) === first,
                      "the returning pane opened a SECOND `Document` on a path "
                      + "that already had a live one — same scope, so no "
                      + "cancellation and no mismatched destination refuses it")
        XCTAssertFalse(first.isClosed,
                       "and nothing closed the one it displaced: its "
                       + "`PendingBuffer` is still live on the writer's file, "
                       + "which is the loss the open gate exists to prevent")
        // **`prose` was the wrong expectation here too** (issue #21), for the
        // same reason and through the same door: the "x" was typed into this
        // pane while it showed this scope, and `reconcile`'s `release()` used to
        // empty it out from under the mint that was creating its file. The pane
        // returning is what makes this arm different from the one above — the
        // mint may bind — and either way the character belongs in the statement
        // the writer typed it into.
        XCTAssertEqual(try fixture.textView(in: window).string, prose + "\n\nx",
                       "the pane never came back off its placeholder, or came "
                       + "back empty over the writer's prose — a load that "
                       + "declines to open a second `Document` must still leave "
                       + "the scope resolved, showing the prose AND the character "
                       + "typed before the pane moved")
    }

    /// The rule itself, over the whole product of its inputs — the file's own
    /// idiom (`shouldMount`, `showsPictureWell`), so the refusal is asserted
    /// deterministically rather than only through the two races above.
    func test_aLoadMayBindOnlyIntoTheScopeItWasStartedFor() {
        let mine = "intent|project"
        let other = "intent|document:ch1"

        XCTAssertTrue(
            StatementEditorHost.loadMayBind(
                loadedScope: mine, paneWants: mine, cancelled: false),
            "the ordinary load refused to bind, so the pane would never show "
            + "anything at all")

        XCTAssertFalse(
            StatementEditorHost.loadMayBind(
                loadedScope: mine, paneWants: other, cancelled: false),
            "a load bound into a box another scope has claimed — the mint arm, "
            + "where no cancellation ever arrives")
        XCTAssertFalse(
            StatementEditorHost.loadMayBind(
                loadedScope: mine, paneWants: mine, cancelled: true),
            "a cancelled load bound anyway")
        XCTAssertFalse(
            StatementEditorHost.loadMayBind(
                loadedScope: mine, paneWants: nil, cancelled: false),
            "a load bound into a pane that has left — `.onDisappear` closed the "
            + "Document and forgot the registration, so this one is registered "
            + "with nothing left to close it")
        XCTAssertFalse(
            StatementEditorHost.loadMayBind(
                loadedScope: mine, paneWants: other, cancelled: true),
            "both signals wrong and it bound regardless")
    }

    /// And the refusal on the OTHER side of the load, over its own inputs.
    func test_aLoadHoldingTheGateReAsksWhatIsAlreadyInTheBox() {
        XCTAssertEqual(
            StatementEditorHost.gateArrival(liveStatementID: nil, loading: "stmt-1"),
            .load,
            "an empty box refused a load, so the pane would never bind at all")
        XCTAssertEqual(
            StatementEditorHost.gateArrival(liveStatementID: "stmt-1", loading: "stmt-1"),
            .alreadyBound,
            "a load opened a second `Document` on a statement the box already "
            + "holds live — the mint-and-return race")
        XCTAssertEqual(
            StatementEditorHost.gateArrival(liveStatementID: "stmt-2", loading: "stmt-1"),
            .refuse,
            "a load displaced ANOTHER statement's live `Document` rather than "
            + "leaving the pane where it is")
    }

    /// A husk in the box is not a live `Document`, and must not be mistaken for
    /// one: `.onDisappear` closes without releasing, so the box outlives what it
    /// holds. Answering `.alreadyBound` over a closed `Document` would mount the
    /// pane on a surface whose every keystroke no-ops.
    func test_theBoxAnswersForALiveDocumentOnly() async throws {
        let fixture = try await fixture(named: "BoxLiveness")
        let statement = try await fixture.store.createStatement(
            kind: .intent, scope: .project)
        let document = try await Document.load(
            url: fixture.projectURL.appendingPathComponent(statement.path),
            device: "seed", session: "seed", presenter: nil)

        let target = StatementTextTarget()
        XCTAssertNil(target.liveStatementID, "an empty box named a statement")
        target.bind(document, id: statement.id, for: "intent|project")
        XCTAssertEqual(target.liveStatementID, statement.id)

        await document.close()
        XCTAssertNil(target.liveStatementID,
                     "a closed `Document` still read as the live one, so a load "
                     + "would decline to replace a husk")
    }
}

import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A statement's verbs are undone where ⌘Z looks** (shell plan 3 Task 5 fix
/// 3, review B2). With the statement's editor holding the keys, ⌘Z runs that
/// editor's own manager (`MaughamTextView.undo:`), so Adopt, Revoke and Edit
/// ruling register there — one ordered history of the statement's typing and
/// verbs — and write undo-coherently so the editor's buffer replace keeps the
/// registration. With no editor (a reading view), ⌘Z walks to the window, so
/// they register on the window's manager. Mounted measurements; nothing is
/// pressed (the verbs are the panes' own static entry points).
@MainActor
final class StatementVerbUndoTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { fixture.tearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func fixture(_ name: String) async throws -> StatementMountFixture {
        let made = try await StatementMountFixture.novel(named: name)
        fixtures.append(made)
        return made
    }

    private let undo = Selector(("undo:"))

    private func ruling(_ text: String) -> Ruling {
        Ruling(id: "", text: text, ruledOn: Date(timeIntervalSince1970: 1_700_000_000), provenance: "test")
    }

    private func rulings(_ f: StatementMountFixture, _ scope: Statement.Scope) -> [String] {
        RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).map(\.text)
    }

    func test_aRevokeWithTheEditorFocusedIsUndoneByItsUndo() async throws {
        let f = try await fixture("VerbUndoRevoke")
        let scope = Statement.Scope.document(f.documentItemId)
        let statement = try await f.store.createStatement(kind: .intent, scope: scope)
        try await f.store.mutateStatementText(of: statement, session: "verb-undo") { _ in
            RulingsSection.render(essay: "Chapter one turns on a lie.", rulings: [self.ruling("no flashbacks")])
        }
        let window = f.hostView(AnyView(StatementEditorHost(
            store: f.store, documentStore: f.documentStore, kind: .intent, scope: scope, posture: .author)),
                                width: 400)
        await pumpUntil(deadline: 5) {
            f.store.openStatementDocument(id: statement.id) != nil && f.firstTextView(in: window) != nil
        }
        let editor = try f.textView(in: window)
        window.makeFirstResponder(editor)
        let statementUndo = try XCTUnwrap(editor.undoManager)
        XCTAssertFalse(statementUndo === window.undoManager, "premise: the editor's own manager")
        XCTAssertTrue(f.store.undoManagerForStatementVerb(kind: .intent, scope: scope, window: window.undoManager)
                      === statementUndo, "a verb registers where this editor's ⌘Z runs")

        var tasks: [Task<Void, Never>] = []
        let row = try XCTUnwrap(RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).first)
        await RulingsStratum.revokeFromAPane(row, at: 0, kind: .intent, forScope: scope, store: f.store,
                                             world: nil, window: window.undoManager,
                                             workTaskSink: { tasks.append($0) })
        await waitOut(0.3)   // the editor's update pass applies the new text
        XCTAssertEqual(rulings(f, scope), [], "premise: revoked")
        XCTAssertTrue(statementUndo.canUndo, "the buffer replace kept the Revoke's registration")
        XCTAssertEqual(statementUndo.undoActionName, "Revoke Ruling")

        XCTAssertTrue(editor.tryToPerform(undo, with: nil), "⌘Z in the statement's editor")
        for task in tasks { await task.value }
        await waitOut(0.3)
        XCTAssertEqual(rulings(f, scope), ["no flashbacks"], "⌘Z undid the Revoke, not older typing")
        XCTAssertTrue(statementUndo.canRedo)
    }

    func test_anAdoptWithTheEditorFocusedIsUndoneByItsUndo() async throws {
        let f = try await fixture("VerbUndoAdopt")
        let statement = try await f.store.createStatement(kind: .visualLanguage, scope: .project)
        try await f.store.mutateStatementText(of: statement, session: "verb-undo") { _ in "Old look." }
        let window = f.hostView(AnyView(StatementEditorHost(
            store: f.store, documentStore: f.documentStore, kind: .visualLanguage, scope: .project,
            posture: .author)), width: 400)
        await pumpUntil(deadline: 5) {
            f.store.openStatementDocument(id: statement.id) != nil && f.firstTextView(in: window) != nil
        }
        let editor = try f.textView(in: window)
        window.makeFirstResponder(editor)
        let statementUndo = try XCTUnwrap(editor.undoManager)
        let proposal = try StatementProposalStore(projectURL: f.projectURL).stage(.init(
            kind: .visualLanguage, markdown: "Serif, generous leading.",
            rationale: nil, proposedAt: Date(), author: "Claude"))

        var tasks: [Task<Void, Never>] = []
        _ = try await StatementProposalGate.adoptFromAPane(proposal, store: f.store, world: nil,
                                                           window: window.undoManager,
                                                           workTaskSink: { tasks.append($0) })
        await pumpUntil(deadline: 3) { editor.string.contains("Serif") }
        await waitOut(0.2)
        XCTAssertTrue(editor.string.contains("Serif"), "premise: adopted into the bound editor")
        XCTAssertTrue(statementUndo.canUndo, "⌘Z is not greyed out after Adopt")

        XCTAssertTrue(editor.tryToPerform(undo, with: nil))
        for task in tasks { await task.value }
        await pumpUntil(deadline: 3) { (try? f.store.statementText(of: statement)) == "Old look." }
        XCTAssertEqual(try f.store.statementText(of: statement), "Old look.", "⌘Z undid the Adopt")
    }

    /// No editor holds the statement (Brief's reading view, a closed pane):
    /// the verbs register on the window's manager, where ⌘Z walks.
    func test_inTheReadingViewTheVerbsRegisterOnTheWindow() async throws {
        let f = try await fixture("VerbUndoReading")
        let scope = Statement.Scope.document(f.documentItemId)
        let statement = try await f.store.createStatement(kind: .intent, scope: scope)
        try await f.store.mutateStatementText(of: statement, session: "verb-undo") { _ in
            RulingsSection.render(essay: "Chapter one.", rulings: [self.ruling("no flashbacks")])
        }
        XCTAssertNil(f.store.openStatementDocument(id: statement.id), "premise: no editor holds it")
        let windowUndo = UndoManager()
        XCTAssertTrue(f.store.undoManagerForStatementVerb(kind: .intent, scope: scope, window: windowUndo)
                      === windowUndo)

        var tasks: [Task<Void, Never>] = []
        let row = try XCTUnwrap(RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).first)
        await RulingsStratum.revokeFromAPane(row, at: 0, kind: .intent, forScope: scope, store: f.store,
                                             world: nil, window: windowUndo,
                                             workTaskSink: { tasks.append($0) })
        await waitOut(0.1)
        XCTAssertEqual(rulings(f, scope), [])
        XCTAssertTrue(windowUndo.canUndo)
        windowUndo.undo()
        for task in tasks { await task.value }
        XCTAssertEqual(rulings(f, scope), ["no flashbacks"], "⌘Z from the window undid the Revoke")

        let vl = try await f.store.createStatement(kind: .visualLanguage, scope: .project)
        try await f.store.mutateStatementText(of: vl, session: "verb-undo") { _ in "Old look." }
        let proposal = try StatementProposalStore(projectURL: f.projectURL).stage(.init(
            kind: .visualLanguage, markdown: "Serif.", rationale: nil, proposedAt: Date(), author: "Claude"))
        tasks.removeAll()
        _ = try await StatementProposalGate.adoptFromAPane(proposal, store: f.store, world: nil,
                                                           window: windowUndo,
                                                           workTaskSink: { tasks.append($0) })
        await waitOut(0.1)
        XCTAssertEqual(windowUndo.undoActionName, StatementProposalCopy.undoActionName)
        windowUndo.undo()
        for task in tasks { await task.value }
        XCTAssertEqual(try f.store.statementText(of: vl), "Old look.", "⌘Z from the window undid the Adopt")
    }
}

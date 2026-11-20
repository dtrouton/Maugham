import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A statement's verbs are undone where ⌘Z looks** (shell plan 3 Task 5 fix
/// 3, 4 and 5). The manager is chosen once, at the press: the one ⌘Z will run
/// from where the keys are (`StatementVerbUndo.manager`). With the keys in a
/// second editor — the statement's own, another statement's, a pulled-up
/// research note's — that editor answers ⌘Z on its own manager
/// (`MaughamTextView.undo:`), so Adopt, Revoke and Edit ruling register
/// there; anywhere else (the manuscript, the tree, a field, nothing) ⌘Z
/// walks to the window, so they register on the window's. Each of the verb's
/// writes says which manager that was (`StatementWriteUndo`): it is
/// undo-coherent only on the statement's own editor's, where it drops that
/// editor's typing and keeps earlier verbs; plain on any other. Mounted
/// measurements; nothing is pressed (the chooser and the verbs are the ones
/// the panes' buttons call).
@MainActor
final class StatementVerbUndoTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { await fixture.closeAndTearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func fixture(_ name: String) async throws -> StatementMountFixture {
        let made = try await StatementMountFixture.novel(named: name)
        fixtures.append(made)
        return made
    }

    private let undo = Selector(("undo:"))
    private let redo = Selector(("redo:"))

    /// **The boundary between two of the writer's acts.** The app's event loop
    /// closes each event's undo group (`groupsByEvent`); the test host's body
    /// runs inside one run-loop callout, so no event group ever closes on its
    /// own and two acts would fold into one ⌘Z (measured: the level stays 1
    /// across run-loop turns). So the managers an act lands on have
    /// `groupsByEvent` off (`ownGroups`), and each act brackets itself
    /// (`act`) — public API only (shell p3 final wave; it used AppKit's
    /// private end-of-event call before).
    private func ownGroups(_ managers: UndoManager...) {
        for manager in managers { manager.groupsByEvent = false }
    }

    /// One act as one undo step: a group opened on each manager and closed
    /// after `body` — over its awaits, because a verb registers in a task
    /// continuation. ⌘Z and ⇧⌘Z are not acts: `undo()` groups its own redo.
    private func act(on managers: UndoManager..., do body: () async throws -> Void) async rethrows {
        for manager in managers { manager.beginUndoGrouping() }
        try await body()
        for manager in managers {
            manager.endUndoGrouping()
            XCTAssertEqual(manager.groupingLevel, 0, "premise: the act's group closed")
        }
    }

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
        let chosen = StatementVerbUndo.manager(window: window.undoManager)
        XCTAssertTrue(chosen === statementUndo, "a verb registers where this editor's ⌘Z runs")

        var tasks: [Task<Void, Never>] = []
        let row = try XCTUnwrap(RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).first)
        await RulingsStratum.revoke(row, at: 0, kind: .intent, forScope: scope, store: f.store,
                                    world: nil, undoManager: chosen,
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
        let chosen = StatementVerbUndo.manager(window: window.undoManager)
        XCTAssertTrue(chosen === statementUndo, "premise: the keys are the statement's editor's")
        _ = try await StatementProposalGate.adopt(proposal, store: f.store, world: nil,
                                                  undoManager: chosen,
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
        XCTAssertTrue(StatementVerbUndo.manager(window: windowUndo) === windowUndo)

        var tasks: [Task<Void, Never>] = []
        let row = try XCTUnwrap(RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).first)
        await RulingsStratum.revoke(row, at: 0, kind: .intent, forScope: scope, store: f.store,
                                    world: nil, undoManager: windowUndo,
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
        _ = try await StatementProposalGate.adopt(proposal, store: f.store, world: nil,
                                                  undoManager: windowUndo,
                                                  workTaskSink: { tasks.append($0) })
        await waitOut(0.1)
        XCTAssertEqual(windowUndo.undoActionName, StatementProposalCopy.undoActionName)
        windowUndo.undo()
        for task in tasks { await task.value }
        XCTAssertEqual(try f.store.statementText(of: vl), "Old look.", "⌘Z from the window undid the Adopt")
    }

    // MARK: - Where the keys are, not who holds the statement (fix 4, R1)

    /// Brief's piece view in small: Going-for's editor holds the intent open
    /// while the writer types in the chapter, then presses Revoke in Decided
    /// (a button takes no focus). The Revoke is the WINDOW's — where ⌘Z from
    /// the manuscript walks — so that ⌘Z undoes the Revoke; on Going-for's
    /// stack, where the round before put it, that ⌘Z skipped it.
    func test_withTheKeysInTheManuscriptARevokeIsUndoneFromTheManuscript() async throws {
        let f = try await fixture("VerbUndoKeysElsewhere")
        let docId = f.documentItemId
        let scope = Statement.Scope.document(docId)
        let statement = try await f.store.createStatement(kind: .intent, scope: scope)
        try await f.store.mutateStatementText(of: statement, session: "verb-undo") { _ in
            RulingsSection.render(essay: "Chapter one turns on a lie.", rulings: [self.ruling("no flashbacks")])
        }
        let window = f.hostView(AnyView(ChapterBesideGoingFor(
            store: f.store, documentStore: f.documentStore, docId: docId)), width: 900)
        await pumpUntil(deadline: 5) {
            f.store.openStatementDocument(id: statement.id) != nil
                && f.allTextViews(in: window).contains { CentreKeys.isManuscriptEditor($0) }
                && f.allTextViews(in: window).contains { !CentreKeys.isManuscriptEditor($0) }
        }
        let manuscript = try XCTUnwrap(f.allTextViews(in: window).first { CentreKeys.isManuscriptEditor($0) })
        let goingFor = try XCTUnwrap(f.allTextViews(in: window).first { !CentreKeys.isManuscriptEditor($0) })
        let statementUndo = try XCTUnwrap(goingFor.undoManager)
        let windowUndo = try XCTUnwrap(window.undoManager)
        XCTAssertFalse(statementUndo === windowUndo, "premise: Going-for's editor has its own manager")
        XCTAssertTrue(f.store.statementUndoManager(forId: statement.id) === statementUndo,
                      "premise: Going-for's editor holds the statement open")

        ownGroups(windowUndo)

        // The writer types in the chapter.
        window.makeFirstResponder(manuscript)
        manuscript.setSelectedRange(NSRange(location: (manuscript.string as NSString).length, length: 0))
        await act(on: windowUndo) {
            manuscript.insertText(" Typed.", replacementRange: manuscript.selectedRange())
            await waitOut(0.2)
        }
        let typed = manuscript.string
        XCTAssertTrue(typed.hasSuffix(" Typed."), "premise: the typing landed")
        XCTAssertTrue(windowUndo.canUndo, "premise: the chapter's typing is on the window's stack")

        // Revoke, from Decided: the keys are still the manuscript's.
        XCTAssertTrue(window.firstResponder === manuscript, "premise: the keys are in the manuscript")
        let chosen = StatementVerbUndo.manager(window: windowUndo)
        XCTAssertTrue(chosen === windowUndo,
                      "the verb goes where the keys' ⌘Z walks, not onto the holding editor's stack")
        var tasks: [Task<Void, Never>] = []
        let row = try XCTUnwrap(RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).first)
        await act(on: windowUndo) {
            await RulingsStratum.revoke(row, at: 0, kind: .intent, forScope: scope, store: f.store,
                                        world: nil, undoManager: chosen, workTaskSink: { tasks.append($0) })
            await waitOut(0.3)
        }
        XCTAssertEqual(rulings(f, scope), [], "premise: revoked")
        XCTAssertEqual(windowUndo.undoActionName, "Revoke Ruling")
        XCTAssertFalse(statementUndo.canUndo, "nothing of it on Going-for's stack")

        // ⌘Z, the keys in the manuscript: the walk reaches the window.
        XCTAssertFalse(manuscript.responds(to: undo), "premise: the manuscript's ⌘Z is the window's")
        XCTAssertTrue(manuscript.tryToPerform(undo, with: nil))
        XCTAssertEqual(tasks.count, 1, "the manuscript's ⌘Z ran the Revoke's undo")
        for task in tasks { await task.value }
        await waitOut(0.2)
        XCTAssertEqual(rulings(f, scope), ["no flashbacks"], "⌘Z from the manuscript undid the Revoke")
        XCTAssertEqual(manuscript.string, typed, "and not the chapter's older typing")
        XCTAssertTrue(manuscript.tryToPerform(undo, with: nil))
        await waitOut(0.2)
        XCTAssertFalse(manuscript.string.hasSuffix(" Typed."), "which the next ⌘Z undoes")
    }

    // MARK: - One write's setting is that write's alone (fix 4, R2)

    /// A verb in the statement's editor, then ⌘Z ⇧⌘Z without waiting: the
    /// undo and the redo each run in their own task and suspend mid-write, so
    /// the two overlap. Afterwards a live write that is nobody's verb (a
    /// promotion's append) replaces the editor's buffer, and the editor
    /// drops its typing undo (ADR 0023 D1, unconditional): nothing an undo
    /// asked for reaches a later write.
    func test_afterAnOverlappingUndoAndRedoALaterWriteStillDropsTheTypingUndo() async throws {
        let f = try await fixture("VerbUndoOverlap")
        let scope = Statement.Scope.document(f.documentItemId)
        let statement = try await f.store.createStatement(kind: .intent, scope: scope)
        try await f.store.mutateStatementText(of: statement, session: "verb-undo") { _ in
            RulingsSection.render(essay: "Chapter one.", rulings: [self.ruling("first"), self.ruling("second")])
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

        var tasks: [Task<Void, Never>] = []
        let chosen = StatementVerbUndo.manager(window: window.undoManager)
        XCTAssertTrue(chosen === statementUndo, "premise: the keys are the statement's editor's")
        let row = try XCTUnwrap(RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).first)
        await RulingsStratum.revoke(row, at: 0, kind: .intent, forScope: scope, store: f.store,
                                    world: nil, undoManager: chosen, workTaskSink: { tasks.append($0) })
        await waitOut(0.3)
        XCTAssertEqual(rulings(f, scope), ["second"], "premise: revoked")

        // ⌘Z ⇧⌘Z, back to back: two tasks, neither awaited before the other starts.
        XCTAssertTrue(editor.tryToPerform(undo, with: nil))
        XCTAssertTrue(editor.tryToPerform(redo, with: nil))
        XCTAssertEqual(tasks.count, 2, "premise: an undo and a redo in flight at once")
        for task in tasks { await task.value }
        await waitOut(0.3)

        try await typeThenWriteFromElsewhere(into: editor, statement, f)
        XCTAssertFalse(statementUndo.canUndo,
                       "a later write kept the editor's typing undo across a buffer replace: "
                       + "some verb's undo-coherence outlived its own write")
    }

    /// Two verbs with the keys outside the statement's editor (which holds
    /// it open), so both are the window's; then ⌘Z ⌘Z without waiting — two
    /// undo tasks overlapping on one statement. Both are undone, and a later
    /// live write still drops the editor's typing undo.
    func test_afterTwoQuickUndosOfTwoVerbsALaterWriteStillDropsTheTypingUndo() async throws {
        let f = try await fixture("VerbUndoTwoQuick")
        let scope = Statement.Scope.document(f.documentItemId)
        let statement = try await f.store.createStatement(kind: .intent, scope: scope)
        try await f.store.mutateStatementText(of: statement, session: "verb-undo") { _ in
            RulingsSection.render(essay: "Chapter one.", rulings: [self.ruling("first"), self.ruling("second")])
        }
        let window = f.hostView(AnyView(StatementEditorHost(
            store: f.store, documentStore: f.documentStore, kind: .intent, scope: scope, posture: .author)),
                                width: 400)
        await pumpUntil(deadline: 5) {
            f.store.openStatementDocument(id: statement.id) != nil && f.firstTextView(in: window) != nil
        }
        let editor = try f.textView(in: window)
        let statementUndo = try XCTUnwrap(editor.undoManager)
        let windowUndo = try XCTUnwrap(window.undoManager)
        window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder === editor, "premise: the keys are not the statement editor's")

        ownGroups(windowUndo)
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<2 {
            let chosen = StatementVerbUndo.manager(window: windowUndo)
            XCTAssertTrue(chosen === windowUndo, "the keys are elsewhere: the window's")
            let row = try XCTUnwrap(RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).first)
            await act(on: windowUndo) {   // each press is its own step
                await RulingsStratum.revoke(row, at: 0, kind: .intent, forScope: scope, store: f.store,
                                            world: nil, undoManager: chosen, workTaskSink: { tasks.append($0) })
                await waitOut(0.2)
            }
        }
        XCTAssertEqual(rulings(f, scope), [], "premise: both revoked")

        // ⌘Z ⌘Z, back to back.
        windowUndo.undo()
        windowUndo.undo()
        XCTAssertEqual(tasks.count, 2, "premise: two undos in flight at once")
        for task in tasks { await task.value }
        await waitOut(0.3)
        XCTAssertEqual(Set(rulings(f, scope)), ["first", "second"], "both Revokes were undone")

        window.makeFirstResponder(editor)
        try await typeThenWriteFromElsewhere(into: editor, statement, f)
        XCTAssertFalse(statementUndo.canUndo,
                       "a later write kept the editor's typing undo across a buffer replace")
    }

    /// The writer types in the statement's editor (premise: it is on that
    /// editor's stack), then a write that is no verb's arrives through the
    /// live arm and the editor's buffer is replaced.
    private func typeThenWriteFromElsewhere(into editor: MaughamTextView, _ statement: Statement,
                                            _ f: StatementMountFixture) async throws {
        let manager = try XCTUnwrap(editor.undoManager)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("Typed. ", replacementRange: editor.selectedRange())
        await waitOut(0.2)
        XCTAssertTrue(manager.canUndo, "premise: the statement's typing is on its editor's stack")
        try await f.store.appendToStatement("A promoted line.", to: statement, session: "later")
        await pumpUntil(deadline: 3) { editor.string.contains("A promoted line.") }
        await waitOut(0.2)
        XCTAssertTrue(editor.string.contains("A promoted line."), "premise: the editor's buffer was replaced")
    }

    /// The store's half, with no editor to consume anything: each write's
    /// `StatementWriteUndo` decides that write and no other.
    func test_aWritesUndoSettingDecidesThatWriteAndNoOther() async throws {
        let f = try await fixture("VerbUndoPerWrite")
        let scope = Statement.Scope.document(f.documentItemId)
        let statement = try await f.store.createStatement(kind: .intent, scope: scope)
        let document = try await Document.load(
            url: f.store.resolvedProjectPath(statement.path), actor: .author,
            session: "pane", presenter: nil)
        let holder = UndoManager()
        holder.groupsByEvent = false
        f.store.noteStatementDocumentOpened(document, id: statement.id, undoManager: holder)
        let target = NSObject()
        func registerTyping() {
            holder.beginUndoGrouping()
            holder.registerUndo(withTarget: target) { _ in }
            holder.endUndoGrouping()
        }
        func write(_ text: String, _ undo: StatementWriteUndo) async throws {
            try await f.store.mutateStatementText(of: statement, session: "w", undo: undo) { _ in text }
        }

        // The forward verb on the holder's own manager: typing dropped, the apply flagged.
        registerTyping()
        try await write("one", .verb(on: holder))
        XCTAssertFalse(holder.canUndo, "the forward verb drops the typing first (D1)")
        XCTAssertTrue(document._undoCoherentApplyPending, "and flags its apply (D2)")

        // The NEXT write is plain: it inherits nothing, and withdraws the unconsumed flag.
        try await write("two", .plain)
        XCTAssertFalse(document._undoCoherentApplyPending,
                       "a plain write went out under an earlier write's undo-coherence")

        // A verb's undo or redo: flagged, nothing cleared.
        registerTyping()
        try await write("three", .replay(on: holder))
        XCTAssertTrue(holder.canUndo, "an undo's write keeps the stack")
        XCTAssertTrue(document.consumeUndoCoherentApplyFlag())

        // Registered on any other manager (the window's): the plain write.
        try await write("four", .verb(on: UndoManager()))
        XCTAssertTrue(holder.canUndo, "the holder's stack is the editor's to drop on the replace")
        XCTAssertFalse(document._undoCoherentApplyPending)

        // A write that changes nothing clears nothing and flags nothing.
        try await write("four", .verb(on: holder))
        XCTAssertTrue(holder.canUndo)
        XCTAssertFalse(document._undoCoherentApplyPending)

        f.store.forgetStatementDocument(id: statement.id)
        await document.close()
    }

    /// **No undo-coherence is stored anywhere** (R2's construction): a
    /// `StatementWriteUndo` is built in the argument that passes it into a
    /// write, or received as a parameter and passed on. A held one — a
    /// property, a collection, a local, annotated or not — could outlive its
    /// write; this census fails on any `let` or `var` that names the type.
    /// The control is a planted offender of each shape.
    func test_noUndoCoherenceIsStored() throws {
        var offenders: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            offenders += Self.heldWriteUndo(in: try SourceTree.read(file)).map { "\(file): \($0)" }
        }
        XCTAssertEqual(offenders, [], "a StatementWriteUndo held past the call it was made for")

        let statements = try SourceTree.read("Maugham/Stores/ProjectStore+Statements.swift")
        let live = try SourceTree.declaration(named: "func mutateLive(", under: "Maugham")
        XCTAssertTrue(live.contains("undo: StatementWriteUndo"), "the live write takes its own setting")
        XCTAssertEqual(statements.components(separatedBy: "mutateLive(live, id: statement.id, undo: undo, mutate)").count - 1,
                       2, "both live arms pass the caller's own setting on")
        XCTAssertEqual(statements.components(separatedBy: "mutateLive(").count - 1, 3,
                       "and nothing else reaches the live write")

        let planted = """
            @ObservationIgnored internal var coherence: [String: StatementWriteUndo] = [:]
            let held: StatementWriteUndo
            let pending = [String: StatementWriteUndo]()
            private let kept = StatementWriteUndo.plain
            let forward = StatementWriteUndo.verb(on: undoManager)
            func write(undo: StatementWriteUndo = .plain) {}
            try await store.mutateStatementText(of: s, session: x, undo: .replay(on: undoManager)) { _ in t }
        """
        XCTAssertEqual(Self.heldWriteUndo(in: planted).count, 5,
                       "the census sees every held shape, and lets a parameter and an argument built in place be")
    }

    /// Lines that HOLD a `StatementWriteUndo`: any `let` or `var` naming the
    /// type, with or without an annotation. The two exemptions are the type's
    /// own declaration line and its computed `plain`.
    private static func heldWriteUndo(in text: String) -> [String] {
        SourceScan.codeLines(of: text).filter { line in
            guard line.contains("StatementWriteUndo"),
                  !line.contains("struct StatementWriteUndo"),
                  !line.contains("static var plain: StatementWriteUndo {") else { return false }
            return line.range(of: #"\b(let|var)\b"#, options: .regularExpression) != nil
        }
    }

    // MARK: - The first responder's own manager, whichever it is (fix 5, N1)

    /// The pure half: `undo:` goes up the responder chain, and the first
    /// second editor on it answers on its own manager; else the window's.
    func test_theVerbsManagerIsTheOneUndoRunsFromTheFirstResponder() {
        let windowUndo = UndoManager()
        func chosen(_ responder: NSResponder?) -> UndoManager? {
            StatementVerbUndo.manager(firstResponder: responder, window: windowUndo)
        }
        XCTAssertTrue(chosen(nil) === windowUndo)
        XCTAssertTrue(chosen(NSOutlineView()) === windowUndo, "the tree")
        XCTAssertTrue(chosen(NSTextView()) === windowUndo, "a field editor, an inline rename: the walk reaches the window")
        let manuscript = MaughamTextView()
        XCTAssertTrue(chosen(manuscript) === windowUndo, "the manuscript, or a note in the centre")
        let second = MaughamTextView()
        second.usesPrivateUndoManager = true
        XCTAssertTrue(chosen(second) === second.privateUndoManager, "a second editor answers ⌘Z itself")
        let inside = NSTextField()
        second.addSubview(inside)
        XCTAssertTrue(chosen(inside) === second.privateUndoManager, "a view inside one: the walk stops at that editor")
        // No environment manager (Task 5 M1): the key window's chain decides,
        // as for any press — never nil while a statement editor has the keys.
        let key = NSApp.keyWindow
        XCTAssertTrue(StatementVerbUndo.manager(window: nil)
                      === StatementVerbUndo.manager(firstResponder: key?.firstResponder,
                                                    window: key?.undoManager))
    }

    /// The keys are in statement Y's editor (the book's visual language);
    /// Revoke is pressed on statement X (the chapter's intent), which its own
    /// editor holds. Y's editor answers ⌘Z from its own stack, so the Revoke
    /// is registered THERE and ⌘Z from Y undoes it. The write to X is plain
    /// (the manager is not X's holder): X's editor drops its stack.
    func test_withTheKeysInAnotherStatementsEditorItsUndoUndoesTheRevoke() async throws {
        let f = try await fixture("VerbUndoOtherStatement")
        let scope = Statement.Scope.document(f.documentItemId)
        let x = try await f.store.createStatement(kind: .intent, scope: scope)
        try await f.store.mutateStatementText(of: x, session: "verb-undo") { _ in
            RulingsSection.render(essay: "Chapter one.", rulings: [self.ruling("no flashbacks")])
        }
        let y = try await f.store.createStatement(kind: .visualLanguage, scope: .project)
        try await f.store.mutateStatementText(of: y, session: "verb-undo") { _ in "Serif." }
        let window = f.hostView(AnyView(HStack(spacing: 0) {
            StatementEditorHost(store: f.store, documentStore: f.documentStore, kind: .intent,
                                scope: scope, posture: .author).frame(width: 320)
            StatementEditorHost(store: f.store, documentStore: f.documentStore, kind: .visualLanguage,
                                scope: .project, posture: .author).frame(width: 320)
        }), width: 640)
        await pumpUntil(deadline: 5) {
            f.store.statementUndoManager(forId: x.id) != nil && f.store.statementUndoManager(forId: y.id) != nil
                && f.allTextViews(in: window).count == 2
        }
        let xUndo = try XCTUnwrap(f.store.statementUndoManager(forId: x.id))
        let yUndo = try XCTUnwrap(f.store.statementUndoManager(forId: y.id))
        let yEditor = try XCTUnwrap(f.allTextViews(in: window).first { $0.undoManager === yUndo })
        window.makeFirstResponder(yEditor)
        XCTAssertTrue(window.firstResponder === yEditor, "premise: the keys are in the other statement's editor")
        ownGroups(yUndo)

        // The writer types in Y first (Task 5 M2): that typing must survive
        // the verb on X and its undo.
        yEditor.setSelectedRange(NSRange(location: 0, length: 0))
        await act(on: yUndo) {
            yEditor.insertText("Bold ", replacementRange: yEditor.selectedRange())
            await waitOut(0.2)
        }
        XCTAssertEqual(yEditor.string, "Bold Serif.", "premise: Y's typing landed")
        XCTAssertEqual(yUndo.undoActionName, "Typing", "premise: on Y's own stack")

        let chosen = StatementVerbUndo.manager(window: window.undoManager)
        XCTAssertTrue(chosen === yUndo, "the verb goes on the stack ⌘Z runs from the keys: the other editor's")
        var tasks: [Task<Void, Never>] = []
        let row = try XCTUnwrap(RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).first)
        await act(on: yUndo) {
            await RulingsStratum.revoke(row, at: 0, kind: .intent, forScope: scope, store: f.store,
                                        world: nil, undoManager: chosen, workTaskSink: { tasks.append($0) })
            await waitOut(0.3)
        }
        XCTAssertEqual(rulings(f, scope), [], "premise: revoked")
        XCTAssertEqual(yUndo.undoActionName, "Revoke Ruling")
        XCTAssertFalse(xUndo.canUndo, "a plain write: the pressed statement's own editor keeps nothing")
        XCTAssertFalse(window.undoManager?.canUndo ?? false, "and nothing went to the window, where this ⌘Z never walks")

        XCTAssertTrue(yEditor.tryToPerform(undo, with: nil), "⌘Z, the keys still in the other editor")
        for task in tasks { await task.value }
        await waitOut(0.2)
        XCTAssertEqual(rulings(f, scope), ["no flashbacks"], "⌘Z from the other statement's editor undid the Revoke")
        XCTAssertEqual(yEditor.string, "Bold Serif.", "and that editor's own text was never touched")

        // M2: Y's own typing, below the verb, still undoes — and range-valid.
        XCTAssertEqual(yUndo.undoActionName, "Typing", "Y's typing survived the verb on X and its undo")
        XCTAssertTrue(yEditor.tryToPerform(undo, with: nil), "⌘Z again in Y")
        await waitOut(0.2)
        XCTAssertEqual(yEditor.string, "Serif.", "the next ⌘Z undid Y's own typing, exactly")
    }

    /// The same with a research note pulled up beside the manuscript (a
    /// second editor with its own stack) holding the keys, and no editor
    /// holding the statement.
    func test_withTheKeysInAPulledUpNotesEditorItsUndoUndoesTheRevoke() async throws {
        let f = try await fixture("VerbUndoNote")
        let scope = Statement.Scope.document(f.documentItemId)
        let statement = try await f.store.createStatement(kind: .intent, scope: scope)
        try await f.store.mutateStatementText(of: statement, session: "verb-undo") { _ in
            RulingsSection.render(essay: "Chapter one.", rulings: [self.ruling("no flashbacks")])
        }
        let note = try await f.store.createResearchNote(scope: .shared, title: "Notes")
        let notePath = try XCTUnwrap(f.store.findResearchItem(id: note.id, in: f.store.manifest.research)?.path)
        let window = f.hostView(AnyView(ResearchNoteEditor(
            store: f.store, documentStore: f.documentStore, path: notePath, itemId: note.id,
            previewVisible: false, lockEditing: false, isSecondEditor: true)), width: 500)
        await pumpUntil(deadline: 5) { f.firstTextView(in: window) != nil }
        let noteEditor = try f.textView(in: window)
        window.makeFirstResponder(noteEditor)
        let noteUndo = try XCTUnwrap(noteEditor.undoManager)
        XCTAssertFalse(noteUndo === window.undoManager, "premise: the pulled-up note keeps its own stack")

        let chosen = StatementVerbUndo.manager(window: window.undoManager)
        XCTAssertTrue(chosen === noteUndo, "the verb goes on the stack ⌘Z runs from the keys: the note editor's")
        var tasks: [Task<Void, Never>] = []
        let row = try XCTUnwrap(RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).first)
        await RulingsStratum.revoke(row, at: 0, kind: .intent, forScope: scope, store: f.store,
                                    world: nil, undoManager: chosen, workTaskSink: { tasks.append($0) })
        await waitOut(0.2)
        XCTAssertEqual(rulings(f, scope), [], "premise: revoked")
        XCTAssertTrue(noteEditor.tryToPerform(undo, with: nil))
        for task in tasks { await task.value }
        await waitOut(0.2)
        XCTAssertEqual(rulings(f, scope), ["no flashbacks"], "⌘Z from the note's editor undid the Revoke")
    }

    /// **Edit ruling** (state 5e): the keys are in the row's inline field at
    /// the commit, with the statement's own editor mounted beside it. The
    /// field is outside every editor, so the edit is the window's; when the
    /// field closes the keys fall to the window itself (never back into the
    /// statement's editor), and ⌘Z from there undoes the edit.
    func test_anEditCommittedFromItsInlineFieldIsTheWindowsAndUndoneFromWhereTheKeysLand() async throws {
        let f = try await fixture("VerbUndoEditField")
        let scope = Statement.Scope.document(f.documentItemId)
        let statement = try await f.store.createStatement(kind: .intent, scope: scope)
        try await f.store.mutateStatementText(of: statement, session: "verb-undo") { _ in
            RulingsSection.render(essay: "Chapter one.", rulings: [self.ruling("no flashbacks")])
        }
        let probe = InlineFieldProbe()
        let window = f.hostView(AnyView(VStack(spacing: 0) {
            StatementEditorHost(store: f.store, documentStore: f.documentStore, kind: .intent,
                                scope: scope, posture: .author)
            InlineFieldStandIn(probe: probe).frame(height: 30)
        }), width: 400)
        await pumpUntil(deadline: 5) {
            f.store.openStatementDocument(id: statement.id) != nil && f.firstTextView(in: window) != nil
                && probe.field?.window != nil
        }
        let editor = try f.textView(in: window)
        let statementUndo = try XCTUnwrap(editor.undoManager)
        let windowUndo = try XCTUnwrap(window.undoManager)
        // The writer was in the statement's editor, then opened the row's field.
        window.makeFirstResponder(editor)
        let field = try XCTUnwrap(probe.field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSText, "premise: the keys are in the inline field")
        XCTAssertTrue(fieldEditor.isFieldEditor)

        // Return: the commit chooses its manager with the keys in the field.
        let chosen = StatementVerbUndo.manager(window: windowUndo)
        XCTAssertTrue(chosen === windowUndo, "an inline field is outside every editor: the window's")
        var tasks: [Task<Void, Never>] = []
        await RulingsStratum.edit(at: 0, to: "no dream sequences", kind: .intent, forScope: scope,
                                  store: f.store, world: nil, undoManager: chosen,
                                  workTaskSink: { tasks.append($0) })
        // The row closes its field.
        probe.isOpen = false
        await pumpUntil(deadline: 3) { probe.field?.window == nil }
        await waitOut(0.2)
        XCTAssertEqual(rulings(f, scope), ["no dream sequences"], "premise: edited")
        XCTAssertFalse(window.firstResponder === editor, "the keys do not land back in the statement's editor")
        XCTAssertTrue(StatementVerbUndo.manager(window: windowUndo) === windowUndo,
                      "where the keys landed, ⌘Z runs the window's manager")
        XCTAssertFalse(statementUndo.canUndo, "a plain write: the statement's editor dropped its stack")

        _ = window.firstResponder?.tryToPerform(undo, with: nil)
        for task in tasks { await task.value }
        await waitOut(0.2)
        XCTAssertEqual(rulings(f, scope), ["no flashbacks"], "⌘Z from where the keys landed undid the edit")
    }

    // MARK: - Two verbs in a row (fix 5, Q4)

    /// The keys are in the statement's own editor: typing, Revoke, Revoke.
    /// Each Revoke's write drops the editor's TYPING (D1: its ranges are
    /// stale) and nothing else, so ⌘Z ⌘Z undoes both Revokes, latest first,
    /// ⇧⌘Z ⇧⌘Z redoes both, and the typing done before the first is not
    /// brought back. Each act is its own step (`act`).
    func test_twoVerbsInTheStatementsEditorAreUndoneAndRedoneInOrder() async throws {
        let f = try await fixture("VerbUndoTwoVerbs")
        let scope = Statement.Scope.document(f.documentItemId)
        let statement = try await f.store.createStatement(kind: .intent, scope: scope)
        try await f.store.mutateStatementText(of: statement, session: "verb-undo") { _ in
            RulingsSection.render(essay: "Chapter one.", rulings: [self.ruling("first"), self.ruling("second")])
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

        ownGroups(statementUndo)

        // The writer types in the statement.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        await act(on: statementUndo) {
            editor.insertText("Typed. ", replacementRange: editor.selectedRange())
            await waitOut(0.2)
        }
        XCTAssertEqual(statementUndo.undoActionName, "Typing", "premise: the typing is on the editor's stack")
        let typedText = try f.store.statementText(of: statement)
        XCTAssertTrue(typedText.contains("Typed. "), "premise: the typing reached the statement")

        // Revoke, Revoke: each its own step.
        var tasks: [Task<Void, Never>] = []
        for expected in [["second"], []] {
            let chosen = StatementVerbUndo.manager(window: window.undoManager)
            XCTAssertTrue(chosen === statementUndo, "premise: the keys are the statement's editor's")
            let row = try XCTUnwrap(RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).first)
            await act(on: statementUndo) {
                await RulingsStratum.revoke(row, at: 0, kind: .intent, forScope: scope, store: f.store,
                                            world: nil, undoManager: chosen, workTaskSink: { tasks.append($0) })
                await waitOut(0.3)
            }
            XCTAssertEqual(rulings(f, scope), expected, "premise: revoked")
        }

        // ⌘Z: the second Revoke. ⌘Z: the first. Then nothing: the typing is gone.
        func press(_ selector: Selector) async {
            tasks.removeAll()
            XCTAssertTrue(editor.tryToPerform(selector, with: nil))
            for task in tasks { await task.value }
            await waitOut(0.3)
        }
        XCTAssertEqual(statementUndo.undoActionName, "Revoke Ruling")
        await press(undo)
        XCTAssertEqual(rulings(f, scope), ["second"], "the first ⌘Z undid the later Revoke")
        XCTAssertEqual(statementUndo.undoActionName, "Revoke Ruling",
                       "the earlier Revoke's undo survived the later Revoke")
        await press(undo)
        XCTAssertEqual(rulings(f, scope), ["first", "second"], "the second ⌘Z undid the earlier Revoke")
        // `canUndo` answers true over an empty stack once `groupsByEvent` is
        // off (measured), so what is left is read by name.
        XCTAssertEqual(statementUndo.undoActionName, "",
                       "the typing before the first verb is not resurrected (D1)")
        XCTAssertTrue(try f.store.statementText(of: statement).contains("Typed. "), "and what was typed stays typed")

        // ⇧⌘Z ⇧⌘Z: both again, in order.
        await press(redo)
        XCTAssertEqual(rulings(f, scope), ["second"], "the first ⇧⌘Z redid the earlier Revoke")
        await press(redo)
        XCTAssertEqual(rulings(f, scope), [], "the second ⇧⌘Z redid the later Revoke")
    }
}

/// Whether the stand-in inline field is drawn, and the field itself.
@Observable
@MainActor
final class InlineFieldProbe {
    var isOpen = true
    @ObservationIgnored weak var field: NSTextField?
    init() {}
}

/// A ruling row's inline field in small: a text field beside the statement's
/// editor and outside it, removed when the row closes it.
@MainActor
private struct InlineFieldStandIn: View {
    let probe: InlineFieldProbe
    struct Field: NSViewRepresentable {
        let probe: InlineFieldProbe
        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField(string: "no flashbacks")
            probe.field = field
            return field
        }
        func updateNSView(_ view: NSTextField, context: Context) {}
    }
    var body: some View {
        if probe.isOpen { Field(probe: probe) }
    }
}

/// The chapter in the centre beside Going-for's editor, as the window lays
/// Brief's piece view out: the manuscript's `EditorHost` and the intent's
/// `StatementEditorHost`, both mounted.
@MainActor
private struct ChapterBesideGoingFor: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let docId: String
    @State private var control = EditorControl()
    @State private var referenceIndex = ReferenceIndexHost()

    var body: some View {
        HStack(spacing: 0) {
            EditorHost(store: store, documentStore: documentStore,
                       selectedItemId: docId, control: control, referenceIndex: referenceIndex)
                .frame(width: 560)
            StatementEditorHost(store: store, documentStore: documentStore, kind: .intent,
                                scope: .document(docId), posture: .author)
                .frame(width: 320)
        }
    }
}

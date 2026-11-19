import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A statement's verbs are undone where ⌘Z looks** (shell plan 3 Task 5 fix
/// 3 and 4). The manager is chosen once, at the press, by where the keys are
/// (`StatementVerbUndo.manager`): with the statement's own editor holding
/// them, ⌘Z runs that editor's manager (`MaughamTextView.undo:`), so Adopt,
/// Revoke and Edit ruling register there — one ordered history of the
/// statement's typing and verbs — and each of the verb's writes says so
/// itself (`StatementWriteUndo`), so the editor's buffer replace keeps the
/// registration. With the keys anywhere else (the manuscript, the tree, no
/// editor at all), ⌘Z walks to the window, so they register on the window's
/// manager and write plainly. Mounted measurements; nothing is pressed (the
/// chooser and the verbs are the ones the panes' buttons call).
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
    private let redo = Selector(("redo:"))

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
        let chosen = StatementVerbUndo.manager(kind: .intent, scope: scope, store: f.store,
                                               window: window.undoManager)
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
        let chosen = StatementVerbUndo.manager(kind: .visualLanguage, scope: .project, store: f.store,
                                               window: window.undoManager)
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
        XCTAssertTrue(StatementVerbUndo.manager(kind: .intent, scope: scope, store: f.store,
                                                window: windowUndo) === windowUndo)

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

        // The writer types in the chapter.
        window.makeFirstResponder(manuscript)
        manuscript.setSelectedRange(NSRange(location: (manuscript.string as NSString).length, length: 0))
        manuscript.insertText(" Typed.", replacementRange: manuscript.selectedRange())
        await waitOut(0.2)
        let typed = manuscript.string
        XCTAssertTrue(typed.hasSuffix(" Typed."), "premise: the typing landed")
        XCTAssertTrue(windowUndo.canUndo, "premise: the chapter's typing is on the window's stack")

        // Revoke, from Decided: the keys are still the manuscript's.
        XCTAssertTrue(window.firstResponder === manuscript, "premise: the keys are in the manuscript")
        let chosen = StatementVerbUndo.manager(kind: .intent, scope: scope, store: f.store, window: windowUndo)
        XCTAssertTrue(chosen === windowUndo,
                      "the verb goes where the keys' ⌘Z walks, not onto the holding editor's stack")
        var tasks: [Task<Void, Never>] = []
        let row = try XCTUnwrap(RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).first)
        await RulingsStratum.revoke(row, at: 0, kind: .intent, forScope: scope, store: f.store,
                                    world: nil, undoManager: chosen, workTaskSink: { tasks.append($0) })
        await waitOut(0.3)
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
        // Not asserted: that the typing survives this ⌘Z. The app's event loop
        // closes the typing's undo group before the press, so there the Revoke
        // is its own step, above the typing. The test host draws no event
        // boundary (measured: the window manager's group stays open across
        // run-loop turns, and closing it by hand aborts), so here the two fold
        // into one group and one ⌘Z legitimately reverses both.
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
        let chosen = StatementVerbUndo.manager(kind: .intent, scope: scope, store: f.store,
                                               window: window.undoManager)
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

        var tasks: [Task<Void, Never>] = []
        for _ in 0..<2 {
            let chosen = StatementVerbUndo.manager(kind: .intent, scope: scope, store: f.store, window: windowUndo)
            XCTAssertTrue(chosen === windowUndo, "the keys are elsewhere: the window's")
            let row = try XCTUnwrap(RulingsStratum.currentRows(kind: .intent, forScope: scope, store: f.store).first)
            await RulingsStratum.revoke(row, at: 0, kind: .intent, forScope: scope, store: f.store,
                                        world: nil, undoManager: chosen, workTaskSink: { tasks.append($0) })
            await waitOut(0.2)
        }
        XCTAssertEqual(rulings(f, scope), [], "premise: both revoked")

        // ⌘Z ⌘Z, back to back. (The test host draws no event boundary between
        // the two presses, so both Revokes sit in one group and the first ⌘Z
        // already starts both undos; in the app it takes the two.)
        windowUndo.undo()
        if windowUndo.canUndo { windowUndo.undo() }
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
    /// `StatementWriteUndo` is built in the expression that passes it into a
    /// write, or received as a parameter and passed on. A stored one — a
    /// property, a dictionary, a `var` — could outlive its write; this
    /// census fails on it. The control is a planted offender.
    func test_noUndoCoherenceIsStored() throws {
        var offenders: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            offenders += Self.storedWriteUndo(in: try SourceTree.read(file)).map { "\(file): \($0)" }
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
            func write(undo: StatementWriteUndo = .plain) {}
            try await store.mutateStatementText(of: s, session: x, undo: .replay(on: undoManager)) { _ in t }
            let forward = StatementWriteUndo.verb(on: undoManager)
        """
        XCTAssertEqual(Self.storedWriteUndo(in: planted).count, 2,
                       "the census sees a stored property and a held value, and lets parameters and locals built in place be")
    }

    /// Lines that HOLD a `StatementWriteUndo`: a `var` of any shape, or a
    /// `let`/`var` declared with the type (a stored property, a collection).
    /// A parameter, or a local `let` initialised in place, is not one. The
    /// type's own declaration (its `weak var registeredOn`) is skipped.
    private static func storedWriteUndo(in text: String) -> [String] {
        SourceScan.codeLines(of: text).filter { line in
            guard line.contains("StatementWriteUndo"), !line.contains("struct StatementWriteUndo") else { return false }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"\bvar\b"#, options: .regularExpression) != nil { return true }
            return trimmed.range(of: #"\blet\s+\w+\s*:\s*[^=]*StatementWriteUndo"#, options: .regularExpression) != nil
        }
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

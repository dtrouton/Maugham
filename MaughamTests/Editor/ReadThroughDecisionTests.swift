import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **In read-through every decision passes** (shell read-through Task 2):
/// comment, query, suggest, accept, reject, stet, got it, reply, resolve a
/// to-do, the round's bulk verbs. Each family on a hand-pumped editor bound
/// to a real `Document` in read-through: the op lands, the text view shows
/// the result through the one `applyExternalText` site (one call per apply),
/// the window's undo manager undoes and redoes it with the view following
/// where the op has an undo, and typing is still refused afterwards. No
/// press and no wait on a clock (tripwire 33): the verbs are the handlers'
/// own calls, and an undo's async hop is awaited through its handle.
@MainActor
final class ReadThroughDecisionTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    private var opened: [RealDocumentHarness] = []

    override func tearDown() async throws {
        for rd in opened {
            rd.harness.window.undoManager?.removeAllActions()
            await rd.document.close()
        }
        opened = []
    }

    /// A real document in an editor, the piece in read-through as the window
    /// mirrors it.
    private func reading(_ text: String) async throws -> RealDocumentHarness {
        let rd = try await EditorIntegrationHarness.withRealDocument(mode: ProseMode(), initialText: text)
        opened.append(rd)
        let coordinator = rd.harness.coordinator
        coordinator.documentId = rd.document.docId
        let control = EditorControl()
        control.readThroughDocIds = [rd.document.docId]
        coordinator.observeControl(control)
        XCTAssertTrue(coordinator.isInReadThrough, "premise: in read-through")
        XCTAssertFalse(rd.harness.textView.isEditable)
        return rd
    }

    /// The window's undo manager — the one ⌘Z reaches and every decision is
    /// handed (`EditorHost`'s `um`).
    private func undo(_ rd: RealDocumentHarness) throws -> UndoManager {
        let um = try XCTUnwrap(rd.harness.textView.undoManager)
        XCTAssertTrue(um === rd.harness.window.undoManager, "no throwaway in read-through")
        XCTAssertNil(ReadingUndoGuard.standing(over: rd.harness.window), "and no guard barring ⌘Z")
        return um
    }

    /// One update pass, as `EditorSurface.updateNSView` makes it.
    private func pass(_ rd: RealDocumentHarness) {
        EditorSurface.reconcileTextBuffer(
            textView: rd.harness.textView, coordinator: rd.harness.coordinator,
            translationLanguage: nil, text: rd.document.displayText,
            undoCoherentApply: rd.document.consumeUndoCoherentApplyFlag())
    }

    private func firstParagraph(_ rd: RealDocumentHarness) throws -> String {
        try XCTUnwrap(rd.document.paragraphId(at: 0))
    }

    private func status(_ rd: RealDocumentHarness, _ id: String) -> AnnotationStatus? {
        rd.document.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }?.status
    }

    private func assertTypingRefused(_ rd: RealDocumentHarness,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = rd.harness.textView.string
        rd.harness.textView.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        rd.harness.typeCharacter("Z")
        try await rd.document.flushBurstNow()
        XCTAssertEqual(rd.harness.textView.string, before, "typing is still refused", file: file, line: line)
        XCTAssertEqual(rd.document.displayText, before, file: file, line: line)
    }

    private func suggestion(_ rd: RealDocumentHarness, pid: String) async throws -> String {
        try await rd.document.addAnnotation(
            kind: .suggestedChange, paragraphId: pid, body: "stronger", suggestedText: "pitch-black",
            span: SpanAnchor(quote: "very dark", prefix: "was ", suffix: " and", posHint: 14))
    }

    private let night = "The night was very dark and stormy."

    // MARK: - 1. Comment, Query, Suggest

    /// The selection toolbar offers every kind (the review render is on), and
    /// the create handler appends; the text is unchanged.
    func test_commentQueryAndSuggestAreOfferedAndAppend() async throws {
        let rd = try await reading(night)
        let coordinator = rd.harness.coordinator
        XCTAssertTrue(coordinator.isReviewMode, "the review render: the selection toolbar shows")
        XCTAssertEqual(SelectionToolbarView.kinds(isReadingTranslation: coordinator.isReadingTranslation),
                       SelectionToolbarView.Kind.allCases)
        let pid = try firstParagraph(rd)
        let calls = coordinator.applyExternalTextCallCount
        for kind in [AnnotationKind.comment, .query, .suggestedChange] {
            _ = try await rd.document.addReviewerAnnotation(
                kind: kind, paragraphId: pid,
                span: SpanAnchor(quote: "dark", prefix: "very ", suffix: " and", posHint: 19),
                body: "note", suggestedText: kind == .suggestedChange ? "black" : nil, authorName: "Me")
        }
        pass(rd)
        XCTAssertEqual(rd.document.annotations(filter: AnnotationFilter(statuses: [.open])).count, 3)
        XCTAssertEqual(rd.harness.textView.string, night, "a note changes no text")
        XCTAssertEqual(coordinator.applyExternalTextCallCount, calls)
        try await assertTypingRefused(rd)
    }

    // MARK: - 2. Accept

    /// **Accept, ⌘Z, ⇧⌘Z** — the text view shows each state, one apply each.
    func test_acceptChangesTheText_andUndoAndRedoFollow() async throws {
        let rd = try await reading(night)
        let coordinator = rd.harness.coordinator
        let um = try undo(rd)
        let id = try await suggestion(rd, pid: try firstParagraph(rd))
        let calls = coordinator.applyExternalTextCallCount
        try await rd.document.acceptAnnotation(id: id, undoManager: um, mayWrite: { true })
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, "The night was pitch-black and stormy.")
        XCTAssertEqual(coordinator.applyExternalTextCallCount, calls + 1)
        XCTAssertTrue(um.canUndo, "the accept is undoable in read-through")

        um.undo()
        await rd.document.awaitPendingUndoWork()
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, night, "⌘Z: the text returns")
        XCTAssertEqual(status(rd, id), .open)
        XCTAssertEqual(coordinator.applyExternalTextCallCount, calls + 2)

        um.redo()
        await rd.document.awaitPendingUndoWork()
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, "The night was pitch-black and stormy.", "⇧⌘Z")
        XCTAssertEqual(status(rd, id), .accepted)
        XCTAssertEqual(coordinator.applyExternalTextCallCount, calls + 3)
        XCTAssertTrue(coordinator.isInReadThrough)
        try await assertTypingRefused(rd)
    }

    // MARK: - 3. Reject, Stet, Got it, Reply

    func test_rejectStetGotItAndReplyLand_andAreUndoable() async throws {
        let rd = try await reading(night)
        let um = try undo(rd)
        let pid = try firstParagraph(rd)
        let calls = rd.harness.coordinator.applyExternalTextCallCount
        func comment() async throws -> String {
            try await rd.document.addAnnotation(kind: .comment, paragraphId: pid, body: "hm", suggestedText: nil)
        }
        let rejected = try await suggestion(rd, pid: pid)
        try await rd.document.rejectAnnotation(id: rejected, undoManager: um)
        XCTAssertEqual(status(rd, rejected), .rejected)
        XCTAssertTrue(um.canUndo)
        um.undo()
        await rd.document.awaitPendingUndoWork()
        XCTAssertEqual(status(rd, rejected), .open, "⌘Z reopens the rejected note")

        let stetted = try await comment()
        try await rd.document.stetAnnotation(id: stetted, undoManager: um)
        XCTAssertNotEqual(status(rd, stetted), .open)
        XCTAssertTrue(um.canUndo)
        um.undo()
        await rd.document.awaitPendingUndoWork()
        XCTAssertEqual(status(rd, stetted), .open, "⌘Z takes the stet back")

        let gotIt = try await comment()
        try await rd.document.acceptAnnotation(id: gotIt, undoManager: um, mayWrite: { true })
        XCTAssertEqual(status(rd, gotIt), .accepted)
        XCTAssertTrue(um.canUndo)

        let replied = try await comment()
        try await rd.document.acceptAnnotation(id: replied, userResponse: "Yes — fixed later.",
                                               undoManager: um, mayWrite: { true })
        XCTAssertEqual(rd.document.annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == replied }?.userResponse, "Yes — fixed later.")
        XCTAssertTrue(um.canUndo)

        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, night, "no answer here changes the text")
        XCTAssertEqual(rd.harness.coordinator.applyExternalTextCallCount, calls)
        try await assertTypingRefused(rd)
    }

    // MARK: - 4. Resolve a to-do

    /// A checkbox flip (`checkboxToggleHandler`'s path) and a Tasks-pane
    /// archive change the text, and ⌘Z takes each back, the view following.
    func test_aCheckboxFlipAndATaskArchiveLand_andAreUndoable() async throws {
        let rd = try await reading("- [ ] buy milk")
        let coordinator = rd.harness.coordinator
        XCTAssertTrue(coordinator.allowsCheckboxToggle, "resolving a to-do is a decision")
        let um = try undo(rd)
        let pid = try firstParagraph(rd)
        let calls = coordinator.applyExternalTextCallCount
        InlineToggleUndo.perform(on: rd.document, paragraphId: pid, prior: "- [ ] buy milk",
                                 flipped: "- [x] buy milk", undoManager: um, mayWrite: { true })
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, "- [x] buy milk")
        XCTAssertEqual(coordinator.applyExternalTextCallCount, calls + 1)
        um.undo()
        await rd.document.awaitPendingUndoWork()
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, "- [ ] buy milk", "⌘Z flips it back")
        XCTAssertEqual(coordinator.applyExternalTextCallCount, calls + 2)

        let task = try XCTUnwrap(rd.document.tasks(filter: TaskFilter(
            scope: .document(docId: rd.document.docId), statuses: [.open])).first)
        rd.document.archiveTask(id: task.id, undoManager: um)
        pass(rd)
        XCTAssertEqual(rd.document.tasks(filter: TaskFilter(
            scope: .document(docId: rd.document.docId), statuses: [.archived])).count, 1)
        XCTAssertEqual(rd.harness.textView.string, rd.document.displayText, "the view follows the archive")
        XCTAssertTrue(um.canUndo)
        um.undo()
        await rd.document.awaitPendingUndoWork()
        pass(rd)
        XCTAssertEqual(rd.document.tasks(filter: TaskFilter(
            scope: .document(docId: rd.document.docId), statuses: [.open])).count, 1, "⌘Z restores it")
        XCTAssertEqual(rd.harness.textView.string, rd.document.displayText)
        try await assertTypingRefused(rd)
    }

    // MARK: - 5. The round's verbs

    /// A bulk accept through `AnnotationBulkActions` and a triage mark land,
    /// and ⌘Z reaches them.
    func test_aBulkAcceptAndATriageLand() async throws {
        let rd = try await reading(night)
        let um = try undo(rd)
        let pid = try firstParagraph(rd)
        let id = try await suggestion(rd, pid: pid)
        let calls = rd.harness.coordinator.applyExternalTextCallCount
        let outcome = await AnnotationBulkActions.perform(.accept, on: [id], in: rd.document,
                                                          undoManager: um, mayWrite: { true })
        XCTAssertEqual(outcome.succeeded, [id])
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, "The night was pitch-black and stormy.")
        XCTAssertEqual(rd.harness.coordinator.applyExternalTextCallCount, calls + 1)
        um.undo()
        await rd.document.awaitPendingUndoWork()
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, night, "⌘Z takes the bulk accept back")

        let note = try await rd.document.addAnnotation(kind: .comment, paragraphId: pid, body: "?",
                                                       suggestedText: nil)
        let triaged = await AnnotationBulkActions.perform(.triage(.discuss), on: [note], in: rd.document,
                                                          undoManager: um)
        XCTAssertEqual(triaged.succeeded, [note])
        XCTAssertEqual(rd.document.annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == note }?.triage, .discuss)
        XCTAssertTrue(um.canUndo)
        try await assertTypingRefused(rd)
    }

    // MARK: - 6. A Translator's note

    /// **Read-through and reading a translation do not combine**: a piece in
    /// read-through, read in a language, offers only the Translator's note,
    /// and the line over it is the translation's (Task 8's), not read-through's.
    func test_overATranslationTheToolbarOffersOnlyTheTranslatorsNote() async throws {
        let rd = try await reading(night)
        let coordinator = rd.harness.coordinator
        EditorSurface.reconcileTextBuffer(textView: rd.harness.textView, coordinator: coordinator,
                                          translationLanguage: "sr", text: "Noć je bila mračna.",
                                          undoCoherentApply: false)
        XCTAssertEqual(SelectionToolbarView.kinds(isReadingTranslation: coordinator.isReadingTranslation),
                       [.translatorsNote])
        let host = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/EditorHost.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(host.contains("if let language = control.translationLanguage {"),
                      "the translation's line is drawn on the language")
    }
}

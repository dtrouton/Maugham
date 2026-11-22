import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **In read-through every decision passes** (shell read-through Task 2):
/// comment, query, suggest, accept, reject, stet, got it, reply, resolve a
/// to-do, the round's verbs. Each family on a hand-pumped editor bound to a
/// real `Document` in read-through, with the window's real posture door
/// behind the handlers (`EditorHost.acceptFromCard`, `toggleCheckbox`,
/// `mayWriteText`): the op lands, the text view shows the result through the
/// one `applyExternalText` site (one call per apply), ⌘Z and ⇧⌘Z — delivered
/// as the menu delivers them, to the first responder answering `undo:` /
/// `redo:`, validated there — undo and redo it with the view following, and
/// typing is still refused afterwards. No press and no wait on a clock
/// (tripwire 33): a card's work and an undo's hop are awaited through their
/// handles.
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

    /// A real document in an editor wired as `EditorHost` wires the review
    /// render, the piece in read-through as the window mirrors it.
    private func reading(_ text: String) async throws -> RealDocumentHarness {
        let rd = try await EditorIntegrationHarness.withRealDocument(mode: ProseMode(), initialText: text)
        opened.append(rd)
        let doc = rd.document
        let coordinator = rd.harness.coordinator
        coordinator.documentId = doc.docId
        coordinator.reviewAnnotationsProvider = { doc.annotations(filter: AnnotationFilter(statuses: [.open])) }
        coordinator.reviewParagraphRangeProvider = { doc.displayRange(forParagraphId: $0) }
        coordinator.reviewParagraphTextProvider = { doc.paragraph(id: $0) }
        // `EditorHost`'s locator, which the checkbox click's hit test asks.
        coordinator.paragraphLocator = { location in
            guard let pid = doc.paragraphId(at: location),
                  let range = doc.displayRange(forParagraphId: pid) else { return nil }
            return (paragraphId: pid, offsetWithinParagraph: location - range.location)
        }
        let control = EditorControl()
        control.posture = rd.documentStore.posture(forDocId: doc.docId)
        control.readThroughDocIds = [doc.docId]
        coordinator.observeControl(control)
        XCTAssertTrue(coordinator.isInReadThrough, "premise: in read-through")
        XCTAssertFalse(rd.harness.textView.isEditable)
        XCTAssertTrue(EditorHost.mayWriteText(rd.documentStore, docId: doc.docId)(),
                      "premise: the window's door lets this Mac write the piece")
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

    /// **⌘Z (⇧⌘Z) as Edit ▸ Undo delivers it**: its target-less action goes
    /// to the first responder from the non-editable text view up that answers
    /// it, validated there; then the decision's async hop is awaited.
    private func menu(_ rd: RealDocumentHarness, redo: Bool = false,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let action = Selector(redo ? "redo:" : "undo:")
        var responder: NSResponder? = rd.harness.textView
        while let current = responder, !current.responds(to: action) { responder = current.nextResponder }
        let target = try XCTUnwrap(responder, "something answers \(action)", file: file, line: line)
        let item = NSMenuItem(title: redo ? "Redo" : "Undo", action: action, keyEquivalent: "z")
        let enabled = (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item)
            ?? (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
        XCTAssertTrue(enabled, "\(action) is enabled at \(target)", file: file, line: line)
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: item), file: file, line: line)
        await rd.document.awaitPendingUndoWork()
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

    private func annotation(_ rd: RealDocumentHarness, _ id: String) -> Annotation? {
        rd.document.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    private func status(_ rd: RealDocumentHarness, _ id: String) -> AnnotationStatus? {
        annotation(rd, id)?.status
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
        let id = try await rd.document.addAnnotation(
            kind: .suggestedChange, paragraphId: pid, body: "stronger", suggestedText: "pitch-black",
            span: SpanAnchor(quote: "very dark", prefix: "was ", suffix: " and", posHint: 14))
        rd.harness.coordinator.refreshReviewMarksFromProvider()
        return id
    }

    private func comment(_ rd: RealDocumentHarness, pid: String) async throws -> String {
        try await rd.document.addAnnotation(kind: .comment, paragraphId: pid, body: "hm", suggestedText: nil)
    }

    private func mayWrite(_ rd: RealDocumentHarness) -> @MainActor () -> Bool {
        EditorHost.mayWriteText(rd.documentStore, docId: rd.document.docId)
    }

    private let night = "The night was very dark and stormy."
    private let pitch = "The night was pitch-black and stormy."

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

    /// **The margin card's Accept, ⌘Z, ⇧⌘Z** — through the card's verb and
    /// the host's real handler; the text view shows each state, one apply each.
    func test_acceptFromTheCardChangesTheText_andUndoAndRedoFollow() async throws {
        let rd = try await reading(night)
        let coordinator = rd.harness.coordinator
        let um = try undo(rd)
        let doc = rd.document, ds = rd.documentStore
        // `EditorHost`'s closure, whose body is the static (pinned below).
        coordinator.reviewAcceptHandler = { id in
            try? await EditorHost.acceptFromCard(id, on: doc, undoManager: um, documentStore: ds)
        }
        let id = try await suggestion(rd, pid: try firstParagraph(rd))
        let mark = try XCTUnwrap(coordinator.resolvedReviewMarks.first { $0.id == id }, "the card is drawn")
        XCTAssertTrue(coordinator.reviewCardActions(for: mark).contains(.accept), "the card offers Accept")
        let calls = coordinator.applyExternalTextCallCount
        coordinator.performReviewCardAction(.accept, annotationId: id)
        await coordinator.reviewActionTask?.value
        pass(rd)
        XCTAssertEqual(status(rd, id), .accepted)
        XCTAssertEqual(rd.harness.textView.string, pitch)
        XCTAssertEqual(coordinator.applyExternalTextCallCount, calls + 1)

        try await menu(rd)
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, night, "⌘Z: the text returns")
        XCTAssertEqual(status(rd, id), .open)
        XCTAssertEqual(coordinator.applyExternalTextCallCount, calls + 2)

        try await menu(rd, redo: true)
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, pitch, "⇧⌘Z")
        XCTAssertEqual(status(rd, id), .accepted)
        XCTAssertEqual(coordinator.applyExternalTextCallCount, calls + 3)
        XCTAssertTrue(coordinator.isInReadThrough)
        XCTAssertTrue(um.canUndo)
        try await assertTypingRefused(rd)

        // The host's closures ARE these statics: a decision asks the posture
        // door, never the membrane or `isEditable`.
        let host = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/EditorHost.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(host.contains("try await Self.acceptFromCard(id, on: doc, undoManager: um,"))
        XCTAssertTrue(host.contains("Self.toggleCheckbox(on: doc, paragraphId: paragraphId, offset: offset, kind: kind,"))
        XCTAssertTrue(host.contains("mayWrite: Self.mayWriteText(documentStore, docId: doc.docId))"), "Reply")
        let door = try SourceTree.declaration(named: "static func mayWriteText(", under: "Maugham")
        XCTAssertFalse(door.contains("commandMayWrite") || door.contains("isEditable")
                       || door.contains("isInReadThrough"), "a decision never asks the typing guard")
    }

    // MARK: - 3. Reject, Stet, Got it, Reply

    func test_rejectStetGotItAndReplyLand_andUndoAndRedo() async throws {
        let rd = try await reading(night)
        let um = try undo(rd)
        let pid = try firstParagraph(rd)
        let calls = rd.harness.coordinator.applyExternalTextCallCount

        let rejected = try await suggestion(rd, pid: pid)
        try await rd.document.rejectAnnotation(id: rejected, undoManager: um)
        XCTAssertEqual(status(rd, rejected), .rejected)
        try await menu(rd)
        XCTAssertEqual(status(rd, rejected), .open, "⌘Z reopens the rejected note")
        try await menu(rd, redo: true)
        XCTAssertEqual(status(rd, rejected), .rejected, "⇧⌘Z rejects it again")

        let stetted = try await comment(rd, pid: pid)
        try await rd.document.stetAnnotation(id: stetted, undoManager: um)
        let stetStatus = status(rd, stetted)
        XCTAssertNotEqual(stetStatus, .open)
        try await menu(rd)
        XCTAssertEqual(status(rd, stetted), .open, "⌘Z takes the stet back")
        try await menu(rd, redo: true)
        XCTAssertEqual(status(rd, stetted), stetStatus, "⇧⌘Z stets it again")

        let gotIt = try await comment(rd, pid: pid)
        try await rd.document.acceptAnnotation(id: gotIt, undoManager: um, mayWrite: mayWrite(rd))
        XCTAssertEqual(status(rd, gotIt), .accepted)
        try await menu(rd)
        XCTAssertEqual(status(rd, gotIt), .open, "⌘Z takes Got it back")
        try await menu(rd, redo: true)
        XCTAssertEqual(status(rd, gotIt), .accepted, "⇧⌘Z")

        let replied = try await comment(rd, pid: pid)
        try await rd.document.acceptAnnotation(id: replied, userResponse: "Yes — fixed later.",
                                               undoManager: um, mayWrite: mayWrite(rd))
        XCTAssertEqual(annotation(rd, replied)?.userResponse, "Yes — fixed later.")
        try await menu(rd)
        XCTAssertEqual(status(rd, replied), .open, "⌘Z takes the reply back")
        try await menu(rd, redo: true)
        XCTAssertEqual(status(rd, replied), .accepted)
        XCTAssertEqual(annotation(rd, replied)?.userResponse, "Yes — fixed later.", "⇧⌘Z keeps the reply")

        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, night, "no answer here changes the text")
        XCTAssertEqual(rd.harness.coordinator.applyExternalTextCallCount, calls)
        try await assertTypingRefused(rd)
    }

    // MARK: - 4. Resolve a to-do

    /// A checkbox flip through the host's real handler, and a Tasks-pane
    /// archive, change the text; ⌘Z and ⇧⌘Z follow, the view with them.
    func test_aCheckboxFlipAndATaskArchiveLand_andUndoAndRedo() async throws {
        let rd = try await reading("- [ ] buy milk")
        let coordinator = rd.harness.coordinator
        XCTAssertTrue(coordinator.allowsCheckboxToggle, "resolving a to-do is a decision")
        let um = try undo(rd)
        let pid = try firstParagraph(rd)
        let calls = coordinator.applyExternalTextCallCount
        // Where the click's own hit test puts it (`MaughamTextView.mouseDown`).
        let hit = try XCTUnwrap(coordinator.checkboxHitTest(atCharacterIndex: 3))
        XCTAssertEqual(hit.paragraphId, pid)
        EditorHost.toggleCheckbox(on: rd.document, paragraphId: hit.paragraphId,
                                  offset: hit.offsetWithinParagraph, kind: hit.kind,
                                  undoManager: um, documentStore: rd.documentStore)
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, "- [x] buy milk")
        XCTAssertEqual(coordinator.applyExternalTextCallCount, calls + 1)
        try await menu(rd)
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, "- [ ] buy milk", "⌘Z flips it back")
        XCTAssertEqual(coordinator.applyExternalTextCallCount, calls + 2)
        try await menu(rd, redo: true)
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, "- [x] buy milk", "⇧⌘Z flips it again")
        XCTAssertEqual(coordinator.applyExternalTextCallCount, calls + 3)

        func tasks(_ status: TaskStatus) -> [WriterTask] {
            rd.document.tasks(filter: TaskFilter(scope: .document(docId: rd.document.docId), statuses: [status]))
        }
        let task = try XCTUnwrap(tasks(.done).first ?? tasks(.open).first)
        rd.document.archiveTask(id: task.id, undoManager: um)
        pass(rd)
        XCTAssertEqual(tasks(.archived).count, 1)
        XCTAssertTrue(tasks(.open).isEmpty && tasks(.done).isEmpty)
        XCTAssertEqual(rd.harness.textView.string, rd.document.displayText, "the view follows the archive")
        try await menu(rd)
        pass(rd)
        XCTAssertEqual(tasks(.open).count, 1, "⌘Z restores the to-do")
        XCTAssertEqual(rd.harness.textView.string, rd.document.displayText)
        try await menu(rd, redo: true)
        pass(rd)
        // ⇧⌘Z is enabled and reaches the document (`menu` asserts it); what
        // an inline archive's redo restores is the task system's own rule,
        // outside read-through (reported, not pinned here).
        XCTAssertEqual(rd.harness.textView.string, rd.document.displayText)
        try await assertTypingRefused(rd)
    }

    // MARK: - 5. The round's verbs

    /// A bulk accept through `AnnotationBulkActions` and a triage mark land;
    /// ⌘Z and ⇧⌘Z reach both.
    func test_aBulkAcceptAndATriageLand_andUndoAndRedo() async throws {
        let rd = try await reading(night)
        let um = try undo(rd)
        let pid = try firstParagraph(rd)
        let id = try await suggestion(rd, pid: pid)
        let calls = rd.harness.coordinator.applyExternalTextCallCount
        let outcome = await AnnotationBulkActions.perform(.accept, on: [id], in: rd.document,
                                                          undoManager: um, mayWrite: mayWrite(rd))
        XCTAssertEqual(outcome.succeeded, [id])
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, pitch)
        XCTAssertEqual(rd.harness.coordinator.applyExternalTextCallCount, calls + 1)
        try await menu(rd)
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, night, "⌘Z takes the bulk accept back")
        try await menu(rd, redo: true)
        pass(rd)
        XCTAssertEqual(rd.harness.textView.string, pitch, "⇧⌘Z")

        let note = try await comment(rd, pid: pid)
        let triaged = await AnnotationBulkActions.perform(.triage(.discuss), on: [note], in: rd.document,
                                                          undoManager: um)
        XCTAssertEqual(triaged.succeeded, [note])
        XCTAssertEqual(annotation(rd, note)?.triage, .discuss)
        try await menu(rd)
        XCTAssertNil(annotation(rd, note)?.triage, "⌘Z clears the mark")
        try await menu(rd, redo: true)
        XCTAssertEqual(annotation(rd, note)?.triage, .discuss, "⇧⌘Z marks it again")
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

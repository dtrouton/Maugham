import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// ⌘Z undo of inline checkbox toggles (Task 5). Inline tasks are
/// text-is-state — a toggle is a plain `setParagraph` → `.typingBurst`, NO
/// task op — so undo is a guarded flip-back of the paragraph text, keyed to
/// the undo-coherent apply flag so the editor's external buffer replace
/// doesn't wipe the just-registered action (v0.17.0 D2 rule).
///
/// The interleaving harness test pins the ⌘Z-crash class (B3) via the D1
/// rule: a toggle replaces the whole NSTextView buffer, which makes any
/// pre-toggle native typing-undo action unsound — so `InlineToggleUndo`
/// clears them (clear→mutate→register, accept's choreography) and the
/// walk-back is: post-toggle typing → toggle → nothing.
@MainActor
final class InlineTaskToggleUndoTests: XCTestCase {

    // MARK: - Fixture (mirrors DocumentTasksTests)

    private func makeProject(initialMd: String) throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("INLINE-TOGGLE-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document, path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    private func makeDocument(initialMd: String) async throws -> Document {
        let (project, path) = try makeProject(initialMd: initialMd)
        return try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
    }

    private func firstParagraphId(of doc: Document) async throws -> String {
        let log = try await doc.opLog()
        guard let bootstrap = log.first(where: { $0.kind == .bootstrap }),
              let pid = bootstrap.changes.first?.paragraphId else {
            XCTFail("no bootstrap paragraph")
            throw NSError(domain: "test", code: 0)
        }
        return pid
    }

    // MARK: - Direct helper drive (no SwiftUI harness needed)

    func test_inlineToggle_undo_restoresUncheckedText() async throws {
        let doc = try await makeDocument(initialMd: "- [ ] buy milk")
        let pid = try await firstParagraphId(of: doc)
        let um = UndoManager()

        let prior = try XCTUnwrap(doc.paragraph(id: pid))     // "- [ ] buy milk"
        let flipped = flipInlineCheckbox(prior)               // "- [x] buy milk"
        XCTAssertNotEqual(prior, flipped)

        InlineToggleUndo.perform(on: doc, paragraphId: pid,
                                 prior: prior, flipped: flipped, undoManager: um)
        XCTAssertEqual(doc.paragraph(id: pid), flipped)

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.paragraph(id: pid), prior,
            "⌘Z of an inline toggle restores the pre-toggle text")

        um.redo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.paragraph(id: pid), flipped,
            "⇧⌘Z re-applies the toggle")

        // Re-arm: redo forwards the LIVE undo manager into the forward
        // re-toggle, which registers a FRESH undo pair (a nil-forwarded
        // manager — the T3 regression — would fail right here).
        XCTAssertTrue(um.canUndo,
            "redo's forward re-toggle must re-register undo — the cycle re-arms")
        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.paragraph(id: pid), prior,
            "a second ⌘Z after ⇧⌘Z restores the pre-toggle text again")
    }

    func test_inlineToggle_undo_afterParagraphEdited_isLoudNoOp() async throws {
        let doc = try await makeDocument(initialMd: "- [ ] buy milk")
        let pid = try await firstParagraphId(of: doc)
        let um = UndoManager()

        let prior = try XCTUnwrap(doc.paragraph(id: pid))
        let flipped = flipInlineCheckbox(prior)
        InlineToggleUndo.perform(on: doc, paragraphId: pid,
                                 prior: prior, flipped: flipped, undoManager: um)

        // Drift the paragraph out from under the pending undo.
        doc.setParagraph(id: pid, text: "- [x] buy oat milk")

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.paragraph(id: pid), "- [x] buy oat milk",
            "the toggle's flip-back declines as a loud no-op when the paragraph drifted")
    }

    func test_inlineToggle_fountainTodoDone_roundTrips() async throws {
        // Fountain boneyard todo/done flip is also length-preserving; the same
        // guarded flip-back must round-trip.
        let doc = try await makeDocument(initialMd: "note [[todo: fix scene]]")
        let pid = try await firstParagraphId(of: doc)
        // Force the deriver to mint the task anchor so a real anchorId exists.
        let tasks = doc.tasks(filter: .init(scope: .document(docId: doc.docId)))
        let anchored = try XCTUnwrap(doc.paragraph(id: pid))
        XCTAssertTrue(anchored.contains("[[todo:"), "fixture carries a todo")
        let task = try XCTUnwrap(tasks.first)
        let anchorId = try XCTUnwrap(
            task.id.split(separator: ":").last.map(String.init))

        let um = UndoManager()
        let flipped = flipFountainTodoDone(in: anchored, anchorId: anchorId)
        XCTAssertTrue(flipped.contains("[[done:"), "flip produced a done marker")
        InlineToggleUndo.perform(on: doc, paragraphId: pid,
                                 prior: anchored, flipped: flipped, undoManager: um)
        XCTAssertEqual(doc.paragraph(id: pid), flipped)

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.paragraph(id: pid), anchored,
            "⌘Z restores the todo marker")
    }

    // MARK: - Interleaving harness test (B3 crash class)

    // Sync ⟷ async bridges (AnnotationAcceptUndoTests' canonical shape: a
    // SYNCHRONOUS test, default `groupsByEvent`, NO manual undo group —
    // `removeAllActions()` inside a manual `beginUndoGrouping` corrupts
    // NSUndoManager's grouping state, and production never opens one; each
    // user action's event group closes on a run-loop turn instead).

    private final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    /// Run an async body to completion from a synchronous test, pumping the
    /// main run loop via `wait(for:)` so MainActor-hopped continuations progress.
    @discardableResult
    private func bridge<T>(
        timeout: TimeInterval = 15, _ body: @escaping @MainActor () async throws -> T
    ) throws -> T {
        let box = ResultBox<T>()
        let exp = expectation(description: "async-bridge")
        Task { @MainActor in
            do { box.result = .success(try await body()) }
            catch { box.result = .failure(error) }
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        return try box.result!.get()
    }

    func test_type_toggle_type_undoWalksBackInOrder_noCrash() throws {
        let rd = try bridge {
            try await EditorIntegrationHarness.withRealDocument(
                mode: ProseMode(), initialText: "- [ ] buy milk")
        }
        let doc = rd.document
        let h = rd.harness
        let um = try XCTUnwrap(h.textView.undoManager)
        um.removeAllActions()
        // fixed window: `removeAllActions` closes any open group itself
        // (measured — groupingLevel drops straight to 0), so there is no
        // observable condition here; this is the harness settling.
        pumpFor(0.05)

        // Mirror EditorSurface.updateNSView: consume the flag every pass;
        // apply only when the buffer differs.
        func pumpEditorApply() {
            let coherent = doc.consumeUndoCoherentApplyFlag()
            if h.textView.string != doc.displayText {
                h.coordinator.applyExternalText(
                    doc.displayText, preserveUndoStack: coherent)
            }
        }

        // 1. Native typing burst #1 — append "X"; run-loop turn closes the
        //    event group, as between real user actions.
        h.setCursor(to: (h.textView.string as NSString).length)
        h.typeCharacter("X")
        XCTAssertEqual(h.textView.string, "- [ ] buy milkX")
        // `shouldChangeText` registered the typing action synchronously; what
        // the run-loop turn is for is `groupsByEvent` CLOSING that event group.
        // That close is not readable as a value — `canUndo` is already true
        // with the group still open, and measured 2026-08-08 a
        // `waitUntil { um.canUndo && um.groupingLevel == 0 }` never goes true
        // here and burns its whole deadline. So the window stays.
        pumpFor(0.05)  // fixed window: the event-group close — see the note above

        // 2. Inline toggle via the helper, then the editor apply pass the
        //    SwiftUI update would drive. D1: the toggle's buffer replace makes
        //    the pre-toggle native typing history unsound, so perform CLEARS
        //    it before registering (accept's clear→mutate→register).
        let pid = try XCTUnwrap(doc.paragraphId(at: 0))
        let prior = try XCTUnwrap(doc.paragraph(id: pid))     // "- [ ] buy milkX"
        let flipped = flipInlineCheckbox(prior)               // "- [x] buy milkX"
        InlineToggleUndo.perform(on: doc, paragraphId: pid,
                                 prior: prior, flipped: flipped, undoManager: um)
        pumpEditorApply()
        XCTAssertEqual(h.textView.string, "- [x] buy milkX",
            "toggle replaced the buffer")
        pumpFor(0.05)  // fixed window: the event-group close

        // 3. Native typing burst #2 — append "Y". Registered AFTER the
        //    toggle's clear, so it is sound and survives.
        h.setCursor(to: (h.textView.string as NSString).length)
        h.typeCharacter("Y")
        XCTAssertEqual(h.textView.string, "- [x] buy milkXY")
        pumpFor(0.05)  // fixed window: the event-group close

        // 4. ⌘Z walk-back per D1: post-toggle typing (native, sound), then the
        //    toggle (registered action), then NOTHING — the pre-toggle typing
        //    history was cleared at toggle time, so the third ⌘Z is a no-op,
        //    never a pop of a stale action against replaced storage (the B3
        //    SIGSEGV class).
        um.undo()   // undo "Y" (native, synchronous)
        XCTAssertEqual(h.textView.string, "- [x] buy milkX")
        // fixed window: `undo()` closes the top-level group itself and its
        // nested redo registration opens none (measured — groupingLevel is
        // already 0 here), so there is no condition left to name.
        pumpFor(0.05)

        um.undo()   // undo toggle: handler hops async → wait for the flip-back
        waitUntil { doc.paragraph(id: pid) == prior }
        pumpEditorApply()
        XCTAssertEqual(h.textView.string, "- [ ] buy milkX",
            "second ⌘Z undoes the toggle across the interleaved native actions")
        pumpFor(0.05)  // fixed window: asserting nothing happens (canUndo stays false)

        XCTAssertFalse(um.canUndo,
            "pre-toggle typing history was cleared per D1 — nothing left to undo")
        um.undo()   // third ⌘Z: no-op, must not fault (B3)
        pumpFor(0.05)  // fixed window: asserting nothing happens (the buffer is unchanged)
        XCTAssertEqual(h.textView.string, "- [ ] buy milkX",
            "third ⌘Z is a no-op — pre-toggle typing is not recoverable (D1's accepted cost)")
    }
}

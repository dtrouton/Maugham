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
/// The interleaving harness test pins the ⌘Z-crash class (B3): a
/// length-preserving toggle replaces the whole NSTextView buffer while
/// interleaved native typing-undo actions remain on the stack, and popping
/// them afterwards must not fault.
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

    func test_type_toggle_type_undoWalksBackInOrder_noCrash() async throws {
        let rd = try await EditorIntegrationHarness.withRealDocument(
            mode: ProseMode(), initialText: "- [ ] buy milk")
        let doc = rd.document
        let h = rd.harness
        let um = try XCTUnwrap(h.textView.undoManager)
        um.removeAllActions()
        // Each user action (keystroke burst / mouse-click toggle) is a distinct
        // run-loop EVENT in production, so NSUndoManager files each as its own
        // group. A synchronous test collapses them all into one event; opt out
        // of `groupsByEvent` and bracket each action explicitly to reproduce
        // the real per-action grouping.
        um.groupsByEvent = false

        // Mirror EditorSurface.updateNSView: consume the flag every pass;
        // apply only when the buffer differs.
        func pumpEditorApply() {
            let coherent = doc.consumeUndoCoherentApplyFlag()
            if h.textView.string != doc.displayText {
                h.coordinator.applyExternalText(
                    doc.displayText, preserveUndoStack: coherent)
            }
        }
        func asAction(_ body: () -> Void) {
            um.beginUndoGrouping(); body(); um.endUndoGrouping()
        }

        // 1. Native typing burst #1 — append "X".
        asAction {
            h.setCursor(to: (h.textView.string as NSString).length)
            h.typeCharacter("X")
        }
        XCTAssertEqual(h.textView.string, "- [ ] buy milkX")

        // 2. Inline toggle (length-preserving) via the helper, then the editor
        //    apply pass the SwiftUI update would drive.
        let pid = try XCTUnwrap(doc.paragraphId(at: 0))
        let prior = try XCTUnwrap(doc.paragraph(id: pid))     // "- [ ] buy milkX"
        let flipped = flipInlineCheckbox(prior)               // "- [x] buy milkX"
        asAction {
            InlineToggleUndo.perform(on: doc, paragraphId: pid,
                                     prior: prior, flipped: flipped, undoManager: um)
            pumpEditorApply()
        }
        XCTAssertEqual(h.textView.string, "- [x] buy milkX",
            "toggle replaced the buffer, preserving length")

        // 3. Native typing burst #2 — append "Y".
        asAction {
            h.setCursor(to: (h.textView.string as NSString).length)
            h.typeCharacter("Y")
        }
        XCTAssertEqual(h.textView.string, "- [x] buy milkXY")

        // 4. ⌘Z ×3 — native Y, then the toggle (op), then native X. The pop of
        //    the native actions AFTER the toggle's whole-buffer replace is the
        //    B3 fault site; it stays safe because the toggle is length-
        //    preserving, so the native undo ranges remain in bounds.
        um.undo()   // undo "Y" (native, synchronous)
        XCTAssertEqual(h.textView.string, "- [x] buy milkX")

        um.undo(); await doc.awaitPendingUndoWork(); pumpEditorApply()  // undo toggle
        XCTAssertEqual(h.textView.string, "- [ ] buy milkX",
            "second ⌘Z undoes the toggle across the interleaved native actions")

        um.undo()   // undo "X" (native) — the pop that used to segfault (B3)
        XCTAssertEqual(h.textView.string, "- [ ] buy milk",
            "third ⌘Z pops the native typing action after the buffer replace without a fault")
    }
}

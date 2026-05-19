// MaughamTests/Editor/EditorIntegrationHarnessTests.swift
import XCTest
@testable import Maugham

@MainActor
final class EditorIntegrationHarnessTests: XCTestCase {

    func test_singleCharacterTyped_textViewMatchesUserInput() {
        let rig = EditorIntegrationHarness(initialText: "")
        rig.typeCharacter("a")
        XCTAssertEqual(rig.currentText, "a")
        XCTAssertEqual(rig.cursorLocation, 1)
    }

    func test_rapidTyping_preservesCursorAtEnd() async {
        let rig = EditorIntegrationHarness(initialText: "")
        await rig.typeString("The quick brown fox")
        XCTAssertEqual(rig.currentText, "The quick brown fox")
        XCTAssertEqual(rig.cursorLocation, 19,
            "after typing 19 chars at end, cursor must be at 19")
    }

    func test_rapidTyping_inMiddle_preservesInsertionPoint() async {
        let rig = EditorIntegrationHarness(initialText: "Hello world")
        rig.setCursor(to: 5)  // between "Hello" and " world"
        await rig.typeString(", dear")
        XCTAssertEqual(rig.currentText, "Hello, dear world")
        XCTAssertEqual(rig.cursorLocation, 11)  // 5 + 6 typed chars
    }

    func test_trailingSpace_persistsAcrossAutosave() async throws {
        let rig = EditorIntegrationHarness(initialText: "")
        await rig.typeString("hello ")
        // Wait > 750ms for any autosave to complete + onChange to run.
        try await Task.sleep(for: .milliseconds(900))
        await rig.typeString("world")
        // The trailing space we typed should still be present.
        XCTAssertEqual(rig.currentText, "hello world",
            "trailing space typed before autosave must persist")
    }

    func test_pasteMultiCharString_preservesCursorAtPasteEnd() {
        let rig = EditorIntegrationHarness(initialText: "")
        rig.paste("foo bar")
        XCTAssertEqual(rig.currentText, "foo bar")
        XCTAssertEqual(rig.cursorLocation, 7)
    }

    func test_externalEditWithIdsIntact_ingestsSilently() async throws {
        let rig = EditorIntegrationHarness(
            initialText: "<!-- ¶a3f9 -->\n\nHello.\n")
        let docStore = try await rig.attachDocumentStore()
        let doc = try await Document.load(
            url: rig.projectURL.appendingPathComponent(rig.docPath),
            device: "m", session: "s", presenter: docStore.presenter)
        docStore.register(document: doc, for: rig.docPath)

        // Write the external content + drive the presenter callback. In
        // process NSFilePresenter callbacks are unreliable, so we invoke the
        // dispatch directly — this still exercises the T11 routing path
        // (`presenterDidChangeSubitem` → `document(for:)` → Document).
        try await rig.writeExternalMdContent(
            "<!-- ¶a3f9 -->\n\nHello, edited.\n")
        docStore.presenterDidChangeSubitem(
            at: rig.projectURL.appendingPathComponent(rig.docPath))
        try await waitFor(timeout: .seconds(2)) {
            doc.displayText.contains("edited")
        }

        XCTAssertNil(doc.pendingConflict,
            "intact ¶ids → silent ingest, no conflict sheet")
        XCTAssertTrue(doc.displayText.contains("edited"))
    }

    func test_externalEditWithIdsStripped_surfacesConflict() async throws {
        let rig = EditorIntegrationHarness(
            initialText: "<!-- ¶a3f9 -->\n\nHello.\n")
        let docStore = try await rig.attachDocumentStore()
        let doc = try await Document.load(
            url: rig.projectURL.appendingPathComponent(rig.docPath),
            device: "m", session: "s", presenter: docStore.presenter)
        docStore.register(document: doc, for: rig.docPath)

        try await rig.writeExternalMdContent("Hello, edited (no IDs).\n")
        docStore.presenterDidChangeSubitem(
            at: rig.projectURL.appendingPathComponent(rig.docPath))
        try await waitFor(timeout: .seconds(2)) {
            doc.pendingConflict != nil
        }

        XCTAssertNotNil(doc.pendingConflict,
            "stripped ¶ids → conflict surfaces")
    }

    /// Polls predicate every 50ms up to `timeout`. Returns when true; no
    /// throw on timeout — caller asserts the actual condition right after.
    private func waitFor(
        timeout: Duration, _ predicate: @escaping () -> Bool
    ) async throws {
        let start = Date()
        let maxSeconds = Double(timeout.components.seconds)
        while !predicate() {
            if Date().timeIntervalSince(start) > maxSeconds { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func test_endOfFileTyping_doesNotFireApplyExternalText() {
        let rig = EditorIntegrationHarness(initialText: "Hello")
        rig.setCursor(to: 5)

        rig.assertNoApplyExternalText {
            rig.typeCharacter(" ")
            rig.typeCharacter("w")
            rig.typeCharacter("o")
            rig.typeCharacter("r")
            rig.typeCharacter("l")
            rig.typeCharacter("d")
        }

        XCTAssertEqual(rig.currentText, "Hello world")
        XCTAssertEqual(rig.cursorLocation, 11)
    }

    func test_documentSwitch_flushesPendingBurst_beforeNewBinding() async throws {
        // This test pins the contract that switching documents flushes any
        // pending burst on the previously-loaded doc. The harness today
        // doesn't run a multi-doc binder, so this test is XCTSkip'd until
        // Stage 2 lands DocumentStore.register + Document.close.
        throw XCTSkip("Multi-doc switching wired in Stage 2 via Document.close")
    }

    func test_burst_appendOnceAtIdleThreshold() async throws {
        // BurstScheduler is idle: 30s, max: 90s today. Verifying a single
        // typing_burst op lands after the idle threshold requires either a
        // 30-second test (too slow) or a test-only constructor that lets
        // us override the thresholds. Stage 1 lands the Document type with
        // testable thresholds; this test un-skips then.
        throw XCTSkip("Testable burst thresholds land with Document in Stage 1")
    }
}

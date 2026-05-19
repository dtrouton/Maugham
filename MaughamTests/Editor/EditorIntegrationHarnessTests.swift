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
        _ = try await rig.attachDocumentStore()

        // Externally rewrite the .md, keeping the ¶id intact but changing
        // the paragraph body. Reconciler.classify should return
        // .silentIngest; the editor view should reflect the change without
        // a conflict sheet surfacing.
        try await rig.writeExternalMdContent(
            "<!-- ¶a3f9 -->\n\nHello, edited.\n")
        try await Task.sleep(for: .milliseconds(300))

        // Today this path may not be fully wired end-to-end (audit finding
        // #3). After Stage 3 it will be. For now we document the expected
        // post-refactor behaviour:
        // XCTAssertTrue(rig.currentText.contains("edited"))
        // The test is `XCTSkip`'d today; Stage 3 will un-skip.
        throw XCTSkip("Reconciler end-to-end path is wired in Stage 3")
    }

    func test_externalEditWithIdsStripped_surfacesConflict() async throws {
        let rig = EditorIntegrationHarness(
            initialText: "<!-- ¶a3f9 -->\n\nHello.\n")
        _ = try await rig.attachDocumentStore()

        // External tool stripped the ¶id comment. Reconciler should
        // classify as .needsSheet, surfacing pendingConflict.
        try await rig.writeExternalMdContent("Hello, edited (no IDs).\n")
        try await Task.sleep(for: .milliseconds(300))

        // Same situation — Stage 3 will un-skip.
        throw XCTSkip("Reconciler end-to-end path is wired in Stage 3")
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

// MaughamTests/Editor/EditorIntegrationHarnessTests.swift
import XCTest
import MaughamCore
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
        // ADR 0019: the op log is the source of truth — seed it (after
        // attachDocumentStore writes the manifest) so the doc derives its
        // paragraph from the op log; the intact-id external edit is then a
        // clean in-place change of a3f9, ingested silently.
        try await seedOpLogBootstrap(
            projectURL: rig.projectURL,
            docId: "doc-test",
            paragraphs: ["a3f9": "Hello."],
            sequence: ["a3f9"])
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
        // Two documents in the same project; type in doc A, close it,
        // assert A's op log received the typing_burst op (i.e. close
        // flushed the pending buffer).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EIH-T9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docAPath = "manuscript/a.md"
        let docBPath = "manuscript/b.md"
        try "Doc A initial.\n".data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docAPath), options: .atomic)
        try "Doc B initial.\n".data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docBPath), options: .atomic)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-a", title: "A", type: .document, path: docAPath),
                StructureItem(id: "doc-b", title: "B", type: .document, path: docBPath),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let docA = try await Document.load(
            url: tmp.appendingPathComponent(docAPath),
            device: "m", session: "s", presenter: nil)
        docA.setFullText("Doc A edited.")
        // Simulate the doc-switch: close docA before loading docB.
        await docA.close()

        let opStore = OpLogStore(projectURL: tmp)
        let opsA = try await opStore.load(docId: docA.docId)
        let burstCount = opsA.filter { $0.kind == .typingBurst }.count
        XCTAssertGreaterThanOrEqual(burstCount, 1,
            "doc-switch close() must flush the pending typing_burst op")
    }

    func test_typingCaretIntoCharacterCue_doesNotFireApplyExternalText() {
        // Regression net for dual-dialogue cue entry (Editor AREA.md tripwire 7).
        // Typing "^" after a character name produces a dual-dialogue cue; the
        // tokenizer strips the caret from content but must not trigger
        // applyExternalText (which is reserved for cloud-conflict resolution).
        let rig = EditorIntegrationHarness(
            mode: ScreenplayMode(),
            initialText: "BRICK\nHello.\n\n")

        rig.assertNoApplyExternalText {
            for ch in "STEVE ^\nHi." {
                rig.typeCharacter(ch)
            }
        }
    }

    func test_burst_appendOnceAtIdleThreshold() async throws {
        // Short thresholds via the internal Document.load overload so the
        // test doesn't have to wait 30 seconds.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EIH-T10-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c.md"
        try "Hello.\n".data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath), options: .atomic)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-c", title: "C", type: .document, path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let doc = try await Document.load(
            url: tmp.appendingPathComponent(docPath),
            device: "m", session: "s", presenter: nil,
            burstIdle: .milliseconds(250),
            burstMax: .seconds(60))

        let opStore = OpLogStore(projectURL: tmp)
        let opsBefore = try await opStore.load(docId: doc.docId)
        let burstsBefore = opsBefore.filter { $0.kind == .typingBurst }.count

        // Type a burst.
        doc.setFullText("Hello world.")

        // Wait > idle threshold so the BurstScheduler fires.
        try await Task.sleep(for: .milliseconds(600))

        let opsAfter = try await opStore.load(docId: doc.docId)
        let burstsAfter = opsAfter.filter { $0.kind == .typingBurst }.count
        XCTAssertEqual(burstsAfter, burstsBefore + 1,
            "exactly one typing_burst op should fire at idle threshold")
    }
}

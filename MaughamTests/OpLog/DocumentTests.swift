// MaughamTests/OpLog/DocumentTests.swift
import XCTest
@testable import Maugham

@MainActor
final class DocumentTests: XCTestCase {

    private func makeProject(initialMd: String = "") throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DOC-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        // Minimal manifest so resolveDocId can find the doc.
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document,
                path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    func test_load_emptyDocument_displayTextIsEmpty() async throws {
        let (project, path) = try makeProject(initialMd: "")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        XCTAssertEqual(doc.displayText, "")
    }

    func test_load_existingMd_runsBootstrapAndPopulatesDisplayText() async throws {
        let (project, path) = try makeProject(initialMd: "Hello world.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        // After bootstrap, the .md gained inline ¶id markers; displayText
        // is the stripped form.
        XCTAssertEqual(doc.displayText, "Hello world.")
    }

    func test_setFullText_updatesDisplayTextOnce() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        doc.setFullText("Hello world.")
        XCTAssertEqual(doc.displayText, "Hello world.")
    }

    func test_setFullText_emitsParagraphChangeIntoPendingBuffer() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        doc.setFullText("Hello world.")
        try await doc.flushBurstNow()
        let opStore = OpLogStore(projectURL: project)
        let ops = try await opStore.load(docId: doc.docId)
        // Bootstrap op + typing_burst op.
        XCTAssertGreaterThanOrEqual(ops.count, 2)
        let burst = ops.last!
        XCTAssertEqual(burst.kind, .typingBurst)
    }

    func test_materialize_roundTripsThroughBootstrap() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n\nWorld.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let rendered = doc.materialize()
        // Rendered form has inline ¶id markers; parsing back yields the
        // same paragraph texts.
        let parsed = ParagraphParser.parse(rendered)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].text, "Hello.")
        XCTAssertEqual(parsed[1].text, "World.")
    }

    func test_close_flushesBurstAndAutosave() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        doc.setFullText("Hello world.")
        await doc.close()
        // After close, the .md on disk reflects materialize().
        let onDisk = try String(
            contentsOf: project.appendingPathComponent(path),
            encoding: .utf8)
        XCTAssertTrue(onDisk.contains("Hello world."))
    }

    /// Regression: setFullText must write displayText verbatim, not the
    /// re-rendered form. ParagraphParser strips trailing whitespace and
    /// newlines from paragraph text; if displayText is recomputed from
    /// paragraphs, pressing Enter (textView.string="Hello\n") produces a
    /// shorter displayText ("Hello"), which causes the EditorSurface
    /// updateNSView mismatch path to fire applyExternalText. Under
    /// NSSpellChecker's inline-prediction window that crashes the app
    /// with an NSRangeException unsigned-underflow. The invariant: for
    /// any input text, displayText == text after setFullText returns.
    func test_setFullText_displayTextMatchesInputVerbatim() async throws {
        let (project, path) = try makeProject(initialMd: "")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)

        // Trailing newline — the case that crashed under autocorrect.
        doc.setFullText("Hello\n")
        XCTAssertEqual(doc.displayText, "Hello\n",
            "trailing newline must round-trip verbatim through setFullText")

        // Trailing space.
        doc.setFullText("Hello world ")
        XCTAssertEqual(doc.displayText, "Hello world ",
            "trailing space must round-trip verbatim through setFullText")

        // Multiple consecutive newlines.
        doc.setFullText("Hello\n\n\n")
        XCTAssertEqual(doc.displayText, "Hello\n\n\n",
            "trailing blank lines must round-trip verbatim through setFullText")

        // Standard mid-paragraph text — also unchanged.
        doc.setFullText("Hello\n\nWorld.")
        XCTAssertEqual(doc.displayText, "Hello\n\nWorld.")
    }

    func test_handleExternalDiskChange_echo_isNoOp() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        // Force lastWrittenText to match the diskMd we'll feed in.
        doc.setFullText("Hello.")
        await doc.close()
        let onDisk = try String(
            contentsOf: project.appendingPathComponent(path),
            encoding: .utf8)
        try await doc.handleExternalDiskChange(diskMd: onDisk)
        XCTAssertNil(doc.pendingConflict)
    }
}

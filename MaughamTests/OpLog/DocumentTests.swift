// MaughamTests/OpLog/DocumentTests.swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class DocumentTests: XCTestCase {

    func test_load_emptyDocument_displayTextIsEmpty() async throws {
        let (_, docURL) = try makeTestProject(prefix: "DOC", initialMd: "")
        let doc = try await Document.load(
            url: docURL,
            device: "m", session: "s", presenter: nil)
        XCTAssertEqual(doc.displayText, "")
    }

    func test_load_existingMd_runsBootstrapAndPopulatesDisplayText() async throws {
        let (_, docURL) = try makeTestProject(prefix: "DOC", initialMd: "Hello world.\n")
        let doc = try await Document.load(
            url: docURL,
            device: "m", session: "s", presenter: nil)
        // After bootstrap, the .md gained inline ¶id markers; displayText
        // is the stripped form.
        XCTAssertEqual(doc.displayText, "Hello world.")
    }

    func test_setFullText_updatesDisplayTextOnce() async throws {
        let (_, docURL) = try makeTestProject(prefix: "DOC", initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: docURL,
            device: "m", session: "s", presenter: nil)
        doc.setFullText("Hello world.")
        XCTAssertEqual(doc.displayText, "Hello world.")
    }

    func test_setFullText_emitsParagraphChangeIntoPendingBuffer() async throws {
        let (project, docURL) = try makeTestProject(prefix: "DOC", initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: docURL,
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
        let (_, docURL) = try makeTestProject(prefix: "DOC", initialMd: "Hello.\n\nWorld.\n")
        let doc = try await Document.load(
            url: docURL,
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
        let (_, docURL) = try makeTestProject(prefix: "DOC", initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: docURL,
            device: "m", session: "s", presenter: nil)
        doc.setFullText("Hello world.")
        await doc.close()
        // After close, the .md on disk reflects materialize().
        let onDisk = try String(
            contentsOf: docURL,
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
        let (_, docURL) = try makeTestProject(prefix: "DOC", initialMd: "")
        let doc = try await Document.load(
            url: docURL,
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
        let (_, docURL) = try makeTestProject(prefix: "DOC", initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: docURL,
            device: "m", session: "s", presenter: nil)
        // Force lastDiskEcho to match the diskMd we'll feed in.
        doc.setFullText("Hello.")
        await doc.close()
        let onDisk = try String(
            contentsOf: docURL,
            encoding: .utf8)
        let mirrorBefore = doc.opLogMirrorCount
        try await doc.handleExternalDiskChange(diskMd: onDisk)
        XCTAssertEqual(doc.opLogMirrorCount, mirrorBefore,
            "an echo (disk already matches our clean render) must be a no-op")
    }
}

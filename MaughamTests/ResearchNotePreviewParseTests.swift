import XCTest
import AppKit
@testable import Maugham

/// Audit A4: `ResearchNotePreviewPane` used to turn every non-empty line into
/// its own `.paragraph` block, so hard-wrapped prose rendered as stacked line
/// fragments instead of flowing paragraphs. `parse` accumulates consecutive
/// non-empty, non-heading, non-solo-image lines and joins them with a
/// newline, preserving the writer's own line break inside the paragraph
/// (parsed with `.inlineOnlyPreservingWhitespace` so Markdown's default
/// soft-break-to-space collapse never eats it); a blank line, heading, solo
/// image, or end of text flushes the buffer.
final class ResearchNotePreviewParseTests: XCTestCase {
    typealias Block = ResearchNotePreviewPane.Block

    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResearchPreview-\(UUID())")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        return tmp
    }

    /// Writes a tiny real PNG so `NSImage(contentsOf:)` succeeds the way it
    /// would against a writer's actual pasted image.
    private func writeImage(named name: String, in project: URL) throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("failed to build test PNG fixture")
        }
        try pngData.write(to: project.appendingPathComponent("research/\(name)"))
    }

    private func plainText(_ block: Block) -> String? {
        guard case .paragraph(let attr) = block else { return nil }
        return String(attr.characters)
    }

    func test_hardWrappedLinesJoinIntoOneParagraph() throws {
        let project = try makeProject()
        let text = "line one\nline two\n\npara two"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 2, "blank line separates exactly two paragraphs")
        XCTAssertEqual(plainText(blocks[0]), "line one\nline two")
        XCTAssertEqual(plainText(blocks[1]), "para two")
    }

    func test_headingFlushesParagraphBuffer() throws {
        let project = try makeProject()
        let text = "line one\n# Heading\nline two"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(plainText(blocks[0]), "line one")
        guard case .heading(let level, let headingText) = blocks[1] else {
            return XCTFail("expected heading, got \(blocks[1])")
        }
        XCTAssertEqual(level, 1); XCTAssertEqual(headingText, "Heading")
        XCTAssertEqual(plainText(blocks[2]), "line two")
    }

    func test_soloImageFlushesParagraphBuffer() throws {
        let project = try makeProject()
        try writeImage(named: "photo.png", in: project)
        let text = "line one\n![alt](./photo.png)\nline two"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 3, "got \(blocks)")
        XCTAssertEqual(plainText(blocks[0]), "line one")
        guard case .image = blocks[1] else { return XCTFail("expected image, got \(blocks[1])") }
        XCTAssertEqual(plainText(blocks[2]), "line two")
    }

    /// If an `![alt](./path)` line's image can't actually be loaded (missing
    /// file), it is not a real image block — it falls through and joins the
    /// paragraph buffer as text, same as any other line, rather than always
    /// isolating itself as its own paragraph. The joined buffer still goes
    /// through `AttributedString(markdown:)`, which parses `![alt](url)` as
    /// Markdown image syntax and renders only the alt text (no inline image
    /// support in `AttributedString`) — so the surviving text is "alt", not
    /// the raw `![alt](./missing.png)` source line.
    func test_missingImageFile_lineJoinsParagraphBufferAsText() throws {
        let project = try makeProject()
        // Deliberately do NOT write research/missing.png.
        let text = "line one\n![alt](./missing.png)\nline two"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 1, "got \(blocks)")
        XCTAssertEqual(plainText(blocks[0]), "line one\nalt\nline two")
    }

    func test_endOfTextFlushesTrailingParagraph() throws {
        let project = try makeProject()
        let text = "only one\nwrapped line"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(plainText(blocks[0]), "only one\nwrapped line")
    }

    // MARK: - Task 4: a line break inside a paragraph renders as one

    func test_singleNewlineSurvivesInsideOneParagraph() throws {
        let project = try makeProject()
        let text = "first line\nsecond line"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 1, "got \(blocks)")
        let plain = plainText(blocks[0])
        XCTAssertEqual(plain, "first line\nsecond line")
        XCTAssertTrue(plain?.contains("\n") == true, "the line break must survive, not collapse to a space")
    }

    func test_blankLineStillSeparatesTwoParagraphs() throws {
        let project = try makeProject()
        let text = "a\n\nb"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 2, "got \(blocks)")
        XCTAssertEqual(plainText(blocks[0]), "a")
        XCTAssertEqual(plainText(blocks[1]), "b")
    }

    /// Emphasis must still resolve ACROSS a preserved line break: `*a\nb*` is
    /// one run of `AttributedString` inline Markdown, not two runs split by
    /// the newline, so the writer's italics spanning a hard-wrapped sentence
    /// keep working under the new parsing options.
    func test_emphasisSpansAPreservedLineBreak() throws {
        let project = try makeProject()
        let text = "*a\nb*"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 1, "got \(blocks)")
        guard case .paragraph(let attr) = blocks[0] else {
            return XCTFail("expected paragraph, got \(blocks[0])")
        }
        XCTAssertEqual(String(attr.characters), "a\nb")
        let emphasizedRuns = attr.runs.filter {
            $0.inlinePresentationIntent?.contains(.emphasized) == true
        }
        XCTAssertFalse(emphasizedRuns.isEmpty, "expected at least one emphasized run spanning the break")
        for run in emphasizedRuns {
            let runText = String(attr[run.range].characters)
            XCTAssertTrue(runText == "a" || runText == "b" || runText == "a\nb",
                          "unexpected emphasized run text: \(runText)")
        }
    }

    // MARK: - Shared block parser cutover: new block kinds

    private func codeText(_ block: Block) -> String? {
        guard case .code(let text) = block else { return nil }
        return text
    }

    func test_fenceRendersAsMonospaceVerbatim() throws {
        let project = try makeProject()
        let text = "```swift\nlet x = 1\n  indented\n```"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 1, "got \(blocks)")
        XCTAssertEqual(codeText(blocks[0]), "let x = 1\n  indented")
    }

    func test_listRendersBulletAndOrderedItems() throws {
        let project = try makeProject()
        let text = "- one\n- two\n\n1. first\n2. second"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 4, "got \(blocks)")
        guard case .listItem(let ordered0, let index0, let text0) = blocks[0] else {
            return XCTFail("expected listItem, got \(blocks[0])")
        }
        XCTAssertFalse(ordered0)
        XCTAssertNil(index0)
        XCTAssertEqual(String(text0.characters), "one")

        guard case .listItem(let ordered2, let index2, let text2) = blocks[2] else {
            return XCTFail("expected listItem, got \(blocks[2])")
        }
        XCTAssertTrue(ordered2)
        XCTAssertEqual(index2, 1)
        XCTAssertEqual(String(text2.characters), "first")
    }

    func test_tableRendersHeaderAndRows() throws {
        let project = try makeProject()
        let text = "| a | b |\n|---|---|\n| 1 | 2 |"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 1, "got \(blocks)")
        guard case .table(let header, let rows) = blocks[0] else {
            return XCTFail("expected table, got \(blocks[0])")
        }
        XCTAssertEqual(header, ["a", "b"])
        XCTAssertEqual(rows, [["1", "2"]])
    }

    func test_blockquoteFlattensToAccentQuote() throws {
        let project = try makeProject()
        let text = "> quoted line"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 1, "got \(blocks)")
        guard case .quote(let attr) = blocks[0] else {
            return XCTFail("expected quote, got \(blocks[0])")
        }
        XCTAssertEqual(String(attr.characters), "quoted line")
    }

    func test_thematicBreakRendersAsDivider() throws {
        let project = try makeProject()
        let text = "para one\n\n---\n\npara two"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 3, "got \(blocks)")
        XCTAssertEqual(plainText(blocks[0]), "para one")
        guard case .divider = blocks[1] else { return XCTFail("expected divider, got \(blocks[1])") }
        XCTAssertEqual(plainText(blocks[2]), "para two")
    }
}

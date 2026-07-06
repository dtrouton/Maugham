import XCTest
import AppKit
@testable import Maugham

/// Audit A4: `ResearchNotePreviewPane` used to turn every non-empty line into
/// its own `.paragraph` block, so hard-wrapped prose rendered as stacked line
/// fragments instead of flowing paragraphs. `parse` accumulates consecutive
/// non-empty, non-heading, non-solo-image lines and joins them with a single
/// space; a blank line, heading, solo image, or end of text flushes the buffer.
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
        XCTAssertEqual(plainText(blocks[0]), "line one line two")
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
        XCTAssertEqual(plainText(blocks[0]), "line one alt line two")
    }

    func test_endOfTextFlushesTrailingParagraph() throws {
        let project = try makeProject()
        let text = "only one\nwrapped line"
        let blocks = ResearchNotePreviewPane.parse(
            text: text, notePath: "research/sarah.md", projectURL: project)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(plainText(blocks[0]), "only one wrapped line")
    }
}

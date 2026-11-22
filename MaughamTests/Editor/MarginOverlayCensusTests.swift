import XCTest
@testable import Maugham

/// **The margin carries no model content** (shell p5 Task 2; ADR 0027 §1 as
/// amended 2026-11-22). Two censuses over the source:
///
/// 1. The overlay file draws no string: no text-drawing call of any kind.
/// 2. What is drawn beside the text — the margin's dots and the review
///    render's cards — asks ONE predicate, `NoteOwner.isAPersons`, through
///    `MarginMarks.drawnBesideTheText`: no other production file reads the
///    predicate, and every write of the review render's set and its pull
///    goes through `EditorHost.reviewRenderSet`.
final class MarginOverlayCensusTests: XCTestCase {

    private static let overlay = "Maugham/Editor/MarginOverlayView.swift"
    private static let marks = "Maugham/Editor/MarginMarks.swift"
    private static let host = "Maugham/Views/EditorHost.swift"

    /// Calls that draw words, in code (comments and strings masked).
    private static let textDrawing = [
        "draw(at:", "draw(in:", "draw(with:", "drawText", "NSAttributedString", "AttributedString(",
        "Text(", "CATextLayer", "NSTextField", "NSTextView(", "NSString(", ".string(", "drawGlyphs",
        "showGlyphs", "CTLine", "CTFrame",
    ]

    private static func drawsText(_ masked: [UInt8]) -> [String] {
        let code = String(decoding: masked, as: UTF8.self)
        return textDrawing.filter { code.contains($0) }
    }

    func test_theMarginOverlayDrawsNoString() throws {
        let real = try SourceTree.checkedMask(SourceTree.read(Self.overlay), path: Self.overlay)
        XCTAssertTrue(String(decoding: real, as: UTF8.self).contains("override func draw("),
                      "the control: the real overlay draws, and is read")
        XCTAssertEqual(Self.drawsText(real), [], "the overlay draws positions, never words")

        let planted = SourceTree.mask("""
            override func draw(_ dirtyRect: NSRect) {
                (mark.body as NSString).draw(at: point, withAttributes: [:])
            }
            """)
        XCTAssertEqual(Self.drawsText(planted), ["draw(at:"], "a planted offender is caught")
        let comment = SourceTree.mask("""
            // never NSAttributedString or draw(at:) here
            let label = "Text(\\(name))"
            """)
        XCTAssertEqual(Self.drawsText(comment), [], "a comment or a string is not a call")
    }

    /// One predicate decides what is drawn beside the text.
    func test_whatIsDrawnBesideTheTextAsksOnePredicate() throws {
        var readers: [String] = []
        for root in SourceTree.productionRoots {
            for file in try SourceTree.maskedSources(under: root)
            where String(decoding: file.masked, as: UTF8.self).contains(".isAPersons") {
                readers.append(file.path)
            }
        }
        XCTAssertEqual(readers, [Self.marks], "the predicate is read in the margin's file alone")
        let marksCode = String(decoding: try SourceTree.checkedMask(
            SourceTree.read(Self.marks), path: Self.marks), as: UTF8.self)
        XCTAssertTrue(marksCode.contains("drawnBesideTheText(notes"),
                      "the dots come through the one filter")

        let hostCode = String(decoding: try SourceTree.checkedMask(
            SourceTree.read(Self.host), path: Self.host), as: UTF8.self)
        XCTAssertGreaterThan(Self.renderWrites(hostCode).count, 3,
                             "the control: EditorHost's pushes and pull are in the population")
        XCTAssertEqual(Self.unfilteredRenderWrites(hostCode), [],
                       "every write of the review render's set reads `reviewRenderSet`")
        XCTAssertTrue(hostCode.contains("MarginMarks.drawnBesideTheText("),
                      "and `reviewRenderSet` is the one filter")

        // Every other production writer of the control's set, by name — the
        // editor's own files carry it one way and produce none.
        var elsewhere: [String] = []
        for root in SourceTree.productionRoots {
            for file in try SourceTree.maskedSources(under: root)
            where file.path != Self.host && !file.path.hasPrefix("Maugham/Editor/") {
                let code = String(decoding: file.masked, as: UTF8.self)
                if code.contains("control.reviewAnnotations =") || code.contains("reviewAnnotationsProvider:") {
                    elsewhere.append(file.path)
                }
            }
        }
        XCTAssertEqual(elsewhere, [], "the review render's set is written by EditorHost alone")

        let planted = """
            control.reviewAnnotations = doc.annotations(filter: AnnotationFilter(statuses: [.open]))

            reviewAnnotationsProvider: { Self.reviewRenderSet(doc) },
            """
        XCTAssertEqual(Self.unfilteredRenderWrites(planted).count, 1,
                       "a planted unfiltered push is caught; the filtered pull is the control")
    }

    /// The lines that write the render's set: a push into the control, the
    /// pull's closure, and their continuation lines up to the value.
    private static func renderWrites(_ code: String) -> [String] {
        let lines = code.components(separatedBy: "\n")
        var writes: [String] = []
        for (index, line) in lines.enumerated()
        where line.contains("control.reviewAnnotations =") || line.contains("reviewAnnotationsProvider:") {
            writes.append(lines[index...].prefix(2).joined(separator: "\n"))
        }
        return writes
    }

    private static func unfilteredRenderWrites(_ code: String) -> [String] {
        renderWrites(code).filter { !$0.contains("reviewRenderSet(") }
    }

    /// **To resolve's selection reaches the margin with one writer**: the
    /// window's `resolveSelection` is assigned in one place, the closure
    /// `RightColumn` hands To resolve, and To resolve publishes what it shows
    /// on every change, from its first.
    func test_theSelectionTheTicksFollowHasOneWriter() throws {
        var writers: [String] = []
        for root in SourceTree.productionRoots {
            for file in try SourceTree.maskedSources(under: root) {
                let code = String(decoding: file.masked, as: UTF8.self)
                writers += Self.selectionWrites(code).map { "\(file.path): \($0)" }
            }
        }
        XCTAssertEqual(writers.count, 1, "\(writers)")
        XCTAssertTrue(writers.first?.contains("onResolveSelectionShown: { resolveSelection = $0 }") == true,
                      "the one write is the published value")

        let pane = "Maugham/Views/Resolve/ResolvePane.swift"
        let paneCode = String(decoding: try SourceTree.checkedMask(SourceTree.read(pane), path: pane),
                              as: UTF8.self)
        XCTAssertTrue(paneCode.contains(".onChange(of: shownSelection, initial: true) { _, shown in onSelectionShown(shown) }"),
                      "To resolve publishes what it shows, from its first value")

        let planted = """
            onResolveSelectionShown: { resolveSelection = $0 },
            .onAppear { resolveSelection = [] }
            """
        XCTAssertEqual(Self.selectionWrites(planted).count, 2, "a second writer is caught")
    }

    private static func selectionWrites(_ code: String) -> [String] {
        code.components(separatedBy: "\n").filter { $0.contains("resolveSelection = ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

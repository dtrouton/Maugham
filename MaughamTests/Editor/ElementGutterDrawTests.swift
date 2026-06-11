import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

@MainActor
final class ElementGutterDrawTests: XCTestCase {

    private func script(_ text: String) -> FountainScript {
        FountainTokenizer().parse(text)
    }

    // The visible-range selector returns exactly the labeled lines whose
    // ranges intersect the visible character range — equivalence vs the
    // brute-force full scan. An empty window selects nothing.
    func test_visibleSelection_matchesBruteForce() {
        let s = script((0..<400).map { i in
            i % 5 == 0 ? "INT. SCENE \(i) - DAY" : "Action line \(i)."
        }.joined(separator: "\n\n"))
        let full = s.lines.enumerated().filter {
            ElementGutterView.abbreviation(for: $0.element.element) != nil
        }.map(\.offset)
        // Several visible windows, incl. empty, head, mid, tail, and all.
        let totalLen = s.lines.last.map { NSMaxRange($0.range) } ?? 0
        for window in [NSRange(location: 0, length: 0),
                       NSRange(location: 0, length: totalLen / 10),
                       NSRange(location: totalLen / 2, length: totalLen / 10),
                       NSRange(location: max(0, totalLen - 50), length: 50),
                       NSRange(location: 0, length: totalLen)] {
            let selected = ElementGutterView.labeledLineIndices(
                in: s, intersecting: window)
            let expected = full.filter {
                NSIntersectionRange(s.lines[$0].range, window).length > 0
            }
            XCTAssertEqual(selected, expected, "window \(window)")
        }
    }

    // Binary-search bounds: first/last line exactly at window edges included.
    func test_visibleSelection_edgeLines() {
        let s = script("INT. A - DAY\n\nAction.\n\nINT. B - DAY\n\nAction.")
        let second = s.lines.first { $0.content.contains("B") }!
        let window = NSRange(location: second.range.location, length: 1)
        let selected = ElementGutterView.labeledLineIndices(in: s, intersecting: window)
        XCTAssertTrue(selected.contains(s.lines.firstIndex(of: second)!))
    }

    // Label cache: same (element, pointSize, color) returns the cached
    // instance; a different pointSize is a different entry; a different
    // color (theme/appearance change) is a different entry (no stale color).
    func test_labelCache() {
        let cache = ElementGutterView.LabelCache()
        let a1 = cache.attributedLabel(for: .sceneHeading, pointSize: 13,
                                       color: .black)
        let a2 = cache.attributedLabel(for: .sceneHeading, pointSize: 13,
                                       color: .black)
        XCTAssertTrue(a1 === a2, "second lookup must be the cached instance")

        let fresh = cache.attributedLabel(for: .sceneHeading, pointSize: 14,
                                          color: .black)
        XCTAssertFalse(a1 === fresh, "different pointSize is a different entry")

        let recolored = cache.attributedLabel(for: .sceneHeading, pointSize: 13,
                                              color: .red)
        XCTAssertFalse(a1 === recolored, "different color is a different entry")
    }
}

import XCTest
import MaughamCore
@testable import MaughamPhone

/// The iOS half of the cross-surface `ScreenplayEmphasis` contract (sibling in
/// `MaughamTests` covers the Mac editor). Asserts the SwiftUI reader's
/// `FountainStyler` applies the same bold/italic/underline the contract
/// declares, so the two surfaces can't silently drift and a new
/// `ScreenplayElement` is forced to be styled here too, not just on the Mac.
final class ScreenplayEmphasisContractTests: XCTestCase {
    private let allElements: [ScreenplayElement] = [
        .action, .sceneHeading, .character, .dialogue, .parenthetical,
        .transition, .centered, .lyric, .section(level: 1), .synopsis,
        .pageBreak, .boneyard, .note, .titlePage,
    ]

    private func line(_ element: ScreenplayElement) -> FountainLine {
        FountainLine(
            range: NSRange(location: 0, length: 1), element: element,
            content: "Sample", isForced: false, sourceCase: .mixed)
    }

    func test_fountainStyler_honoursEmphasisContract() {
        for element in allElements {
            guard let expected = ScreenplayEmphasis.contract(for: element) else {
                continue  // intentionally surface-specific — no assertion
            }
            let style = FountainStyler.style(for: line(element))
            let actual = ScreenplayEmphasis(
                bold: style.weight == .bold, italic: style.italic,
                underline: style.underline)
            XCTAssertEqual(
                actual, expected,
                "FountainStyler emphasis for \(element) diverged from the ScreenplayEmphasis contract")
        }
    }
}

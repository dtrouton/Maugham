import XCTest
import MaughamCore
@testable import MaughamPhone

/// The iOS half of the cross-surface `ScreenplayUppercase` display-uppercase
/// contract.
///
/// Asserts that `FountainStyler.style(for:).uppercased` matches
/// `ScreenplayUppercase.shouldDisplayUppercase(_:)` for every
/// `ScreenplayElement`. This pins the phone renderer to the shared decision
/// and ensures a new element is classified before it can silently default to
/// as-typed rendering.
///
/// The Mac editor currently defers display-uppercase (option-A fallback,
/// CLAUDE.md), so there is no corresponding Mac contract test asserting
/// uppercase. If the Mac implements it, it will consume
/// `ScreenplayUppercase.shouldDisplayUppercase` and a Mac test will be added
/// then.
final class ScreenplayUppercaseContractTests: XCTestCase {
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

    func test_fountainStyler_honoursUppercaseContract() {
        for element in allElements {
            let expected = ScreenplayUppercase.shouldDisplayUppercase(element)
            let actual   = FountainStyler.style(for: line(element)).uppercased
            XCTAssertEqual(
                actual, expected,
                "FountainStyler.uppercased for \(element) (\(actual)) " +
                "diverged from ScreenplayUppercase.shouldDisplayUppercase (\(expected))")
        }
    }
}

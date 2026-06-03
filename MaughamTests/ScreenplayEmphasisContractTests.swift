import XCTest
import MaughamCore
import AppKit
@testable import Maugham

/// The Mac half of the cross-surface `ScreenplayEmphasis` contract. Its sibling
/// lives in `MaughamPhoneTests` for the iOS reader; together they guarantee that
/// the elements which *should* read the same (bold/italic/underline) DO read
/// the same on both the AppKit editor and the SwiftUI reader, and that adding a
/// new `ScreenplayElement` forces a decision for both surfaces (the exhaustive
/// switch in `ScreenplayEmphasis.contract(for:)` stops compiling otherwise).
final class ScreenplayEmphasisContractTests: XCTestCase {
    private let mode = ScreenplayMode()

    /// One representative instance of every `ScreenplayElement` case. If a new
    /// case is added, this list (and the contract switch) must grow with it.
    private let allElements: [ScreenplayElement] = [
        .action, .sceneHeading, .character, .dialogue, .parenthetical,
        .transition, .centered, .lyric, .section(level: 1), .synopsis,
        .pageBreak, .boneyard, .note, .titlePage,
    ]

    func test_screenplayMode_honoursEmphasisContract() {
        for element in allElements {
            guard let expected = ScreenplayEmphasis.contract(for: element) else {
                continue  // intentionally surface-specific — no assertion
            }
            let actual = mode.contractEmphasis(for: element)
            XCTAssertEqual(
                actual, expected,
                "ScreenplayMode emphasis for \(element) diverged from the ScreenplayEmphasis contract")
        }
    }
}

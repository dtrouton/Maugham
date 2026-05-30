import XCTest
import SwiftUI
@testable import MaughamPhone

/// The renderer's only pure, non-rendering piece: mapping the platform-agnostic
/// `FountainLineStyle.Align` to SwiftUI's `Alignment` / `TextAlignment`. The rest
/// of `DocumentReaderView` / `FountainSemanticRenderer` is interactive
/// download/render that can't be meaningfully unit-tested here.
final class FountainAlignMapperTests: XCTestCase {
    func test_frameAlignment_mapsEachCase() {
        XCTAssertEqual(FountainAlignMapper.frameAlignment(.leading), .leading)
        XCTAssertEqual(FountainAlignMapper.frameAlignment(.center), .center)
        XCTAssertEqual(FountainAlignMapper.frameAlignment(.trailing), .trailing)
    }

    func test_textAlignment_mapsEachCase() {
        XCTAssertEqual(FountainAlignMapper.textAlignment(.leading), .leading)
        XCTAssertEqual(FountainAlignMapper.textAlignment(.center), .center)
        XCTAssertEqual(FountainAlignMapper.textAlignment(.trailing), .trailing)
    }
}

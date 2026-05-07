import XCTest
@testable import Maugham

final class WritingModeFactoryTests: XCTestCase {

    func test_mdFile_returnsProseMode() {
        let mode = WritingModeFactory.mode(for: "manuscript/01-chapter-1.md")
        XCTAssertTrue(mode is ProseMode)
    }

    func test_fountainFile_returnsScreenplayMode() {
        let mode = WritingModeFactory.mode(for: "manuscript/01-scene-1.fountain")
        XCTAssertTrue(mode is ScreenplayMode)
    }

    func test_unknownExtension_defaultsToProseMode() {
        let mode = WritingModeFactory.mode(for: "manuscript/notes.txt")
        XCTAssertTrue(mode is ProseMode)
    }

    func test_typographyFor_mdFile_usesProseDefaults() {
        let typography = WritingModeFactory.defaultTypography(
            for: "manuscript/01-chapter-1.md")
        XCTAssertEqual(typography.fontFamily, "Iowan Old Style")
    }

    func test_typographyFor_fountainFile_usesScreenplayDefaults() {
        let typography = WritingModeFactory.defaultTypography(
            for: "manuscript/01-scene-1.fountain")
        XCTAssertEqual(typography.fontFamily, "JetBrains Mono")
    }
}

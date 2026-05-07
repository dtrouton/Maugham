import XCTest
@testable import Maugham

final class TypographySettingsTests: XCTestCase {
    func test_defaults_matchSpec() {
        let s = TypographySettings.defaults
        XCTAssertEqual(s.fontFamily, "Iowan Old Style")
        XCTAssertEqual(s.fontSize, 17)
        XCTAssertEqual(s.lineHeightMultiplier, 1.7, accuracy: 0.001)
        XCTAssertEqual(s.pageWidthCharacters, 70)
        XCTAssertEqual(s.paragraphSpacingMultiplier, 0.6, accuracy: 0.001)
        XCTAssertTrue(s.smartQuotes)
        XCTAssertTrue(s.emDashAutoReplace)
        XCTAssertTrue(s.ellipsisAutoReplace)
    }

    func test_codable_roundTrips() throws {
        let s = TypographySettings(
            fontFamily: "New York",
            fontSize: 19,
            lineHeightMultiplier: 1.6,
            pageWidthCharacters: 80,
            paragraphSpacingMultiplier: 0.8,
            smartQuotes: false,
            emDashAutoReplace: false,
            ellipsisAutoReplace: false
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(TypographySettings.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    func test_curatedFonts_includesExpectedFamilies() {
        let names = TypographySettings.curatedFonts.map(\.fontName)
        XCTAssertTrue(names.contains("Iowan Old Style"))
        XCTAssertTrue(names.contains("New York"))
        XCTAssertTrue(names.contains("Charter"))
    }
}

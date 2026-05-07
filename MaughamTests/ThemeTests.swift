import XCTest
import AppKit
@testable import Maugham

final class ThemeTests: XCTestCase {
    func test_allCases_containsThreeBuiltinsPlusFollowSystem() {
        XCTAssertEqual(Set(Theme.allCases), [.light, .dark, .sepia, .followSystem])
    }

    func test_palette_lightHasWhiteBackground() {
        XCTAssertEqual(Theme.light.palette.background, NSColor(rgbHex: 0xFFFFFF))
    }

    func test_palette_darkHasDarkBackground() {
        XCTAssertEqual(Theme.dark.palette.background, NSColor(rgbHex: 0x1E1E1E))
    }

    func test_palette_sepiaHasPaperBackground() {
        XCTAssertEqual(Theme.sepia.palette.background, NSColor(rgbHex: 0xFBF0D9))
    }

    func test_followSystem_resolvesToLightOrDark() {
        let resolved = Theme.followSystem.resolved(systemAppearanceIsDark: false)
        XCTAssertEqual(resolved, .light)
        let resolvedDark = Theme.followSystem.resolved(systemAppearanceIsDark: true)
        XCTAssertEqual(resolvedDark, .dark)
    }

    func test_codable_roundTripsRawValues() throws {
        for theme in Theme.allCases {
            let data = try JSONEncoder().encode(theme)
            let decoded = try JSONDecoder().decode(Theme.self, from: data)
            XCTAssertEqual(decoded, theme)
        }
    }
}

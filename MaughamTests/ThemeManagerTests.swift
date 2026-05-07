import XCTest
@testable import Maugham

@MainActor
final class ThemeManagerTests: XCTestCase {
    var defaults: UserDefaults!
    var manager: ThemeManager!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "ThemeManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        manager = ThemeManager(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults = nil
        manager = nil
        try await super.tearDown()
    }

    func test_freshManager_returnsDefaults() {
        XCTAssertEqual(manager.theme, .followSystem)
        XCTAssertEqual(manager.typography, .defaults)
    }

    func test_themeMutation_persistsAndIsObservable() {
        manager.theme = .sepia
        let other = ThemeManager(defaults: defaults)
        XCTAssertEqual(other.theme, .sepia)
    }

    func test_typographyMutation_persists() {
        var t = TypographySettings.defaults
        t.fontSize = 22
        manager.typography = t
        let other = ThemeManager(defaults: defaults)
        XCTAssertEqual(other.typography.fontSize, 22)
    }

    func test_corruptStoredData_fallsBackToDefaults() {
        defaults.set("not json", forKey: "maugham.typography")
        let m = ThemeManager(defaults: defaults)
        XCTAssertEqual(m.typography, .defaults)
    }
}

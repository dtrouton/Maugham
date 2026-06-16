import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class UserPreferencesTests: XCTestCase {
    var defaults: UserDefaults!
    var manager: UserPreferences!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "UserPreferencesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        manager = UserPreferences(defaults: defaults)
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
        let other = UserPreferences(defaults: defaults)
        XCTAssertEqual(other.theme, .sepia)
    }

    func test_typographyMutation_persists() {
        var t = TypographySettings.defaults
        t.fontSize = 22
        manager.typography = t
        let other = UserPreferences(defaults: defaults)
        XCTAssertEqual(other.typography.fontSize, 22)
    }

    func test_corruptStoredData_fallsBackToDefaults() {
        defaults.set("not json", forKey: "maugham.typography")
        let m = UserPreferences(defaults: defaults)
        XCTAssertEqual(m.typography, .defaults)
    }

    func test_freshManager_focusPrefsHaveExpectedDefaults() {
        XCTAssertFalse(manager.typewriterScroll)
        XCTAssertFalse(manager.sentenceFocus)
        XCTAssertFalse(manager.paragraphFocus)
        XCTAssertTrue(manager.goalIndicatorsVisible)
    }

    func test_typewriterScrollMutation_persists() {
        manager.typewriterScroll = true
        let other = UserPreferences(defaults: defaults)
        XCTAssertTrue(other.typewriterScroll)
    }

    func test_sentenceFocusMutation_persists() {
        manager.sentenceFocus = true
        let other = UserPreferences(defaults: defaults)
        XCTAssertTrue(other.sentenceFocus)
    }

    func test_paragraphFocusMutation_persists() {
        manager.paragraphFocus = true
        let other = UserPreferences(defaults: defaults)
        XCTAssertTrue(other.paragraphFocus)
    }

    func test_goalIndicatorsMutation_persists() {
        manager.goalIndicatorsVisible = false
        let other = UserPreferences(defaults: defaults)
        XCTAssertFalse(other.goalIndicatorsVisible)
    }

    func test_hasCompletedWelcome_defaultsFalseAndPersists() {
        let suite = "test-welcome-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = UserPreferences(defaults: defaults)
        XCTAssertFalse(prefs.hasCompletedWelcome)
        prefs.hasCompletedWelcome = true

        let reloaded = UserPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.hasCompletedWelcome)
    }
}

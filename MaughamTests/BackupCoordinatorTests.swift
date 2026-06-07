import XCTest
@testable import Maugham

@MainActor
final class BackupCoordinatorTests: XCTestCase {
    func test_userPreferences_persistsBackupDestinations() {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let cfg = BackupDestinationConfig(
            id: "d1", displayName: "Local", bookmark: Data([1, 2, 3]), retention: 10)
        do {
            let prefs = UserPreferences(defaults: defaults)
            prefs.backupDestinations = [cfg]
        }
        // A fresh instance on the same defaults must reload it.
        let reloaded = UserPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.backupDestinations, [cfg])
    }
}

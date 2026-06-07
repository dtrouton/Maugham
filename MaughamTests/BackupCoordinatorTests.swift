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

    func test_resolveDestinations_roundTripsRealFolderBookmark() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let cfg = BackupDestinationConfig(id: "d1", displayName: "L", bookmark: bookmark, retention: 7)

        let resolved = BackupCoordinator.resolveDestinations([cfg])

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].retention, 7)
        XCTAssertEqual(resolved[0].url.resolvingSymlinksInPath().path, dir.resolvingSymlinksInPath().path)
    }

    func test_resolveDestinations_dropsUnresolvableBookmarks() {
        let cfg = BackupDestinationConfig(id: "bad", displayName: "X", bookmark: Data([9, 9, 9]), retention: 3)
        XCTAssertTrue(BackupCoordinator.resolveDestinations([cfg]).isEmpty)
    }
}

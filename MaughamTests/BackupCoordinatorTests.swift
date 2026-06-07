import XCTest
@testable import Maugham
import MaughamCore

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

    private func tempProjectWithOps() throws -> URL {
        let proj = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: proj.appendingPathComponent(".maugham/ops"), withIntermediateDirectories: true)
        // a valid op line so the project is non-empty + integrity-clean
        let op = Op(opId: "01ABC", docId: "doc-0f0f0f0f", at: Date(timeIntervalSince1970: 0),
                    device: "macA", session: "s", kind: .checkpoint, changes: [], sequence: nil, provenance: nil)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        let line = String(data: try enc.encode(op), encoding: .utf8)!
        try (line + "\n").write(to: proj.appendingPathComponent(".maugham/ops/doc-0f0f0f0f.macA.jsonl"), atomically: true, encoding: .utf8)
        return proj
    }
    private func destDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dst-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func test_backupNow_writesGenerationAndRecordsStatus() async throws {
        let proj = try tempProjectWithOps(); let dest = destDir()
        defer { [proj, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        let coordinator = BackupCoordinator()
        coordinator.destinations = [BackupDestination(url: dest, retention: 5)]

        await coordinator.backupNow(projectURL: proj, generationId: "01GEN", at: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["01GEN"])
        if case .ok = coordinator.lastResult { } else { XCTFail("expected ok, got \(String(describing: coordinator.lastResult))") }
    }

    func test_backupNow_abortsAndFlagsWhenSourceCorrupt() async throws {
        let proj = try tempProjectWithOps(); let dest = destDir()
        defer { [proj, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        // Corrupt the op log so ProjectIntegrity.check is unhealthy.
        try "GARBAGE NOT JSON\n".write(to: proj.appendingPathComponent(".maugham/ops/doc-0f0f0f0f.macA.jsonl"), atomically: true, encoding: .utf8)
        let coordinator = BackupCoordinator()
        coordinator.destinations = [BackupDestination(url: dest, retention: 5)]

        await coordinator.backupNow(projectURL: proj, generationId: "01GEN", at: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(try BackupWriter.generationIds(at: dest), [])  // nothing backed up
        if case .integrityFailed = coordinator.lastResult { } else { XCTFail("expected integrityFailed, got \(String(describing: coordinator.lastResult))") }
    }
}

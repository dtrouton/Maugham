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

    /// Writes a valid `project.maugham.json` carrying `id` into `proj`, so
    /// `BackupCoordinator.projectKey` reads the minted id instead of falling
    /// back to the folder name.
    private func writeManifest(id: String, into proj: URL) throws {
        let manifest = ProjectManifest(
            id: id, type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [])
        try ProjectManifest.makeEncoder().encode(manifest)
            .write(to: proj.appendingPathComponent(ProjectManifest.fileName))
    }

    func test_backupNow_writesGenerationAndRecordsStatus() async throws {
        let proj = try tempProjectWithOps(); let dest = destDir()
        defer { [proj, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        let coordinator = BackupCoordinator()
        coordinator.destinations = [BackupDestination(url: dest, retention: 5)]

        await coordinator.backupNow(projectURL: proj, generationId: "01GEN", at: Date(timeIntervalSince1970: 1))

        // No manifest → key falls back to the project folder name; generation lives
        // under <dest>/<projectFolderName>/, not flat under <dest>.
        XCTAssertEqual(try BackupWriter.generationIds(at: dest.appendingPathComponent(proj.lastPathComponent)), ["01GEN"])
        if case .ok = coordinator.lastResult(for: proj) { } else { XCTFail("expected ok, got \(String(describing: coordinator.lastResult(for: proj)))") }
    }

    func test_backupNow_keysGenerationsUnderProjectSubfolder() async throws {
        let proj = try tempProjectWithOps()  // existing helper
        // Give the project a manifest with a known id.
        try writeManifest(id: "proj-AAAA", into: proj)
        let dest = destDir()                  // existing helper
        defer { [proj, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        let coordinator = BackupCoordinator()
        coordinator.destinations = [BackupDestination(url: dest, retention: 5)]

        await coordinator.backupNow(projectURL: proj, generationId: "01GEN", at: Date(timeIntervalSince1970: 1))

        // Generation lives under <dest>/<manifest.id>/, NOT flat under <dest>.
        XCTAssertEqual(try BackupWriter.generationIds(at: dest.appendingPathComponent("proj-AAAA")), ["01GEN"])
        // The only entry directly under <dest> is the project-key subfolder — the
        // generation id itself never sits flat under <dest>.
        XCTAssertEqual(try BackupWriter.generationIds(at: dest), ["proj-AAAA"])
        XCTAssertFalse(try BackupWriter.generationIds(at: dest).contains("01GEN"))
    }

    func test_generationsForProject_listsOnlyThatProject() async throws {
        let projA = try tempProjectWithOps()
        try writeManifest(id: "proj-A", into: projA)
        let projB = try tempProjectWithOps()
        try writeManifest(id: "proj-B", into: projB)
        let dest = destDir()
        defer { [projA, projB, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        let coordinator = BackupCoordinator()
        coordinator.destinations = [BackupDestination(url: dest, retention: 5)]
        await coordinator.backupNow(projectURL: projA, generationId: "01A", at: Date(timeIntervalSince1970: 1))
        await coordinator.backupNow(projectURL: projB, generationId: "01B", at: Date(timeIntervalSince1970: 2))

        // Same shared destination, but each project sees only its own generations.
        XCTAssertEqual(coordinator.generations(forProject: projA).map(\.id), ["01A"])
        XCTAssertEqual(coordinator.generations(forProject: projB).map(\.id), ["01B"])
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
        if case .integrityFailed = coordinator.lastResult(for: proj) { } else { XCTFail("expected integrityFailed, got \(String(describing: coordinator.lastResult(for: proj)))") }
    }

    // Regression: a corrupt project's integrity failure must NOT bleed into another
    // open project's result (the coordinator is one app-wide object; results are
    // keyed per project so the banner only lights on the failing project's window).
    @MainActor
    func test_results_arePerProject_failureDoesNotBleed() async throws {
        let good = try tempProjectWithOps()
        let bad = try tempProjectWithOps()
        try "GARBAGE NOT JSON\n".write(
            to: bad.appendingPathComponent(".maugham/ops/doc-0f0f0f0f.macA.jsonl"),
            atomically: true, encoding: .utf8)
        let dest = destDir()
        defer { [good, bad, dest].forEach { try? FileManager.default.removeItem(at: $0) } }
        let coordinator = BackupCoordinator()
        coordinator.destinations = [BackupDestination(url: dest, retention: 5)]

        await coordinator.backupNow(projectURL: good, generationId: "01G", at: Date(timeIntervalSince1970: 1))
        await coordinator.backupNow(projectURL: bad, generationId: "01B", at: Date(timeIntervalSince1970: 2))

        if case .ok = coordinator.lastResult(for: good) {} else {
            XCTFail("good project should be .ok, got \(coordinator.lastResult(for: good))")
        }
        if case .integrityFailed = coordinator.lastResult(for: bad) {} else {
            XCTFail("bad project should be .integrityFailed, got \(coordinator.lastResult(for: bad))")
        }
    }
}

// MaughamTests/Stores/ManifestContentFloorTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **A schema-9 book that gains v10 content reaches disk at 10, through the
/// real save door** (report foundations, Task 5 fix round 1, M3).
///
/// `ProjectManifest.encodeForDisk` is pinned as a pure value in Core; this
/// pins that `ProjectStore.saveManifest` — both its coordinated path and the
/// legacy direct one — actually goes through it, and that the live copy
/// follows the file, so the store does not spend the session holding a number
/// lower than the one on disk.
@MainActor
final class ManifestContentFloorTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        let (dir, _) = try makeTestProject(prefix: "FLOOR", initialMd: "Hello.\n")
        projectURL = dir
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.schemaVersion = 9
        try ProjectManifest.makeEncoder().encode(manifest).write(to: manifestURL)
    }

    override func tearDown() async throws {
        if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
        projectURL = nil
    }

    private var manifestURL: URL {
        projectURL.appendingPathComponent(ProjectManifest.fileName)
    }

    private func schemaOnDisk() throws -> Int? {
        ProjectManifest.schemaVersion(ofFileAt: manifestURL)
    }

    func test_aProfileSavedThroughTheCoordinatedDoorReachesDiskAtTen() async throws {
        let store = try await DocumentStore.open(url: projectURL)
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        XCTAssertEqual(projectStore.manifest.schemaVersion, 9)

        projectStore.manifest.profile = .report
        try await projectStore.saveManifest()

        XCTAssertEqual(try schemaOnDisk(), 10)
        XCTAssertEqual(projectStore.manifest.schemaVersion, 10,
                       "the live copy follows the file it just wrote")
        await store.close()
    }

    func test_aProfileSavedThroughTheLegacyDirectPathReachesDiskAtTen() async throws {
        let projectStore = try await ProjectStore.load(from: projectURL)
        XCTAssertNil(projectStore.documentStore)

        projectStore.manifest.profile = .report
        try await projectStore.saveManifest()

        XCTAssertEqual(try schemaOnDisk(), 10)
        XCTAssertEqual(projectStore.manifest.schemaVersion, 10)
    }

    /// The other direction: the same save with no v10 content leaves 9.
    func test_aSaveWithNoV10ContentLeavesTheBookAtNine() async throws {
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.manifest.title = "Renamed"
        try await projectStore.saveManifest()

        XCTAssertEqual(try schemaOnDisk(), 9)
        XCTAssertEqual(projectStore.manifest.schemaVersion, 9)
    }
}

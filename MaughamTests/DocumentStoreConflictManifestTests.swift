import XCTest
@testable import Maugham

@MainActor
final class DocumentStoreConflictManifestTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_externalManifestNewer_preservesInMemoryAndReloads() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "Manifest", in: temp.url)
        let store = try await DocumentStore.open(url: url)

        // Write a NEWER manifest externally
        let project = try await ProjectStore.load(from: url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var manifest = project.manifest
        manifest.title = "Externally Renamed"
        manifest.modified = Date(timeIntervalSinceNow: 60)  // 1 minute in the future
        let externalData = try encoder.encode(manifest)
        let manifestURL = url.appendingPathComponent("project.maugham.json")
        try externalData.write(to: manifestURL, options: [.atomic])

        // Wait for presenter callback. Use polling for robustness.
        let conflictsDir = url.appendingPathComponent(".maugham/conflicts")
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            let files = (try? FileManager.default
                .contentsOfDirectory(atPath: conflictsDir.path)) ?? []
            if files.contains(where: { $0.hasPrefix("manifest-") }) {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let files = (try? FileManager.default
            .contentsOfDirectory(atPath: conflictsDir.path)) ?? []
        XCTAssertTrue(files.contains { $0.hasPrefix("manifest-") },
                      "expected manifest backup, got \(files)")
        await store.close()
    }
}

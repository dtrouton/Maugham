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

        // Drive the presenter-routing entry point DIRECTLY rather than waiting
        // for the OS NSFilePresenter callback to fire. The callback's delivery
        // is nondeterministic and unreliable in a headless CI run loop (this
        // test flaked the v0.4.0 release on a fresh runner: the event never
        // arrived inside the old 3s poll). `presenterDidChangeSubitem(at:)` is
        // exactly what `ProjectFolderPresenter` calls, so this still exercises
        // the real classify → manifest → archive-when-newer logic — only the
        // OS event delivery (Apple's behavior, not ours) is removed from the
        // test. `archiveManifestForConflict` writes synchronously, so the
        // backup exists immediately after the call.
        store.presenterDidChangeSubitem(at: manifestURL)

        let conflictsDir = url.appendingPathComponent(".maugham/conflicts")
        let files = (try? FileManager.default
            .contentsOfDirectory(atPath: conflictsDir.path)) ?? []
        XCTAssertTrue(files.contains { $0.hasPrefix("manifest-") },
                      "expected manifest backup, got \(files)")
        await store.close()
    }
}

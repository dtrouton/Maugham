import XCTest
@testable import Maugham

@MainActor
final class ProjectStoreTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() {
        super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    func test_load_readsManifestAndManuscript() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Loadable", in: temp.url)
        try "Hello world".write(to: url.appendingPathComponent("story.md"),
                                atomically: true, encoding: .utf8)

        let store = try await ProjectStore.load(from: url)
        XCTAssertEqual(store.manifest.title, "Loadable")
        XCTAssertEqual(store.manifest.type, .shortStory)
        XCTAssertEqual(store.manuscriptText, "Hello world")
        XCTAssertEqual(store.url, url)
    }

    func test_load_missingManifest_throws() async throws {
        let badURL = temp.url.appendingPathComponent("NotAProject")
        try FileManager.default.createDirectory(
            at: badURL, withIntermediateDirectories: true)

        do {
            _ = try await ProjectStore.load(from: badURL)
            XCTFail("expected throw")
        } catch ProjectStoreError.manifestNotFound {
            // ok
        }
    }

    func test_load_corruptManifest_throws() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Corrupt", in: temp.url)
        try "not valid json".write(
            to: url.appendingPathComponent("project.maugham.json"),
            atomically: true, encoding: .utf8)

        do {
            _ = try await ProjectStore.load(from: url)
            XCTFail("expected throw")
        } catch ProjectStoreError.manifestUnreadable {
            // ok
        }
    }

    func test_load_missingManuscript_treatsAsEmpty() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "NoStory", in: temp.url)
        try FileManager.default.removeItem(at: url.appendingPathComponent("story.md"))

        let store = try await ProjectStore.load(from: url)
        XCTAssertEqual(store.manuscriptText, "")
    }

    func test_save_writesManuscriptToDisk() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Savable", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        store.manuscriptText = "First sentence."
        try await store.save()

        let storyText = try String(contentsOf: url.appendingPathComponent("story.md"),
                                   encoding: .utf8)
        XCTAssertEqual(storyText, "First sentence.")
    }

    func test_save_updatesManifestModifiedDate() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Mod", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let originalModified = store.manifest.modified

        // ISO8601 round-trip truncates to second resolution, so we must wait
        // long enough to guarantee a different whole second on disk.
        try await Task.sleep(for: .milliseconds(1100))

        store.manuscriptText = "x"
        try await store.save()

        XCTAssertGreaterThan(store.manifest.modified, originalModified)

        // And the manifest on disk reflects it
        let data = try Data(contentsOf: url.appendingPathComponent("project.maugham.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode(ProjectManifest.self, from: data)
        XCTAssertEqual(onDisk.modified, store.manifest.modified)
    }

    func test_save_isAtomicForManifest() async throws {
        // We can't easily test atomicity directly, but we can verify the .tmp
        // file doesn't get left behind on a successful save.
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Atomic", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        try await store.save()

        let tmpURL = url.appendingPathComponent("project.maugham.json.tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))
    }
}

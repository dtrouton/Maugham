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
}

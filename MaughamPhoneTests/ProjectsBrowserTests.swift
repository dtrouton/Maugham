import XCTest
@testable import MaughamPhone
import MaughamCore

/// `UbiquitousDownloader` that treats every URL as already-local: the temp
/// files these tests write are real local files, not ubiquitous items. Its
/// `download` yields a single 1.0 then finishes, which drives
/// `DownloadCoordinator.ensureDownloaded` straight to `.downloaded` without
/// throwing — so `ProjectsBrowser` proceeds to the coordinated read.
private struct AlwaysLocalDownloader: UbiquitousDownloader {
    func fileSize(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
    }

    func download(at url: URL) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(1.0)
            continuation.finish()
        }
    }
}

@MainActor
final class ProjectsBrowserTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectsBrowserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Helpers

    /// Encode a real `ProjectManifest` into `<folder>/project.maugham.json` so
    /// the decoder config is matched by construction. Returns the folder url.
    @discardableResult
    private func makeProject(folder: String, id: String?, title: String) throws -> URL {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manifest = ProjectManifest(
            id: id,
            type: .novel,
            title: title,
            author: "Tester",
            created: Date(timeIntervalSince1970: 1_700_000_000),
            modified: Date(timeIntervalSince1970: 1_700_000_500),
            structure: [],
            research: [])

        // Match production's manifest encoder (ISO8601 dates) so the browser's
        // ISO8601 decoder round-trips.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: dir.appendingPathComponent("project.maugham.json"), options: [.atomic])
        return dir
    }

    private func makeBrowser() -> ProjectsBrowser {
        let coordinator = DownloadCoordinator(downloader: AlwaysLocalDownloader())
        return ProjectsBrowser(downloads: coordinator)
    }

    // MARK: - Tests

    func test_listsProjectsWithMintedIds() async throws {
        try makeProject(folder: "alpha", id: "ID-ALPHA", title: "Charlie")  // titles deliberately
        try makeProject(folder: "bravo", id: "ID-BRAVO", title: "alpha")    // out of folder order
        try makeProject(folder: "delta", id: "ID-DELTA", title: "Bravo")

        let browser = makeBrowser()
        await browser.refresh(root: root)

        XCTAssertNil(browser.loadError)
        XCTAssertEqual(browser.projects.count, 3)
        // Sorted by title, case-insensitively: alpha, Bravo, Charlie.
        XCTAssertEqual(browser.projects.map(\.manifest.title), ["alpha", "Bravo", "Charlie"])
        // Keyed by the minted ids; project(id:) resolves each.
        XCTAssertEqual(browser.project(id: "ID-ALPHA")?.manifest.title, "Charlie")
        XCTAssertEqual(browser.project(id: "ID-BRAVO")?.manifest.title, "alpha")
        XCTAssertEqual(browser.project(id: "ID-DELTA")?.manifest.title, "Bravo")
        XCTAssertNil(browser.project(id: "ID-MISSING"))
        XCTAssertTrue(browser.failures.isEmpty)
    }

    func test_idlessProjectGetsPathFallback() async throws {
        try makeProject(folder: "untouched-project", id: nil, title: "Untouched")

        let browser = makeBrowser()
        await browser.refresh(root: root)

        XCTAssertEqual(browser.projects.count, 1)
        // Folder-derived, "path:"-namespaced fallback so it never collides with
        // a real ULID and the project still appears.
        let fallbackId = "path:untouched-project"
        XCTAssertEqual(browser.projects.first?.id, fallbackId)
        XCTAssertEqual(browser.project(id: fallbackId)?.manifest.title, "Untouched")
    }

    func test_skipsUndecodableManifest_listsRest() async throws {
        try makeProject(folder: "good-one", id: "ID-GOOD", title: "Good")
        try makeProject(folder: "good-two", id: "ID-GOOD-2", title: "AlsoGood")

        // A folder with a garbage manifest — must be skipped into failures.
        let badDir = root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("{ not valid json at all".utf8)
            .write(to: badDir.appendingPathComponent("project.maugham.json"))

        let browser = makeBrowser()
        await browser.refresh(root: root)

        XCTAssertEqual(browser.projects.count, 2)
        XCTAssertEqual(Set(browser.projects.map(\.id)), ["ID-GOOD", "ID-GOOD-2"])
        XCTAssertNil(browser.loadError, "A single bad manifest is a per-project failure, not a root error")
        XCTAssertNotNil(browser.failures[badDir], "The bad project is recorded in failures")
    }

    func test_ignoresNonProjectDirs() async throws {
        try makeProject(folder: "real-project", id: "ID-REAL", title: "Real")

        // A directory with no manifest — ignored.
        let plainDir = root.appendingPathComponent("just-a-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: plainDir.appendingPathComponent("notes.txt"))

        // A loose file at the root — ignored.
        try Data("loose".utf8).write(to: root.appendingPathComponent("loose-file.txt"))

        let browser = makeBrowser()
        await browser.refresh(root: root)

        XCTAssertEqual(browser.projects.count, 1)
        XCTAssertEqual(browser.projects.first?.id, "ID-REAL")
        XCTAssertTrue(browser.failures.isEmpty)
    }

    func test_refresh_isIdempotent_andReplaces() async throws {
        try makeProject(folder: "p1", id: "ID-1", title: "One")
        try makeProject(folder: "p2", id: "ID-2", title: "Two")

        let browser = makeBrowser()
        await browser.refresh(root: root)
        XCTAssertEqual(browser.projects.count, 2)

        // Refresh again over the same root: list replaces, never duplicates.
        await browser.refresh(root: root)
        XCTAssertEqual(browser.projects.count, 2)
        XCTAssertEqual(browser.projects.map(\.id), ["ID-1", "ID-2"])

        // Removing a project and refreshing drops it (replace, not merge).
        try FileManager.default.removeItem(at: root.appendingPathComponent("p2"))
        await browser.refresh(root: root)
        XCTAssertEqual(browser.projects.map(\.id), ["ID-1"])
        XCTAssertNil(browser.project(id: "ID-2"))
    }
}

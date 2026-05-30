import XCTest
@testable import MaughamPhone
import MaughamCore

/// `UbiquitousDownloader` that reports every URL as already-current and a tiny
/// fixed size. Its `download` yields a single 1.0 then finishes, so any
/// `ensureDownloadedIfBudgetAllows` that the budget admits resolves instantly
/// without hitting a real ubiquitous container. Mirrors the `AlwaysLocalDownloader`
/// pattern from `ProjectsBrowserTests`.
private struct AlwaysLocalDownloader: UbiquitousDownloader {
    /// Tiny so the 50 MB cold-launch budget admits every op log under test.
    func fileSize(at url: URL) -> Int64? { 1 }

    func download(at url: URL) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(1.0)
            continuation.finish()
        }
    }
}

@MainActor
final class ColdLaunchDownloaderTests: XCTestCase {

    // MARK: - Helpers

    /// A `BrowsedProject` over a synthetic folder URL. The url need not exist;
    /// `prefetch` only enumerates op logs via the injected closure and sizes them
    /// via the (faked) downloader — neither touches the real folder here.
    private func makeProject(folder: String, id: String) -> BrowsedProject {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(folder, isDirectory: true)
        let manifest = ProjectManifest(
            id: id,
            type: .novel,
            title: folder,
            author: "Tester",
            created: Date(timeIntervalSince1970: 1_700_000_000),
            modified: Date(timeIntervalSince1970: 1_700_000_500),
            structure: [],
            research: [])
        return BrowsedProject(id: id, url: url, manifest: manifest)
    }

    private func opLogURLs(for project: BrowsedProject, count: Int) -> [URL] {
        let ops = project.url
            .appendingPathComponent(".maugham", isDirectory: true)
            .appendingPathComponent("ops", isDirectory: true)
        return (0..<count).map { ops.appendingPathComponent("d_doc\($0).jsonl") }
    }

    private func makeDownloader() -> ColdLaunchDownloaderTestDeps {
        let coordinator = DownloadCoordinator(downloader: AlwaysLocalDownloader())
        return ColdLaunchDownloaderTestDeps(coordinator: coordinator)
    }

    /// Bundles the shared coordinator so a test can both build a
    /// `ColdLaunchDownloader` and later inspect the coordinator's recorded state.
    private struct ColdLaunchDownloaderTestDeps {
        let coordinator: DownloadCoordinator
    }

    // MARK: - Tests

    /// Two recent projects, two op logs each → all four op-log URLs are attempted
    /// (returned), and the coordinator saw a download request for each (budget
    /// admitted them; tiny sizes fit the 50 MB cap → coordinator now tracks state
    /// for all four URLs).
    func test_prefetch_attemptsRecentProjectOpLogs() async {
        let p1 = makeProject(folder: "alpha", id: "ID-A")
        let p2 = makeProject(folder: "bravo", id: "ID-B")
        let p1Logs = opLogURLs(for: p1, count: 2)
        let p2Logs = opLogURLs(for: p2, count: 2)

        let deps = makeDownloader()
        let enumerate: (URL) -> [URL] = { folder in
            if folder == p1.url { return p1Logs }
            if folder == p2.url { return p2Logs }
            return []
        }
        let cold = ColdLaunchDownloader(
            downloads: deps.coordinator,
            io: .live,
            enumerateOpLogs: enumerate)

        let attempted = await cold.prefetch(recentProjects: [p1, p2])

        // All four op logs were attempted.
        XCTAssertEqual(Set(attempted), Set(p1Logs + p2Logs))
        XCTAssertEqual(attempted.count, 4)

        // The coordinator saw a budgeted request for each (its state map now has
        // an entry per URL — tiny sizes fit the budget, so each was started).
        let states = await deps.coordinator.states
        XCTAssertEqual(Set(states.keys), Set(p1Logs + p2Logs))
    }

    /// A project whose enumerateOpLogs yields nothing contributes no attempts and
    /// doesn't crash.
    func test_prefetch_skipsProjectsWithNoOps() async {
        let withOps = makeProject(folder: "has-ops", id: "ID-1")
        let withoutOps = makeProject(folder: "empty", id: "ID-2")
        let logs = opLogURLs(for: withOps, count: 2)

        let deps = makeDownloader()
        let enumerate: (URL) -> [URL] = { folder in
            folder == withOps.url ? logs : []
        }
        let cold = ColdLaunchDownloader(
            downloads: deps.coordinator,
            io: .live,
            enumerateOpLogs: enumerate)

        let attempted = await cold.prefetch(recentProjects: [withOps, withoutOps])

        // Only the project with op logs contributed.
        XCTAssertEqual(Set(attempted), Set(logs))
        XCTAssertEqual(attempted.count, 2)
    }

    /// Best-effort contract: an empty recent list (and a throwing enumerator)
    /// complete without propagating anything.
    func test_prefetch_isBestEffort_neverThrows() async {
        let deps = makeDownloader()

        // Empty recents → no attempts, no crash.
        let coldEmpty = ColdLaunchDownloader(
            downloads: deps.coordinator,
            io: .live,
            enumerateOpLogs: { _ in [] })
        let none = await coldEmpty.prefetch(recentProjects: [])
        XCTAssertTrue(none.isEmpty)

        // An enumerator that always returns [] for present projects also
        // contributes nothing without throwing — the closure can't throw, but
        // this guards the "no ops anywhere" path completing cleanly.
        let project = makeProject(folder: "p", id: "ID-X")
        let coldNoOps = ColdLaunchDownloader(
            downloads: deps.coordinator,
            io: .live,
            enumerateOpLogs: { _ in [] })
        let attempted = await coldNoOps.prefetch(recentProjects: [project])
        XCTAssertTrue(attempted.isEmpty)
    }
}

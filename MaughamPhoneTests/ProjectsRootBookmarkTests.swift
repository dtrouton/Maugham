import XCTest
@testable import MaughamPhone
import MaughamCore

// MARK: - Fake bookmark resolver

/// Programmable `BookmarkResolving` double. Each closure-backed knob lets a test
/// drive one leg of `ProjectsRoot`'s state machine without a real grant.
private final class FakeBookmarkResolver: BookmarkResolving, @unchecked Sendable {
    var resolveResult: () throws -> (url: URL, isStale: Bool)
    var makeBookmarkResult: () throws -> Data
    var startAccessingResult: (URL) -> Bool

    // Records the URL passed to makeBookmark so round-trip tests can confirm it.
    private(set) var lastMadeBookmarkURL: URL?
    // Ordered record of seam calls, so a test can assert ordering (on iOS
    // startAccessing must precede makeBookmark — see the regression test).
    private(set) var callOrder: [String] = []

    init(
        resolve: @escaping () throws -> (url: URL, isStale: Bool) = {
            (URL(fileURLWithPath: "/dev/null"), false)
        },
        makeBookmark: @escaping () throws -> Data = { Data([0x01, 0x02, 0x03]) },
        startAccessing: @escaping (URL) -> Bool = { _ in true }
    ) {
        self.resolveResult = resolve
        self.makeBookmarkResult = makeBookmark
        self.startAccessingResult = startAccessing
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) { try resolveResult() }
    func makeBookmark(for url: URL) throws -> Data {
        callOrder.append("makeBookmark")
        lastMadeBookmarkURL = url
        return try makeBookmarkResult()
    }
    func startAccessing(_ url: URL) -> Bool {
        callOrder.append("startAccessing")
        return startAccessingResult(url)
    }
}

private struct FakeResolveError: Error, LocalizedError {
    var errorDescription: String? { "boom-resolve" }
}

private struct FakeMakeError: Error {}

// MARK: - Tests

@MainActor
final class ProjectsRootBookmarkTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    // The variant-keyed key the production code actually writes under — assert
    // against the real key, not a duplicated literal.
    private var bookmarkKey: String { BuildVariant.current.bookmarkUserDefaultsKey }

    override func setUp() {
        super.setUp()
        suiteName = "ProjectsRootBookmarkTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_resolveOnLaunch_noBookmark_isNeeded() {
        let root = ProjectsRoot(defaults: defaults, resolver: FakeBookmarkResolver())
        root.resolveOnLaunch()

        XCTAssertEqual(root.picker, .needed)
        XCTAssertNil(root.rootURL)
    }

    func test_pick_persistsBookmark_setsRoot_andIdle() throws {
        let bytes = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let resolver = FakeBookmarkResolver(makeBookmark: { bytes })
        let root = ProjectsRoot(defaults: defaults, resolver: resolver)

        let picked = URL(fileURLWithPath: "/Users/x/iCloud/Projects")
        try root.pick(from: picked)

        XCTAssertEqual(root.rootURL, picked)
        XCTAssertEqual(root.picker, .idle)
        XCTAssertEqual(resolver.lastMadeBookmarkURL, picked, "bookmark must be minted for the picked URL")
        XCTAssertEqual(defaults.data(forKey: bookmarkKey), bytes,
                       "bookmark bytes must be persisted under the variant key")
    }

    func test_resolveOnLaunch_nonStale_restoresRoot() {
        // Seed any bookmark bytes so the launch path proceeds to resolve.
        defaults.set(Data([0x01]), forKey: bookmarkKey)

        let resolved = URL(fileURLWithPath: "/Users/x/iCloud/Projects")
        let resolver = FakeBookmarkResolver(resolve: { (resolved, false) })
        let root = ProjectsRoot(defaults: defaults, resolver: resolver)
        root.resolveOnLaunch()

        XCTAssertEqual(root.rootURL, resolved)
        XCTAssertNotEqual(root.picker, .stale)
        XCTAssertNotEqual(root.picker, .needed)
    }

    func test_resolveOnLaunch_stale_isStale_rootNil() {
        defaults.set(Data([0x01]), forKey: bookmarkKey)

        let resolved = URL(fileURLWithPath: "/Users/x/iCloud/Projects")
        let resolver = FakeBookmarkResolver(resolve: { (resolved, true) })  // stale
        let root = ProjectsRoot(defaults: defaults, resolver: resolver)
        root.resolveOnLaunch()

        XCTAssertEqual(root.picker, .stale)
        XCTAssertNil(root.rootURL, "a stale bookmark must not yield a usable root")
    }

    func test_resolveOnLaunch_startAccessingFalse_stillAdoptsFolder() {
        // `startAccessingSecurityScopedResource` returns false for URLs that
        // don't need scoping (already accessible) — NOT a denial. The folder
        // must still be adopted, or a non-scoped pick (e.g. the app's own
        // container, which bit us in simulator smoke) silently lists nothing.
        defaults.set(Data([0x01]), forKey: bookmarkKey)

        let resolved = URL(fileURLWithPath: "/Users/x/iCloud/Projects")
        let resolver = FakeBookmarkResolver(
            resolve: { (resolved, false) },
            startAccessing: { _ in false }
        )
        let root = ProjectsRoot(defaults: defaults, resolver: resolver)
        root.resolveOnLaunch()

        XCTAssertEqual(root.rootURL, resolved)
        XCTAssertEqual(root.picker, .idle)
    }

    func test_resolveOnLaunch_resolveThrows_isResolveFailed() {
        defaults.set(Data([0x01]), forKey: bookmarkKey)

        let resolver = FakeBookmarkResolver(resolve: { throw FakeResolveError() })
        let root = ProjectsRoot(defaults: defaults, resolver: resolver)
        root.resolveOnLaunch()

        XCTAssertEqual(root.picker, .resolveFailed("boom-resolve"))
        XCTAssertNil(root.rootURL)
    }

    /// Regression: on iOS a security-scoped URL from the document picker must have
    /// its scope ACTIVE before `bookmarkData()` reads it, or the sandbox treats the
    /// out-of-container iCloud path as non-existent and `makeBookmark` throws
    /// NSFileReadNoSuchFileError ("…doesn't exist"). So `pick` must call
    /// `startAccessing` BEFORE `makeBookmark`. (Found on the phone-v0.0.1 TestFlight
    /// build: "Couldn't open folder because it doesn't exist" right after picking;
    /// a debug build worked by luck because the picker grant was still active.)
    func test_pick_startsAccessBeforeMakingBookmark() throws {
        let resolver = FakeBookmarkResolver()
        let root = ProjectsRoot(defaults: defaults, resolver: resolver)
        try root.pick(from: URL(fileURLWithPath: "/Users/x/iCloud/Projects"))

        let startIdx = resolver.callOrder.firstIndex(of: "startAccessing")
        let bookmarkIdx = resolver.callOrder.firstIndex(of: "makeBookmark")
        XCTAssertNotNil(startIdx, "pick must start security-scoped access")
        XCTAssertNotNil(bookmarkIdx, "pick must mint a bookmark")
        if let s = startIdx, let b = bookmarkIdx {
            XCTAssertLessThan(s, b, "startAccessing must precede makeBookmark on iOS")
        }
    }

    /// If minting the bookmark fails (sandbox blocks an inaccessible URL), `pick`
    /// propagates the throw so `SettingsView` surfaces `.resolveFailed` rather than
    /// adopting a dead root.
    func test_pick_makeBookmarkThrows_propagates() {
        let resolver = FakeBookmarkResolver(makeBookmark: { throw FakeMakeError() })
        let root = ProjectsRoot(defaults: defaults, resolver: resolver)
        XCTAssertThrowsError(try root.pick(from: URL(fileURLWithPath: "/Users/x/iCloud/Projects")))
    }

    func test_roundTrip_pickThenFreshResolveRestoresRoot() throws {
        let pickedURL = URL(fileURLWithPath: "/Users/x/iCloud/Projects")
        let bytes = Data([0x09, 0x08, 0x07])

        // 1) Pick on one instance — persists the bookmark bytes.
        let writer = ProjectsRoot(
            defaults: defaults,
            resolver: FakeBookmarkResolver(makeBookmark: { bytes })
        )
        try writer.pick(from: pickedURL)
        XCTAssertEqual(defaults.data(forKey: bookmarkKey), bytes)

        // 2) Fresh instance over the SAME defaults; its resolver maps the
        //    persisted bytes back to the same URL. Launch must restore it.
        let reader = ProjectsRoot(
            defaults: defaults,
            resolver: FakeBookmarkResolver(resolve: { (pickedURL, false) })
        )
        reader.resolveOnLaunch()

        XCTAssertEqual(reader.rootURL, pickedURL)
        XCTAssertEqual(reader.picker, .idle)
    }
}

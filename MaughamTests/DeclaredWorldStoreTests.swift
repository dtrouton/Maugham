import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class DeclaredWorldStoreTests: XCTestCase {
    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeclaredWorldStore-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeWorld(
        sourceHash: String = "hash-A", clause: String = "The book is about weather"
    ) -> DerivedWorld {
        // Whole-second `derivedAt`: ISO8601 round-tripping through the sidecar
        // truncates fractional seconds (the rounding the manifest's `modified`
        // already lives with), so a sub-second `Date()` fixture would fail
        // equality after a save/load cycle for a reason that has nothing to do
        // with the store's correctness.
        let wholeSecond = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return DerivedWorld(
            sourceHash: sourceHash,
            clauses: [DerivedClause(quote: clause, check: "every scene names the weather")],
            rules: [DerivedRule(
                subject: "Kelly", quote: "Kelly only acts on what she has heard",
                constraint: "Kelly must not act on information she has not heard")],
            derivedAt: wholeSecond)
    }

    // MARK: - The one spelling of a scope key

    /// Task 4's performer and Task 6's pane must not each invent one. The
    /// spelling is `project` / `doc-<id>`, and it lives here.
    func test_theScopeKeyHasOneSpelling() {
        XCTAssertEqual(DeclaredWorldStore.scopeKey(for: .project), "project")
        XCTAssertEqual(DeclaredWorldStore.scopeKey(for: .document("doc-4f2a")), "doc-doc-4f2a")
    }

    /// A scope written by a newer build still keys something stable and
    /// filename-safe — the cache must not refuse to have a filename for a
    /// statement it cannot otherwise interpret.
    func test_anUnknownScopeStillKeysSomethingStableAndSafe() {
        let key1 = DeclaredWorldStore.scopeKey(for: .unknown("chapter:7/of 9"))
        let key2 = DeclaredWorldStore.scopeKey(for: .unknown("chapter:7/of 9"))
        let other = DeclaredWorldStore.scopeKey(for: .unknown("chapter:8/of 9"))
        XCTAssertEqual(key1, key2, "same scope, same key across launches")
        XCTAssertNotEqual(key1, other)
        XCTAssertFalse(key1.contains("/"))
        XCTAssertFalse(key1.contains(":"))
    }

    /// The key becomes a path component. A document id carrying a separator or
    /// a `..` must not be able to steer the write out of `.maugham/derived/`.
    func test_aScopeKeyCanNeverEscapeTheDerivedDirectory() {
        let project = URL(fileURLWithPath: "/tmp/project")
        let hostile = DeclaredWorldStore.scopeKey(for: .document("../../etc/passwd"))
        XCTAssertFalse(hostile.contains("/"))
        XCTAssertFalse(hostile.contains(".."))

        let url = DeclaredWorldStore.sidecarURL(
            projectRoot: project, scopeKey: hostile,
            device: DeviceSlug.make(from: "test-mac"))
        XCTAssertEqual(
            url.standardizedFileURL.deletingLastPathComponent().path,
            project.appendingPathComponent(".maugham/derived").path)
    }

    // MARK: - The filename

    func test_sidecarFilename_isPerDevice_andTakesDeviceSlug() {
        let project = URL(fileURLWithPath: "/tmp/project")
        let slug = DeviceSlug.make(from: "Denvers-Mac.local")
        let url = DeclaredWorldStore.sidecarURL(
            projectRoot: project, scopeKey: "project", device: slug)
        XCTAssertEqual(
            url.path,
            project.appendingPathComponent(".maugham/derived/project.\(slug.raw).json").path)
    }

    /// Per-device layout is not decoration: this machine's derivation is not
    /// served to another machine's store, the way a diagnostics run on one Mac
    /// is not another's.
    func test_anotherDevicesDerivationIsNotServed() throws {
        let project = try makeProject()
        let world = makeWorld()

        DeclaredWorldStore(projectRoot: project, device: DeviceSlug.make(from: "mac-A"))
            .store(world, forScopeKey: "project")

        let onB = DeclaredWorldStore(
            projectRoot: project, device: DeviceSlug.make(from: "mac-B"))
        XCTAssertNil(onB.cached(forScopeKey: "project", sourceHash: world.sourceHash))
    }

    // MARK: - The hash gate

    /// The whole point of the store: a derivation read from prose that has
    /// since changed can never be served. The writer edits their intent, the
    /// hash moves, the cache goes quiet.
    func test_aChangedStatementInvalidatesTheCache() throws {
        let project = try makeProject()
        let store = DeclaredWorldStore(
            projectRoot: project, device: DeviceSlug.make(from: "test-mac"))
        let world = makeWorld(sourceHash: "hash-A")
        store.store(world, forScopeKey: "project")

        XCTAssertEqual(store.cached(forScopeKey: "project", sourceHash: "hash-A"), world)
        XCTAssertNil(
            store.cached(forScopeKey: "project", sourceHash: "hash-B"),
            "a derivation of prose that has since changed is never served")
        XCTAssertNil(store.cached(forScopeKey: "doc-doc-1", sourceHash: "hash-A"),
                     "and a scope nothing was ever derived for is absent, not empty")
    }

    /// The hash is over the exact text the derivation read — no normalization,
    /// no anchor-stripping. Deliberate: the cache key must mean "this
    /// derivation was made from precisely this string", so any transform
    /// between the hash and the deriver's input is a way to serve a reading of
    /// text that was never read.
    func test_theHashIsSHA256OfTheExactText() {
        XCTAssertEqual(
            DerivedWorld.sourceHash(of: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "SHA-256 of \"abc\" — pins the algorithm, not just its stability")
        XCTAssertNotEqual(
            DerivedWorld.sourceHash(of: "a b"), DerivedWorld.sourceHash(of: "a  b"))
        XCTAssertNotEqual(
            DerivedWorld.sourceHash(of: "intent"), DerivedWorld.sourceHash(of: "intent\n"))
    }

    // MARK: - The sidecar

    /// A fresh store over an existing project serves what the last one derived
    /// — with no `load` call to forget. A cache that only works after a
    /// ceremony is a cache that silently re-derives (and re-spends) on every
    /// launch.
    func test_roundTrip_survivesRelaunchWithoutBeingTold() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let world = makeWorld()

        DeclaredWorldStore(projectRoot: project, device: device)
            .store(world, forScopeKey: "doc-doc-7")

        let reopened = DeclaredWorldStore(projectRoot: project, device: device)
        XCTAssertEqual(
            reopened.cached(forScopeKey: "doc-doc-7", sourceHash: world.sourceHash), world)
    }

    func test_corruptSidecar_readsAsEmpty_neverThrows() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let url = DeclaredWorldStore.sidecarURL(
            projectRoot: project, scopeKey: "project", device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0x00, 0x13, 0x37]).write(to: url)

        let store = DeclaredWorldStore(projectRoot: project, device: device)

        XCTAssertNil(store.cached(forScopeKey: "project", sourceHash: "hash-A"))
    }

    /// One unreadable sidecar costs its own scope's derivation and nothing
    /// else's — the derived directory is a set of independent caches.
    func test_oneCorruptSidecarDoesNotHideTheOthers() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let world = makeWorld()
        DeclaredWorldStore(projectRoot: project, device: device)
            .store(world, forScopeKey: "doc-doc-9")

        let corrupt = DeclaredWorldStore.sidecarURL(
            projectRoot: project, scopeKey: "project", device: device)
        try Data("{ not json".utf8).write(to: corrupt)

        let reopened = DeclaredWorldStore(projectRoot: project, device: device)
        XCTAssertNil(reopened.cached(forScopeKey: "project", sourceHash: world.sourceHash))
        XCTAssertEqual(
            reopened.cached(forScopeKey: "doc-doc-9", sourceHash: world.sourceHash), world)
    }

    // MARK: - Version and invalidation

    func test_store_bumpsVersion() throws {
        let project = try makeProject()
        let store = DeclaredWorldStore(
            projectRoot: project, device: DeviceSlug.make(from: "test-mac"))
        let before = store.version

        store.store(makeWorld(), forScopeKey: "project")

        XCTAssertGreaterThan(store.version, before)
    }

    /// The revoke/edit path's call. It must reach the disk too: an entry
    /// dropped from memory alone comes back on the next launch, and the writer
    /// who revoked a ruling would be checked against it again.
    func test_invalidate_removesTheEntry_bumpsVersion_andReachesTheDisk() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let store = DeclaredWorldStore(projectRoot: project, device: device)
        let world = makeWorld()
        store.store(world, forScopeKey: "project")
        let before = store.version

        store.invalidate(forScopeKey: "project")

        XCTAssertNil(store.cached(forScopeKey: "project", sourceHash: world.sourceHash))
        XCTAssertGreaterThan(store.version, before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: DeclaredWorldStore.sidecarURL(
                projectRoot: project, scopeKey: "project", device: device).path))

        let reopened = DeclaredWorldStore(projectRoot: project, device: device)
        XCTAssertNil(reopened.cached(forScopeKey: "project", sourceHash: world.sourceHash),
                     "a revoked derivation does not return on relaunch")
    }

    /// Invalidating one scope leaves the other alone — a ruling on a piece
    /// must not throw away the project's derivation.
    func test_invalidate_isScoped() throws {
        let project = try makeProject()
        let store = DeclaredWorldStore(
            projectRoot: project, device: DeviceSlug.make(from: "test-mac"))
        let world = makeWorld()
        store.store(world, forScopeKey: "project")
        store.store(world, forScopeKey: "doc-doc-3")

        store.invalidate(forScopeKey: "doc-doc-3")

        XCTAssertEqual(store.cached(forScopeKey: "project", sourceHash: world.sourceHash), world)
        XCTAssertNil(store.cached(forScopeKey: "doc-doc-3", sourceHash: world.sourceHash))
    }

    /// Invalidating something never derived is a no-op the caller can make
    /// unconditionally — Task 4's performer calls this on every ruling, and
    /// most scopes have never been derived.
    func test_invalidatingSomethingNeverDerivedIsHarmless() {
        let store = DeclaredWorldStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused-\(UUID())"),
            device: DeviceSlug.make(from: "test-mac"))

        store.invalidate(forScopeKey: "project")

        XCTAssertNil(store.cached(forScopeKey: "project", sourceHash: "hash-A"))
    }

    /// A second derivation for the same scope replaces the first: there is
    /// never more than one reading of one statement live (`DiagnosticsStore`'s
    /// replace-not-merge discipline).
    func test_aSecondDerivationReplacesTheFirst() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let store = DeclaredWorldStore(projectRoot: project, device: device)
        let first = makeWorld(sourceHash: "hash-A", clause: "the old line")
        let second = makeWorld(sourceHash: "hash-B", clause: "the new line")
        store.store(first, forScopeKey: "project")
        store.store(second, forScopeKey: "project")

        XCTAssertNil(store.cached(forScopeKey: "project", sourceHash: "hash-A"))
        XCTAssertEqual(store.cached(forScopeKey: "project", sourceHash: "hash-B"), second)

        let reopened = DeclaredWorldStore(projectRoot: project, device: device)
        XCTAssertEqual(reopened.cached(forScopeKey: "project", sourceHash: "hash-B"), second)
    }
}

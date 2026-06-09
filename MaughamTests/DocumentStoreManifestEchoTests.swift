import XCTest
import MaughamCore
@testable import Maugham

/// Finding 1.2 + O2: the manifest write-side echo guard.
///
/// `writeManifest` stamps a content-hash echo of the bytes it wrote; the
/// presenter's `handleManifestChanged` skips archiving when the disk content
/// matches that echo (our own write), and archives only on a genuine external
/// change — including the O2 case where the external manifest shares the same
/// whole-second `modified` timestamp as ours but differs in content.
@MainActor
final class DocumentStoreManifestEchoTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeNovel() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "ManifestEcho", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    private func conflictFiles(in url: URL) -> [String] {
        let conflictsDir = url.appendingPathComponent(".maugham/conflicts")
        return ((try? FileManager.default
            .contentsOfDirectory(atPath: conflictsDir.path)) ?? [])
            .filter { $0.hasPrefix("manifest-") }
    }

    /// Headline: a structural edit drives saveManifest → writeManifest. When the
    /// project-root presenter then fires for that very write, we must NOT archive
    /// our own bytes as a conflict.
    func test_ownStructuralSave_producesNoConflictArchive() async throws {
        let (url, store, ds) = try await makeNovel()
        let manifestURL = url.appendingPathComponent(ProjectManifest.fileName)

        // First structural edit + its presenter callback, to seed the
        // observed/echo state to a known whole second.
        _ = try await store.addStructureItem(
            parentId: nil, title: "Chapter Two",
            kind: .document(extension: "md"))
        ds.presenterDidChangeSubitem(at: manifestURL)
        XCTAssertTrue(conflictFiles(in: url).isEmpty, "first own save must not archive")

        // Cross a whole-second boundary so a timestamp-only `>` compare WOULD
        // fire (the original bug), then do a SECOND own structural save whose
        // `modified` is strictly newer.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        _ = try await store.addStructureItem(
            parentId: nil, title: "Chapter Three",
            kind: .document(extension: "md"))

        // Drive the presenter callback the way production does for the manifest
        // write we just made. The disk content is exactly what we wrote, so the
        // content-hash echo guard must recognize it as our own write and NOT
        // archive — even though its timestamp is newer than what we last observed.
        ds.presenterDidChangeSubitem(at: manifestURL)

        XCTAssertTrue(conflictFiles(in: url).isEmpty,
                      "self-save must not archive a conflict, got \(conflictFiles(in: url))")
        await ds.close()
    }

    /// A genuinely-different external manifest with a NEWER timestamp must still
    /// archive (regression guard for the original LWW behavior).
    func test_externalNewerManifest_archives() async throws {
        let (url, _, ds) = try await makeNovel()
        let manifestURL = url.appendingPathComponent(ProjectManifest.fileName)

        let project = try await ProjectStore.load(from: url)
        var manifest = project.manifest
        manifest.title = "Externally Renamed"
        manifest.modified = Date(timeIntervalSinceNow: 60)
        let externalData = try ProjectManifest.makeEncoder().encode(manifest)
        try externalData.write(to: manifestURL, options: [.atomic])

        ds.presenterDidChangeSubitem(at: manifestURL)

        XCTAssertFalse(conflictFiles(in: url).isEmpty,
                       "genuine external change must archive")
        await ds.close()
    }

    /// O2: an external manifest that differs in CONTENT but shares the same
    /// whole-second `modified` timestamp as the one we last wrote. The old
    /// timestamp-only `>` compare silently accepted this (no archive). The
    /// content-hash compare must still recognize it as external and archive it.
    func test_externalSameWholeSecondDifferentContent_archives() async throws {
        let (url, store, ds) = try await makeNovel()
        let manifestURL = url.appendingPathComponent(ProjectManifest.fileName)

        // First do an own write so the echo + observed timestamp are seeded to a
        // known whole-second value.
        try await store.updateInspector(
            id: store.manifest.structure[0].id, tags: ["seed"])
        ds.presenterDidChangeSubitem(at: manifestURL)
        XCTAssertTrue(conflictFiles(in: url).isEmpty, "own write must not archive")

        // Now craft an external manifest whose `modified` truncates to the SAME
        // whole second as what we last wrote, but whose content differs.
        let onDisk = try ProjectManifest.makeDecoder().decode(
            ProjectManifest.self, from: Data(contentsOf: manifestURL))
        var external = onDisk
        external.title = "Same-Second External Rename"
        // Keep the same whole-second `modified` — iso8601 encoding truncates to
        // whole seconds, so after a round-trip the timestamps are byte-equal.
        external.modified = onDisk.modified
        let externalData = try ProjectManifest.makeEncoder().encode(external)
        try externalData.write(to: manifestURL, options: [.atomic])

        ds.presenterDidChangeSubitem(at: manifestURL)

        XCTAssertFalse(conflictFiles(in: url).isEmpty,
                       "same-whole-second external content change must archive (O2)")
        await ds.close()
    }
}

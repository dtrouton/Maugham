import XCTest
@testable import MaughamPhone
import MaughamCore

/// `UbiquitousDownloader` that treats every URL as already-local — the temp
/// files these tests write are real local files, not ubiquitous items. Mirrors
/// the private fake in `ProjectsBrowserTests`/`PhoneStatementReadTests` (each
/// suite keeps its own so a change to one test's fake can't silently retune
/// another's).
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

/// M3 P1's whole-branch review, seam 2: **a schema-6 manifest driven through
/// the PHONE's decode path** — `ProjectsBrowser` → `CoordinatedFileIO` →
/// `decodeGuardingSchema` — not just MaughamCore's own tests, which every
/// platform shares but no platform's loader exercises.
///
/// The paired-release constraint this pins (`ProjectManifest`'s 5→6 contract
/// row): a phone build carrying this branch must OPEN a v6 manifest with
/// review-pass data intact, and must REFUSE one newer than it understands, via
/// its own real loader. `PhoneStatementReadTests` is the M1A precedent for the
/// 3→4 bump; this is the same net cast over the 5→6 fields.
///
/// The lossless half matters most on the phone: the phone never writes the
/// manifest, so it can never clobber a pass state — but a phone build that
/// silently dropped `passStates` at decode would under-report the project to
/// every reader downstream, and nothing on the Mac could see it happen.
final class PhoneReviewPassReadTests: XCTestCase {

    private func makeProjectFolder(_ name: String, json: Data) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneReviewPassRead-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try json.write(to: dir.appendingPathComponent(ProjectManifest.fileName), options: [.atomic])
        return root
    }

    /// A v6 manifest the Mac would write — a customized pass list plus a piece
    /// carrying a known state AND a state no build can read yet — opens through
    /// the phone's own loader with every field intact.
    ///
    /// Built from the same shared ingredients the Mac uses
    /// (`ProjectManifest.makeEncoder()`, memberwise init at
    /// `currentSchemaVersion`), so the fixture cannot drift from what
    /// production actually writes.
    @MainActor
    func test_aMacWrittenV6ManifestWithPassDataOpensOnThePhoneIntact() async throws {
        let customPasses = [
            ReviewPass(id: "structural", name: "Structural"),
            ReviewPass(id: "sensitivity", name: "Sensitivity"),
        ]
        let piece = StructureItem(
            id: "doc-0001", title: "Chapter One", type: .document,
            path: "manuscript/01-chapter-one.md",
            passStates: [
                "structural": .done,
                // The forward-compat case: a state written by a build NEWER
                // than this one. The phone must carry it, not degrade it.
                "sensitivity": .unknown("deferred_to_editor"),
            ])
        let manifest = ProjectManifest(
            id: "PRJ-V6-PASSES", type: .novel, title: "V6 Passes", author: "Tester",
            created: Date(timeIntervalSince1970: 1_700_000_000),
            modified: Date(timeIntervalSince1970: 1_700_000_500),
            structure: [piece], research: [],
            reviewPasses: customPasses)
        XCTAssertEqual(manifest.schemaVersion, ProjectManifest.currentSchemaVersion,
            "premise: the memberwise init stamps the current schema, which is what a Mac on this branch writes")
        let root = try makeProjectFolder(
            "v6-passes", json: try ProjectManifest.makeEncoder().encode(manifest))

        let browser = ProjectsBrowser(downloads: DownloadCoordinator(downloader: AlwaysLocalDownloader()))
        await browser.refresh(root: root)
        XCTAssertNil(browser.loadError)
        XCTAssertTrue(browser.failures.isEmpty,
            "a current-schema manifest must not be refused by the phone's own gate: \(browser.failures)")

        let browsed = try XCTUnwrap(browser.project(id: "PRJ-V6-PASSES"))
        XCTAssertEqual(browsed.manifest.reviewPasses, customPasses,
            "the customized pass list must survive the phone's decode")
        XCTAssertEqual(browsed.manifest.effectiveReviewPasses, customPasses,
            "…and a non-empty stored list IS the effective list")
        let decoded = try XCTUnwrap(browsed.manifest.structure.first)
        XCTAssertEqual(decoded.passStates?["structural"], .done)
        XCTAssertEqual(decoded.passStates?["sensitivity"], .unknown("deferred_to_editor"),
            "an unrecognised state must decode lossless on the phone too — "
            + "`.unknown(raw)`, never a sentinel and never a drop")
    }

    /// The other half of the paired-release gate: a manifest ONE schema ahead
    /// of this build is refused by the phone's own loader — landing in
    /// `failures`, not opening degraded. Version-relative, so this test
    /// survives the next bump without editing.
    @MainActor
    func test_aManifestOneSchemaAheadIsRefusedByThePhonesOwnGate() async throws {
        let tooNew = ProjectManifest.currentSchemaVersion + 1
        let json = """
        {
          "author" : "Tester",
          "created" : "2023-11-14T22:13:20Z",
          "id" : "PRJ-FUTURE",
          "modified" : "2023-11-14T22:21:40Z",
          "research" : [],
          "schemaVersion" : \(tooNew),
          "structure" : [],
          "title" : "From the Future",
          "type" : "novel"
        }
        """
        let root = try makeProjectFolder("future", json: Data(json.utf8))

        let browser = ProjectsBrowser(downloads: DownloadCoordinator(downloader: AlwaysLocalDownloader()))
        await browser.refresh(root: root)
        XCTAssertEqual(browser.failures.count, 1,
            "a too-new manifest must be refused into `failures` — opening it and "
            + "re-reading what this build can parse is the degrade path the "
            + "schema gate exists to close")
        XCTAssertNil(browser.project(id: "PRJ-FUTURE"),
            "…and the refused project must not be browsable")
    }
}

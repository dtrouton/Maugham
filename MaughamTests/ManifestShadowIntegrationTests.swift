import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ManifestShadowIntegrationTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }
    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_writeManifest_writesShadow_andLoadRecoversFromIt() async throws {
        let url = try await ProjectFactory.createShortStoryProject(named: "Shadowed", in: temp.url)

        // A real manifest save (via DocumentStore) mirrors the shadow.
        let ds = try await DocumentStore.open(url: url)
        let manifestData = try Data(contentsOf: url.appendingPathComponent(ProjectManifest.fileName))
        try await ds.writeManifest(manifestData)
        await ds.close()
        XCTAssertNotNil(ManifestShadow.recover(in: url), "save should have written a verified shadow")

        // Corrupt the live manifest, then load — it must recover from the shadow.
        try Data("{ this is not valid json".utf8).write(
            to: url.appendingPathComponent(ProjectManifest.fileName), options: .atomic)

        let store = try await ProjectStore.load(from: url)
        XCTAssertEqual(store.manifest.title, "Shadowed")  // recovered the real manifest

        // ...and the live manifest was repaired from the shadow (decodes again).
        let repaired = try Data(contentsOf: url.appendingPathComponent(ProjectManifest.fileName))
        XCTAssertNoThrow(try ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: repaired))
    }

    func test_load_stillThrows_whenManifestCorruptAndNoShadow() async throws {
        let url = try await ProjectFactory.createShortStoryProject(named: "NoShadow", in: temp.url)
        // No shadow was ever written (factory writes the manifest directly). Corrupt it.
        try Data("{ broken".utf8).write(
            to: url.appendingPathComponent(ProjectManifest.fileName), options: .atomic)

        do {
            _ = try await ProjectStore.load(from: url)
            XCTFail("expected load to throw with a corrupt manifest and no shadow")
        } catch {
            // expected
        }
    }

    // MARK: - #92: a MISSING manifest comes back from its shadow

    private func manifestURL(_ url: URL) -> URL { url.appendingPathComponent(ProjectManifest.fileName) }

    /// A project whose shadow mirrors its manifest, as every save leaves it.
    private func shadowedProject(_ name: String) async throws -> URL {
        let url = try await ProjectFactory.createShortStoryProject(named: name, in: temp.url)
        try ManifestShadow.write(try Data(contentsOf: manifestURL(url)), in: url)
        return url
    }

    func test_aMissingManifestIsPutBackFromAGoodShadowAndSaysSoOnce() async throws {
        let url = try await shadowedProject("Lost")
        try FileManager.default.removeItem(at: manifestURL(url))

        let store = try await ProjectStore.load(from: url)

        XCTAssertEqual(store.manifest.title, "Lost")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL(url).path))
        XCTAssertEqual(store.manifestRestoredNotice,
            "This project's settings file was missing, so Maugham put it back from its safety copy.")
        // The file is back, so the next open has nothing to say.
        let again = try await ProjectStore.load(from: url)
        XCTAssertNil(again.manifestRestoredNotice)
    }

    func test_aMissingManifestWithNoShadowStillRefuses() async throws {
        let url = try await ProjectFactory.createShortStoryProject(named: "Gone", in: temp.url)
        try FileManager.default.removeItem(at: manifestURL(url))
        do {
            _ = try await ProjectStore.load(from: url)
            XCTFail("expected manifestNotFound")
        } catch ProjectStoreError.manifestNotFound {
            XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL(url).path))
        }
    }

    func test_aMissingManifestWithACorruptShadowStillRefuses() async throws {
        let url = try await shadowedProject("BadShadow")
        try FileManager.default.removeItem(at: manifestURL(url))
        // The checksum no longer matches: `recover` refuses the shadow.
        try Data("{ tampered".utf8).write(
            to: url.appendingPathComponent(".maugham/manifest.shadow.json"), options: .atomic)
        do {
            _ = try await ProjectStore.load(from: url)
            XCTFail("expected manifestNotFound")
        } catch ProjectStoreError.manifestNotFound {
            XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL(url).path))
        }
    }

    func test_aPresentManifestIsNeverReplacedByTheShadow() async throws {
        let url = try await shadowedProject("Present")
        let present = try Data(contentsOf: manifestURL(url))
        // A shadow that disagrees with the live file (a different title).
        var other = try ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: present)
        other.title = "Shadow Title"
        try ManifestShadow.write(try ProjectManifest.makeEncoder().encode(other), in: url)

        XCTAssertFalse(ProjectStore.restoreMissingManifest(at: manifestURL(url), projectURL: url))
        XCTAssertEqual(try Data(contentsOf: manifestURL(url)), present)

        let store = try await ProjectStore.load(from: url)
        XCTAssertEqual(store.manifest.title, "Present")
        XCTAssertNil(store.manifestRestoredNotice)
    }

    func test_aCorruptManifestSelfHealsAsBeforeWithNoMissingFileNotice() async throws {
        let url = try await shadowedProject("Corrupt")
        try Data("{ broken".utf8).write(to: manifestURL(url), options: .atomic)
        let store = try await ProjectStore.load(from: url)
        XCTAssertEqual(store.manifest.title, "Corrupt")
        XCTAssertNil(store.manifestRestoredNotice)
    }
}

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
}

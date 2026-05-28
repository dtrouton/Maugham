import XCTest
@testable import Maugham

final class PublishStarterTests: XCTestCase {
    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishStarterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testIsInitialized_falseWhenAbsent() {
        XCTAssertFalse(PublishStarter.isInitialized(in: tmp))
    }

    func testInstall_copiesAllExpectedFiles() async throws {
        try await PublishStarter.install(into: tmp, force: false)

        let pub = tmp.appendingPathComponent(".maugham/publish")
        for name in [
            "template.tex", "preamble.tex", "frontmatter.tex",
            "prose.tex", "screenplay.tex", "backmatter.tex",
            "styles.css", "config.json"
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: pub.appendingPathComponent(name).path),
                "missing \(name)")
        }
    }

    func testInstall_throws_whenAlreadyInitialized() async throws {
        try await PublishStarter.install(into: tmp, force: false)
        // XCTAssertThrowsError doesn't support `try await` (autoclosure isn't
        // async-marked). Use do/catch — same shape, async-safe.
        do {
            try await PublishStarter.install(into: tmp, force: false)
            XCTFail("expected throw")
        } catch PublishStarter.Error.alreadyInitialized {
            // expected
        }
    }

    func testInstall_force_overwritesExisting() async throws {
        try await PublishStarter.install(into: tmp, force: false)
        // Mutate template.tex.
        let templateURL = tmp.appendingPathComponent(".maugham/publish/template.tex")
        try "% mutated".write(to: templateURL, atomically: true, encoding: .utf8)
        // Force reinstall.
        try await PublishStarter.install(into: tmp, force: true)
        let content = try String(contentsOf: templateURL)
        XCTAssertFalse(content.contains("mutated"))
        XCTAssertTrue(content.contains("Barebones publish template"))
    }

    func testInstall_renamesDefaultConfigJsonToConfigJson() async throws {
        try await PublishStarter.install(into: tmp, force: false)
        let cfg = tmp.appendingPathComponent(".maugham/publish/config.json")
        let defaults = tmp.appendingPathComponent(".maugham/publish/default-config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cfg.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaults.path))
    }

    // MARK: - D3a: high-water-mark reconciliation

    func testInstall_preservesNextVersion_whenPriorPublicationsExist() async throws {
        // Simulate a project that has already published v0.1 and v0.2:
        // write a publications.jsonl by hand, then install the starter.
        // The starter's default config has next_version="0.1"; install must
        // reconcile to "0.3" (max(0.1, 0.2) + 1).
        try await PublishStarter.install(into: tmp, force: false)

        // Manually append two publications via PublicationStore so we don't
        // depend on the full compile path.
        let pubStore = await PublicationStore(projectURL: tmp)
        let now = Date()
        for version in ["0.1", "0.2"] {
            try await pubStore.append(Publication(
                publicationID: "pub-\(version)-test",
                version: version,
                label: nil,
                format: .pdf,
                outputPath: "Exports/Untitled-v\(version).pdf",
                snapshotID: "snap-\(version)-test",
                checkpointID: "",
                republishedFrom: nil,
                compiledAt: now,
                maughamVersion: "0.0.0-test",
                tectonicVersion: "0.15.0"))
        }

        // Force-init while publications exist. Reconciliation must run.
        try await PublishStarter.install(into: tmp, force: true)

        let cfg = try await PublishConfigStore(projectURL: tmp).load()
        XCTAssertEqual(cfg?.nextVersion, "0.3",
                       "expected 0.3 (max(0.1, 0.2) + 1); got \(cfg?.nextVersion ?? "nil")")
    }

    func testInstall_doesNotRewindNextVersion_whenStarterDefaultIsHigher() async throws {
        // Edge: if (hypothetically) the freshly-written default config had
        // a HIGHER next_version than max(publications), the high-water-mark
        // logic must not roll it backward. Today the default is "0.1" so
        // this only fires if publications are also below 0.1 (none) — we
        // verify by running install with NO publications and expecting the
        // freshly-written "0.1" to survive untouched.
        try await PublishStarter.install(into: tmp, force: false)
        let cfg = try await PublishConfigStore(projectURL: tmp).load()
        XCTAssertEqual(cfg?.nextVersion, "0.1")
    }

    func testInstall_ignoresNonNumericPublicationVersions() async throws {
        // Republish records use non-numeric versions like "0.3-r5f7a". Those
        // aren't candidates for next_version comparison and must not poison
        // the reconciliation.
        try await PublishStarter.install(into: tmp, force: false)

        let pubStore = await PublicationStore(projectURL: tmp)
        try await pubStore.append(Publication(
            publicationID: "pub-republish-1",
            version: "0.3-r5f7a", // non-numeric (republish form)
            label: nil, format: .pdf,
            outputPath: "Exports/x.pdf",
            snapshotID: "snap-test",
            checkpointID: "",
            republishedFrom: "0.3",
            compiledAt: Date(),
            maughamVersion: "0",
            tectonicVersion: "0.15.0"))

        try await PublishStarter.install(into: tmp, force: true)

        let cfg = try await PublishConfigStore(projectURL: tmp).load()
        // Only the republish-form exists, so reconciliation finds no numeric
        // versions and leaves the default "0.1" alone.
        XCTAssertEqual(cfg?.nextVersion, "0.1")
    }
}

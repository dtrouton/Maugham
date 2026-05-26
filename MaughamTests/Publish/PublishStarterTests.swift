import XCTest
@testable import Maugham

final class PublishStarterTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishStarterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testIsInitialized_falseWhenAbsent() {
        XCTAssertFalse(PublishStarter.isInitialized(in: tmp))
    }

    func testInstall_copiesAllExpectedFiles() throws {
        try PublishStarter.install(into: tmp, force: false)

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

    func testInstall_throws_whenAlreadyInitialized() throws {
        try PublishStarter.install(into: tmp, force: false)
        XCTAssertThrowsError(try PublishStarter.install(into: tmp, force: false)) { err in
            guard case PublishStarter.Error.alreadyInitialized = err else {
                XCTFail("wrong error: \(err)")
                return
            }
        }
    }

    func testInstall_force_overwritesExisting() throws {
        try PublishStarter.install(into: tmp, force: false)
        // Mutate template.tex.
        let templateURL = tmp.appendingPathComponent(".maugham/publish/template.tex")
        try "% mutated".write(to: templateURL, atomically: true, encoding: .utf8)
        // Force reinstall.
        try PublishStarter.install(into: tmp, force: true)
        let content = try String(contentsOf: templateURL)
        XCTAssertFalse(content.contains("mutated"))
        XCTAssertTrue(content.contains("Barebones publish template"))
    }

    func testInstall_renamesDefaultConfigJsonToConfigJson() throws {
        try PublishStarter.install(into: tmp, force: false)
        let cfg = tmp.appendingPathComponent(".maugham/publish/config.json")
        let defaults = tmp.appendingPathComponent(".maugham/publish/default-config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cfg.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaults.path))
    }
}

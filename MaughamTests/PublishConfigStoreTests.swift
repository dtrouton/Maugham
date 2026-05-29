import XCTest
@testable import Maugham

final class PublishConfigStoreTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishConfigStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLoad_returnsNilWhenAbsent() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        let result = try await store.load()
        XCTAssertNil(result)
    }

    func testSave_thenLoad_roundTrips() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig()
        cfg.metadata.title = "Round Trip"
        try await store.save(cfg)

        let loaded = try await store.load()
        XCTAssertEqual(loaded?.metadata.title, "Round Trip")
    }

    func testSave_writesPrettyPrintedJSON_withSnakeCaseKeys() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        try await store.save(PublishConfig())
        let data = try Data(contentsOf: tmp.appendingPathComponent(".maugham/publish/config.json"))
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains("\"schema_version\""))
        XCTAssertTrue(s.contains("\"next_version\""))
        XCTAssertTrue(s.contains("\n"))   // pretty-printed
    }

    func testSave_createsIntermediateDirectories() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        try await store.save(PublishConfig())
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent(".maugham/publish").path,
            isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testApplyPatch_mergesIntoExistingConfig() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        var initial = PublishConfig()
        initial.metadata.title = "Initial"
        initial.metadata.author = "A"
        try await store.save(initial)

        let patch = #"{"metadata":{"title":"Updated","keywords":["x","y"]}}"#
        let result = try await store.applyPatch(Data(patch.utf8))

        XCTAssertEqual(result.config.metadata.title, "Updated")
        XCTAssertEqual(result.config.metadata.author, "A")
        XCTAssertEqual(result.config.metadata.keywords, ["x", "y"])
        XCTAssertTrue(result.errors.isEmpty)

        let reloaded = try await store.load()
        XCTAssertEqual(reloaded?.metadata.title, "Updated")
    }

    func testApplyPatch_loadsFromNothing_usesDefaults() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        let patch = #"{"metadata":{"title":"Created","author":"X"}}"#
        let result = try await store.applyPatch(Data(patch.utf8))
        XCTAssertEqual(result.config.metadata.title, "Created")
        XCTAssertEqual(result.config.schemaVersion, 1)
    }

    func testApplyPatch_reportsValidationErrors_andDoesNotSave() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        try await store.save(PublishConfig(metadata: .init(title: "Good", author: "Y")))

        let patch = #"{"metadata":{"title":""}}"#
        let result = try await store.applyPatch(Data(patch.utf8))
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertEqual(result.errors.first?.field, "metadata.title")

        let reloaded = try await store.load()
        XCTAssertEqual(reloaded?.metadata.title, "Good") // unchanged
    }

    // Regression test for the Section custom init(from:) fix.
    // Before the fix, applying a partial section patch that introduced a NEW
    // section key with only one field would throw `keyNotFound` for `start_on`
    // and `include_in_toc` (which are non-optional in the synthesised decoder).
    // The fix adds a custom init(from:) that defaults those fields.
    func test_applyPatch_partialNewSection_decodesWithDefaults() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        // Start from a clean default config (no sections).
        try await store.save(PublishConfig())

        // Patch adds a new section with ONLY title_override — no start_on or include_in_toc.
        let patch = #"{"sections":{"ab12":{"title_override":"Tribute"}}}"#
        let result = try await store.applyPatch(Data(patch.utf8))

        // Must not throw (above), must have no validation errors.
        XCTAssertTrue(result.errors.isEmpty)

        let section = try XCTUnwrap(result.config.sections["ab12"],
                                    "section ab12 should be present after patch")
        XCTAssertEqual(section.titleOverride, "Tribute")
        XCTAssertEqual(section.startOn, .any,        "startOn should default to .any")
        XCTAssertEqual(section.includeInToc, true,   "includeInToc should default to true")
        XCTAssertNil(section.styleFile,              "styleFile should default to nil")

        // Optional second assert: updating only start_on on an existing section
        // preserves the previously set titleOverride and flips startOn.
        let patch2 = #"{"sections":{"ab12":{"start_on":"recto"}}}"#
        let result2 = try await store.applyPatch(Data(patch2.utf8))
        XCTAssertTrue(result2.errors.isEmpty)

        let section2 = try XCTUnwrap(result2.config.sections["ab12"],
                                     "section ab12 should still be present after second patch")
        XCTAssertEqual(section2.titleOverride, "Tribute", "titleOverride must be preserved")
        XCTAssertEqual(section2.startOn, .recto,          "startOn must be updated to .recto")
        XCTAssertEqual(section2.includeInToc, true,       "includeInToc must still be true")
    }
}

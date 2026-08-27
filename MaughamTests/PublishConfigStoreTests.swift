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

    // MARK: - additionalValidation (imprints P1, Task 3)
    //
    // `set_publish_config` needs a rule the pure validator cannot express — a
    // template that exists, an allowlist id the project actually has — so
    // `applyPatch` takes a second, project-aware pass. Its contract is the
    // same as the pure one's: a non-empty result means the errors come back
    // and NOTHING is written.

    func test_applyPatch_additionalValidationRefuses_andTheFileIsByteIdentical() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        try await store.save(PublishConfig(metadata: .init(title: "Good", author: "Y")))
        let url = tmp.appendingPathComponent(".maugham/publish/config.json")
        let before = try Data(contentsOf: url)

        let patch = #"{"metadata":{"title":"Updated"}}"#
        let result = try await store.applyPatch(Data(patch.utf8)) { _ in
            [.init(field: "imprints.x.template", message: "no such template")]
        }

        XCTAssertEqual(result.errors.map(\.field), ["imprints.x.template"])
        XCTAssertEqual(try Data(contentsOf: url), before,
                       "a refused patch must leave the config file byte-identical")
    }

    func test_applyPatch_additionalValidationPasses_andTheFileChanges() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        try await store.save(PublishConfig(metadata: .init(title: "Good", author: "Y")))
        let url = tmp.appendingPathComponent(".maugham/publish/config.json")
        let before = try Data(contentsOf: url)

        let patch = #"{"metadata":{"title":"Updated"}}"#
        let result = try await store.applyPatch(Data(patch.utf8)) { _ in [] }

        XCTAssertTrue(result.errors.isEmpty, "got \(result.errors)")
        XCTAssertNotEqual(try Data(contentsOf: url), before,
                          "an accepted patch must reach disk")
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded?.metadata.title, "Updated")
    }

    /// The extra pass sees the MERGED config, not the one on disk — otherwise
    /// it would judge the state the patch is replacing.
    func test_applyPatch_additionalValidationSeesTheMergedConfig() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        try await store.save(PublishConfig(metadata: .init(title: "Good", author: "Y")))

        let seen = Mutex<String?>(nil)
        _ = try await store.applyPatch(Data(#"{"metadata":{"title":"Updated"}}"#.utf8)) { cfg in
            seen.set(cfg.metadata.title)
            return []
        }
        XCTAssertEqual(seen.get(), "Updated")
    }

    /// The pure rules run FIRST, and a config they refuse never reaches the
    /// project-aware pass — which is what keeps the same rule from being
    /// reported twice (the project-aware validator runs the pure rules itself).
    func test_applyPatch_pureFailureShortCircuitsTheExtraPass() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        try await store.save(PublishConfig(metadata: .init(title: "Good", author: "Y")))

        let ran = Mutex<Bool>(false)
        let result = try await store.applyPatch(Data(#"{"metadata":{"title":""}}"#.utf8)) { _ in
            ran.set(true)
            return []
        }
        XCTAssertEqual(result.errors.map(\.field), ["metadata.title"])
        XCTAssertFalse(ran.get(), "the extra pass must not run over a config the pure rules refused")
    }
}

/// Minimal box so a `@Sendable` validation closure can report back into a test.
private final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}

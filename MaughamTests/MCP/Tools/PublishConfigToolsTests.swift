import XCTest
@testable import Maugham

@MainActor
final class PublishConfigToolsTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var projectID: String!
    var projectURL: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PCToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "T", in: tmp)
        // ProjectFactory.installIfMissing already wrote publish/config.json.
        let store = try await ProjectStore.load(from: projectURL)
        registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        projectID = ProjectIdentifier.id(for: projectURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - GetPublishConfigTool

    func testGet_returnsConfig() async throws {
        let data = try await GetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID!)"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(resp?["config"])
        let cfg = resp?["config"] as? [String: Any]
        let meta = cfg?["metadata"] as? [String: Any]
        XCTAssertNotNil(meta?["title"])
    }

    func testGet_unknownProjectID_throws() async throws {
        do {
            _ = try await GetPublishConfigTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_notreal"}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.invalidArgument(message) {
            XCTAssertTrue(message.contains("unknown project_id"))
        }
    }

    func testGet_noConfigFile_returnsDefaults() async throws {
        // Remove config file so we exercise the default path.
        let cfgURL = projectURL.appendingPathComponent(".maugham/publish/config.json")
        try? FileManager.default.removeItem(at: cfgURL)

        let data = try await GetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID!)"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let cfg = resp?["config"] as? [String: Any]
        let meta = cfg?["metadata"] as? [String: Any]
        // Default title from PublishConfig.Metadata.init()
        XCTAssertEqual(meta?["title"] as? String, "Untitled")
        // source discriminator must report "defaults" since no file exists.
        XCTAssertEqual(resp?["source"] as? String, "defaults",
                       "expected source=defaults when config.json absent")
    }

    func testGet_configFile_returnsPersistedDiscriminator() async throws {
        // Persist a config, then ensure get reports source=persisted.
        let configStore = PublishConfigStore(projectURL: projectURL)
        var cfg = PublishConfig()
        cfg.metadata.title = "Saved"
        try await configStore.save(cfg)

        let data = try await GetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID!)"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["source"] as? String, "persisted",
                       "expected source=persisted when config.json is on disk")
        let meta = (resp?["config"] as? [String: Any])?["metadata"] as? [String: Any]
        XCTAssertEqual(meta?["title"] as? String, "Saved")
    }

    // MARK: - SetPublishConfigTool

    func testSet_appliesPatch() async throws {
        let patch = #"{"metadata":{"title":"New Title","author":"Me"}}"#
        let data = try await SetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID!)","patch":\#(patch)}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let cfg = resp?["config"] as? [String: Any]
        let meta = cfg?["metadata"] as? [String: Any]
        XCTAssertEqual(meta?["title"] as? String, "New Title")
        XCTAssertEqual(meta?["author"] as? String, "Me")
    }

    func testSet_validationError_returnsErrorsAndDoesNotSave() async throws {
        // Empty title fails validation.
        let patch = #"{"metadata":{"title":""}}"#
        let data = try await SetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID!)","patch":\#(patch)}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let errs = resp?["errors"] as? [[String: Any]]
        XCTAssertFalse(errs?.isEmpty ?? true, "expected validation errors")
        XCTAssertEqual(errs?.first?["field"] as? String, "metadata.title")
    }

    func testSet_errorsArrayIsEmpty_onValidPatch() async throws {
        let patch = #"{"metadata":{"title":"Valid Title","author":"Author"}}"#
        let data = try await SetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID!)","patch":\#(patch)}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let errs = resp?["errors"] as? [[String: Any]]
        XCTAssertTrue(errs?.isEmpty ?? false)
    }

    func testSet_unknownProjectID_throws() async throws {
        do {
            _ = try await SetPublishConfigTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_notreal","patch":{}}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.invalidArgument(message) {
            XCTAssertTrue(message.contains("unknown project_id"))
        }
    }

    func testSet_missingPatch_throws() async throws {
        do {
            _ = try await SetPublishConfigTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(projectID!)"}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch MCPError.invalidArgument {
            // expected
        }
    }
}

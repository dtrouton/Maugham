import XCTest
@testable import Maugham

@MainActor
final class InitializePublishTemplateToolTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var projectID: String!
    var projectURL: URL!

    override func setUp() async throws {
        tmp = TestTemp.root
            .appendingPathComponent("InitPublishToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(
            named: "T", in: tmp)
        // ProjectFactory.installIfMissing was called inside the factory, so the
        // template already exists; remove it so testInitialize_installsStarter
        // exercises the install path.
        let publishDir = projectURL.appendingPathComponent(".maugham/publish")
        try? FileManager.default.removeItem(at: publishDir)

        let store = try await ProjectStore.load(from: projectURL)
        registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        projectID = ProjectIdentifier.id(for: projectURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testInitialize_installsStarter() async throws {
        let params = #"{"project_id":"\#(projectID!)","force":false}"#
        let data = try await InitializePublishTemplateTool.handle(
            paramsJSON: Data(params.utf8), registry: registry)
        let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(response?["status"] as? String, "initialized")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent(".maugham/publish/template.tex").path))
    }

    func testInitialize_refusesIfAlreadyInitialized() async throws {
        // Install once.
        _ = try await InitializePublishTemplateTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID!)"}"#.utf8),
            registry: registry)
        // Second without force.
        do {
            _ = try await InitializePublishTemplateTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(projectID!)"}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.invalidArgument(message) {
            XCTAssertTrue(message.lowercased().contains("already"),
                          "expected 'already' in error: \(message)")
        }
    }

    func testInitialize_force_overwrites() async throws {
        _ = try await InitializePublishTemplateTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID!)"}"#.utf8),
            registry: registry)
        let templateURL = projectURL.appendingPathComponent(".maugham/publish/template.tex")
        try "% mutated".write(to: templateURL, atomically: true, encoding: .utf8)
        _ = try await InitializePublishTemplateTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(projectID!)","force":true}"#.utf8),
            registry: registry)
        let content = try String(contentsOf: templateURL)
        XCTAssertFalse(content.contains("mutated"))
    }

    func testInitialize_unknownProjectID_throws() async throws {
        do {
            _ = try await InitializePublishTemplateTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_notreal"}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }

    func testInitialize_missingParams_throws() async throws {
        do {
            _ = try await InitializePublishTemplateTool.handle(
                paramsJSON: nil, registry: registry)
            XCTFail("expected throw")
        } catch MCPError.invalidArgument {
            // expected
        }
    }

    /// A Report's re-init picks the Report variant from the manifest's
    /// profile — the tool passes nothing but the project (R-4-6).
    func testInitialize_force_onAReport_reinstallsTheReportStarter() async throws {
        let reportURL = try await ProjectFactory.createReportProject(
            named: "R", in: tmp, shape: .sections)
        let store = try await ProjectStore.load(from: reportURL)
        registry.register(url: reportURL, store: store)
        let id = ProjectIdentifier.id(for: reportURL)
        let publish = reportURL.appendingPathComponent(".maugham/publish")
        try "% mutated".write(to: publish.appendingPathComponent("template.tex"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: publish.appendingPathComponent("prose.tex"))
        _ = try await InitializePublishTemplateTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(id)","force":true}"#.utf8), registry: registry)
        let template = try String(contentsOf: publish.appendingPathComponent("template.tex"), encoding: .utf8)
        XCTAssertTrue(template.contains("Report starter"), template)
        let prose = try Data(contentsOf: publish.appendingPathComponent("prose.tex"))
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "prose.tex", withExtension: nil,
                                                    subdirectory: "PublishStarter/report"))
        XCTAssertEqual(prose, try Data(contentsOf: bundled))
        XCTAssertEqual(try PublishConfigStore.read(in: reportURL)?.outputs.formatsEnabled, [.pdf, .docx])
    }
}

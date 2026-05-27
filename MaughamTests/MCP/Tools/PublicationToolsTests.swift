import XCTest
@testable import Maugham

@MainActor
final class PublicationToolsTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var pid: String!
    var projectURL: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicationToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "T", in: tmp)
        let store = try await ProjectStore.load(from: projectURL)
        registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        pid = ProjectIdentifier.id(for: projectURL)
        PublishingStores._resetForTesting()
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - tectonic locator (mirrors CompileToolsTests pattern)

    private func tectonicAvailable() -> Bool {
        let testBundlePath = Bundle(for: PublicationToolsTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        return (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil
    }

    // MARK: - list_publications

    func testList_emptyProject_returnsEmpty() async throws {
        let data = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pubs = resp?["publications"] as? [Any]
        XCTAssertNotNil(pubs, "expected publications array, got: \(resp ?? [:])")
        XCTAssertEqual(pubs?.count, 0)
    }

    func testList_returnsRecordedPublication() async throws {
        let stores = PublishingStores.sharedFor(
            projectID: pid, projectURL: projectURL)
        let pub = Publication(
            publicationID: "pub-abc",
            version: "0.5",
            label: "test",
            format: .pdf,
            outputPath: "Exports/T-v0.5.pdf",
            snapshotID: "snap-xyz",
            checkpointID: "ck-1",
            republishedFrom: nil,
            compiledAt: Date(),
            maughamVersion: "0.0.0",
            tectonicVersion: "0.15.0")
        try await stores.publicationStore.append(pub)

        let data = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pubs = resp?["publications"] as? [[String: Any]] ?? []
        XCTAssertEqual(pubs.count, 1)
        XCTAssertEqual(pubs.first?["version"] as? String, "0.5")
        XCTAssertEqual(pubs.first?["format"] as? String, "pdf")
    }

    func testList_filtersByFormat() async throws {
        let stores = PublishingStores.sharedFor(
            projectID: pid, projectURL: projectURL)
        let now = Date()
        try await stores.publicationStore.append(Publication(
            publicationID: "pub-1", version: "0.1", label: nil,
            format: .pdf, outputPath: "Exports/T-v0.1.pdf",
            snapshotID: "s1", checkpointID: "", republishedFrom: nil,
            compiledAt: now, maughamVersion: "0", tectonicVersion: "0.15.0"))
        try await stores.publicationStore.append(Publication(
            publicationID: "pub-2", version: "0.2", label: nil,
            format: .epub, outputPath: "Exports/T-v0.2.epub",
            snapshotID: "s2", checkpointID: "", republishedFrom: nil,
            compiledAt: now, maughamVersion: "0", tectonicVersion: "0.15.0"))

        let data = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"epub"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pubs = resp?["publications"] as? [[String: Any]] ?? []
        XCTAssertEqual(pubs.count, 1)
        XCTAssertEqual(pubs.first?["format"] as? String, "epub")
    }

    func testList_unknownProject_throws() async throws {
        do {
            _ = try await ListPublicationsTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_notreal"}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("unknown project_id"))
        }
    }

    // MARK: - read_publication_page

    func testReadPage_unknownVersion_throws() async throws {
        do {
            _ = try await ReadPublicationPageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","version":"9.9","page_number":1}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("9.9"),
                          "expected error to mention version, got: \(msg)")
        }
    }

    func testReadPage_unknownProject_throws() async throws {
        do {
            _ = try await ReadPublicationPageTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_notreal","version":"0.1","page_number":1}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("unknown project_id"))
        }
    }

    func testReadPage_returnsImageEnvelope() async throws {
        guard tectonicAvailable() else {
            throw XCTSkip("tectonic binary not bundled in test host")
        }
        // Compile to produce a real PDF first.
        _ = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":120}"#.utf8),
            registry: registry)
        // Discover the published version.
        let listData = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let listResp = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
        let pubs = listResp?["publications"] as? [[String: Any]] ?? []
        guard let version = pubs.last?["version"] as? String else {
            return XCTFail("compile did not record a publication")
        }

        let data = try await ReadPublicationPageTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","version":"\#(version)","page_number":1}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = resp?["content"] as? [[String: Any]] ?? []
        XCTAssertFalse(content.isEmpty, "expected content array")
        // Last block is the image; an earlier text block may explain fallback.
        let imageBlock = content.last
        XCTAssertEqual(imageBlock?["type"] as? String, "image")
        XCTAssertEqual(imageBlock?["mimeType"] as? String, "image/jpeg")
        XCTAssertNotNil(imageBlock?["data"] as? String)
    }

    func testReadPage_outOfRange_throws() async throws {
        guard tectonicAvailable() else {
            throw XCTSkip("tectonic binary not bundled in test host")
        }
        _ = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":120}"#.utf8),
            registry: registry)
        let listData = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let listResp = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
        let pubs = listResp?["publications"] as? [[String: Any]] ?? []
        guard let version = pubs.last?["version"] as? String else {
            return XCTFail("compile did not record a publication")
        }
        do {
            _ = try await ReadPublicationPageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","version":"\#(version)","page_number":999}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("page out of range"))
        }
    }

    // MARK: - republish

    func testRepublish_unknownProject_throws() async throws {
        do {
            _ = try await RepublishTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_notreal","snapshot_id":"snap-x"}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("unknown project_id"))
        }
    }

    func testRepublish_recompilesFromSnapshot() async throws {
        guard tectonicAvailable() else {
            throw XCTSkip("tectonic binary not bundled in test host")
        }
        // Initial compile.
        _ = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":120}"#.utf8),
            registry: registry)
        // Grab snapshot id from the recorded publication.
        let listData = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let listResp = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
        let pubs = listResp?["publications"] as? [[String: Any]] ?? []
        guard let snapshotID = pubs.last?["snapshot_id"] as? String,
              let priorVersion = pubs.last?["version"] as? String else {
            return XCTFail("compile did not record a snapshot_id/version")
        }

        let data = try await RepublishTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","snapshot_id":"\#(snapshotID)","format":"pdf"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "completed",
                       "unexpected: \(resp ?? [:])")
        XCTAssertEqual(resp?["format"] as? String, "pdf")

        // New publication should have republished_from set to prior version.
        let after = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let afterResp = try JSONSerialization.jsonObject(with: after) as? [String: Any]
        let afterPubs = afterResp?["publications"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(afterPubs.count, 2)
        XCTAssertEqual(afterPubs.last?["republished_from"] as? String, priorVersion)
    }
}

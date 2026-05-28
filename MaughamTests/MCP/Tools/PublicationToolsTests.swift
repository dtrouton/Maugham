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

    // MARK: - D3b: publication_id addressing

    /// Seed two publications at the same version (the version-collision case
    /// surfaced by external testing) and verify publication_id can address
    /// them apart.
    private func seedCollidingPublications() async throws -> (older: Publication, newer: Publication) {
        let stores = PublishingStores.sharedFor(
            projectID: pid!, projectURL: projectURL)
        let older = Publication(
            publicationID: "pub-older-test",
            version: "0.1", label: "first", format: .pdf,
            outputPath: "Exports/older.pdf",
            snapshotID: "snap-older", checkpointID: "",
            republishedFrom: nil,
            compiledAt: Date(timeIntervalSinceNow: -3600),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0")
        let newer = Publication(
            publicationID: "pub-newer-test",
            version: "0.1", label: "second", format: .pdf,
            outputPath: "Exports/newer.pdf",
            snapshotID: "snap-newer", checkpointID: "",
            republishedFrom: nil,
            compiledAt: Date(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0")
        try await stores.publicationStore.append(older)
        try await stores.publicationStore.append(newer)
        return (older, newer)
    }

    func testList_filtersByPublicationID() async throws {
        let (older, _) = try await seedCollidingPublications()
        let data = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","publication_id":"\#(older.publicationID)"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let pubs = resp["publications"] as? [[String: Any]] ?? []
        XCTAssertEqual(pubs.count, 1)
        XCTAssertEqual(pubs.first?["publication_id"] as? String, older.publicationID)
    }

    func testList_filtersByVersion_returnsAllColliding() async throws {
        // Behaviour preserved from before publication_id addressing was added:
        // version filter returns ALL matching publications. Agents that want
        // exactly one should use publication_id.
        _ = try await seedCollidingPublications()
        let data = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","version":"0.1"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let pubs = resp["publications"] as? [[String: Any]] ?? []
        XCTAssertEqual(pubs.count, 2,
                       "version filter must return both colliding publications")
    }

    func testReadPage_acceptsPublicationID_resolvesUnambiguously() async throws {
        // Write a minimal PDF for each colliding publication so the rasterizer
        // can actually open them. Hand-craft is overkill — borrow from the
        // testReadPage_returnsImageEnvelope fixture path by running a compile.
        // Simpler: seed publications that point at the SAME existing PDF (the
        // baseline produced by setUp's compile step, if any). For this test
        // we just verify the *addressing path* works: the tool resolves to the
        // requested publication_id and either succeeds or fails with an error
        // that names the specific publication, not the wrong one.
        let (older, newer) = try await seedCollidingPublications()

        // Both pubs point at nonexistent PDFs — read_publication_page will
        // fail to open. What matters is which one it TRIED — the error
        // message must reference the requested publication's path, proving
        // addressing-by-publication-id resolved to the right record.
        do {
            _ = try await ReadPublicationPageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","publication_id":"\#(older.publicationID)","page_number":1}"#.utf8),
                registry: registry)
            XCTFail("expected throw — fixture has no PDF on disk")
        } catch let MCPError.internalError(msg) {
            XCTAssertTrue(msg.contains("older.pdf"),
                          "expected error to reference older.pdf (the older publication's outputPath), got: \(msg)")
            XCTAssertFalse(msg.contains("newer.pdf"))
        }

        // Inverse: request the newer one, must reference newer.pdf.
        do {
            _ = try await ReadPublicationPageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","publication_id":"\#(newer.publicationID)","page_number":1}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.internalError(msg) {
            XCTAssertTrue(msg.contains("newer.pdf"),
                          "expected error to reference newer.pdf, got: \(msg)")
        }
    }

    func testReadPage_unknownPublicationID_throws() async throws {
        do {
            _ = try await ReadPublicationPageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","publication_id":"pub-does-not-exist","page_number":1}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("pub-does-not-exist"))
        }
    }

    func testReadPage_publicationIDAndVersionDisagree_throws() async throws {
        let (older, _) = try await seedCollidingPublications()
        do {
            _ = try await ReadPublicationPageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","publication_id":"\#(older.publicationID)","version":"9.9","page_number":1}"#.utf8),
                registry: registry)
            XCTFail("expected throw — version='9.9' does not match older.version='0.1'")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("9.9"))
            XCTAssertTrue(msg.contains("0.1"))
        }
    }

    func testReadPage_neitherPublicationIDNorVersion_throws() async throws {
        do {
            _ = try await ReadPublicationPageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","page_number":1}"#.utf8),
                registry: registry)
            XCTFail("expected throw — neither addressing key provided")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.lowercased().contains("publication_id")
                          || msg.lowercased().contains("version"))
        }
    }
}

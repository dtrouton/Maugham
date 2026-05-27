import XCTest
import PDFKit
import CommonCrypto
@testable import Maugham

@MainActor
final class PublishingEndToEndTests: XCTestCase {

    var tmp: URL!
    var projectURL: URL!
    var registry: ProjectRegistry!
    var pid: String!

    // Mirrors CompileToolsTests / PublicationToolsTests: in the xctest harness
    // Bundle.main isn't the host .app, so TectonicLocator.locate() returns nil even
    // though tectonic is bundled. Probe the host explicitly.
    private func tectonicAvailable() -> Bool {
        let testBundlePath = Bundle(for: PublishingEndToEndTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        return (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil
    }

    override func setUp() async throws {
        guard tectonicAvailable() else {
            throw XCTSkip("tectonic binary not bundled in test host — full E2E requires bundled binary")
        }
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // ProjectFactory.createNovelProject installs the publish starter automatically.
        projectURL = try await ProjectFactory.createNovelProject(named: "E2E", in: tmp)
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

    // MARK: - Task 47: full flow

    func testFullFlow_initialize_setConfig_compilePDF_compileEPUB_listPublications_readPage() async throws {
        // 1. Initialize publish template (force=true because ProjectFactory already
        //    installed it; this exercises the overwrite path and keeps the E2E
        //    test self-contained / template-reset).
        let initData = try await InitializePublishTemplateTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","force":true}"#.utf8),
            registry: registry)
        let initResp = try JSONSerialization.jsonObject(with: initData) as? [String: Any]
        XCTAssertEqual(initResp?["status"] as? String, "initialized",
                       "unexpected initialize response: \(initResp ?? [:])")

        // 2. Set basic metadata.
        let cfgData = try await SetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","patch":{"metadata":{"title":"E2E Book","author":"Tester"}}}"#.utf8),
            registry: registry)
        let cfgResp = try JSONSerialization.jsonObject(with: cfgData) as? [String: Any]
        // SetPublishConfigTool returns {"config": {...}, "errors": [...]} — no "status" key.
        // Confirm errors is empty (patch was valid).
        let cfgErrors = cfgResp?["errors"] as? [[String: Any]] ?? []
        XCTAssertTrue(cfgErrors.isEmpty,
                      "unexpected config validation errors: \(cfgErrors)")

        // 3. Compile PDF.
        // wait_seconds=180 because the first tectonic invocation may download
        // ~150 MB of TeX Live packages on a cold cache (subsequent runs reuse
        // ~/Library/Caches/Maugham/tectonic/ and finish in <1s).
        let pdfData = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":180}"#.utf8),
            registry: registry)
        let pdfResp = try JSONSerialization.jsonObject(with: pdfData) as? [String: Any]
        XCTAssertEqual(pdfResp?["status"] as? String, "completed",
                       "PDF compile failed: \(pdfResp ?? [:])")
        XCTAssertEqual(pdfResp?["format"] as? String, "pdf")
        XCTAssertNotNil(pdfResp?["output_path"])
        XCTAssertNotNil(pdfResp?["version"])

        // 4. Compile EPUB.
        // Cache is warm by this point; 60s is ample.
        let epubData = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"epub","wait_seconds":60}"#.utf8),
            registry: registry)
        let epubResp = try JSONSerialization.jsonObject(with: epubData) as? [String: Any]
        XCTAssertEqual(epubResp?["status"] as? String, "completed",
                       "EPUB compile failed: \(epubResp ?? [:])")
        XCTAssertEqual(epubResp?["format"] as? String, "epub")

        // 5. List publications — should have PDF (v0.1) and EPUB (v0.2).
        let listData = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let listResp = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
        let pubs = listResp?["publications"] as? [[String: Any]] ?? []
        XCTAssertEqual(pubs.count, 2,
                       "expected 2 publications (pdf + epub), got: \(pubs.count)")

        // 6. Read PDF page 1 as image (MCP image-response envelope: content array).
        let pageData = try await ReadPublicationPageTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","version":"0.1","page_number":1}"#.utf8),
            registry: registry)
        let pageResp = try JSONSerialization.jsonObject(with: pageData) as? [String: Any]
        let content = pageResp?["content"] as? [[String: Any]] ?? []
        XCTAssertFalse(content.isEmpty,
                       "expected content array in page response, got: \(pageResp ?? [:])")
        let imageBlock = content.last
        XCTAssertEqual(imageBlock?["type"] as? String, "image")
        XCTAssertEqual(imageBlock?["mimeType"] as? String, "image/jpeg")
        XCTAssertNotNil(imageBlock?["data"])

        // 7. Verify Exports/ contains both files on disk.
        // output_path in the compile response is relative to projectURL
        // (e.g. "Exports/E2E Book-v0.1.pdf"). Resolve it here.
        let pdfOutputPath = pdfResp?["output_path"] as? String ?? ""
        let epubOutputPath = epubResp?["output_path"] as? String ?? ""
        let pdfURL = resolveOutputPath(pdfOutputPath)
        let epubURL = resolveOutputPath(epubOutputPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path),
                      "PDF not found at \(pdfURL.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: epubURL.path),
                      "EPUB not found at \(epubURL.path)")
    }

    // MARK: - Task 48: republish reproducibility

    func testRepublish_producesIdenticalContent_evenAfterTemplateMutation() async throws {
        // 1. Set metadata and compile v0.1 (template already installed by setUp).
        _ = try await SetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","patch":{"metadata":{"title":"Repro","author":"T"}}}"#.utf8),
            registry: registry)
        _ = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":180}"#.utf8),
            registry: registry)

        // 2. Locate and verify the v0.1 PDF on disk.
        // output_path is relative; resolve against projectURL.
        let v01RelPath = "Exports/Repro-v0.1.pdf"
        let v01URL = projectURL.appendingPathComponent(v01RelPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: v01URL.path),
                      "v0.1 PDF not found at \(v01URL.path)")

        // 3. Capture a hash of the original PDF (demonstrating byte-identity isn't
        //    expected across runs — only content-text identity is).
        let originalHash = try sha256(of: v01URL)

        // 4. Mutate the live template to garbage so any fresh compile would fail.
        let templateURL = projectURL.appendingPathComponent(".maugham/publish/template.tex")
        try "\\notarealcommand".write(to: templateURL, atomically: true, encoding: .utf8)

        // 5. Find the v0.1 publication's snapshot_id.
        let listData = try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","version":"0.1"}"#.utf8),
            registry: registry)
        let listResp = try JSONSerialization.jsonObject(with: listData) as? [String: Any]
        let pubs = (listResp?["publications"] as? [[String: Any]]) ?? []
        guard let snapshotID = pubs.first?["snapshot_id"] as? String else {
            XCTFail("no snapshot_id in v0.1 publication; pubs=\(pubs)")
            return
        }

        // 6. Republish from snapshot — should use the snapshotted template, not
        //    the garbage we just wrote.
        let rData = try await RepublishTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","snapshot_id":"\#(snapshotID)","format":"pdf"}"#.utf8),
            registry: registry)
        let rResp = try JSONSerialization.jsonObject(with: rData) as? [String: Any]
        XCTAssertEqual(rResp?["status"] as? String, "completed",
                       "republish from valid snapshot failed; live template is invalid which is fine — snapshot has the good one; response: \(rResp ?? [:])")

        // 7. Verify text content is identical between original and republished PDF.
        //
        //    Byte equality is NOT expected (tectonic embeds compile timestamps in
        //    PDF metadata). Text content equality IS expected because the same
        //    manuscript + template is used.
        //
        //    We use a normalized comparator that collapses all whitespace runs to
        //    a single space. PDFKit text extraction can introduce minor whitespace
        //    differences (e.g. page boundaries inserting extra newlines). If you
        //    see this test fail in a future run, check whether the normalizer below
        //    needs to be loosened further — but try the strict comparator first.
        let republishedRawPath = rResp?["output_path"] as? String ?? ""
        let republishedURL = resolveOutputPath(republishedRawPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: republishedURL.path),
                      "republished PDF not found at \(republishedURL.path)")

        let originalText = pdfPlainText(at: v01URL)
        let republishedText = pdfPlainText(at: republishedURL)

        let normalize: (String) -> String = { text in
            text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        // Prefer the normalized comparator: PDFKit extraction can add/remove
        // whitespace at page margins. Byte equality would require identical TeX
        // timestamps which tectonic does not guarantee.
        XCTAssertEqual(normalize(originalText), normalize(republishedText),
                       "republished PDF text differs from original; snapshot did not preserve template")

        // Demonstrate hash was captured (byte-identical is not the goal here).
        _ = originalHash
    }

    // MARK: - Helpers

    private func resolveOutputPath(_ raw: String) -> URL {
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        return projectURL.appendingPathComponent(raw)
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var hash = [UInt8](repeating: 0, count: 32)
        _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func pdfPlainText(at url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var out = ""
        for i in 0..<doc.pageCount {
            out += doc.page(at: i)?.string ?? ""
        }
        return out
    }
}

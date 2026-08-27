import XCTest
import PDFKit
import AppKit
import MaughamCore
@testable import Maugham

@MainActor
final class ReadPreviewPageToolTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var pid: String!
    var projectURL: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadPreviewPageToolTests-\(UUID().uuidString)")
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

    // MARK: - Helpers

    private var previewDir: URL {
        projectURL.appendingPathComponent(PreviewCompiler.previewSubpath, isDirectory: true)
    }

    /// Write a minimal one-page PDF at `url`. `fillGray` distinguishes the
    /// rendered content so parity/freshness assertions can tell pages apart.
    @discardableResult
    private func writePDF(
        named name: String, in dir: URL,
        size: CGSize = CGSize(width: 200, height: 300),
        fillGray: CGFloat = 1.0,
        mtime: Date? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("could not create PDF context")
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: fillGray, alpha: 1))
        ctx.fill(mediaBox)
        ctx.endPDFPage()
        ctx.closePDF()
        if let mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    private func call(_ paramsJSON: String) async throws -> [String: Any] {
        let data = try await ReadPreviewPageTool.handle(
            paramsJSON: Data(paramsJSON.utf8), registry: registry)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: - No preview

    func testNoPreview_absentDir_throwsLoudly() async throws {
        do {
            _ = try await call(#"{"project_id":"\#(pid!)","page_number":1}"#)
            XCTFail("expected throw — no preview dir")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("No preview output — run preview_compile first"),
                          "got: \(msg)")
        }
    }

    func testNoPreview_emptyDir_throwsLoudly() async throws {
        try FileManager.default.createDirectory(
            at: previewDir, withIntermediateDirectories: true)
        do {
            _ = try await call(#"{"project_id":"\#(pid!)","page_number":1}"#)
            XCTFail("expected throw — empty preview dir")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("No preview output"), "got: \(msg)")
        }
    }

    func testUnknownProject_throws() async throws {
        do {
            _ = try await call(#"{"project_id":"proj_notreal","page_number":1}"#)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }

    // MARK: - Rendering

    func testRendersLatestPreview_returnsImageEnvelopeAndResolution() async throws {
        let url = try writePDF(named: "preview-0.1-pdf.pdf", in: previewDir)
        let resp = try await call(#"{"project_id":"\#(pid!)","page_number":1}"#)

        let content = resp["content"] as? [[String: Any]] ?? []
        let imageBlock = content.last
        XCTAssertEqual(imageBlock?["type"] as? String, "image")
        XCTAssertEqual(imageBlock?["mimeType"] as? String, "image/jpeg")
        XCTAssertNotNil(imageBlock?["data"] as? String)

        // Resolution metadata: filename + ISO8601 mtime.
        XCTAssertEqual(resp["preview_filename"] as? String, url.lastPathComponent)
        let mtimeStr = try XCTUnwrap(resp["preview_mtime"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: mtimeStr),
                        "preview_mtime must be ISO8601, got: \(mtimeStr)")
    }

    func testPageOutOfRange_throws() async throws {
        try writePDF(named: "preview-0.1-pdf.pdf", in: previewDir)
        do {
            _ = try await call(#"{"project_id":"\#(pid!)","page_number":99}"#)
            XCTFail("expected throw")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("page out of range"), "got: \(msg)")
        }
    }

    // MARK: - Freshness (newest-by-mtime resolution)

    func testResolvesNewestPDFByMtime() async throws {
        let old = Date(timeIntervalSinceNow: -3600)
        let new = Date()
        try writePDF(named: "preview-old.pdf", in: previewDir, mtime: old)
        try writePDF(named: "preview-new.pdf", in: previewDir, mtime: new)

        let resp = try await call(#"{"project_id":"\#(pid!)","page_number":1}"#)
        XCTAssertEqual(resp["preview_filename"] as? String, "preview-new.pdf",
                       "must resolve the newest .pdf by mtime")
    }

    func testSecondPreviewWins_freshness() async throws {
        // First preview.
        try writePDF(named: "preview-A.pdf", in: previewDir,
                     mtime: Date(timeIntervalSinceNow: -100))
        var resp = try await call(#"{"project_id":"\#(pid!)","page_number":1}"#)
        XCTAssertEqual(resp["preview_filename"] as? String, "preview-A.pdf")

        // A newer preview lands → the tool must now read it.
        try writePDF(named: "preview-B.pdf", in: previewDir, mtime: Date())
        resp = try await call(#"{"project_id":"\#(pid!)","page_number":1}"#)
        XCTAssertEqual(resp["preview_filename"] as? String, "preview-B.pdf",
                       "a newer preview must become the new resolution target")
    }

    // MARK: - The BSD `hidden` flag is not Maugham's to honour

    /// 2026-08-27: a synced Documents folder flagged every file under
    /// `.maugham/` `UF_HIDDEN` behind Maugham's back, and `.skipsHiddenFiles`
    /// then answered "No preview output" over a directory holding two
    /// previews. The tool skips by NAME only (`DotfileScan`).
    func testHiddenFlaggedPreview_isStillFound() async throws {
        let url = try writePDF(named: "preview-0.1-pdf-sr.pdf", in: previewDir)
        var values = URLResourceValues()
        values.isHidden = true
        var flagged = url
        try flagged.setResourceValues(values)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isHiddenKey]).isHidden, true,
                       "premise: the flag must actually be set")

        let resp = try await call(#"{"project_id":"\#(pid!)","page_number":1}"#)
        XCTAssertEqual(resp["preview_filename"] as? String, "preview-0.1-pdf-sr.pdf",
                       "a preview the OS flags hidden is still the latest preview")
    }

    /// A genuinely dot-prefixed entry (an editor's swap file, a sync
    /// sidecar) is still skipped, and by its name.
    func testDotPrefixedEntry_isSkippedByName() async throws {
        try writePDF(named: "preview-0.1-pdf.pdf", in: previewDir,
                     mtime: Date(timeIntervalSinceNow: -100))
        try writePDF(named: ".preview-0.1-pdf.pdf.icloud", in: previewDir, mtime: Date())
        let resp = try await call(#"{"project_id":"\#(pid!)","page_number":1}"#)
        XCTAssertEqual(resp["preview_filename"] as? String, "preview-0.1-pdf.pdf")
    }

    /// The language-suffixed name `PreviewCompiler` writes for an edition
    /// preview resolves like any other, newest by mtime in either direction.
    func testLanguageSuffixedPreview_ordersByMtimeWithTheSourcePreview() async throws {
        try writePDF(named: "preview-0.1-pdf.pdf", in: previewDir,
                     mtime: Date(timeIntervalSinceNow: -3600))
        try writePDF(named: "preview-0.1-pdf-sr.pdf", in: previewDir,
                     mtime: Date(timeIntervalSinceNow: -60))
        var resp = try await call(#"{"project_id":"\#(pid!)","page_number":1}"#)
        XCTAssertEqual(resp["preview_filename"] as? String, "preview-0.1-pdf-sr.pdf")

        // A later source-language preview wins back.
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: previewDir.appendingPathComponent("preview-0.1-pdf.pdf").path)
        resp = try await call(#"{"project_id":"\#(pid!)","page_number":1}"#)
        XCTAssertEqual(resp["preview_filename"] as? String, "preview-0.1-pdf.pdf")
    }

    // MARK: - EPUB is not rasterizable

    func testLatestPreviewIsEPUB_throwsClearly() async throws {
        try writePDF(named: "preview-old-pdf.pdf", in: previewDir,
                     mtime: Date(timeIntervalSinceNow: -3600))
        // A newer .epub is the latest preview → PDF-only error, not a silent
        // fall back to the stale PDF.
        try FileManager.default.createDirectory(
            at: previewDir, withIntermediateDirectories: true)
        let epub = previewDir.appendingPathComponent("preview-new-epub.epub")
        try Data("PK".utf8).write(to: epub)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: epub.path)

        do {
            _ = try await call(#"{"project_id":"\#(pid!)","page_number":1}"#)
            XCTFail("expected throw — latest preview is EPUB")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("EPUB"), "got: \(msg)")
        }
    }

    // MARK: - Parity with read_publication_page

    /// The exact same PDF file, addressed as a preview vs. as a Publication,
    /// must rasterize to byte-identical JPEG payloads for the same page and
    /// region — read_preview_page reuses the same rasterize+encode path.
    func testParityWithReadPublicationPage_pageAndRegion() async throws {
        // One PDF in the preview dir; point a Publication record at the same
        // file (relative path) so both tools open identical bytes.
        try writePDF(named: "preview-0.1-pdf.pdf", in: previewDir,
                     fillGray: 0.5)
        let relPath = "\(PreviewCompiler.previewSubpath)/preview-0.1-pdf.pdf"

        let stores = PublishingStores.sharedFor(projectID: pid!, projectURL: projectURL)
        try await stores.publicationStore.append(Publication(
            publicationID: "pub-parity", version: "0.1", label: nil,
            format: .pdf, outputPath: relPath,
            snapshotID: "s", checkpointID: "", republishedFrom: nil,
            compiledAt: Date(), maughamVersion: "0", tectonicVersion: "0.15.0"))

        func imageData(from resp: [String: Any]) throws -> String {
            let content = resp["content"] as? [[String: Any]] ?? []
            let block = try XCTUnwrap(content.last)
            return try XCTUnwrap(block["data"] as? String)
        }

        // Full page parity.
        let previewFull = try await call(#"{"project_id":"\#(pid!)","page_number":1}"#)
        let pubFullData = try await ReadPublicationPageTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","version":"0.1","page_number":1}"#.utf8),
            registry: registry)
        let pubFull = try JSONSerialization.jsonObject(with: pubFullData) as? [String: Any] ?? [:]
        XCTAssertEqual(try imageData(from: previewFull), try imageData(from: pubFull),
                       "full-page rasterization must match read_publication_page")

        // Region crop parity.
        let region = #"{"x":0.1,"y":0.1,"width":0.5,"height":0.5}"#
        let previewCrop = try await call(
            #"{"project_id":"\#(pid!)","page_number":1,"region":\#(region)}"#)
        let pubCropData = try await ReadPublicationPageTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","version":"0.1","page_number":1,"region":\#(region)}"#.utf8),
            registry: registry)
        let pubCrop = try JSONSerialization.jsonObject(with: pubCropData) as? [String: Any] ?? [:]
        XCTAssertEqual(try imageData(from: previewCrop), try imageData(from: pubCrop),
                       "region-cropped rasterization must match read_publication_page")
    }
}

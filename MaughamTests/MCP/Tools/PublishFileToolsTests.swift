import XCTest
import AppKit
@testable import Maugham

@MainActor
final class PublishFileToolsTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var pid: String!
    var projectURL: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PubFileToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "T", in: tmp)
        // ProjectFactory already installed the publish starter via
        // PublishStarter.installIfMissing — so template.tex/styles.css/config.json
        // are all present.
        let store = try await ProjectStore.load(from: projectURL)
        registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        pid = ProjectIdentifier.id(for: projectURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - list_publish_files

    func testList_returnsStarterFiles() async throws {
        let data = try await ListPublishFilesTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let files = (resp?["files"] as? [[String: Any]]) ?? []
        let names = Set(files.compactMap { $0["path"] as? String })
        XCTAssertTrue(names.contains("template.tex"), "expected template.tex, got \(names)")
        XCTAssertTrue(names.contains("styles.css"))
        XCTAssertTrue(names.contains("config.json"))
        // Each row should have size + modified_at populated.
        for f in files {
            XCTAssertNotNil(f["size"])
            XCTAssertNotNil(f["modified_at"])
        }
    }

    func testList_skipsBuildSubdir() async throws {
        // Plant a file under build/ — should not appear in the listing.
        let build = projectURL.appendingPathComponent(".maugham/publish/build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "% transient".write(
            to: build.appendingPathComponent("foo.aux"),
            atomically: true, encoding: .utf8)

        let data = try await ListPublishFilesTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let files = (resp?["files"] as? [[String: Any]]) ?? []
        let names = files.compactMap { $0["path"] as? String }
        XCTAssertFalse(names.contains(where: { $0.hasPrefix("build/") }),
                       "build/ should be skipped, got \(names)")
    }

    func test_listPublishFiles_surfacesBuildArtifactsSeparately() async throws {
        // Plant a top-level file and a build/ file.
        let publishRoot = projectURL.appendingPathComponent(".maugham/publish")
        let buildDir = publishRoot.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try "% prose".write(
            to: publishRoot.appendingPathComponent("prose.tex"),
            atomically: true, encoding: .utf8)
        try "% body".write(
            to: buildDir.appendingPathComponent("body.tex"),
            atomically: true, encoding: .utf8)

        let data = try await ListPublishFilesTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // files must contain prose.tex
        let files = (obj?["files"] as? [[String: Any]]) ?? []
        let filePaths = Set(files.compactMap { $0["path"] as? String })
        XCTAssertTrue(filePaths.contains("prose.tex"), "prose.tex missing from files: \(filePaths)")

        // files must NOT contain any build/ path
        XCTAssertFalse(filePaths.contains(where: { $0.hasPrefix("build/") }),
                       "build/ paths should not appear in files: \(filePaths)")

        // build_artifacts must contain build/body.tex
        let buildArtifacts = (obj?["build_artifacts"] as? [[String: Any]]) ?? []
        let buildPaths = Set(buildArtifacts.compactMap { $0["path"] as? String })
        XCTAssertTrue(buildPaths.contains("build/body.tex"),
                      "build/body.tex missing from build_artifacts: \(buildPaths)")

        // _diagnostic must be absent
        XCTAssertNil(obj?["_diagnostic"], "_diagnostic should be absent from response")
    }

    func test_listPublishFiles_returnsEveryRegularFile() async throws {
        // Plant a set of files including a nested one.
        let publishRoot = projectURL.appendingPathComponent(".maugham/publish")
        let piecesDir = publishRoot.appendingPathComponent("pieces")
        try FileManager.default.createDirectory(at: piecesDir, withIntermediateDirectories: true)
        try "% t".write(to: publishRoot.appendingPathComponent("template2.tex"),
                        atomically: true, encoding: .utf8)
        try "% p".write(to: publishRoot.appendingPathComponent("prose2.tex"),
                        atomically: true, encoding: .utf8)
        try "{}".write(to: publishRoot.appendingPathComponent("config2.json"),
                       atomically: true, encoding: .utf8)
        try "% tribute".write(to: piecesDir.appendingPathComponent("tribute.tex"),
                              atomically: true, encoding: .utf8)

        let data = try await ListPublishFilesTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let files = (obj?["files"] as? [[String: Any]]) ?? []
        let filePaths = Set(files.compactMap { $0["path"] as? String })

        // All planted files must appear (completeness regression net).
        for expected in ["template2.tex", "prose2.tex", "config2.json", "pieces/tribute.tex"] {
            XCTAssertTrue(filePaths.contains(expected),
                          "\(expected) missing from listing: \(filePaths)")
        }
    }

    func testList_unknownProject_throws() async throws {
        do {
            _ = try await ListPublishFilesTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_notreal"}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }

    // MARK: - read_publish_file

    func testReadFile_returnsTemplateContent() async throws {
        let data = try await ReadPublishFileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"template.tex"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["path"] as? String, "template.tex")
        let content = resp?["content"] as? String ?? ""
        XCTAssertFalse(content.isEmpty)
        // Sanity: starter template references LaTeX commands.
        XCTAssertTrue(content.contains("\\"))
    }

    func testReadFile_missingFile_throws() async throws {
        do {
            _ = try await ReadPublishFileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"nope.tex"}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("not found"))
        }
    }

    // MARK: - path validation

    func testPathValidation_rejectsDotDotSegment() async throws {
        do {
            _ = try await ReadPublishFileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"../../../etc/passwd"}"#.utf8),
                registry: registry)
            XCTFail("expected reject")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains(".."), "expected '..' in error: \(msg)")
        }
    }

    func testPathValidation_rejectsNestedDotDot() async throws {
        do {
            _ = try await ReadPublishFileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"chapter/../escape.tex"}"#.utf8),
                registry: registry)
            XCTFail("expected reject")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains(".."))
        }
    }

    func testPathValidation_acceptsLegalDotDotInFilename() async throws {
        // `chapter..outline.tex` contains `..` as a substring but not as a
        // path segment. Should be a legal filename.
        let params = #"{"project_id":"\#(pid!)","path":"chapter..outline.tex","content":"% legal"}"#
        _ = try await WritePublishFileTool.handle(
            paramsJSON: Data(params.utf8), registry: registry)
        let read = try await ReadPublishFileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"chapter..outline.tex"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: read) as? [String: Any]
        XCTAssertEqual(resp?["content"] as? String, "% legal")
    }

    func testPathValidation_rejectsLeadingSlash() async throws {
        do {
            _ = try await ReadPublishFileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"/etc/passwd"}"#.utf8),
                registry: registry)
            XCTFail("expected reject")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("relative"))
        }
    }

    func testPathValidation_rejectsNullByte() async throws {
        // JSON can carry a literal NUL via  .
        let raw = "{\"project_id\":\"\(pid!)\",\"path\":\"foo\\u0000bar.txt\"}"
        do {
            _ = try await ReadPublishFileTool.handle(
                paramsJSON: Data(raw.utf8), registry: registry)
            XCTFail("expected reject")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("null"))
        }
    }

    func testPathValidation_rejectsEmptyPath() async throws {
        do {
            _ = try await ReadPublishFileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","path":""}"#.utf8),
                registry: registry)
            XCTFail("expected reject")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.lowercased().contains("empty"))
        }
    }

    // MARK: - write_publish_file

    func testWriteFile_utf8Content() async throws {
        let params = #"{"project_id":"\#(pid!)","path":"prose.tex","content":"% new"}"#
        let data = try await WritePublishFileTool.handle(
            paramsJSON: Data(params.utf8), registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "written")
        let written = try String(contentsOf:
            projectURL.appendingPathComponent(".maugham/publish/prose.tex"),
            encoding: .utf8)
        XCTAssertEqual(written, "% new")
    }

    func testWriteFile_base64Binary() async throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let b64 = bytes.base64EncodedString()
        let params = #"{"project_id":"\#(pid!)","path":"cover.jpg","content":"\#(b64)","content_encoding":"base64"}"#
        _ = try await WritePublishFileTool.handle(
            paramsJSON: Data(params.utf8), registry: registry)
        let written = try Data(contentsOf:
            projectURL.appendingPathComponent(".maugham/publish/cover.jpg"))
        XCTAssertEqual(written, bytes)
    }

    func testWriteFile_invalidBase64_throws() async throws {
        let params = #"{"project_id":"\#(pid!)","path":"cover.jpg","content":"not-valid!!","content_encoding":"base64"}"#
        do {
            _ = try await WritePublishFileTool.handle(
                paramsJSON: Data(params.utf8), registry: registry)
            XCTFail("expected reject")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("base64"))
        }
    }

    func testWriteFile_unknownEncoding_throws() async throws {
        let params = #"{"project_id":"\#(pid!)","path":"foo.txt","content":"x","content_encoding":"hex"}"#
        do {
            _ = try await WritePublishFileTool.handle(
                paramsJSON: Data(params.utf8), registry: registry)
            XCTFail("expected reject")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("utf8"))
        }
    }

    func testWriteFile_createsSubdirectory() async throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let b64 = bytes.base64EncodedString()
        let params = #"{"project_id":"\#(pid!)","path":"assets/cover.jpg","content":"\#(b64)","content_encoding":"base64"}"#
        _ = try await WritePublishFileTool.handle(
            paramsJSON: Data(params.utf8), registry: registry)
        let assetsDir = projectURL
            .appendingPathComponent(".maugham/publish/assets")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetsDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        let written = try Data(contentsOf:
            assetsDir.appendingPathComponent("cover.jpg"))
        XCTAssertEqual(written, bytes)
    }

    // MARK: - delete_publish_file

    func testDeleteFile_userFile_succeeds() async throws {
        // Create a NON-protected user file first. After D2 (2026-05-28) any
        // *.tex/.css/.json file directly under .maugham/publish/ is
        // protected, so this uses .md to exercise the unprotected path.
        let url = projectURL.appendingPathComponent(".maugham/publish/scratch.md")
        try "# scratch".write(to: url, atomically: true, encoding: .utf8)

        let data = try await DeletePublishFileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"scratch.md"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - D2: expanded delete protection

    /// Regression test for D2 (2026-05-28). Every starter file ships as a
    /// `*.tex`, `*.css`, or `*.json` at the publish root; all are now
    /// protected. Previously only template.tex/config.json/styles.css were.
    /// External tester surfaced the gap by deleting `preamble.tex` without
    /// force, which silently broke every subsequent PDF compile.
    func testDeleteFile_protectsAllStarterPartials() async throws {
        for partial in [
            "preamble.tex", "prose.tex", "screenplay.tex",
            "frontmatter.tex", "backmatter.tex"
        ] {
            do {
                _ = try await DeletePublishFileTool.handle(
                    paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"\#(partial)"}"#.utf8),
                    registry: registry)
                XCTFail("\(partial) deleted without force — protection gap regression")
            } catch let MCPError.invalidArgument(msg) {
                XCTAssertTrue(msg.lowercased().contains("protected"),
                              "wrong error for \(partial): \(msg)")
            }
            // File must still exist on disk.
            let url = projectURL.appendingPathComponent(".maugham/publish/\(partial)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(partial) shouldn't have been deleted")
        }
    }

    func testDeleteFile_allowsNestedDirEvenIfTexExtension() async throws {
        // The protection rule is "at publish root only" — files in nested
        // dirs (fonts/, build/, user-created) must remain freely deletable
        // regardless of extension.
        let nested = projectURL.appendingPathComponent(
            ".maugham/publish/scratch-dir/draft.tex")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "% nested".write(to: nested, atomically: true, encoding: .utf8)

        let data = try await DeletePublishFileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"scratch-dir/draft.tex"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
    }

    func testDeleteFile_refusesProtectedWithoutForce() async throws {
        do {
            _ = try await DeletePublishFileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"template.tex"}"#.utf8),
                registry: registry)
            XCTFail("expected reject")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.lowercased().contains("protected"))
        }
        // template.tex still on disk.
        let url = projectURL.appendingPathComponent(".maugham/publish/template.tex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeleteFile_protectedWithForce_succeeds() async throws {
        let data = try await DeletePublishFileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"template.tex","force":true}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "deleted")
        let url = projectURL.appendingPathComponent(".maugham/publish/template.tex")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - read_publish_image

    func testReadImage_throughEnvelope() async throws {
        // Plant a real PNG so NSImage can decode it.
        let png = try makeSolidPNG(width: 16, height: 16, color: .red)
        let url = projectURL.appendingPathComponent(".maugham/publish/cover.png")
        try png.write(to: url)

        let data = try await ReadPublishImageTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"cover.png"}"#.utf8),
            registry: registry)
        // Verify the MCP envelope shape: {content: [{type: "image",
        // data: ..., mimeType: "image/jpeg"}]}.
        let any = try JSONDecoder().decode(AnyJSON.self, from: data)
        guard case .object(let obj) = any,
              case .array(let content) = obj["content"] else {
            return XCTFail("expected {content: [...]}, got \(any)")
        }
        XCTAssertGreaterThanOrEqual(content.count, 1)
        // Last block should be the image (fallback note may precede it).
        guard case .object(let imgBlock) = content.last,
              case .string(let typ) = imgBlock["type"],
              case .string(let b64) = imgBlock["data"],
              case .string(let mime) = imgBlock["mimeType"] else {
            return XCTFail("expected image block, got \(content)")
        }
        XCTAssertEqual(typ, "image")
        XCTAssertEqual(mime, "image/jpeg")
        XCTAssertFalse(b64.isEmpty)
        // Decoded JPEG should be non-empty bytes.
        XCTAssertNotNil(Data(base64Encoded: b64))
    }

    func testReadImage_missingFile_throws() async throws {
        do {
            _ = try await ReadPublishImageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"missing.png"}"#.utf8),
                registry: registry)
            XCTFail("expected reject")
        } catch let MCPError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("not found"))
        }
    }

    func testReadImage_regionCrop() async throws {
        let png = try makeSolidPNG(width: 32, height: 32, color: .blue)
        let url = projectURL.appendingPathComponent(".maugham/publish/cover.png")
        try png.write(to: url)

        let req = #"{"project_id":"\#(pid!)","path":"cover.png","region":{"x":0.0,"y":0.0,"width":0.5,"height":0.5}}"#
        let data = try await ReadPublishImageTool.handle(
            paramsJSON: Data(req.utf8), registry: registry)
        let any = try JSONDecoder().decode(AnyJSON.self, from: data)
        guard case .object(let obj) = any,
              case .array(let content) = obj["content"],
              let last = content.last,
              case .object(let imgBlock) = last,
              case .string = imgBlock["data"] else {
            return XCTFail("expected image envelope")
        }
    }

    // MARK: - helpers

    private func makeSolidPNG(width: Int, height: Int, color: NSColor) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: - Reproduction: list_publish_files after a non-protected delete
    //
    // External report (Claude Desktop session, 2026-05-28): after deleting
    // an unprotected starter file (preamble.tex), list_publish_files
    // returned {"files":[]} even though template.tex etc. remained on disk
    // and read_publish_file could read them. This test exercises the
    // narrowed sequence in a clean fixture to confirm whether the bug is
    // in our code or environmental.

    func testList_afterForcedDelete_stillShowsRemainingFiles() async throws {
        // Confirm starter is installed and listing works pre-delete.
        let pre = try await ListPublishFilesTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let preResp = try JSONSerialization.jsonObject(with: pre) as? [String: Any]
        let preFiles = (preResp?["files"] as? [[String: Any]]) ?? []
        let preNames = Set(preFiles.compactMap { $0["path"] as? String })
        XCTAssertTrue(preNames.contains("preamble.tex"),
                      "test fixture missing preamble.tex — got \(preNames)")
        XCTAssertTrue(preNames.contains("template.tex"))
        let preCount = preFiles.count

        // Delete preamble.tex with force=true (post-D2 it's now protected;
        // this repro test specifically exercises the "force delete then
        // list" sequence the external tester ran).
        _ = try await DeletePublishFileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"preamble.tex","force":true}"#.utf8),
            registry: registry)

        // Sanity: preamble is gone from disk, template still on disk.
        let preambleURL = projectURL.appendingPathComponent(
            ".maugham/publish/preamble.tex")
        let templateURL = projectURL.appendingPathComponent(
            ".maugham/publish/template.tex")
        XCTAssertFalse(FileManager.default.fileExists(atPath: preambleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: templateURL.path))

        // Re-list. The bug report claims this returns empty. We assert that
        // every surviving disk file is still represented in the listing.
        let post = try await ListPublishFilesTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        let postResp = try JSONSerialization.jsonObject(with: post) as? [String: Any]
        let postFiles = (postResp?["files"] as? [[String: Any]]) ?? []
        let postNames = Set(postFiles.compactMap { $0["path"] as? String })

        XCTAssertEqual(postFiles.count, preCount - 1,
                       "expected exactly one fewer file after delete; pre=\(preCount), post=\(postFiles.count), names=\(postNames)")
        XCTAssertTrue(postNames.contains("template.tex"),
                      "template.tex missing from post-delete listing: \(postNames)")
        XCTAssertFalse(postNames.contains("preamble.tex"),
                       "preamble.tex shouldn't be in listing after delete: \(postNames)")
    }

    /// Same sequence but adds a failed compile attempt between the delete
    /// and the second list — the tester ran a compile (which would fail
    /// because preamble.tex is missing) before observing the empty list.
    func testList_afterDeleteAndFailedCompile_stillShowsRemainingFiles() async throws {
        // Mirror PDFCompiler's host-bundle fallback used in XCTest harness:
        // Bundle.main is the runner, not the app, so TectonicLocator.locate()
        // would skip even though tectonic is bundled. Walk up to the app.
        let testBundlePath = Bundle(for: PublishFileToolsTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil else {
            throw XCTSkip("tectonic binary not bundled in test host")
        }

        _ = try await DeletePublishFileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"preamble.tex","force":true}"#.utf8),
            registry: registry)

        // Attempt a compile — expected to fail (template won't compile
        // without preamble.tex). We don't assert on the compile result;
        // we assert that the subsequent list call is intact.
        _ = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":60}"#.utf8),
            registry: registry)

        // Re-list. template.tex must still be present.
        let resp = try JSONSerialization.jsonObject(with:
            try await ListPublishFilesTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
                registry: registry)) as? [String: Any]
        let files = (resp?["files"] as? [[String: Any]]) ?? []
        let names = Set(files.compactMap { $0["path"] as? String })
        XCTAssertTrue(names.contains("template.tex"),
                      "template.tex missing from listing after failed compile: \(names)")
        XCTAssertGreaterThanOrEqual(files.count, 6,
                                    "expected at least the 7 surviving starter files; got \(files.count): \(names)")
    }
}

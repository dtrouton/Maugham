import XCTest
@testable import Maugham

@MainActor
final class PieceStyleToolsTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var pid: String!
    var projectURL: URL!
    /// The real piece id from the novel project's manifest (e.g. "doc-XXXXXXXX").
    var realPieceID: String!
    /// The title of that piece ("Chapter 1" for a novel project).
    var realPieceTitle: String!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PieceStyleToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "T", in: tmp)
        let store = try await ProjectStore.load(from: projectURL)
        registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        pid = ProjectIdentifier.id(for: projectURL)
        // Extract the real piece id + title from the manifest so tests don't use synthetic ids.
        let docs = ProjectStore.collectDocuments(in: store.manifest.structure)
        realPieceID = docs.first!.id
        realPieceTitle = docs.first!.title
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private var publishRoot: URL {
        projectURL.appendingPathComponent(".maugham/publish")
    }

    /// Concatenate the contents of every regular file under `dir` (recursive).
    private func recursiveContents(of dir: URL) -> String {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir,
                                     includingPropertiesForKeys: [.isRegularFileKey],
                                     options: []) else { return "" }
        var all = ""
        for case let url as URL in en {
            let res = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard res?.isRegularFile == true else { continue }
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                all += s
            }
        }
        return all
    }

    func test_setPieceStyle_writesFileAndWiresConfig() async throws {
        // Uses realPieceID from the manifest — synthetic ids ("ab12") now correctly throw.
        let params = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)","content":"% piece style","filename":"tribute.tex"}"#
        let data = try await SetPieceStyleTool.handle(
            paramsJSON: Data(params.utf8), registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "set")

        let fileURL = publishRoot.appendingPathComponent("pieces/tribute.tex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "pieces/tribute.tex should exist")

        let cfg = try await PublishConfigStore(projectURL: projectURL).load()
        XCTAssertEqual(cfg?.sections[realPieceID]?.styleFile, "tribute.tex")
    }

    func test_setPieceStyle_overwriteSendsPriorToTrash() async throws {
        // Uses realPieceID from the manifest — synthetic ids ("ab12") now correctly throw.
        let p1 = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)","content":"%v1","filename":"tribute.tex"}"#
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(p1.utf8), registry: registry)

        let p2 = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)","content":"%v2","filename":"tribute.tex"}"#
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(p2.utf8), registry: registry)

        let fileURL = publishRoot.appendingPathComponent("pieces/tribute.tex")
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(onDisk, "%v2", "current file should hold the new content")

        // Prior version must be recoverable from the project trash.
        let trashRoot = projectURL.appendingPathComponent(".trash")
        let trashed = recursiveContents(of: trashRoot)
        XCTAssertTrue(trashed.contains("%v1"),
                      "prior version (%v1) should be in trash, got: \(trashed)")
    }

    func test_setPieceStyle_defaultFilenameIsDeterministicSlug() async throws {
        // Uses realPieceID (e.g. "doc-XXXXXXXX") + realPieceTitle ("Chapter 1") from manifest.
        // The slug is derived from the manifest item's title, so "Chapter 1" -> "chapter-1.tex".
        // Synthetic ids ("ab12") now correctly throw; titleOverride is no longer consulted for slug.
        let expectedSlug = PieceStyleSlug.slug(realPieceTitle) + ".tex"

        let params = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)","content":"% gen"}"#
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(params.utf8), registry: registry)
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(params.utf8), registry: registry)

        let piecesDir = publishRoot.appendingPathComponent("pieces")
        let names = (try FileManager.default.contentsOfDirectory(
            atPath: piecesDir.path))
            .filter { $0.hasSuffix(".tex") }
        XCTAssertEqual(names.count, 1,
                       "same title -> same file, no duplicate; got \(names)")
        XCTAssertEqual(names.first, expectedSlug,
                       "deterministic slug from piece title expected; got \(names)")

        let cfgAfter = try await PublishConfigStore(projectURL: projectURL).load()
        XCTAssertEqual(cfgAfter?.sections[realPieceID]?.styleFile, expectedSlug)
    }

    // MARK: - clear_piece_style

    func test_clearPieceStyle_unwiresAndTrashesOrphanFile() async throws {
        // Uses realPieceID from the manifest — synthetic ids ("ab12") now correctly throw.
        let setP = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)","content":"%x","filename":"t.tex"}"#
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(setP.utf8), registry: registry)

        let clearP = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)"}"#
        let data = try await ClearPieceStyleTool.handle(paramsJSON: Data(clearP.utf8), registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "cleared")
        XCTAssertEqual(resp?["deleted_file"] as? Bool, true)

        let cfg = try await PublishConfigStore(projectURL: projectURL).load()
        XCTAssertNil(cfg?.sections[realPieceID]?.styleFile,
                     "style_file should be unwired")

        let fileURL = publishRoot.appendingPathComponent("pieces/t.tex")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "orphaned pieces/t.tex should be deleted (moved to trash)")

        let trashRoot = projectURL.appendingPathComponent(".trash")
        let trashed = recursiveContents(of: trashRoot)
        XCTAssertTrue(trashed.contains("%x"),
                      "deleted file content (%x) should be in trash, got: \(trashed)")
    }

    func test_clearPieceStyle_keepsFileWhenSharedByAnotherPiece() async throws {
        // Uses realPieceID from the manifest for piece 1; adds a real second document for piece 2.
        // Synthetic ids ("ab12", "cd34") now correctly throw; both pieces must exist in the manifest.
        let entry = registry.lookup(id: pid)!
        let piece2 = try await entry.store.addStructureItem(
            parentId: nil, title: "Chapter 2", kind: .document(extension: "md"))

        let s1 = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)","content":"%shared","filename":"shared.tex"}"#
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(s1.utf8), registry: registry)
        let s2 = #"{"project_id":"\#(pid!)","piece_id":"\#(piece2.id)","content":"%shared","filename":"shared.tex"}"#
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(s2.utf8), registry: registry)

        let clearP = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)"}"#
        let data = try await ClearPieceStyleTool.handle(paramsJSON: Data(clearP.utf8), registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "cleared")
        XCTAssertEqual(resp?["deleted_file"] as? Bool, false)

        let fileURL = publishRoot.appendingPathComponent("pieces/shared.tex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "shared.tex must survive because piece2 still references it")

        let cfg = try await PublishConfigStore(projectURL: projectURL).load()
        XCTAssertNil(cfg?.sections[realPieceID]?.styleFile, "realPieceID should be unwired")
        XCTAssertEqual(cfg?.sections[piece2.id]?.styleFile, "shared.tex",
                       "piece2 should still reference shared.tex")
    }

    func test_clearPieceStyle_noStyleFile_isNoop() async throws {
        // Uses realPieceID from the manifest — consistent with the rest of the suite.
        let clearP = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)"}"#
        let data = try await ClearPieceStyleTool.handle(paramsJSON: Data(clearP.utf8), registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "noop")
    }

    // MARK: - New: unknown piece_id validation + default filename from title

    // MARK: - LaTeX injection validation (finding 1.4)

    func test_setPieceStyle_rejectsTeXSpecialInFilename_closeBrace() async throws {
        // `}` in a filename closes the \input{} argument — injection vector.
        let params = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)","content":"% x","filename":"bad}inject.tex"}"#
        do {
            _ = try await SetPieceStyleTool.handle(paramsJSON: Data(params.utf8), registry: registry)
            XCTFail("Expected rejection of filename with '}'")
        } catch MCPError.invalidArgument {
            // Expected
        }
        // No file should exist
        let fileURL = publishRoot.appendingPathComponent("pieces/bad}inject.tex")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_setPieceStyle_rejectsPathTraversalInFilename() async throws {
        // `../` traversal bypasses the pieces/ directory.
        let params = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)","content":"% x","filename":"../escape.tex"}"#
        do {
            _ = try await SetPieceStyleTool.handle(paramsJSON: Data(params.utf8), registry: registry)
            XCTFail("Expected rejection of filename with '../'")
        } catch MCPError.invalidArgument {
            // Expected
        }
    }

    func test_setPieceStyle_rejectsSlashInFilename() async throws {
        // A `/` in the filename would create a nested path.
        let params = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)","content":"% x","filename":"sub/dir.tex"}"#
        do {
            _ = try await SetPieceStyleTool.handle(paramsJSON: Data(params.utf8), registry: registry)
            XCTFail("Expected rejection of filename with '/'")
        } catch MCPError.invalidArgument {
            // Expected
        }
    }

    func test_setPieceStyle_rejectsTeXPercent() async throws {
        // `%` starts a TeX comment — could hide injected content after it.
        let params = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)","content":"% x","filename":"comment%inject.tex"}"#
        do {
            _ = try await SetPieceStyleTool.handle(paramsJSON: Data(params.utf8), registry: registry)
            XCTFail("Expected rejection of filename with '%'")
        } catch MCPError.invalidArgument {
            // Expected
        }
    }

    func test_setPieceStyle_acceptsSafeFilename() async throws {
        // A purely safe filename should be accepted.
        let params = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)","content":"% safe","filename":"my-style_v2.tex"}"#
        let data = try await SetPieceStyleTool.handle(paramsJSON: Data(params.utf8), registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "set")
        XCTAssertEqual(resp?["style_file"] as? String, "my-style_v2.tex")
    }

    // MARK: - New: unknown piece_id validation + default filename from title

    func test_setPieceStyle_unknownPieceID_throws() async throws {
        // "doc-deadbeef" is not a real piece in this project; the tool must reject it loudly.
        let params = #"{"project_id":"\#(pid!)","piece_id":"doc-deadbeef","content":"% bad","filename":"bad.tex"}"#
        do {
            _ = try await SetPieceStyleTool.handle(paramsJSON: Data(params.utf8), registry: registry)
            XCTFail("Expected MCPError.invalidArgument for unknown piece_id, but handle returned normally")
        } catch MCPError.invalidArgument {
            // Expected — correct behaviour.
        } catch {
            XCTFail("Expected MCPError.invalidArgument, got \(error)")
        }

        // No file should have been written.
        let piecesDir = publishRoot.appendingPathComponent("pieces")
        let badFile = piecesDir.appendingPathComponent("bad.tex")
        XCTAssertFalse(FileManager.default.fileExists(atPath: badFile.path),
                       "No file should be written for an unknown piece_id")

        // Config should not have been modified for the bogus key.
        let cfg = try await PublishConfigStore(projectURL: projectURL).load()
        XCTAssertNil(cfg?.sections["doc-deadbeef"],
                     "Config must not be modified for an unknown piece_id")
    }

    func test_setPieceStyle_defaultFilename_usesPieceTitle() async throws {
        // Without an explicit filename, the slug comes from the manifest item's title, not the raw id.
        // Novel project: title is "Chapter 1" -> slug "chapter-1" -> "chapter-1.tex".
        let expectedSlug = PieceStyleSlug.slug(realPieceTitle) + ".tex"

        let params = #"{"project_id":"\#(pid!)","piece_id":"\#(realPieceID!)","content":"% auto"}"#
        let data = try await SetPieceStyleTool.handle(paramsJSON: Data(params.utf8), registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "set")
        XCTAssertEqual(resp?["style_file"] as? String, expectedSlug,
                       "returned style_file should be the title-derived slug, not the raw piece id")

        // File must exist at the title-derived name.
        let fileURL = publishRoot.appendingPathComponent("pieces/\(expectedSlug)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "pieces/\(expectedSlug) should exist")

        // Raw id-named file must NOT exist.
        let idFile = publishRoot.appendingPathComponent("pieces/\(realPieceID!).tex")
        XCTAssertFalse(FileManager.default.fileExists(atPath: idFile.path),
                       "No file should be named after the raw piece id")

        // Config must wire the real piece id to the title-slug file name.
        let cfg = try await PublishConfigStore(projectURL: projectURL).load()
        XCTAssertEqual(cfg?.sections[realPieceID]?.styleFile, expectedSlug)
    }
}

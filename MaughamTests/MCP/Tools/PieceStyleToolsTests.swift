import XCTest
@testable import Maugham

@MainActor
final class PieceStyleToolsTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var pid: String!
    var projectURL: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PieceStyleToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "T", in: tmp)
        let store = try await ProjectStore.load(from: projectURL)
        registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        pid = ProjectIdentifier.id(for: projectURL)
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
        let params = #"{"project_id":"\#(pid!)","piece_id":"ab12","content":"% piece style","filename":"tribute.tex"}"#
        let data = try await SetPieceStyleTool.handle(
            paramsJSON: Data(params.utf8), registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "set")

        let fileURL = publishRoot.appendingPathComponent("pieces/tribute.tex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "pieces/tribute.tex should exist")

        let cfg = try await PublishConfigStore(projectURL: projectURL).load()
        XCTAssertEqual(cfg?.sections["ab12"]?.styleFile, "tribute.tex")
    }

    func test_setPieceStyle_overwriteSendsPriorToTrash() async throws {
        let p1 = #"{"project_id":"\#(pid!)","piece_id":"ab12","content":"%v1","filename":"tribute.tex"}"#
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(p1.utf8), registry: registry)

        let p2 = #"{"project_id":"\#(pid!)","piece_id":"ab12","content":"%v2","filename":"tribute.tex"}"#
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
        // Give the piece a title override so the slug is deterministic.
        let store = PublishConfigStore(projectURL: projectURL)
        var cfg = PublishConfig()
        var sec = PublishConfig.Section()
        sec.titleOverride = "A Tribute!"
        cfg.sections["ab12"] = sec
        try await store.save(cfg)

        let params = #"{"project_id":"\#(pid!)","piece_id":"ab12","content":"% gen"}"#
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(params.utf8), registry: registry)
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(params.utf8), registry: registry)

        let piecesDir = publishRoot.appendingPathComponent("pieces")
        let names = (try FileManager.default.contentsOfDirectory(
            atPath: piecesDir.path))
            .filter { $0.hasSuffix(".tex") }
        XCTAssertEqual(names.count, 1,
                       "same title -> same file, no duplicate; got \(names)")
        XCTAssertEqual(names.first, "a-tribute.tex",
                       "deterministic slug expected; got \(names)")

        let cfgAfter = try await store.load()
        XCTAssertEqual(cfgAfter?.sections["ab12"]?.styleFile, "a-tribute.tex")
    }

    // MARK: - clear_piece_style

    func test_clearPieceStyle_unwiresAndTrashesOrphanFile() async throws {
        let setP = #"{"project_id":"\#(pid!)","piece_id":"ab12","content":"%x","filename":"t.tex"}"#
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(setP.utf8), registry: registry)

        let clearP = #"{"project_id":"\#(pid!)","piece_id":"ab12"}"#
        let data = try await ClearPieceStyleTool.handle(paramsJSON: Data(clearP.utf8), registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "cleared")
        XCTAssertEqual(resp?["deleted_file"] as? Bool, true)

        let cfg = try await PublishConfigStore(projectURL: projectURL).load()
        XCTAssertNil(cfg?.sections["ab12"]?.styleFile,
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
        let s1 = #"{"project_id":"\#(pid!)","piece_id":"ab12","content":"%shared","filename":"shared.tex"}"#
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(s1.utf8), registry: registry)
        let s2 = #"{"project_id":"\#(pid!)","piece_id":"cd34","content":"%shared","filename":"shared.tex"}"#
        _ = try await SetPieceStyleTool.handle(paramsJSON: Data(s2.utf8), registry: registry)

        let clearP = #"{"project_id":"\#(pid!)","piece_id":"ab12"}"#
        let data = try await ClearPieceStyleTool.handle(paramsJSON: Data(clearP.utf8), registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "cleared")
        XCTAssertEqual(resp?["deleted_file"] as? Bool, false)

        let fileURL = publishRoot.appendingPathComponent("pieces/shared.tex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "shared.tex must survive because cd34 still references it")

        let cfg = try await PublishConfigStore(projectURL: projectURL).load()
        XCTAssertNil(cfg?.sections["ab12"]?.styleFile, "ab12 should be unwired")
        XCTAssertEqual(cfg?.sections["cd34"]?.styleFile, "shared.tex",
                       "cd34 should still reference shared.tex")
    }

    func test_clearPieceStyle_noStyleFile_isNoop() async throws {
        let clearP = #"{"project_id":"\#(pid!)","piece_id":"ab12"}"#
        let data = try await ClearPieceStyleTool.handle(paramsJSON: Data(clearP.utf8), registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "noop")
    }
}

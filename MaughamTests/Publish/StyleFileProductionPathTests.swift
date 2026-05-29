import XCTest
import MaughamCore
@testable import Maugham

/// Production-path reproduction for the `style_file` / section-override id seam.
///
/// The existing `StyleFileCompileEndToEndTests` uses a synthetic `TwoPieceSource`
/// with hand-matched ids ("two"), so it can never catch an id MISMATCH between
/// the id a client passes to `set_piece_style` and the `pieceID` that
/// `ProjectStoreASTSource` emits into the AST. This test exercises the REAL
/// path: a real on-disk project, the real `GetOutlineTool` (the id a client
/// would obtain), the real `set_piece_style` tool, the real
/// `ProjectStoreASTSource`, and the real `LaTeXBodyEmitter`.
@MainActor
final class StyleFileProductionPathTests: XCTestCase {

    var tmp: URL!
    var projectURL: URL!
    var store: ProjectStore!
    var registry: ProjectRegistry!
    var pid: String!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("StyleFileProdPath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "Prod", in: tmp)
        store = try await ProjectStore.load(from: projectURL)
        registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        pid = ProjectIdentifier.id(for: projectURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_productionPath_styleFile_wrapperEmitted() async throws {
        // Seed the chapter with some prose so the piece is non-empty.
        let chapterPath = store.manifest.structure.first?.path ?? ""
        XCTAssertFalse(chapterPath.isEmpty, "novel should have a chapter path")
        try "Opening line of the chapter.".write(
            to: projectURL.appendingPathComponent(chapterPath),
            atomically: true, encoding: .utf8)

        // 1. The id a client would discover via get_outline.
        let outlineData = try await GetOutlineTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8),
            registry: registry)
        // Decode loosely: GetOutlineTool encodes `modified` as an ISO8601 string,
        // so a plain Decodable round-trip throws. We only need the document id.
        let outlineObj = try JSONSerialization.jsonObject(with: outlineData) as? [String: Any]
        let nodes = outlineObj?["nodes"] as? [[String: Any]] ?? []
        let clientID = nodes.first { ($0["type"] as? String) == "document" }?["id"] as? String ?? "<none>"

        // 2. The id ProjectStoreASTSource produces.
        let astSource = ProjectStoreASTSource(projectStore: store)
        let pieces = astSource.orderedPieces()
        let astID = pieces.first?.pieceID ?? "<none>"

        // 3. Surface the comparison.
        XCTContext.runActivity(named: "id comparison") { _ in
            print("DIAGNOSTIC clientID=\(clientID) astID=\(astID) match=\(clientID == astID)")
        }

        // 4. Set the style via the real tool, keyed by the CLIENT id.
        let setParams = #"{"project_id":"\#(pid!)","piece_id":"\#(clientID)","content":"% salute style","filename":"salute.tex"}"#
        _ = try await SetPieceStyleTool.handle(
            paramsJSON: Data(setParams.utf8), registry: registry)

        // 5. Load config and emit body from the real AST.
        let cfg = (try await PublishConfigStore(projectURL: projectURL).load()) ?? PublishConfig()
        let ast = ProjectASTBuilder.build(from: ProjectStoreASTSource(projectStore: store))
        let body = LaTeXBodyEmitter.emit(ast, config: cfg)

        // 6. The wrapper must appear.
        let diag = """
            clientID=\(clientID)
            astID=\(astID)
            match=\(clientID == astID)
            config.sections.keys=\(Array(cfg.sections.keys))
            body.tex:
            \(body)
            """
        XCTAssertTrue(body.contains("\\input{pieces/salute.tex}"),
                      "body.tex missing \\input{pieces/salute.tex}.\n\(diag)")
        XCTAssertTrue(body.contains("\\begingroup"),
                      "body.tex missing \\begingroup.\n\(diag)")
    }

    /// Same production path, but for a COLLECTION loose piece — the namespace
    /// the real reported usage most likely came from. Collection pieces get
    /// their `StructureItem.id` from `addLoosePiece` (`Self.newId(prefix:"doc")`),
    /// the same minting the outline/AST both read, so this probes whether the
    /// divergence lives in the collection path specifically.
    func test_productionPath_collectionLoosePiece_wrapperEmitted() async throws {
        let colURL = try await ProjectFactory.createCollectionProject(named: "Col", in: tmp)
        let colStore = try await ProjectStore.load(from: colURL)
        let colRegistry = ProjectRegistry()
        colRegistry.register(url: colURL, store: colStore)
        let colPid = ProjectIdentifier.id(for: colURL)

        let piece = try await colStore.addLoosePiece(title: "Salute", mode: .prose)
        try "Loose piece body.".write(
            to: colURL.appendingPathComponent(piece.path!),
            atomically: true, encoding: .utf8)

        let outlineData = try await GetOutlineTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(colPid)"}"#.utf8),
            registry: colRegistry)
        let outlineObj = try JSONSerialization.jsonObject(with: outlineData) as? [String: Any]
        let nodes = outlineObj?["nodes"] as? [[String: Any]] ?? []
        let clientID = nodes.first { ($0["type"] as? String) == "document" }?["id"] as? String ?? "<none>"

        let astSource = ProjectStoreASTSource(projectStore: colStore)
        let astID = astSource.orderedPieces().first?.pieceID ?? "<none>"

        print("DIAGNOSTIC[collection] clientID=\(clientID) astID=\(astID) manifestID=\(piece.id) match=\(clientID == astID)")

        let setParams = #"{"project_id":"\#(colPid)","piece_id":"\#(clientID)","content":"% salute","filename":"salute.tex"}"#
        _ = try await SetPieceStyleTool.handle(
            paramsJSON: Data(setParams.utf8), registry: colRegistry)

        let cfg = (try await PublishConfigStore(projectURL: colURL).load()) ?? PublishConfig()
        let ast = ProjectASTBuilder.build(from: ProjectStoreASTSource(projectStore: colStore))
        let body = LaTeXBodyEmitter.emit(ast, config: cfg)

        let diag = """
            clientID=\(clientID) astID=\(astID) manifestID=\(piece.id) match=\(clientID == astID)
            config.sections.keys=\(Array(cfg.sections.keys))
            ast pieceIDs=\(ast.sections.map(\.pieceID))
            body.tex:
            \(body)
            """
        XCTAssertTrue(body.contains("\\input{pieces/salute.tex}"),
                      "body.tex missing \\input{pieces/salute.tex}.\n\(diag)")
        XCTAssertTrue(body.contains("\\begingroup"),
                      "body.tex missing \\begingroup.\n\(diag)")
    }
}

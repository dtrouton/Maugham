import XCTest
@testable import Maugham
import MaughamCore

/// `read_craft_intent` after M1A: it answers off a `Statement`, for **any**
/// manuscript document rather than a Collection loose piece alone, and it
/// derives from the op log rather than reading the `.md` (tripwire 20).
@MainActor
final class CraftIntentToolTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeRegisteredNovel() async throws -> (URL, ProjectStore, DocumentStore, ProjectRegistry) {
        let url = try await ProjectFactory.createNovelProject(named: "IntentMCP", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg)
    }

    private func read(
        _ reg: ProjectRegistry, projectURL: URL, itemId: String? = nil
    ) async throws -> ReadCraftIntentTool.Result {
        let id = ProjectIdentifier.id(for: projectURL)
        var params = "{\"project_id\":\"\(id)\""
        if let itemId { params += ",\"item_id\":\"\(itemId)\"" }
        params += "}"
        let json = try await ReadCraftIntentTool.handle(
            paramsJSON: Data(params.utf8), registry: reg)
        return try JSONDecoder().decode(ReadCraftIntentTool.Result.self, from: json)
    }

    /// Put `text` into a statement the way the writer does — through its op log —
    /// and leave the derived `.md` on disk as `Document.close()` renders it.
    private func write(_ text: String, into statement: Statement, at projectURL: URL) async throws {
        let document = try await Document.load(
            url: projectURL.appendingPathComponent(statement.path),
            device: "intent-mcp-test", session: "s", presenter: nil)
        document.setFullText(text)
        try await document.flushBurstNow()
        await document.close()
    }

    // MARK: - Absence stays valid, and stays free of side effects

    func test_absentIntent_returnsExistsFalse_notError() async throws {
        let (url, _, ds, reg) = try await makeRegisteredNovel()
        let result = try await read(reg, projectURL: url)
        XCTAssertFalse(result.exists)
        XCTAssertNil(result.markdown)
        await ds.close()
    }

    /// An undeclared scope answers `exists: false` and **changes nothing**: no
    /// statement is registered and no file appears. The tool's own shipped
    /// sentence promises Claude that absence is "a valid, deliberate state", and
    /// a read that mints on the way would contradict it.
    func test_readCraftIntentStillSaysExistsFalseForAnUndeclaredScope() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let chapter = try XCTUnwrap(
            store.manifest.structure.first(where: { $0.type == .document }))
        let before = try tree(of: url)

        let result = try await read(reg, projectURL: url, itemId: chapter.id)

        XCTAssertFalse(result.exists)
        XCTAssertNil(result.markdown)
        XCTAssertNil(result.path)
        XCTAssertTrue(store.manifest.statements.isEmpty,
                      "the read registered a statement")
        XCTAssertEqual(try tree(of: url), before,
                       "the read changed the project directory")
        await ds.close()
    }

    /// An `item_id` naming nothing in this project is the same undeclared scope,
    /// not an error — the pre-M1A behaviour, kept.
    func test_readCraftIntentSaysExistsFalseForAnUnknownItemId() async throws {
        let (url, _, ds, reg) = try await makeRegisteredNovel()
        let result = try await read(reg, projectURL: url, itemId: "doc-nope")
        XCTAssertFalse(result.exists)
        await ds.close()
    }

    // MARK: - The widening (contract 4)

    /// **A novel chapter's intent is readable.** Before M1A the `item_id`
    /// argument went to `craftIntentItem(forPieceId:)`, whose lookup ran through
    /// `ResearchScope.pieceResearchPrefix` — nil for anything that is not a
    /// Collection loose piece — so this returned `exists: false` for every
    /// chapter of every novel. Falsified by restoring that behaviour.
    func test_readCraftIntentAnswersForANovelChapter() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let chapter = try XCTUnwrap(
            store.manifest.structure.first(where: { $0.type == .document }))
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await write("This chapter should smell of the harbour.",
                        into: statement, at: url)

        let result = try await read(reg, projectURL: url, itemId: chapter.id)

        XCTAssertTrue(result.exists,
                      "a novel chapter's intent reads as absent — the tool is "
                      + "still treating item_id as a Collection loose piece")
        XCTAssertEqual(result.markdown, "This chapter should smell of the harbour.")
        XCTAssertEqual(result.path, statement.path)
        XCTAssertTrue(statement.path.hasPrefix("intent/"),
                      "precondition: a document-scoped statement lives under "
                      + "intent/, got \(statement.path)")
        await ds.close()
    }

    func test_readCraftIntentAnswersForTheProject() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .intent, scope: .project)
        try await write("This story lives in the body.", into: statement, at: url)

        let result = try await read(reg, projectURL: url)
        XCTAssertTrue(result.exists)
        XCTAssertEqual(result.markdown, "This story lives in the body.")
        XCTAssertEqual(result.path, "intent.md")
        await ds.close()
    }

    // MARK: - The read derives (contract 5, tripwire 20)

    /// **The `.md` is deliberately staled.** A statement is a `Document` with an
    /// op log, so the file beside it is derived and is allowed to lag — a peer
    /// that synced `.maugham/ops/` before the render leaves exactly these bytes.
    /// Without the staling this test passes under both the file read and the
    /// derived read, which is the falsifiability defect found on Task 2 of this
    /// branch.
    func test_readCraftIntentReadsTheOpLogAndNotTheFile() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .intent, scope: .project)
        try await write("What the op log says.", into: statement, at: url)

        let fileURL = url.appendingPathComponent(statement.path)
        try "What the stale file says.".write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8),
                       "What the stale file says.",
                       "precondition: the file must really be stale, or this test "
                       + "cannot tell the two reads apart")

        let result = try await read(reg, projectURL: url)
        XCTAssertEqual(result.markdown, "What the op log says.",
                       "the tool read the derived `.md` instead of the op log")
        await ds.close()
    }

    /// **The open pane's `Document` wins, which is ADR 0018's open-doc rule.**
    /// A statement is in no `DocumentStore` registry by design, so the branch
    /// every other reader takes (`documentStore.document(forDocId:)`) answers nil
    /// for one; `ProjectStore.openStatementDocument(id:)` — built by Task 7 for
    /// promotion's own collision — is the seam that finds it.
    func test_readCraftIntentAnswersFromTheOpenPanesDocument() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .intent, scope: .project)
        try await write("Flushed to the op log.", into: statement, at: url)

        // Stand in for the Intent pane: one live Document, registered exactly as
        // `StatementEditorHost` registers its own, holding an unflushed burst.
        let live = try await Document.load(
            url: url.appendingPathComponent(statement.path),
            device: "pane-test", session: "pane", presenter: nil)
        store.noteStatementDocumentOpened(live, id: statement.id)
        live.setFullText("Flushed to the op log.\n\nStill in the writer's hands.")

        XCTAssertNotEqual(
            try store.derivedCache.displayText(forDocId: statement.id, in: url),
            live.displayText,
            "precondition: the burst has already reached the op log, so this test "
            + "cannot tell the live branch from the derived one")

        let result = try await read(reg, projectURL: url)
        XCTAssertEqual(result.markdown, live.displayText,
                       "the tool answered from the op log while the writer had "
                       + "the pane open — Claude reads their intent one burst old")

        store.forgetStatementDocument(id: statement.id)
        await live.close()
        await ds.close()
    }

    // MARK: - Unchanged

    func test_unknownProject_throwsToolError() async throws {
        let reg = ProjectRegistry()
        do {
            _ = try await ReadCraftIntentTool.handle(
                paramsJSON: Data("{\"project_id\":\"nope\"}".utf8), registry: reg)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }

    // MARK: - Helpers

    /// Every path under `url`, sorted — a whole-directory snapshot, so a read
    /// that writes anywhere at all shows up.
    private func tree(of url: URL) throws -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: url.path)
        var paths: [String] = []
        while let next = enumerator?.nextObject() as? String { paths.append(next) }
        return paths.sorted()
    }
}

import XCTest
@testable import Maugham
import MaughamCore

/// `read_first_reader` — the fifth spine reader, `read_lessons`'s exact
/// shape plus a `name` sourced from the manifest rather than the statement:
/// project scope only, absence of the statement is `exists: false` and
/// never an error, and the read derives through
/// `ProjectStore.statementText(of:)` like every other statement reader.
@MainActor
final class FirstReaderToolsTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeRegisteredNovel() async throws -> (URL, ProjectStore, DocumentStore, ProjectRegistry) {
        let url = try await ProjectFactory.createNovelProject(named: "FirstReaderMCP", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg)
    }

    private func read(_ reg: ProjectRegistry, projectURL: URL) async throws -> ReadFirstReaderTool.Result {
        let id = ProjectIdentifier.id(for: projectURL)
        let json = try await ReadFirstReaderTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        return try JSONDecoder().decode(ReadFirstReaderTool.Result.self, from: json)
    }

    /// Put `text` into a statement the way the writer's own verbs do — through
    /// its op log — and leave the derived `.md` on disk as `Document.close()`
    /// renders it. Mirrors `LessonsToolsTests.write(_:into:at:)`.
    private func write(_ text: String, into statement: Statement, at projectURL: URL) async throws {
        let document = try await Document.load(
            url: projectURL.appendingPathComponent(statement.path),
            device: "first-reader-mcp-test", session: "s", presenter: nil)
        document.setFullText(text)
        try await document.flushBurstNow()
        await document.close()
    }

    // MARK: - No name, no statement

    func test_noName_returnsExistsFalse_nameNil() async throws {
        let (url, _, ds, reg) = try await makeRegisteredNovel()
        let result = try await read(reg, projectURL: url)
        XCTAssertFalse(result.exists)
        XCTAssertNil(result.name)
        XCTAssertNil(result.markdown)
        XCTAssertNil(result.path)
        await ds.close()
    }

    /// The read mints nothing on the way — same contract as `read_lessons`.
    func test_noStatement_registersNoStatementAndWritesNoFile() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let before = try tree(of: url)

        _ = try await read(reg, projectURL: url)

        XCTAssertTrue(store.manifest.statements.isEmpty,
                      "the read registered a statement")
        XCTAssertEqual(try tree(of: url), before,
                       "the read changed the project directory")
        await ds.close()
    }

    // MARK: - Name without a statement

    func test_nameWithoutStatement_returnsExistsFalse_withName() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        try await store.setFirstReaderName("Tabitha")

        let result = try await read(reg, projectURL: url)

        XCTAssertFalse(result.exists)
        XCTAssertEqual(result.name, "Tabitha")
        XCTAssertNil(result.markdown)
        XCTAssertNil(result.path)
        await ds.close()
    }

    // MARK: - Name and statement both present

    func test_nameAndStatement_returnsExistsTrue_markdownAndPath() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        try await store.setFirstReaderName("Tabitha")
        let statement = try await store.createStatement(kind: .firstReader, scope: .project)
        try await write(
            "Reads for pace, not prose. Will not sit through a slow opening.",
            into: statement, at: url)

        let result = try await read(reg, projectURL: url)

        XCTAssertTrue(result.exists)
        XCTAssertEqual(result.name, "Tabitha")
        XCTAssertEqual(result.markdown,
                       "Reads for pace, not prose. Will not sit through a slow opening.")
        XCTAssertEqual(result.path, "first-reader.md")
        await ds.close()
    }

    /// **The `.md` is deliberately staled** — same falsifiability shape as
    /// `LessonsToolsTests.test_readLessonsReadsTheOpLogAndNotTheFile`.
    func test_readFirstReaderReadsTheOpLogAndNotTheFile() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .firstReader, scope: .project)
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

    // MARK: - Unchanged

    func test_unknownProject_throwsToolError() async throws {
        let reg = ProjectRegistry()
        do {
            _ = try await ReadFirstReaderTool.handle(
                paramsJSON: Data("{\"project_id\":\"nope\"}".utf8), registry: reg)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }

    // MARK: - Catalogue

    func test_readFirstReaderIsInTheCatalogExactlyOnce() {
        let matches = MCPToolCatalog.all.filter { $0.method == "read_first_reader" }
        XCTAssertEqual(matches.count, 1)
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

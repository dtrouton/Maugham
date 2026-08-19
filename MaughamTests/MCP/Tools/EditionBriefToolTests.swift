import XCTest
@testable import Maugham
import MaughamCore

/// `read_edition_brief` — the publish department's per-language doctrine,
/// readable from outside so an outside translator does not re-decide
/// register/idiom a prior session already ruled on.
///
/// Mirrors `VisualLanguageToolTests`' shape: the tool answers off a
/// project-scope `Statement` keyed by language, derives its prose from the
/// op log rather than the `.md` (tripwire 20), and treats absence as a
/// valid, non-minting answer.
@MainActor
final class EditionBriefToolTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeRegisteredNovel() async throws -> (URL, ProjectStore, DocumentStore, ProjectRegistry) {
        let url = try await ProjectFactory.createNovelProject(named: "BriefMCP", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg)
    }

    private func read(
        _ reg: ProjectRegistry, projectURL: URL, language: String
    ) async throws -> ReadEditionBriefTool.Result {
        let id = ProjectIdentifier.id(for: projectURL)
        let json = try await ReadEditionBriefTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\",\"language\":\"\(language)\"}".utf8),
            registry: reg)
        return try JSONDecoder().decode(ReadEditionBriefTool.Result.self, from: json)
    }

    /// Put `text` into a statement the way a translation session does —
    /// through its op log — and leave the derived `.md` on disk as
    /// `Document.close()` renders it.
    private func write(_ text: String, into statement: Statement, at projectURL: URL) async throws {
        let document = try await Document.load(
            url: projectURL.appendingPathComponent(statement.path),
            device: "edition-brief-test", session: "s", presenter: nil)
        document.setFullText(text)
        try await document.flushBurstNow()
        await document.close()
    }

    // MARK: - Absence stays valid, and stays free of side effects

    /// **Absence is `exists: false`, never an error**, in `read_craft_intent`'s
    /// shape — and the read mints nothing on the way. A project that has not
    /// declared a brief for a language has not failed to; a tool that created
    /// the file to answer the question would put a statement in the project
    /// nobody opened.
    func test_readEditionBriefSaysExistsFalseWhenNoneIsDeclared() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let before = try tree(of: url)

        let result = try await read(reg, projectURL: url, language: "es")

        XCTAssertFalse(result.exists)
        XCTAssertEqual(result.markdown, "")
        XCTAssertEqual(result.language, "es")
        XCTAssertTrue(store.manifest.statements.isEmpty,
                      "the read registered a statement")
        XCTAssertEqual(try tree(of: url), before,
                       "the read changed the project directory")
        await ds.close()
    }

    // MARK: - The prose (contract)

    func test_readEditionBriefReturnsTheBriefsProse() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        try await write("Register: warm, familiar. Idioms translate for sense, never literally.",
                        into: statement, at: url)

        let result = try await read(reg, projectURL: url, language: "es")

        XCTAssertTrue(result.exists)
        XCTAssertEqual(result.markdown,
                       "Register: warm, familiar. Idioms translate for sense, never literally.")
        XCTAssertEqual(result.language, "es")
        await ds.close()
    }

    /// **Two languages discriminate.** A brief for `es` must not answer a
    /// request for `fr`, and vice versa — this is the reason the kind carries
    /// the language tag rather than the tool taking a bare project id.
    func test_readEditionBriefDiscriminatesByLanguage() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let es = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        try await write("Spanish doctrine.", into: es, at: url)
        let fr = try await store.createStatement(kind: .editionBrief("fr"), scope: .project)
        try await write("French doctrine.", into: fr, at: url)

        let esResult = try await read(reg, projectURL: url, language: "es")
        let frResult = try await read(reg, projectURL: url, language: "fr")
        let deResult = try await read(reg, projectURL: url, language: "de")

        XCTAssertEqual(esResult.markdown, "Spanish doctrine.")
        XCTAssertEqual(frResult.markdown, "French doctrine.")
        XCTAssertFalse(deResult.exists)
        await ds.close()
    }

    // MARK: - The read derives (contract, tripwire 20)

    /// **The `.md` is deliberately staled.** A statement is a `Document` with
    /// an op log, so the file beside it is derived and is allowed to lag — a
    /// peer that synced `.maugham/ops/` before the render leaves exactly
    /// these bytes.
    func test_readEditionBriefDerivesFromTheOpLog() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        try await write("What the op log says.", into: statement, at: url)

        let fileURL = url.appendingPathComponent(statement.path)
        try "What the stale file says."
            .write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8),
                       "What the stale file says.",
                       "precondition: the file must really be stale, or this test "
                       + "cannot tell the two reads apart")

        let result = try await read(reg, projectURL: url, language: "es")

        XCTAssertEqual(result.markdown, "What the op log says.",
                       "the tool read the derived `.md` instead of the op log")
        await ds.close()
    }

    /// **The open pane's `Document` wins**, ADR 0018's open-doc rule.
    func test_readEditionBriefAnswersFromTheOpenPanesDocument() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        try await write("Flushed to the op log.", into: statement, at: url)

        let live = try await Document.load(
            url: url.appendingPathComponent(statement.path),
            device: "pane-test", session: "pane", presenter: nil)
        store.noteStatementDocumentOpened(live, id: statement.id)
        live.setFullText("Flushed to the op log.\n\nAnd a new ruling on top.")

        XCTAssertNotEqual(
            try store.derivedCache.displayText(forDocId: statement.id, in: url),
            live.displayText,
            "precondition: the burst has already reached the op log, so this test "
            + "cannot tell the live branch from the derived one")

        let result = try await read(reg, projectURL: url, language: "es")

        XCTAssertEqual(result.markdown, live.displayText,
                       "the tool answered from the op log while a translation session "
                       + "had the pane open")

        store.forgetStatementDocument(id: statement.id)
        await live.close()
        await ds.close()
    }

    // MARK: - Shape

    /// Project scope by construction: `StatementConvention.newPath` has no
    /// row for `(.editionBrief, .document)`, so the tool takes `project_id`
    /// and `language` and nothing else.
    func test_readEditionBriefTakesProjectIdAndLanguageAndNothingElse() throws {
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(ReadEditionBriefTool.inputSchemaJSON.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["project_id", "language"])
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["project_id", "language"])
    }

    func test_unknownProject_throwsToolError() async throws {
        let reg = ProjectRegistry()
        do {
            _ = try await ReadEditionBriefTool.handle(
                paramsJSON: Data("{\"project_id\":\"nope\",\"language\":\"es\"}".utf8), registry: reg)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }

    func test_catalogIncludesReadEditionBrief() {
        XCTAssertTrue(MCPToolCatalog.all.contains { $0.method == "read_edition_brief" })
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

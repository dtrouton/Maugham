import XCTest
@testable import Maugham
import MaughamCore

/// `read_visual_language` — M1's second named protection (spec §10, M1):
/// visual language gets a consumer in the same milestone that builds it, and
/// the cheap half of that is Claude reading it while authoring a template.
///
/// The tool answers off a project-scope `Statement`, derives its prose from the
/// op log rather than the `.md` (tripwire 20), and reports the images the
/// writer referenced as project-relative paths.
@MainActor
final class VisualLanguageToolTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeRegisteredNovel() async throws -> (URL, ProjectStore, DocumentStore, ProjectRegistry) {
        let url = try await ProjectFactory.createNovelProject(named: "LookMCP", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg)
    }

    private func read(
        _ reg: ProjectRegistry, projectURL: URL
    ) async throws -> ReadVisualLanguageTool.Result {
        let id = ProjectIdentifier.id(for: projectURL)
        let json = try await ReadVisualLanguageTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        return try JSONDecoder().decode(ReadVisualLanguageTool.Result.self, from: json)
    }

    /// Put `text` into a statement the way the writer does — through its op log —
    /// and leave the derived `.md` on disk as `Document.close()` renders it.
    private func write(_ text: String, into statement: Statement, at projectURL: URL) async throws {
        let document = try await Document.load(
            url: projectURL.appendingPathComponent(statement.path),
            device: "visual-language-test", session: "s", presenter: nil)
        document.setFullText(text)
        try await document.flushBurstNow()
        await document.close()
    }

    // MARK: - Absence stays valid, and stays free of side effects

    /// **Absence is `exists: false`, never an error**, in `read_craft_intent`'s
    /// shape — and the read mints nothing on the way. A project that has not
    /// declared a look has not failed to; a tool that created the file to answer
    /// the question would put a statement in the Visual Language pane the writer
    /// never opened.
    func test_readVisualLanguageSaysExistsFalseWhenNoneIsDeclared() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let before = try tree(of: url)

        let result = try await read(reg, projectURL: url)

        XCTAssertFalse(result.exists)
        XCTAssertNil(result.markdown)
        XCTAssertNil(result.path)
        XCTAssertNil(result.image_paths)
        XCTAssertTrue(store.manifest.statements.isEmpty,
                      "the read registered a statement")
        XCTAssertEqual(try tree(of: url), before,
                       "the read changed the project directory")
        await ds.close()
    }

    // MARK: - The prose and its images (contract 3)

    /// Visual language is "images, references, and prose" (spec §3.2), so the
    /// answer is the prose **plus** the images it points at, resolved to
    /// project-relative paths through `ProjectStore.resolveImageRef` — the one
    /// spelling of ref→path this repo keeps.
    func test_readVisualLanguageReturnsTheProseAndItsImages() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .visualLanguage, scope: .project)
        try await write("""
            Cheap, loud, affectionate; the type should feel photocopied.

            ![the zine that started it](./covers/zine.jpg)

            ![a rule weight to steal](research/images/rules.png)
            """, into: statement, at: url)

        let result = try await read(reg, projectURL: url)

        XCTAssertTrue(result.exists)
        XCTAssertEqual(result.path, "visual-language.md")
        XCTAssertEqual(result.markdown?.contains("photocopied"), true)
        XCTAssertEqual(result.image_paths,
                       ["covers/zine.jpg", "research/images/rules.png"],
                       "the images the writer referenced, in document order, with "
                       + "the `./` resolved away")
        await ds.close()
    }

    /// **An image referenced mid-paragraph counts.** Visual language is prose
    /// with pictures in it, not a gallery: the writer writes "the cover
    /// ![like this](./x.jpg) is the whole idea" and means it. Falsified by
    /// scanning with `MarkdownBlockParser.matchSoloImage`, which matches only a
    /// line that is *entirely* an image reference and drops both of these.
    func test_readVisualLanguageReportsAnImageReferencedMidParagraph() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .visualLanguage, scope: .project)
        try await write(
            "The cover ![like this](./covers/zine.jpg) is the whole idea, and the "
            + "spine ![this](./covers/spine.png) follows it.",
            into: statement, at: url)

        let result = try await read(reg, projectURL: url)

        XCTAssertEqual(result.image_paths, ["covers/zine.jpg", "covers/spine.png"],
                       "an image inside a paragraph went unreported — the scanner "
                       + "is whole-line-anchored")
        await ds.close()
    }

    /// The field answers "which images", not "how many references" — a picture
    /// the writer cites twice is one picture.
    func test_readVisualLanguageReportsARepeatedImageOnce() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .visualLanguage, scope: .project)
        try await write("""
            ![the cover](./covers/zine.jpg)

            The same cover again ![here](covers/zine.jpg), because it matters twice.
            """, into: statement, at: url)

        let result = try await read(reg, projectURL: url)

        XCTAssertEqual(result.image_paths, ["covers/zine.jpg"])
        await ds.close()
    }

    /// A remote URL is not a project-relative path, and this field is documented
    /// as project-relative paths that `read_publish_image` opens — so one
    /// sitting in it makes the tool's own description false. `PaletteCard`
    /// already applies exactly this filter; this is the same rule, one surface
    /// over. (Whole-branch review.)
    func test_readVisualLanguageDoesNotReportARemoteUrlAsAProjectPath() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .visualLanguage, scope: .project)
        try await write("""
            The palette comes from ![this](https://example.com/cover.jpg).

            The spine is ours: ![spine](./covers/spine.png)
            """, into: statement, at: url)

        let result = try await read(reg, projectURL: url)

        XCTAssertEqual(result.image_paths, ["covers/spine.png"],
                       "a remote URL was reported in a field of project-relative "
                       + "paths, so a reader would hand it to a tool that reads "
                       + "files by project-relative path")
        await ds.close()
    }

    // MARK: - The read derives (contract 3, tripwire 20)

    /// **The `.md` is deliberately staled.** A statement is a `Document` with an
    /// op log, so the file beside it is derived and is allowed to lag — a peer
    /// that synced `.maugham/ops/` before the render leaves exactly these bytes.
    /// Without the staling this test passes under both the file read and the
    /// derived read, which is the falsifiability defect found on Task 2 of this
    /// branch.
    func test_readVisualLanguageDerivesFromTheOpLog() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .visualLanguage, scope: .project)
        try await write("What the op log says. ![real](./covers/real.jpg)",
                        into: statement, at: url)

        let fileURL = url.appendingPathComponent(statement.path)
        try "What the stale file says. ![stale](./covers/stale.jpg)"
            .write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8),
                       "What the stale file says. ![stale](./covers/stale.jpg)",
                       "precondition: the file must really be stale, or this test "
                       + "cannot tell the two reads apart")

        let result = try await read(reg, projectURL: url)

        XCTAssertEqual(result.markdown, "What the op log says. ![real](./covers/real.jpg)",
                       "the tool read the derived `.md` instead of the op log")
        XCTAssertEqual(result.image_paths, ["covers/real.jpg"],
                       "the images were scanned out of the stale file")
        await ds.close()
    }

    /// **The open pane's `Document` wins**, which is ADR 0018's open-doc rule.
    /// The Visual Language pane (⌘⌥V) is a real surface, so this branch is
    /// reachable in the shipping app: a writer describing the look while Claude
    /// authors the template is the whole point of the tool.
    func test_readVisualLanguageAnswersFromTheOpenPanesDocument() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        let statement = try await store.createStatement(kind: .visualLanguage, scope: .project)
        try await write("Flushed to the op log.", into: statement, at: url)

        // Stand in for the Visual Language pane: one live Document, registered
        // exactly as `StatementEditorHost` registers its own.
        let live = try await Document.load(
            url: url.appendingPathComponent(statement.path),
            device: "pane-test", session: "pane", presenter: nil)
        store.noteStatementDocumentOpened(live, id: statement.id)
        live.setFullText("Flushed to the op log.\n\nAnd photocopied ![now](./covers/now.jpg)")

        XCTAssertNotEqual(
            try store.derivedCache.displayText(forDocId: statement.id, in: url),
            live.displayText,
            "precondition: the burst has already reached the op log, so this test "
            + "cannot tell the live branch from the derived one")

        let result = try await read(reg, projectURL: url)

        XCTAssertEqual(result.markdown, live.displayText,
                       "the tool answered from the op log while the writer had the "
                       + "pane open — Claude reads their look one burst old")
        XCTAssertEqual(result.image_paths, ["covers/now.jpg"],
                       "the images came from the stale branch too")

        store.forgetStatementDocument(id: statement.id)
        await live.close()
        await ds.close()
    }

    // MARK: - Shape

    /// Project scope by construction (contract 1): `StatementConvention.newPath`
    /// has no row for `(.visualLanguage, .document)`, so the tool takes
    /// `project_id` and nothing else. A schema that offered `item_id` would
    /// promise a scope the store refuses to create.
    func test_readVisualLanguageTakesProjectIdAndNothingElse() throws {
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(ReadVisualLanguageTool.inputSchemaJSON.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["project_id"])
        XCTAssertEqual(schema["required"] as? [String], ["project_id"])
    }

    func test_unknownProject_throwsToolError() async throws {
        let reg = ProjectRegistry()
        do {
            _ = try await ReadVisualLanguageTool.handle(
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

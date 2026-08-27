import XCTest
import MaughamCore
@testable import Maugham

/// Task 8: translated-text substitution in `ProjectStoreASTSource`.
///
/// The load-bearing pin is *identity-translation equivalence*: for a doc whose
/// every paragraph carries a verbatim (identity) translation record, the AST
/// built through the `language:` substitution path must EQUAL the AST built
/// through the `language: nil` materialize path. That proves the `"\n\n"` block
/// join reproduces `stripAnchors(materialize())` byte-for-byte — if it diverges
/// (e.g. on a multi-line Fountain dialogue block) these tests fail and the JOIN
/// must be fixed, never the test loosened. One prose fixture (closed doc →
/// `derivedCache.state`) and one Fountain fixture (open doc → live `Document`)
/// cover both source-of-truth branches. A final real-substitution test proves
/// translated text actually lands in the AST nodes.
@MainActor
final class ASTTranslationSubstitutionTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASTTrans-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture builder

    private struct Fixture {
        let store: ProjectStore
        let docId: String
        let path: String
        let docURL: URL
        let doc: Document
    }

    /// Build a one-doc project on disk, bootstrap its op log via `Document.load`
    /// (so both the live `Document` and `derivedCache` see the same paragraphs),
    /// and return the loaded (but unregistered) doc.
    private func makeFixture(fileName: String, body: String) async throws -> Fixture {
        let projectDir = tmp.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let path = "manuscript/\(fileName)"
        let docId = "doc-\(fileName.replacingOccurrences(of: ".", with: "-"))"
        let docURL = projectDir.appendingPathComponent(path)
        try body.write(to: docURL, atomically: true, encoding: .utf8)

        let item = StructureItem(id: docId, title: "Ch", type: .document, path: path)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: projectDir.appendingPathComponent(ProjectManifest.fileName))

        let store = try await ProjectStore.load(from: projectDir)
        // Bootstraps `.maugham/ops/<docId>.<slug>.jsonl` and mints the ¶ anchors
        // the closed-doc derive reads back; resolveDocId matches our manifest id.
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        return Fixture(store: store, docId: docId, path: path, docURL: docURL, doc: doc)
    }

    /// Write a verbatim (identity) translation record for every paragraph:
    /// `translatedText == sourceText`, so the substituted display text must
    /// match the source-language materialize path exactly.
    private func writeIdentityTranslation(
        _ fx: Fixture, language: String
    ) async throws {
        let slug = DeviceSlug.make(from: "test-mac")
        for id in fx.doc.sequence {
            let source = fx.doc.paragraphs[id] ?? ""
            let rec = TranslationRecord(
                paragraphId: id, language: language, text: source,
                sourceHash: TranslationHash.hash(source), verbatim: true)
            try await TranslationStore.append(
                rec, forDocId: fx.docId, deviceSlug: slug, in: fx.store.url)
        }
    }

    // MARK: - identity equivalence: prose (closed doc → derivedCache.state)

    func test_identityTranslation_proseClosedDoc_equalsSourceAST() async throws {
        let body = """
        First paragraph with *emphasis*.

        Second paragraph, plain.
        """
        let fx = try await makeFixture(fileName: "story.md", body: body)
        try await writeIdentityTranslation(fx, language: "es")
        // Doc is NOT registered → both sources take the closed-doc branch.

        let sourceAST = try ProjectASTBuilder.build(
            from: ProjectStoreASTSource(projectStore: fx.store))
        let translatedAST = try ProjectASTBuilder.build(
            from: ProjectStoreASTSource(projectStore: fx.store, language: "es"))

        XCTAssertFalse(sourceAST.sections.isEmpty, "fixture produced no sections")
        XCTAssertEqual(
            translatedAST, sourceAST,
            "identity translation must reproduce the source AST via the closed-doc "
            + "derivedCache path; a divergence means the \"\\n\\n\" join no longer "
            + "matches stripAnchors(materialize()) — fix the join, not the test")
    }

    // MARK: - identity equivalence: fountain (open doc → live Document)

    func test_identityTranslation_fountainOpenDoc_equalsSourceAST() async throws {
        // Scene heading in one paragraph; a character + dialogue block in another
        // (no blank line between the cue and the speech, so it's ONE paragraph —
        // the multi-line block whose "\n\n" join is easy to get wrong).
        let body = """
        INT. KITCHEN - DAY

        AARON
        Morning, everyone.
        """
        let fx = try await makeFixture(fileName: "scene.fountain", body: body)

        // Register the doc so BOTH sources take the open-doc (live Document) branch.
        let ds = try await DocumentStore.open(url: fx.store.url)
        fx.store.documentStore = ds
        defer { Task { await ds.close() } }
        ds.register(document: fx.doc, for: fx.path)

        try await writeIdentityTranslation(fx, language: "es")

        let sourceAST = try ProjectASTBuilder.build(
            from: ProjectStoreASTSource(projectStore: fx.store))
        let translatedAST = try ProjectASTBuilder.build(
            from: ProjectStoreASTSource(projectStore: fx.store, language: "es"))

        // Guard: the fixture really is a two-paragraph doc with a multi-line block.
        XCTAssertEqual(fx.doc.sequence.count, 2,
            "fixture must be scene-heading + one character/dialogue paragraph")
        XCTAssertFalse(sourceAST.sections.isEmpty, "fixture produced no sections")
        XCTAssertEqual(
            translatedAST, sourceAST,
            "identity translation must reproduce the source AST via the open-doc "
            + "live-Document path; a divergence on the multi-line dialogue block "
            + "means the \"\\n\\n\" join is wrong — fix the join, not the test")
    }

    // MARK: - identity equivalence: prose with fenced code containing blank line

    func test_identityEquivalence_fencedCodeBlockWithInternalBlankLine() async throws {
        // A fenced code block with a truly blank line inside the fence.
        // ParagraphParser splits it into two paragraph units at that blank;
        // the pin proves the substitution path still round-trips byte-identically.
        let body = """
        Preamble text.

        ```
        line one

        line three
        ```

        Trailing text.
        """
        let fx = try await makeFixture(fileName: "code.md", body: body)
        try await writeIdentityTranslation(fx, language: "es")
        // Doc is NOT registered → both sources take the closed-doc branch.

        let sourceAST = try ProjectASTBuilder.build(
            from: ProjectStoreASTSource(projectStore: fx.store))
        let translatedAST = try ProjectASTBuilder.build(
            from: ProjectStoreASTSource(projectStore: fx.store, language: "es"))

        XCTAssertFalse(sourceAST.sections.isEmpty, "fixture produced no sections")
        XCTAssertEqual(
            translatedAST, sourceAST,
            "identity translation must reproduce the source AST via the closed-doc "
            + "derivedCache path even when a fenced code block contains internal blanks; "
            + "a divergence means the \"\\n\\n\" join no longer matches stripAnchors(materialize()) "
            + "— fix the join, not the test")
    }

    // MARK: - identity equivalence: fountain with trailing held-blank dialogue pause

    func test_identityEquivalence_fountainTrailingHeldBlank() async throws {
        // A fountain document whose LAST paragraph is a held-blank dialogue pause
        // (a two-space line, per ParagraphParser's held-blank rule).
        // This pins the trailing-whitespace trim edge in the join.
        let body = """
        INT. KITCHEN - DAY

        AARON
        What's for breakfast?

        """
        let fx = try await makeFixture(fileName: "trailing.fountain", body: body)

        // Register the doc so BOTH sources take the open-doc (live Document) branch.
        let ds = try await DocumentStore.open(url: fx.store.url)
        fx.store.documentStore = ds
        defer { Task { await ds.close() } }
        ds.register(document: fx.doc, for: fx.path)

        try await writeIdentityTranslation(fx, language: "es")

        let sourceAST = try ProjectASTBuilder.build(
            from: ProjectStoreASTSource(projectStore: fx.store))
        let translatedAST = try ProjectASTBuilder.build(
            from: ProjectStoreASTSource(projectStore: fx.store, language: "es"))

        // Guard: the fixture really includes the held-blank final paragraph.
        XCTAssertGreaterThan(fx.doc.sequence.count, 1,
            "fixture must include the held-blank dialogue pause as a paragraph")
        XCTAssertFalse(sourceAST.sections.isEmpty, "fixture produced no sections")
        XCTAssertEqual(
            translatedAST, sourceAST,
            "identity translation must reproduce the source AST via the open-doc "
            + "live-Document path even with a trailing held-blank dialogue pause; "
            + "a divergence means the \"\\n\\n\" join's trailing-whitespace trim "
            + "is wrong — fix the join, not the test")
    }

    // MARK: - real substitution: translated text lands in the AST nodes

    func test_realTranslation_blockquoteParagraph_reemergesTranslatedAndSameKind() async throws {
        // A blockquote paragraph in the source; the translation swaps the text
        // but keeps the `> **…**` shape, so it must re-emerge as a blockquote
        // node carrying the TRANSLATED words, not the source words.
        let body = "> **Doctor:** How are you feeling today?"
        let fx = try await makeFixture(fileName: "consult.md", body: body)

        let id = try XCTUnwrap(fx.doc.sequence.first)
        let source = fx.doc.paragraphs[id] ?? ""
        let translated = "> **Doctora:** ¿Cómo se siente hoy?"
        let rec = TranslationRecord(
            paragraphId: id, language: "es", text: translated,
            sourceHash: TranslationHash.hash(source), verbatim: false)
        try await TranslationStore.append(
            rec, forDocId: fx.docId, deviceSlug: DeviceSlug.make(from: "test-mac"),
            in: fx.store.url)

        let ast = try ProjectASTBuilder.build(
            from: ProjectStoreASTSource(projectStore: fx.store, language: "es"))
        let nodes = try XCTUnwrap(ast.sections.first?.nodes)
        XCTAssertEqual(nodes.count, 1)

        guard case .prose(.blockquote(let inner)) = nodes[0] else {
            return XCTFail("translated paragraph must re-parse as a blockquote, got \(nodes)")
        }
        let text = inner.map(Self.flatten(node:)).joined(separator: "\n")
        XCTAssertTrue(text.contains("Doctora:"),
            "translated strong text must land in the AST, got \(text)")
        XCTAssertTrue(text.contains("¿Cómo se siente hoy?"),
            "translated body must land in the AST, got \(text)")
        XCTAssertFalse(text.contains("Doctor:") && !text.contains("Doctora:"),
            "source strong text must be replaced, got \(text)")
        XCTAssertFalse(text.contains("How are you feeling today?"),
            "source body must be replaced, got \(text)")
    }

    // MARK: - real translation: fountain structure is the SOURCE's

    /// The Serbian preview bug (2026-08-27): a Cyrillic slugline re-parses as
    /// a character cue, and the emitter trusted the re-parse. The source
    /// paragraph's element is authoritative — the translated edition's AST
    /// must carry a scene heading, with the translated words, and the cue +
    /// dialogue that follow it must keep their roles too.
    func test_realTranslation_cyrillicSlugline_isASceneHeadingNotACue() async throws {
        let body = """
        EXT. TERRACE - DAY

        GRACE
        Morning, everyone.

        CUT TO:
        """
        let fx = try await makeFixture(fileName: "scene.fountain", body: body)
        XCTAssertEqual(fx.doc.sequence.count, 3, "fixture must be heading + block + transition")

        let translations = ["ЕКСТ. ТЕРАСА - ДАН", "ГРЕЈС\nДобро јутро свима.", "РЕЗ НА:"]
        let slug = DeviceSlug.make(from: "test-mac")
        for (id, text) in zip(fx.doc.sequence, translations) {
            let source = fx.doc.paragraphs[id] ?? ""
            let rec = TranslationRecord(
                paragraphId: id, language: "sr", text: text,
                sourceHash: TranslationHash.hash(source), verbatim: false)
            try await TranslationStore.append(
                rec, forDocId: fx.docId, deviceSlug: slug, in: fx.store.url)
        }

        let ast = try ProjectASTBuilder.build(
            from: ProjectStoreASTSource(projectStore: fx.store, language: "sr"))
        let nodes = try XCTUnwrap(ast.sections.first?.nodes)
        let shape = nodes.map { node -> String in
            guard case .fountain(let f) = node else { return "prose" }
            switch f {
            case .sceneHeading(let s, _): return "heading(\(s))"
            case .character(let s): return "character(\(s))"
            case .dialogue(let i): return "dialogue(\(Self.flatten(inlines: i)))"
            case .transition(let s): return "transition(\(s))"
            case .action(let i): return "action(\(Self.flatten(inlines: i)))"
            default: return "other"
            }
        }
        XCTAssertEqual(shape, [
            "heading(ЕКСТ. ТЕРАСА - ДАН)",
            "character(ГРЕЈС)",
            "dialogue(Добро јутро свима.)",
            "transition(РЕЗ НА:)",
        ], "the translated edition must keep the source's structure with the translated words")
    }

    // MARK: - plain-text flatteners (assert translated text, ignore inline shape)

    private static func flatten(inlines: [ProjectAST.Inline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s), .code(let s): return s
            case .emphasis(let i), .strong(let i), .strikethrough(let i), .underline(let i):
                return flatten(inlines: i)
            case .wikiLink(_, let display): return display
            case .lineBreak: return "\n"
            }
        }.joined()
    }

    private static func flatten(node: ProjectAST.ProseNode) -> String {
        switch node {
        case .paragraph(let i), .heading(_, let i): return flatten(inlines: i)
        case .blockquote(let inner): return inner.map(flatten(node:)).joined(separator: "\n")
        case .list(_, let items): return items.map(flatten(inlines:)).joined(separator: "\n")
        case .verbatim(let lines): return lines.joined(separator: "\n")
        case .sceneBreak: return ""
        }
    }
}

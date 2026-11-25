import XCTest
import MaughamCore
@testable import Maugham

/// **A removed edition is hidden everywhere — one predicate** (shell p4
/// closing round, fix round 1; closing review IM2 and the controller's
/// ruling "hidden means hidden"). Every derivation is driven directly with a
/// removed `es` beside a kept `sr`; the census holds that no listing of
/// translation languages escapes `BookEditions`; MCP refuses the language
/// and names the way back.
@MainActor
final class BookEditionsTests: XCTestCase {

    private let removed: [String]? = ["es"]

    // MARK: - The predicate

    func test_theOnePredicateHidesARemovedEditionCaseInsensitively() {
        XCTAssertFalse(BookEditions.lists("ES", removed: removed))
        XCTAssertTrue(BookEditions.lists("sr", removed: removed))
        XCTAssertTrue(BookEditions.lists(nil, removed: removed), "the source is always listed")
        XCTAssertEqual(BookEditions.listed(["sr", "es", "de"], removed: removed), ["sr", "de"], "order kept")
        XCTAssertEqual(BookEditions.listed(["es"], removed: nil), ["es"], "none removed: all listed")
    }

    // MARK: - Each derivation

    /// The tree's, Status's and MCP's rows' union, the desk's language rows,
    /// MCP's figure rows, the figure inspector, the translator's-note picker.
    func test_everyDerivationHidesARemovedEdition() throws {
        XCTAssertEqual(EditionStatus.editionLanguages(files: ["es", "sr"], queries: ["es"], roles: ["ES", "de"],
                                                      removed: removed), ["de", "sr"])
        var manifest = Self.manifest(docId: "d1")
        manifest.productionRoles = [ProductionRole(id: "r1", role: .translator(language: "es"), name: "Ana"),
                                    ProductionRole(id: "r2", role: .translator(language: "sr"), name: "Kiš")]
        manifest.removedEditions = removed
        XCTAssertEqual(EditionStatus.languageRows(from: [], in: manifest).map(\.language), ["sr"],
                       "the desk's and Status's language rows")
        XCTAssertEqual(EditionStatus.figureLanguages(languages: ["sr"], onFile: ["es", "sr"], removed: removed),
                       ["sr"], "MCP's figures agree with its rows")

        let url = try Self.project(withTranslationsOf: "d1", in: ["es", "sr"])
        XCTAssertEqual(DocumentStore.bookTranslationLanguages(in: url, manifest: manifest), ["sr"],
                       "the figure inspector offers no coverage line, so no reveal, into it")
        XCTAssertEqual(TranslatorsNote.editions(manifest: manifest, docId: "d1", projectURL: url), ["sr"],
                       "the translator's-note picker")
        manifest.removedEditions = nil
        XCTAssertEqual(DocumentStore.bookTranslationLanguages(in: url, manifest: manifest), ["es", "sr"],
                       "added back: listed again")
    }

    /// The Book's (and a Part's, and a piece's) To resolve, and the tree's
    /// marks, read their notes through `hiding`: a removed edition's
    /// questions are not listed; every other note is.
    func test_aRemovedEditionsQuestionsAreHiddenFromTheBooksList() {
        func note(_ id: String, language: String?) -> ProjectAnnotation {
            ProjectAnnotation(docId: "d1", annotation: Annotation(
                id: id, kind: language == nil ? .craftNote : .query, paragraphId: "aa11",
                body: "?", suggestedText: nil, priorText: nil, createdAt: Date(timeIntervalSince1970: 0),
                createdBySession: nil, status: .open, userResponse: nil, resolvedAt: nil, isStale: false,
                language: language))
        }
        let walk = ProjectAnnotationsSnapshot(
            annotations: [note("n1", language: "es"), note("n2", language: "sr"), note("n3", language: nil)],
            unreadableDocIds: [], sequences: ["d1": ["aa11"]])
        XCTAssertEqual(BookEditions.hiding(walk, removed: removed).annotations.map(\.annotation.id), ["n2", "n3"])
        XCTAssertEqual(BookEditions.hiding(walk, removed: nil), walk)
    }

    // MARK: - The reading door

    /// A reveal or a choice into a removed edition is refused, and a piece
    /// read in it when it is removed is read in Source.
    func test_aReadIntoARemovedEditionIsRefusedAndOneUnderWayReturnsToSource() {
        let reading = ReadingLanguageModel()
        reading.adopt(.init(languagesByDocId: ["d1": ["es", "sr"]]))
        XCTAssertTrue(reading.admits("es"))
        XCTAssertFalse(ReadingLanguage.readsInSourceAfterRemoval("es", reading: reading))
        reading.removedEditions = removed
        XCTAssertFalse(reading.admits("es"), "the door refuses it")
        XCTAssertTrue(reading.admits("sr"))
        XCTAssertTrue(reading.admits(nil), "Source is always admitted")
        XCTAssertEqual(reading.languages(for: "d1"), ["sr"], "the switch never offers it")
        XCTAssertTrue(ReadingLanguage.readsInSourceAfterRemoval("es", reading: reading),
                      "a piece read in it is read in Source")
        XCTAssertFalse(ReadingLanguage.readsInSourceAfterRemoval("sr", reading: reading))
        XCTAssertFalse(ReadingLanguage.readsInSourceAfterRemoval(nil, reading: reading))
    }

    // MARK: - MCP

    /// **A tool asked to write, compile, preview or propose into a removed
    /// edition refuses** in Claude's terms — the writer removed it, and it
    /// comes back when they add the language again; the app's own line names
    /// Add Language. The source is never refused.
    func test_mcpRefusesARemovedEditionAndNamesTheWayBack() async throws {
        XCTAssertThrowsError(try BookEditions.refuseIfRemoved(["sr", "ES"], removed: removed)) { error in
            XCTAssertEqual(error as? MCPError, .invalidArgument(BookEditions.removedLineForClaude(language: "ES")))
        }
        XCTAssertNoThrow(try BookEditions.refuseIfRemoved([nil, "source", "sr"], removed: removed))
        XCTAssertTrue(BookEditions.removedLine(language: "es").contains("Add Language"))

        let temp = try TempDirectory()
        defer { temp.cleanup() }
        let url = try await ProjectFactory.createNovelProject(named: "Removed", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        defer { Task { await documentStore.close() } }
        try await store.setEdition("es", removed: true)
        let registry = ProjectRegistry()
        registry.register(url: url, store: store)
        let id = ProjectIdentifier.id(for: url)
        let expected = MCPError.invalidArgument(BookEditions.removedLineForClaude(language: "es"))
        func refuses(_ call: () async throws -> Data, _ tool: String) async {
            do {
                _ = try await call()
                XCTFail("\(tool) wrote into a removed edition")
            } catch {
                XCTAssertEqual(error as? MCPError, expected, tool)
            }
        }
        func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        await refuses({ try await ProposeEditionBriefTool.handle(
            paramsJSON: try json(["project_id": id, "language": "es", "markdown": "x"]), registry: registry) },
                      "propose_edition_brief")
        await refuses({ try await WriteTranslationTool.handle(
            paramsJSON: try json(["project_id": id, "document_id": "d1", "language": "es", "entries": []]),
            registry: registry) }, "write_translation")
        await refuses({ try await CompileTool.handle(
            paramsJSON: try json(["project_id": id, "format": "pdf", "language": "es"]), registry: registry) },
                      "compile")
        await refuses({ try await PreviewCompileTool.handle(
            paramsJSON: try json(["project_id": id, "format": "pdf", "languages": ["en", "es"]]),
            registry: registry) }, "preview_compile")
    }

    // MARK: - The census

    /// **No listing of the book's translation languages escapes the one
    /// predicate.** A file that lists them from disk or the manifest also asks
    /// `BookEditions`, or is named here with why it may not; the list of
    /// removed editions itself is read only where it is written or handed to
    /// the predicate.
    func test_everyLanguageListingGoesThroughBookEditions() throws {
        let primitives = ["TranslationStore.languagesByDocId(", "TranslationStore.languages(forDocId:",
                          "storedTranslatorLanguages(in:", "editionLanguages(in: store.manifest.statements)",
                          "editionLanguages(files:"]
        let exempt: [String: String] = [
            "Maugham/Stores/ProjectStore+FigureTranslations.swift":
                "the relabel keeps a hidden edition's translations coherent for its return",
            "Maugham/Publish/FigureUse.swift": "a compile's fresh labels for one language already admitted",
            "Maugham/Views/ReadingLanguage.swift":
                "the raw listing; `languages(for:)` filters it through BookEditions",
        ]
        var offenders: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            let code = SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: "\n")
            guard primitives.contains(where: code.contains) else { continue }
            if exempt[file] != nil { continue }
            // `editionLanguages(files:…removed:)` asks the predicate itself;
            // its `removed` is required, so the compiler finds every caller.
            let handsTheListOn = code.contains("editionLanguages(") && code.contains(".removedEditions)")
            if !code.contains("BookEditions.") && !handsTheListOn && !file.hasSuffix("BookEditions.swift") {
                offenders.append(file)
            }
        }
        XCTAssertEqual(offenders, [], "a language listing that does not ask BookEditions")
        // The two places To resolve reads its notes hide a removed edition's.
        for (file, token) in [
            ("Maugham/Views/Resolve/ResolveReader.swift", "annotations: BookEditions.hiding(overlaying(annotations, live: live),"),
            ("Maugham/Views/Resolve/ResolvePresence.swift", "annotations: BookEditions.hiding(ResolveReader.overlaying(walk, live: live),"),
            ("Maugham/Views/Brief/BriefReader.swift", "for language in BookEditions.listed(editionLanguages(in: store.manifest.statements),"),
        ] {
            let code = SourceScan.codeLines(of: try SourceTree.read(file))
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            XCTAssertTrue(code.contains(token), "\(file) lost: \(token)")
        }
        // `isEditionRemoved` / `removedEditions` are not asked behind the
        // predicate's back.
        let readers: Set<String> = [
            "Maugham/Publish/BookEditions.swift", "Maugham/Stores/ProjectStore+ProductionRoles.swift",
        ]
        for file in try SourceTree.swiftFiles(under: "Maugham") where !readers.contains(file) {
            let code = SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: "\n")
            XCTAssertFalse(code.contains("isEditionRemoved("), "\(file) asks isEditionRemoved itself")
        }
    }

    // MARK: - Fixtures

    private static func manifest(docId: String) -> ProjectManifest {
        ProjectManifest(type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
                        structure: [StructureItem(id: docId, title: "One", type: .document, path: "one.md")],
                        research: [])
    }

    private static func project(withTranslationsOf docId: String, in languages: [String]) throws -> URL {
        let url = TestTemp.root.appendingPathComponent("BookEditions-\(UUID().uuidString.prefix(6))")
        let folder = TranslationStore.directoryURL(in: url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for language in languages {
            try Data("{}\n".utf8).write(to: folder.appendingPathComponent("\(docId).\(language).dev1.jsonl"))
        }
        return url
    }
}

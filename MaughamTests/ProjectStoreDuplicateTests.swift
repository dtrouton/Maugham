import XCTest
@testable import Maugham
@testable import MaughamCore

@MainActor
final class ProjectStoreDuplicateTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeNovel() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Dupe", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    func test_duplicateDocument_createsCopyWithCopyOfPrefix() async throws {
        let (url, store, ds) = try await makeNovel()
        let chapter1 = store.manifest.structure[0]
        try "Hello world".write(
            to: url.appendingPathComponent(chapter1.path!),
            atomically: true, encoding: .utf8)

        let copy = try await store.duplicateStructureItem(id: chapter1.id)

        XCTAssertEqual(copy.title, "Copy of Chapter 1")
        XCTAssertNotEqual(copy.id, chapter1.id)
        XCTAssertEqual(copy.type, .document)

        let copyURL = url.appendingPathComponent(copy.path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
        let copyContent = try String(contentsOf: copyURL, encoding: .utf8)
        XCTAssertEqual(copyContent, "Hello world")

        XCTAssertEqual(store.manifest.structure.count, 2)
        XCTAssertEqual(store.manifest.structure[1].id, copy.id)
        await ds.close()
    }

    func test_duplicateDocument_filenameUsesNextNN() async throws {
        let (_, store, ds) = try await makeNovel()
        let chapter1 = store.manifest.structure[0]

        let copy = try await store.duplicateStructureItem(id: chapter1.id)

        XCTAssertTrue(copy.path!.hasPrefix("manuscript/02-"),
                      "expected NN '02-' prefix, got \(copy.path!)")
        await ds.close()
    }

    func test_duplicateGroup_recursivelyCopiesDescendants() async throws {
        let (url, store, ds) = try await makeNovel()
        let group = try await store.addStructureItem(
            parentId: nil, title: "Act One", kind: .group)
        let inner1 = try await store.addStructureItem(
            parentId: group.id, title: "Scene 1",
            kind: .document(.markdown))
        try "scene 1 text".write(
            to: url.appendingPathComponent(inner1.path!),
            atomically: true, encoding: .utf8)

        let copy = try await store.duplicateStructureItem(id: group.id)

        XCTAssertEqual(copy.title, "Copy of Act One")
        XCTAssertEqual(copy.type, .group)
        XCTAssertNotEqual(copy.id, group.id)
        XCTAssertEqual(copy.children?.count, 1)
        let copiedInner = copy.children!.first!
        XCTAssertNotEqual(copiedInner.id, inner1.id)
        XCTAssertEqual(copiedInner.title, "Scene 1")
        let copiedFileURL = url.appendingPathComponent(copiedInner.path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedFileURL.path))
        let copiedContent = try String(contentsOf: copiedFileURL, encoding: .utf8)
        XCTAssertEqual(copiedContent, "scene 1 text")
        await ds.close()
    }

    func test_duplicate_invalidId_throws() async throws {
        let (_, store, ds) = try await makeNovel()
        do {
            _ = try await store.duplicateStructureItem(id: "nope")
            XCTFail("expected throw")
        } catch ProjectStoreError.structureMissing {}
        await ds.close()
    }

    // MARK: - The creation-time opening is byte-neutral (P3c plan 2 Task 4)

    /// **A copy's bytes are exactly what its first open would have written**
    /// (fix round 3, Minor 3). Duplicate now mints the copy's opening at
    /// creation and renders it (Ruling L (a)); before, the first open did.
    /// Pinned for the shapes a render could normalise: a Fountain piece,
    /// trailing blank lines, and CRLF line endings — each compared with the
    /// render the SOURCE's own first open writes, since the copy is its words.
    func test_aCopysBytesAreWhatItsFirstOpenWouldHaveWritten() async throws {
        let (url, store, ds) = try await makeNovel()
        let cases: [(format: DocumentFormat, body: String)] = [
            (.fountain, "INT. HOUSE - DAY\n\nShe walks in.\n\nANNA\nHello.\n"),
            (.markdown, "One.\n\nTwo.\n\n\n\n"),
            (.markdown, "One.\r\n\r\nTwo.\r\n"),
        ]
        for (index, shape) in cases.enumerated() {
            let source = try await store.addStructureItem(
                parentId: nil, title: "Source \(index)",
                kind: .document(shape.format))
            let sourceURL = url.appendingPathComponent(source.path!)
            try Data(shape.body.utf8).write(to: sourceURL)

            let copy = try await store.duplicateStructureItem(id: source.id)
            let copyBytes = try Data(contentsOf: url.appendingPathComponent(copy.path!))

            let firstOpen = try await Document.load(
                url: sourceURL, actor: .author, session: "first-open", presenter: nil)
            try await firstOpen.performAutosave()
            let sourceText = firstOpen.displayText
            await firstOpen.close()
            XCTAssertEqual(copyBytes, try Data(contentsOf: sourceURL),
                           "case \(index): the copy holds its first open's render")

            let copied = try await Document.load(
                url: url.appendingPathComponent(copy.path!), actor: .author,
                session: "copy-open", presenter: nil)
            XCTAssertEqual(copied.displayText, sourceText, "case \(index): the same words")
            await copied.close()
        }
        await ds.close()
    }

    func test_duplicateResearchItem_givesTheCopyAFreshCitationKey() async throws {
        let (_, store, _) = try await makeNovel()
        let info = CitationInfo(key: "gartner2026", authors: ["Gartner"], year: 2026, pages: "4")
        store.manifest.research.append(ResearchItem(id: "r-src", title: "Src", type: .asset, kind: .link,
                                                    url: "https://example.com", citation: info))
        let copy = try await store.duplicateResearchItem(id: "r-src")
        XCTAssertEqual(copy.citation?.key, "gartner2026a")
        XCTAssertEqual(copy.citation?.pages, "4")
        XCTAssertEqual(store.manifest.research.first { $0.id == "r-src" }?.citation?.key, "gartner2026")
    }

    func test_duplicateResearchGroup_rekeysCitedChildren() async throws {
        let (_, store, _) = try await makeNovel()
        let child = ResearchItem(id: "r-kid", title: "Kid", type: .asset, kind: .link, url: "https://example.com",
                                 citation: CitationInfo(key: "gartner2026", authors: ["Gartner"], year: 2026))
        store.manifest.research.append(ResearchItem(id: "g-src", title: "G", type: .group, children: [child]))
        let copy = try await store.duplicateResearchItem(id: "g-src")
        XCTAssertEqual(copy.children?.first?.citation?.key, "gartner2026a")
        XCTAssertEqual(store.manifest.research.citationKeys, ["gartner2026", "gartner2026a"])
    }
}

import XCTest
@testable import Maugham
@testable import MaughamCore

/// The one door a research item's citation details are written through
/// (report foundations plan 3a, R-3a-7): `ProjectStore.updateCitation`.
/// The inspector and `update_research_citation` both call it, so its rules
/// are pinned here once.
@MainActor
final class CitationEditTests: XCTestCase {
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
        let url = try await ProjectFactory.createNovelProject(named: "Cite", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    private func link(_ id: String, _ key: String? = nil, authors: [String] = ["Gartner"], year: Int? = 2026) -> ResearchItem {
        ResearchItem(id: id, title: "Item \(id)", type: .asset, kind: .link,
                     url: "https://example.com/\(id)",
                     citation: key.map { CitationInfo(key: $0, authors: authors, year: year) })
    }

    private func citation(of id: String, in store: ProjectStore) -> CitationInfo? {
        TreeWalk.find(id: id, in: store.manifest.research)?.citation
    }

    private func assertRefused(
        _ expected: CitationEditError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CitationEditError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }

    // MARK: - Valid

    func test_aValidCitationIsStoredAndReachesDiskThroughTheContentFloor() async throws {
        let (url, store, ds) = try await makeNovel()
        store.manifest.research.append(link("r-a"))
        let accessed = Date(timeIntervalSince1970: 1_780_000_000)
        let info = CitationInfo(key: "gartner2026", authors: ["Gartner"], sourceTitle: "Hype Cycle",
                                publisher: "Gartner Inc.", year: 2026, accessed: accessed, pages: "4–9")
        try await store.updateCitation(researchId: "r-a", info)
        XCTAssertEqual(citation(of: "r-a", in: store), info)

        await ds.close()
        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(TreeWalk.find(id: "r-a", in: reloaded.manifest.research)?.citation, info)
        XCTAssertGreaterThanOrEqual(reloaded.manifest.schemaVersion, 10,
            "a citation is v10 content: the manifest door raises the schema")
    }

    func test_fieldsAreTrimmedAndBlankAuthorsDropped() async throws {
        let (_, store, _) = try await makeNovel()
        store.manifest.research.append(link("r-a"))
        try await store.updateCitation(researchId: "r-a", CitationInfo(
            key: "  gartner2026 ", authors: [" Gartner ", "  ", ""], sourceTitle: "  ",
            publisher: " Gartner Inc. ", pages: ""))
        XCTAssertEqual(citation(of: "r-a", in: store), CitationInfo(
            key: "gartner2026", authors: ["Gartner"], publisher: "Gartner Inc."))
    }

    // MARK: - Invalid

    func test_anInvalidKeyIsRefusedAndNothingChanges() async throws {
        let (_, store, _) = try await makeNovel()
        store.manifest.research.append(link("r-a", "gartner2026"))
        await assertRefused(.invalidKey) {
            try await store.updateCitation(researchId: "r-a", CitationInfo(key: "bad key"))
        }
        await assertRefused(.invalidKey) {
            try await store.updateCitation(researchId: "r-a", CitationInfo(key: "-dash"))
        }
        XCTAssertEqual(citation(of: "r-a", in: store)?.key, "gartner2026")
    }

    func test_aKeyAnotherLiveItemHoldsIsRefused() async throws {
        let (_, store, _) = try await makeNovel()
        store.manifest.research.append(link("r-a", "smith2020"))
        store.manifest.research.append(ResearchItem(
            id: "g", title: "G", type: .group, children: [link("r-b")]))
        await assertRefused(.duplicateKey("smith2020")) {
            try await store.updateCitation(researchId: "r-b", CitationInfo(key: "smith2020"))
        }
        XCTAssertNil(citation(of: "r-b", in: store))
    }

    func test_aKeyATrashedItemHoldsIsRefused() async throws {
        let (_, store, _) = try await makeNovel()
        store.manifest.research.append(link("r-a", "jones2019"))
        store.manifest.research.append(link("r-b"))
        try await store.deleteResearchItem(id: "r-a")
        XCTAssertFalse(store.manifest.research.citationKeys.contains("jones2019"), "premise: A is in the Trash")
        await assertRefused(.duplicateKey("jones2019")) {
            try await store.updateCitation(researchId: "r-b", CitationInfo(key: "jones2019"))
        }
    }

    func test_itsOwnKeyUnchangedIsAccepted() async throws {
        let (_, store, _) = try await makeNovel()
        store.manifest.research.append(link("r-a", "gartner2026"))
        try await store.updateCitation(researchId: "r-a", CitationInfo(
            key: "gartner2026", authors: ["Gartner"], year: 2026, pages: "12"))
        XCTAssertEqual(citation(of: "r-a", in: store)?.pages, "12")
    }

    // MARK: - Clearing

    func test_nilRemovesTheCitation() async throws {
        let (_, store, _) = try await makeNovel()
        store.manifest.research.append(link("r-a", "gartner2026"))
        try await store.updateCitation(researchId: "r-a", nil)
        XCTAssertNil(citation(of: "r-a", in: store))
    }

    func test_clearingEveryFieldRemovesTheCitation() async throws {
        let (_, store, _) = try await makeNovel()
        store.manifest.research.append(link("r-a", "gartner2026"))
        try await store.updateCitation(researchId: "r-a", CitationInfo(
            key: "  ", authors: [" "], sourceTitle: "", publisher: " ", pages: ""))
        XCTAssertNil(citation(of: "r-a", in: store))
    }

    func test_clearingTheKeyWhileOtherFieldsAreSetIsRefused() async throws {
        let (_, store, _) = try await makeNovel()
        store.manifest.research.append(link("r-a", "gartner2026"))
        await assertRefused(.needsAKey) {
            try await store.updateCitation(researchId: "r-a", CitationInfo(key: "", authors: ["Gartner"]))
        }
        await assertRefused(.needsAKey) {
            try await store.updateCitation(researchId: "r-a", CitationInfo(key: " ", year: 2026))
        }
        XCTAssertEqual(citation(of: "r-a", in: store)?.key, "gartner2026")
        XCTAssertEqual(CitationEditError.needsAKey.localizedDescription, "A citation needs a key")
    }

    func test_anUnknownResearchIdIsRefused() async throws {
        let (_, store, _) = try await makeNovel()
        do {
            try await store.updateCitation(researchId: "r-nope", CitationInfo(key: "x"))
            XCTFail("expected a throw")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .structureMissing)
        }
    }

    // MARK: - A Collection piece's research

    func test_aCollectionPiecesResearchTakesTheSameDoor() async throws {
        let url = try await ProjectFactory.createCollectionProject(named: "Coll", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", format: .markdown)
        let pieceLink = try await store.addPieceResearchLink(
            pieceId: piece.id, title: "Source", url: "https://example.com/s")
        XCTAssertTrue(pieceLink.path?.hasPrefix("pieces/") == true, "premise: a piece-scoped item")
        store.manifest.research.append(link("r-shared", "shared2020"))

        try await store.updateCitation(researchId: pieceLink.id, CitationInfo(key: "piece2026", year: 2026))
        XCTAssertEqual(citation(of: pieceLink.id, in: store)?.key, "piece2026")
        await assertRefused(.duplicateKey("shared2020")) {
            try await store.updateCitation(researchId: pieceLink.id, CitationInfo(key: "shared2020"))
        }
        await assertRefused(.duplicateKey("piece2026")) {
            try await store.updateCitation(researchId: "r-shared", CitationInfo(key: "piece2026"))
        }
        await ds.close()
    }

    // MARK: - Suggest

    func test_suggestAvoidsLiveAndTrashedKeys() async throws {
        let (_, store, _) = try await makeNovel()
        store.manifest.research.append(link("r-live", "gartner2026"))
        store.manifest.research.append(link("r-gone", "gartner2026a"))
        store.manifest.research.append(ResearchItem(
            id: "r-new", title: "New", type: .asset, kind: .link, url: "https://example.com",
            citation: CitationInfo(key: "placeholder", authors: ["Ada Gartner"], year: 2026)))
        try await store.deleteResearchItem(id: "r-gone")
        let suggested = await store.suggestedCitationKey(for: "r-new")
        XCTAssertEqual(suggested, "gartner2026b")
    }

    func test_suggestDoesNotCountTheItemsOwnKey() async throws {
        let (_, store, _) = try await makeNovel()
        store.manifest.research.append(link("r-a", "gartner2026"))
        let suggested = await store.suggestedCitationKey(for: "r-a")
        XCTAssertEqual(suggested, "gartner2026")
    }

    func test_suggestFromDraftValuesUsesThemOverTheStoredOnes() async throws {
        let (_, store, _) = try await makeNovel()
        store.manifest.research.append(link("r-a"))
        let suggested = await store.suggestedCitationKey(
            for: "r-a", authors: ["Mary Smith"], year: 1999, sourceTitle: nil)
        XCTAssertEqual(suggested, "smith1999")
        let fromTitle = await store.suggestedCitationKey(
            for: "r-a", authors: [], year: nil, sourceTitle: nil)
        XCTAssertEqual(fromTitle, "item", "no authors and no source title: a word of the item's title")
    }
}

import XCTest
import MaughamCore
@testable import Maugham

/// `update_research_citation` goes through `ProjectStore.updateCitation` (the
/// rules are pinned in `CitationEditTests`); here: the wire, the error mapping,
/// and `list_research` reporting the citation back.
@MainActor
final class UpdateResearchCitationToolTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeRegistry() async throws -> (ProjectRegistry, ProjectStore, DocumentStore, String) {
        let url = try await ProjectFactory.createNovelProject(named: "MCPCite", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        store.manifest.research.append(ResearchItem(
            id: "r-a", title: "Hype Cycle", type: .asset, kind: .link, url: "https://example.com/a"))
        store.manifest.research.append(ResearchItem(
            id: "r-b", title: "Other", type: .asset, kind: .link, url: "https://example.com/b",
            citation: CitationInfo(key: "smith2020", authors: ["Smith"], year: 2020)))
        let registry = ProjectRegistry()
        registry.register(url: url, store: store)
        return (registry, store, ds, ProjectIdentifier.id(for: url))
    }

    private func call(_ dict: [String: Any], _ registry: ProjectRegistry) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: dict)
        let out = try await UpdateResearchCitationTool.handle(paramsJSON: data, registry: registry)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    private func assertInvalidArgument(
        _ dict: [String: Any], _ registry: ProjectRegistry, containing words: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await call(dict, registry)
            XCTFail("expected invalid_argument", file: file, line: line)
        } catch let MCPError.invalidArgument(message) {
            XCTAssertTrue(message.contains(words), "\(message)", file: file, line: line)
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }

    private static func utcDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func test_aFullCitationRoundTripsThroughTheStoreAndListResearch() async throws {
        let (registry, store, ds, pid) = try await makeRegistry()
        let result = try await call([
            "project_id": pid, "research_id": "r-a",
            "citation": [
                "key": "gartner2026", "authors": ["Gartner", "Ada Lovelace"],
                "source_title": "Hype Cycle for AI", "publisher": "Gartner Inc.",
                "year": 2026, "accessed": "2026-03-03", "pages": "4–9",
            ] as [String: Any],
        ], registry)

        XCTAssertEqual(result["research_id"] as? String, "r-a")
        let wire = try XCTUnwrap(result["citation"] as? [String: Any])
        XCTAssertEqual(wire["key"] as? String, "gartner2026")
        XCTAssertEqual(wire["accessed"] as? String, "2026-03-03")

        let stored = TreeWalk.find(id: "r-a", in: store.manifest.research)?.citation
        XCTAssertEqual(stored, CitationInfo(
            key: "gartner2026", authors: ["Gartner", "Ada Lovelace"], sourceTitle: "Hype Cycle for AI",
            publisher: "Gartner Inc.", year: 2026, accessed: Self.utcDay(2026, 3, 3), pages: "4–9"))

        let listed = try await ListResearchTool.handle(
            paramsJSON: try JSONSerialization.data(withJSONObject: ["project_id": pid]), registry: registry)
        let tree = try XCTUnwrap(try JSONSerialization.jsonObject(with: listed) as? [String: Any])
        let items = try XCTUnwrap(tree["items"] as? [[String: Any]])
        let a = try XCTUnwrap(items.first { $0["id"] as? String == "r-a" })
        let cite = try XCTUnwrap(a["citation"] as? [String: Any])
        XCTAssertEqual(cite["key"] as? String, "gartner2026")
        XCTAssertEqual(cite["authors"] as? [String], ["Gartner", "Ada Lovelace"])
        XCTAssertEqual(cite["source_title"] as? String, "Hype Cycle for AI")
        XCTAssertEqual(cite["publisher"] as? String, "Gartner Inc.")
        XCTAssertEqual(cite["year"] as? Int, 2026)
        XCTAssertEqual(cite["accessed"] as? String, "2026-03-03")
        XCTAssertEqual(cite["pages"] as? String, "4–9")
        await ds.close()
    }

    /// The shape: an item with no citation reports `citation: null`; one with
    /// a citation reports all seven fields, null where unset; the other
    /// optional fields keep their old form (absent when nil).
    func test_listResearchReportsACitationOrNullOnEveryItem() async throws {
        let (registry, _, ds, pid) = try await makeRegistry()
        let listed = try await ListResearchTool.handle(
            paramsJSON: try JSONSerialization.data(withJSONObject: ["project_id": pid]), registry: registry)
        let tree = try XCTUnwrap(try JSONSerialization.jsonObject(with: listed) as? [String: Any])
        let items = try XCTUnwrap(tree["items"] as? [[String: Any]])
        let a = try XCTUnwrap(items.first { $0["id"] as? String == "r-a" })
        XCTAssertTrue(a["citation"] is NSNull, "null rather than vanishing: \(a)")
        XCTAssertNil(a["children"], "an asset's children stay absent, as before")
        let b = try XCTUnwrap(items.first { $0["id"] as? String == "r-b" })
        let cite = try XCTUnwrap(b["citation"] as? [String: Any])
        XCTAssertEqual(Set(cite.keys),
                       ["key", "authors", "source_title", "publisher", "year", "accessed", "pages"])
        XCTAssertTrue(cite["publisher"] is NSNull)
        XCTAssertTrue(cite["accessed"] is NSNull)
        XCTAssertEqual(cite["year"] as? Int, 2020)
        await ds.close()
    }

    func test_nullRemovesTheCitation() async throws {
        let (registry, store, ds, pid) = try await makeRegistry()
        let result = try await call(
            ["project_id": pid, "research_id": "r-b", "citation": NSNull()], registry)
        XCTAssertTrue(result["citation"] is NSNull)
        XCTAssertNil(TreeWalk.find(id: "r-b", in: store.manifest.research)?.citation)
        await ds.close()
    }

    func test_anOmittedCitationIsRefusedRatherThanReadAsNull() async throws {
        let (registry, store, ds, pid) = try await makeRegistry()
        await assertInvalidArgument(["project_id": pid, "research_id": "r-b"], registry,
                                    containing: "citation")
        XCTAssertNotNil(TreeWalk.find(id: "r-b", in: store.manifest.research)?.citation)
        await ds.close()
    }

    func test_theDoorsRefusalsAreInvalidArgumentsInTheWritersWords() async throws {
        let (registry, _, ds, pid) = try await makeRegistry()
        await assertInvalidArgument(
            ["project_id": pid, "research_id": "r-a", "citation": ["key": "smith2020"]], registry,
            containing: "smith2020")
        await assertInvalidArgument(
            ["project_id": pid, "research_id": "r-a", "citation": ["key": "bad key"]], registry,
            containing: "letters, digits")
        await assertInvalidArgument(
            ["project_id": pid, "research_id": "r-b",
             "citation": ["authors": ["Smith"]] as [String: Any]], registry,
            containing: "A citation needs a key")
        await ds.close()
    }

    func test_aMalformedDateAndAnUnknownIdAreInvalidArguments() async throws {
        let (registry, _, ds, pid) = try await makeRegistry()
        await assertInvalidArgument(
            ["project_id": pid, "research_id": "r-a",
             "citation": ["key": "x2026", "accessed": "3 March 2026"]], registry,
            containing: "YYYY-MM-DD")
        await assertInvalidArgument(
            ["project_id": pid, "research_id": "r-nope", "citation": ["key": "x2026"]], registry,
            containing: "r-nope")
        await ds.close()
    }

    func test_theISODateHelpersAreUTCDays() {
        XCTAssertEqual(ResearchCitationWire.parseDay("2026-03-03"), Self.utcDay(2026, 3, 3))
        XCTAssertNil(ResearchCitationWire.parseDay("2026-3-3x"))
        XCTAssertNil(ResearchCitationWire.parseDay("2026-02-30"))
        XCTAssertEqual(ResearchCitationWire.formatDay(Self.utcDay(2026, 12, 31)), "2026-12-31")
    }
}

import XCTest
@testable import MaughamCore

final class CitationInfoTests: XCTestCase {
    func test_suggest_examples() {
        XCTAssertEqual(CitationKey.suggest(authors: ["Müller"], year: 2020, title: "x", existing: []), "muller2020")
        XCTAssertEqual(CitationKey.suggest(authors: ["García Márquez"], year: nil, title: "x", existing: []), "marquez")
        XCTAssertEqual(CitationKey.suggest(authors: ["林"], year: nil, title: "x", existing: []), "lin")
        XCTAssertEqual(CitationKey.suggest(authors: [], year: nil, title: "The State of AI", existing: []), "state")
    }

    func test_suggest_skipsEmptyAuthorsAndFallsBack() {
        XCTAssertEqual(CitationKey.suggest(authors: ["  ", "Ada Lovelace"], year: 1843, title: "t", existing: []), "lovelace1843")
        XCTAssertEqual(CitationKey.suggest(authors: [], year: nil, title: "A to Z", existing: []), "source")
        XCTAssertEqual(CitationKey.suggest(authors: ["!!!"], year: 2001, title: "t", existing: []), "source2001")
    }

    func test_suggest_deduplicates() {
        XCTAssertEqual(CitationKey.suggest(authors: ["Gartner"], year: 2026, title: "t", existing: ["gartner2026"]), "gartner2026a")
        XCTAssertEqual(CitationKey.suggest(authors: ["Gartner"], year: 2026, title: "t", existing: ["gartner2026", "gartner2026a"]), "gartner2026b")
        var taken: Set<String> = ["k"]
        for c in "abcdefghijklmnopqrstuvwxyz" { taken.insert("k\(c)") }
        XCTAssertEqual(CitationKey.suggest(authors: ["K"], year: nil, title: "t", existing: taken), "kaa")
    }

    func test_isValid() {
        for ok in ["a", "muller2020", "A_b-c", "9x"] { XCTAssertTrue(CitationKey.isValid(ok), ok) }
        for bad in ["", "-a", "_a", "a b", "é", "a.b", "a]"] { XCTAssertFalse(CitationKey.isValid(bad), bad) }
    }

    func test_roundTripWithAndWithoutCitation() throws {
        let enc = JSONEncoder(), dec = JSONDecoder()
        let plain = ResearchItem(id: "r1", title: "T", type: .asset)
        XCTAssertNil(try dec.decode(ResearchItem.self, from: enc.encode(plain)).citation)
        let info = CitationInfo(key: "k1", authors: ["A B"], sourceTitle: "S", publisher: "P", year: 2020,
                                accessed: Date(timeIntervalSince1970: 1_700_000_000), pages: "1-2")
        let cited = ResearchItem(id: "r2", title: "T", type: .asset, citation: info)
        XCTAssertEqual(try dec.decode(ResearchItem.self, from: enc.encode(cited)), cited)
    }

    func test_preFeatureJSONDecodesWithNilCitation() throws {
        let json = #"{"id":"r1","title":"T","type":"asset"}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(ResearchItem.self, from: json).citation)
    }

    func test_citationKeysFindsNestedKeys() {
        let leaf = ResearchItem(id: "c", title: "c", type: .asset, citation: CitationInfo(key: "deep"))
        let inner = ResearchItem(id: "g2", title: "g2", type: .group, children: [leaf])
        let outer = ResearchItem(id: "g1", title: "g1", type: .group, children: [inner])
        let top = ResearchItem(id: "t", title: "t", type: .asset, citation: CitationInfo(key: "top"))
        XCTAssertEqual([outer, top].citationKeys, ["deep", "top"])
    }
}

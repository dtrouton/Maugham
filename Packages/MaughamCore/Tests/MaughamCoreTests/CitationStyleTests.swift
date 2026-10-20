import XCTest
@testable import MaughamCore

final class CitationStyleTests: XCTestCase {
    private func entry(_ key: String, authors: [String] = [], year: Int? = 2026,
                       sourceTitle: String? = nil, title: String = "Item", publisher: String? = nil,
                       accessed: Date? = nil, url: String? = nil) -> CitationLibrary.Entry {
        let item = ResearchItem(id: "i", title: title, type: .asset, url: url,
                                citation: CitationInfo(key: key, authors: authors, sourceTitle: sourceTitle,
                                                       publisher: publisher, year: year, accessed: accessed))
        return CitationLibrary(items: [item]).entry(for: key)!
    }

    private func label(_ e: CitationLibrary.Entry) -> String {
        CitationStyle.disambiguated([e])[0].label
    }

    func test_nameForms() {
        XCTAssertEqual(label(entry("a", authors: ["Smith, Jane"])), "Smith 2026")
        XCTAssertEqual(label(entry("a", authors: ["Gartner"])), "Gartner 2026")
        XCTAssertEqual(label(entry("a", authors: ["Smith, Jane", "Lee, Wu"])), "Smith and Lee 2026")
        XCTAssertEqual(label(entry("a", authors: ["Smith, J", "Lee, W", "Kim, K"])), "Smith et al. 2026")
        XCTAssertEqual(label(entry("a", sourceTitle: "Annual Report")), "Annual Report 2026")
        XCTAssertEqual(label(entry("a", title: "Notes")), "Notes 2026")
    }

    func test_missingYear_isND() {
        XCTAssertEqual(label(entry("a", authors: ["Gartner"], year: nil)), "Gartner n.d.")
    }

    func test_unicodeAuthors() {
        XCTAssertEqual(label(entry("a", authors: ["Müller, Hans"])), "Müller 2026")
        XCTAssertEqual(label(entry("a", authors: ["林"])), "林 2026")
    }

    func test_sameNameAndYear_takeLettersInReferencesOrder() {
        let b = entry("b", authors: ["Smith, J"], title: "Zebra")
        let a = entry("a", authors: ["Smith, J"], title: "Apple")
        let out = CitationStyle.disambiguated([b, a])
        XCTAssertEqual(out.map(\.label), ["Smith 2026a", "Smith 2026b"])
        XCTAssertEqual(out.map(\.entry.info.key), ["a", "b"])
    }

    func test_namesDifferingOnlyByCaseOrDiacritics_areDisambiguated() {
        let out = CitationStyle.disambiguated([entry("m2", authors: ["Muller"]), entry("m1", authors: ["Müller"])])
        XCTAssertTrue(out.allSatisfy { $0.label.hasSuffix("a") || $0.label.hasSuffix("b") })
        XCTAssertEqual(Set(out.map { String($0.label.last!) }), ["a", "b"])
    }

    func test_identicalNameYearAndTitle_orderByKey() {
        let out = CitationStyle.disambiguated([entry("z", authors: ["Smith"]), entry("y", authors: ["Smith"])])
        XCTAssertEqual(out.map(\.entry.info.key), ["y", "z"])
        XCTAssertEqual(out.map(\.label), ["Smith 2026a", "Smith 2026b"])
    }

    func test_referencesOrder_nameThenYear_caseAndDiacriticInsensitive() {
        let es = [entry("1", authors: ["zed"]), entry("2", authors: ["Émile"]),
                  entry("3", authors: ["Adams"], year: 2030), entry("4", authors: ["Adams"], year: 2020)]
        XCTAssertEqual(CitationStyle.disambiguated(es).map(\.entry.info.key), ["4", "3", "2", "1"])
    }

    func test_inText_locatorAndMultipleItems() {
        let labels = ["a": "Smith 2026", "b": "Lee n.d."]
        XCTAssertEqual(CitationStyle.inText([CitationItem(key: "a", locator: "p. 12")], labels: labels),
                       "(Smith 2026, p. 12)")
        XCTAssertEqual(CitationStyle.inText([CitationItem(key: "a", locator: nil),
                                             CitationItem(key: "b", locator: nil)], labels: labels),
                       "(Smith 2026; Lee n.d.)")
    }

    func test_inText_unknownKeyOrNoItems_isNil() {
        let labels = ["a": "Smith 2026"]
        XCTAssertNil(CitationStyle.inText([CitationItem(key: "a", locator: nil),
                                           CitationItem(key: "zz", locator: nil)], labels: labels))
        XCTAssertNil(CitationStyle.inText([], labels: labels))
    }

    func test_referenceEntry_full() {
        let date = Date(timeIntervalSince1970: 1_772_496_000) // 2026-03-03 00:00 UTC
        let e = entry("a", authors: ["Smith, Jane"], sourceTitle: "A Book", publisher: "Acme",
                      accessed: date, url: "https://x.org")
        let runs = CitationStyle.referenceEntry(e, label: "Smith 2026")
        XCTAssertEqual(runs.map(\.text).joined(),
                       "Smith, Jane. 2026. A Book. Acme. https://x.org (accessed 3 March 2026).")
        XCTAssertEqual(runs.filter(\.italic).map(\.text), ["A Book"])
    }

    func test_referenceEntry_everyOptionalPartAbsent_hasNoStrayPunctuation() {
        let e = entry("a", year: nil, title: "Notes")
        let text = CitationStyle.referenceEntry(e, label: "Notes n.d.").map(\.text).joined()
        XCTAssertEqual(text, "n.d. Notes.")
        XCTAssertFalse(text.contains(". ."))
    }

    /// I2 (final review): the a/b letter the in-text label carries is printed
    /// in the References entry's year too, or "(Smith 2026a)" matches nothing.
    func test_sameNameAndYear_theReferenceEntryCarriesTheInTextLetter() {
        let out = CitationStyle.disambiguated([
            entry("b", authors: ["Smith, Jane"], sourceTitle: "Zebra"),
            entry("a", authors: ["Smith, Jane"], sourceTitle: "Apple")])
        XCTAssertEqual(out.map { CitationStyle.inText([CitationItem(key: $0.entry.info.key, locator: nil)],
                                                      labels: [$0.entry.info.key: $0.label]) },
                       ["(Smith 2026a)", "(Smith 2026b)"])
        XCTAssertEqual(out.map { CitationStyle.referenceEntry($0.entry, label: $0.label).map(\.text).joined() },
                       ["Smith, Jane. 2026a. Apple.", "Smith, Jane. 2026b. Zebra."])
    }

    /// A no-year duplicate reads "n.d.-a" in both places (never "n.d.a").
    func test_sameNameNoYear_theLetterFollowsAHyphenInBothPlaces() {
        let out = CitationStyle.disambiguated([
            entry("b", authors: ["Gartner"], year: nil, sourceTitle: "Two"),
            entry("a", authors: ["Gartner"], year: nil, sourceTitle: "One")])
        XCTAssertEqual(out.map(\.label), ["Gartner n.d.-a", "Gartner n.d.-b"])
        XCTAssertEqual(out.map { CitationStyle.referenceEntry($0.entry, label: $0.label).map(\.text).joined() },
                       ["Gartner. n.d.-a. One.", "Gartner. n.d.-b. Two."])
    }

    func test_library_walksChildren_firstDuplicateWins_andListsKeys() {
        let child = ResearchItem(id: "child", title: "Child", type: .asset,
                                 citation: CitationInfo(key: "k", year: 1))
        let dup = ResearchItem(id: "dup", title: "Dup", type: .asset,
                               citation: CitationInfo(key: "k", year: 2))
        let group = ResearchItem(id: "g", title: "G", type: .group, children: [child])
        let lib = CitationLibrary(items: [group, dup])
        XCTAssertEqual(lib.keys, ["k"])
        XCTAssertEqual(lib.entry(for: "k")?.info.year, 1)
        XCTAssertNil(lib.entry(for: "nope"))
    }
}

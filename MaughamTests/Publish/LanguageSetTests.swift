import XCTest
@testable import Maugham

/// TDD tests for `LanguageSet` — the reconciliation of legacy `language`,
/// new `languages`, and the `"source"` sentinel into an ordered body-tag
/// list plus a joined identity string.
final class LanguageSetTests: XCTestCase {

    // MARK: - both nil/empty → source-only

    func test_bothNil_yieldsSourceOnlyBody() throws {
        let set = try LanguageSet(language: nil, languages: nil, sourceTag: "en")
        XCTAssertEqual(set.bodies, [nil])
        XCTAssertTrue(set.isSourceCompile)
        XCTAssertEqual(set.translatedTags, [])
        XCTAssertNil(set.identity)
        XCTAssertNil(set.singleTag)
    }

    func test_bothEmpty_yieldsSourceOnlyBody() throws {
        let set = try LanguageSet(language: "", languages: [], sourceTag: "en")
        XCTAssertEqual(set.bodies, [nil])
        XCTAssertTrue(set.isSourceCompile)
        XCTAssertNil(set.identity)
        XCTAssertNil(set.singleTag)
    }

    // MARK: - a single translated tag

    func test_languagesSingleTag_translated() throws {
        let set = try LanguageSet(language: nil, languages: ["sr"], sourceTag: "en")
        XCTAssertEqual(set.bodies, ["sr"])
        XCTAssertFalse(set.isSourceCompile)
        XCTAssertEqual(set.translatedTags, ["sr"])
        XCTAssertEqual(set.identity, "sr")
        XCTAssertEqual(set.singleTag, "sr")
    }

    func test_legacyLanguageOnly_translated() throws {
        // The legacy single-string field, with no `languages` given at all.
        let set = try LanguageSet(language: "sr", languages: nil, sourceTag: "en")
        XCTAssertEqual(set.bodies, ["sr"])
        XCTAssertEqual(set.identity, "sr")
        XCTAssertEqual(set.singleTag, "sr")
    }

    // MARK: - source tag / "source" sentinel mapping

    func test_sourceTagInList_mapsToNilBody() throws {
        let set = try LanguageSet(language: nil, languages: ["en", "sr"], sourceTag: "en")
        XCTAssertEqual(set.bodies, [nil, "sr"])
        XCTAssertEqual(set.identity, "en+sr")
        XCTAssertTrue(set.isSourceCompile)
        XCTAssertNil(set.singleTag)
    }

    func test_sourceSentinel_mapsToNilBody_sameAsSourceTag() throws {
        let bySentinel = try LanguageSet(language: nil, languages: ["source", "sr"], sourceTag: "en")
        let byTag = try LanguageSet(language: nil, languages: ["en", "sr"], sourceTag: "en")
        XCTAssertEqual(bySentinel.bodies, [nil, "sr"])
        XCTAssertEqual(bySentinel, byTag, "\"source\" and the literal sourceTag must be equivalent spellings")
    }

    /// "source" and the literal sourceTag are the SAME body once substituted —
    /// two entries that both name it are a duplicate, not two distinct bodies.
    func test_twoSpellingsOfTheSource_areADuplicate() throws {
        XCTAssertThrowsError(
            try LanguageSet(language: nil, languages: ["source", "en"], sourceTag: "en")
        ) { error in
            guard let invalid = error as? LanguageSet.Invalid else {
                return XCTFail("expected LanguageSet.Invalid, got \(error)")
            }
            XCTAssertEqual(invalid.message, "duplicate language 'en'")
        }
    }

    /// Control: "source" beside a DIFFERENT tag is not a duplicate.
    func test_sourceSentinelBesideAnotherTag_isAccepted() throws {
        let set = try LanguageSet(language: nil, languages: ["source", "es"], sourceTag: "en")
        XCTAssertEqual(set.bodies, [nil, "es"])
    }

    // MARK: - order is preserved

    func test_orderIsPreserved() throws {
        let set = try LanguageSet(language: nil, languages: ["sr", "en"], sourceTag: "pt")
        XCTAssertEqual(set.bodies, ["sr", "en"])
        XCTAssertEqual(set.identity, "sr+en")
    }

    // MARK: - duplicates refused

    func test_duplicateTag_refused() throws {
        XCTAssertThrowsError(
            try LanguageSet(language: nil, languages: ["sr", "sr"], sourceTag: "en")
        ) { error in
            guard let invalid = error as? LanguageSet.Invalid else {
                return XCTFail("expected LanguageSet.Invalid, got \(error)")
            }
            XCTAssertEqual(invalid.message, "duplicate language 'sr'")
        }
    }

    /// Control: the same two tags, not duplicated, must be accepted.
    func test_duplicateTag_control_distinctTagsAccepted() throws {
        let set = try LanguageSet(language: nil, languages: ["sr", "es"], sourceTag: "en")
        XCTAssertEqual(set.bodies, ["sr", "es"])
    }

    // MARK: - invalid tag refused

    func test_invalidTag_refused() throws {
        XCTAssertThrowsError(
            try LanguageSet(language: nil, languages: ["xx-!"], sourceTag: "en")
        ) { error in
            guard let invalid = error as? LanguageSet.Invalid else {
                return XCTFail("expected LanguageSet.Invalid, got \(error)")
            }
            XCTAssertEqual(invalid.message, "invalid language tag 'xx-!'")
        }
    }

    /// Control: a well-formed tag with hyphenated subtags is accepted.
    func test_invalidTag_control_wellFormedTagAccepted() throws {
        let set = try LanguageSet(language: nil, languages: ["pt-br"], sourceTag: "en")
        XCTAssertEqual(set.bodies, ["pt-br"])
    }

    // MARK: - language/languages agreement

    func test_languageAndLanguagesDisagree_refused() throws {
        XCTAssertThrowsError(
            try LanguageSet(language: "sr", languages: ["es"], sourceTag: "en")
        ) { error in
            guard let invalid = error as? LanguageSet.Invalid else {
                return XCTFail("expected LanguageSet.Invalid, got \(error)")
            }
            XCTAssertEqual(invalid.message, "language 'sr' and languages [es] disagree")
        }
    }

    func test_languageAndLanguagesAgree_accepted() throws {
        let set = try LanguageSet(language: "sr", languages: ["sr"], sourceTag: "en")
        XCTAssertEqual(set.bodies, ["sr"])
        XCTAssertEqual(set.identity, "sr")
    }

    /// Control: agreement holds through the substitution mapping, not just
    /// literal string equality — "source" and the literal sourceTag name the
    /// same body.
    func test_languageAndLanguagesAgree_throughSubstitution() throws {
        let set = try LanguageSet(language: "source", languages: ["en"], sourceTag: "en")
        XCTAssertEqual(set.bodies, [nil])
        XCTAssertTrue(set.isSourceCompile)
    }
}

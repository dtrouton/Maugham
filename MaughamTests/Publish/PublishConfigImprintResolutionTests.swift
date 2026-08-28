import XCTest
@testable import Maugham

/// Task 2 — `PublishConfig.resolved(imprint:pieceIDs:)`, spec §3.
///
/// Resolution is the ONE place imprint-awareness lives: it turns
/// `(config, imprint name)` into an ordinary `PublishConfig` that every
/// downstream reader (compilers, filename builder, gate, snapshot) can
/// treat as the book's own.
final class PublishConfigImprintResolutionTests: XCTestCase {

    // MARK: - Fixtures

    private let pieceIDs = ["p1", "p2"]

    /// A book with no imprints at all.
    private func plainBook() -> PublishConfig {
        PublishConfig(
            metadata: .init(title: "The Book", subtitle: "A Book", author: "Denver"),
            outputs: .init(filenameTemplate: "{title}-v{version}.{ext}"),
            cover: .init(path: "cover.jpg"),
            sections: ["p1": .init(titleOverride: "One"), "p2": .init()],
            nextVersion: "0.3"
        )
    }

    /// The same book, plus `special` (an allowlist, a metadata patch, its own
    /// template and version counter) and `plain` (metadata only).
    private func bookWithImprints() -> PublishConfig {
        var cfg = plainBook()
        cfg.languageOverrides["fr"] = .init(metadata: ["title": "Le Livre"])
        cfg.imprints["special"] = .init(
            template: "templates/special.tex",
            sections: ["p2": .init()],
            metadata: ["title": .string("Special"), "subtitle": .null],
            nextVersion: "1.0"
        )
        cfg.imprints["plain"] = .init(
            metadata: ["title": .string("Plain")]
        )
        return cfg
    }

    // MARK: - 1. `nil` is identity

    func test_aNilNameResolvesToTheBookItself() throws {
        let config = plainBook()
        XCTAssertEqual(try config.resolved(imprint: nil, pieceIDs: pieceIDs), config)
    }

    func test_aNilNameLeavesTheImprintsThemselvesInPlace() throws {
        let config = bookWithImprints()
        XCTAssertEqual(try config.resolved(imprint: nil, pieceIDs: pieceIDs), config)
    }

    // MARK: - 2. An unknown name throws, naming what it knows

    func test_anUnknownNameThrowsNamingTheKnownImprints() throws {
        let config = bookWithImprints()
        XCTAssertThrowsError(
            try config.resolved(imprint: "nope", pieceIDs: pieceIDs)
        ) { error in
            guard let unknown = error as? PublishConfig.UnknownImprint else {
                return XCTFail("expected UnknownImprint, got \(error)")
            }
            XCTAssertEqual(unknown.requested, "nope")
            XCTAssertEqual(unknown.known, ["plain", "special"], "known names are sorted")
            XCTAssertEqual(
                unknown.errorDescription,
                "unknown imprint 'nope'; known: plain, special")
        }
    }

    func test_anUnknownNameOnAProjectWithNoImprintsSaysSo() throws {
        let config = plainBook()
        XCTAssertThrowsError(
            try config.resolved(imprint: "special", pieceIDs: pieceIDs)
        ) { error in
            guard let unknown = error as? PublishConfig.UnknownImprint else {
                return XCTFail("expected UnknownImprint, got \(error)")
            }
            XCTAssertEqual(unknown.known, [])
            XCTAssertEqual(
                unknown.errorDescription,
                "unknown imprint 'special'; this project defines no imprints")
        }
    }

    // MARK: - 4. `sections` is an allowlist, materialized

    func test_anAllowlistExcludesEveryPieceItDoesNotName() throws {
        let resolved = try bookWithImprints()
            .resolved(imprint: "special", pieceIDs: pieceIDs)
        XCTAssertEqual(resolved.excludedSectionIDs, ["p1"])
        XCTAssertEqual(resolved.sections["p2"]?.include, true)
        XCTAssertEqual(
            Set(resolved.sections.keys), ["p1", "p2"],
            "every piece is spoken for, so the excluded set is complete")
    }

    func test_anAllowlistEntryIsIncludedEvenWhenItSaysOtherwise() throws {
        var config = bookWithImprints()
        config.imprints["special"]?.sections = ["p2": .init(include: false)]
        let resolved = try config.resolved(imprint: "special", pieceIDs: pieceIDs)
        XCTAssertEqual(
            resolved.sections["p2"]?.include, true,
            "naming a piece in the allowlist IS the inclusion")
    }

    func test_anAllowlistEntryKeepsItsOtherFields() throws {
        var config = bookWithImprints()
        config.imprints["special"]?.sections = [
            "p2": .init(titleOverride: "Two, specially", startOn: .recto)
        ]
        let resolved = try config.resolved(imprint: "special", pieceIDs: pieceIDs)
        XCTAssertEqual(resolved.sections["p2"]?.titleOverride, "Two, specially")
        XCTAssertEqual(resolved.sections["p2"]?.startOn, .recto)
    }

    func test_anAbsentAllowlistInheritsTheBooksOwnSections() throws {
        let config = bookWithImprints()
        let resolved = try config.resolved(imprint: "plain", pieceIDs: pieceIDs)
        XCTAssertEqual(resolved.sections, config.sections)
        XCTAssertEqual(resolved.excludedSectionIDs, [])
    }

    // MARK: - 5. `metadata` / `outputs` / `cover` deep-merge

    func test_metadataMergesReplacingDeletingAndInheriting() throws {
        let resolved = try bookWithImprints()
            .resolved(imprint: "special", pieceIDs: pieceIDs)
        XCTAssertEqual(resolved.metadata.title, "Special", "replaced")
        XCTAssertNil(resolved.metadata.subtitle, "null deletes")
        XCTAssertEqual(resolved.metadata.author, "Denver", "untouched keys inherit")
    }

    func test_outputsAreInheritedWholeWhenTheImprintNamesNone() throws {
        let resolved = try bookWithImprints()
            .resolved(imprint: "special", pieceIDs: pieceIDs)
        XCTAssertEqual(resolved.outputs.filenameTemplate, "{title}-v{version}.{ext}")
        XCTAssertEqual(resolved.outputs, plainBook().outputs)
    }

    func test_outputsMergeKeyByKeyWhenTheImprintNamesSome() throws {
        var config = bookWithImprints()
        config.imprints["special"]?.outputs = ["directory": .string("Exports/Special")]
        let resolved = try config.resolved(imprint: "special", pieceIDs: pieceIDs)
        XCTAssertEqual(resolved.outputs.directory, "Exports/Special")
        XCTAssertEqual(
            resolved.outputs.filenameTemplate, "{title}-v{version}.{ext}",
            "the keys the fragment does not name survive")
        XCTAssertEqual(resolved.outputs.formatsEnabled, [.pdf, .epub])
    }

    func test_coverIsReplacedOrDeletedByItsFragment() throws {
        var config = bookWithImprints()
        config.imprints["special"]?.cover = ["path": .string("special-cover.jpg")]
        XCTAssertEqual(
            try config.resolved(imprint: "special", pieceIDs: pieceIDs).cover.path,
            "special-cover.jpg")

        config.imprints["special"]?.cover = ["path": .null]
        XCTAssertNil(
            try config.resolved(imprint: "special", pieceIDs: pieceIDs).cover.path,
            "null deletes the cover as it deletes a subtitle")
    }

    func test_deletingARequiredFieldThrowsNamingIt() throws {
        var config = bookWithImprints()
        config.imprints["special"]?.metadata = ["title": .null]
        XCTAssertThrowsError(
            try config.resolved(imprint: "special", pieceIDs: pieceIDs)
        ) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(
                text.contains("title"), "the error names the field: \(text)")
            XCTAssertTrue(
                text.contains("special"), "and the imprint: \(text)")
        }
    }

    // MARK: - 6. `nextVersion`

    func test_theImprintsVersionCounterReplacesTheBooks() throws {
        let resolved = try bookWithImprints()
            .resolved(imprint: "special", pieceIDs: pieceIDs)
        XCTAssertEqual(resolved.nextVersion, "1.0")
    }

    func test_anImprintWithNoCounterInheritsTheBooks() throws {
        let resolved = try bookWithImprints()
            .resolved(imprint: "plain", pieceIDs: pieceIDs)
        XCTAssertEqual(resolved.nextVersion, "0.3")
    }

    // MARK: - 3 + 7. Identity of the resolved config

    func test_theResultCarriesItsNameAndTemplate() throws {
        let resolved = try bookWithImprints()
            .resolved(imprint: "special", pieceIDs: pieceIDs)
        XCTAssertEqual(resolved.imprint, "special")
        XCTAssertEqual(resolved.template, "templates/special.tex")
    }

    func test_anImprintWithNoTemplateKeepsTheBooks() throws {
        let resolved = try bookWithImprints()
            .resolved(imprint: "plain", pieceIDs: pieceIDs)
        XCTAssertEqual(resolved.template, "template.tex")
        XCTAssertEqual(resolved.imprint, "plain")
    }

    func test_theResultStillCarriesTheImprintsSoASnapshotDecodes() throws {
        let config = bookWithImprints()
        let resolved = try config.resolved(imprint: "special", pieceIDs: pieceIDs)
        XCTAssertEqual(resolved.imprints, config.imprints)

        let data = try JSONEncoder().encode(resolved)
        let decoded = try JSONDecoder().decode(PublishConfig.self, from: data)
        XCTAssertEqual(decoded, resolved, "a snapshot of a resolved config round-trips")
    }

    // MARK: - 8. `languageOverrides` are somebody else's job

    func test_languageOverridesAreUntouched() throws {
        let config = bookWithImprints()
        let resolved = try config.resolved(imprint: "special", pieceIDs: pieceIDs)
        XCTAssertEqual(resolved.languageOverrides, config.languageOverrides)
    }
}

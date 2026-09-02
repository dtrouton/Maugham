import XCTest
@testable import MaughamCore

/// The shared half of the statement seam (M1A Task 3): a pure lookup by
/// `(kind, scope)` and the one spelling of the §2.2 storage table. Both surfaces
/// call these — the Mac wraps them with creation, the phone reads them (tripwire
/// 19).
final class StatementLookupTests: XCTestCase {

    private func statement(
        _ id: String, _ kind: Statement.Kind, _ scope: Statement.Scope, _ path: String
    ) -> Statement {
        Statement(id: id, kind: kind, scope: scope, path: path)
    }

    // MARK: - Lookup

    func test_bothKindAndScopeDiscriminate() {
        let statements = [
            statement("s-a", .intent, .project, "intent.md"),
            statement("s-b", .visualLanguage, .project, "visual-language.md"),
            statement("s-c", .intent, .document("doc-9"), "intent/chapter-nine.md"),
        ]

        XCTAssertEqual(
            StatementLookup.statement(in: statements, kind: .intent, scope: .project)?.id, "s-a")
        XCTAssertEqual(
            StatementLookup.statement(in: statements, kind: .visualLanguage, scope: .project)?.id,
            "s-b", "same scope, different kind — kind must discriminate")
        XCTAssertEqual(
            StatementLookup.statement(in: statements, kind: .intent, scope: .document("doc-9"))?.id,
            "s-c", "same kind, different scope — scope must discriminate")
        XCTAssertNil(
            StatementLookup.statement(in: statements, kind: .intent, scope: .document("doc-1")),
            "a scope with no statement is nil, not the project's")
    }

    func test_anEmptyRegistryIsNil() {
        XCTAssertNil(StatementLookup.statement(in: [], kind: .intent, scope: .project))
    }

    // MARK: - The storage table (spec §2.2)

    func test_theTableMintsOnePathPerRow() {
        XCTAssertEqual(
            StatementConvention.newPath(kind: .intent, scope: .project, documentSlug: nil),
            "intent.md")
        XCTAssertEqual(
            StatementConvention.newPath(
                kind: .intent, scope: .document("doc-9"), documentSlug: "chapter-nine"),
            "intent/chapter-nine.md")
        XCTAssertEqual(
            StatementConvention.newPath(kind: .visualLanguage, scope: .project, documentSlug: nil),
            "visual-language.md")
    }

    func test_offTheTableThereIsNoPath() {
        XCTAssertNil(
            StatementConvention.newPath(
                kind: .visualLanguage, scope: .document("doc-9"), documentSlug: "chapter-nine"),
            "visual language is project-scope only — there is no per-document row")
        XCTAssertNil(
            StatementConvention.newPath(
                kind: .unknown("manifesto"), scope: .project, documentSlug: nil),
            "a kind written by a newer build has no path this build can mint")
        XCTAssertNil(
            StatementConvention.newPath(
                kind: .intent, scope: .unknown("series:s-9"), documentSlug: nil),
            "a scope written by a newer build has no path this build can mint")
        XCTAssertNil(
            StatementConvention.newPath(
                kind: .intent, scope: .document("doc-9"), documentSlug: nil),
            "a document scope with no slug cannot name a file")
    }

    func test_editionBriefMintsTheRowForProjectScope() {
        XCTAssertEqual(
            StatementConvention.newPath(
                kind: .editionBrief("es"), scope: .project, documentSlug: nil),
            "editions/es.md")
    }

    func test_editionBriefHasNoPathForDocumentScope() {
        XCTAssertNil(
            StatementConvention.newPath(
                kind: .editionBrief("fr"), scope: .document("doc-9"), documentSlug: "chapter-nine"),
            "edition briefs are project-scope only — there is no per-document row")
    }

    func test_editionBriefWithEmptyLanguageReturnsNil() {
        XCTAssertNil(
            StatementConvention.newPath(
                kind: .editionBrief(""), scope: .project, documentSlug: nil),
            "an empty language tag has no valid path — match the empty-slug guard")
    }

    func test_twoEditionBriefsWithDifferentLanguagesDiscriminate() {
        let statements = [
            statement("s-a", .editionBrief("es"), .project, "editions/es.md"),
            statement("s-b", .editionBrief("fr"), .project, "editions/fr.md"),
        ]

        XCTAssertEqual(
            StatementLookup.statement(in: statements, kind: .editionBrief("es"), scope: .project)?.id,
            "s-a")
        XCTAssertEqual(
            StatementLookup.statement(in: statements, kind: .editionBrief("fr"), scope: .project)?.id,
            "s-b",
            "different language tags must discriminate — kind equality already does this")
    }

    // MARK: - The lessons row (editorial letter P2, Task 1)

    /// The ledger is one per project: what the writer has learned about their
    /// own writing is not a per-chapter fact.
    func test_lessonsMintsTheRowForProjectScope() {
        XCTAssertEqual(
            StatementConvention.newPath(kind: .lessons, scope: .project, documentSlug: nil),
            "lessons.md")
    }

    /// CONTROL for the row above: document scope has no row, with or without a
    /// slug, so the store throws `.statementHasNoStorage` rather than minting a
    /// second ledger under `lessons/`.
    func test_lessonsHasNoPathForDocumentScope() {
        XCTAssertNil(
            StatementConvention.newPath(
                kind: .lessons, scope: .document("doc-9"), documentSlug: "chapter-nine"),
            "the lessons ledger is project-scope only — there is no per-document row")
        XCTAssertNil(
            StatementConvention.newPath(
                kind: .lessons, scope: .document("doc-9"), documentSlug: nil),
            "and a missing slug does not make one appear either")
    }
}

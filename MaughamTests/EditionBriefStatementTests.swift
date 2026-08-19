import XCTest
@testable import Maugham
import MaughamCore

/// The publish department, Task 5: proving the edition brief — a THIRD
/// `Statement.Kind` (`.editionBrief(String)`, Tasks 1–2) — rides the existing
/// statement machinery end to end with no new store code. `createStatement`
/// walks `StatementConvention.newPath`'s `(.editionBrief(lang), .project)` row
/// straight to `editions/<lang>.md`; the only thing this kind needed that
/// didn't already exist is its writer-facing name in `ArtifactIndex.kindTitle`.
@MainActor
final class EditionBriefStatementTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// A loaded novel project with its async load work settled, so a test that
    /// asserts "nothing was written twice" isn't racing `load`'s own tail.
    private func loadedNovel(named name: String) async throws -> (URL, ProjectStore) {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return (url, store)
    }

    // MARK: - (a) creation, path, find-or-create

    func test_creatingAnEditionBriefMintsAtEditionsSlashLangDotMd() async throws {
        let (url, store) = try await loadedNovel(named: "EditionBriefCreate")

        let first = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        XCTAssertEqual(first.path, "editions/es.md")
        XCTAssertEqual(first.kind, .editionBrief("es"))
        XCTAssertEqual(first.scope, .project)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("editions/es.md").path))
        XCTAssertEqual(store.manifest.statements.map(\.id), [first.id],
                       "the brief must register in the manifest, same as any other statement")

        let second = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        XCTAssertEqual(second.id, first.id, "find-or-create must find before it creates")
        XCTAssertEqual(second.path, first.path)
        XCTAssertEqual(store.manifest.statements.count, 1,
                       "a second call must not register a second statement")
    }

    /// A different language is a different statement, not a second copy of the
    /// same one — the lang tag is part of the kind's identity.
    func test_twoLanguagesAreTwoDistinctBriefs() async throws {
        let (_, store) = try await loadedNovel(named: "EditionBriefTwoLanguages")

        let es = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        let fr = try await store.createStatement(kind: .editionBrief("fr"), scope: .project)

        XCTAssertNotEqual(es.id, fr.id)
        XCTAssertEqual(es.path, "editions/es.md")
        XCTAssertEqual(fr.path, "editions/fr.md")
        XCTAssertEqual(store.manifest.statements.count, 2)
    }

    // MARK: - (b) statementText on a fresh brief

    func test_statementTextOnAFreshBriefAnswersEmptyWithoutThrowing() async throws {
        let (_, store) = try await loadedNovel(named: "EditionBriefEmptyText")

        let brief = try await store.createStatement(kind: .editionBrief("es"), scope: .project)

        XCTAssertEqual(try store.statementText(of: brief), "",
                       "a fresh mint has no words yet, and reading it must not throw")
    }

    /// The other half of (b): words written through the shared append path come
    /// back out again — the same round trip every other statement kind gets.
    func test_statementTextReflectsWhatWasAppended() async throws {
        let (_, store) = try await loadedNovel(named: "EditionBriefAppendedText")

        let brief = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        try await store.appendToStatement(
            "For the Spanish edition, keep October's doctor female.",
            to: brief, session: "test-\(UUID().uuidString)")

        XCTAssertEqual(try store.statementText(of: brief),
                       "For the Spanish edition, keep October's doctor female.")
    }

    // MARK: - (c) kindTitle

    func test_kindTitleSpellsEditionBriefWithTheLanguageTag() {
        XCTAssertEqual(ArtifactIndex.kindTitle(.editionBrief("es")), "Edition Brief · es")
        XCTAssertEqual(ArtifactIndex.kindTitle(.editionBrief("fr")), "Edition Brief · fr",
                       "the language tag is not hardcoded to one language")
    }

    // MARK: - (d) statementTitlePairs

    func test_statementTitlePairsIncludesTheBriefUnderItsTitle() async throws {
        let (_, store) = try await loadedNovel(named: "EditionBriefTitlePairs")

        let brief = try await store.createStatement(kind: .editionBrief("es"), scope: .project)

        let pairs = store.statementTitlePairs()
        XCTAssertTrue(pairs.contains { $0.id == brief.id && $0.title == "Edition Brief · es" },
                     "expected (\(brief.id), \"Edition Brief · es\") among \(pairs)")
    }
}

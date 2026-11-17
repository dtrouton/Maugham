import XCTest
import MaughamCore
@testable import Maugham

/// **The Editions rows** (shell p1 Task 3): one per language, the source
/// first, and none until publishing is initialised or a translation exists.
@MainActor
final class TreeEditionRowsTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        temp.cleanup()
        temp = nil
    }

    // MARK: - The fold

    func test_theSourceLanguageIsTheFirstEdition() async throws {
        XCTAssertEqual(
            TreeEditionRows.languages(source: "en", publishingInitialised: false,
                                      translated: ["es", "sr"]),
            ["en", "es", "sr"])
        XCTAssertEqual(
            TreeEditionRows.languages(source: "en", publishingInitialised: true,
                                      translated: ["EN", "es"]),
            ["en", "es"], "the source is never listed twice")

        // Over a real book: a translator named is a translation, and the
        // source — the config's own tag, `en` with no config — leads.
        let store = try await novel()
        _ = try await store.translatorRole(for: "sr")
        XCTAssertEqual(TreeEditionRows.languages(store: store), ["en", "sr"])
        let rows = TreeEditionRows.rows(store: store)
        XCTAssertEqual(rows.map(\.language), ["en", "sr"])
        XCTAssertEqual(rows.map(\.isSource), [true, false])
    }

    func test_noEditionsRowsBeforePublishingOrATranslationExists() async throws {
        XCTAssertEqual(
            TreeEditionRows.languages(source: "en", publishingInitialised: false,
                                      translated: []), [])
        XCTAssertEqual(
            TreeEditionRows.languages(source: "en", publishingInitialised: true,
                                      translated: []), ["en"],
            "publishing initialised: the source edition alone")
        let store = try await novel()
        XCTAssertTrue(PublishStarter.isInitialized(in: store.url),
                      "premise: a new project starts with publishing initialised")
        XCTAssertEqual(TreeEditionRows.languages(store: store), ["en"],
                       "publishing initialised: the source edition alone")
        // Take publishing away: no translation either, so no Editions rows.
        try FileManager.default.removeItem(
            at: store.url.appendingPathComponent(".maugham/publish"))
        XCTAssertFalse(PublishStarter.isInitialized(in: store.url))
        XCTAssertEqual(TreeEditionRows.languages(store: store), [],
                       "neither publishing nor a translation: no edition to list")
        _ = try await store.translatorRole(for: "sr")
        XCTAssertEqual(TreeEditionRows.languages(store: store), ["en", "sr"],
                       "a translation alone is enough, and the source still leads")
        XCTAssertEqual(TreeRowSlot.order(hasInbox: false, showsFigures: false,
                                         showsEditions: false).contains(.editions), false)
    }

    // MARK: - Validation accepts what the tree lists

    /// **The source language is an edition** (controller ruling 3): a window
    /// restored onto it stays there, and a language the tree does not list
    /// falls back to the Book.
    func test_theSourceEditionSurvivesTheRepairAndAGoneLanguageDoesNot() async throws {
        let store = try await novel()
        _ = try await store.translatorRole(for: "sr")
        for language in ["en", "sr"] {
            let subject = SubjectSamples.opened(.edition(language: language))
            XCTAssertEqual(ProjectWindow.validatedSubject(subject, in: store), subject,
                           "\(language) is one of the tree's editions")
        }
        XCTAssertEqual(
            ProjectWindow.validatedSubject(SubjectSamples.opened(.edition(language: "fr")),
                                           in: store),
            .book, "a language with no edition left falls back to the Book")
    }

    // MARK: - Fixtures

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Editions-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }
}

import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// **What Publish's desk draws** (publish-department P4 Task 1) — the seat it
/// takes in the right column is `PersonaPaneRegistryTests`'; this file is about
/// the pane itself: its two sections and what a language row says. The Design
/// row and every verb on the desk are `DepartmentRunTests`'.
///
/// **Nothing here needs a project on disk**, which is the point rather than a
/// convenience. `DepartmentPane` takes a title, a language list and a resolved
/// design row — no `ProjectStore`, no `DocumentStore` — so the whole surface is
/// drivable from literals, exactly as `ReviewBoardPane` is one persona over.
/// That is tripwire 4 satisfied by construction, and
/// `test_theSourceReadsNoStoreAtAll` is the census that keeps it so: the
/// derivations the values come from (a walk of every document's translation
/// store, a read of the staged proposals) are the host's, and a `body` that
/// could reach either would run it once per row.
///
/// **The desk has no empty state to test any more** (Task 4). Task 1's
/// `ContentUnavailableView` was honest while nothing on the pane could act; the
/// Design row's Run retired it, because every project has a designer and asking
/// for a first design round is exactly what a writer with an empty department
/// came here to do. What replaced those tests is
/// `DepartmentRunTests.test_aProjectWithNothingInItStillOffersADesignRound`.
@MainActor
final class DepartmentPaneTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // The parallel-worker fontd cold-start window (CLAUDE.md): this suite
        // mounts real text through production typography.
        FontWarmup.ensure()
    }

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
    }

    // MARK: - A row's own words (Task 2, no window)

    /// **A language with no name to print says so rather than printing nothing.**
    /// `translatorName` answers nil for an unlisted, unminted language — the
    /// honest answer for the MCP field, which omits it — and a desk row with a
    /// blank where a person's name goes reads as a bug rather than as a person
    /// the writer has not named yet.
    func test_aRowWithNoTranslatorSaysSoRatherThanPrintingABlank() {
        XCTAssertEqual(DepartmentDesk.translatorLine("Cortázar"), "Cortázar")
        XCTAssertEqual(DepartmentDesk.translatorLine(nil),
                       DepartmentDesk.noTranslatorYet)
        XCTAssertFalse(DepartmentDesk.noTranslatorYet.isEmpty)
    }

    /// The coverage line is the three figures `translation_status` reports, in
    /// its own vocabulary — and a language nobody has translated a paragraph of
    /// says *that* rather than "0 fresh · 0 stale · 0 missing", which is what a
    /// query-first language's zeroes would otherwise read as.
    func test_theCoverageLineCarriesTheThreeFigures() {
        XCTAssertEqual(DepartmentDesk.coverageLine(fresh: 12, stale: 3, missing: 1),
                       "12 fresh · 3 stale · 1 missing")
        XCTAssertEqual(DepartmentDesk.coverageLine(fresh: 0, stale: 0, missing: 0),
                       DepartmentDesk.notStarted)
        XCTAssertEqual(DepartmentDesk.coverageLine(fresh: 0, stale: 0, missing: 4),
                       "0 fresh · 0 stale · 4 missing")
    }

    /// Open queries are what the writer OWES somebody, so the row says it only
    /// when there is a debt — and counts in a singular where there is one.
    func test_theQueryLineAppearsOnlyWhereThereIsSomethingToAnswer() {
        XCTAssertNil(DepartmentDesk.queryLine(openQueries: 0),
                     "nothing owed, nothing said")
        XCTAssertEqual(DepartmentDesk.queryLine(openQueries: 1), "1 open query")
        XCTAssertEqual(DepartmentDesk.queryLine(openQueries: 5), "5 open queries")
    }

    // MARK: - The rows are translation_status's own numbers (Task 2)

    /// **The desk and the tool cannot disagree, because there is one
    /// derivation.** The pane's rows are `EditionStatus`, and so are
    /// `translation_status`'s — the union of file languages and open-query
    /// languages, the same freshness derivation, the same open-query filter
    /// (`.query` AND language-tagged `.craftNote`, the P2 widening). This drives
    /// both over one fixture and asserts the desk's per-language totals are the
    /// tool's rows summed.
    ///
    /// The disable experiment: give the pane a union of its own — file languages
    /// alone, say — and the `fr` row (query-first, no file) disappears here while
    /// the tool goes on reporting it.
    func test_theDesksRowsAreTranslationStatusOwnNumbers() async throws {
        let h = try await makeProject()
        let ids1 = h.doc1.sequence
        // es across both documents, one paragraph of doc-1 left untranslated.
        try await seed(h, doc: h.doc1, paragraphId: ids1[0], language: "es", text: "uno")
        try await seed(h, doc: h.doc2, paragraphId: h.doc2.sequence[0],
                       language: "es", text: "dos")
        // fr exists ONLY as an open question — the query-first workflow.
        try await addQuery(h, doc: h.doc1, paragraphId: ids1[0],
                           body: "tu or vous?", language: "fr")
        // …and es has one anchored query plus one whole-document craft note.
        try await addQuery(h, doc: h.doc1, paragraphId: ids1[1],
                           body: "idiom or literal?", language: "es")
        _ = try await h.doc1.addAnnotation(
            kind: .craftNote, paragraphId: nil,
            body: "Translation query (es) — tú or usted throughout?",
            toolArgs: #"{"language":"es","role_id":"role-es"}"#)

        let desk = await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL).rows
        let tool = try await self.toolRows(h)

        XCTAssertEqual(desk.map(\.language), ["es", "fr"],
                       "one row per language the book has an edition in, sorted")
        for row in desk {
            let mine = tool.filter { $0.language == row.language }
            XCTAssertFalse(mine.isEmpty)
            XCTAssertEqual(row.fresh, mine.reduce(0) { $0 + $1.fresh },
                           "\(row.language) fresh")
            XCTAssertEqual(row.stale, mine.reduce(0) { $0 + $1.stale },
                           "\(row.language) stale")
            XCTAssertEqual(row.missing, mine.reduce(0) { $0 + $1.missing },
                           "\(row.language) missing")
            XCTAssertEqual(row.openQueries, mine.reduce(0) { $0 + $1.open_queries },
                           "\(row.language) open queries")
            XCTAssertEqual(row.translator, mine.first?.translator,
                           "\(row.language) translator")
        }
        // Spelled out, so a derivation that agreed with a BROKEN tool would
        // still fail here.
        let es = try XCTUnwrap(desk.first { $0.language == "es" })
        XCTAssertEqual(es.fresh, 2, "one paragraph in each document")
        XCTAssertEqual(es.missing, 1, "doc-1's second paragraph")
        XCTAssertEqual(es.openQueries, 2, "the anchored one and the whole-document one")
        let fr = try XCTUnwrap(desk.first { $0.language == "fr" })
        XCTAssertEqual(fr.openQueries, 1)
        XCTAssertEqual(fr.fresh + fr.stale + fr.missing, 0,
                       "no file yet — coverage is absent, not 'all missing'")

        await h.documentStore.close()
    }

    // MARK: - …and they degrade alike (issue #43, F-D)

    /// **One derivation means one DEGRADE.** With chapter 2's history file
    /// present and unreadable, the desk and `translation_status` name the same
    /// chapter with the same reason, and both still report chapter 1's Spanish
    /// coverage. A desk that degraded on its own — or a tool that went on
    /// throwing — would be the disagreement `EditionStatus` exists to prevent,
    /// arriving through the failure path instead of the happy one.
    ///
    /// The control is `test_theDesksRowsAreTranslationStatusOwnNumbers` above:
    /// the same fixture with nothing broken, where both name nothing.
    func test_theDeskAndTheToolNameTheSameUnreadableChapter() async throws {
        let h = try await makeProject()
        try await seed(h, doc: h.doc1, paragraphId: h.doc1.sequence[0],
                       language: "es", text: "uno")
        try await seed(h, doc: h.doc2, paragraphId: h.doc2.sequence[0],
                       language: "es", text: "dos")
        try await breakChapterTwo(h)

        let desk = await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL)
        let tool = try await toolResult(h)

        XCTAssertEqual(desk.unreadable.map(\.documentId), ["doc-2"])
        XCTAssertEqual(tool.unreadable_documents.map(\.document_id),
                       desk.unreadable.map(\.documentId),
                       "the desk names \(desk.unreadable.map(\.documentId)) and the "
                       + "tool names \(tool.unreadable_documents.map(\.document_id)) "
                       + "\u{2014} two answers to one question")
        XCTAssertEqual(tool.unreadable_documents.first?.title,
                       desk.unreadable.first?.title)
        XCTAssertEqual(tool.unreadable_documents.first?.reason,
                       desk.unreadable.first?.reason)
        XCTAssertEqual(desk.unreadable.first?.title, "Chapter 2")
        XCTAssertFalse(desk.unreadable.first?.reason.isEmpty ?? true)

        XCTAssertEqual(desk.rows.map(\.language), ["es"],
                       "the readable chapter's edition is still on the desk")
        XCTAssertEqual(desk.rows.first?.fresh, 1, "chapter 1's own paragraph")
        XCTAssertEqual(tool.rows.map(\.document_id), ["doc-1"],
                       "and the tool reports no rows for the chapter it skipped")

        await h.documentStore.close()
    }

    /// **Looking at the desk must not mint a translator** (the read rule in
    /// `ProjectStore+ProductionRoles.swift`, which names "a desk row"
    /// explicitly). The preset name is printed; the manifest is not touched, on
    /// disk or in memory.
    ///
    /// Disable experiment: route the name through
    /// `ProjectStore.translatorRole(for:)` — find-or-create — and the byte
    /// comparison fails.
    func test_anUnmintedLanguageShowsThePresetAndLeavesTheManifestAlone() async throws {
        let h = try await makeProject()
        try await seed(h, doc: h.doc1, paragraphId: h.doc1.sequence[0],
                       language: "es", text: "uno")

        let manifestURL = h.projectURL.appendingPathComponent("project.maugham.json")
        let before = try Data(contentsOf: manifestURL)

        let rows = await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL).rows

        XCTAssertEqual(rows.first { $0.language == "es" }?.translator, "Cortázar")
        XCTAssertEqual(try Data(contentsOf: manifestURL), before,
                       "a desk row must not mint a production role")
        XCTAssertTrue(h.projectStore.manifest.productionRoles.isEmpty,
                      "…and the in-memory manifest is untouched too")

        await h.documentStore.close()
    }

    /// A stored rename wins over the preset — `effectiveName`, resolved in the
    /// one place that resolves it.
    func test_aStoredRenameIsWhatTheRowPrints() async throws {
        let h = try await makeProject()
        try await seed(h, doc: h.doc1, paragraphId: h.doc1.sequence[0],
                       language: "es", text: "uno")
        let minted = try await h.projectStore.translatorRole(for: "es")
        try await h.projectStore.renameProductionRole(id: minted.id, to: "Alejandra")

        let rows = await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL).rows
        XCTAssertEqual(rows.first { $0.language == "es" }?.translator, "Alejandra")

        await h.documentStore.close()
    }

    // MARK: - A named translator anchors an edition (cast-management)

    /// **A stored translator is enough to put an edition on the desk** — the
    /// union's third source, and the whole of what makes *Add Language* land
    /// somewhere. No translation file, no query: just somebody named.
    ///
    /// The disable experiment: drop `roles` from `EditionStatus.editionLanguages`
    /// and this row vanishes while the manifest goes on carrying the person the
    /// writer named.
    func test_aNamedTranslatorAloneGivesTheEditionARowOnTheDesk() async throws {
        let h = try await makeProject()
        let minted = try await h.projectStore.translatorRole(for: "pt-br")
        try await h.projectStore.renameProductionRole(id: minted.id, to: "Ana")

        let rows = await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL).rows

        let row = try XCTUnwrap(rows.first { $0.language == "pt-br" },
                                "naming a translator started an edition the desk "
                                + "cannot see. Rows: \(rows.map(\.language))")
        XCTAssertEqual(row.translator, "Ana")
        XCTAssertEqual(
            DepartmentDesk.coverageLine(fresh: row.fresh, stale: row.stale,
                                        missing: row.missing),
            DepartmentDesk.notStarted,
            "nothing is translated yet, which is 'Not started' — the query-first "
            + "arm's own answer, not 'every paragraph missing'")
        XCTAssertEqual(row.openQueries, 0)

        await h.documentStore.close()
    }

    /// **One edition spelled two ways is still one row.** `storedTranslator(for:)`
    /// reads `ES` and `es` as one person's language, so a manifest that spells a
    /// tag one way and a translation file that spells it the other must not draw
    /// the writer two rows for the same Spanish edition.
    func test_anEditionSpelledTwoWaysIsStillOneRow() async throws {
        let h = try await makeProject()
        try await seed(h, doc: h.doc1, paragraphId: h.doc1.sequence[0],
                       language: "es", text: "uno")
        _ = try await h.projectStore.translatorRole(for: "ES")

        let rows = await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL).rows

        XCTAssertEqual(rows.map(\.language), ["es"],
                       "one Spanish edition, however its tag is capitalised, and "
                       + "spelled the way the write pipeline spells one")
        XCTAssertEqual(rows[0].fresh, 1, "…and it keeps the file's own coverage")

        await h.documentStore.close()
    }

    /// **A book with no chapters yet still shows the edition it named.** The
    /// per-document walk has nothing to walk in an empty manuscript, so without
    /// the manifest arm of the fold, Add Language on a fresh project would write
    /// a translator to disk and change nothing on screen.
    ///
    /// Driven through the pure fold rather than a fixture, because "no documents
    /// at all" is precisely the state a project on disk here would not be in.
    func test_aBookWithNoChaptersStillShowsTheEditionItNamed() {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [],
            productionRoles: [ProductionRole(
                id: "role-1", role: .translator(language: "pt-br"), name: "Ana")])

        let rows = EditionStatus.languageRows(from: [], in: manifest)

        XCTAssertEqual(rows.map(\.language), ["pt-br"])
        XCTAssertEqual(rows.first?.translator, "Ana")
    }

    /// The union itself, as a truth table: files and queries as before, a role
    /// joining only when nothing already present matches it case-insensitively.
    func test_theUnionTakesFilesQueriesAndRolesAndFoldsTheirCase() {
        XCTAssertEqual(
            EditionStatus.editionLanguages(files: ["es"], queries: ["fr"],
                                           roles: ["pt-br"]),
            ["es", "fr", "pt-br"])
        XCTAssertEqual(
            EditionStatus.editionLanguages(files: ["es"], queries: [], roles: ["ES"]),
            ["es"], "one edition, one row")
        XCTAssertEqual(
            EditionStatus.editionLanguages(files: [], queries: [], roles: []),
            [], "a document with nothing to say about any edition says nothing")
    }

    /// A designer is not an edition, and neither is a role written by a newer
    /// build — only `.translator` rows anchor a language.
    func test_onlyATranslatorRoleAnchorsAnEdition() {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [],
            productionRoles: [
                ProductionRole(id: "designer", role: .designer, name: "Tschichold"),
                ProductionRole(id: "role-x", role: .unknown("proofreader"), name: "P"),
                ProductionRole(id: "role-1", role: .translator(language: "de")),
            ])

        XCTAssertEqual(
            EditionStatus.storedTranslatorLanguages(in: manifest), ["de"])
    }

    /// A tag stored in whatever case the writer typed reaches the union in the
    /// one case every other reader of a language tag uses — the write pipeline's
    /// own `isValidLanguageTag` accepts nothing else.
    func test_aStoredTagReachesTheUnionLowercased() {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [],
            productionRoles: [ProductionRole(
                id: "role-1", role: .translator(language: "PT-BR"))])

        XCTAssertEqual(
            EditionStatus.storedTranslatorLanguages(in: manifest), ["pt-br"])
    }

    // MARK: - Add Language's dedupe is a union (issue #43, F-G)

    /// A row the desk has already drawn is a home, with or without a stored
    /// role behind it.
    func test_languageAlreadyOnTheDesk_derivedRowAlone_isTrue() {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [])
        let derived = [EditionStatus.LanguageRow(
            language: "es", translator: nil, fresh: 1, stale: 0, missing: 0,
            openQueries: 0)]

        XCTAssertTrue(DepartmentPaneHost.languageAlreadyOnTheDesk(
            "es", derived: derived, manifest: manifest))
    }

    /// A translator the manifest already stores is a home even when `derive()`
    /// has not caught up with a row for it yet — the exact staleness window
    /// that let Confirm's name silently rename somebody (issue #43, F-G).
    func test_languageAlreadyOnTheDesk_manifestAlone_isTrue() {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [],
            productionRoles: [ProductionRole(
                id: "role-1", role: .translator(language: "es"), name: "Cortázar")])

        XCTAssertTrue(DepartmentPaneHost.languageAlreadyOnTheDesk(
            "es", derived: [], manifest: manifest))
    }

    /// Neither side knows the language — it is genuinely new, and Add Language
    /// must be free to mint it.
    func test_languageAlreadyOnTheDesk_neither_isFalse() {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [])

        XCTAssertFalse(DepartmentPaneHost.languageAlreadyOnTheDesk(
            "es", derived: [], manifest: manifest))
    }

    /// The match is case-insensitive on both sides, matching
    /// `storedTranslator(for:)`.
    func test_languageAlreadyOnTheDesk_caseInsensitive_isTrue() {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [],
            productionRoles: [ProductionRole(
                id: "role-1", role: .translator(language: "es"), name: "Cortázar")])

        XCTAssertTrue(DepartmentPaneHost.languageAlreadyOnTheDesk(
            "ES", derived: [], manifest: manifest))
    }

    /// An unlisted, unminted language has nobody to name, and the row says so
    /// in words rather than leaving the line blank.
    func test_anUnlistedLanguageHasNobodyToName() async throws {
        let h = try await makeProject()
        try await seed(h, doc: h.doc1, paragraphId: h.doc1.sequence[0],
                       language: "xx", text: "uno")

        let rows = await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL).rows
        let xx = try XCTUnwrap(rows.first { $0.language == "xx" })
        XCTAssertNil(xx.translator, "no preset, nothing stored — nothing honest")
        XCTAssertEqual(DepartmentDesk.translatorLine(xx.translator),
                       DepartmentDesk.noTranslatorYet)

        await h.documentStore.close()
    }

    // MARK: - The brief's door (Task 2)

    /// **The door mints the file the writer is about to write in, and mints it
    /// once.** `createStatement` is find-or-create, so a second click finds what
    /// the first made — same id, one manifest row, one file. A door that minted
    /// per click would leave `edition-brief-es-2.md` beside the writer's own
    /// (`vacantStatementPath` steers around an occupied path), and the second
    /// visit would open the empty one.
    func test_theBriefsDoorCreatesOnceAndFindsItThereafter() async throws {
        let h = try await makeProject()

        let opened = await DepartmentPaneHost.openBrief(language: "es", in: h.projectStore)
        let reopened = await DepartmentPaneHost.openBrief(language: "es", in: h.projectStore)
        let first = try XCTUnwrap(opened)
        let second = try XCTUnwrap(reopened)

        XCTAssertEqual(first.language, "es")
        XCTAssertEqual(second.statementID, first.statementID,
                       "the second click found what the first made")
        let briefs = h.projectStore.manifest.statements.filter {
            $0.kind == .editionBrief("es") && $0.scope == .project
        }
        XCTAssertEqual(briefs.count, 1, "one brief per edition, ever")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: h.projectURL.appendingPathComponent(briefs[0].path).path),
            "the door leaves a file to write in")

        await h.documentStore.close()
    }

    /// Two languages are two briefs — the statement is keyed by its language,
    /// so the door must not hand `fr` the `es` brief.
    func test_eachEditionGetsItsOwnBrief() async throws {
        let h = try await makeProject()

        let openedES = await DepartmentPaneHost.openBrief(language: "es", in: h.projectStore)
        let openedFR = await DepartmentPaneHost.openBrief(language: "fr", in: h.projectStore)
        let es = try XCTUnwrap(openedES)
        let fr = try XCTUnwrap(openedFR)

        XCTAssertNotEqual(es.statementID, fr.statementID)
        XCTAssertEqual(h.projectStore.manifest.statements.count, 2)

        await h.documentStore.close()
    }

    // MARK: - Mounted: which arm the pane is on

    /// The sections scroll in ONE scroller of the pane's own — a right-column
    /// pane may never grow the split view past the window it is a column of
    /// (`DetailPaneColumnHeightCensusTests`).
    func test_theDeskPutsItsSectionsInOneScrollerOfItsOwn() async throws {
        let window = mount(languages: ["es"])
        let scrollers = try await scrollersSettling(in: window)

        XCTAssertEqual(scrollers.count, 1)
    }

    /// …and a project with no editions at all still has them, which is the arm
    /// a reading of "the desk is for translations" would get wrong: the Design
    /// row is always there, and Task 4 retired the empty state that used to
    /// stand in front of it.
    func test_aProjectWithNoEditionsStillHasTheDesksSections() async throws {
        let window = mount(languages: [])
        let scrollers = try await scrollersSettling(in: window)

        XCTAssertEqual(scrollers.count, 1)
    }

    /// **A language row is named the way the rest of the app names one** —
    /// `TranslationReviewIndicator.displayLabel`, so the tag the writer reads in
    /// the translation indicator and the one they read on the desk are the same
    /// string. Read off the accessibility tree, and skipped by name where no
    /// assistive client can attach: a tree that was never built is not evidence
    /// about this view.
    func test_aLanguageRowIsNamedAsTheRestOfTheAppNamesIt() async throws {
        let window = mount(languages: ["es"])
        _ = try await scrollersSettling(in: window)

        let texts = try axTexts(in: window)
        XCTAssertFalse(texts.isEmpty,
                       "the hosted desk published no text at all, so this test "
                       + "could not fail for the reason it exists")
        let expected = TranslationReviewIndicator.displayLabel(forLanguageTag: "es")
        XCTAssertTrue(texts.contains { $0.contains(expected) },
                      "no row reads \u{201C}\(expected)\u{201D}. Published: \(texts.sorted())")
    }

    /// **The row carries the four facts the spec asks a language row for** —
    /// who translates it, how much of it is fresh/stale/missing, what is still
    /// unanswered — and the door to its brief. Read off the mounted tree so the
    /// assertion is about what a writer can see, not about a string constant.
    func test_aLanguageRowCarriesItsTranslatorItsCoverageAndItsQueries() async throws {
        let row = EditionStatus.LanguageRow(
            language: "es", translator: "Cortázar",
            fresh: 12, stale: 3, missing: 1, openQueries: 2)
        let window = mount(rows: [row])
        _ = try await scrollersSettling(in: window)

        let texts = try axTexts(in: window)
        for expected in ["Cortázar",
                         DepartmentDesk.coverageLine(fresh: 12, stale: 3, missing: 1),
                         DepartmentDesk.queryLine(openQueries: 2) ?? "",
                         DepartmentDesk.editionBriefTitle] {
            XCTAssertTrue(texts.contains { $0.contains(expected) },
                          "nothing on the row reads \u{201C}\(expected)\u{201D}. "
                          + "Published: \(texts.sorted())")
        }
    }

    /// The door is a control, not a caption — a writer reaches it with the
    /// keyboard and VoiceOver announces it, which a `Text` would not. Read off
    /// the accessibility tree, as the sibling board reads its chips.
    func test_theEditionBriefDoorIsAButtonOnEveryRow() async throws {
        let window = mount(languages: ["es", "fr"])
        _ = try await scrollersSettling(in: window)

        let labels = try axButtonLabels(in: window)
        XCTAssertEqual(labels.filter { $0 == DepartmentDesk.editionBriefTitle }.count, 2,
                       "one door per edition. Buttons published: \(labels.sorted())")
    }

    /// **Pressing a door carries the ROW's own tag**, so two editions cannot
    /// open one brief.
    ///
    /// **Pressed through the accessibility tree since Task 3**, which is both a
    /// necessity and an improvement. The necessity: the row grew a Run button, so
    /// counting SwiftUI's private focus-ring views no longer identifies a door —
    /// the reading Task 1's report warned would need re-deriving once the rows had
    /// verbs. The improvement: `accessibilityPerformPress` is the action a click
    /// ultimately performs, and unlike a synthetic `mouseDown` it does not need
    /// this process to be the active app, so an overnight gate on a locked screen
    /// can no longer fail this test for a reason that has nothing to do with the
    /// desk (CLAUDE.md's synthetic-click premise).
    func test_theDoorReportsTheLanguageItBelongsTo() async throws {
        var opened: [String] = []
        let window = mount(languages: ["es", "fr"],
                           openEditionBrief: { opened.append($0) })
        _ = try await scrollersSettling(in: window)

        let doors = try axButtons(labelled: DepartmentDesk.editionBriefTitle,
                                  in: window)
        XCTAssertEqual(doors.count, 2, "one door per edition")
        // Rows are drawn in the language order, and the tree is built in the
        // order the rows are — so the second door is `fr`'s.
        _ = (doors[1] as? NSObject)?.perform(
            NSSelectorFromString("accessibilityPerformPress"))
        _ = await pumpUntil(deadline: 3) { !opened.isEmpty }

        XCTAssertEqual(opened, ["fr"],
                       "the second row's door opened \(opened) — a door that "
                       + "captured the wrong row's tag would open the first")
    }

    // MARK: - The unreadable chapter, on screen (issue #43, F-D)

    /// **A chapter that would not open is named on the desk, and "No
    /// translations yet." yields to it.** Read off the mounted tree, because
    /// this test is about what a writer sees rather than about which strings
    /// exist: an empty Languages section over a book Maugham could not read is
    /// the false claim F-D is about, and it is false in the exact case where
    /// there is nothing else on the section to contradict it.
    ///
    /// The disable experiment: draw `noLanguagesYet` unconditionally and the
    /// second assertion fails while the first still passes — the line alone is
    /// not the fix.
    func test_anUnreadableChapterIsNamedAndTheEmptyStateYieldsToIt() async throws {
        let window = mount(rows: [], unreadable: [
            EditionStatus.UnreadableDocument(
                documentId: "doc-2", title: "Chapter 2",
                reason: "The manuscript\u{2019}s history file can\u{2019}t be read."),
        ])
        _ = try await scrollersSettling(in: window)

        let texts = try axTexts(in: window)
        XCTAssertFalse(texts.isEmpty,
                       "the hosted desk published no text at all, so this test "
                       + "could not fail for the reason it exists")
        let named = DepartmentDesk.couldNotRead("Chapter 2")
        XCTAssertTrue(texts.contains { $0.contains(named) },
                      "nothing on the desk reads \u{201C}\(named)\u{201D}. "
                      + "Published: \(texts.sorted())")
        XCTAssertTrue(texts.contains { $0.contains("history file") },
                      "…and the failure's own sentence goes with it, so the "
                      + "writer knows what to fix. Published: \(texts.sorted())")
        XCTAssertFalse(texts.contains { $0.contains(DepartmentDesk.noLanguagesYet) },
                       "\u{201C}\(DepartmentDesk.noLanguagesYet)\u{201D} is a claim "
                       + "about the book, and a chapter that would not open is "
                       + "exactly the case where Maugham cannot make it")
    }

    /// The control: nothing unreadable, no rows — the desk says what it has
    /// always said, so the suppression above is the squat's doing and not a
    /// section that lost its empty state.
    func test_aReadableBookWithNoEditionsStillSaysSo() async throws {
        let window = mount(rows: [], unreadable: [])
        _ = try await scrollersSettling(in: window)

        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains(DepartmentDesk.noLanguagesYet) },
                      "Published: \(texts.sorted())")
        XCTAssertFalse(texts.contains { $0.contains("Couldn\u{2019}t read") },
                       "nothing failed, so nothing is named")
    }

    // MARK: - The imprint picker and the desk's own compile (imprints P3 Task 5)

    /// **The picker is drawn only where there is a choice to make.** A project
    /// with no imprints gets one sentence saying where an imprint comes from,
    /// because a popup whose single row cannot be changed is a control that can
    /// only refuse.
    ///
    /// The disable experiment: drop the `if !imprints.isEmpty` guard around the
    /// `Picker` in `DepartmentPane.header` and the second half fails — the
    /// picker publishes "Book" over a project that has no imprints at all.
    func test_theImprintPickerIsDrawnOnlyWhenTheProjectDefinesOne() async throws {
        let withOne = mount(languages: [], imprints: ["special"])
        _ = try await scrollersSettling(in: withOne)
        let drawn = try axTexts(in: withOne)
        XCTAssertFalse(drawn.isEmpty,
                       "the hosted desk published no text at all, so this test "
                       + "could not fail for the reason it exists")
        XCTAssertTrue(drawn.contains { $0.contains(DepartmentDesk.bookImprintTitle) },
                      "the picker stands on the book until an imprint is picked. "
                      + "Published: \(drawn.sorted())")

        let withNone = mount(languages: [], imprints: [])
        _ = try await scrollersSettling(in: withNone)
        let bare = try axTexts(in: withNone)
        XCTAssertFalse(bare.contains { $0.contains(DepartmentDesk.bookImprintTitle) },
                       "no imprints, no picker. Published: \(bare.sorted())")
    }

    /// …and what stands in its place says where an imprint comes from. A writer
    /// who cannot find the door has no other clue: an imprint is declared in a
    /// file, not by a control on this desk.
    ///
    /// The disable experiment: draw `noImprintsYet` unconditionally and the
    /// second assertion fails — the line appears over a project that HAS
    /// imprints, beside the picker that contradicts it.
    func test_aProjectWithNoImprintsIsToldWhereOneComesFrom() async throws {
        let bare = mount(languages: [], imprints: [])
        _ = try await scrollersSettling(in: bare)
        let texts = try axTexts(in: bare)
        XCTAssertTrue(texts.contains { $0.contains(DepartmentDesk.noImprintsYet) },
                      "Published: \(texts.sorted())")
        XCTAssertTrue(DepartmentDesk.noImprintsYet.contains("config.json"),
                      "the line names the file, or it says nothing actionable")

        let withOne = mount(languages: [], imprints: ["special"])
        _ = try await scrollersSettling(in: withOne)
        let drawn = try axTexts(in: withOne)
        XCTAssertFalse(drawn.contains { $0.contains(DepartmentDesk.noImprintsYet) },
                       "a project WITH imprints is not told it has none. "
                       + "Published: \(drawn.sorted())")
    }

    /// **Compile is a door on the desk** — a real control a keyboard reaches
    /// and VoiceOver announces, not a caption. Until Task 4 there was no way to
    /// make a book from inside Maugham at all; this is the press.
    func test_compileIsADoorOnTheDesk() async throws {
        let window = mount(languages: [])
        _ = try await scrollersSettling(in: window)

        let labels = try axButtonLabels(in: window)
        XCTAssertEqual(labels.filter { $0 == DepartmentDesk.compileTitle }.count, 1,
                       "one press, on a project-level surface. Buttons "
                       + "published: \(labels.sorted())")
    }

    /// **What the compile is doing is drawn where the run lines are drawn** —
    /// one channel, `DepartmentCompileState.statusLine`, so the desk never says
    /// two things about one press.
    func test_theCompilesOwnLineIsDrawnOnTheDesk() async throws {
        let running = DepartmentCompileState(
            phase: .running(format: .epub, languages: ["en"], imprint: "special"),
            isRunning: true)
        let window = mount(languages: [], compileRun: running)
        _ = try await scrollersSettling(in: window)

        let texts = try axTexts(in: window)
        let expected = try XCTUnwrap(running.statusLine)
        XCTAssertTrue(texts.contains { $0.contains(expected) },
                      "nothing on the desk reads \u{201C}\(expected)\u{201D}. "
                      + "Published: \(texts.sorted())")
    }

    /// **Cancel is gated on `isRunning`, never on the phase** (Task 4's review
    /// carry). Drawn while one runs, absent when none does.
    ///
    /// **Two disable experiments, and the pair is the point.** Gate the button
    /// on `if case .running = compileRun.phase` instead and this still passes —
    /// which is exactly why the refusal test below exists. And the ABSENT half
    /// here is held by the outer `statusLine != nil || isRunning` guard around
    /// `compileStatus` rather than by the button's own gate: making both `true`
    /// is what publishes a "Cancel Compile" over an idle desk and fails it.
    func test_cancelIsDrawnWhileACompileRunsAndNotOtherwise() async throws {
        let running = mount(
            languages: [],
            compileRun: DepartmentCompileState(
                phase: .running(format: .pdf, languages: [], imprint: nil),
                isRunning: true))
        _ = try await scrollersSettling(in: running)
        XCTAssertEqual(
            try axButtonLabels(in: running)
                .filter { $0 == DepartmentDesk.cancelCompileLabel }.count, 1,
            "a compile in flight has exactly one way to stop it")

        let idle = mount(languages: [])
        _ = try await scrollersSettling(in: idle)
        let labels = try axButtonLabels(in: idle)
        XCTAssertFalse(labels.contains(DepartmentDesk.cancelCompileLabel),
                       "nothing is running, so there is nothing to cancel. "
                       + "Buttons published: \(labels.sorted())")
    }

    /// **A refusal does not take the Cancel away, and does not pretend nothing
    /// is compiling.** The second press replaces the PHASE while the run it was
    /// refused for carries on: a Cancel read off the phase would vanish in
    /// exactly that moment, taking the writer's only way to stop the compile
    /// with it, and a bare refusal line would leave a Cancel button with
    /// nothing on screen to explain what it cancels.
    ///
    /// The disable experiment: gate the Cancel on the phase (`if case .running`)
    /// and the first assertion fails; return the bare `sentence` from
    /// `statusLine`'s `.refused` arm and the second fails.
    func test_aRefusalKeepsBothTheCancelAndTheNewsThatSomethingIsCompiling()
        async throws {
        let refused = DepartmentCompileState(
            phase: .refused(DepartmentCompileState.alreadyRunning),
            isRunning: true)
        let window = mount(languages: [], compileRun: refused)
        _ = try await scrollersSettling(in: window)

        XCTAssertEqual(
            try axButtonLabels(in: window)
                .filter { $0 == DepartmentDesk.cancelCompileLabel }.count, 1,
            "the run the press was refused for is still going, and stopping it "
            + "is still the writer's to do")
        let texts = try axTexts(in: window)
        let expected = try XCTUnwrap(refused.statusLine)
        XCTAssertTrue(texts.contains { $0.contains(expected) },
                      "Published: \(texts.sorted())")
        XCTAssertTrue(expected.contains("still compiling"),
                      "…and that line says something IS compiling: \(expected)")
    }

    // MARK: - The compile sheet (Task 5)

    /// **The sheet opens on the book itself.** A writer who presses Compile…
    /// and then Compile gets what they came for — the book — and every other
    /// box is something they added deliberately.
    func test_theSheetOffersTheBooksOwnLanguageCheckedAndCompilesIt() async throws {
        var asked: [DeskCompileRunner.Request] = []
        let window = mountSheet(languages: ["es"], bookLanguage: "en",
                                onCompile: { asked.append($0) })
        _ = await pumpUntil(deadline: 3) {
            (try? self.axButtonLabels(in: window))?
                .contains(DepartmentCompileState.compileTitle) == true
        }
        let doors = try axButtons(labelled: DepartmentCompileState.compileTitle,
                                  in: window)
        XCTAssertEqual(doors.count, 1, "one Compile on the sheet")
        press(doors[0])
        _ = await pumpUntil(deadline: 3) { !asked.isEmpty }

        XCTAssertEqual(asked, [DeskCompileRunner.Request(
            format: .pdf, languages: ["en"], imprint: nil, allowStale: false)],
            "the book's own tag, PDF, no imprint, nothing stale")
    }

    /// **The imprint is shown and never asked** — the desk's picker already
    /// answered it, and a second control for one decision is two places that
    /// can disagree about which book is being made.
    func test_theSheetCarriesTheDesksImprintWithoutAskingAgain() async throws {
        var asked: [DeskCompileRunner.Request] = []
        let window = mountSheet(languages: [], bookLanguage: "en",
                                imprint: "special",
                                onCompile: { asked.append($0) })
        _ = await pumpUntil(deadline: 3) {
            (try? self.axButtonLabels(in: window))?
                .contains(DepartmentCompileState.compileTitle) == true
        }
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains("special") },
                      "the sheet says which book it is about. "
                      + "Published: \(texts.sorted())")

        press(try axButtons(labelled: DepartmentCompileState.compileTitle,
                            in: window)[0])
        _ = await pumpUntil(deadline: 3) { !asked.isEmpty }
        XCTAssertEqual(asked.first?.imprint, "special")
    }

    /// **Nothing checked is refused in words**, not silently honoured. An empty
    /// list reaches `LanguageSet` as the source book, so a sheet that let it
    /// through would compile the book a writer had just unchecked.
    func test_theSheetRefusesACompileWithNoEditionInIt() {
        XCTAssertFalse(DepartmentCompileSheetCopy.pickAnEdition.isEmpty)
        XCTAssertTrue(DepartmentCompileSheetCopy
            .bookLanguageTitle("en").contains("English"),
            "the untranslated body is named by its language, as the rest of the "
            + "app names one")
        XCTAssertTrue(DepartmentCompileSheetCopy.subjectLine(imprint: "special")
            .contains("special"))
        XCTAssertFalse(DepartmentCompileSheetCopy.subjectLine(imprint: nil)
            .contains("imprint"),
            "the plain book is not described as an imprint of itself")
    }

    // MARK: - The imprint, in the host (Task 5)

    /// The picker's rows are the config's own imprints, sorted — and a project
    /// with no config has none rather than crashing on one.
    func test_theImprintPickersRowsAreTheConfigsImprintsSorted() {
        var config = PublishConfig()
        config.imprints = ["zeta": .init(), "alpha": .init()]
        XCTAssertEqual(DepartmentPaneHost.imprintNames(in: config),
                       ["alpha", "zeta"])
        XCTAssertEqual(DepartmentPaneHost.imprintNames(in: PublishConfig()), [])
        XCTAssertEqual(DepartmentPaneHost.imprintNames(in: nil), [])
    }

    /// **An imprint's `sections` block is an allowlist, and the desk sums what
    /// would actually be compiled.** An edition is "3 missing" against the whole
    /// novel and complete against the pamphlet cut from it.
    ///
    /// The disable experiment: return `all` unconditionally and the first
    /// assertion fails.
    func test_anImprintWithAnAllowlistScopesTheDesksDocuments() {
        var config = PublishConfig()
        config.imprints = [
            "pamphlet": .init(sections: ["doc-2": .init()]),
            "whole": .init(),
        ]
        let all = ["doc-1", "doc-2", "doc-3"]

        XCTAssertEqual(
            DepartmentPaneHost.scopedDocumentIds(all, imprint: "pamphlet",
                                                 in: config),
            ["doc-2"])
        XCTAssertEqual(
            DepartmentPaneHost.scopedDocumentIds(all, imprint: "whole", in: config),
            all, "an imprint with no sections block inherits the book's own map")
        XCTAssertEqual(
            DepartmentPaneHost.scopedDocumentIds(all, imprint: nil, in: config),
            all)
        XCTAssertEqual(
            DepartmentPaneHost.scopedDocumentIds(all, imprint: "gone", in: config),
            all, "a name the config no longer defines is a choice the writer "
            + "can no longer see; the honest reading is the whole book")
    }

    /// A stale id in a hand-edited allowlist must not put a chapter that does
    /// not exist onto the desk.
    func test_anAllowlistNamingAChapterTheBookNoLongerHoldsAddsNothing() {
        var config = PublishConfig()
        config.imprints = ["pamphlet": .init(
            sections: ["doc-2": .init(), "deleted": .init()])]
        XCTAssertEqual(
            DepartmentPaneHost.scopedDocumentIds(["doc-1", "doc-2"],
                                                 imprint: "pamphlet", in: config),
            ["doc-2"])
    }

    /// **The pick is remembered for the project.** A writer who compiles the
    /// same special edition all week does not re-pick it every morning, and
    /// picking the book again clears it.
    func test_pickingAnImprintIsRememberedForTheProject() async throws {
        let fixture = try await makeProject()
        XCTAssertNil(fixture.documentStore.uiState.publishImprint)

        DepartmentPaneHost.select(imprint: "special", in: fixture.documentStore)
        XCTAssertEqual(fixture.documentStore.uiState.publishImprint, "special")

        DepartmentPaneHost.select(imprint: nil, in: fixture.documentStore)
        XCTAssertNil(fixture.documentStore.uiState.publishImprint,
                     "the picker's first row is the book, and choosing it is a "
                     + "choice rather than a no-op")
    }

    /// **The scoped derivation is the same walk over fewer chapters.** Chapter
    /// one has two paragraphs and one of them is translated; chapter two has
    /// one and it is done. The whole book is therefore one paragraph short of a
    /// Spanish edition, and a pamphlet cut to chapter two is complete — the
    /// same edition, two honest answers, because they are answers about
    /// different books.
    ///
    /// The disable experiment: have the new overload ignore `documentIds` and
    /// walk `manuscriptDocumentIds` anyway — the scoped half then reports
    /// 2 fresh / 1 missing and both of its assertions fail.
    func test_theScopedWalkSumsOnlyTheDocumentsItWasGiven() async throws {
        let fixture = try await makeProject()
        try await seed(fixture, doc: fixture.doc1,
                       paragraphId: try XCTUnwrap(fixture.doc1.sequence.first),
                       language: "es", text: "Documento uno, primero.")
        try await seed(fixture, doc: fixture.doc2,
                       paragraphId: try XCTUnwrap(fixture.doc2.sequence.first),
                       language: "es", text: "Solo el documento dos.")

        let whole = await EditionStatus.languageRows(
            in: fixture.projectStore, projectURL: fixture.projectURL)
        let wholeES = try XCTUnwrap(whole.rows.first { $0.language == "es" })
        XCTAssertEqual(wholeES.fresh, 2)
        XCTAssertEqual(wholeES.missing, 1,
                       "chapter one's second paragraph is untranslated")

        let scoped = await EditionStatus.languageRows(
            in: fixture.projectStore, projectURL: fixture.projectURL,
            documentIds: ["doc-2"])
        let scopedES = try XCTUnwrap(scoped.rows.first { $0.language == "es" })
        XCTAssertEqual(scopedES.fresh, 1)
        XCTAssertEqual(scopedES.missing, 0,
                       "the pamphlet is chapter two, and chapter two is done")
    }

    /// **The book's own language is the IMPRINT's, when the imprint spells
    /// one** — and getting this wrong refuses a compile for a translation
    /// nobody wrote.
    ///
    /// `CompileOrchestrator` builds its `LanguageSet` with `sourceTag:
    /// config.metadata.language` off the config it has already RESOLVED, and
    /// says so in its own comment. So an imprint whose `metadata` fragment
    /// carries `"language": "es"` has `es` as its source tag: a sheet offering
    /// the top-level `en` would send `["en"]`, and `LanguageSet` would read
    /// that as a translated edition of a Spanish book.
    ///
    /// The last two assertions are the consequence rather than a restatement:
    /// the same tag the sheet would send, put through the reader the
    /// orchestrator actually uses, is a SOURCE body — and the unresolved one is
    /// not.
    ///
    /// The disable experiment: answer `config.metadata.language` without
    /// resolving and the first assertion fails with "en".
    func test_theBooksOwnLanguageIsTheImprintsWhenTheImprintSpellsOne() throws {
        var config = PublishConfig()
        config.metadata.language = "en"
        config.imprints = [
            "es-edition": .init(metadata: ["language": .string("es")]),
            "plain": .init(metadata: ["title": .string("A Special Edition")]),
        ]
        let pieces = ["doc-1", "doc-2"]

        XCTAssertEqual(
            DepartmentPaneHost.sourceLanguage(imprint: "es-edition", in: config,
                                              pieceIDs: pieces), "es")
        XCTAssertEqual(
            DepartmentPaneHost.sourceLanguage(imprint: "plain", in: config,
                                              pieceIDs: pieces), "en",
            "an imprint that spells no language of its own inherits the book's")
        XCTAssertEqual(
            DepartmentPaneHost.sourceLanguage(imprint: nil, in: config,
                                              pieceIDs: pieces), "en")
        XCTAssertEqual(
            DepartmentPaneHost.sourceLanguage(imprint: "gone", in: config,
                                              pieceIDs: pieces), "en",
            "a name the config no longer defines falls back to the book, as "
            + "`scopedDocumentIds` does for the same case")
        XCTAssertEqual(
            DepartmentPaneHost.sourceLanguage(imprint: "es-edition", in: nil,
                                              pieceIDs: pieces),
            PublishConfig.Metadata().language,
            "a project with no config at all still has to answer something")

        // The consequence, through the orchestrator's own reader.
        let asSent = try LanguageSet(language: nil, languages: ["es"],
                                     sourceTag: "es")
        XCTAssertEqual(asSent.bodies, [nil],
                       "the resolved tag makes a SOURCE compile")
        let asUnresolved = try LanguageSet(language: nil, languages: ["en"],
                                           sourceTag: "es")
        XCTAssertEqual(asUnresolved.bodies, ["en"],
                       "…and the top-level one would have asked for a Spanish "
                       + "book's English TRANSLATION, which nobody wrote")
    }

    /// **The sheet carries whatever source tag the host resolved** — the label
    /// the writer reads and the tag the request sends are the same value, so
    /// the fix above reaches the press rather than stopping at a static
    /// function.
    func test_theSheetsBookLanguageRowIsTheOneTheHostResolved() async throws {
        var asked: [DeskCompileRunner.Request] = []
        let window = mountSheet(languages: [], bookLanguage: "es",
                                imprint: "es-edition",
                                onCompile: { asked.append($0) })
        _ = await pumpUntil(deadline: 3) {
            (try? self.axButtonLabels(in: window))?
                .contains(DepartmentCompileState.compileTitle) == true
        }
        let texts = try axTexts(in: window)
        let expected = DepartmentCompileSheetCopy.bookLanguageTitle("es")
        XCTAssertTrue(texts.contains { $0.contains(expected) },
                      "nothing on the sheet reads \u{201C}\(expected)\u{201D}. "
                      + "Published: \(texts.sorted())")

        press(try axButtons(labelled: DepartmentCompileState.compileTitle,
                            in: window)[0])
        _ = await pumpUntil(deadline: 3) { !asked.isEmpty }
        XCTAssertEqual(asked.first?.languages, ["es"])
    }

    /// **A persisted imprint the config no longer declares is not a selection.**
    ///
    /// An imprint is declared by hand-editing `config.json`, so one can be
    /// deleted under a stored `UIState.publishImprint`. The `Picker`'s
    /// selection then matched no tag it drew and it went BLANK — not the
    /// imprint, not "Book", nothing on screen to say which the desk was about
    /// — while the ROWS below it had already fallen back to the whole book
    /// (`scopedDocumentIds`). The header and the rows disagreed, silently.
    ///
    /// Disable experiment: return `persisted` unconditionally from
    /// `DepartmentPaneHost.selection(persisted:among:)` and the first assertion
    /// fails with `XCTAssertNil failed: "gone"`.
    func test_aPersistedImprintTheConfigNoLongerHasIsDrawnAsTheBook() throws {
        XCTAssertNil(DepartmentPaneHost.selection(persisted: "gone",
                                                  among: ["special", "other"]),
                     "a name no row can show is not a selection — the picker "
                     + "draws blank on it")
        XCTAssertNil(DepartmentPaneHost.selection(persisted: "special", among: []),
                     "…and a project whose imprints all went away is the book")

        // The controls: a name the config still declares survives, and the
        // book itself is unaffected.
        XCTAssertEqual(DepartmentPaneHost.selection(persisted: "special",
                                                    among: ["other", "special"]),
                       "special")
        XCTAssertNil(DepartmentPaneHost.selection(persisted: nil,
                                                  among: ["special"]))

        // …and the rows the desk draws under that blank picker were already
        // the whole book, which is what the picker now agrees with.
        let pieces = ["doc-1", "doc-2"]
        var config = PublishConfig(metadata: .init(title: "T", author: "A"))
        config.imprints = ["special": .init(sections: ["doc-1": .init(include: true)])]
        XCTAssertEqual(
            DepartmentPaneHost.scopedDocumentIds(pieces, imprint: "gone", in: config),
            pieces,
            "premise: the rows already fall back to the whole book for a name "
            + "the config does not define")
    }

    /// **The desk's pick is joined into the re-derive key**, which is the whole
    /// of how picking an imprint re-sums the rows. Nothing the pane DRAWS shows
    /// this: delete the join and the desk goes on reporting the previous book's
    /// coverage under the new imprint's name, silently.
    ///
    /// The disable experiment: drop `imprint:` from `reloadKey`'s construction
    /// (pass `nil`) and the second assertion fails — the two keys compare equal
    /// across a changed pick.
    func test_theDesksPickIsJoinedIntoTheReDeriveKey() async throws {
        let fixture = try await makeProject()
        let host = DepartmentPaneHost(store: fixture.projectStore,
                                      documentStore: fixture.documentStore,
                                      projectURL: fixture.projectURL)
        let onTheBook = host.reloadKey

        DepartmentPaneHost.select(imprint: "special", in: fixture.documentStore)
        let onTheImprint = host.reloadKey

        XCTAssertEqual(onTheImprint.imprint, "special")
        XCTAssertNotEqual(onTheBook, onTheImprint,
                          "a changed pick must change the key, or the rows are "
                          + "never re-derived against the imprint's own "
                          + "documents")
    }

    /// **The compile sheet never offers the book's own language twice.**
    ///
    /// The sheet draws the untranslated body as its own checkbox ("The book's
    /// own language (English)"). A translator ROW named for the same tag — the
    /// desk accepts `Add Language…` with "en" on an English book — put a second
    /// English box beside it, and a writer who checked both sent `["en", "en"]`
    /// into `LanguageSet`, which refuses a duplicate: a red compile for a
    /// request the sheet itself made offerable.
    ///
    /// Disable experiment: delete the `.filter` on `languages:` at
    /// `DepartmentPane`'s `DepartmentCompileSheet(…)` and this fails with
    /// `XCTAssertEqual failed: ("1") is not equal to ("0") — the book's own
    /// language is offered twice…`.
    func test_theCompileSheetNeverOffersTheBooksOwnLanguageTwice() async throws {
        // "EN" rather than "en" — a tag is matched case-insensitively
        // everywhere else on this desk, and a writer types what they type.
        let window = mount(languages: ["EN", "es"])
        _ = try await scrollersSettling(in: window)
        press(try axButtons(labelled: DepartmentDesk.compileTitle, in: window)[0])
        let attached = await attachedSheetWindow(of: window)
        let sheet = try XCTUnwrap(attached, "Compile… opened no sheet to inspect")

        let texts = try axTexts(in: sheet)
        let ownTag = TranslationReviewIndicator.displayLabel(forLanguageTag: "EN")
        XCTAssertEqual(texts.filter { $0 == ownTag }.count, 0,
                       "the book's own language is offered twice — checking "
                       + "both boxes sends a duplicate tag and the compile is "
                       + "refused. Published: \(texts.sorted())")

        // The controls: the book's own row IS there, and a language that is
        // genuinely a translation still is too.
        let bookRow = DepartmentCompileSheetCopy.bookLanguageTitle("en")
        XCTAssertTrue(texts.contains { $0.contains(bookRow) },
                      "the book's own language must still be offered once. "
                      + "Published: \(texts.sorted())")
        let other = TranslationReviewIndicator.displayLabel(forLanguageTag: "es")
        XCTAssertTrue(texts.contains { $0 == other },
                      "…and a real translation is still on the sheet. "
                      + "Published: \(texts.sorted())")
    }

    /// **Wait for a `.sheet` to attach** — a real child `NSWindow` once the
    /// parent is ordered front, which every mount here does.
    private func attachedSheetWindow(of parent: NSWindow,
                                     deadline: TimeInterval = 5) async -> NSWindow? {
        var sheet: NSWindow?
        _ = await pumpUntil(deadline: deadline) {
            sheet = parent.attachedSheet
            return sheet != nil
        }
        return sheet
    }

    // MARK: - Census

    /// **The desk reads no store** (tripwire 4). Its values are assembled by the
    /// mount precisely because assembling them is expensive — the language union
    /// walks every document's translation store and the proposal count reads
    /// `.maugham/design/proposals/` — and a `body` that could reach either would
    /// pay for it once per row. Tasks 2–4 add the rows' contents and their
    /// verbs: the verbs arrive as closures, the contents as values, and neither
    /// makes this census stale.
    func test_theSourceReadsNoStoreAtAll() throws {
        let code = try Self.codeLines(of: "Views/Publish/DepartmentPane.swift")

        for forbidden in ["ProjectStore", "DocumentStore", "TranslationStore",
                          "DesignProposalStore", "PublishConfigStore",
                          "FileManager", "contentsOf"] {
            XCTAssertFalse(code.contains { $0.contains(forbidden) },
                           "`\(forbidden)` appears on the pane's path — the desk "
                           + "takes values so nothing per-row can reach the disk "
                           + "(tripwire 4)")
        }
    }

    // MARK: - Hosting

    /// Bare tags, for the tests that are about the sections rather than a row's
    /// contents: every figure zero, nobody named.
    private func mount(languages: [String],
                       width: CGFloat = 340,
                       imprints: [String] = [],
                       compileRun: DepartmentCompileState = DepartmentCompileState(),
                       openEditionBrief: @escaping (String) -> Void = { _ in }) -> NSWindow {
        mount(rows: languages.map {
            EditionStatus.LanguageRow(language: $0, translator: nil,
                                      fresh: 0, stale: 0, missing: 0, openQueries: 0)
        }, width: width, imprints: imprints, compileRun: compileRun,
           openEditionBrief: openEditionBrief)
    }

    private func mount(rows: [EditionStatus.LanguageRow],
                       unreadable: [EditionStatus.UnreadableDocument] = [],
                       width: CGFloat = 340,
                       imprints: [String] = [],
                       compileRun: DepartmentCompileState = DepartmentCompileState(),
                       openEditionBrief: @escaping (String) -> Void = { _ in }) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(DepartmentPane(title: "The Project",
                                   languages: rows,
                                   unreadable: unreadable,
                                   openEditionBrief: openEditionBrief,
                                   imprints: imprints,
                                   compileRun: compileRun)
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: width, height: 600))
        windows.append(window)
        pump(0.1)
        return window
    }

    /// The compile sheet on its own, mounted rather than presented: a `.sheet`
    /// needs a host window to attach to, and what these tests are about is the
    /// request the sheet assembles — which is the sheet's own, wherever it is
    /// drawn.
    private func mountSheet(languages: [String],
                            bookLanguage: String,
                            imprint: String? = nil,
                            onCompile: @escaping (DeskCompileRunner.Request) -> Void
                                = { _ in }) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(DepartmentCompileSheet(languages: languages,
                                           bookLanguage: bookLanguage,
                                           imprint: imprint,
                                           onCompile: onCompile,
                                           onCancel: { })
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: 420, height: 600))
        windows.append(window)
        pump(0.1)
        return window
    }

    private func scrollViews(in window: NSWindow) -> [NSScrollView] {
        collect(NSScrollView.self, in: window)
    }

    private func scrollersSettling(in window: NSWindow,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) async throws -> [NSScrollView] {
        var found: [NSScrollView] = []
        _ = await pumpUntil(deadline: 5) {
            found = self.scrollViews(in: window)
            return !found.isEmpty
        }
        pump(0.2)
        found = scrollViews(in: window)
        XCTAssertFalse(found.isEmpty,
                       "the desk mounted no sections at all", file: file, line: line)
        return found
    }

    // MARK: - A project on disk (the derivation's fixture)

    /// Two manuscript documents, open and registered — `TranslationStatusTool
    /// Tests`' harness, because the point of these tests is that the desk and
    /// that tool answer alike and a fixture of my own would be a second world
    /// for them to agree in.
    private struct Fixture {
        let projectURL: URL
        let projectId: String
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let registry: ProjectRegistry
        let doc1: Document
        let doc2: Document
        let path2: String
    }

    /// **Make chapter 2 unreadable**, the way `ReadOnlyRecoveryTests` does it: a
    /// DIRECTORY squatting an op-log file path, which is present and cannot be
    /// read. Closing and unregistering it first is what puts it on the transient
    /// load path — an OPEN document is read out of memory, and a squatted file
    /// under it would never be touched.
    private func breakChapterTwo(_ fixture: Fixture) async throws {
        let docId = fixture.doc2.docId
        await fixture.doc2.close()
        fixture.documentStore.unregister(path: fixture.path2)
        let squat = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: DeviceSlug.make(from: "bad"),
            in: fixture.projectURL)
        try FileManager.default.createDirectory(at: squat, withIntermediateDirectories: true)
    }

    private func makeProject() async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DPT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let path1 = "manuscript/c1.md"
        let path2 = "manuscript/c2.md"
        try "Doc one first.\n\nDoc one second."
            .write(to: tmp.appendingPathComponent(path1), atomically: true, encoding: .utf8)
        try "Doc two only."
            .write(to: tmp.appendingPathComponent(path2), atomically: true, encoding: .utf8)

        let manifest = ProjectManifest(
            type: .novel, title: "The Project", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-1", title: "Chapter 1", type: .document, path: path1),
                StructureItem(id: "doc-2", title: "Chapter 2", type: .document, path: path2),
            ],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let projectStore = try await ProjectStore.load(from: tmp)
        let documentStore = try await DocumentStore.open(url: tmp)
        projectStore.documentStore = documentStore

        let doc1 = try await Document.load(
            url: tmp.appendingPathComponent(path1),
            device: "test", session: "s", presenter: nil)
        documentStore.register(document: doc1, for: path1)
        let doc2 = try await Document.load(
            url: tmp.appendingPathComponent(path2),
            device: "test", session: "s", presenter: nil)
        documentStore.register(document: doc2, for: path2)

        let registry = ProjectRegistry()
        registry.register(url: tmp, store: projectStore)

        return Fixture(projectURL: tmp, projectId: ProjectIdentifier.id(for: tmp),
                       projectStore: projectStore, documentStore: documentStore,
                       registry: registry, doc1: doc1, doc2: doc2, path2: path2)
    }

    private func seed(_ fixture: Fixture, doc: Document, paragraphId: String,
                      language: String, text: String) async throws {
        let source = doc.paragraphs[paragraphId] ?? ""
        try await TranslationStore.append(
            TranslationRecord(paragraphId: paragraphId, language: language, text: text,
                              sourceHash: TranslationHash.hash(source), verbatim: false),
            forDocId: doc.docId,
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current),
            in: fixture.projectURL)
    }

    private func addQuery(_ fixture: Fixture, doc: Document, paragraphId: String,
                          body: String, language: String) async throws {
        let params: [String: Any] = [
            "project_id": fixture.projectId,
            "document_id": doc.docId,
            "paragraph_id": paragraphId,
            "body": body,
            "language": language,
        ]
        _ = try await AddQueryTool.handle(
            paramsJSON: try JSONSerialization.data(withJSONObject: params),
            registry: fixture.registry)
    }

    /// `translation_status`' own answer over the same fixture — the other half
    /// of the agreement.
    private func toolRows(_ fixture: Fixture) async throws -> [TranslationStatusTool.Row] {
        try await toolResult(fixture).rows
    }

    /// The tool's whole answer, for the halves of the agreement that are not
    /// rows — `unreadable_documents` (issue #43, F-D).
    private func toolResult(_ fixture: Fixture) async throws -> TranslationStatusTool.Result {
        let params = try JSONSerialization.data(
            withJSONObject: ["project_id": fixture.projectId])
        let out = try await TranslationStatusTool.handle(
            paramsJSON: params, registry: fixture.registry)
        return try JSONDecoder().decode(
            TranslationStatusTool.Result.self, from: out)
    }

    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = appSourceDir.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - The cast sheet's three fields (translation pipeline P2 Task 9)

    func test_everyEditionAskTakesTheCastAndTheDesignersDoesNot() {
        XCTAssertTrue(DepartmentCastPrompt(ask: .addLanguage).takesCast)
        XCTAssertTrue(DepartmentCastPrompt(ask: .nameForRun(language: "es", docId: "d")).takesCast)
        XCTAssertTrue(DepartmentCastPrompt(
            ask: .rename(subject: .edition(language: "es"), currentName: "X")).takesCast)
        XCTAssertFalse(DepartmentCastPrompt(
            ask: .rename(subject: .designer, currentName: "X")).takesCast)
    }

    // MARK: - Naming a translator a BOOK run is waiting on (translation
    // pipeline P4 Task 2)

    /// **A whole-book run stands behind the same sheet a chapter run does**,
    /// and it has to carry its own queue: the ask is what Confirm runs, and a
    /// `.nameForRun` here would translate the open chapter alone — the writer
    /// having asked for the book.
    func test_theBookRunsAskCarriesItsQueueAndWearsTheRunSheetsWords() {
        let ask = DepartmentPaneHost.bookAsk(language: "xx",
                                             documentIds: ["doc-1", "doc-2"])
        XCTAssertEqual(ask, .nameForBookRun(language: "xx",
                                            documentIds: ["doc-1", "doc-2"]))

        let prompt = DepartmentCastPrompt(ask: ask)
        XCTAssertEqual(prompt.title, DepartmentCastCopy.nameForRunTitle(language: "xx"),
                       "the sheet names the edition it is about, as the chapter "
                       + "run's does")
        XCTAssertEqual(prompt.confirmTitle, DepartmentCastCopy.nameAndRunTitle)
        XCTAssertEqual(DepartmentCastCopy.nameAndRunTitle, "Name & Run")
        XCTAssertTrue(prompt.takesCast, "an edition ask takes the whole cast")
        XCTAssertFalse(prompt.takesLanguageTag,
                       "the language is already known — only Add Language types one")
    }

    /// One prompt per subject, and the book's is not the chapter's: a writer
    /// who presses Run and then Run Whole Book must not have the second ask
    /// silently answered by the first sheet's identity.
    func test_theBookRunsAskHasAnIdentityOfItsOwn() {
        let book = DepartmentCastPrompt(ask: .nameForBookRun(language: "xx",
                                                             documentIds: ["doc-1"]))
        let chapter = DepartmentCastPrompt(ask: .nameForRun(language: "xx", docId: "doc-1"))
        XCTAssertNotEqual(book.id, chapter.id)
    }
}

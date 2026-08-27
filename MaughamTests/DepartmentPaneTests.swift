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
                          "DesignProposalStore", "FileManager", "contentsOf"] {
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
                       openEditionBrief: @escaping (String) -> Void = { _ in }) -> NSWindow {
        mount(rows: languages.map {
            EditionStatus.LanguageRow(language: $0, translator: nil,
                                      fresh: 0, stale: 0, missing: 0, openQueries: 0)
        }, width: width, openEditionBrief: openEditionBrief)
    }

    private func mount(rows: [EditionStatus.LanguageRow],
                       unreadable: [EditionStatus.UnreadableDocument] = [],
                       width: CGFloat = 340,
                       openEditionBrief: @escaping (String) -> Void = { _ in }) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: width, height: 600)
        let hosting = NSHostingView(rootView: AnyView(
            DepartmentPane(title: "The Project",
                           languages: rows,
                           unreadable: unreadable,
                           openEditionBrief: openEditionBrief)
                .frame(maxWidth: .infinity, maxHeight: .infinity)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
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
}

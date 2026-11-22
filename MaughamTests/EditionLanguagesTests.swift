import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A book's editions, as `EditionStatus` reads them, and the imprint the
/// window stands on** (publish-department P4; the Department desk these
/// tests first described went in shell p4 Task 7 — its behaviour claims that
/// still ship moved here onto their homes: `EditionStatus`, `PublishImprint`,
/// `EditionCastVerbs`, `CompileSheet` and `EditionCompileAsk`).
@MainActor
final class EditionLanguagesTests: XCTestCase {

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

    // MARK: - A proposed brief with no edition (moved from the desk's mark)

    /// A proposed brief for a language the book has an edition of is that
    /// edition's (its Brief's gate); one with no edition shows on the Source
    /// edition's Brief. A visual-language proposal is neither.
    func test_aProposalWithNoEditionIsListedForTheSource() {
        let proposals: [StatementProposalStore.Proposal] = [
            .init(kind: .editionBrief("es"), markdown: "x", rationale: nil, proposedAt: Date(), author: "Claude"),
            .init(kind: .editionBrief("IT"), markdown: "x", rationale: nil, proposedAt: Date(), author: "Claude"),
            .init(kind: .visualLanguage, markdown: "x", rationale: nil, proposedAt: Date(), author: "Claude"),
        ]
        XCTAssertEqual(EditionCastVerbs.proposalsWithoutAnEdition(proposals, editions: ["en", "ES"]), ["it"])
        XCTAssertEqual(EditionCastVerbs.proposalsWithoutAnEdition(proposals, editions: []), ["es", "it"])
        XCTAssertEqual(EditionCastVerbs.proposedWithoutAnEditionLine(language: "it"),
                       "Claude proposed a brief for an edition in Italian.")
        XCTAssertEqual(EditionCastVerbs.addProposedTitle(language: "it"), "Add Italian\u{2026}")
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
        XCTAssertEqual([row.fresh, row.stale, row.missing], [0, 0, 0],
                       "nothing is translated yet — the query-first arm's own answer")
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
    func test_alreadyAnEdition_treeRowAlone_isTrue() {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [])
        XCTAssertTrue(EditionCastVerbs.alreadyAnEdition(
            "es", editions: ["en", "es"], manifest: manifest))
    }

    /// A translator the manifest already stores is a home even when `derive()`
    /// has not caught up with a row for it yet — the exact staleness window
    /// that let Confirm's name silently rename somebody (issue #43, F-G).
    func test_alreadyAnEdition_manifestAlone_isTrue() {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [],
            productionRoles: [ProductionRole(
                id: "role-1", role: .translator(language: "es"), name: "Cortázar")])

        XCTAssertTrue(EditionCastVerbs.alreadyAnEdition(
            "es", editions: [], manifest: manifest))
    }

    /// Neither side knows the language — it is genuinely new, and Add Language
    /// must be free to mint it.
    func test_alreadyAnEdition_neither_isFalse() {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [])

        XCTAssertFalse(EditionCastVerbs.alreadyAnEdition(
            "es", editions: [], manifest: manifest))
    }

    /// The match is case-insensitive on both sides, matching
    /// `storedTranslator(for:)`.
    func test_alreadyAnEdition_caseInsensitive_isTrue() {
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [],
            productionRoles: [ProductionRole(
                id: "role-1", role: .translator(language: "es"), name: "Cortázar")])

        XCTAssertTrue(EditionCastVerbs.alreadyAnEdition(
            "ES", editions: [], manifest: manifest))
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
        XCTAssertTrue(TranslationRunStart.needsTranslatorName(language: "xx", in: h.projectStore.manifest),
                      "…so a Run stands behind the cast sheet")

        await h.documentStore.close()
    }

    // MARK: - The compile sheet (Task 5)

    /// **The sheet opens on the book itself.** A writer who presses Compile…
    /// and then Compile gets what they came for — the book — and every other
    /// box is something they added deliberately.
    func test_theSheetOffersTheBooksOwnLanguageCheckedAndCompilesIt() async throws {
        var asked: [CompileRunner.Request] = []
        let window = mountSheet(languages: ["es"], bookLanguage: "en",
                                onCompile: { asked.append($0) })
        _ = await pumpUntil(deadline: 3) {
            (try? self.axButtonLabels(in: window))?
                .contains(CompileRunState.compileTitle) == true
        }
        let doors = try axButtons(labelled: CompileRunState.compileTitle,
                                  in: window)
        XCTAssertEqual(doors.count, 1, "one Compile on the sheet")
        press(doors[0])
        _ = await pumpUntil(deadline: 3) { !asked.isEmpty }

        XCTAssertEqual(asked, [CompileRunner.Request(
            format: .pdf, languages: ["en"], imprint: nil, allowStale: false)],
            "the book's own tag, PDF, no imprint, nothing stale")
    }

    /// The desk's format picker names every format this build produces, Word
    /// by name (report plan 4 Task 2, R-4-5).
    func test_theFormatPickerNamesWordByName() {
        XCTAssertEqual(PublishConfig.Format.allCases.map(CompileSheetCopy.formatTitle),
                       ["PDF", "EPUB", "Word (.docx)"])
    }

    /// **Nothing checked is refused in words**, not silently honoured. An empty
    /// list reaches `LanguageSet` as the source book, so a sheet that let it
    /// through would compile the book a writer had just unchecked.
    func test_theSheetRefusesACompileWithNoEditionInIt() {
        XCTAssertFalse(CompileSheetCopy.pickAnEdition.isEmpty)
        XCTAssertTrue(CompileSheetCopy
            .bookLanguageTitle("en").contains("English"),
            "the untranslated body is named by its language, as the rest of the "
            + "app names one")
        XCTAssertTrue(CompileSheetCopy.subjectLine(imprint: "special")
            .contains("special"))
        XCTAssertFalse(CompileSheetCopy.subjectLine(imprint: nil)
            .contains("imprint"),
            "the plain book is not described as an imprint of itself")
        XCTAssertTrue(CompileSheetCopy.subjectLine(imprint: nil)
            .contains("a Word export its own draft"),
            "R-4-1: a Word export mints a draft, never a version, and the sheet says so")
        XCTAssertTrue(CompileSheetCopy.subjectLine(imprint: "special")
            .contains("a Word export mints its own draft"),
            "an imprint's Word export is a draft too, and its line says so")
    }

    // MARK: - The imprint, in the host (Task 5)

    /// The picker's rows are the config's own imprints, sorted — and a project
    /// with no config has none rather than crashing on one.
    func test_theImprintPickersRowsAreTheConfigsImprintsSorted() {
        var config = PublishConfig()
        config.imprints = ["zeta": .init(), "alpha": .init()]
        XCTAssertEqual(PublishImprint.imprintNames(in: config),
                       ["alpha", "zeta"])
        XCTAssertEqual(PublishImprint.imprintNames(in: PublishConfig()), [])
        XCTAssertEqual(PublishImprint.imprintNames(in: nil), [])
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
            PublishImprint.scopedDocumentIds(all, imprint: "pamphlet",
                                                 in: config),
            ["doc-2"])
        XCTAssertEqual(
            PublishImprint.scopedDocumentIds(all, imprint: "whole", in: config),
            all, "an imprint with no sections block inherits the book's own map")
        XCTAssertEqual(
            PublishImprint.scopedDocumentIds(all, imprint: nil, in: config),
            all)
        XCTAssertEqual(
            PublishImprint.scopedDocumentIds(all, imprint: "gone", in: config),
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
            PublishImprint.scopedDocumentIds(["doc-1", "doc-2"],
                                                 imprint: "pamphlet", in: config),
            ["doc-2"])
    }

    /// **The pick is remembered for the project.** A writer who compiles the
    /// same special edition all week does not re-pick it every morning, and
    /// picking the book again clears it.
    func test_pickingAnImprintIsRememberedForTheProject() async throws {
        let fixture = try await makeProject()
        XCTAssertNil(fixture.documentStore.uiState.publishImprint)

        PublishImprint.select(imprint: "special", in: fixture.documentStore)
        XCTAssertEqual(fixture.documentStore.uiState.publishImprint, "special")

        PublishImprint.select(imprint: nil, in: fixture.documentStore)
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

    /// **The questions handed in from the project-wide read give the same
    /// rows as the per-chapter load** (shell p4 Task 5 fix round, I4) — over
    /// an open chapter and a closed one, a translation and an open question —
    /// so the edition's Status and the desk agree with `translation_status`,
    /// whose own path (no options) is unchanged. `languages` narrows the walk
    /// to one edition and nothing else.
    func test_theHandedQuestionsReadAsTheLoadDoes() async throws {
        let fixture = try await makeProject()
        let first = try XCTUnwrap(fixture.doc1.sequence.first)
        try await seed(fixture, doc: fixture.doc1, paragraphId: first,
                       language: "es", text: "Documento uno, primero.")
        try await addQuery(fixture, doc: fixture.doc1, paragraphId: first,
                           body: "t\u{FA} or usted?", language: "es")
        try await seed(fixture, doc: fixture.doc2,
                       paragraphId: try XCTUnwrap(fixture.doc2.sequence.first),
                       language: "fr", text: "Seulement le deux.")
        try await addQuery(fixture, doc: fixture.doc2,
                           paragraphId: try XCTUnwrap(fixture.doc2.sequence.first),
                           body: "vous?", language: "fr")
        // Chapter two closes: its questions come from its op log.
        fixture.documentStore.unregister(path: fixture.path2)
        await fixture.doc2.close()

        let ids = EditionStatus.manuscriptDocumentIds(in: fixture.projectStore.manifest)
        let loaded = await EditionStatus.documentRows(
            documentIds: ids, store: fixture.projectStore, projectURL: fixture.projectURL)
        let questions = EditionStatus.openQuestions(
            in: fixture.projectStore.listAnnotationsAcrossProject())
        let handed = await EditionStatus.documentRows(
            documentIds: ids, store: fixture.projectStore, projectURL: fixture.projectURL,
            options: .init(openQuestions: questions, yieldsAndStops: true))
        XCTAssertEqual(handed.rows, loaded.rows)
        XCTAssertEqual(handed.unreadable, loaded.unreadable)
        XCTAssertEqual(loaded.rows.filter { $0.openQueries > 0 }.count, 2, "the premise: two questions")

        let spanish = await EditionStatus.documentRows(
            documentIds: ids, store: fixture.projectStore, projectURL: fixture.projectURL,
            options: .init(openQuestions: questions, languages: ["ES"]))
        XCTAssertEqual(spanish.rows, loaded.rows.filter { $0.language == "es" })
        XCTAssertFalse(spanish.rows.isEmpty)

        // A chapter the read could not open is named, never counted empty.
        let broken = await EditionStatus.documentRows(
            documentIds: ids, store: fixture.projectStore, projectURL: fixture.projectURL,
            options: .init(openQuestions: .init(byDoc: questions.byDoc, unreadable: ["doc-2"])))
        XCTAssertEqual(broken.unreadable.map(\.documentId), ["doc-2"])
        XCTAssertFalse(broken.rows.contains { $0.documentId == "doc-2" })
    }

    /// **The read stops when its task is cancelled** — a Status whose key
    /// moved on does not finish the old walk.
    func test_aCancelledReadStopsWalking() async throws {
        let fixture = try await makeProject()
        try await seed(fixture, doc: fixture.doc1,
                       paragraphId: try XCTUnwrap(fixture.doc1.sequence.first),
                       language: "es", text: "Documento uno, primero.")
        let whole = await EditionStatus.documentRows(
            documentIds: EditionStatus.manuscriptDocumentIds(in: fixture.projectStore.manifest),
            store: fixture.projectStore, projectURL: fixture.projectURL,
            options: .init(openQuestions: .init(byDoc: [:], unreadable: []), yieldsAndStops: true))
        XCTAssertFalse(whole.rows.isEmpty, "the premise: an uncancelled read has rows")
        let ids = EditionStatus.manuscriptDocumentIds(in: fixture.projectStore.manifest)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await EditionStatus.documentRows(
                documentIds: ids, store: fixture.projectStore, projectURL: fixture.projectURL,
                options: .init(openQuestions: .init(byDoc: [:], unreadable: []), yieldsAndStops: true))
        }
        let report = await task.value
        XCTAssertTrue(report.rows.isEmpty && report.unreadable.isEmpty, "\(report.rows)")
    }

    /// **The book's own language is the IMPRINT's, when the imprint spells
    /// one** — and getting this wrong refuses a compile for a translation
    /// nobody wrote.
    ///
    /// `PublishOrchestrator` builds its `LanguageSet` with `sourceTag:
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
            PublishImprint.sourceLanguage(imprint: "es-edition", in: config,
                                              pieceIDs: pieces), "es")
        XCTAssertEqual(
            PublishImprint.sourceLanguage(imprint: "plain", in: config,
                                              pieceIDs: pieces), "en",
            "an imprint that spells no language of its own inherits the book's")
        XCTAssertEqual(
            PublishImprint.sourceLanguage(imprint: nil, in: config,
                                              pieceIDs: pieces), "en")
        XCTAssertEqual(
            PublishImprint.sourceLanguage(imprint: "gone", in: config,
                                              pieceIDs: pieces), "en",
            "a name the config no longer defines falls back to the book, as "
            + "`scopedDocumentIds` does for the same case")
        XCTAssertEqual(
            PublishImprint.sourceLanguage(imprint: "es-edition", in: nil,
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
    /// `PublishImprint.selection(persisted:among:)` and the first assertion
    /// fails with `XCTAssertNil failed: "gone"`.
    func test_aPersistedImprintTheConfigNoLongerHasIsDrawnAsTheBook() throws {
        XCTAssertNil(PublishImprint.selection(persisted: "gone",
                                                  among: ["special", "other"]),
                     "a name no row can show is not a selection — the picker "
                     + "draws blank on it")
        XCTAssertNil(PublishImprint.selection(persisted: "special", among: []),
                     "…and a project whose imprints all went away is the book")

        // The controls: a name the config still declares survives, and the
        // book itself is unaffected.
        XCTAssertEqual(PublishImprint.selection(persisted: "special",
                                                    among: ["other", "special"]),
                       "special")
        XCTAssertNil(PublishImprint.selection(persisted: nil,
                                                  among: ["special"]))

        // …and the rows the desk draws under that blank picker were already
        // the whole book, which is what the picker now agrees with.
        let pieces = ["doc-1", "doc-2"]
        var config = PublishConfig(metadata: .init(title: "T", author: "A"))
        config.imprints = ["special": .init(sections: ["doc-1": .init(include: true)])]
        XCTAssertEqual(
            PublishImprint.scopedDocumentIds(pieces, imprint: "gone", in: config),
            pieces,
            "premise: the rows already fall back to the whole book for a name "
            + "the config does not define")
    }

    /// **The compile sheet never offers the book's own language twice**
    /// (moved from the desk to `EditionCompileAsk`, the compile bar's ask).
    ///
    /// The sheet draws the untranslated body as its own checkbox. An edition
    /// named for the same tag — "EN" on an English book — put a second English
    /// box beside it, and checking both sent `["en", "en"]` into
    /// `LanguageSet`, which refuses a duplicate.
    func test_theCompileSheetNeverOffersTheBooksOwnLanguageTwice() {
        for edition in [nil, "es"] as [String?] {
            let ask = EditionCompileAsk.make(editions: ["en", "EN", "es"], edition: edition)
            XCTAssertEqual(ask.bookLanguage, "en")
            XCTAssertFalse(ask.languages.contains { $0.caseInsensitiveCompare("en") == .orderedSame },
                           "the book's own language is offered twice: \(ask.languages)")
            XCTAssertEqual(ask.languages, ["es"], "a real translation is still on the sheet")
        }
    }

    // MARK: - Hosting

    /// The compile sheet on its own, mounted rather than presented: a `.sheet`
    /// needs a host window to attach to, and what these tests are about is the
    /// request the sheet assembles — which is the sheet's own, wherever it is
    /// drawn.
    private func mountSheet(languages: [String],
                            bookLanguage: String,
                            imprint: String? = nil,
                            onCompile: @escaping (CompileRunner.Request) -> Void
                                = { _ in }) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(CompileSheet(languages: languages,
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
        let squat = try OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: DeviceSlug.make(from: "bad"),
            in: fixture.projectURL)
        try FileManager.default.createDirectory(at: squat, withIntermediateDirectories: true)
    }

    private func makeProject() async throws -> Fixture {
        let tmp = TestTemp.root
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
            identity: LocalIdentities.current.translator, identities: .current,
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
        XCTAssertTrue(EditionCastPrompt(ask: .addLanguage).takesCast)
        XCTAssertTrue(EditionCastPrompt(ask: .nameForRun(language: "es", docId: "d")).takesCast)
        XCTAssertTrue(EditionCastPrompt(
            ask: .rename(subject: .edition(language: "es"), currentName: "X")).takesCast)
        XCTAssertFalse(EditionCastPrompt(
            ask: .rename(subject: .designer, currentName: "X")).takesCast)
    }

    // MARK: - Naming a translator a BOOK run is waiting on (translation
    // pipeline P4 Task 2)

    /// **A whole-book run stands behind the same sheet a chapter run does**,
    /// and it has to carry its own queue: the ask is what Confirm runs, and a
    /// `.nameForRun` here would translate the open chapter alone — the writer
    /// having asked for the book.
    func test_theBookRunsAskCarriesItsQueueAndWearsTheRunSheetsWords() {
        let ask = TranslationRunStart.bookAsk(language: "xx",
                                             documentIds: ["doc-1", "doc-2"])
        XCTAssertEqual(ask, .nameForBookRun(language: "xx",
                                            documentIds: ["doc-1", "doc-2"]))

        let prompt = EditionCastPrompt(ask: ask)
        XCTAssertEqual(prompt.title, EditionCastCopy.nameForRunTitle(language: "xx"),
                       "the sheet names the edition it is about, as the chapter "
                       + "run's does")
        XCTAssertEqual(prompt.confirmTitle, EditionCastCopy.nameAndRunTitle)
        XCTAssertEqual(EditionCastCopy.nameAndRunTitle, "Name & Run")
        XCTAssertTrue(prompt.takesCast, "an edition ask takes the whole cast")
        XCTAssertFalse(prompt.takesLanguageTag,
                       "the language is already known — only Add Language types one")
    }

    /// One prompt per subject, and the book's is not the chapter's: a writer
    /// who presses Run and then Run Whole Book must not have the second ask
    /// silently answered by the first sheet's identity.
    func test_theBookRunsAskHasAnIdentityOfItsOwn() {
        let book = EditionCastPrompt(ask: .nameForBookRun(language: "xx",
                                                             documentIds: ["doc-1"]))
        let chapter = EditionCastPrompt(ask: .nameForRun(language: "xx", docId: "doc-1"))
        XCTAssertNotEqual(book.id, chapter.id)
    }

}

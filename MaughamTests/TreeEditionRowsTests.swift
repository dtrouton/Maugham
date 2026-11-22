import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The Editions rows** (shell p1 Task 3): one per language, the source
/// first, and none until publishing is initialised or a translation exists.
@MainActor
final class TreeEditionRowsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        await waitOut(0.05)
        windows.removeAll()
        for store in documentStores { await store.close() }
        documentStores.removeAll()
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

    // MARK: - Add Language (shell p4 Task 7)

    /// **Adding a language is the Editions header's `+`**, drawn where
    /// Research's and the Palette's are — every `+` in the tree at one x —
    /// and the act it opens starts the edition, named, over the store's
    /// current editions: a second Add of the same language is a sentence,
    /// never a silent rename.
    func test_addLanguageIsTheEditionsPlus() async throws {
        let store = try await novel()
        let documentStore = try await DocumentStore.open(url: store.url)
        documentStores.append(documentStore)
        store.documentStore = documentStore
        XCTAssertTrue(EditionCastVerbs.mayAddLanguage(documentStore: documentStore),
                      "premise: the book's own author may add an edition")

        // Mounted: three `+` menus — Research's header, the Palette row's and
        // the Editions header's — sharing one x.
        var subject = WindowSubject.book
        let window = TestWindow.mount(
            AnyView(TreeHostFixture.binder(
                store: store, subject: Binding(get: { subject }, set: { subject = $0 }),
                treeState: BinderTreeSectionsState())),
            size: CGSize(width: 320, height: 700), as: SilentTestWindow.self)
        windows.append(window)
        await pumpUntil(deadline: 5) { self.plusMenus(in: window).count == 3 }
        let pluses = plusMenus(in: window)
        XCTAssertEqual(pluses.count, 3, "Research's, the Palette's and the Editions' `+`: \(pluses)")
        let xs = pluses.map(\.midX)
        XCTAssertLessThanOrEqual((xs.max() ?? 0) - (xs.min() ?? 0), 0.5,
                                 "the tree's `+` menus sit at one x: \(pluses)")

        // The act: a new edition, its translator named.
        let added = await EditionCastVerbs.addLanguage(
            answer: EditionCastAnswer(language: "PT-BR ", name: "Ana"),
            store: store, documentStore: documentStore)
        XCTAssertEqual(added, .added(language: "pt-br"))
        XCTAssertEqual(TreeEditionRows.languages(store: store), ["en", "pt-br"])
        XCTAssertEqual(EditionStatus.translatorName(for: "pt-br", in: store.manifest), "Ana")

        let again = await EditionCastVerbs.addLanguage(
            answer: EditionCastAnswer(language: "pt-br", name: "Somebody Else"),
            store: store, documentStore: documentStore)
        XCTAssertEqual(again, .refused(EditionCastCopy.alreadyAnEdition(language: "pt-br")))
        XCTAssertEqual(EditionStatus.translatorName(for: "pt-br", in: store.manifest), "Ana",
                       "a second Add renames nobody")
        let source = await EditionCastVerbs.addLanguage(
            answer: EditionCastAnswer(language: "en", name: "Nobody"),
            store: store, documentStore: documentStore)
        XCTAssertEqual(source, .refused(EditionCastCopy.alreadyAnEdition(language: "en")),
                       "the Source is an edition too")
        let bad = await EditionCastVerbs.addLanguage(
            answer: EditionCastAnswer(language: "not a tag", name: "X"),
            store: store, documentStore: documentStore)
        XCTAssertEqual(bad, .refused(EditionCastCopy.unusableTag("not a tag")))

        // A proposed brief's Add opens the sheet on its language.
        XCTAssertEqual(EditionCastVerbs.addPrompt(proposing: "it").proposedTag, "it")
        XCTAssertEqual(EditionCastVerbs.addPrompt().proposedTag, "")
        var received: [Notification] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: capture-only observer inspecting the exact scoped Notification Add Language posts
            forName: .maughamAddLanguage, object: nil, queue: nil) { received.append($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        MaughamEvent.postAddLanguage()
        MaughamEvent.postAddLanguage(proposing: "it")
        XCTAssertEqual(received.map { $0.userInfo?[MaughamEvent.proposedLanguageKey] as? String }, [nil, "it"])
        XCTAssertEqual(received.first?.userInfo?[MaughamEvent.scopeKindKey] as? String,
                       EventScope.keyWindow.kindString)
    }

    /// **Every verb the Department desk offered has one home, or is named as
    /// gone with its reason** (shell p4 Task 7's census). Each home is a code
    /// token in a production file; the desk's verb list is closed, so a verb
    /// that loses its home, or a home that is renamed away, goes red here.
    func test_everyDeskVerbHasAHome() throws {
        // The desk's verbs, by the titles it drew (`DepartmentDesk`,
        // `DepartmentDesignRow`, `DepartmentRunState`, `DepartmentCompileState`).
        let deskVerbs: Set<String> = [
            "Add Language…", "Rename <translator>…", "Rename <designer>…", "Edition Brief",
            "Proposed (a brief's badge)", "Run", "Run Whole Book", "Cancel (round)", "Show (round)",
            "Run (design)", "Request Changes", "Cancel (design)", "Show (design)",
            "Compile…", "Cancel Compile", "Show Problems", "Imprint",
        ]
        let homes: [(verb: String, file: String, token: String)] = [
            ("Add Language…", "Maugham/Views/TreeEditionRows.swift", "SwiftUI.Menu { addLanguageItem }"),
            ("Rename <translator>…", "Maugham/Views/Brief/BriefEditionView.swift",
             "castPrompt = EditionCastVerbs.renamePrompt(language: language, in: store.manifest)"),
            ("Rename <designer>…", "Maugham/Views/Brief/BriefEditionView.swift",
             "castPrompt = EditionCastVerbs.designerPrompt(store: store)"),
            ("Edition Brief", "Maugham/Views/Brief/BriefEditionView.swift",
             "kind: .editionBrief(language), subject: .project)"),
            ("Proposed (a brief's badge)", "Maugham/Views/Brief/BriefEditionView.swift",
             "EditionCastVerbs.proposalsWithoutAnEdition(proposals, editions: editions)"),
            ("Run Whole Book", "Maugham/Views/Resolve/ResolveEditionItems.swift",
             "Button(TranslationRunState.runBookTitle) { runBook() }"),
            ("Cancel (round)", "Maugham/Views/Resolve/ResolveEditionItems.swift",
             "Button(TranslationRunState.cancelTitle) { verbs.cancelRound() }"),
            ("Show (round)", "Maugham/Views/Resolve/ResolveEditionItems.swift",
             "Button(ResolveEditionItems.openTheReportTitle) { onShowRound(round) }"),
            ("Run (design)", "Maugham/Views/Resolve/ResolveEditionItems.swift", "Button(DesignRoundState.runTitle) {"),
            ("Request Changes", "Maugham/Views/Resolve/ResolveEditionItems.swift",
             "Button(DesignRoundState.requestChangesTitle) {"),
            ("Cancel (design)", "Maugham/Views/Resolve/ResolveEditionItems.swift",
             "Button(TranslationRunState.cancelTitle) { verbs.cancelDesign() }"),
            ("Show (design)", "Maugham/Views/Resolve/ResolveEditionItems.swift",
             "Button(DesignRoundState.showTitle) { onShowProposal(newest) }"),
            ("Compile…", "Maugham/Views/Publish/PublishPreviewCentre.swift", "Button(CompileBarCopy.compileTitle) {"),
            ("Cancel Compile", "Maugham/Views/Publish/PublishPreviewCentre.swift",
             ".accessibilityLabel(CompileBarCopy.cancelCompileLabel)"),
            ("Show Problems", "Maugham/Views/Publish/PublishPreviewCentre.swift",
             "Button(CompileRunState.showProblemsTitle) { showProblems() }"),
            ("Imprint", "Maugham/Views/Publish/PublishPreviewCentre.swift", "Picker(CompileBarCopy.imprintLabel,"),
        ]
        let gone: [String: String] = [
            // Plan 4 Task 9 builds a one-chapter run on the piece read in a
            // language; until then a chapter is run by Run Whole Book.
            "Run": "a one-chapter run in a language is plan 4 Task 9's, on the piece read in that language",
        ]
        XCTAssertEqual(Set(homes.map(\.verb)).union(gone.keys), deskVerbs,
                       "every desk verb has a home or a reason it is gone")
        XCTAssertTrue(Set(homes.map(\.verb)).isDisjoint(with: gone.keys))
        var lost: [String] = []
        for home in homes {
            let code = SourceScan.codeLines(of: try SourceTree.read(home.file))
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            if !code.contains(home.token) { lost.append("\(home.verb): \(home.file) lacks \(home.token)") }
        }
        XCTAssertEqual(lost, [], "a desk verb lost its home:\n" + lost.joined(separator: "\n"))
        // The desk itself is gone.
        let views = try SourceTree.sources(under: "Maugham").map { ($0.path as NSString).lastPathComponent }
        XCTAssertFalse(views.contains { $0.hasPrefix("DepartmentPane") }, "the desk's files are gone")
    }

    /// The tree's `+` menus, in window coordinates.
    private func plusMenus(in window: NSWindow) -> [CGRect] {
        guard let content = window.contentView else { return [] }
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        return all(content)
            .filter { String(describing: type(of: $0)).contains("SwiftUIPopupButton") && !$0.isHiddenOrHasHiddenAncestor }
            .map { $0.convert($0.bounds, to: content) }
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

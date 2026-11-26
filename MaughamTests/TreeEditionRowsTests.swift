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

        // Mounted: the Editions header's `+` is one plain button (its glyph's
        // x beside Research's is `TreeTopLevelAlignmentTests`').
        var subject = WindowSubject.book
        let window = TestWindow.mount(
            AnyView(TreeHostFixture.binder(
                store: store, subject: Binding(get: { subject }, set: { subject = $0 }),
                treeState: BinderTreeSectionsState())),
            size: CGSize(width: 320, height: 700), as: SilentTestWindow.self)
        windows.append(window)
        await pumpUntil(deadline: 5) { self.plusMenus(in: window).count == 2 }
        XCTAssertEqual(plusMenus(in: window).count, 2,
                       "Research's and the Palette's `+` are menus; Editions' is a plain button")
        let editions = try XCTUnwrap(drawnHeaders(in: window).last, "premise: the Editions header is drawn")
        XCTAssertTrue(try trailingInk(in: editions, window: window), "the Editions header draws its `+`")

        // The act: a new edition, its translator named.
        let added = await EditionCastVerbs.addLanguage(
            answer: EditionCastAnswer(language: "PT-BR ", name: "Ana"),
            store: store, documentStore: documentStore)
        XCTAssertEqual(added, .added(language: "pt-br", warning: nil))
        XCTAssertEqual(TreeEditionRows.languages(store: store), ["en", "pt-br"])
        XCTAssertEqual(EditionStatus.translatorName(for: "pt-br", in: store.manifest), "Ana")

        let again = await EditionCastVerbs.addLanguage(
            answer: EditionCastAnswer(language: "pt-br", name: "Somebody Else"),
            store: store, documentStore: documentStore)
        XCTAssertEqual(again, .existing(language: "pt-br"),
                       "the book has it: the window goes to its Brief, nothing is written")
        XCTAssertEqual(EditionStatus.translatorName(for: "pt-br", in: store.manifest), "Ana",
                       "a second Add renames nobody")
        let source = await EditionCastVerbs.addLanguage(
            answer: EditionCastAnswer(language: "en", name: "Nobody"),
            store: store, documentStore: documentStore)
        XCTAssertEqual(source, .existing(language: "en"),
                       "the Source is an edition too")
        let bad = await EditionCastVerbs.addLanguage(
            answer: EditionCastAnswer(language: "not a tag", name: "X"),
            store: store, documentStore: documentStore)
        XCTAssertEqual(bad, .refused(EditionCastCopy.unusableTag("not a tag")))

        // A proposed brief's Add opens the sheet on its language.
        XCTAssertEqual(EditionCastVerbs.addPrompt(proposing: "it", manifest: store.manifest).proposedTag, "it")
        XCTAssertEqual(EditionCastVerbs.addPrompt(manifest: store.manifest).proposedTag, "")
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

    /// **Remove Edition** (owner's answer 1, 2026-11-22): the exact inverse
    /// of Add for the edition's EXISTENCE — it leaves the tree, the switch and
    /// Add's "existing" check — while every file it ever made stays byte for
    /// byte, and its cast stays named; adding the language again brings it
    /// all back. The Source is never removable; a running round refuses.
    func test_removeEditionHidesItKeepsEverythingAndAddBringsItBack() async throws {
        let store = try await novel()
        let documentStore = try await DocumentStore.open(url: store.url)
        documentStores.append(documentStore)
        store.documentStore = documentStore
        _ = await EditionCastVerbs.addLanguage(
            answer: EditionCastAnswer(language: "es", name: "Ana", reader: "Bea", collator: "Cy"),
            store: store, documentStore: documentStore)
        let docId = try XCTUnwrap(EditionStatus.manuscriptDocumentIds(in: store.manifest).first)
        // What the edition made: a translation file, a round ledger.
        let translation = TranslationStore.directoryURL(in: store.url)
            .appendingPathComponent("\(docId).es.dev1.jsonl")
        let ledger = TranslationRoundStore.fileURL(language: "es", in: store.url)
        for url in [translation, ledger] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("kept \(url.lastPathComponent)".utf8).write(to: url)
        }
        func kept() throws -> [Data] { try [translation, ledger].map { try Data(contentsOf: $0) } }
        let before = try kept()
        XCTAssertEqual(TreeEditionRows.languages(store: store), ["en", "es"])

        let source = await EditionCastVerbs.removeEdition(language: "en", store: store,
                                                          documentStore: documentStore, busy: { _ in nil })
        XCTAssertEqual(source, .refused(EditionCastCopy.sourceIsNotRemovable), "the Source is the book")
        let running = await EditionCastVerbs.removeEdition(language: "es", store: store,
                                                           documentStore: documentStore, busy: { _ in "busy" })
        XCTAssertEqual(running, .refused("busy"), "a round or compile running for it refuses")
        XCTAssertEqual(TreeEditionRows.languages(store: store), ["en", "es"], "and nothing moved")

        let removed = await EditionCastVerbs.removeEdition(language: "ES", store: store,
                                                           documentStore: documentStore, busy: { _ in nil })
        XCTAssertEqual(removed, .removed(language: "es"))
        XCTAssertEqual(TreeEditionRows.languages(store: store), ["en"], "hidden, though its files remain")
        XCTAssertTrue(store.manifest.isEditionRemoved("es"))
        XCTAssertEqual(try kept(), before, "its translations and rounds stay byte for byte")
        XCTAssertEqual(EditionStatus.translatorName(for: "es", in: store.manifest), "Ana", "its cast stays")
        XCTAssertTrue(EditionCastVerbs.restores("es", manifest: store.manifest))
        XCTAssertFalse(EditionCastVerbs.alreadyAnEdition("es", editions: TreeEditionRows.languages(store: store),
                                                         manifest: store.manifest),
                       "a removed edition is not one Add stops at")
        let reading = ReadingLanguageModel()
        reading.adopt(.init(languagesByDocId: [docId: ["es", "sr"]]))
        reading.removedEditions = store.manifest.removedEditions
        XCTAssertEqual(reading.languages(for: docId), ["sr"], "no piece is read in a removed edition")
        // The sheet, asked for `es` again, offers the cast it had (IM1).
        let offered = EditionCastVerbs.addPrompt(manifest: store.manifest).offered(for: "es")
        XCTAssertEqual(offered, .init(name: "Ana", reader: "Bea", collator: "Cy"),
                       "a removed edition's own cast, never the presets")
        let again = await EditionCastVerbs.removeEdition(language: "es", store: store,
                                                         documentStore: documentStore, busy: { _ in nil })
        XCTAssertEqual(again, .refused(EditionCastCopy.noSuchEdition(language: "es")))

        // **Closing review IM1**: added again with OTHER names, it comes back
        // as it was — nobody is renamed — and says so.
        let back = await EditionCastVerbs.addLanguage(
            answer: EditionCastAnswer(language: "es", name: "Cortázar", reader: "Other", collator: "Else"),
            store: store, documentStore: documentStore)
        XCTAssertEqual(back, .restored(language: "es"))
        XCTAssertEqual(EditionCastVerbs.landing(back, proposed: false).alert,
                       EditionCastCopy.restoredLine(language: "es"))
        XCTAssertEqual(EditionStatus.translatorName(for: "es", in: store.manifest), "Ana", "the stored cast survives")
        XCTAssertEqual(EditionStatus.readerName(for: "es", in: store.manifest), "Bea")
        XCTAssertEqual(EditionStatus.collatorName(for: "es", in: store.manifest), "Cy")
        XCTAssertEqual(TreeEditionRows.languages(store: store), ["en", "es"], "adding it again brings it back")
        XCTAssertFalse(store.manifest.isEditionRemoved("es"))
        XCTAssertNil(store.manifest.removedEditions, "no tag left behind")
        XCTAssertEqual(try kept(), before, "with everything it had")
    }

    /// **Remove Edition's rules and doors**, pure and censused (the desk
    /// capability census's neighbour): what stops it, which edition the menu
    /// item is about, where a window lands when its edition leaves the list,
    /// and each door it is reached by.
    func test_removeEditionsRulesAndDoors() throws {
        let busyRound = EditionCastVerbs.removalBusy(language: "es", session: .busy(language: "ES"), compile: .idle)
        XCTAssertEqual(busyRound, EditionCastCopy.removeWhileTranslating(language: "es"))
        XCTAssertNotNil(EditionCastVerbs.removalBusy(language: "es", session: .busy(language: nil), compile: .idle),
                        "a round whose language is not known yet refuses too")
        XCTAssertNil(EditionCastVerbs.removalBusy(language: "es", session: .busy(language: "sr"), compile: .idle))
        XCTAssertEqual(EditionCastVerbs.removalBusy(
            language: "es", session: .free,
            compile: .running(format: .pdf, languages: ["en", "es"], imprint: nil)),
                       EditionCastCopy.removeWhileCompiling(language: "es"))
        XCTAssertNil(EditionCastVerbs.removalBusy(
            language: "es", session: .free, compile: .running(format: .pdf, languages: ["en"], imprint: nil)))
        XCTAssertNil(EditionCastVerbs.removalBusy(language: "es", session: .free, compile: .idle))

        XCTAssertEqual(EditionCastVerbs.removable("ES", editions: ["en", "es"]), "es")
        XCTAssertNil(EditionCastVerbs.removable("en", editions: ["en", "es"]), "never the Source")
        XCTAssertNil(EditionCastVerbs.removable("sr", editions: ["en", "es"]))

        let rows = [TreeEditionRows.Row(language: "en", title: "English", isSource: true),
                    TreeEditionRows.Row(language: "es", title: "Spanish", isSource: false)]
        XCTAssertTrue(TreeEditionRows.offersRemove(rows[1], mayAddLanguage: true))
        XCTAssertFalse(TreeEditionRows.offersRemove(rows[0], mayAddLanguage: true), "the Source's menu has none")
        XCTAssertFalse(TreeEditionRows.offersRemove(rows[1], mayAddLanguage: false), "hidden where it may not")
        let onSpanish = WindowSubject(open: .edition(language: "es"), faces: .edition(language: "es"))
        XCTAssertEqual(EditionWiring.editionToRemove(subject: onSpanish, editions: rows), "es")
        XCTAssertNil(EditionWiring.editionToRemove(
            subject: WindowSubject(open: .edition(language: "en"), faces: .edition(language: "en")), editions: rows))
        XCTAssertNil(EditionWiring.editionToRemove(subject: .book, editions: rows))

        // Where a window lands when its edition leaves the list: the Book.
        let landed = try XCTUnwrap(EditionWiring.landing(subject: onSpanish, before: rows, after: [rows[0]]))
        XCTAssertEqual(landed.open, .project)
        XCTAssertEqual(landed.faces, .project)
        var facesOnly = WindowSubject(open: .item("c1"), faces: .item("c1"))
        facesOnly.faces = .edition(language: "es")
        XCTAssertEqual(EditionWiring.landing(subject: facesOnly, before: rows, after: [rows[0]])?.faces, .project)
        XCTAssertNil(EditionWiring.landing(subject: onSpanish, before: [], after: rows), "the first read moves nothing")
        XCTAssertNil(EditionWiring.landing(subject: .book, before: rows, after: [rows[0]]))

        XCTAssertEqual(EditionCastVerbs.removeEditionTitle(language: "es"),
                       "Remove \(LanguageName.title("es")) Edition\u{2026}", "rows 13 and 68 say what goes")
        XCTAssertEqual(EditionCastVerbs.removeEditionTitle(language: nil), "Remove Edition\u{2026}")
        XCTAssertEqual(EditionCastCopy.removeEditionTitle(language: "es"),
                       "Remove the \(LanguageName.title("es")) edition?")
        XCTAssertEqual(EditionCastCopy.removeEditionMessage(language: "es"),
                       "Its translations stay in the project and come back if you add \(LanguageName.title("es")) again.")

        func code(_ file: String) throws -> String {
            SourceScan.codeLines(of: try SourceTree.read(file))
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        let doors: [(String, String)] = [
            ("Maugham/Views/TreeEditionRows.swift",
             "if Self.offersRemove(row, mayAddLanguage: mayAddLanguage) { Button(EditionCastVerbs.removeEditionTitle(language: row.language)) { MaughamEvent.postRemoveEdition(row.language) }"),
            ("Maugham/MaughamApp.swift", "Button(EditionCastVerbs.removeEditionTitle(language: removable)) {"),
            ("Maugham/MaughamApp.swift", "if let removable { MaughamEvent.postRemoveEdition(removable) } } .disabled(!enabled(removable != nil))"),
            ("Maugham/Views/Publish/EditionWiring.swift", "guard let documentStore, EditionCastVerbs.mayAddLanguage(documentStore: documentStore),"),
            ("Maugham/Views/Publish/EditionWiring.swift", ".alert(EditionCastCopy.removeEditionTitle(language: removing ?? \"\"), isPresented: Binding("),
            ("Maugham/Views/Publish/EditionWiring.swift", "if case .refused(let sentence) = await EditionCastVerbs.removeEdition("),
            ("Maugham/Views/Publish/EditionWiring.swift",
             "if let landed = Self.landing(subject: subject, before: old, after: new) { subject = landed }"),
            ("Maugham/Views/Publish/EditionCastVerbs.swift",
             "let posture = await documentStore.settledPosture(forDocId: DocumentClass.projectStreamDocId) guard StatementSurfaceVerbs.offered(under: posture) else { return .refused(EditionCastCopy.mayNotRemove) }"),
            ("Maugham/Views/ProjectWindow.swift", "busy: { removalBusy($0) }))"),
            ("Maugham/Views/ReadingLanguageModifier.swift", "reading.removedEditions = removed"),
        ]
        for (file, token) in doors {
            XCTAssertTrue(try code(file).contains(token), "\(file) lost: \(token)")
        }
    }

    /// **Where Add Language lands** (fix round): a new edition selected on
    /// To resolve (Run Whole Book is next), or on its Brief when a proposed
    /// brief brought the writer (it waits there); an edition the book has,
    /// selected on its Brief with no alert; a refusal, said and nothing moved.
    func test_addLanguageLandsWhereTheNextStepIs() {
        XCTAssertEqual(EditionCastVerbs.landing(.added(language: "it", warning: nil), proposed: false),
                       .init(select: .edition(language: "it"), position: .resolve, alert: nil))
        XCTAssertEqual(EditionCastVerbs.landing(.added(language: "it", warning: nil), proposed: true),
                       .init(select: .edition(language: "it"), position: .brief, alert: nil))
        XCTAssertEqual(EditionCastVerbs.landing(.existing(language: "es"), proposed: false),
                       .init(select: .edition(language: "es"), position: .brief, alert: nil))
        XCTAssertEqual(EditionCastVerbs.landing(.added(language: "it", warning: "w"), proposed: false).alert, "w",
                       "a half-named cast is said")
        XCTAssertEqual(EditionCastVerbs.landing(.refused("no"), proposed: true),
                       .init(select: nil, position: nil, alert: "no"))
    }

    /// **A half-failed Add says what was and was not named** (review M1):
    /// the translator lands, the reader's name is refused, and the outcome
    /// says so rather than reporting success.
    func test_aHalfNamedCastIsSaidNotHidden() async throws {
        let store = try await novel()
        let documentStore = try await DocumentStore.open(url: store.url)
        documentStores.append(documentStore)
        store.documentStore = documentStore
        let added = await EditionCastVerbs.addLanguage(
            answer: EditionCastAnswer(language: "xx", name: "Ana", reader: "   ", collator: "Bea"),
            store: store, documentStore: documentStore)
        XCTAssertEqual(added, .added(language: "xx",
                                     warning: EditionCastCopy.partlyNamed(language: "xx", missing: ["reader"])))
        XCTAssertEqual(EditionStatus.translatorName(for: "xx", in: store.manifest), "Ana")
        XCTAssertEqual(EditionStatus.collatorName(for: "xx", in: store.manifest), "Bea",
                       "what could be named was named")
        XCTAssertTrue(TreeEditionRows.languages(store: store).contains("xx"), "the edition stands")
    }

    /// **A book with no editions still offers its first** (the desk's
    /// `test_theAddLanguageDoorIsDrawnWithNoEditionsAtAll`, re-made on the
    /// tree): the Editions header and its `+` are drawn with no rows, and a
    /// pending proposed brief lists the Source, whose Brief offers to add it.
    func test_theAddLanguageDoorIsDrawnWithNoEditionsAtAll() async throws {
        XCTAssertTrue(TreeEditionRows.drawsSection(rows: [], mayAddLanguage: true))
        XCTAssertFalse(TreeEditionRows.drawsSection(rows: [], mayAddLanguage: false),
                       "a reviewer with no editions sees no empty section")
        XCTAssertEqual(TreeEditionRows.languages(source: "en", publishingInitialised: false,
                                                 translated: [], briefProposed: true), ["en"])

        let store = try await novel()
        try FileManager.default.removeItem(at: store.url.appendingPathComponent(".maugham/publish"))
        XCTAssertEqual(TreeEditionRows.languages(store: store), [], "premise: no editions at all")
        _ = try StatementProposalStore(projectURL: store.url).stage(.init(
            kind: .editionBrief("it"), markdown: "x", rationale: nil, proposedAt: Date(), author: "Claude"))
        XCTAssertEqual(TreeEditionRows.languages(store: store), ["en"],
                       "Claude's proposal for a new edition lists the Source, where it shows")

        // Mounted with no rows: the header is drawn, with ink at its
        // trailing edge (the `+`); refused, no header at all. (A list
        // header's controls are not in the accessibility tree this host
        // reads, so the header and its glyph are measured.)
        for (mayAdd, expected) in [(true, 1), (false, 0)] {
            let window = TestWindow.mount(
                AnyView(List { TreeEditionRows(rows: [], mayAddLanguage: mayAdd) }.listStyle(.sidebar)),
                size: CGSize(width: 320, height: 200), as: SilentTestWindow.self)
            windows.append(window)
            await pumpUntil(deadline: 3) { self.drawnHeaders(in: window).count == expected }
            let headers = drawnHeaders(in: window)
            XCTAssertEqual(headers.count, expected, "mayAddLanguage \(mayAdd)")
            if let header = headers.first {
                XCTAssertTrue(try trailingInk(in: header, window: window),
                              "the header draws its `+` at its trailing edge")
            }
        }
        // File ▸ Add Language… is the keyboard's way to the same sheet.
        let app = SourceScan.codeLines(of: try SourceTree.read("Maugham/MaughamApp.swift"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(app.contains("@FocusedValue(\\.mayAddLanguage) private var mayAdd"))
        XCTAssertTrue(app.contains(
            "Button(EditionCastVerbs.addLanguageTitle) { MaughamEvent.postAddLanguage() } .disabled(!enabled(mayAdd == true))"))
    }

    /// **Every capability the Department desk had — what it offered, showed
    /// or kept — has one home, or is named as gone with its reason** (shell
    /// p4 Task 7's census, widened from verbs to capabilities in the fix
    /// round: one row per line of the review's capability table). Each home
    /// is a code token in a production file, so a later deletion of a
    /// display or a state goes red here rather than silently.
    func test_everyDeskCapabilityHasAHome() throws {
        let views = "Maugham/Views/"
        let brief = views + "Brief/BriefEditionView.swift"
        let head = views + "Resolve/ResolveEditionItems.swift"
        let bar = views + "Publish/PublishPreviewCentre.swift"
        let rows = views + "TreeEditionRows.swift"
        let status = views + "Publish/EditionStatusRows.swift"
        let homes: [(capability: String, file: String, token: String)] = [
            ("imprint picker", bar, "Picker(CompileBarCopy.imprintLabel,"),
            ("Compile…", bar, "Button(CompileBarCopy.compileTitle) {"),
            ("the compile's status line", bar, "if let status = compileRun.statusLine {"),
            ("Show Problems", bar, "Button(CompileRunState.showProblemsTitle) { showProblems() }"),
            ("Cancel Compile, kept through a refusal", bar, ".accessibilityLabel(CompileBarCopy.cancelCompileLabel)"),
            ("the sheet never offers the book's language twice", bar,
             "var others = editions.dropFirst().filter { $0.caseInsensitiveCompare(book) != .orderedSame }"),
            ("the designer's name", brief, "let name = store.designerRole().effectiveName"),
            ("rename the designer", brief, "castPrompt = EditionCastVerbs.designerPrompt(store: store)"),
            ("a design proposal waiting", head, "if let pending = read.pendingProposal { items.append(.designProposal(pending)) }"),
            ("Show (design)", head, "Button(DesignRoundState.showTitle) { onShowProposal(newest) }"),
            ("the design's latest line", head, "Text(design.latestLine)"),
            ("the design's status line", head, "if let status = design.statusLine {"),
            ("Run (design)", head, "Button(DesignRoundState.runTitle) {"),
            ("Request Changes", head, "Button(DesignRoundState.requestChangesTitle) {"),
            ("Cancel (design)", head, "Button(TranslationRunState.cancelTitle) { verbs.cancelDesign() }"),
            ("a refused verb's notice", head, ".accessibilityIdentifier(\"resolve.edition.notice\")"),
            ("a row per edition", rows, "ForEach(rows) { row in"),
            ("the translator's name", brief, "(\"Translator\", EditionStatus.translatorName(for: language, in: manifest))"),
            ("rename the translator, reader, collator", brief,
             "castPrompt = EditionCastVerbs.renamePrompt(language: language, in: store.manifest)"),
            ("coverage (fresh, stale, missing)", status, "\"\\(t.fresh) fresh \\u{00B7} \\(t.stale) stale"),
            ("open queries", views + "Resolve/ResolveFilter.swift", "if annotation.language != nil { return .questions }"),
            ("the \"Proposed\" mark on an edition", rows,
             "if ResolvePresence.proposalMark(.edition(row.language), in: presence) {"),
            ("the edition brief", brief, "kind: .editionBrief(language), subject: .project)"),
            ("Run Whole Book", head, "Button(TranslationRunState.runBookTitle) { runBook() }"),
            ("what Run Whole Book costs", head, "let answer = await TranslationPreflight.editionBudget("),
            ("the figure only while idle", head, "TranslationPreflight.refillsBudgets(pipeline: roster?.pipeline.status ?? .idle)"),
            ("Cancel (round)", head, "Button(TranslationRunState.cancelTitle) { verbs.cancelRound() }"),
            ("the running round's leg", head, "if run.isRunning, let status = run.statusLine {"),
            ("why the newest round stopped", head, "stoppedLine: TranslationRunState.roundLine(newest, now: now)"),
            ("Show (round)", head, "Button(ResolveEditionItems.openTheReportTitle) { onShowRound(stopped) }"),
            ("the notes-per-round trend", status, "trend: trends[row.id] ?? [])"),
            ("chapters that would not read", status,
             "unreadable.map { (EditionStatusRows.couldNotRead($0.title), $0.reason) }"),
            ("Add Language…, with no editions too", rows,
             "static func drawsSection(rows: [Row], mayAddLanguage: Bool) -> Bool {"),
            ("Add Language… from the keyboard", "Maugham/MaughamApp.swift", "Button(EditionCastVerbs.addLanguageTitle) { MaughamEvent.postAddLanguage() }"),
            ("the cast sheet", views + "Publish/EditionWiring.swift", "EditionCastSheet("),
            ("adding an edition the book has", views + "Publish/EditionCastVerbs.swift", "return .existing(language:"),
            ("a proposed brief with no edition", brief,
             "EditionCastVerbs.proposalsWithoutAnEdition(proposals, editions: editions)"),
            ("re-reads on a proposal", views + "Resolve/ResolvePresence.swift",
             ".onProjectEvent(.maughamStatementProposalsChanged, url: url, window: window) { _ in"),
            ("⌘⌥K", "Maugham/MaughamApp.swift", "FocusedEditionResolveButton(inFront: inFront)"),
            // A one-chapter run in a language: the piece read in it (shell p4 Task 9).
            ("Run (one chapter)", views + "Resolve/ResolvePieceInLanguage.swift",
             "Button(TranslationRunState.runTitle(pieceWord)) { runThisPiece() }"),
            ("the open chapter's last run report (lastRun)", views + "Resolve/ResolvePieceInLanguage.swift",
             "lastRun: roster?.translationRuns.run(docId: docId, language: language),"),
            ("\"Open a chapter to run it\"", views + "Resolve/ResolvePieceInLanguage.swift",
             "return .open(hasItemsToAnswer ? \"Open this \\(noun) to answer its questions\" : openToRunLine(noun: noun))"),
        ]
        let gone: [String: String] = [
            "the book's title over the desk": "the edition is the subject; the tree and the centre name it",
            "the \"No imprints yet\" line": "the picker is hidden with none; where an imprint comes from is plan 5's guide",
            "\"No translations yet.\"": "the Editions header and its `+` stand in a book with none",
            "one notice slot for the whole desk": "each surface says its own (Brief, the head, the add sheet's alert)",
        ]
        XCTAssertEqual(homes.count + gone.count, 46,
                       "one row per line of the capability table (review of 6a510aaa)")
        XCTAssertEqual(Set(homes.map(\.capability)).count, homes.count, "a capability is listed once")
        XCTAssertTrue(Set(homes.map(\.capability)).isDisjoint(with: gone.keys))
        var lost: [String] = []
        var sources: [String: String] = [:]
        for home in homes {
            if sources[home.file] == nil {
                sources[home.file] = SourceScan.codeLines(of: try SourceTree.read(home.file))
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            }
            if !(sources[home.file] ?? "").contains(home.token) {
                lost.append("\(home.capability): \(home.file) lacks \(home.token)")
            }
        }
        XCTAssertEqual(lost, [], "a desk capability lost its home:\n" + lost.joined(separator: "\n"))
        let files = try SourceTree.sources(under: "Maugham").map { ($0.path as NSString).lastPathComponent }
        XCTAssertFalse(files.contains { $0.hasPrefix("DepartmentPane") }, "the desk's files are gone")
    }

    /// The list headers drawn, top to bottom (a headerless section mounts
    /// one zero points tall).
    private func drawnHeaders(in window: NSWindow) -> [NSView] {
        guard let content = window.contentView else { return [] }
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        return all(content)
            .filter { String(describing: type(of: $0)).contains("ListTableHeaderView") && $0.frame.height > 1 }
            .sorted { $0.convert($0.bounds, to: content).minY < $1.convert($1.bounds, to: content).minY }
    }

    /// Whether `header` draws ink in its trailing 44 points — the `+`.
    private func trailingInk(in header: NSView, window: NSWindow) throws -> Bool {
        let content = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        let frame = header.convert(header.bounds, to: content)
        func py(_ y: CGFloat) -> Int { Int(((content.isFlipped ? y : content.bounds.height - y) * scale).rounded()) }
        let y0 = min(py(frame.minY), py(frame.maxY)) + 1, y1 = max(py(frame.minY), py(frame.maxY)) - 1
        guard y1 > y0, let bg = rep.colorAt(x: 2, y: (y0 + y1) / 2)?.usingColorSpace(.deviceRGB) else { return false }
        for x in Int((frame.maxX - 44) * scale)..<Int(frame.maxX * scale) {
            for y in y0..<y1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(c.redComponent - bg.redComponent) > 0.06 || abs(c.blueComponent - bg.blueComponent) > 0.06 {
                    return true
                }
            }
        }
        return false
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

import XCTest
import AppKit
import SwiftUI
@testable import Maugham
@testable import MaughamCore

/// **A figure whose source data changed is in To resolve** (shell p5 Task 3;
/// ADR 0036's last item kind). The tree's own figure cards say which figures
/// changed (`FigureCardModel.changed`) and the listing where the book places
/// them; To resolve lists one item per figure per placing piece, at its line's
/// paragraph, an unused figure on the Book; the tree marks the placing
/// chapter from the same read, off the window's presence walk, which it never
/// moves. Pure functions, the presence reader driven as its watch drives it,
/// the tree state filled through its own card cache, censuses of the delivery
/// path, and one mounted read of the row. Nothing is pressed (tripwire 33).
///
/// Paragraph ids are 4-char from `ParagraphID`'s alphabet (tripwire 8).
@MainActor
final class ResolveFigureSourceTests: XCTestCase {
    override class func setUp() { super.setUp(); FontWarmup.ensure() }

    // MARK: - Builders

    private static let cash = "fig-0a1b2c3d"
    private static let tax = "fig-1a1b2c3d"
    private static let spare = "fig-2a1b2c3d"

    private static func row(_ id: String, _ name: String, caption: String = "", number: String,
                            uses: [FigureListing.Use] = []) -> FigureListing.Row {
        FigureListing.Row(figureId: id, kind: .table, name: name, caption: caption, number: number,
                          usedIn: uses, referencedFrom: [], pieceOfLine: uses.first?.docId)
    }

    private static func use(_ docId: String, _ line: Int) -> FigureListing.Use {
        FigureListing.Use(docId: docId, lineIndex: line)
    }

    private static func change(_ id: String, number: String = "Table 2", title: String = "Cash",
                               pins: Bool = true, placements: [FigureListing.Use]) -> ResolveFigureChange {
        ResolveFigureChange(figureId: id, number: number, title: title, pinsChanged: pins,
                            placements: placements)
    }

    /// ¶aa11 "Opening words." is line 0; the blank line 1; ¶bb22, the
    /// figure's line, line 2; ¶cc33 line 4.
    private static let sequence = ["aa11", "bb22", "cc33"]
    private static let text = ["aa11": "Opening words.", "bb22": "![Cash](../figures/cash.csv)",
                               "cc33": "After the table."]

    private func gather(_ scope: ResolveScope, _ changes: [ResolveFigureChange],
                        sequences: [String: [String]] = ["doc-a": sequence]) -> ResolveSnapshot {
        ResolveReader.gather(
            scope: scope,
            annotations: ProjectAnnotationsSnapshot(annotations: [], unreadableDocIds: [], sequences: sequences),
            tasks: [], figureOwners: [:], figureChanges: changes, liveFindings: nil,
            paragraphs: { docId in docId == "doc-a" ? Self.text : [:] })
    }

    // MARK: - Where it lists

    /// **On the chapter that places it, under the paragraph holding the
    /// line** — the sentence names the figure as the tree does; at a Book
    /// scope it sits in the piece's group (no text is read for it there),
    /// one item per placing piece however many lines a piece holds.
    func test_aChangedSourceListsUnderThePlacingParagraph() {
        let change = Self.change(Self.cash, placements: [Self.use("doc-a", 2), Self.use("doc-b", 0)])
        let piece = gather(.piece(docId: "doc-a", includesBookLevel: false), [change])
        XCTAssertEqual(piece.items, [.figureSourceChanged(figureId: Self.cash, docId: "doc-a", paragraphId: "bb22")])
        let groups = ResolveGrouping.groups(piece, scope: .piece(docId: "doc-a", includesBookLevel: false),
                                            structure: [], sceneIndex: nil, sceneTitles: [],
                                            figureNames: [:], projectType: .novel)
        XCTAssertEqual(groups.map(\.key), [.paragraph(docId: "doc-a", paragraphId: "bb22")])
        XCTAssertEqual(groups.first?.title, "![Cash](../figures/cash.csv)")
        XCTAssertEqual(change.sentence, "Table 2\u{2019}s source data changed")
        XCTAssertEqual(change.detail, "Cash")

        // A Book: each placing piece once, by piece; a Part that holds one.
        let book = gather(.pieces(docIds: ["doc-a", "doc-b"], includesBookLevel: true), [change])
        XCTAssertEqual(book.items.map(\.id), ["figure-source:doc-a/\(Self.cash)", "figure-source:doc-b/\(Self.cash)"])
        XCTAssertEqual(book.items.map(\.paragraphId), [nil, nil], "a Book groups by piece and reads no text for it")
        let part = gather(.pieces(docIds: ["doc-b"], includesBookLevel: false), [change])
        XCTAssertEqual(part.items, [.figureSourceChanged(figureId: Self.cash, docId: "doc-b", paragraphId: nil)])

        // Two lines in one piece: one item there (the listing's first is kept).
        let twice = ResolveFigureChange.of(
            listing: [Self.row(Self.cash, "cash", number: "Table 2",
                               uses: [Self.use("doc-a", 2), Self.use("doc-a", 9), Self.use("doc-b", 0)])],
            card: { _ in FigureCardModel(kind: .table, pinChanged: true) })
        XCTAssertEqual(twice.first?.placements, [Self.use("doc-a", 2), Self.use("doc-b", 0)])

        // The figure's own list holds it too, in the figure's group.
        let own = gather(.figure(id: Self.cash), [change])
        XCTAssertEqual(own.items, [.figureSourceChanged(figureId: Self.cash, docId: Self.cash, paragraphId: nil)])
        // An edition, or a piece read in a language, lists none.
        XCTAssertEqual(gather(.edition(language: "es", isSource: false, docIds: ["doc-a"]), [change]).items, [])
        XCTAssertEqual(gather(.pieceInLanguage(docId: "doc-a", language: "es"), [change]).items, [])
    }

    /// **An unused figure is the Book's**: listed at the Book's scope under
    /// "The book", never in a Part or a chapter; named by its title, since
    /// it has no number.
    func test_anUnusedFigureIsBookLevel() {
        let change = Self.change(Self.spare, number: FigureListing.unusedNumber, title: "spare", placements: [])
        let book = gather(.pieces(docIds: ["doc-a"], includesBookLevel: true), [change])
        XCTAssertEqual(book.items, [.figureSourceChanged(figureId: Self.spare, docId: nil, paragraphId: nil)])
        XCTAssertEqual(book.items.first?.docId, ProjectStore.projectTasksDocId)
        let groups = ResolveGrouping.groups(book, scope: .pieces(docIds: ["doc-a"], includesBookLevel: true),
                                            structure: [], sceneIndex: nil, sceneTitles: [],
                                            figureNames: [:], projectType: .novel)
        XCTAssertEqual(groups.map(\.key), [.bookLevel])
        XCTAssertEqual(gather(.pieces(docIds: ["doc-a"], includesBookLevel: false), [change]).items, [])
        XCTAssertEqual(gather(.piece(docId: "doc-a", includesBookLevel: false), [change]).items, [])
        XCTAssertEqual(change.sentence, "spare\u{2019}s source data changed")
        XCTAssertNil(change.detail)
    }

    /// **The Book head says what the list holds** (fix round 1, I1): an
    /// unused figure's changed source is no to-do, so the head never says
    /// "Book to-dos open" over a list with no to-do; it says its own line. A
    /// placed figure's counts on its piece. Control: a real Book to-do still
    /// says "Book to-dos open".
    func test_theBookHeadNamesAnUnusedFiguresChangeAndNoToDo() {
        let book = ResolveScope.pieces(docIds: ["doc-a"], includesBookLevel: true)
        func lines(_ items: [ResolveItem]) -> [String] {
            ResolveHead.bookLines(ResolveHead.bookCount(items, scope: book, figureOwners: [:]))
        }
        let unused = ResolveItem.figureSourceChanged(figureId: Self.spare, docId: nil, paragraphId: nil)
        XCTAssertEqual(lines([unused]), [ResolveHead.bookFigureSourcesLine(1)])
        XCTAssertFalse(lines([unused]).contains(ResolveHead.bookTodosLine))
        XCTAssertEqual(ResolveHead.bookFigureSourcesLine(1), "A figure no piece uses has changed source data")
        XCTAssertEqual(ResolveHead.bookFigureSourcesLine(2), "2 figures no piece uses have changed source data")
        let other = ResolveItem.figureSourceChanged(figureId: Self.tax, docId: nil, paragraphId: nil)
        XCTAssertEqual(lines([unused, other]), [ResolveHead.bookFigureSourcesLine(2)])
        let placed = ResolveItem.figureSourceChanged(figureId: Self.cash, docId: "doc-a", paragraphId: nil)
        XCTAssertEqual(lines([placed]), ["1 piece has something open"])
        let todo = ResolveItem.todo(WriterTask(
            id: "t1", kind: .paneCreated, anchor: nil, body: "b", status: .open, priority: 0,
            parentTaskId: nil, createdAt: Date(), createdBySession: nil))
        XCTAssertEqual(lines([todo, unused]), [ResolveHead.bookTodosLine, ResolveHead.bookFigureSourcesLine(1)])
    }

    /// **A current pin lists nothing, and the item goes by itself** once the
    /// pin is current again: the cards decide, a parked figure and one with
    /// no card yet say nothing — through the tree's own card cache, as the
    /// window fills it.
    func test_aCurrentPinListsNothing() async {
        let listing = [Self.row(Self.cash, "cash", caption: "Cash at year end", number: "Table 1",
                                uses: [Self.use("doc-a", 2)]),
                       Self.row(Self.tax, "tax", number: "Table 2", uses: [Self.use("doc-a", 6)])]
        // The pure rule: changed, current, parked, no card.
        let cards: [String: FigureCardModel] = [
            Self.cash: FigureCardModel(kind: .table, readsResearch: true, pinChanged: true),
            Self.tax: FigureCardModel(kind: .table, readsResearch: true),
        ]
        XCTAssertEqual(ResolveFigureChange.of(listing: listing, card: { cards[$0] }).map(\.figureId), [Self.cash])
        XCTAssertEqual(ResolveFigureChange.of(listing: listing, card: { _ in
            FigureCardModel(kind: .parked, pinChanged: true) }), [], "a parked figure has no row to resolve")
        XCTAssertEqual(ResolveFigureChange.of(listing: listing, card: { _ in nil }), [], "no card yet")
        let snapshot = ResolveFigureChange.of(listing: listing, card: { _ in
            FigureCardModel(kind: .table, fromResearchSource: true, sourceChanged: true) })
        XCTAssertEqual(snapshot.map(\.pinsChanged), [false, false],
                       "a changed snapshot is listed, with nothing for Compare to show")

        // The tree's state, filled by its own cards: listed, then gone.
        let state = BinderTreeSectionsState()
        let records = [FigureRecord(id: Self.cash, name: "cash", kind: .table, piece: nil, path: "figures/cash.csv"),
                       FigureRecord(id: Self.tax, name: "tax", kind: .table, piece: nil, path: "figures/tax.csv")]
        let table = FigureState(kind: .table, table: FigureTable(rows: 1, columns: 1))
        final class Box { var changed: Set<String> = [] }
        let box = Box()
        box.changed = [Self.cash]
        state.figureCards.onVersionChange = { [weak state] _ in state?.figureCardsChanged() }
        state.figureCards.attach(FigureCardCache.Source(read: {
            FigureCardInputs(records: records, states: [Self.cash: table, Self.tax: table], workbook: nil,
                             pinChanged: box.changed, locale: TableLocale(languageTag: "en-GB"))
        }))
        state.refreshFigureRows(listing: listing)
        await state.figureCards.idle()
        XCTAssertEqual(state.figureSourceChanges.map(\.figureId), [Self.cash])
        XCTAssertEqual(state.figureSourceChanges.first?.title, "Cash at year end", "named as the tree does")
        let listed = gather(.piece(docId: "doc-a", includesBookLevel: false), state.figureSourceChanges)
        XCTAssertEqual(listed.items.map(\.id), ["figure-source:doc-a/\(Self.cash)"])

        box.changed = []
        state.figureCards.invalidate()
        await state.figureCards.idle()
        XCTAssertEqual(state.figureSourceChanges, [], "pinned again: it goes by itself")
        XCTAssertEqual(gather(.piece(docId: "doc-a", includesBookLevel: false), state.figureSourceChanges).items, [])
        state.detachFigureCards()
    }

    // MARK: - Its source, its lifetime, the margin

    /// **Others, durable, never a tick**: no model flagged it and nobody
    /// wrote it, so it sits under Others, no check replaces it, and the
    /// margin's rule (`.checks` / `.pass` only) never ticks its paragraph.
    func test_aFigureSourceItemIsOthersAndNeverTicksTheMargin() {
        let item = ResolveItem.figureSourceChanged(figureId: Self.cash, docId: "doc-a", paragraphId: "bb22")
        XCTAssertEqual(ResolveFilter.source(of: item, localName: "Denver"), .others)
        XCTAssertFalse(item.isReplacedByTheNextCheck)
        XCTAssertNil(ResolvePane.caption(for: item, localName: "Denver"))
        XCTAssertFalse(ResolveHead.hasItemsToAnswer([item], docId: "doc-a"),
                       "it acts through the figure, wherever listed: the piece need not be open")
        let marks = MarginMarks.of(setting: .everythingFlagged, notes: [], owner: { _ in .unknown },
                                   items: [item], selection: [], localName: "Denver", focusMode: false,
                                   readingTranslation: false, reviewRenderIsOn: false)
        XCTAssertEqual(marks.ticks, [], "a figure's source is not a model's flag")
        // Control: a check's strain on the same paragraph does tick.
        let strain = ResolveItem.finding(docId: "doc-a", Diagnostic(
            id: "s-1", docId: "doc-a", anchor: .init(paragraphId: "bb22", anchorText: "x"),
            body: "b", category: nil, runId: "run-1", kind: .conformanceStrain))
        XCTAssertEqual(MarginMarks.of(setting: .everythingFlagged, notes: [], owner: { _ in .unknown },
                                      items: [item, strain], selection: [], localName: "Denver",
                                      focusMode: false, readingTranslation: false,
                                      reviewRenderIsOn: false).ticks, ["bb22"])
    }

    /// **What the row offers**: Compare… where a pin moved and a tree's
    /// helper stands behind the list; Open where the tree can travel to the
    /// figure and the list is not already the figure's; the sentence goes to
    /// the line only on a placing piece. A verb that cannot act is absent.
    func test_theRowOffersOnlyWhatCanAct() {
        let placed = Self.change(Self.cash, placements: [Self.use("doc-a", 2)])
        func offers(_ change: ResolveFigureChange?, docId: String?, hasTree: Bool = true,
                    draws: Bool = true, atFigure: Bool = false) -> ResolveFigureSourceOffers {
            ResolveFigureSourceOffers.of(change: change, figureId: Self.cash, docId: docId, hasTree: hasTree,
                                         drawsFigure: draws, atFigureScope: atFigure)
        }
        XCTAssertEqual(offers(placed, docId: "doc-a"),
                       ResolveFigureSourceOffers(goesToTheLine: true, compare: true, open: true))
        XCTAssertEqual(offers(placed, docId: nil),
                       ResolveFigureSourceOffers(goesToTheLine: false, compare: true, open: true),
                       "a Book-level item: Open still takes the window to the figure")
        XCTAssertEqual(offers(placed, docId: Self.cash, atFigure: true),
                       ResolveFigureSourceOffers(goesToTheLine: false, compare: true, open: false))
        XCTAssertEqual(offers(placed, docId: "doc-a", hasTree: false, draws: false),
                       ResolveFigureSourceOffers(goesToTheLine: true, compare: false, open: false))
        let snapshot = Self.change(Self.cash, pins: false, placements: [Self.use("doc-a", 2)])
        XCTAssertFalse(offers(snapshot, docId: "doc-a").compare, "no pin moved: nothing to compare")
    }

    // MARK: - The tree's mark

    private var temp: TempDirectory!
    private var documentStores: [DocumentStore] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp?.cleanup()
        temp = nil
    }

    private func book(chapters: Int = 4) async throws -> ResolvePresenceTests.Book {
        let book = try await ResolvePresenceTests.book(in: temp.url, chapters: chapters, noted: [])
        documentStores.append(book.documentStore)
        return book
    }

    /// The watch's `update` and the walk it asks for, until nothing is asked.
    private func settle(_ reader: ResolvePresenceReader, _ book: ResolvePresenceTests.Book,
                        changes: [ResolveFigureChange]) async {
        let key = ResolvePresenceReader.key(store: book.store, documentStore: book.documentStore,
                                            diagnostics: nil, annotationsToken: 0, script: nil,
                                            figureChanges: changes)
        reader.update(key, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        while let request = reader.pendingRequest {
            await reader.run(request, store: book.store, documentStore: book.documentStore, diagnostics: nil)
        }
    }

    /// **The tree's dot marks the chapter placing the figure** (and its
    /// Part, and the Book); an unused figure marks the Book alone. The
    /// figures ride the presence read the window already holds: a change of
    /// them re-gathers and walks nothing — no closed chapter read, no walk
    /// asked — however many chapters the book has.
    func test_theTreeMarksThePlacingChapter() async throws {
        let book = try await book(chapters: 4)
        let chapter = book.ids[2]
        let reader = ResolvePresenceReader()
        await settle(reader, book, changes: [])
        XCTAssertFalse(reader.marks.pieces.contains(chapter), "control: a quiet book")
        XCTAssertFalse(reader.marks.book)
        let walks = reader.walksRequested, read = reader.piecesRead

        await settle(reader, book, changes: [Self.change(Self.cash, placements: [Self.use(chapter, 2)])])
        XCTAssertEqual(reader.marks.pieces, [chapter, "grp-2"], "the chapter, and its Part")
        XCTAssertTrue(reader.marks.book)
        XCTAssertEqual(ResolvePresence.rowMark(.item(chapter), in: reader.marks), .something)
        XCTAssertEqual(reader.walksRequested, walks, "a card fill asks no walk")
        XCTAssertEqual(reader.piecesRead, read, "and reads no chapter")

        await settle(reader, book, changes: [Self.change(Self.spare, number: FigureListing.unusedNumber,
                                                         placements: [])])
        XCTAssertEqual(reader.marks.pieces, [], "an unused figure marks no chapter")
        XCTAssertTrue(reader.marks.book, "it marks the Book")

        await settle(reader, book, changes: [])
        XCTAssertEqual(reader.marks, .none, "pinned again: the mark goes")
        XCTAssertEqual(reader.walksRequested, walks)
    }

    /// **A line moving above a changed figure reads nothing book-wide** (fix
    /// round 1, I2): the keys carry each placement's piece, and a line only
    /// for a `.piece` scope's own piece. So typing above the figure while
    /// the Book or a Part list stands beside the chapter is the live splice,
    /// and the presence read neither gathers nor walks; the chapter's own
    /// list re-reads (its one placement moves paragraph). Pinned by count.
    func test_aLineMovingAboveAChangedFigureReadsNothingBookWide() async throws {
        let book = try await book(chapters: 4)
        let chapter = book.ids[2]
        let before = [Self.change(Self.cash, placements: [Self.use(chapter, 2), Self.use(book.ids[3], 0)])]
        let after = [Self.change(Self.cash, placements: [Self.use(chapter, 6), Self.use(book.ids[3], 0)])]

        // The projection: a line only for the piece's own scope.
        XCTAssertEqual(ResolveFigureChange.keyed(after, for: .piece(docId: chapter, includesBookLevel: false))
                        .first?.placements.map(\.lineIndex), [6, ResolveFigureChange.unplacedLine])
        let bookScope = ResolveScope.of(.project, readIn: nil, sourceLanguage: "en",
                                        structure: book.store.manifest.structure, projectType: .novel)
        XCTAssertEqual(ResolveFigureChange.keyed(after, for: bookScope).first?.placements.map(\.lineIndex),
                       [ResolveFigureChange.unplacedLine, ResolveFigureChange.unplacedLine])

        // To resolve's step on the line move, at each scope.
        func step(_ scope: ResolveScope) -> ResolveRefreshStep {
            func key(_ changes: [ResolveFigureChange]) -> ResolveListKey {
                ResolvePane.listKey(scope: scope, annotationsToken: 0, store: book.store,
                                    documentStore: book.documentStore, diagnostics: nil, localName: "",
                                    script: nil, figureChanges: changes)
            }
            return ResolvePane.refreshStep(key(after), last: key(before))
        }
        XCTAssertEqual(step(bookScope), .live, "the Book list beside the chapter splices")
        XCTAssertEqual(step(.pieces(docIds: [chapter, book.ids[3]], includesBookLevel: false)), .live, "a Part")
        XCTAssertEqual(step(.piece(docId: book.ids[3], includesBookLevel: false)), .live, "another chapter")
        XCTAssertEqual(step(.piece(docId: chapter, includesBookLevel: false)), .read,
                       "control: the chapter's own list places it anew")

        // The presence read: no gather, no walk, no chapter read.
        let reader = ResolvePresenceReader()
        await settle(reader, book, changes: before)
        let gathers = reader.gathers, walks = reader.walksRequested, read = reader.piecesRead
        let marks = reader.marks
        await settle(reader, book, changes: after)
        XCTAssertEqual(reader.gathers, gathers, "a line move gathers nothing")
        XCTAssertEqual(reader.walksRequested, walks)
        XCTAssertEqual(reader.piecesRead, read)
        XCTAssertEqual(reader.marks, marks)
        // Control: a figure's source changing does re-gather (and walks nothing).
        await settle(reader, book, changes: after + [Self.change(Self.tax, placements: [Self.use(book.ids[0], 0)])])
        XCTAssertEqual(reader.gathers, gathers + 1)
        XCTAssertEqual(reader.walksRequested, walks)
        XCTAssertTrue(reader.marks.pieces.contains(book.ids[0]))
    }

    /// A novel (made as the app makes one) with `count` registered table
    /// figures, its stores wired as a window wires them.
    private func novel(figures count: Int) async throws -> (store: ProjectStore, documentStore: DocumentStore,
                                                            chapter: StructureItem, figures: [FigureRecord]) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Figures-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        documentStore.projectStore = store
        documentStores.append(documentStore)
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        var figures: [FigureRecord] = []
        for index in 0..<count {
            figures.append(try await store.createFigure(kind: .table, name: "t\(index)", piece: chapter.id))
        }
        return (store, documentStore, chapter, figures)
    }

    /// **No read opens a figure per row** (fix round 1, M3): forty changed
    /// figures, three of them REGISTERED — real streams the read could open
    /// or derive — list forty items from the values alone; the store opens
    /// no figure host, lends none, and the figure cache derives nothing.
    /// Control: one derive through the cache does move its count.
    func test_noReadOpensAFigureDocumentPerRow() async throws {
        let novel = try await novel(figures: 3)
        let registered = novel.figures.map(\.id)
        let ids = registered + (3..<40).map { String(format: "fig-%08x", 0xa0 + $0) }
        let changes = ids.enumerated().map { index, id in
            Self.change(id, number: "Table \(index + 1)", placements: [Self.use(novel.chapter.id, index)])
        }
        let scope = ResolveScope.of(.project, readIn: nil, sourceLanguage: "en",
                                    structure: novel.store.manifest.structure, projectType: .novel)
        // Settle the store's own work after making the figures, then count.
        for _ in 0..<50 where !novel.documentStore.openFigures.isEmpty || !novel.documentStore.figureHostLoans.isEmpty {
            await Task.yield()
        }
        novel.documentStore.figureCache.invalidateAll()
        let derives = novel.documentStore.figureCache.deriveCount
        XCTAssertEqual(novel.documentStore.openFigures.count, 0, "premise: no host open")
        let read = ResolveReader.read(
            scope: scope, annotations: ProjectAnnotationsSnapshot(annotations: [], unreadableDocIds: [], sequences: [:]),
            tasks: [], live: [:], store: novel.store, documentStore: novel.documentStore, diagnostics: nil,
            figureChanges: changes)
        XCTAssertEqual(read.items.filter {
            if case .figureSourceChanged = $0 { true } else { false }
        }.count, 40)
        XCTAssertEqual(novel.documentStore.openFigures.count, 0, "no figure host was opened")
        XCTAssertEqual(novel.documentStore.figureHostLoans.count, 0, "and none lent")
        XCTAssertEqual(novel.documentStore.figureCache.deriveCount, derives, "no figure stream was read")
        // Control: the counter is live — one read through the cache moves it.
        _ = try novel.documentStore.figureCache.state(
            forFigureId: registered[0], in: novel.store.url, trust: try await novel.documentStore.figureTrust(),
            facts: DocumentClass.Facts(novel.store.manifest))
        XCTAssertEqual(novel.documentStore.figureCache.deriveCount, derives + 1)
    }

    // MARK: - Refresh's refusal (fix round 1, M2)

    /// **Refresh is refused for each reason, and says which**: a piece in
    /// read-through (named), a view-only share, a posture that refuses the
    /// figure — each by the sheet's own function. Control: writing, with no
    /// grid open here, it says to open the table.
    func test_refreshIsRefusedForEachReasonAndNamed() async throws {
        let novel = try await novel(figures: 1)
        let figure = novel.figures[0].id
        func actions(_ store: ProjectStore, share: Bool = false, gate: ReadThroughGate = .writing) -> FigureActions {
            FigureActions(store: store, figureWindows: nil, typography: .defaults,
                          windowRefusesWrites: { share }, readThrough: { gate }, report: { _ in })
        }
        XCTAssertEqual(ResolveFigureCompareSheet.refusal(actions: actions(novel.store), figureId: figure),
                       FigureActions.openTheTableFirst, "control: this Mac may edit it; no grid is open")

        let gate = ReadThroughGate(pieces: [novel.chapter.id], structure: novel.store.manifest.structure,
                                   research: [], projectType: .novel,
                                   figures: novel.store.manifest.figures ?? [],
                                   figureLines: [ReadThroughGateFixture.line(figure, in: novel.chapter.id)])
        let reading = try XCTUnwrap(ResolveFigureCompareSheet.refusal(actions: actions(novel.store, gate: gate),
                                                                      figureId: figure))
        XCTAssertTrue(reading.contains("\u{201C}\(novel.chapter.title)\u{201D}"), "names the piece: \(reading)")
        XCTAssertTrue(reading.contains("read-through"), reading)

        XCTAssertEqual(ResolveFigureCompareSheet.refusal(actions: actions(novel.store, share: true), figureId: figure),
                       "This figure is read-only here.", "a view-only share")

        // A store no session stands behind: no posture, which refuses.
        let unsessioned = try await ProjectStore.load(from: novel.store.url)
        XCTAssertNil(unsessioned.documentStore?.posture(forDocId: figure), "premise: no posture")
        XCTAssertEqual(ResolveFigureCompareSheet.refusal(actions: actions(unsessioned), figureId: figure),
                       "This figure is read-only here.", "a refusing posture")

        // Refused for want of the table alone, the sheet offers the way there;
        // refused for who may write, it offers nothing more (M5).
        XCTAssertTrue(ResolveFigureCompareSheet.offersOpenTheTable(refusal: FigureActions.openTheTableFirst,
                                                                   canOpen: true))
        XCTAssertFalse(ResolveFigureCompareSheet.offersOpenTheTable(refusal: FigureActions.openTheTableFirst,
                                                                    canOpen: false), "no row to go to")
        XCTAssertFalse(ResolveFigureCompareSheet.offersOpenTheTable(refusal: reading, canOpen: true))
        XCTAssertFalse(ResolveFigureCompareSheet.offersOpenTheTable(refusal: nil, canOpen: true), "Refresh acts")
    }

    // MARK: - The row's verbs, without a window (fix round 1, M4)

    /// **Where the sentence goes, and what Open does**: on the paragraph the
    /// read placed it at; else the one the line is in now (the fallback); in
    /// a Book or Part list the piece opens inside the faces; an unused
    /// figure's or the figure's own item goes nowhere. Open reveals the
    /// figure's row, then travels to it.
    func test_theRowsVerbsGoWhereTheySay() {
        let change = Self.change(Self.cash, placements: [Self.use("doc-a", 2), Self.use("doc-b", 4)])
        var asked: [FigureListing.Use] = []
        func place(_ item: ResolveItem, _ scope: ResolveScope) -> ResolveFigureSourceVerbs.Place? {
            ResolveFigureSourceVerbs.place(of: item, change: change, scope: scope) { use in
                asked.append(use)
                return "cc33"
            }
        }
        let placed = ResolveItem.figureSourceChanged(figureId: Self.cash, docId: "doc-a", paragraphId: "bb22")
        XCTAssertEqual(place(placed, .piece(docId: "doc-a", includesBookLevel: false)),
                       .init(docId: "doc-a", paragraphId: "bb22", insideTheFaces: false))
        XCTAssertEqual(asked, [], "the read's paragraph needs no lookup")
        let inBook = ResolveItem.figureSourceChanged(figureId: Self.cash, docId: "doc-b", paragraphId: nil)
        XCTAssertEqual(place(inBook, .pieces(docIds: ["doc-a", "doc-b"], includesBookLevel: true)),
                       .init(docId: "doc-b", paragraphId: "cc33", insideTheFaces: true))
        XCTAssertEqual(asked, [Self.use("doc-b", 4)], "the fallback asks the line placing it in that piece")
        XCTAssertNil(place(.figureSourceChanged(figureId: Self.cash, docId: nil, paragraphId: nil),
                           .pieces(docIds: ["doc-a"], includesBookLevel: true)), "an unused figure's")
        XCTAssertNil(place(.figureSourceChanged(figureId: Self.cash, docId: Self.cash, paragraphId: nil),
                           .figure(id: Self.cash)), "the figure's own list's")

        var events: [String] = []
        ResolveFigureSourceVerbs.open(Self.cash, reveal: { events.append("reveal \($0)") },
                                      travel: { events.append("travel \($0)") })
        XCTAssertEqual(events, ["reveal \(Self.cash)", "travel \(BinderSubject.figure(Self.cash))"])
    }

    // MARK: - The delivery path

    /// Every link the pure tests cannot see: the tree's cards into its
    /// state, the state into the presence key and into To resolve's read
    /// key, the key into the read, the read into the snapshot, the item into
    /// its row, and the column handing the list the tree.
    static let wiring: [(file: String, spelling: String, what: String)] = [
        ("Maugham/Views/FigureSection.swift",
         "if changes != figureSourceChanges { figureSourceChanges = changes }", "the cards fill the state"),
        ("Maugham/Views/Resolve/ResolvePresence.swift",
         "figureChanges: state.figureSourceChanges)", "the watch's key carries them"),
        ("Maugham/Views/Resolve/ResolvePresence.swift",
         "diagnostics: diagnostics, figureChanges: key.read.figureChanges)", "the presence update gathers them"),
        ("Maugham/Views/Resolve/ResolvePresence.swift",
         "            figureChanges: figureChanges,\n", "the presence gather passes them to the reader"),
        ("Maugham/Views/Resolve/ResolvePane.swift",
         "figureChanges: figureTree?.figureSourceChanges ?? [])", "To resolve's key carries them"),
        ("Maugham/Views/Resolve/ResolveListDecisions.swift",
         "figureChanges: key.figureChanges)", "the list's read passes them"),
        ("Maugham/Views/Resolve/ResolveReader.swift",
         "let figures = figureSourceItems(", "the reader lists them"),
        ("Maugham/Views/Resolve/ResolveReader.swift",
         "items: read.items + figures,", "the snapshot holds them"),
        ("Maugham/Views/Resolve/ResolvePane.swift",
         "figureSourceRow(item, figureId: figureId, docId: docId)", "each draws its row"),
        ("Maugham/Views/RightColumn.swift",
         "figureTree: figureTree,\n", "the column hands the list the tree"),
        // Fix round 1: what each key carries (I2) and the row's closures (M1, M4).
        ("Maugham/Views/Resolve/ResolveListDecisions.swift",
         "figureChanges: ResolveFigureChange.keyed(figureChanges, for: scope))", "To resolve's key is keyed"),
        ("Maugham/Views/Resolve/ResolvePresence.swift",
         "figureChanges: ResolveFigureChange.keyed(figureChanges, for: scope)),", "the presence key is keyed"),
        ("Maugham/Views/Resolve/ResolvePane.swift",
         "compare: { comparing = ResolveFigureCompare(figureId: figureId) },", "Compare… raises the sheet"),
        ("Maugham/Views/Resolve/ResolvePane.swift", ".sheet(item: $comparing)", "the sheet is mounted"),
        ("Maugham/Views/Resolve/ResolvePane.swift",
         "open: { ResolveFigureSourceVerbs.open(figureId, reveal: revealFigure, travel: onTravel) })",
         "Open travels"),
        ("Maugham/Views/Resolve/ResolvePane.swift", "paragraphOfLine: paragraphOfLine)",
         "the sentence's fallback finds the line"),
        ("Maugham/Views/Resolve/ResolvePane.swift", "ResolveFigureSourceVerbs.go(to: place)",
         "the sentence goes there"),
        ("Maugham/Views/Resolve/ResolvePane.swift",
         ".shared(report: report, windowRefusesWrites: tree.figureWritesRefused)",
         "Refresh reports to the sheet, under the window's share"),
        ("Maugham/Views/Resolve/ResolveFigureSource.swift",
         "let actions = actions { [weak model] in model?.message = $0 }", "the sheet holds the report"),
        ("Maugham/Views/Resolve/ResolveFigureSource.swift",
         "let refusal = Self.refusal(actions: actions, figureId: figureId)", "the sheet draws its refusal"),
        ("Maugham/Views/Resolve/ResolveFigureSource.swift",
         "if let openTheTable, Self.offersOpenTheTable(refusal: refusal, canOpen: true) {",
         "the sheet offers the table"),
        ("Maugham/Views/Resolve/ResolvePane.swift",
         "openTheTable: drawsFigure(target.figureId) ? {", "the sheet's Open is the row's"),
    ]

    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    static func missing(in sources: [String: String]) -> [String] {
        wiring.filter { !(sources[$0.file] ?? "").contains($0.spelling) }.map(\.what)
    }

    func test_theDeliveryPathIsWired() throws {
        var sources: [String: String] = [:]
        for file in Set(Self.wiring.map(\.file)) {
            sources[file] = Self.codeOnly(try String(
                contentsOf: SourceTree.repoRoot.appendingPathComponent(file), encoding: .utf8))
        }
        XCTAssertEqual(Self.missing(in: sources), [])
        // The census reads: a line commented out, or a file without it, is caught.
        var planted = sources
        planted["Maugham/Views/Resolve/ResolvePane.swift"] = Self.codeOnly(
            "// figureChanges: figureTree?.figureSourceChanges ?? [])")
        XCTAssertEqual(Self.missing(in: planted), [
            "To resolve's key carries them", "each draws its row", "Compare… raises the sheet",
            "the sheet is mounted", "Open travels", "the sentence's fallback finds the line",
            "the sentence goes there", "Refresh reports to the sheet, under the window's share",
            "the sheet's Open is the row's"])
        planted = sources
        planted["Maugham/Views/FigureSection.swift"] = "struct FigureSection {}"
        XCTAssertEqual(Self.missing(in: planted), ["the cards fill the state"])
    }

    // MARK: - The row, mounted as the column builds it

    /// **The Book's list draws the sentence and Compare…** from the tree's
    /// changed figures, through the right column's own builder — read off
    /// the accessibility tree; nothing is pressed.
    func test_theBooksListDrawsTheRow() async throws {
        try requireAssistiveClient()
        let book = try await book(chapters: 2)
        let probe = RightColumnFixture.Probe(position: .resolve, subject: .book)
        probe.figureTree.figureSourceChanges = [
            Self.change(Self.cash, placements: [Self.use(book.ids[1], 0)])]
        let window = TestWindow.mount(
            RightColumnFixture.pane(store: book.store, documentStore: book.documentStore, probe: probe)
                .environment(UserPreferences(defaults: UserDefaults(suiteName: "FigureSource-\(UUID())")!)),
            size: CGSize(width: 340, height: 600))
        windows.append(window)
        let sentence = "Table 2\u{2019}s source data changed"
        let drawn = await pumpUntil(deadline: 5) {
            let texts = (try? self.axTexts(in: window)) ?? []
            return texts.contains { $0.contains(sentence) }
                && texts.contains(ResolveFigureSourceRow.compareTitle)
        }
        XCTAssertTrue(drawn, "drawn: \((try? axTexts(in: window)) ?? [])")
    }
}

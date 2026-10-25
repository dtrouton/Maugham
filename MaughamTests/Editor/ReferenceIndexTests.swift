import XCTest
@testable import MaughamCore
@testable import Maugham

/// The editor's reference index (report foundations plan 3b Task 1, R-3b-2):
/// sources and targets numbered as the default book numbers them, cached and
/// rebuilt off the main thread by `ReferenceIndexHost`.
@MainActor
final class ReferenceIndexTests: XCTestCase {

    private static func label(_ reference: String) -> ManuscriptLabel {
        ManuscriptLabel(reference: reference)!
    }

    private static func source(_ id: String, key: String, authors: [String], year: Int?,
                               title: String? = nil) -> ResearchItem {
        ResearchItem(id: id, title: "Item \(id)", type: .asset, kind: .link,
                     url: "https://example.com/\(id)",
                     citation: CitationInfo(key: key, authors: authors, sourceTitle: title, year: year))
    }

    private static func doc(_ id: String, _ path: String, kind: PieceKind? = nil) -> StructureItem {
        StructureItem(id: id, title: id, type: .document, path: path, pieceKind: kind)
    }

    private static func build(_ structure: [StructureItem], _ texts: [String: String],
                              research: [ResearchItem] = []) -> ReferenceIndex {
        ReferenceIndex.build(structure: structure, research: research,
                             text: { texts[$0.id] }, words: .english)
    }

    // MARK: - Fidelity (review focus 4)

    /// A three-chapter book — one chapter inside a part, a reference piece
    /// between two chapters, an unlabelled table and figure, a label on the
    /// wrong element and a label defined twice — numbers every labelled figure
    /// and table exactly as publishing's resolution of the same project does.
    func test_figureAndTableNumbersMatchPublishing() async throws {
        let tmp = TestTemp.root.appendingPathComponent("RefIndex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = try await ProjectFactory.createNovelProject(named: "Fidelity", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let first = try XCTUnwrap(store.manifest.structure.first?.path)
        let dir = (first as NSString).deletingLastPathComponent
        func path(_ name: String) -> String { dir.isEmpty ? name : "\(dir)/\(name)" }
        store.manifest.structure = [
            Self.doc("ch-one", path("one.md")),
            StructureItem(id: "part", title: "Part", type: .group, children: [
                Self.doc("ch-two", path("two.md")),
                Self.doc("ref", path("ref.md"), kind: .reference),
            ]),
            Self.doc("ch-three", path("three.md")),
        ]
        try await store.saveManifest()   // `Document.load` reads the ids off disk
        let table = "| a | b |\n|---|---|\n| 1 | 2 |"
        let texts = [
            "ch-one": "# One {#sec:one}\n\n![Map](map.png){#fig:map}\n\n\(table)\nTable: Sales {#tbl:sales}\n\n![Unlabelled](u.png)",
            "ch-two": "## Two\n\n\(table)\n\n![Chart](c.png){#fig:chart}\n\n![Cash](figures/cash.csv){#tbl:cash}\n\n\(table)\nTable: Costs {#tbl:costs}\n\n![Wrong](w.png){#tbl:wrong}\n\n![Grid](figures/grid.csv){#fig:grid}",
            "ref": "![Ref](r.png){#fig:ref}\n\n\(table)\nTable: Ref {#tbl:ref}",
            "ch-three": "![Late](l.png){#fig:late}\n\n\(table)\nTable: Again {#tbl:sales}\n\n\(table)\nTable: End {#tbl:end}",
        ]
        for item in ProjectStore.collectDocuments(in: store.manifest.structure) {
            let docURL = url.appendingPathComponent(try XCTUnwrap(item.path))
            try XCTUnwrap(texts[item.id]).write(to: docURL, atomically: true, encoding: .utf8)
            let loaded = try await Document.load(url: docURL, actor: .author, session: "ri", presenter: nil)
            await loaded.close()
        }

        let resolution = try PublishResolution.forCompile(
            source: ProjectStoreASTSource(projectStore: store), bodyTag: nil, imageAllowed: ["png"])
        let index = ReferenceIndex.build(
            structure: store.manifest.structure, research: store.manifest.research,
            text: { try? store.derivedCache.displayText(forDocId: $0.id, in: store.url) },
            words: .english)

        let published = resolution.targets.filter { $0.key.kind != .sec }
        XCTAssertEqual(published.count, 8, "premise: map, sales, chart, cash, costs, grid, late, end")
        let indexed = index.targets.filter { $0.label.kind != .sec }
        XCTAssertEqual(Set(indexed.map(\.label)), Set(published.keys),
                       "the index registers exactly the labels publishing does")
        for (label, target) in published {
            XCTAssertEqual(index.target(for: label)?.text, target.text, "\(label.reference)")
            XCTAssertEqual(index.target(for: label)?.docId, target.pieceID, "\(label.reference)")
        }
        XCTAssertEqual(index.target(for: Self.label("fig:late"))?.text, "Figure 6",
                       "premise: five figures before it (one unlabelled, one wrongly labelled, "
                       + "one table figure labelled fig:), and the reference piece's is not counted")
        // R7a-1 (Review Focus 4): a table figure's line labelled `tbl:` is a
        // table in both, with no wrong-element problem; an image labelled
        // `tbl:` keeps today's answer.
        XCTAssertEqual(index.target(for: Self.label("tbl:cash"))?.text, "Table 3",
                       "premise: Sales, then ch-two's unlabelled pipe table, then the table figure")
        XCTAssertEqual(index.target(for: Self.label("tbl:costs"))?.text, "Table 4")
        XCTAssertEqual(index.target(for: Self.label("fig:grid"))?.text, "Figure 5")
        let wrongElement = resolution.problems.compactMap { problem -> ManuscriptLabel? in
            if case .labelOnWrongElement(let label) = problem.kind { return label }
            return nil
        }
        XCTAssertEqual(wrongElement, [Self.label("tbl:wrong")])
        XCTAssertNil(index.target(for: Self.label("tbl:wrong")))
        XCTAssertEqual(index.target(for: Self.label("tbl:sales"))?.docId, "ch-one",
                       "a label defined twice is the first definition's")
    }

    /// R7a-1: a pipe table, a table figure and an image figure number
    /// Table 1, Table 2, Figure 1, and `@tbl:` reaches the table figure
    /// (the same document in `PublishResolutionTests`).
    func test_aTableFigureLineNumbersAsATable() {
        let index = ReferenceIndex.build(pieces: [("a", ReferenceIndex.PieceSummary(text:
            "| a |\n|---|\n| 1 |\nTable: Sales {#tbl:sales}\n\n"
            + "![Programme cash flows](figures/cash.csv){#tbl:cash}\n\n"
            + "![Sites](figures/sites.png){#fig:sites}\n\nSee @tbl:cash."))],
            research: [], words: .english)
        XCTAssertEqual(index.targets.map(\.label), [Self.label("tbl:sales"), Self.label("tbl:cash"),
                                                    Self.label("fig:sites")])
        XCTAssertEqual(index.targets.map(\.text), ["Table 1", "Table 2", "Figure 1"])
        XCTAssertEqual(index.target(for: Self.label("tbl:cash"))?.detail, "Programme cash flows")
    }

    // MARK: - What the index holds

    func test_referencePiecesAreExcluded() {
        let structure = [Self.doc("a", "a.md"), Self.doc("ref", "ref.md", kind: .reference),
                         Self.doc("b", "b.md")]
        let index = Self.build(structure, [
            "a": "![A](a.png){#fig:a}",
            "ref": "![R](r.png){#fig:r}\n\nSee [@cited].",
            "b": "![B](b.png){#fig:b}",
        ], research: [Self.source("s", key: "cited", authors: ["Smith"], year: 2026)])
        XCTAssertNil(index.target(for: Self.label("fig:r")))
        XCTAssertEqual(index.target(for: Self.label("fig:b"))?.text, "Figure 2")
        XCTAssertEqual(index.labelsDefined(excluding: "a"), [Self.label("fig:b")],
                       "a reference piece's labels are not the book's")
    }

    func test_targetsCarryTextDetailDocAndOrder() {
        let index = Self.build([Self.doc("a", "a.md"), Self.doc("sp", "s.fountain")], [
            "a": "## Method {#sec:method}\n\n| x |\n|---|\n| 1 |\nTable: {#tbl:bare}\n\n![Revenue by year](r.png){#fig:rev}",
            "sp": "![Nope](n.png){#fig:nope}",
        ])
        XCTAssertEqual(index.targets, [
            .init(label: Self.label("sec:method"), text: "Method", detail: "", docId: "a", order: 0),
            .init(label: Self.label("tbl:bare"), text: "Table 1", detail: "", docId: "a", order: 1),
            .init(label: Self.label("fig:rev"), text: "Figure 1", detail: "Revenue by year",
                  docId: "a", order: 2),
        ], "a screenplay is never read")
    }

    /// M4: a section's text drops markup and footnote markers, as publishing's
    /// unnumbered section reference prints it.
    func test_aSectionIsNamedByItsPlainHeadingText() {
        let index = Self.build([Self.doc("a", "a.md")],
                               ["a": "## The *quiet* **method**[^1] {#sec:m}\n\n[^1]: Note."])
        XCTAssertEqual(index.target(for: Self.label("sec:m"))?.text, "The quiet method")
    }

    /// M3: a citation inside a fenced code block is not cited, as publishing
    /// never reads one; the same key outside the fence is. A CLOSED fence is
    /// already one backtick code span to the inline scanner, so the case the
    /// block-level skip exists for is a fence left open to the end of the piece.
    func test_aCitationInFencedCodeIsNotCited() {
        let research = [
            Self.source("1", key: "smithA", authors: ["Smith, Jane"], year: 2026, title: "Alpha"),
            Self.source("2", key: "smithB", authors: ["Smith, Jane"], year: 2026, title: "Beta"),
        ]
        let fenced = Self.build([Self.doc("a", "a.md")],
                                ["a": "Prose [@smithA].\n\n```\nexample [@smithB]\nstill code"],
                                research: research)
        XCTAssertEqual(fenced.source(forKey: "smithA")?.label, "Smith 2026",
                       "only smithA is cited, so it needs no letter")
        let both = Self.build([Self.doc("a", "a.md")],
                              ["a": "Prose [@smithA] and [@smithB].\n\n```\nexample\nstill code"],
                              research: research)
        XCTAssertEqual(both.source(forKey: "smithA")?.label, "Smith 2026a",
                       "control: before the fence, a citation counts")
    }

    func test_elementWordsNameTheNumbers() {
        let index = ReferenceIndex.build(
            structure: [Self.doc("a", "a.md")], research: [],
            text: { _ in "![M](m.png){#fig:m}" }, words: ElementWords.builtIn(language: "sr"))
        XCTAssertEqual(index.target(for: Self.label("fig:m"))?.text, "Slika 1")
    }

    func test_citedSourcesSharingANameAndYearGetLetters() {
        let research = [
            Self.source("1", key: "smithA", authors: ["Smith, Jane"], year: 2026, title: "Alpha"),
            Self.source("2", key: "smithB", authors: ["Smith, Jane"], year: 2026, title: "Beta"),
            Self.source("3", key: "smithC", authors: ["Smith, Jane"], year: 2026, title: "Gamma"),
        ]
        let index = Self.build([Self.doc("a", "a.md"), Self.doc("b", "b.md")],
                               ["a": "As shown [@smithB; @smithA, p. 4].", "b": "Again [@smithA]."],
                               research: research)
        XCTAssertEqual(index.source(forKey: "smithA")?.label, "Smith 2026a")
        XCTAssertEqual(index.source(forKey: "smithB")?.label, "Smith 2026b")
        XCTAssertEqual(index.source(forKey: "smithC")?.label, "Smith 2026",
                       "an uncited source is never disambiguated")
        XCTAssertEqual(index.citationText([CitationItem(key: "smithA", locator: "p. 4"),
                                           CitationItem(key: "smithB", locator: nil)]),
                       "(Smith 2026a, p. 4; Smith 2026b)", "the faint label's text")
        XCTAssertNil(index.citationText([CitationItem(key: "nobody", locator: nil)]))
    }

    func test_uncitedSourcesAreListedSortedByAuthors() {
        let research = [
            Self.source("1", key: "zed", authors: ["Zed, Z"], year: 2001),
            ResearchItem(id: "g", title: "Group", type: .group, children: [
                Self.source("2", key: "abe", authors: ["Abe, A", " ", "Bee, B"], year: nil, title: "Book"),
            ]),
            Self.source("3", key: "mid", authors: [], year: 2010, title: "Middle Report"),
            Self.source("4", key: "abe", authors: ["Duplicate"], year: 1999),
            ResearchItem(id: "5", title: "No key", type: .asset, kind: .link),
        ]
        let index = Self.build([Self.doc("a", "a.md")], ["a": "No citations."], research: research)
        XCTAssertEqual(index.sources, [
            .init(key: "abe", label: "Abe and Bee n.d.", authorsLine: "Abe, A; Bee, B", title: "Book"),
            .init(key: "mid", label: "Middle Report 2010", authorsLine: "", title: "Middle Report"),
            .init(key: "zed", label: "Zed 2001", authorsLine: "Zed, Z", title: "Item 1"),
        ], "children walked, the first of a duplicate key wins, a source with no authors sorts by title")
    }

    func test_labelsDefinedElsewhereIncludeEveryKindAndDuplicates() {
        let index = Self.build([Self.doc("a", "a.md"), Self.doc("b", "b.md")], [
            "a": "![W](w.png){#tbl:table-1}",
            "b": "## B {#sec:b}\n\n![X](x.png){#fig:x}",
        ])
        XCTAssertEqual(index.labelsDefined(excluding: "b"), [Self.label("tbl:table-1")],
                       "a wrong-kind label is still taken")
        XCTAssertEqual(index.labelsDefined(excluding: "a"), [Self.label("sec:b"), Self.label("fig:x")])
    }

    // MARK: - The host

    /// What the host asked, recorded from the main actor (derives) and from
    /// the off-main token step (tokens), so it is locked.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var _derived: [String] = []
        private var _tokens: [String] = []
        private var _tokenCalls = 0
        private var _tokensOnMain: [Bool] = []
        /// What the next token step answers per piece (the stub's entry count).
        private var _tokenEntries = 1
        private var _language = "en"
        var derived: [String] { lock.withLock { _derived } }
        var tokens: [String] { lock.withLock { _tokens } }
        /// How many token steps ran: each is ONE listing of the ops directory.
        var tokenCalls: Int { lock.withLock { _tokenCalls } }
        var tokensOnMain: [Bool] { lock.withLock { _tokensOnMain } }
        var tokenEntries: Int {
            get { lock.withLock { _tokenEntries } }
            set { lock.withLock { _tokenEntries = newValue } }
        }
        var language: String {
            get { lock.withLock { _language } }
            set { lock.withLock { _language = newValue } }
        }
        func noteDerived(_ id: String) { lock.withLock { _derived.append(id) } }
        func tokens(for ids: [String]) -> [String: DerivedManuscriptCache.Token] {
            lock.withLock {
                _tokenCalls += 1
                _tokens += ids
                _tokensOnMain.append(Thread.isMainThread)
                let entries = _tokenEntries
                return Dictionary(uniqueKeysWithValues: ids.map {
                    ($0, DerivedManuscriptCache.Token(stubEntries: entries))
                })
            }
        }
        func words() -> ElementWords {
            language == "sr" ? ElementWords.forBody(PublishConfig.Metadata(language: "sr")) : .english
        }
    }

    private func project(texts: @escaping () -> [String: String],
                         live: @escaping () -> [String: String] = { [:] },
                         research: @escaping () -> [ResearchItem] = { [] },
                         structure: [StructureItem],
                         reads: Reads = Reads()) -> ReferenceIndexHost.Project {
        ReferenceIndexHost.Project(
            structure: { structure },
            research: research,
            liveText: { path in live()[path] },
            tokens: { ids in reads.tokens(for: ids) },
            derivedText: { id in reads.noteDerived(id); return texts()[id] },
            words: { reads.words() })
    }

    func test_theVersionBumpsOnlyWhenTheContentsChange() async {
        var texts = ["a": "![A](a.png){#fig:a}"]
        var research: [ResearchItem] = []
        let host = ReferenceIndexHost()
        var versions: [Int] = []
        host.onVersionChange = { versions.append($0) }
        host.attach(project(texts: { texts }, research: { research }, structure: [Self.doc("a", "a.md")]))
        await host.idle()
        XCTAssertEqual(host.index.version, 1)
        XCTAssertEqual(host.index.target(for: Self.label("fig:a"))?.text, "Figure 1")

        host.noteSettled(docId: "a", text: "![A](a.png){#fig:a}\n\nMore prose.")
        await host.idle()
        XCTAssertEqual(host.index.version, 1, "prose that changes no target bumps nothing")

        texts["a"] = "unused"
        host.noteSettled(docId: "a", text: "![B](b.png){#fig:b}\n\n![A](a.png){#fig:a}")
        await host.idle()
        XCTAssertEqual(host.index.version, 2)
        XCTAssertEqual(host.index.target(for: Self.label("fig:a"))?.text, "Figure 2",
                       "the settled live text is the piece's text")

        research = [Self.source("s", key: "k", authors: ["Lee"], year: 2020)]
        host.invalidate(.research)
        await host.idle()
        XCTAssertEqual(host.index.version, 3)
        XCTAssertEqual(host.index.source(forKey: "k")?.label, "Lee 2020")
        XCTAssertEqual(versions, [1, 2, 3])
    }

    func test_aClosedPieceIsReReadOnlyWhenItsOpLogMoved() async {
        let reads = Reads()
        let host = ReferenceIndexHost()
        host.attach(project(texts: { ["a": "A", "b": "B"] },
                            structure: [Self.doc("a", "a.md"), Self.doc("b", "b.md")],
                            reads: reads))
        await host.idle()
        XCTAssertEqual(reads.derived, ["a", "b"])

        host.invalidate(.all)
        await host.idle()
        XCTAssertEqual(reads.derived, ["a", "b"], "unchanged tokens: no text is derived again")

        host.invalidate(.research)
        await host.idle()
        XCTAssertEqual(reads.tokens.count, 4, "a research change asks no piece anything")

        reads.tokenEntries = 2
        host.invalidate(.piece("b"))
        await host.idle()
        XCTAssertEqual(reads.derived, ["a", "b", "b"], "only the invalidated piece, and it moved")
    }

    /// Whole-branch review I2: a rebuild asks every closed piece's token in
    /// ONE step off the main actor (production: one listing of `.maugham/ops`,
    /// pinned in `DerivedManuscriptCacheTests`), never a listing per piece on
    /// the main actor; an open piece is asked nothing.
    func test_aRebuildAsksEveryClosedPiecesTokenInOneStepOffTheMainActor() async {
        let reads = Reads()
        let structure = (0..<12).map { Self.doc("d\($0)", "d\($0).md") }
        let host = ReferenceIndexHost()
        host.attach(project(texts: { [:] }, live: { ["d3.md": "Open."] },
                            structure: structure, reads: reads))
        await host.idle()
        XCTAssertEqual(reads.tokenCalls, 1, "one token step for the whole project")
        XCTAssertEqual(reads.tokens.count, 11, "every closed piece, in that one step")
        XCTAssertFalse(reads.tokens.contains("d3"), "an open piece's token is never asked")
        host.invalidate(.all)
        await host.idle()
        XCTAssertEqual(reads.tokenCalls, 2, "and one per rebuild after")
        XCTAssertEqual(reads.tokensOnMain, [false, false], "never on the main actor")
    }

    /// Whole-branch review M3: the book's element words are read at every
    /// rebuild, so a language change in Publish shows at the next one
    /// (a settle), not only at a document switch.
    func test_theElementWordsAreReReadAtEveryRebuild() async {
        let reads = Reads()
        let host = ReferenceIndexHost()
        host.attach(project(texts: { [:] },
                            live: { ["a.md": "![A](a.png){#fig:a}"] },
                            structure: [Self.doc("a", "a.md")], reads: reads))
        await host.idle()
        XCTAssertEqual(host.index.target(for: Self.label("fig:a"))?.text, "Figure 1")
        reads.language = "sr"
        host.noteSettled(docId: "a", text: "![A](a.png){#fig:a}\n\nMore.")
        await host.idle()
        XCTAssertEqual(host.index.target(for: Self.label("fig:a"))?.text, "Slika 1")
        XCTAssertEqual(host.index.version, 2, "the new words are new contents")
    }

    /// Whole-branch review I1: before the first build publishes, the index is
    /// empty, so the labels a command must not repeat are walked now — a
    /// closed piece's derived text, an open one's live text — never answered
    /// from the empty index. Once built, the cached index answers and nothing
    /// is derived for it.
    func test_beforeTheFirstBuildTheLabelsElsewhereAreWalked() async {
        let reads = Reads()
        let host = ReferenceIndexHost(builder: { snapshot, memo in
            ReferenceIndexHost.build(snapshot, memo)
        })
        host.attach(project(texts: { ["ch2": "| a |\n|---|\n| 1 |\nTable: T {#tbl:table-1}"] },
                            live: { ["ch3.md": "![F](f.png){#fig:open}"] },
                            structure: [Self.doc("ch1", "ch1.md"), Self.doc("ch2", "ch2.md"),
                                        Self.doc("ch3", "ch3.md")],
                            reads: reads))
        XCTAssertEqual(host.index.version, 0, "nothing has been built yet")
        XCTAssertEqual(host.labelsDefined(excluding: "ch1"),
                       [Self.label("tbl:table-1"), Self.label("fig:open")])
        await host.idle()
        let derived = reads.derived.count
        XCTAssertEqual(host.labelsDefined(excluding: "ch1"),
                       [Self.label("tbl:table-1"), Self.label("fig:open")])
        XCTAssertEqual(reads.derived.count, derived, "built: the cached index answers, no walk")
    }

    func test_anOpenPieceReadsItsLiveText() async {
        let reads = Reads()
        let host = ReferenceIndexHost()
        host.attach(project(texts: { ["a": "![Old](o.png){#fig:old}"] },
                            live: { ["a.md": "![New](n.png){#fig:new}"] },
                            structure: [Self.doc("a", "a.md")], reads: reads))
        await host.idle()
        XCTAssertNotNil(host.index.target(for: Self.label("fig:new")))
        XCTAssertEqual(reads.derived, [], "an open piece is never derived from its op log")
    }

    func test_theRebuildRunsOffTheMainActor() async {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var onMain: [Bool] = []
        }
        let box = Box()
        let host = ReferenceIndexHost(builder: { snapshot, memo in
            box.lock.lock(); box.onMain.append(Thread.isMainThread); box.lock.unlock()
            return ReferenceIndexHost.build(snapshot, memo)
        })
        host.attach(project(texts: { ["a": "![A](a.png){#fig:a}"] }, structure: [Self.doc("a", "a.md")]))
        XCTAssertEqual(host.index.version, 0, "nothing is built on the caller's turn")
        await host.idle()
        XCTAssertEqual(box.onMain, [false])
        XCTAssertEqual(host.index.version, 1, "the result is published back")
    }

    /// The first build publishes even when it finds nothing, so version 0
    /// means "not built yet" (plan 3b Task 6: the problem marks wait for it
    /// rather than call every key unknown). A second empty build bumps nothing.
    func test_theFirstBuildPublishesEvenAnEmptyIndex() async {
        let host = ReferenceIndexHost()
        var versions: [Int] = []
        host.onVersionChange = { versions.append($0) }
        // No piece and no source: the build equals `.empty` in every field.
        host.attach(project(texts: { [:] }, structure: []))
        await host.idle()
        XCTAssertEqual(host.index.version, 1)
        host.invalidate(.all)
        await host.idle()
        XCTAssertEqual(versions, [1])
    }

    /// A re-attach while a build for the old project is still in flight:
    /// the old build publishes nothing, and the new one is not orphaned.
    func test_aReattachMidBuildPublishesOnlyTheNewProject() async {
        let host = ReferenceIndexHost()
        host.attach(project(texts: { ["a": "![Old](o.png){#fig:old}"] }, structure: [Self.doc("a", "a.md")]))
        host.attach(project(texts: { ["c": "C"] }, structure: [Self.doc("c", "c.md")]))
        host.attach(nil)
        host.attach(project(texts: { ["b": "![New](n.png){#fig:new}"] }, structure: [Self.doc("b", "b.md")]))
        await host.idle()
        XCTAssertNil(host.index.target(for: Self.label("fig:old")))
        XCTAssertNotNil(host.index.target(for: Self.label("fig:new")))
        host.invalidate(.research)
        await host.idle()
        XCTAssertNotNil(host.index.target(for: Self.label("fig:new")), "the host still rebuilds")
    }

    func test_theBuildReparsesOnlyAPieceWhoseTextChanged() {
        let snapshot = ReferenceIndexHost.Snapshot(
            pieces: [("a", "![A](a.png){#fig:a}"), ("b", "![B](b.png){#fig:b}")],
            research: [], words: .english)
        let (_, memo) = ReferenceIndexHost.build(snapshot, [:])
        let planted = ReferenceIndexHost.Memo(
            text: "![B](b.png){#fig:b}",
            summary: .init(elements: [.figure(caption: "Planted", label: Self.label("fig:planted"))],
                           definedLabels: [], citedKeys: []))
        var held = memo
        held["b"] = planted
        let (index, _) = ReferenceIndexHost.build(snapshot, held)
        XCTAssertNotNil(index.target(for: Self.label("fig:planted")),
                        "an unchanged text reuses its summary rather than parsing again")
        let changed = ReferenceIndexHost.Snapshot(
            pieces: [("a", "![A](a.png){#fig:a}"), ("b", "![C](c.png){#fig:c}")],
            research: [], words: .english)
        XCTAssertNotNil(ReferenceIndexHost.build(changed, held).0.target(for: Self.label("fig:c")))
    }

    // MARK: - The wiring

    /// `EditorHost` hands the editor the cached index (never a build), takes
    /// the open document's text at the metrics edge (never per keystroke),
    /// pushes a new version through the control plane, and answers
    /// `projectLabelsElsewhere` from the index rather than a walk.
    func test_editorHostWiresTheIndex() throws {
        let host = try SourceTree.read("Maugham/Views/EditorHost.swift")
        for needle in [
            "referenceIndex: { [referenceIndex] in referenceIndex.index }",
            "referenceIndex.noteSettled(docId: doc.docId, text: doc.displayText)",
            "control.referenceIndexVersion = $0",
            "referenceIndex.labelsDefined(excluding: doc.docId)",
            // One listing of the ops directory per rebuild, off main (I2).
            "DerivedManuscriptCache.tokens(forDocIds: docIds, in: url)",
            // (The same watch also refills the figure cards, report plan 7a Task 3.)
            ".onChange(of: store.manifest.research) { _, _ in\n"
                + "            referenceIndex.invalidate(.research)\n",
            // The piece just left is read again from its flushed op log at the
            // switch itself, not only from the new mount's `.onAppear` (I1).
            "documentStore.unregister(path: priorPath)\n"
                + "            // The piece just left, now flushed and closed: the reference\n"
                + "            // index reads it again from its op log, whatever the new\n"
                + "            // document's mount does (plan 3b Task 1 fix round 1, I1).\n"
                + "            referenceIndex.invalidate(.piece(prior.docId))",
            // Another device's sync of a closed piece.
            "referenceIndex.invalidate(.piece(changed))",
        ] {
            XCTAssertTrue(host.contains(needle), "EditorHost no longer says: \(needle)")
        }
        XCTAssertFalse(host.contains("ReportInsert.labelsElsewhere("),
                       "the per-command walk over every document is back")
    }

    // MARK: - Budget (review focus 1)

    /// Building is linear in the project: four times the documents stays
    /// under eight times the time. A scaling ratio, never a wall clock.
    func test_buildingScalesLinearlyWithTheProject() {
        func project(_ count: Int) -> (structure: [StructureItem], texts: [String: String]) {
            var structure: [StructureItem] = []
            var texts: [String: String] = [:]
            let table = "| a | b |\n|---|---|\n| 1 | 2 |"
            for i in 0..<count {
                structure.append(Self.doc("d\(i)", "d\(i).md"))
                var body = "## Chapter \(i) {#sec:c\(i)}\n\n"
                for j in 0..<10 {
                    body += "Prose cites [@k\(j % 7)] and @fig:f\(i)-\(j) here.\n\n"
                    body += "![F](f.png){#fig:f\(i)-\(j)}\n\n\(table)\nTable: T {#tbl:t\(i)-\(j)}\n\n"
                }
                texts["d\(i)"] = body
            }
            return (structure, texts)
        }
        let research = (0..<7).map { Self.source("s\($0)", key: "k\($0)", authors: ["Smith"], year: 2026) }
        let small = project(50), large = project(200)
        func ms(_ p: (structure: [StructureItem], texts: [String: String])) -> Double {
            let clock = ContinuousClock()
            let t = clock.now
            let index = ReferenceIndex.build(structure: p.structure, research: research,
                                             text: { p.texts[$0.id] }, words: .english)
            let d = clock.now - t
            XCTAssertEqual(index.targets.count, p.structure.count * 21)
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        _ = ms(small); _ = ms(large)
        var fastSmall = Double.infinity, fastLarge = Double.infinity
        for _ in 0..<5 {
            fastSmall = min(fastSmall, ms(small))
            fastLarge = min(fastLarge, ms(large))
        }
        XCTAssertLessThan(fastLarge / fastSmall, 8,
            "building grew \(fastLarge / fastSmall)× for 4× the documents "
            + "(50: \(fastSmall) ms → 200: \(fastLarge) ms): something has gone super-linear")
    }
}

private extension DerivedManuscriptCache.Token {
    /// A token that differs by `stubEntries` (the internal init, through
    /// `@testable import MaughamCore`).
    init(stubEntries: Int) {
        self.init(entries: (0..<stubEntries).map { .init(path: "op-\($0)", mtime: 0, size: 1) })
    }
}

import XCTest
import MaughamCore
@testable import Maugham

/// Report foundations plan 2, Task 3: the publish context (live citations,
/// profile, switches, the real project URL, piece paths) and the whole-book
/// resolution scope reach publishing through two defaulted `Source`
/// requirements. Every assertion that matters is made THROUGH
/// `any ProjectASTBuilder.Source`, because that is how the compilers hold a
/// source — a wrapper override reachable only statically would be invisible
/// to them.
///
/// `@MainActor` because `ProjectStoreASTSource`'s conformance is.
@MainActor
final class PublishContextTests: XCTestCase {

    // MARK: - test doubles

    /// A conformer that implements ONLY `orderedPieces()`, like the ~66 test
    /// conformers the defaults exist to leave untouched.
    private struct PlainSource: ProjectASTBuilder.Source {
        let ids: [String]
        func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] {
            ids.map { .init(pieceID: $0, title: $0, mode: .prose, displayText: $0) }
        }
    }

    /// A base with a distinctive context, so a wrapper that answers the
    /// default instead of forwarding is visible.
    private struct ContextSource: ProjectASTBuilder.Source {
        let ids: [String]
        let context: PublishContext
        func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] {
            ids.map { .init(pieceID: $0, title: $0, mode: .prose, displayText: $0) }
        }
        func publishContext() -> PublishContext { context }
    }

    /// THE PLANTED CONTROL: a filtering wrapper written the way all three
    /// production wrappers were before this task — it forwards
    /// `orderedPieces()` and nothing else. `forwardingFailures` must catch it.
    private struct NonForwardingWrapper: ProjectASTBuilder.Source {
        let base: ProjectASTBuilder.Source
        let keep: Set<String>
        func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] {
            try base.orderedPieces().filter { keep.contains($0.pieceID) }
        }
    }

    private static let markerURL = URL(fileURLWithPath: "/marker/Real Project")

    private static func markedContext() -> PublishContext {
        var ctx = PublishContext.empty
        ctx.projectURL = markerURL
        ctx.profile = .report
        ctx.switches = (numberSections: true, listOfFigures: false, listOfTables: true)
        ctx.piecePaths = ["a": "manuscript/a.md", "b": "manuscript/b.md", "c": "manuscript/c.md"]
        return ctx
    }

    /// THE SECOND PLANTED CONTROL (R-S15): an edition filter written the way
    /// `IncludeFilteredASTSource` was before the final review — it forwards
    /// its base's whole book as its scope, so a section the edition excludes
    /// would still number, cite and block. `forwardingFailures` must catch it.
    private struct BaseScopedEditionFilter: ProjectASTBuilder.Source {
        let base: ProjectASTBuilder.Source
        let excluded: Set<String>
        func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] {
            try base.orderedPieces().filter { !excluded.contains($0.pieceID) }
        }
        func publishContext() -> PublishContext { base.publishContext() }
        var resolutionScope: ProjectASTBuilder.Source { base.resolutionScope }
        var isWholeBook: Bool { excluded.isEmpty && base.isWholeBook }
    }

    /// What a filtering wrapper over `ContextSource(ids: a,b,c)` gets wrong, as
    /// sentences; empty means it forwards the context, resolves over
    /// `editionBook` (R-S15: the EDITION's book, never the raw base), shows
    /// `view`, and says it is whole exactly when the two are one. Everything is
    /// asked through the existential.
    private func forwardingFailures(of wrapper: any ProjectASTBuilder.Source,
                                    editionBook: [String], view: [String]) throws -> [String] {
        var failures: [String] = []
        let ctx = wrapper.publishContext()
        if ctx.projectURL != Self.markerURL {
            failures.append("publishContext().projectURL is \(String(describing: ctx.projectURL)), not the base's")
        }
        if ctx.piecePaths.count != 3 {
            failures.append("publishContext().piecePaths has \(ctx.piecePaths.count) entries, not the base's 3")
        }
        if ctx.profile != .report {
            failures.append("publishContext().profile is \(String(describing: ctx.profile)), not the base's")
        }
        let scopeIDs = try wrapper.resolutionScope.orderedPieces().map(\.pieceID)
        if scopeIDs != editionBook {
            failures.append("resolutionScope reads \(scopeIDs), not the edition's book \(editionBook)")
        }
        // A view that is not its book must say so, or the resolution would
        // reuse the view's AST as the book (`forCompile(source:built:…)`); a
        // view that IS its book must say so too, or every compile derives the
        // manuscript twice.
        let shouldBeWhole = view == editionBook
        if wrapper.isWholeBook != shouldBeWhole {
            failures.append("isWholeBook is \(wrapper.isWholeBook) for a view of \(view) over \(editionBook)")
        }
        let viewIDs = try wrapper.orderedPieces().map(\.pieceID)
        if viewIDs != view {
            failures.append("premise: the wrapper's own view is \(viewIDs), not \(view)")
        }
        return failures
    }

    private var base: ContextSource {
        ContextSource(ids: ["a", "b", "c"], context: Self.markedContext())
    }

    // MARK: - the defaults

    func test_aSourceWithOnlyOrderedPieces_answersTheEmptyContextAndItselfAsScope() throws {
        let src: any ProjectASTBuilder.Source = PlainSource(ids: ["x", "y"])
        let ctx = src.publishContext()
        XCTAssertNil(ctx.projectURL)
        XCTAssertNil(ctx.profile)
        XCTAssertTrue(ctx.piecePaths.isEmpty)
        XCTAssertTrue(ctx.library.keys.isEmpty)
        XCTAssertFalse(ctx.switches.numberSections || ctx.switches.listOfFigures || ctx.switches.listOfTables)
        XCTAssertEqual(try src.resolutionScope.orderedPieces().map(\.pieceID), ["x", "y"])
        XCTAssertTrue(src.isWholeBook, "a source that filters nothing is its own whole book")
    }

    // MARK: - the wrappers forward, through the existential

    /// A preview narrowing over an edition that excludes nothing resolves over
    /// the whole base.
    func test_filteredASTSource_forwardsContextAndScopeThroughAnySource() throws {
        let wrapper: any ProjectASTBuilder.Source = FilteredASTSource(
            base: base, sectionIDs: ["b"], editionExcludedSectionIDs: [])
        XCTAssertEqual(try forwardingFailures(of: wrapper, editionBook: ["a", "b", "c"], view: ["b"]), [])
    }

    /// R-S15: a preview narrowing resolves over its EDITION's book — not the
    /// raw base — so a section the edition leaves out is outside it.
    func test_filteredASTSource_resolvesOverTheEditionsBook() throws {
        let wrapper: any ProjectASTBuilder.Source = FilteredASTSource(
            base: base, sectionIDs: ["b"], editionExcludedSectionIDs: ["c"])
        XCTAssertEqual(try forwardingFailures(of: wrapper, editionBook: ["a", "b"], view: ["b"]), [])
    }

    /// An explicit `section_ids` may name a section the edition excludes: it
    /// is shown, and the book stays the edition's.
    func test_filteredASTSource_namingAnExcludedSection_showsItButResolvesOverTheEdition() throws {
        let wrapper: any ProjectASTBuilder.Source = FilteredASTSource(
            base: base, sectionIDs: ["c"], editionExcludedSectionIDs: ["c"])
        XCTAssertEqual(try forwardingFailures(of: wrapper, editionBook: ["a", "b"], view: ["c"]), [])
    }

    /// R-S15: the edition's filter IS the edition's book — its own scope, and
    /// whole — so an excluded section neither numbers nor blocks.
    func test_includeFilteredASTSource_isItsOwnBookThroughAnySource() throws {
        let wrapper: any ProjectASTBuilder.Source = IncludeFilteredASTSource(
            base: base, excludedSectionIDs: ["a", "c"])
        XCTAssertEqual(try forwardingFailures(of: wrapper, editionBook: ["b"], view: ["b"]), [])
    }

    /// Wrappers nest (a preview's filter over a body an edition already
    /// filtered): the inner filter is the edition, so its book is the scope.
    func test_nestedWrappers_resolveOverTheInnerEdition() throws {
        let inner = IncludeFilteredASTSource(base: base, excludedSectionIDs: ["c"])
        let outer: any ProjectASTBuilder.Source = FilteredASTSource(
            base: inner, sectionIDs: ["b"], editionExcludedSectionIDs: [])
        XCTAssertEqual(try forwardingFailures(of: outer, editionBook: ["a", "b"], view: ["b"]), [])
    }

    /// The narrowing reads its base once for both of its views (M4).
    func test_filteredASTSource_readsItsBaseOnce() throws {
        final class Counter { var reads = 0 }
        struct Counting: ProjectASTBuilder.Source {
            let counter: Counter
            func orderedPieces() throws -> [ProjectASTBuilder.PieceRef] {
                counter.reads += 1
                return ["a", "b"].map { .init(pieceID: $0, title: $0, mode: .prose, displayText: $0) }
            }
        }
        let counter = Counter()
        let wrapper: any ProjectASTBuilder.Source = FilteredASTSource(
            base: Counting(counter: counter), sectionIDs: ["b"], editionExcludedSectionIDs: [])
        _ = try ProjectASTBuilder.build(from: wrapper)
        _ = try ProjectASTBuilder.build(from: wrapper.resolutionScope)
        XCTAssertEqual(counter.reads, 1)
    }

    /// `SinglePieceSource` has no base: it carries its own context (the
    /// contract examples' library) and is its own whole book.
    func test_singlePieceSource_answersItsOwnContextThroughAnySource() throws {
        let src: any ProjectASTBuilder.Source = SinglePieceSource(
            pieceID: "p", title: "P", mode: .prose, text: "Hello.",
            context: Self.markedContext())
        XCTAssertEqual(src.publishContext().projectURL, Self.markerURL)
        XCTAssertEqual(try src.resolutionScope.orderedPieces().map(\.pieceID), ["p"])
        let plain: any ProjectASTBuilder.Source = SinglePieceSource(
            pieceID: "p", title: "P", mode: .prose, text: "Hello.")
        XCTAssertNil(plain.publishContext().projectURL, "defaults to the empty context")
    }

    /// The control: the same check, run against a wrapper that does NOT
    /// forward, fails — so the passes above are earned.
    func test_plantedControl_aWrapperThatDoesNotForward_isCaught() throws {
        let wrapper: any ProjectASTBuilder.Source = NonForwardingWrapper(base: base, keep: ["b"])
        let failures = try forwardingFailures(of: wrapper, editionBook: ["a", "b", "c"], view: ["b"])
        XCTAssertEqual(failures.count, 5, "context (3 facts), scope and wholeness all lost: \(failures)")
        XCTAssertTrue(failures.contains { $0.hasPrefix("isWholeBook is true") }, "\(failures)")
        XCTAssertTrue(failures.contains { $0.hasPrefix("resolutionScope") }, "\(failures)")
        XCTAssertFalse(failures.contains { $0.hasPrefix("premise") }, "\(failures)")
    }

    /// The R-S15 control: an edition filter that resolves over its base's
    /// whole book — the shape the final review found — fails on scope and
    /// wholeness.
    func test_plantedControl_anEditionFilterScopedToTheRawBase_isCaught() throws {
        let wrapper: any ProjectASTBuilder.Source = BaseScopedEditionFilter(base: base, excluded: ["a", "c"])
        let failures = try forwardingFailures(of: wrapper, editionBook: ["b"], view: ["b"])
        XCTAssertEqual(failures.count, 2, "scope and wholeness: \(failures)")
        XCTAssertTrue(failures.contains { $0.hasPrefix("resolutionScope reads [\"a\", \"b\", \"c\"]") },
                      "\(failures)")
        XCTAssertTrue(failures.contains { $0.hasPrefix("isWholeBook is false") }, "\(failures)")
    }

    // MARK: - the production source

    private var tmp: URL!

    override func setUp() async throws {
        tmp = TestTemp.root.appendingPathComponent("PublishContext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func cited(_ id: String, key: String) -> ResearchItem {
        ResearchItem(id: id, title: "Item \(id)", type: .asset, kind: .link,
                     url: "https://example.com/\(id)",
                     citation: CitationInfo(key: key, authors: ["Smith"], year: 2026))
    }

    /// A novel with two chapters, each bootstrapped into the op log through
    /// `Document.load`, so `orderedPieces()` can derive both.
    private func makeNovelStore() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(named: "Ctx", in: tmp)
        let store = try await ProjectStore.load(from: url)
        store.manifest.structure.append(StructureItem(
            id: "doc-two", title: "Two", type: .document, path: "manuscript/two.md"))
        for (index, item) in store.manifest.structure.enumerated() {
            let docURL = url.appendingPathComponent(try XCTUnwrap(item.path))
            try "Chapter \(index + 1).".write(to: docURL, atomically: true, encoding: .utf8)
            let doc = try await Document.load(
                url: docURL, actor: .author, session: "ctx", presenter: nil)
            await doc.close()
        }
        return store
    }

    func test_projectStoreSource_buildsTheContextFromTheManifestAndTheRealURL() async throws {
        let store = try await makeNovelStore()
        store.manifest.profile = .report
        store.manifest.switches = ProjectSwitches(numberSections: false)
        store.manifest.research.append(cited("r-live", key: "smith2026"))
        store.manifest.research.append(ResearchItem(
            id: "g", title: "Group", type: .group, children: [cited("r-kid", key: "jones2025")]))

        let src: any ProjectASTBuilder.Source = ProjectStoreASTSource(projectStore: store)
        let ctx = src.publishContext()

        XCTAssertEqual(ctx.projectURL, store.url)
        XCTAssertEqual(ctx.profile, .report)
        XCTAssertFalse(ctx.switches.numberSections, "the stored switch wins")
        XCTAssertTrue(ctx.switches.listOfFigures, "the Report profile's default")
        XCTAssertTrue(ctx.switches.listOfTables, "the Report profile's default")
        XCTAssertEqual(ctx.library.keys, ["smith2026", "jones2025"], "children are walked")

        let expected = Dictionary(uniqueKeysWithValues: ProjectStoreASTSource(projectStore: store)
            .publishablePieces().compactMap { item in item.path.map { (item.id, $0) } })
        XCTAssertFalse(expected.isEmpty, "premise: the novel has publishable pieces")
        XCTAssertEqual(ctx.piecePaths, expected)
        XCTAssertTrue(ctx.piecePaths.values.allSatisfy { !$0.hasPrefix("/") }, "project-relative")
    }

    /// A trashed source is not citable: the library is built from live
    /// research only.
    func test_projectStoreSource_libraryExcludesTrashedResearch() async throws {
        let store = try await makeNovelStore()
        store.manifest.research.append(cited("r-live", key: "smith2026"))
        store.manifest.research.append(cited("r-gone", key: "gone2024"))
        try await store.deleteResearchItem(id: "r-gone")
        let trashed = await store.trashedResearchCitationKeys()
        XCTAssertEqual(trashed, ["gone2024"], "premise: the item is in the Trash")

        let src: any ProjectASTBuilder.Source = ProjectStoreASTSource(projectStore: store)
        XCTAssertEqual(src.publishContext().library.keys, ["smith2026"])
        XCTAssertNil(src.publishContext().library.entry(for: "gone2024"))
    }

    /// A body `BodyPlan` binds to a language, then wraps, still answers the
    /// real project's context, and its scope is the whole book.
    func test_bodyPlanRebindingAndWrapping_keepTheContextAndTheWholeBookScope() async throws {
        let store = try await makeNovelStore()
        store.manifest.research.append(cited("r-live", key: "smith2026"))
        let src = ProjectStoreASTSource(projectStore: store)
        let all = src.publishablePieces().map(\.id)
        XCTAssertGreaterThan(all.count, 1, "premise: more than one piece to filter")

        let rebound: any ProjectASTBuilder.Source = src.rebound(toLanguage: "es")
        XCTAssertEqual(rebound.publishContext().projectURL, store.url)
        XCTAssertEqual(rebound.publishContext().library.keys, ["smith2026"])

        let plan = try BodyPlan.make(
            set: try LanguageSet(language: nil, languages: nil, sourceTag: "en"),
            resolved: PublishConfig(),
            source: src,
            publishDir: store.url.appendingPathComponent(".maugham/publish"),
            wrap: { FilteredASTSource(base: $0, sectionIDs: [all[0]], editionExcludedSectionIDs: []) })
        let body = plan.first.source
        XCTAssertEqual(try body.orderedPieces().map(\.pieceID), [all[0]], "premise: a subset body")
        XCTAssertEqual(body.publishContext().projectURL, store.url)
        XCTAssertEqual(try body.resolutionScope.orderedPieces().map(\.pieceID), all)
    }

    /// `SampleCompiler` hands `PreviewCompiler` a SCRATCH directory as its
    /// `projectURL`, with the live source. The context comes from the source,
    /// so a sample's body — filtered to its selection exactly as the preview
    /// wraps it — still names the real project, never the scratch.
    func test_sampleCompile_theContextNamesTheRealProjectNotTheScratch() async throws {
        let store = try await makeNovelStore()
        let src = ProjectStoreASTSource(projectStore: store)
        let first = try XCTUnwrap(src.publishablePieces().first?.id)
        let proposal = DesignProposalStore.Proposal(
            id: "p-ctx", designerName: "Tschichold", round: 1, language: nil,
            created: Date(), status: .pending, specMarkdown: "", filePaths: [],
            sampleResult: nil, revertNote: nil)
        let scratch = SampleCompiler.scratchURL(proposal: proposal, projectURL: store.url)

        let plan = try BodyPlan.make(
            set: try LanguageSet(language: nil, languages: nil, sourceTag: "en"),
            resolved: PublishConfig(),
            source: src,
            publishDir: scratch.appendingPathComponent(".maugham/publish"),
            wrap: { FilteredASTSource(base: $0, sectionIDs: [first], editionExcludedSectionIDs: []) })
        let ctx = plan.first.source.publishContext()
        XCTAssertEqual(ctx.projectURL, store.url)
        XCTAssertNotEqual(ctx.projectURL, scratch)
        XCTAssertFalse(ctx.projectURL?.path.hasPrefix(scratch.path) ?? true)
    }
}

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

    /// What a filtering wrapper over `ContextSource(ids: a,b,c)` that keeps
    /// only `b` gets wrong, as sentences; empty means it forwards both
    /// requirements. Everything is asked through the existential.
    private func forwardingFailures(of wrapper: any ProjectASTBuilder.Source) throws -> [String] {
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
        if scopeIDs != ["a", "b", "c"] {
            failures.append("resolutionScope reads \(scopeIDs), not the whole book [a, b, c]")
        }
        // Premise: the wrapper really is a subset view, or the scope check
        // above proves nothing.
        // A subset view must say so, or the resolution would reuse the
        // subset's AST as the whole book (`forCompile(source:built:…)`).
        if wrapper.isWholeBook {
            failures.append("isWholeBook is true for a subset view")
        }
        let viewIDs = try wrapper.orderedPieces().map(\.pieceID)
        if viewIDs != ["b"] {
            failures.append("premise: the wrapper's own view is \(viewIDs), not [b]")
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

    func test_filteredASTSource_forwardsContextAndScopeThroughAnySource() throws {
        let wrapper: any ProjectASTBuilder.Source = FilteredASTSource(base: base, sectionIDs: ["b"])
        XCTAssertEqual(try forwardingFailures(of: wrapper), [])
    }

    func test_includeFilteredASTSource_forwardsContextAndScopeThroughAnySource() throws {
        let wrapper: any ProjectASTBuilder.Source = IncludeFilteredASTSource(
            base: base, excludedSectionIDs: ["a", "c"])
        XCTAssertEqual(try forwardingFailures(of: wrapper), [])
    }

    /// Wrappers nest (a preview's filter over a body bound by `BodyPlan`):
    /// the scope is still the innermost base's whole book.
    func test_nestedWrappers_reachTheInnermostBase() throws {
        let inner = IncludeFilteredASTSource(base: base, excludedSectionIDs: ["c"])
        let outer: any ProjectASTBuilder.Source = FilteredASTSource(base: inner, sectionIDs: ["b"])
        XCTAssertEqual(try forwardingFailures(of: outer), [])
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
        let failures = try forwardingFailures(of: wrapper)
        XCTAssertEqual(failures.count, 5, "context (3 facts), scope and wholeness all lost: \(failures)")
        XCTAssertTrue(failures.contains("isWholeBook is true for a subset view"), "\(failures)")
        XCTAssertTrue(failures.contains { $0.hasPrefix("resolutionScope") }, "\(failures)")
        XCTAssertFalse(failures.contains { $0.hasPrefix("premise") }, "\(failures)")
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
            wrap: { FilteredASTSource(base: $0, sectionIDs: [all[0]]) })
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
            wrap: { FilteredASTSource(base: $0, sectionIDs: [first]) })
        let ctx = plan.first.source.publishContext()
        XCTAssertEqual(ctx.projectURL, store.url)
        XCTAssertNotEqual(ctx.projectURL, scratch)
        XCTAssertFalse(ctx.projectURL?.path.hasPrefix(scratch.path) ?? true)
    }
}

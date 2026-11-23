import XCTest
import MaughamCore
@testable import Maugham

/// **Research is the book's or a piece's, never both** (shell p5 Task 4a, the
/// owner's ruling of 2026-11-22). `ResearchHomes` is the one answer; these
/// pin what it answers (a table), that nothing it answers leaves an item on
/// no row (a property over generated books), what it costs (counted), and
/// that no tree surface asks anything else (a census with a planted offender).
@MainActor
final class ResearchHomesTests: XCTestCase {

    // MARK: - Fixtures

    private func chapter(_ id: String, links: [String]? = nil) -> StructureItem {
        StructureItem(id: id, title: id.uppercased(), type: .document,
                      path: "manuscript/\(id).md", linkedResearchIds: links)
    }

    private func note(_ id: String, in folder: String = "research") -> ResearchItem {
        ResearchItem(id: id, title: id.capitalized, type: .asset, kind: .document,
                     path: "\(folder)/\(id).md")
    }

    private func group(_ id: String, _ children: [ResearchItem],
                       in folder: String = "research") -> ResearchItem {
        ResearchItem(id: id, title: id.capitalized, type: .group, path: "\(folder)/\(id)",
                     children: children)
    }

    private var palette: ResearchItem {
        var palette = group("pal", [note("card", in: "research/palette")])
        palette.role = .paletteGroup
        return palette
    }

    /// A novel: `ch1` links `linked`, `both`, the group `grp` and `inner` (in
    /// the whole-book group `world`); `ch2`, inside a Part, links `both`,
    /// `inner2` and an id the research does not hold.
    private var novel: (structure: [StructureItem], research: [ResearchItem]) {
        ([chapter("ch1", links: ["linked", "both", "grp", "inner"]),
          StructureItem(id: "part", title: "Part", type: .group,
                        children: [chapter("ch2", links: ["both", "inner2", "ghost"])])],
         [note("book"), note("linked"), note("both"),
          group("grp", [note("ingrp")]),
          group("world", [note("inner", in: "research/world"), note("inner2", in: "research/world"),
                          note("stays", in: "research/world")]),
          palette])
    }

    private func homes(_ structure: [StructureItem], _ research: [ResearchItem],
                       _ type: ProjectType = .novel) -> ResearchHomes {
        ResearchHomes.derive(structure: structure, research: research, projectType: type)
    }

    // MARK: - The table

    func test_theDerivationTable_aNovel() {
        let (structure, research) = novel
        let homes = homes(structure, research)
        // Unlinked: the book's.
        XCTAssertTrue(homes.isWholeBook("book"))
        XCTAssertEqual(homes.homes(of: "book"), [])
        // Linked to one: that chapter's only.
        XCTAssertFalse(homes.isWholeBook("linked"))
        XCTAssertEqual(homes.homes(of: "linked"), ["ch1"])
        // Linked to two: both, in tree order.
        XCTAssertEqual(homes.homes(of: "both"), ["ch1", "ch2"])
        // A linked group: the group and everything in it, drawn under the group.
        XCTAssertEqual(homes.homes(of: "grp"), ["ch1"])
        XCTAssertEqual(homes.homes(of: "ingrp"), ["ch1"])
        XCTAssertEqual(homes.foldRoots(of: "ch1").map(\.id), ["linked", "both", "grp", "inner"],
                       "a fold's roots, in the order the chapter linked them")
        XCTAssertEqual(homes.foldRoots(of: "ch2").map(\.id), ["both", "inner2"])
        // Inside a whole-book group: filtered out of the group, never moved.
        XCTAssertEqual(homes.place(of: "inner"), "World")
        XCTAssertNil(homes.place(of: "linked"), "a root names no place")
        let world = homes.wholeBook.first { $0.id == "world" }
        XCTAssertEqual(world?.children?.map(\.id), ["stays"],
                       "the group stays in the section with its whole-book note")
        XCTAssertEqual(homes.wholeBook.map(\.id), ["book", "world"])
        // A link to an id the research does not hold names nothing.
        XCTAssertEqual(homes.homes(of: "ghost"), [])
        // The palette's cards are the Palette section's.
        XCTAssertFalse(homes.isWholeBook("card"))
        XCTAssertEqual(homes.homes(of: "card"), [])
        // Links: the chapters linking an item itself, not through its group.
        XCTAssertEqual(homes.links(of: "ingrp"), [])
        XCTAssertEqual(homes.links(of: "both"), ["ch1", "ch2"])
    }

    /// **A link held by a piece the structure lost falls back to the book**,
    /// and comes back when the piece does: trashing a chapter takes its
    /// `linkedResearchIds` with it, and restoring it brings them back (the
    /// dormant-link semantics) — so a restored chapter has its research again.
    func test_aLinkToAPieceNoLongerInTheBookFallsBackToTheBook() {
        let research = [note("tides")]
        let live = [chapter("ch1"), chapter("ch3", links: ["tides"])]
        XCTAssertEqual(homes(live, research).homes(of: "tides"), ["ch3"])
        let trashed = [chapter("ch1")]
        XCTAssertTrue(homes(trashed, research).isWholeBook("tides"),
                      "while ch3 is in the Trash, its note is the book's")
        XCTAssertEqual(homes(live, research).homes(of: "tides"), ["ch3"],
                       "restored, it is ch3's again")
    }

    func test_theDerivationTable_aCollection() {
        let pieceA = StructureItem(id: "pA", title: "A", type: .document,
                                   path: "pieces/01-a/01-a.md", pieceKind: .loose)
        let pieceB = StructureItem(id: "pB", title: "B", type: .document,
                                   path: "pieces/02-b/02-b.md", pieceKind: .loose,
                                   linkedResearchIds: ["shared"])
        let research = [note("shared"), note("book"),
                        group("own", [note("deep", in: "pieces/01-a/research/own")],
                              in: "pieces/01-a/research"),
                        note("stray", in: "pieces/09-gone/research")]
        let homes = homes([pieceA, pieceB], research, .collection)
        XCTAssertEqual(homes.homes(of: "own"), ["pA"])
        XCTAssertEqual(homes.homes(of: "deep"), ["pA"])
        XCTAssertEqual(homes.owner(of: "deep"), "pA")
        XCTAssertEqual(homes.homes(of: "shared"), ["pB"], "the two kinds read alike")
        XCTAssertTrue(homes.isWholeBook("book"))
        XCTAssertTrue(homes.isWholeBook("stray"),
                      "a folder no live piece owns has no fold: the book draws it")
        XCTAssertFalse(homes.takesLinks("pA"), "a Collection files, it does not link")
    }

    func test_aSingleDocumentProjectsResearchIsAllTheBooks() {
        for type in [ProjectType.shortStory, .screenplay] {
            let homes = homes([chapter("doc", links: ["tides"])], [note("tides")], type)
            XCTAssertTrue(homes.isWholeBook("tides"), "\(type)")
            XCTAssertEqual(homes.pieceOrder, [], "\(type): its one piece keeps no fold of its own")
        }
    }

    func test_thePreferredFoldIsTheOpenPiecesElseTheFirst() {
        let (structure, research) = novel
        let homes = homes(structure, research)
        XCTAssertEqual(homes.preferredFold(of: "both", openPiece: "ch2"), "ch2")
        XCTAssertEqual(homes.preferredFold(of: "both", openPiece: "ch9"), "ch1")
        XCTAssertEqual(homes.preferredFold(of: "both", openPiece: nil), "ch1")
        XCTAssertNil(homes.preferredFold(of: "book", openPiece: "ch1"))
    }

    // MARK: - Nothing becomes invisible (B)

    /// **Every research item has a row, always** — over generated books:
    /// nested groups, items linked to no chapter, one, two, a missing piece,
    /// linked groups, in a novel and a Collection. A row is counted where the
    /// tree draws it: the Research section's tree (`wholeBook`), and each
    /// piece's fold as `PieceFoldIndex.entries` lists it (the drawn layer, each
    /// root with its subtree). Either/or: an item drawn in the section is in
    /// no fold, and one in a fold is not in the section; no fold draws an item
    /// twice; and the read-through gate's owners are its homes.
    func test_everyItemHasARowInEveryGeneratedBook() {
        for seed in UInt64(1)...60 {
            var rng = SplitMix(seed: seed)
            let collection = seed % 3 == 0
            let (structure, research) = collection
                ? generatedCollection(&rng) : generatedNovel(&rng)
            let type: ProjectType = collection ? .collection : .novel
            let homes = homes(structure, research, type)
            var sectionRows = Set<String>()
            func walk(_ items: [ResearchItem]) {
                for item in items { sectionRows.insert(item.id); walk(item.children ?? []) }
            }
            walk(homes.wholeBook)
            var foldRows: [String: Int] = [:]
            for piece in TreeWalk.collect(in: structure, where: { $0.type == .document }) {
                let fold = TreeSectionDerivation.pieceFold(for: piece, projectType: type, homes: homes)
                let shelf = PinnedReferences.pinned(
                    forDocId: piece.id, links: piece.linkedResearchIds, derived: [],
                    scene: nil, scraps: [:], items: CanvasItemIndex.over(research: research))
                let entries = PieceFoldIndex.entries(
                    docId: piece.id, shelf: shelf, fold: fold, figures: [], links: [],
                    structure: structure, research: research)
                var inThisFold: [String] = []
                for case .research(let id, _, _) in entries {
                    guard let item = TreeWalk.find(id: id, in: research) else { continue }
                    inThisFold.append(id)
                    inThisFold += TreeWalk.collect(in: item.children ?? [], where: { _ in true }).map(\.id)
                }
                XCTAssertEqual(inThisFold.count, Set(inThisFold).count,
                               "seed \(seed): \(piece.id)'s fold draws an item twice")
                for id in inThisFold { foldRows[id, default: 0] += 1 }
            }
            let paletteIds = Set(TreeWalk.collect(
                in: PaletteLookup.paletteGroup(in: research).map { [$0] } ?? [], where: { _ in true })
                .map(\.id))
            let gate = ReadThroughGate(pieces: Set(homes.pieceOrder), structure: structure,
                                       research: research, projectType: type,
                                       figures: [], figureLines: [])
            for item in TreeWalk.collect(in: research, where: { _ in true })
            where !paletteIds.contains(item.id) {
                let inSection = sectionRows.contains(item.id)
                let folds = foldRows[item.id] ?? 0
                XCTAssertTrue(inSection || folds > 0, "seed \(seed): \(item.id) has no row")
                XCTAssertFalse(inSection && folds > 0, "seed \(seed): \(item.id) is drawn in both")
                XCTAssertEqual(folds, homes.homes(of: item.id).count,
                               "seed \(seed): \(item.id) has a row under each home")
                XCTAssertEqual(gate.owners(of: .research(item.id)), Set(homes.homes(of: item.id)),
                               "seed \(seed): the gate and the tree agree on whose \(item.id) is")
            }
        }
    }

    private func generatedNovel(_ rng: inout SplitMix) -> ([StructureItem], [ResearchItem]) {
        var research: [ResearchItem] = []
        var ids: [String] = []
        func make(_ depth: Int, _ prefix: String) -> ResearchItem {
            let id = "\(prefix)-\(ids.count)"
            ids.append(id)
            if depth < 3, rng.next(4) == 0 {
                let children = (0..<rng.next(4)).map { _ in make(depth + 1, id) }
                return ResearchItem(id: id, title: id, type: .group, path: "research/\(id)",
                                    children: children)
            }
            return note(id)
        }
        for _ in 0..<(3 + rng.next(8)) { research.append(make(0, "r")) }
        research.append(palette)
        let chapters = (0..<(1 + rng.next(5))).map { "ch\($0)" }
        var links: [String: [String]] = [:]
        for id in ids {
            switch rng.next(5) {
            case 0: links[chapters[rng.next(chapters.count)], default: []].append(id)
            case 1:
                for chapter in chapters.shuffledPrefix(2, &rng) { links[chapter, default: []].append(id) }
            case 2: links["gone", default: []].append(id)   // a piece no longer in the book
            default: break
            }
        }
        var structure = chapters.map { chapter($0, links: links[$0]) }
        if structure.count > 2 {
            // Some chapters inside a Part.
            let inside = Array(structure.suffix(2))
            structure = Array(structure.dropLast(2))
                + [StructureItem(id: "part", title: "Part", type: .group, children: inside)]
        }
        return (structure, research)
    }

    private func generatedCollection(_ rng: inout SplitMix) -> ([StructureItem], [ResearchItem]) {
        let pieces = (0..<(1 + rng.next(4))).map { index in
            StructureItem(id: "p\(index)", title: "P\(index)", type: .document,
                          path: "pieces/0\(index)-p/0\(index)-p.md", pieceKind: .loose)
        }
        var research: [ResearchItem] = [palette]
        var shared: [String] = []
        for index in 0..<(3 + rng.next(8)) {
            let id = "r\(index)"
            if rng.next(2) == 0 {
                let piece = rng.next(pieces.count + 1)   // one past: a folder no piece owns
                let folder = "pieces/0\(piece)-p/research"
                research.append(rng.next(3) == 0
                    ? group(id, [note("\(id)c", in: "\(folder)/\(id)")], in: folder)
                    : note(id, in: folder))
            } else {
                research.append(note(id))
                shared.append(id)
            }
        }
        var linked = pieces
        for id in shared where rng.next(3) == 0 {
            let index = rng.next(linked.count)
            linked[index].linkedResearchIds = (linked[index].linkedResearchIds ?? []) + [id]
        }
        return (linked, research)
    }

    // MARK: - Cost (I)

    /// **One derivation per manifest, never one per row**, at 200 chapters ×
    /// 500 research items: the window's cache derives once however many rows
    /// ask, the derivation visits each node once, and a changed manifest
    /// derives once more (tripwire 4).
    func test_aTwoHundredChapterBookDerivesOncePerManifest() {
        var research: [ResearchItem] = []
        for g in 0..<50 {
            research.append(group("g\(g)", (0..<9).map { note("n\(g)-\($0)") }))
        }
        let chapters = (0..<200).map { index in
            chapter("ch\(index)", links: index % 2 == 0 ? ["n\(index % 50)-1", "g\(index % 50)"] : nil)
        }
        var manifest = ProjectManifest(type: .novel, title: "Big", author: "A", created: Date(),
                                       modified: Date(), structure: chapters, research: research)
        let state = BinderTreeSectionsState()
        for _ in 0..<(200 + 500) {
            _ = state.researchHomes(in: manifest)
        }
        XCTAssertEqual(state.researchHomesCache.derivations, 1,
                       "every row asked; the book was walked once")
        XCTAssertEqual(state.researchHomes(in: manifest).visited, 200 + 500,
                       "one visit per chapter and per research item")
        manifest.research.append(note("new"))
        for _ in 0..<100 { _ = state.researchHomes(in: manifest) }
        XCTAssertEqual(state.researchHomesCache.derivations, 2, "a change derives once more")
    }

    /// The body paths ask the window's cache; the derivation runs only where
    /// it is once per change (the fold index's task, a drop, the gate) or a
    /// pure spelling tests use — counted per file.
    func test_theDerivationRunsOnlyWhereItIsOncePerChange() throws {
        let expected: [String: Int] = [
            "Maugham/Stores/ResearchHomes.swift": 1,          // the cache
            "Maugham/Views/TreeSectionDerivation.swift": 2,   // the by-id and section spellings
            "Maugham/Views/PieceFoldContents.swift": 1,       // the index, in its task
            "Maugham/Views/TreeDropIntent.swift": 1,          // per drop
            "Maugham/Views/ReadThrough.swift": 1,             // the gate, per change of the set
        ]
        var found: [String: Int] = [:]
        for root in ["Maugham"] {
            for file in try SourceTree.swiftFiles(under: root) {
                let count = SourceScan.codeLines(of: try SourceTree.read(file))
                    .filter { $0.contains("ResearchHomes.derive(") }.count
                if count > 0 { found[file] = count }
            }
        }
        XCTAssertEqual(found, expected)
    }

    // MARK: - One predicate (A)

    /// The tokens that restate where research lives: a document's links read
    /// directly, a piece folder's prefix, a fold's roots by path.
    static let restatements = [".linkedResearchIds", "pieceResearchPrefix(",
                               "pieceResearchSectionRoots(", "researchFolders("]

    /// The code lines of `text` that restate the rule.
    static func restating(_ text: String) -> [String] {
        SourceScan.codeLines(of: text).filter { line in
            restatements.contains { line.contains($0) }
        }
    }

    /// **No tree surface restates where research lives**: the section, the
    /// folds, the reveals, the drops, the menus and the gate ask `ResearchHomes`
    /// (the gate keeps the folder list for Find's file paths, which have no
    /// manifest item to ask about).
    func test_noTreeSurfaceRestatesWhereResearchLives() throws {
        let allowed: [String: Int] = [
            "Maugham/Views/ReadThrough.swift": 1,
            // "Link Research…" edits a chapter's links; it reads them to show
            // which are on, not to place a row.
            "Maugham/Views/ResearchLinkPickerSheet.swift": 1,
        ]
        var found: [String: Int] = [:]
        for file in try SourceTree.swiftFiles(under: "Maugham/Views") {
            let lines = Self.restating(try SourceTree.read(file))
            if !lines.isEmpty { found[file] = lines.count }
        }
        XCTAssertEqual(found, allowed)
        // And each of them asks the one answer.
        for file in ["Maugham/Views/BinderTreeSections.swift", "Maugham/Views/BinderPieceFold.swift",
                     "Maugham/Views/TreeSectionDerivation.swift", "Maugham/Views/PieceFoldContents.swift",
                     "Maugham/Views/TreeDropIntent.swift", "Maugham/Views/ResearchHomeMenu.swift",
                     "Maugham/Views/ReadThrough.swift"] {
            let code = SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: "\n")
            XCTAssertTrue(code.contains("ResearchHomes") || code.contains("researchHomes("), file)
        }
    }

    func test_theRestatementCensusSeesAPlantedOffender() {
        XCTAssertEqual(Self.restating("let ids = item.linkedResearchIds ?? []").count, 1)
        XCTAssertEqual(Self.restating("let p = ProjectStore.pieceResearchPrefix(for: piece)").count, 1)
        // Control: a comment naming it is not code, and the one answer is not a restatement.
        XCTAssertEqual(Self.restating("// reads `linkedResearchIds` through the homes").count, 0)
        XCTAssertEqual(Self.restating("let homes = state.researchHomes(in: manifest)").count, 0)
    }
}

/// A small seeded generator, so a failing book can be named by its seed.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// A number in `0..<bound` (0 for an empty bound).
    mutating func next(_ bound: Int) -> Int {
        bound <= 0 ? 0 : Int(nextRaw() % UInt64(bound))
    }
}

private extension Array {
    /// Up to `count` distinct elements, in a seeded order.
    func shuffledPrefix(_ count: Int, _ rng: inout SplitMix) -> [Element] {
        var pool = self
        var out: [Element] = []
        while out.count < count, !pool.isEmpty {
            out.append(pool.remove(at: rng.next(pool.count)))
        }
        return out
    }
}

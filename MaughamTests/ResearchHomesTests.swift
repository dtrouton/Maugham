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
    /// linked groups, Parts nested deep, a card claiming a note, in a novel,
    /// a Collection (a reference piece's links included), a short story and a
    /// screenplay. A row is counted where the tree draws it: the Research
    /// section's tree (`wholeBook`), and each piece's fold as the host draws
    /// it — the index a task built from a STALE manifest (the links before
    /// the last edit), read through the current homes
    /// (`PieceFoldIndex.layout(of:homes:)`), each research root with its
    /// subtree and a card's note as its card.
    ///
    /// Either/or: an item drawn in the section is in no fold and one in a
    /// fold is not in the section; no fold draws an item twice; a group that
    /// holds only pieces' items is drawn nowhere and holds nothing else
    /// (`isContainer`). A single-document project draws the book's research
    /// in the section and, as its one piece's, in that piece's fold too (R6).
    func test_everyItemHasARowInEveryGeneratedBook() {
        for seed in UInt64(1)...90 {
            var rng = SplitMix(seed: seed)
            let type: ProjectType = [.novel, .novel, .collection, .shortStory, .screenplay][Int(seed % 5)]
            let (structure, research) = type.holdsPieces
                ? generatedCollection(&rng) : generatedNovel(&rng)
            let stale = relinked(structure, research: research, &rng)
            let homes = homes(structure, research, type)
            var sectionRows = Set<String>()
            func walk(_ items: [ResearchItem]) {
                for item in items { sectionRows.insert(item.id); walk(item.children ?? []) }
            }
            walk(homes.wholeBook)
            var built = builtIndex(stale, research, type)
            // A card claims a leaf the stale fold drew as research: its row
            // is the card's from then on (the shelf's first claim).
            var claimed = Set<String>()
            for (piece, rows) in built.entries {
                guard let index = rows.firstIndex(where: {
                    if case .research(let id, _, _) = $0 {
                        return TreeWalk.find(id: id, in: research)?.type == .asset
                    }
                    return false
                }), rng.next(2) == 0, case .research(let id, let title, _) = rows[index] else { continue }
                var next = rows
                next[index] = .card(PinnedReference(id: id, kind: .research(itemId: id), title: title))
                var entries = built.entries
                entries[piece] = next
                built = PieceFoldIndex(entries: entries)
                claimed.insert(id)
            }
            var foldRows: [String: Int] = [:]
            var cardRows = Set<String>()
            for piece in TreeWalk.collect(in: structure, where: { $0.type == .document }) {
                let layout = built.layout(of: piece.id, homes: homes)
                let entries: [PieceFoldEntry]
                switch layout {
                case .rows(let rows)?: entries = rows
                case .groups(let runs)?: entries = runs.flatMap(\.entries)
                case nil: entries = []
                }
                var inThisFold: [String] = []
                for entry in entries {
                    switch entry {
                    case .research(let id, _, _):
                        guard let item = TreeWalk.find(id: id, in: research) else { continue }
                        inThisFold.append(id)
                        inThisFold += TreeWalk.collect(in: item.children ?? [], where: { _ in true }).map(\.id)
                    case .card(let ref):
                        // A card is the canvas's row, not the research's.
                        if case .research(let id) = ref.kind { cardRows.insert(id) }
                    default: break
                    }
                }
                // A single document's fold lists the book's assets as built
                // (R6), its own shape; either/or is a book of pieces'.
                if !homes.pieceOrder.isEmpty {
                    XCTAssertEqual(inThisFold.count, Set(inThisFold).count,
                                   "seed \(seed): \(piece.id)'s fold draws an item twice")
                }
                for id in inThisFold { foldRows[id, default: 0] += 1 }
            }
            let paletteIds = Set(TreeWalk.collect(
                in: PaletteLookup.paletteGroup(in: research).map { [$0] } ?? [], where: { _ in true })
                .map(\.id))
            let singleDocument = homes.pieceOrder.isEmpty
            for item in TreeWalk.collect(in: research, where: { _ in true })
            where !paletteIds.contains(item.id) {
                let inSection = sectionRows.contains(item.id)
                let folds = foldRows[item.id] ?? 0
                if homes.isContainer(item.id) {
                    XCTAssertFalse(inSection || folds > 0, "seed \(seed): container \(item.id) is drawn")
                    XCTAssertTrue((item.children ?? []).allSatisfy {
                        !homes.homes(of: $0.id).isEmpty || homes.isContainer($0.id)
                    }, "seed \(seed): container \(item.id) holds something of the book's")
                    continue
                }
                XCTAssertTrue(inSection || folds > 0 || cardRows.contains(item.id),
                              "seed \(seed): \(item.id) has no row")
                if singleDocument {
                    XCTAssertTrue(inSection, "seed \(seed) \(type): the book draws \(item.id)")
                    continue
                }
                XCTAssertFalse(inSection && folds > 0, "seed \(seed): \(item.id) is drawn in both")
                // A card's note inside a group is its group's row in the fold.
                if !claimed.contains(item.id) {
                    XCTAssertEqual(folds, homes.homes(of: item.id).count,
                                   "seed \(seed): \(item.id) has a row under each home")
                }
            }
        }
    }

    /// **The read-through gate against an oracle written here, not asked of
    /// `ResearchHomes`** (M1): a research item is frozen by a piece in
    /// read-through exactly when that piece links it or a group above it, or
    /// (a Collection) files it in its own folder — and a piece counts only
    /// while it is in the book and keeps research of its own. Every piece of
    /// every generated book is put in read-through alone, and the gate's
    /// answer compared item by item.
    func test_theReadThroughGateAgreesWithAnOracle() {
        for seed in UInt64(1)...40 {
            var rng = SplitMix(seed: seed)
            let type: ProjectType = [.novel, .collection, .shortStory][Int(seed % 3)]
            let (structure, research) = type.holdsPieces
                ? generatedCollection(&rng) : generatedNovel(&rng)
            let pieces = TreeWalk.collect(in: structure, where: { $0.type == .document })
            for piece in pieces {
                let gate = ReadThroughGate(pieces: [piece.id], structure: structure,
                                           research: research, projectType: type,
                                           figures: [], figureLines: [])
                for item in TreeWalk.collect(in: research, where: { _ in true }) {
                    XCTAssertEqual(gate.owners(of: .research(item.id)).contains(piece.id),
                                   Self.oracleFreezes(item.id, by: piece, structure: structure,
                                                      research: research, type: type),
                                   "seed \(seed) \(type): \(item.id) under \(piece.id)")
                }
            }
        }
    }

    /// The oracle: plain rules over the manifest, in their own words.
    private static func oracleFreezes(_ id: String, by piece: StructureItem,
                                      structure: [StructureItem], research: [ResearchItem],
                                      type: ProjectType) -> Bool {
        guard let routing = try? ProjectStore.researchRouting(for: piece, projectType: type) else {
            return false
        }
        if case .sharedOnly = routing { return false }
        if let palette = PaletteLookup.paletteGroup(in: research),
           palette.id == id || TreeWalk.contains(id: id, in: palette.children ?? []) { return false }
        // The item and every group above it.
        var chain: [ResearchItem] = []
        func path(_ items: [ResearchItem], _ above: [ResearchItem]) -> Bool {
            for item in items {
                if item.id == id { chain = above + [item]; return true }
                if path(item.children ?? [], above + [item]) { return true }
            }
            return false
        }
        guard path(research, []) else { return false }
        let links = Set(piece.linkedResearchIds ?? [])
        if chain.contains(where: { links.contains($0.id) }) { return true }
        // A Collection piece's own folder: `pieces/<its folder>/research/…`.
        if type.holdsPieces, let piecePath = piece.path, let rootPath = chain.first?.path {
            let folder = (piecePath as NSString).deletingLastPathComponent
            return rootPath.hasPrefix(folder + "/research/")
        }
        return false
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
        let chapters = (0..<(1 + rng.next(6))).map { "ch\($0)" }
        let links = randomLinks(ids, chapters: chapters, &rng)
        var structure = chapters.map { chapter($0, links: links[$0]) }
        // Parts, nested up to three deep.
        var depth = 0
        while structure.count > 2, depth < 3, rng.next(3) != 0 {
            let inside = Array(structure.suffix(2))
            structure = Array(structure.dropLast(2))
                + [StructureItem(id: "part\(depth)", title: "Part \(depth)", type: .group,
                                 children: inside)]
            depth += 1
        }
        return (structure, research)
    }

    private func randomLinks(_ ids: [String], chapters: [String],
                             _ rng: inout SplitMix) -> [String: [String]] {
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
        return links
    }

    /// The same book with its chapters' links drawn again — what a fold
    /// index built before the last link edits holds.
    private func relinked(_ structure: [StructureItem], research: [ResearchItem],
                          _ rng: inout SplitMix) -> [StructureItem] {
        let ids = TreeWalk.collect(in: research, where: { $0.role == nil }).map(\.id)
        let pieces = TreeWalk.collect(in: structure, where: { $0.type == .document }).map(\.id)
        let links = randomLinks(ids, chapters: pieces, &rng)
        func redo(_ items: [StructureItem]) -> [StructureItem] {
            items.map { item in
                var item = item
                if item.type == .document, item.pieceKind != .reference {
                    item.linkedResearchIds = links[item.id]
                }
                item.children = item.children.map(redo)
                return item
            }
        }
        return redo(structure)
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
        // A reference piece (another project's): its links place nothing here.
        if rng.next(2) == 0 {
            linked.append(StructureItem(id: "ref", title: "Ref", type: .document,
                                        path: "../Elsewhere/elsewhere.md", pieceKind: .reference,
                                        linkedResearchIds: shared.isEmpty ? nil : [shared[0]]))
        }
        return (linked, research)
    }

    // MARK: - One manifest state for the section and the folds (fix round 1, I6)

    /// The fold index as its task last built it, for `structure`.
    private func builtIndex(_ structure: [StructureItem], _ research: [ResearchItem],
                            _ type: ProjectType = .novel) -> PieceFoldIndex {
        let homes = homes(structure, research, type)
        var entries: [String: [PieceFoldEntry]] = [:]
        for piece in TreeWalk.collect(in: structure, where: { $0.type == .document }) {
            let rows = PieceFoldIndex.entries(
                docId: piece.id,
                shelf: PinnedReferences.pinned(
                    forDocId: piece.id, links: piece.linkedResearchIds, derived: [], scene: nil,
                    scraps: [:], items: CanvasItemIndex.over(research: research)),
                fold: TreeSectionDerivation.pieceFold(for: piece, projectType: type, homes: homes),
                figures: [], links: [], structure: structure, research: research)
            if !rows.isEmpty { entries[piece.id] = rows }
        }
        return PieceFoldIndex(entries: entries)
    }

    /// **A link that arrives under an unchanged stamp** (a synced manifest
    /// whose `modified` decodes equal) moves the note out of the section and
    /// into its fold in the same pass: the drawn fold reads the homes the
    /// section reads, whatever the index's key says. Before, the index kept
    /// the old fold until an unrelated change, and the note was in neither.
    func test_aLinkThatArrivesUnderAnUnchangedStampIsDrawnInItsFold() {
        let research = [note("tides"), note("book")]
        let before = [chapter("ch1")]
        let after = [chapter("ch1", links: ["tides"])]
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        let built = builtIndex(before, research)
        XCTAssertNil(built.layout(of: "ch1"), "premise: the built index has no fold for ch1")

        let state = BinderTreeSectionsState()
        state.foldIndex = built
        let manifest = ProjectManifest(type: .novel, title: "N", author: "A", created: stamp,
                                       modified: stamp, structure: after, research: research)
        XCTAssertFalse(state.researchHomes(in: manifest).wholeBook.contains { $0.id == "tides" },
                       "the section no longer draws it")
        guard case .rows(let rows)? = state.foldLayout(of: "ch1", in: manifest) else {
            return XCTFail("the fold draws it in the same pass")
        }
        XCTAssertEqual(rows, [.research(id: "tides", title: "Tides", owned: false)])

        // And back: unlinked under the same stamp, the fold lets it go as the
        // section takes it.
        state.foldIndex = builtIndex(after, research)
        let unlinked = ProjectManifest(type: .novel, title: "N", author: "A", created: stamp,
                                       modified: stamp, structure: before, research: research)
        XCTAssertTrue(state.researchHomes(in: unlinked).wholeBook.contains { $0.id == "tides" })
        XCTAssertNil(state.foldLayout(of: "ch1", in: unlinked), "no twin left in the fold")
    }

    /// A card that claims a note keeps it: the drawn fold reads the homes for
    /// research rows and never draws a card's note twice.
    func test_aCardsClaimSurvivesTheLiveResearchRows() {
        let ref = PinnedReference(id: "tides", kind: .research(itemId: "tides"), title: "Tides")
        let index = PieceFoldIndex(entries: ["ch1": [.card(ref)]])
        let homes = homes([chapter("ch1", links: ["tides"])], [note("tides")])
        guard case .rows(let rows)? = index.layout(of: "ch1", homes: homes) else {
            return XCTFail("the fold is drawn")
        }
        XCTAssertEqual(rows, [.card(ref)])
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

        // **An equal manifest in new buffers** (an adopted, unchanged one —
        // M3): compared once, and the key takes its buffers, so every later
        // lookup is the free comparison again.
        let compares = state.researchHomesCache.contentCompares
        var adopted = manifest
        adopted.structure = manifest.structure.map { $0 }
        adopted.research = manifest.research.map { $0 }
        for _ in 0..<100 { _ = state.researchHomes(in: adopted) }
        XCTAssertEqual(state.researchHomesCache.derivations, 2, "equal content derives nothing")
        XCTAssertEqual(state.researchHomesCache.contentCompares, compares + 1,
                       "one deep compare, then the key holds the new buffers")
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

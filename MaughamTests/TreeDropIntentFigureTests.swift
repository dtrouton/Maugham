import XCTest
import MaughamCore
@testable import Maugham

/// **What a drag between Research and the Figures section MEANS** (report
/// plan 8b Task 5, spec §7, D8-2): a Research table, picture or PDF dropped on
/// Figures is *Use in Document*; a figure dropped on Research is *Send to
/// Research* into the scope the target names — a piece row or its fold is that
/// piece's Research, a group is the group — and nothing dropped within Figures
/// moves, since numbers follow the text. The answers per target × figure id /
/// research id / structure id / unknown id, per project type, in a table: the
/// classifier is pure, a drag session is not synthesisable.
final class TreeDropIntentFigureTests: XCTestCase {

    private typealias Intent = TreeDropIntent.Intent

    private static let fig = "fig-0a1b2c3d"
    private static let other = "fig-1b2c3d4e"
    private static let figures = [
        FigureRecord(id: fig, name: "cash", kind: .table, piece: nil, path: "figures/cash.csv"),
        FigureRecord(id: other, name: "map", kind: .image, piece: nil, path: "figures/map.png"),
    ]

    private static func asset(_ id: String, _ kind: ResearchItem.AssetKind, _ path: String) -> ResearchItem {
        ResearchItem(id: id, title: id, type: .asset, kind: kind, path: path)
    }

    /// Shared Research every fixture holds: a note, a table, a picture, a
    /// PDF, and a group "world" with a table inside.
    private static let shared: [ResearchItem] = [
        asset("note", .document, "research/note.md"),
        asset("table", .table, "research/table.csv"),
        asset("photo", .image, "research/photo.png"),
        asset("scan", .pdf, "research/scan.pdf"),
        ResearchItem(id: "world", title: "World", type: .group, path: "research/world", children: [
            asset("nested", .table, "research/world/nested.csv"),
        ]),
    ]

    private struct Fixture {
        let type: ProjectType
        let structure: [StructureItem]
        let research: [ResearchItem]

        func classify(_ payload: String, _ target: TreeDropIntent.Target) -> Intent {
            TreeDropIntent.classify(payloadId: payload, target: target, structure: structure,
                                    research: research, figures: TreeDropIntentFigureTests.figures,
                                    projectType: type)
        }
    }

    private let novel = Fixture(
        type: .novel,
        structure: [
            StructureItem(id: "ch1", title: "One", type: .document, path: "manuscript/01.md",
                          linkedResearchIds: ["note"]),
            StructureItem(id: "grp", title: "Part", type: .group, children: []),
        ],
        research: shared)

    private let collection = Fixture(
        type: .collection,
        structure: [
            StructureItem(id: "pA", title: "A", type: .document, path: "pieces/01-a/01-a.md",
                          pieceKind: .loose),
            StructureItem(id: "pRef", title: "Ref", type: .document, path: "pieces/02-ref",
                          pieceKind: .reference),
        ],
        research: shared + [
            asset("pieceTable", .table, "pieces/01-a/research/t.csv"),
            ResearchItem(id: "pieceGroup", title: "Sources", type: .group,
                         path: "pieces/01-a/research/sources", children: [
                            asset("pieceNested", .table, "pieces/01-a/research/sources/n.csv"),
                         ]),
        ])

    private func single(_ type: ProjectType) -> Fixture {
        Fixture(type: type,
                structure: [StructureItem(id: "doc", title: "Story", type: .document,
                                          path: "manuscript/story.md")],
                research: Self.shared)
    }

    private func send(_ scope: ResearchScope, _ group: String? = nil) -> Intent {
        .sendFigureToResearch(figureId: Self.fig, scope: scope, group: group)
    }

    // MARK: - Research → Figures

    /// A table, picture or PDF dropped on the header or any figure's row is
    /// *Use in Document*, in every type whose manuscript holds figures; a
    /// note, a group, a manuscript row and an unknown id are refused.
    func test_aFigureSourceDroppedOnFiguresIsUseInDocument() {
        for fixture in [novel, collection, single(.shortStory)] {
            for target in [TreeDropIntent.Target.figuresSection, .figureRow(Self.fig), .figureRow(Self.other)] {
                let label = "\(fixture.type) → \(target)"
                for source in ["table", "photo", "scan", "nested"] {
                    XCTAssertEqual(fixture.classify(source, target), .useInDocument(researchId: source),
                                   "\(source) \(label)")
                }
                XCTAssertEqual(fixture.classify("note", target), .refuse(.notAFigureKind), "note \(label)")
                XCTAssertEqual(fixture.classify("world", target), .refuse(.notAFigureKind), "group \(label)")
                XCTAssertEqual(fixture.classify(fixture.structure[0].id, target), .refuse(.notAFigureKind),
                               "manuscript row \(label)")
                XCTAssertEqual(fixture.classify("elsewhere-9f2c", target), .refuse(.unknownId),
                               "unknown \(label)")
            }
        }
        XCTAssertEqual(collection.classify("pieceTable", .figuresSection),
                       .useInDocument(researchId: "pieceTable"), "a piece's own table")
    }

    func test_aScreenplayMakesNoFigureFromResearch() {
        XCTAssertEqual(single(.screenplay).classify("table", .figuresSection), .refuse(.notAFigureKind),
                       "a screenplay's manuscript holds no figures (holdsFigures)")
    }

    // MARK: - Within Figures

    func test_aFigureDroppedWithinFiguresIsRefused() {
        for fixture in [novel, collection, single(.shortStory)] {
            XCTAssertEqual(fixture.classify(Self.fig, .figuresSection), .refuse(.alreadyInFigures))
            XCTAssertEqual(fixture.classify(Self.fig, .figureRow(Self.other)), .refuse(.figuresHaveNoOrder),
                           "\(fixture.type): no renumber by a drag")
            XCTAssertEqual(fixture.classify(Self.fig, .figureRow(Self.fig)), .refuse(.sameRow))
        }
    }

    // MARK: - Figures → Research

    func test_aFigureDroppedOnSharedResearchSendsToShared() {
        for fixture in [novel, collection, single(.shortStory)] {
            let label = "\(fixture.type)"
            XCTAssertEqual(fixture.classify(Self.fig, .sharedSection), send(.shared), label)
            XCTAssertEqual(fixture.classify(Self.fig, .researchRow("note")), send(.shared),
                           "\(label): beside a root row, the shared root")
            XCTAssertEqual(fixture.classify(Self.fig, .researchRow("world")), send(.shared, "world"),
                           "\(label): a group is a destination")
            XCTAssertEqual(fixture.classify(Self.fig, .researchRow("nested")), send(.shared, "world"),
                           "\(label): beside a row inside a group, that group")
            XCTAssertEqual(fixture.classify(Self.fig, .researchRow("ghost")), .refuse(.unknownId), label)
        }
    }

    /// A novel chapter's Research is links: the copy is made in shared
    /// Research and linked to the chapter (`ResearchScope.document`), from the
    /// chapter's row or any row in its fold, a group's included.
    func test_aFigureDroppedOnANovelChapterGoesToThatChaptersResearch() {
        XCTAssertEqual(novel.classify(Self.fig, .pieceRow("ch1")), send(.document("ch1")))
        XCTAssertEqual(novel.classify(Self.fig, .foldRow(rowId: "note", documentId: "ch1")),
                       send(.document("ch1")))
        XCTAssertEqual(novel.classify(Self.fig, .foldRow(rowId: "world", documentId: "ch1")),
                       send(.document("ch1")), "a linked fold places nothing in a group")
        XCTAssertEqual(novel.classify(Self.fig, .pieceRow("grp")), .refuse(.notAResearchTarget))
        XCTAssertEqual(novel.classify(Self.fig, .pieceRow("nobody")), .refuse(.unknownId))
    }

    /// A Collection piece's Research is its folder: the piece row, its fold,
    /// and its own group.
    func test_aFigureDroppedOnACollectionPieceGoesToItsFolder() {
        XCTAssertEqual(collection.classify(Self.fig, .pieceRow("pA")), send(.document("pA")))
        XCTAssertEqual(collection.classify(Self.fig, .foldRow(rowId: "pieceTable", documentId: "pA")),
                       send(.document("pA")))
        XCTAssertEqual(collection.classify(Self.fig, .foldRow(rowId: "pieceGroup", documentId: "pA")),
                       send(.document("pA"), "pieceGroup"))
        XCTAssertEqual(collection.classify(Self.fig, .foldRow(rowId: "pieceNested", documentId: "pA")),
                       send(.document("pA"), "pieceGroup"))
        XCTAssertEqual(collection.classify(Self.fig, .researchRow("pieceGroup")),
                       send(.document("pA"), "pieceGroup"), "the piece's group, wherever it is drawn")
        XCTAssertEqual(collection.classify(Self.fig, .researchRow("pieceTable")), send(.document("pA")))
        XCTAssertEqual(collection.classify(Self.fig, .pieceRow("pRef")), .refuse(.notAResearchTarget),
                       "a referenced piece keeps its Research in its own project")
    }

    func test_aSingleDocumentsRowIsSharedResearch() {
        for type in [ProjectType.shortStory, .screenplay] {
            XCTAssertEqual(single(type).classify(Self.fig, .pieceRow("doc")), send(.shared), "\(type)")
        }
    }

    /// Control: what a note dropped on Research meant before is unchanged by
    /// the registry being passed.
    func test_researchAndStructureDropsAreUnchangedByTheRegistry() {
        XCTAssertEqual(novel.classify("table", .pieceRow("ch1")),
                       .link(researchId: "table", toDocumentId: "ch1"))
        XCTAssertEqual(collection.classify("note", .pieceRow("pA")), .rescope(ids: ["note"], to: .piece("pA")))
        XCTAssertEqual(novel.classify("ch1", .sharedSection), .refuse(.structureOntoResearch))
    }
}

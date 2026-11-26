import Foundation
import MaughamCore
@testable import Maugham

/// **A Collection's read-through gate, by value** (shell read-through Task 4):
/// piece A with its own research folder (a nested note), piece B, a shared
/// note, A's figure and a book-wide one — the shape every read-through suite
/// asks its targets of. `figureLines` places figures' lines in pieces, as the
/// window's listing does.
enum ReadThroughGateFixture {
    static let pieceA = "piece-a"
    static let pieceB = "piece-b"
    /// A's own research: its folder group and the note nested in it.
    static let folder = "a-folder"
    static let nestedNote = "a-nested"
    static let sharedNote = "shared"
    /// A's figure (`FigureRecord.piece` = A) and the whole book's.
    static let figureA = "fig-a"
    static let bookFigure = "fig-book"

    static func doc(_ id: String, _ path: String, loose: Bool = false) -> StructureItem {
        StructureItem(id: id, title: id, type: .document, path: path,
                      pieceKind: loose ? .loose : nil)
    }

    static let structure = [doc(pieceA, "pieces/01-a/a.md", loose: true),
                            doc(pieceB, "pieces/02-b/b.md", loose: true)]

    static let research = [
        ResearchItem(id: folder, title: "A notes", type: .group,
                     path: "pieces/01-a/research/notes",
                     children: [ResearchItem(id: nestedNote, title: "Tide", type: .asset,
                                             kind: .document,
                                             path: "pieces/01-a/research/notes/tide.md")]),
        ResearchItem(id: sharedNote, title: "Shared", type: .asset, kind: .document,
                     path: "research/shared.md"),
    ]

    static let figures = [
        FigureRecord(id: figureA, name: "A's table", kind: .table, piece: pieceA,
                     path: "figures/a.csv"),
        FigureRecord(id: bookFigure, name: "Book table", kind: .table, piece: nil,
                     path: "figures/book.csv"),
    ]

    /// A listing row placing `figureId`'s one line in `piece`.
    static func line(_ figureId: String, in piece: String) -> FigureListing.Row {
        FigureListing.Row(figureId: figureId, kind: .table, name: figureId, caption: "",
                          number: "Table 1", usedIn: [.init(docId: piece, lineIndex: 0)],
                          referencedFrom: [], pieceOfLine: piece)
    }

    static func gate(pieces: Set<String>, figureLines: [FigureListing.Row] = []) -> ReadThroughGate {
        ReadThroughGate(pieces: pieces, structure: structure, research: research,
                        projectType: .collection, figures: figures, figureLines: figureLines)
    }
}

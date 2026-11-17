import XCTest
import MaughamCore
@testable import Maugham

/// Shell plan 2, Task 1 — `ResolveScope.of`: what To resolve is about, from
/// the faces' subject. Pure.
final class ResolveScopeTests: XCTestCase {

    /// A Collection: a Part of two chapters, a loose piece, and a reference
    /// piece living in another project.
    private let structure: [StructureItem] = [
        StructureItem(id: "grp-1", title: "Part One", type: .group, children: [
            StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md"),
            StructureItem(id: "doc-b", title: "B", type: .document, path: "manuscript/b.md"),
        ]),
        StructureItem(id: "doc-c", title: "C", type: .document, path: "manuscript/c.md"),
        StructureItem(id: "doc-r", title: "R", type: .document, path: "manuscript/r.md",
                      pieceKind: .reference),
    ]

    func test_aDocumentIsAPieceAndAGroupItsDocuments() {
        XCTAssertEqual(ResolveScope.of(.item("doc-c"), structure: structure, projectType: .collection),
                       .piece(docId: "doc-c"))
        XCTAssertEqual(ResolveScope.of(.item("grp-1"), structure: structure, projectType: .collection),
                       .pieces(docIds: ["doc-a", "doc-b"], includesBookLevel: false))
        XCTAssertEqual(ResolveScope.of(.project, structure: structure, projectType: .collection),
                       .pieces(docIds: ["doc-a", "doc-b", "doc-c"], includesBookLevel: true))
    }

    func test_editionCanvasInboxPaletteAreOutside() {
        for faces: BinderSubject in [.edition(language: "es"), .canvas, .inbox, .palette,
                                     .research("res-1"), .item("doc-gone")] {
            XCTAssertEqual(ResolveScope.of(faces, structure: structure, projectType: .novel), .outside,
                           "\(faces)")
        }
        XCTAssertEqual(ResolveScope.outside.docIds, [])
    }

    func test_aReferencePieceIsElsewhereAndAddsNothingToTheBook() {
        let scope = ResolveScope.of(.item("doc-r"), structure: structure, projectType: .collection)
        XCTAssertEqual(scope, .elsewhere(docId: "doc-r"))
        XCTAssertEqual(scope.docIds, [], "a reference piece holds nothing here")
        let book = ResolveScope.of(.project, structure: structure, projectType: .collection)
        XCTAssertFalse(book.docIds.contains("doc-r"))
    }

    func test_aScreenplaysBookIsItsScript() {
        let script = [StructureItem(id: "doc-s", title: "Script", type: .document, path: "script.fountain")]
        XCTAssertEqual(ResolveScope.of(.project, structure: script, projectType: .screenplay),
                       .piece(docId: "doc-s", includesBookLevel: true))
        // CONTROL: the same one-document structure in prose is a Book.
        XCTAssertEqual(ResolveScope.of(.project, structure: script, projectType: .novel),
                       .pieces(docIds: ["doc-s"], includesBookLevel: true))
    }

    func test_aFigureIsAFigureScope() {
        let scope = ResolveScope.of(.figure("fig-aaaa1111"), structure: structure, projectType: .novel)
        XCTAssertEqual(scope, .figure(id: "fig-aaaa1111"))
        XCTAssertEqual(scope.docIds, ["fig-aaaa1111"])
    }
}

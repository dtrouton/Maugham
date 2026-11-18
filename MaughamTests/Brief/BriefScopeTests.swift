import XCTest
import MaughamCore
@testable import Maugham

/// Shell plan 3, Task 1 — `BriefScope`: what Brief is about, from the faces.
final class BriefScopeTests: XCTestCase {

    private let book: [StructureItem] = [
        StructureItem(id: "grp-1", title: "Part One", type: .group, children: [
            StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md"),
            StructureItem(id: "grp-2", title: "Inner", type: .group, children: [
                StructureItem(id: "doc-b", title: "B", type: .document, path: "manuscript/b.md"),
            ]),
        ]),
        StructureItem(id: "doc-c", title: "C", type: .document, path: "manuscript/c.md"),
    ]

    func test_aDocumentIsAPieceAGroupIsAPartAndTheProjectIsTheBook() {
        XCTAssertEqual(BriefScope.of(.item("doc-a"), structure: book, projectType: .novel),
                       .piece(docId: "doc-a"))
        XCTAssertEqual(BriefScope.of(.item("grp-1"), structure: book, projectType: .novel),
                       .part(groupId: "grp-1", docIds: ["doc-a", "doc-b"]),
                       "a Part is its document descendants, in manuscript order")
        XCTAssertEqual(BriefScope.of(.project, structure: book, projectType: .novel), .book)
        XCTAssertEqual(BriefScope.of(.edition(language: "es"), structure: book, projectType: .novel),
                       .edition(language: "es"))
        XCTAssertEqual(BriefScope.of(.item("nope"), structure: book, projectType: .novel), .outside,
                       "an id the structure does not hold is outside")
    }

    func test_aScreenplaysBookIsItsScript() {
        let script = [StructureItem(id: "doc-s", title: "Script", type: .document, path: "script.fountain")]
        XCTAssertEqual(BriefScope.of(.project, structure: script, projectType: .screenplay),
                       .piece(docId: "doc-s"))
        // CONTROL: the same structure in a novel is the Book.
        XCTAssertEqual(BriefScope.of(.project, structure: script, projectType: .novel), .book)
    }

    func test_aReferencePieceIsElsewhere() {
        let collection = [
            StructureItem(id: "doc-r", title: "R", type: .document, path: "pieces/r.md", pieceKind: .reference),
            StructureItem(id: "doc-o", title: "O", type: .document, path: "pieces/o.md"),
        ]
        XCTAssertEqual(BriefScope.of(.item("doc-r"), structure: collection, projectType: .collection),
                       .elsewhere(docId: "doc-r"))
        XCTAssertEqual(BriefScope.of(.item("doc-o"), structure: collection, projectType: .collection),
                       .piece(docId: "doc-o"))
    }

    func test_theCanvasInboxPaletteAFigureAndResearchAreOutside() {
        for faces: BinderSubject in [.canvas, .inbox, .palette, .figure("fig-1"), .research("r-1")] {
            XCTAssertEqual(BriefScope.of(faces, structure: book, projectType: .novel), .outside, "\(faces)")
        }
    }
}

import XCTest
import MaughamCore
@testable import MaughamPhone

/// Unit coverage for the pure Read-tab icon/eligibility mapping (E.3). The views
/// are build-verified; this pins the branching logic the rows depend on.
final class ReadIconsTests: XCTestCase {

    func test_projectSymbol_perType() {
        XCTAssertEqual(ProjectType.shortStory.symbolName, "doc.text")
        XCTAssertEqual(ProjectType.novel.symbolName, "book.closed")
        XCTAssertEqual(ProjectType.screenplay.symbolName, "film")
        XCTAssertEqual(ProjectType.collection.symbolName, "books.vertical")
        XCTAssertEqual(ProjectType.unknown.symbolName, "questionmark.folder")
    }

    func test_structureSymbol_group_isFolder() {
        let group = StructureItem(id: "g_1", title: "Act I", type: .group)
        XCTAssertEqual(ReadIcons.structureSymbol(group), "folder")
    }

    func test_structureSymbol_documentByExtension() {
        let md = StructureItem(id: "d_1", title: "Ch1", type: .document, path: "manuscript/ch1.md")
        let fountain = StructureItem(id: "d_2", title: "Scene", type: .document, path: "script.fountain")
        XCTAssertEqual(ReadIcons.structureSymbol(md), "doc.text")
        XCTAssertEqual(ReadIcons.structureSymbol(fountain), "film")
        let upper = StructureItem(id: "d_4", title: "Scene", type: .document, path: "script.FOUNTAIN")
        let txt = StructureItem(id: "d_5", title: "Raw", type: .document, path: "notes.txt")
        XCTAssertEqual(ReadIcons.structureSymbol(upper), "film")
        XCTAssertEqual(ReadIcons.structureSymbol(txt), "doc")
    }

    func test_structureSymbol_pathlessDocument_fallsBackToGenericPage() {
        let doc = StructureItem(id: "d_3", title: "Stub", type: .document, path: nil)
        XCTAssertEqual(ReadIcons.structureSymbol(doc), "doc")
    }

    func test_researchSymbol_perKind() {
        XCTAssertEqual(ReadIcons.researchSymbol(.image), "photo")
        XCTAssertEqual(ReadIcons.researchSymbol(.document), "doc.text")
        XCTAssertEqual(ReadIcons.researchSymbol(.pdf), "doc.richtext")
        XCTAssertEqual(ReadIcons.researchSymbol(.audio), "waveform")
        XCTAssertEqual(ReadIcons.researchSymbol(.link), "link")
        XCTAssertEqual(ReadIcons.researchSymbol(nil), "doc")
    }

    func test_isReadableResearch_onlyTextDocumentsWithPath() {
        let doc = ResearchItem(id: "r_1", title: "Notes", type: .asset, kind: .document, path: "research/notes.md")
        XCTAssertTrue(ReadIcons.isReadableResearch(doc))

        // nil kind with a path is treated as openable text.
        let untyped = ResearchItem(id: "r_2", title: "Loose", type: .asset, kind: nil, path: "research/x.md")
        XCTAssertTrue(ReadIcons.isReadableResearch(untyped))

        // Media/link kinds are listed but not openable in the text reader.
        let image = ResearchItem(id: "r_3", title: "Map", type: .asset, kind: .image, path: "research/map.png")
        XCTAssertFalse(ReadIcons.isReadableResearch(image))

        // A group is not an asset.
        let group = ResearchItem(id: "r_4", title: "Refs", type: .group)
        XCTAssertFalse(ReadIcons.isReadableResearch(group))

        // A path-less document can't be opened.
        let pathless = ResearchItem(id: "r_5", title: "Stub", type: .asset, kind: .document, path: nil)
        XCTAssertFalse(ReadIcons.isReadableResearch(pathless))
    }
}

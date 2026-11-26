import XCTest
import MaughamCore
@testable import Maugham

final class WindowSubjectTests: XCTestCase {

    private let structure: [StructureItem] = [
        StructureItem(id: "ch-1", title: "One", type: .document, path: "one.md"),
    ]

    private func validated(_ w: WindowSubject, languages: Set<String> = ["es"]) -> WindowSubject {
        w.validated(structure: structure, researchIDs: ["r-1"], figureIDs: ["f-1"],
                    editionLanguages: languages)
    }

    func test_aLiveSubjectIsUntouched() {
        let w = WindowSubject(open: .item("ch-1"), faces: .figure("f-1"),
                              beside: .research("r-1"))
        XCTAssertEqual(validated(w), w)
    }

    func test_aRemovedPieceFallsBackToTheBook() {
        let w = WindowSubject(open: .item("gone"), faces: .item("gone"), beside: nil)
        XCTAssertEqual(validated(w), .book)
    }

    func test_aRemovedBesideItemBecomesNil() {
        let w = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"),
                              beside: .research("gone"))
        XCTAssertEqual(validated(w),
                       WindowSubject(open: .item("ch-1"), faces: .item("ch-1"), beside: nil))
    }

    func test_anEditionWhoseLanguageIsGoneFallsBackToTheBook() {
        let w = WindowSubject(open: .edition(language: "sr"), faces: .project, beside: nil)
        XCTAssertEqual(validated(w).open, .project)
        XCTAssertEqual(validated(WindowSubject(open: .edition(language: "es"),
                                               faces: .project, beside: nil)).open,
                       .edition(language: "es"))
    }

    func test_aGoneFigureAndAGoneFacesFallToTheBook() {
        let w = WindowSubject(open: .figure("gone"), faces: .research("gone"), beside: nil)
        XCTAssertEqual(validated(w), .book)
    }

    func test_codableRoundTripsEveryCase() throws {
        for s in [BinderSubject.project, .item("a"), .research("b"), .figure("c"),
                  .inbox, .canvas, .palette, .edition(language: "es")] {
            let w = WindowSubject(open: s, faces: s, beside: .research("r"))
            let back = try JSONDecoder().decode(WindowSubject.self,
                                                from: JSONEncoder().encode(w))
            XCTAssertEqual(back, w)
        }
    }
}

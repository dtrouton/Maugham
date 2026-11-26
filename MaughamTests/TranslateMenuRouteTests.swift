import XCTest
import MaughamCore
@testable import Maugham

/// **File ▸ Translate… runs what its title names, or says why it does not**
/// (shell p5 Task 7 fix round 1, review C1). The title comes from the scope
/// To resolve will show (`ResolveScope.of(faces, readIn:)`, the pane's own),
/// never the centre; the ask carries its target; a head runs only an ask for
/// itself and says why otherwise; a pending ask dies with its scope. Each of
/// the review's three failure states failed on the pre-fix code (report).
@MainActor
final class TranslateMenuRouteTests: XCTestCase {
    private let structure = [
        StructureItem(id: "c1", title: "One", type: .document, path: "one.md"),
        StructureItem(id: "part-1", title: "Part", type: .group, children: [
            StructureItem(id: "c2", title: "Two", type: .document, path: "two.md"),
        ]),
    ]
    private let novel = PieceNoun.Book(type: .novel)

    /// (faces, the faces read in) → the scope the pane shows → the offer.
    private func offer(faces: BinderSubject, readIn: String?, open: String = "c1",
                       may: Bool = true, any: Bool = true) -> TranslateMenuOffer? {
        let scope = ResolveScope.of(faces, readIn: readIn, sourceLanguage: "en",
                                    structure: structure, projectType: .novel)
        return TranslateMenuOffer.of(scope: scope, isOpen: { $0 == open }, structure: structure, book: novel,
                                     mayTranslate: { _ in may }, mayTranslateAny: any)
    }

    func test_theOfferIsTheScopesNeverTheCentres() {
        XCTAssertEqual(offer(faces: .item("c1"), readIn: "sr"),
                       .piece(docId: "c1", noun: .chapter, language: "sr"))
        XCTAssertEqual(offer(faces: .item("c1"), readIn: "sr")?.title,
                       "Translate This Chapter into \(LanguageName.title("sr"))")
        // (a) The Serbian edition faced (the centre may read a chapter in
        // Serbian — it is not asked): the book, titled as the book.
        XCTAssertEqual(offer(faces: .edition(language: "sr"), readIn: "sr"), .book(language: "sr"))
        XCTAssertEqual(offer(faces: .edition(language: "sr"), readIn: nil)?.title,
                       "Translate Whole Book into \(LanguageName.title("sr"))")
        // (b) A Part or the Book faced: no head would take an ask, so none.
        XCTAssertNil(offer(faces: .item("part-1"), readIn: "sr"))
        XCTAssertNil(offer(faces: .project, readIn: "sr"))
        XCTAssertNil(offer(faces: .edition(language: "en"), readIn: nil), "the Source edition translates nothing")
        XCTAssertNil(offer(faces: .item("c1"), readIn: nil), "a chapter read in Source")
        XCTAssertNil(offer(faces: .item("c2"), readIn: "sr"), "the head's Run needs the piece open")
        XCTAssertNil(offer(faces: .item("c1"), readIn: "sr", may: false), "the translator may not")
        XCTAssertNil(offer(faces: .edition(language: "sr"), readIn: nil, any: false))
    }

    /// (a, the head) A chapter's ask reaching the edition's head is refused
    /// in words — never `runBook()`; a book's ask reaching a chapter's head
    /// likewise; each head runs its own.
    func test_aHeadRunsOnlyAnAskForItself() {
        let chapter = TranslateMenuOffer.piece(docId: "c1", noun: .chapter, language: "sr")
        let book = TranslateMenuOffer.book(language: "sr")
        XCTAssertEqual(TranslateMenuOffer.answer(chapter, editionHead: "sr"), .refuse(chapter.notHereLine))
        XCTAssertEqual(TranslateMenuOffer.answer(book, pieceHead: "c1", language: "sr"), .refuse(book.notHereLine))
        XCTAssertEqual(TranslateMenuOffer.answer(chapter, pieceHead: "c2", language: "sr"), .refuse(chapter.notHereLine),
                       "another chapter's head")
        XCTAssertEqual(TranslateMenuOffer.answer(chapter, pieceHead: "c1", language: "es"), .refuse(chapter.notHereLine),
                       "another language")
        XCTAssertEqual(TranslateMenuOffer.answer(chapter, pieceHead: "c1", language: "sr"), .run)
        XCTAssertEqual(TranslateMenuOffer.answer(book, editionHead: "sr"), .run)
        XCTAssertTrue(chapter.notHereLine.contains(chapter.title), "the notice names what was asked")
    }

    /// (b, the pane) An ask that does not land in the pane's scope is said
    /// there, not left set; (c) a pending ask does not outlive its scope.
    func test_anAskOutsideItsScopeIsSaidAndAPendingAskDiesWithItsScope() throws {
        let chapter = TranslateMenuOffer.piece(docId: "c1", noun: .chapter, language: "sr")
        XCTAssertTrue(chapter.lands(in: .pieceInLanguage(docId: "c1", language: "sr")))
        XCTAssertFalse(chapter.lands(in: .pieces(docIds: ["c2"], includesBookLevel: false)))
        XCTAssertFalse(TranslateMenuOffer.book(language: "sr")
            .lands(in: .edition(language: "sr", isSource: true, docIds: [])))
        XCTAssertNil(ResolvePane.pendingSurvivingScopeChange(.translate(chapter)))
        XCTAssertEqual(ResolvePane.pendingSurvivingScopeChange(.filter(.mine)), .filter(.mine),
                       "control: other requests wait for the read as before")
        func flat(_ path: String) throws -> String {
            SourceScan.codeLines(of: try SourceTree.read(path))
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        let pane = try flat("Maugham/Views/Resolve/ResolvePane.swift")
        XCTAssertTrue(pane.contains("if case .translate(let ask) = pending { if ask.lands(in: scope) { translateAsk = ask } else { filedNotice = FiledNotice.after( .filed(FiledNotice.Filing(sentence: ask.notHereLine, brief: nil)), current: filedNotice) } return }"))
        XCTAssertTrue(pane.contains("translateAsk = nil pendingRequest = Self.pendingSurvivingScopeChange(pendingRequest)"))
        // The heads ask the one answer, and say every refusal.
        let piece = try flat("Maugham/Views/Resolve/ResolvePieceInLanguage.swift")
        XCTAssertTrue(piece.contains("if case .refuse(let line) = TranslateMenuOffer.answer(asked, pieceHead: docId, language: language) { notice = line return }"))
        XCTAssertTrue(piece.contains("notice = TranslateMenuOffer.notOfferedLine"))
        let edition = try flat("Maugham/Views/Resolve/ResolveEditionItems.swift")
        XCTAssertTrue(edition.contains("if case .refuse(let line) = TranslateMenuOffer.answer(asked, editionHead: language) { notice = line return }"))
        XCTAssertTrue(edition.contains("notice = TranslateMenuOffer.notOfferedLine"))
        // The receiver asks with the offer the item is titled by.
        let window = SourceScan.codeLines(of: try SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"]))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(window.contains("guard let offer = translateOffer else { return } ProjectWindow.selectPosition(.resolve, showInspector: $showInspector, position: $position) resolveRequest = .translate(offer)"))
        XCTAssertTrue(window.contains("translate: translateMenuOffer)"), "the item's title reads the same cached offer")
        XCTAssertTrue(window.contains("translateOffer: translateMenuOffer,"))
    }
}
